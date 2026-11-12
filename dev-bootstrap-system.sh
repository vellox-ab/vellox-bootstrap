#!/usr/bin/env bash
# HELP>
# dev-bootstrap-system.sh (v6) — the server half of the Ubuntu dev bootstrap
#
# Run ONCE per machine, as root. Then every developer runs
# dev-bootstrap-user.sh as themselves (no sudo needed for that one).
#
# Supports Ubuntu 24.04 LTS (noble) and 26.04 LTS (resolute) from one file.
# Everything release-specific is detected at runtime.
#
# Idempotent AND self-cleaning: every re-run first removes the apt sources and
# keyrings that earlier versions of this script created, then re-derives them
# for the release it is actually running on. It never touches sources it did
# not create.
#
#   sudo bash dev-bootstrap-system.sh                  # everything
#   sudo bash dev-bootstrap-system.sh --clean-only     # only remove our apt artifacts
#   bash dev-bootstrap-system.sh --help
#
#   sudo SKIP_MSSQL=1 bash dev-bootstrap-system.sh     # skip a section
#   sudo DEV_EXTRAS_UPGRADE=1 bash dev-bootstrap-system.sh   # re-fetch the GitHub-release tools
#   sudo NODE_MAJOR=current bash dev-bootstrap-system.sh     # newest Node major, not newest LTS
#
# What it does: apt packages, Node (NodeSource), .NET SDK, the PostgreSQL and
# SQL Server clients, Docker, extra tools from GitHub releases (installed to
# /usr/local/bin for every user), inotify / open-file limits, and a light
# hardening pass (unattended-upgrades, fail2ban, ufw). The firewall opens SSH
# (and mosh) only; set DEV_UFW_TRUST to networks that should reach every port
# (none by default — production-safe).
#
#   sudo SKIP_EXTRAS=1 SKIP_DOCKER=1 SKIP_HARDENING=1 bash dev-bootstrap-system.sh
#   sudo DEV_UFW_TRUST="10.8.0.0/24" bash dev-bootstrap-system.sh
#
# It ends by removing what nothing uses any more — unused packages and config
# left by removed kernels and Node packages. Database servers, Docker and the
# bootloader are never removed.
#
#   sudo SKIP_AUTOREMOVE=1 bash dev-bootstrap-system.sh    # list leftover packages only
#
# It asks nothing, so it runs unattended.
#
# Deliberately NOT using `set -e`: a single failing repo must never leave the
# machine half-configured. Failures are collected and reported at the end.
#
# <HELP
set -uo pipefail

# ---------------------------------------------------------------- settings --
NODE_MAJOR="${NODE_MAJOR:-lts}"         # lts | current | a major number
DOTNET_MAJOR="${DOTNET_MAJOR:-}"        # empty = newest SDK the distro offers
PG_MAJOR="${PG_MAJOR:-}"                # empty = newest client PGDG carries
SKIP_SYSTEM="${SKIP_SYSTEM:-0}"
SKIP_NODE="${SKIP_NODE:-0}"
SKIP_DOTNET="${SKIP_DOTNET:-0}"
SKIP_MSSQL="${SKIP_MSSQL:-0}"
SKIP_POSTGRES="${SKIP_POSTGRES:-0}"
SKIP_EXTRAS="${SKIP_EXTRAS:-0}"         # lazygit, atuin, starship, ...
SKIP_DOCKER="${SKIP_DOCKER:-0}"
SKIP_HARDENING="${SKIP_HARDENING:-0}"   # unattended-upgrades, fail2ban, ufw
SKIP_AUTOREMOVE="${SKIP_AUTOREMOVE:-0}" # 1 = list leftover packages, remove none
SKIP_SYSCTL="${SKIP_SYSCTL:-0}"
DEV_EXTRAS_UPGRADE="${DEV_EXTRAS_UPGRADE:-0}"   # 1 = re-download release tools
# Networks the firewall and fail2ban trust outright (every port open to them).
# Empty by default so the script is safe on production; SSH is allowed from
# everywhere regardless, so an empty list cannot lock you out.
DEV_UFW_TRUST="${DEV_UFW_TRUST:-}"
CLEAN_ONLY=0

MANAGED="# managed-by: dev-bootstrap -- safe to delete, regenerated on re-run"
BIN=/usr/local/bin                      # where release binaries go, for every user

for arg in "$@"; do
  case "$arg" in
    --clean-only) CLEAN_ONLY=1 ;;
    # "$0" is "bash" when the script is piped in from curl, and there is no
    # file to read the help out of — point at the repo instead of failing.
    --help|-h) if [[ -r "$0" ]]; then
                 sed -n '/^# HELP>$/,/^# <HELP$/p' "$0" | sed '1d;$d; s/^# \{0,1\}//'
               else
                 echo "Reading the script from stdin — save it to a file for the help text:"
                 echo "  curl -fsSL <url> -o dev-bootstrap-system.sh && bash dev-bootstrap-system.sh --help"
               fi
               exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------- helpers --
if [[ -t 1 ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi
log()  { printf '%s==>%s %s%s%s\n' "$G" "$N" "$B" "$*" "$N"; }
sub()  { printf '    %s\n' "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

FAILED_STEPS=()
soft() {                       # soft <label> <command...>
  local label="$1"; shift
  if ! "$@"; then
    warn "step failed: $label (continuing)"
    FAILED_STEPS+=("$label")
    return 1
  fi
  return 0
}
note_fail() { FAILED_STEPS+=("$1"); }

apt_has()  { apt-cache show "$1" >/dev/null 2>&1; }
apt_cand() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}'; }
# Not `apt-cache policy | grep -q`: grep -q quits at the match, apt-cache dies
# of SIGPIPE writing the rest, and under pipefail that reads as "not
# installable" — for every package, every time.
apt_installable() { [[ "$(apt_cand "$1")" == [0-9]* ]]; }
# dpkg -s also succeeds for a package removed with its config files kept.
pkg_installed() { [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == installed ]]; }

# ============================================================== preflight ===
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 $*"
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] || die "This script targets Ubuntu/Debian."

OS_VER="${VERSION_ID:-}"
OS_CODE="${VERSION_CODENAME:-}"
[[ -z "$OS_CODE" ]] && OS_CODE="$(lsb_release -cs 2>/dev/null || echo unknown)"
ARCH="$(dpkg --print-architecture)"
APT_VER="$(apt-get --version 2>/dev/null | head -1 | awk '{print $2}')"
APT_MAJOR="${APT_VER%%.*}"

log "Host"
sub "$(hostname) — user ${USER}"
sub "${PRETTY_NAME:-unknown}  (${OS_VER} / ${OS_CODE} / ${ARCH})"
sub "apt ${APT_VER}"

case "$OS_VER" in
  24.04|26.04) : ;;
  *) warn "Tested on Ubuntu 24.04 and 26.04; ${OS_VER} may behave differently." ;;
esac
# apt >= 3 verifies signatures with sqv and treats duplicate Signed-By values
# for one repo as a FATAL error that aborts the whole update.
(( APT_MAJOR >= 3 )) && sub "apt 3.x: strict signature checks, duplicate-source conflicts are fatal"


install -d -m 0755 "$BIN"

# =============================================================== cleanup ====
# Remove every apt artifact this script family has ever created, in any format,
# from any release. They are all regenerated below for the release we are on.
# Sources that were NOT created by us are listed but never touched.
log "Cleaning up artifacts from previous runs"

LEGACY_SOURCES=(
  /etc/apt/sources.list.d/mssql-release.list
  /etc/apt/sources.list.d/mssql-release.sources
  /etc/apt/sources.list.d/nodesource.list
  /etc/apt/sources.list.d/nodesource.sources
  /etc/apt/sources.list.d/pgdg.list
  /etc/apt/sources.list.d/pgdg.sources
  /etc/apt/sources.list.d/docker.list
  /etc/apt/sources.list.d/docker.sources
  /etc/apt/preferences.d/mssql-release.pref
)
LEGACY_KEYS=(
  /etc/apt/keyrings/microsoft-prod.gpg
  /etc/apt/keyrings/microsoft.asc
  /etc/apt/keyrings/nodesource.gpg
  /etc/apt/keyrings/nodesource.asc
  /etc/apt/keyrings/pgdg.gpg
  /etc/apt/keyrings/pgdg.asc
  /etc/apt/keyrings/docker.gpg
  /etc/apt/keyrings/docker.asc
)
removed=0
for f in "${LEGACY_SOURCES[@]}" "${LEGACY_KEYS[@]}"; do
  if [[ -e "$f" ]]; then rm -f "$f"; sub "removed  $f"; removed=$((removed+1)); fi
done
# Anything else carrying our marker (e.g. from a future rename) goes too.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  rm -f "$f"; sub "removed  $f"; removed=$((removed+1))
done < <(grep -rls "managed-by: dev-bootstrap" /etc/apt/sources.list.d/ /etc/apt/preferences.d/ 2>/dev/null)
(( removed == 0 )) && sub "nothing to clean"

log "Third-party apt sources NOT managed by this script (left untouched)"
foreign=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  foreign=1
  sub "$(basename "$f")"
  grep -vE '^\s*(#|$)' "$f" 2>/dev/null | head -4 | sed 's/^/        /'
done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null \
         | grep -v 'ubuntu\.sources' | sort)
(( foreign == 0 )) && sub "(none)"

if [[ "$CLEAN_ONLY" == "1" ]]; then
  log "Refreshing apt after cleanup"
  apt-get update 2>&1 | grep -E '^(E|W):' | sed 's/^/    /'
  log "--clean-only finished. No packages or config were changed."
  exit 0
fi

# ------------------------------------------------------------ repo helper --
# add_repo <file> <uri> <suite> <components> <keyring>
# Refuses to create a source that duplicates an existing uri+suite, because on
# apt 3.x two entries for one repo with different Signed-By values abort every
# subsequent `apt update` with "Conflicting values set for option Signed-By".
add_repo() {
  local file="$1" uri="$2" suite="$3" comps="$4" keyring="$5"
  local existing
  existing="$(grep -rlsI -- "$uri" /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null \
              | grep -v "^${file}$" | head -1)"
  if [[ -n "$existing" ]]; then
    warn "a source for ${uri} already exists ($existing) — not adding a duplicate"
    return 1
  fi
  tee "$file" >/dev/null <<EOF
${MANAGED}
Types: deb
URIs: ${uri}
Suites: ${suite}
Components: ${comps}
Signed-By: ${keyring}
EOF
  return 0
}

# fetch_keys <dest> <url...>  — concatenated armoured keys; apt accepts several
fetch_keys() {
  local dest="$1"; shift
  local tmp; tmp="$(mktemp)"
  local u
  for u in "$@"; do
    curl -fsSL --max-time 30 "$u" >> "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    printf '\n' >> "$tmp"
  done
  local n; n="$(grep -c 'BEGIN PGP PUBLIC KEY BLOCK' "$tmp")"
  if (( n < $# )); then rm -f "$tmp"; return 1; fi
  install -d -m 0755 /etc/apt/keyrings
  install -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
  gpg --show-keys --with-colons "$dest" 2>/dev/null | awk -F: '/^fpr:/{print "        key " $10}'
  return 0
}

# ========================================================== system packages ==
if [[ "$SKIP_SYSTEM" != "1" ]]; then
  log "Updating apt index"
  apt-get update 2>&1 | grep -E '^(E|W):' | sed 's/^/    /'

  # One list for both releases; anything absent on this release is skipped
  # rather than failing the whole install.
  BASE_PKGS=(
    build-essential pkg-config make cmake
    git git-lfs gh git-delta
    curl wget ca-certificates gnupg apt-transport-https software-properties-common lsb-release
    unzip zip p7zip-full xz-utils zstd unrar-free
    tmux neovim nano micro less pspg
    jq yq ripgrep fd-find fzf bat tree eza zoxide direnv vivid sd glow
    htop btop ncdu iotop lsof strace du-dust duf hyperfine procs
    net-tools dnsutils iputils-ping traceroute mtr-tiny socat openssh-client rsync
    mosh gping lnav ttyd fastfetch age tealdeer
    sqlite3 shellcheck shfmt acl attr
    bash-completion moreutils just plocate dos2unix pv tokei trash-cli
    # Newer releases carry these; on older ones the extras section fetches
    # the GitHub release instead.
    lazygit starship atuin difftastic trippy
    xclip wl-clipboard
    python3 python3-venv python3-pip python3-dev pipx
    unixodbc unixodbc-dev libssl-dev libffi-dev zlib1g-dev
  )
  WANT=(); MISSING=()
  for p in "${BASE_PKGS[@]}"; do
    if apt_has "$p"; then WANT+=("$p"); else MISSING+=("$p"); fi
  done
  (( ${#MISSING[@]} )) && warn "not available on ${OS_CODE}: ${MISSING[*]}"

  log "Installing ${#WANT[@]} base packages"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${WANT[@]}"; then
    warn "bulk install failed — retrying one by one to isolate the problem"
    for p in "${WANT[@]}"; do
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$p" \
        >/dev/null 2>&1 || { warn "  could not install: $p"; note_fail "pkg:$p"; }
    done
  fi

  git lfs install --system >/dev/null 2>&1 || true
fi

# ==================================================================== node ==
# The newest Node on both releases, from NodeSource: Ubuntu's own is a major or
# more behind (24.04 has 18, 26.04 has 22). NODE_MAJOR picks the line:
#   lts      the newest LTS major in nodejs.org's release index (the default)
#   current  the newest major, LTS or not
#   <n>      exactly that major
# The source is rewritten on every run, not only when Node is missing — the
# cleanup above removed it — so apt keeps Node patched, and a re-run moves up a
# major as soon as nodejs.org lists one. An installed newer major is kept.
if [[ "$SKIP_NODE" != "1" ]]; then
  if [[ "$NODE_MAJOR" != lts && "$NODE_MAJOR" != current && ! "$NODE_MAJOR" =~ ^[0-9]+$ ]]; then
    warn "NODE_MAJOR='${NODE_MAJOR}' is not lts, current or a major number — using lts"
    NODE_MAJOR=lts
  fi
  node_major="$NODE_MAJOR"
  [[ "$node_major" =~ ^[0-9]+$ ]] || node_major="$(curl -fsSL --max-time 30 https://nodejs.org/dist/index.json 2>/dev/null \
    | jq -r --arg ch "$NODE_MAJOR" \
        'map(select($ch == "current" or .lts))[0].version // empty | ltrimstr("v") | split(".")[0]' 2>/dev/null)"
  # dpkg, not `node --version`: an nvm or mise node on PATH is not ours.
  node_have=0
  pkg_installed nodejs && node_have="$(dpkg-query -W -f='${Version}' nodejs | cut -d. -f1)"
  [[ "$node_have" =~ ^[0-9]+$ ]] || node_have=0
  if [[ -z "$node_major" ]]; then
    warn "could not read the Node release index from nodejs.org"
    node_major="$node_have"            # still put the installed major's source back
  fi
  (( node_have > node_major )) && node_major="$node_have"

  if (( node_major == 0 )); then
    note_fail "nodejs"
  elif ! curl -fsI --max-time 20 \
         "https://deb.nodesource.com/node_${node_major}.x/dists/nodistro/InRelease" >/dev/null 2>&1; then
    warn "NodeSource has no node_${node_major}.x repo (yet)"; note_fail "nodejs"
  elif ! fetch_keys /etc/apt/keyrings/nodesource.asc \
         https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key; then
    warn "could not fetch the NodeSource key"; note_fail "nodejs"
  else
    log "Node.js ${node_major}.x from NodeSource (NODE_MAJOR=${NODE_MAJOR})"
    add_repo /etc/apt/sources.list.d/nodesource.sources \
      "https://deb.nodesource.com/node_${node_major}.x" nodistro main \
      /etc/apt/keyrings/nodesource.asc || true
    apt-get update -qq 2>&1 | grep -E '^E:' | sed 's/^/    /'
    # Ubuntu's Node packages, if an older run installed them, go in the same
    # transaction: NodeSource's nodejs conflicts with npm, but shares files
    # with libnode-dev (/usr/include/node) and node-corepack (/usr/bin/corepack)
    # without saying so, and dpkg aborts mid-unpack on those.
    node_drop=()
    for p in npm libnode-dev node-corepack; do
      pkg_installed "$p" && node_drop+=("${p}-")
    done
    soft "nodejs ${node_major}.x" DEBIAN_FRONTEND=noninteractive \
      apt-get install -y -qq nodejs "${node_drop[@]}" \
      && sub "node $(/usr/bin/node --version 2>/dev/null)"
  fi
fi

# =================================================================== .NET ===
# Ubuntu ships .NET itself now (26.04 -> 10.0, 24.04 -> 8.0), and that is the
# path of least resistance: no extra apt source to conflict with, and security
# updates arrive with the distro. DOTNET_MAJOR pins one; empty means "newest the
# distro offers". If the distro has none, dev-bootstrap-user.sh puts a private
# copy in each user's ~/.dotnet with Microsoft's installer.
if [[ "$SKIP_DOTNET" != "1" ]]; then
  cur_dotnet="$(dotnet --list-sdks 2>/dev/null | awk '{print $1}' | cut -d. -f1 | sort -rn | head -1)"
  [[ "$cur_dotnet" =~ ^[0-9]+$ ]] || cur_dotnet=0
  if (( cur_dotnet > 0 )); then
    log ".NET SDK ${cur_dotnet}.x already present"
  else
    dn_pkg=""
    if [[ -n "$DOTNET_MAJOR" ]]; then
      apt_installable "dotnet-sdk-${DOTNET_MAJOR}.0" && dn_pkg="dotnet-sdk-${DOTNET_MAJOR}.0"
      [[ -z "$dn_pkg" ]] && warn "Ubuntu ${OS_VER} has no dotnet-sdk-${DOTNET_MAJOR}.0 — taking what it has"
    fi
    if [[ -z "$dn_pkg" ]]; then
      for dn_m in 10 9 8; do
        if apt_installable "dotnet-sdk-${dn_m}.0"; then dn_pkg="dotnet-sdk-${dn_m}.0"; break; fi
      done
    fi
    if [[ -n "$dn_pkg" ]]; then
      log "Installing ${dn_pkg} from Ubuntu ${OS_VER}"
      soft "$dn_pkg" DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$dn_pkg"
    else
      log "Ubuntu ${OS_VER} carries no .NET SDK — dev-bootstrap-user.sh installs one per user (~/.dotnet)"
    fi
  fi
fi

# ============================================================ extra tools ===
# Tools that make a headless box pleasant, installed the same way the base
# packages are: from apt when this release carries them (they are in BASE_PKGS
# for that reason), and otherwise from the project's latest GitHub release. A
# .deb asset is preferred and goes through apt, so it is tracked and brings its
# man page; anything else is unpacked and the binary put in /usr/local/bin.
#
# Already-present tools are left alone — there is no upgrade path for a binary
# that did not come from apt, except DEV_EXTRAS_UPGRADE=1, which re-fetches all
# of them.
case "$ARCH" in
  amd64) ARCH_RUST=x86_64;  ARCH_CROC=64bit ;;
  arm64) ARCH_RUST=aarch64; ARCH_CROC=ARM64 ;;
  *)     ARCH_RUST="$ARCH"; ARCH_CROC="$ARCH" ;;
esac
ARCH_RE="(${ARCH}|${ARCH_RUST})"     # projects name the arch either way

# gh_asset_url <repo> <regex> — download URL of the first matching asset of the
# latest release. An authenticated gh dodges the 60/hour anonymous API limit.
gh_asset_url() {
  local repo="$1" re="$2" json=""
  if have gh && gh auth token >/dev/null 2>&1; then
    json="$(gh api "repos/${repo}/releases/latest" 2>/dev/null)"
  fi
  [[ -n "$json" ]] || json="$(curl -fsSL --max-time 30 -H 'Accept: application/vnd.github+json' \
                         "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)"
  [[ -n "$json" ]] || return 1
  jq -r '.assets[]?.browser_download_url' <<<"$json" 2>/dev/null | grep -E "$re" | head -1 | grep .
}

# gh_bin <repo> <asset-regex> <binary> [binary...]
gh_bin() {
  local repo="$1" re="$2"; shift 2
  local main="$1" url tmpd file rc=0 b found owner copy cv av
  # Packaged in /usr/bin by a repo apt follows (this release carries it, or
  # the box was upgraded to one that does): apt keeps it current. A copy of
  # ours in /usr/local/bin that is no newer only hides it, so it goes. A newer
  # copy stays: going back a version can break data the newer one already
  # migrated (atuin's history.db does exactly that).
  if owner="$(dpkg-query -S "/usr/bin/$main" 2>/dev/null)" \
     && [[ -n "$(apt-cache madison "${owner%%:*}" 2>/dev/null)" ]]; then
    owner="${owner%%:*}"; copy="$BIN/$main"
    if [[ -f "$copy" && ! -L "$copy" ]]; then
      cv="$("$copy" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
      av="$(dpkg-query -W -f='${Version}' "$owner" 2>/dev/null)"
      if [[ -n "$cv" ]] && dpkg --compare-versions "${av#*:}" ge "$cv"; then
        for b in "$@"; do
          [[ -f "$BIN/$b" && ! -L "$BIN/$b" ]] || continue
          rm -f "$BIN/$b"
          sub "removed $BIN/$b — ${owner} ${av} from apt is at least as new"
        done
      fi
    fi
    if [[ ! -f "$copy" || -L "$copy" ]]; then
      sub "$(printf '%-11s' "$main") from apt (${owner})"; return 0
    fi
  fi
  if [[ "$DEV_EXTRAS_UPGRADE" != "1" ]] && have "$main"; then
    sub "$(printf '%-11s' "$main") already present"; return 0
  fi
  if ! url="$(gh_asset_url "$repo" "$re")"; then
    warn "${main}: no release asset for ${ARCH} in ${repo} (or the GitHub API is rate-limited)"
    note_fail "$main"; return 1
  fi
  tmpd="$(mktemp -d)"; file="${tmpd}/${url##*/}"
  if ! curl -fsSL --max-time 300 -o "$file" "$url"; then
    warn "${main}: download failed — ${url}"; note_fail "$main"; rm -rf "$tmpd"; return 1
  fi
  case "$file" in
    *.deb)           DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$file" >/dev/null 2>&1 || rc=1 ;;
    *.tar.gz|*.tgz)  tar xzf "$file" -C "$tmpd" 2>/dev/null || rc=1 ;;
    *.tar.xz)        tar xJf "$file" -C "$tmpd" 2>/dev/null || rc=1 ;;
    *.tar.bz2)       tar xjf "$file" -C "$tmpd" 2>/dev/null || rc=1 ;;
    *.zip)           unzip -qo "$file" -d "$tmpd" 2>/dev/null || rc=1 ;;
    *)               mv "$file" "${tmpd}/${main}" ;;            # a bare binary
  esac
  if (( rc == 0 )) && [[ "$file" != *.deb ]]; then
    for b in "$@"; do
      found="$(find "$tmpd" -type f -name "$b" | head -1)"
      if [[ -n "$found" ]]; then
        install -m 0755 "$found" "$BIN/$b"
      else
        warn "${main}: ${b} is not in the archive"; rc=1
      fi
    done
  fi
  rm -rf "$tmpd"
  if (( rc == 0 )); then
    sub "$(printf '%-11s' "$main") ${url##*/}"
  else
    warn "could not install ${main}"; note_fail "$main"
  fi
  return "$rc"
}

if [[ "$SKIP_EXTRAS" != "1" ]]; then
  log "Extra tools (apt where the release has them, GitHub releases otherwise)"
  gh_bin jesseduffield/lazygit     "lazygit_.*_linux_${ARCH_RE}\.tar\.gz$"                 lazygit
  gh_bin starship/starship         "starship-${ARCH_RUST}-unknown-linux-gnu\.tar\.gz$"      starship
  gh_bin atuinsh/atuin             "/atuin-${ARCH_RUST}-unknown-linux-gnu\.tar\.gz$"        atuin
  gh_bin watchexec/watchexec       "watchexec-.*-${ARCH_RUST}-unknown-linux-gnu\.deb$"      watchexec
  gh_bin Wilfred/difftastic        "difft-${ARCH_RUST}-unknown-linux-gnu\.tar\.gz$"         difft
  gh_bin sxyazi/yazi               "yazi-${ARCH_RUST}-unknown-linux-gnu\.deb$"              yazi ya
  gh_bin fujiapple852/trippy       "(trippy_.*_${ARCH}\.deb|trippy-.*-${ARCH_RUST}-unknown-linux-gnu\.tar\.gz)$" trip
  gh_bin o2sh/onefetch             "onefetch_${ARCH}\.deb$"                                 onefetch
  gh_bin PaulJuliusMartinez/jless  "jless-.*-${ARCH_RUST}-unknown-linux-gnu\.zip$"          jless
  gh_bin schollz/croc              "/croc_.*_Linux-${ARCH_CROC}\.tar\.gz$"                  croc
  gh_bin getsops/sops              "sops_.*_${ARCH}\.deb$"                                  sops
  gh_bin fastfetch-cli/fastfetch   "fastfetch-linux-${ARCH_RE}\.deb$"                       fastfetch
  gh_bin dalance/procs             "procs-.*-${ARCH_RUST}-linux\.zip$"                      procs


  # trippy opens raw sockets; the capability saves running it under sudo.
  if have trip; then
    setcap cap_net_raw+ep "$(command -v trip)" 2>/dev/null \
      || sub "trip: could not set cap_net_raw — run it with sudo"
  fi
fi

# ================================================================= docker ===
# Docker's own repo first: it carries buildx and the compose plugin as current
# releases, and tracks new Ubuntu versions within weeks. Until it does (or if
# the repo is unreachable) Ubuntu's own docker.io + docker-compose-v2 serve —
# same CLI, slightly older.
#
# An installed docker-ce gets Docker's source back on every run (the cleanup
# above removed it), so `apt upgrade` keeps it current. It is not upgraded
# here: that restarts dockerd, and every running container with it.
if [[ "$SKIP_DOCKER" != "1" ]]; then
  docker_ce=0; pkg_installed docker-ce && docker_ce=1
  if have docker && (( ! docker_ce )); then
    log "Docker already present ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
  else
    docker_done=0
    if (( docker_ce )); then
      log "Docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,) — keeping download.docker.com configured"
    else
      log "Installing Docker"
    fi
    if curl -fsI --max-time 20 \
         "https://download.docker.com/linux/ubuntu/dists/${OS_CODE}/InRelease" >/dev/null 2>&1 \
       && fetch_keys /etc/apt/keyrings/docker.asc https://download.docker.com/linux/ubuntu/gpg; then
      if add_repo /etc/apt/sources.list.d/docker.sources \
           "https://download.docker.com/linux/ubuntu" "$OS_CODE" stable \
           /etc/apt/keyrings/docker.asc; then
        apt-get update -qq 2>&1 | grep -E '^E:' | sed 's/^/    /'
      fi
      if (( docker_ce )); then
        docker_done=1                    # installed; the source was all it lacked
      elif apt_installable docker-ce; then
        sub "docker-ce $(apt_cand docker-ce) from download.docker.com (${OS_CODE})"
        soft "docker-ce" DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
          docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
          && docker_done=1
      else
        warn "the Docker repo offers no docker-ce for ${OS_CODE} — removing it again"
        rm -f /etc/apt/sources.list.d/docker.sources
        apt-get update -qq >/dev/null 2>&1 || true
      fi
    else
      sub "download.docker.com has no ${OS_CODE} suite yet"
    fi
    if (( ! docker_done && ! docker_ce )); then
      sub "installing Ubuntu's docker.io ($(apt_cand docker.io)) with compose v2 and buildx"
      soft "docker.io" DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker.io docker-compose-v2 docker-buildx || true
    fi
  fi

  if have docker; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    # The person who ran sudo; anyone else: usermod -aG docker <user>.
    dk_user="${SUDO_USER:-}"
    if [[ -n "$dk_user" && "$dk_user" != root ]] && getent group docker >/dev/null 2>&1 \
       && ! id -nG "$dk_user" | tr ' ' '\n' | grep -qx docker; then
      usermod -aG docker "$dk_user" \
        && warn "added ${dk_user} to the docker group — takes effect at the next login" \
        || warn "could not add ${dk_user} to the docker group"
    fi
    # dive inspects image layers; lazydocker is a TUI over containers/compose.
    gh_bin wagoodman/dive           "dive_.*_linux_${ARCH}\.deb$"                 dive
    gh_bin jesseduffield/lazydocker "lazydocker_.*_Linux_${ARCH_RE}\.tar\.gz$"    lazydocker
  fi
fi

# ================================================== microsoft sql tooling ===
# What the Microsoft repos actually carry is probed live below; as of this
# writing:
#   ubuntu/24.04/prod (noble)     -> msodbcsql18 + mssql-tools18, plus ~100
#                                    unrelated packages (powershell, moby, ...)
#   ubuntu/25.10/prod (questing)  -> msodbcsql18 + mssql-tools18 and nothing else
#   ubuntu/26.04/prod (resolute)  -> exists and signs, but carries only the
#                                    container/Azure packages — no SQL tooling
# So on 26.04 we install packages built for an older release. They run fine:
# both depend on nothing but libc6, libstdc++6, libkrb5-3, openssl and debconf.
#
# Three routes are tried in order, because the repo route has many moving parts
# (keys, suites, Signed-By conflicts, pinning) and any of them can already be
# broken on a machine that has met another Microsoft installer:
#   1. a Microsoft repo that is already configured here and already offers it
#   2. our own source for the newest suite that really carries the packages
#   3. the .deb files straight from the pool, checksum-verified and installed
#      with `apt-get install ./file.deb`, so apt still resolves dependencies
#      but nothing depends on repo metadata, signing keys or pinning
# If all three fail, go-sqlcmd (a static binary: sqlcmd, but no bcp, no driver).
MS_BIN=/opt/mssql-tools18/bin

# Both packages gate their *preinst* on a debconf answer, and a preinst that
# refuses aborts the whole apt transaction. ACCEPT_EULA in the environment is
# Microsoft's documented way in, and every install below sets it with `env`
# so it reaches the maintainer script. Seeding the answers as well covers the case where the config
# script never runs (a plain `dpkg -i`, or a package configured out of band).
ms_eula_preseed() {
  have debconf-set-selections || return 0
  printf '%s\n' \
    'msodbcsql18 msodbcsql/ACCEPT_EULA boolean true' \
    'msodbcsql18 msodbcsql/accept_eula boolean true' \
    'mssql-tools18 mssql-tools/accept_eula boolean true' \
    | debconf-set-selections 2>/dev/null
}

# ms_apt_install <target...> — targets are package names or local .deb paths.
# Only mssql-tools18 is ever named: msodbcsql18 comes along as its dependency
# when it is missing and is left alone when it is already installed. Asking for
# msodbcsql18 by name would make apt reinstall it, and its preinst aborts the
# transaction with "ODBC Driver 18 for SQL Server detected!" when the driver is
# already registered with odbcinst.
ms_apt_install() {
  env ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq "$@"
}

# ms_newest <packages-index> <package> -> "version<TAB>filename<TAB>sha256"
# The pool indexes keep every version ever published, in no useful order, so
# the winner is picked with dpkg's own version comparison rather than sort.
ms_newest() {
  local idx="$1" want="$2" best="" bestline="" v f s
  while IFS=$'\t' read -r v f s; do
    [[ -z "$v" || -z "$f" || -z "$s" ]] && continue
    if [[ -z "$best" ]] || dpkg --compare-versions "$v" gt "$best"; then
      best="$v"; bestline="${v}"$'\t'"${f}"$'\t'"${s}"
    fi
  done < <(awk -v want="$want" '
      function flush() {
        if (p == want && v != "" && f != "" && s != "") print v "\t" f "\t" s
        p=""; v=""; f=""; s=""
      }
      /^Package: /  { flush(); p=$2 }
      /^Version: /  { if (p==want) v=$2 }
      /^Filename: / { if (p==want) f=$2 }
      /^SHA256: /   { if (p==want) s=$2 }
      END           { flush() }
    ' "$idx")
  [[ -n "$bestline" ]] || return 1
  printf '%s\n' "$bestline"
}

# ms_pool_install <base-url> <packages-index>
ms_pool_install() {
  local base="$1" idx="$2" tmpd pkg line ver file sha rc=0
  tmpd="$(mktemp -d)" || return 1
  local debs=()
  for pkg in msodbcsql18 mssql-tools18; do
    # Skip the driver when it is already installed — see ms_apt_install.
    [[ "$pkg" == msodbcsql18 ]] && pkg_installed msodbcsql18 && continue
    if ! line="$(ms_newest "$idx" "$pkg")"; then
      warn "${pkg} is not in the pool index"; rc=1; break
    fi
    IFS=$'\t' read -r ver file sha <<<"$line"
    sub "downloading ${pkg} ${ver}"
    if ! curl -fsSL --max-time 300 -o "${tmpd}/${pkg}.deb" "${base}/${file}"; then
      warn "download failed: ${base}/${file}"; rc=1; break
    fi
    if ! printf '%s  %s\n' "$sha" "${tmpd}/${pkg}.deb" | sha256sum -c --status; then
      warn "checksum mismatch for ${pkg} ${ver} — refusing to install it"; rc=1; break
    fi
    debs+=("${tmpd}/${pkg}.deb")
  done
  if (( rc == 0 )) && (( ${#debs[@]} )); then
    ms_apt_install "${debs[@]}" || rc=1
  fi
  rm -rf "$tmpd"
  return "$rc"
}

if [[ "$SKIP_MSSQL" != "1" ]]; then
  # An installed copy still goes through the probe and route 2: the cleanup
  # above removed its source, and route 2 is what puts it back so apt keeps it
  # patched. Route 3 and go-sqlcmd are only for a missing sqlcmd.
  ms_done=0; ms_have=0
  if [[ -x "$MS_BIN/sqlcmd" ]]; then
    log "sqlcmd already installed — putting its apt source back"
    sub "$MS_BIN/sqlcmd  ($(dpkg-query -W -f='${Version}' mssql-tools18 2>/dev/null || echo 'not from a package'))"
    ms_have=1
  else
    log "Installing the Microsoft SQL tooling"
  fi
  ms_eula_preseed

  # ---- route 1: a Microsoft repo that is already configured here ----------
  # Not for an installed copy: apt offers that as its own candidate even with
  # no source behind it, which would pass for "reachable" here.
  if (( ! ms_have )) && apt_installable mssql-tools18; then
    sub "already reachable from a configured repo (candidate $(apt_cand mssql-tools18))"
    ms_apt_install mssql-tools18 && ms_done=1
    (( ms_done )) || warn "that repo could not deliver the package — trying the other routes"
  fi

  # ---- probe: which suite actually carries the packages? ------------------
  # Asked over plain HTTPS, so a broken apt configuration cannot produce a
  # false negative, and the index we get is reused by route 3.
  ms_base=""; ms_idx=""; ms_suite=""; ms_relver=""; ms_tried=" "
  if (( ! ms_done )); then
    ms_probe="$(mktemp)"
    for pair in "${OS_VER}:${OS_CODE}" "25.10:questing" "24.04:noble" "22.04:jammy"; do
      p_ver="${pair%%:*}"; p_suite="${pair##*:}"
      [[ -z "$p_ver" || -z "$p_suite" ]] && continue
      [[ "$ms_tried" == *" ${p_ver}/${p_suite} "* ]] && continue
      ms_tried+="${p_ver}/${p_suite} "
      printf '    %-16s ' "${p_ver}/${p_suite}"
      if ! curl -fsSL --max-time 60 -o "$ms_probe" \
           "https://packages.microsoft.com/ubuntu/${p_ver}/prod/dists/${p_suite}/main/binary-${ARCH}/Packages" 2>/dev/null; then
        echo "no package index"; continue
      fi
      ms_t="$(grep -c '^Package: mssql-tools18$' "$ms_probe")"
      ms_o="$(grep -c '^Package: msodbcsql18$'  "$ms_probe")"
      echo "mssql-tools18=${ms_t} msodbcsql18=${ms_o}"
      (( ms_t > 0 && ms_o > 0 )) || continue
      ms_relver="$p_ver"; ms_suite="$p_suite"
      ms_base="https://packages.microsoft.com/ubuntu/${p_ver}/prod"
      ms_idx="$(mktemp)"; cp "$ms_probe" "$ms_idx"
      break
    done
    rm -f "$ms_probe"
    [[ -n "$ms_base" && "$ms_relver" != "$OS_VER" ]] && \
      warn "Microsoft has no Ubuntu ${OS_VER} build — using the ${ms_relver} (${ms_suite}) packages"
  fi

  # ---- route 2: our own source for that suite -----------------------------
  if (( ! ms_done )) && [[ -n "$ms_base" ]]; then
    if fetch_keys /etc/apt/keyrings/microsoft.asc \
         https://packages.microsoft.com/keys/microsoft.asc \
         https://packages.microsoft.com/keys/microsoft-2025.asc; then
      if add_repo /etc/apt/sources.list.d/mssql-release.sources \
           "$ms_base" "$ms_suite" main /etc/apt/keyrings/microsoft.asc; then
        # A repo for another release must not become a general-purpose source:
        # noble/prod alone carries ~100 packages (powershell, moby, kubectl)
        # built for the wrong Ubuntu. Pin the whole suite out of reach and let
        # only the two SQL packages back through.
        if [[ "$ms_suite" != "$OS_CODE" ]]; then
          tee /etc/apt/preferences.d/mssql-release.pref >/dev/null <<EOF
${MANAGED}
Package: *
Pin: release n=${ms_suite}
Pin-Priority: 1

Package: msodbcsql18 mssql-tools18
Pin: release n=${ms_suite}
Pin-Priority: 500
EOF
          sub "pinned: only msodbcsql18/mssql-tools18 may come from ${ms_suite}"
        fi
        apt-get update -qq 2>&1 | grep -E '^E:' | sed 's/^/    /'
        if apt_installable mssql-tools18; then
          sub "candidate $(apt_cand mssql-tools18) from ${ms_relver}/${ms_suite}"
          ms_apt_install mssql-tools18 && ms_done=1
        else
          warn "the ${ms_suite} source produced no installable candidate — removing it again"
          rm -f /etc/apt/sources.list.d/mssql-release.sources \
                     /etc/apt/preferences.d/mssql-release.pref
          apt-get update -qq >/dev/null 2>&1 || true
        fi
      fi
    else
      warn "could not download the Microsoft signing keys"
    fi
  fi

  # ---- route 3: the .deb files straight from the pool ---------------------
  if (( ! ms_done && ! ms_have )) && [[ -n "$ms_base" ]]; then
    warn "repo route did not work — installing the .deb files from the pool"
    ms_pool_install "$ms_base" "$ms_idx" && ms_done=1
  fi
  [[ -n "$ms_idx" ]] && rm -f "$ms_idx"

  # ---- last resort: go-sqlcmd --------------------------------------------
  if (( ! ms_done && ! ms_have )); then
    [[ -n "$ms_base" ]] || warn "no Microsoft repo carries mssql-tools18 for ${ARCH}"
    warn "falling back to go-sqlcmd (static binary: sqlcmd only — no bcp, no ODBC driver)"
    if curl -fsSL --max-time 300 \
         "https://github.com/microsoft/go-sqlcmd/releases/latest/download/sqlcmd-linux-${ARCH}.tar.bz2" \
         | tar xj -C "$BIN" sqlcmd 2>/dev/null; then
      sub "installed $BIN/sqlcmd"
      note_fail "mssql-tools18 (go-sqlcmd installed instead)"
    else
      warn "that failed too — this machine has no sqlcmd"
      note_fail "mssql-tools18"
    fi
  fi


  # /opt/mssql-tools18/bin is on no one's PATH by default; rc.sh appends it when
  # the directory exists, so a login shell picks it up from the next start.
  # Checked by what it prints rather than by its exit status: `sqlcmd -?` is a
  # usage screen, and usage screens are not required to exit 0.
  if [[ -x "$MS_BIN/sqlcmd" ]]; then
    ms_v="$("$MS_BIN/sqlcmd" -? 2>&1 | awk '/Version/{print $2; exit}')"
    if [[ -n "$ms_v" ]]; then
      sub "sqlcmd ${ms_v} — ${MS_BIN}/sqlcmd (on PATH from the next login shell)"
    else
      warn "sqlcmd is installed at ${MS_BIN}/sqlcmd but did not report a version"
    fi
  fi
fi


# ============================================================== postgres ====
# PGDG carries a new Ubuntu release only some months after launch, so probe
# before trusting it. Ubuntu 26.04's own client is current anyway.
#
# The PGDG source is rewritten on every run, not only when psql is missing —
# the cleanup above removed it — so apt keeps the client and libpq patched.
# PG_MAJOR empty takes the newest client on offer: pg_dump refuses to dump a
# server newer than itself, so the newest client works against every server.
if [[ "$SKIP_POSTGRES" != "1" ]]; then
  pg_suite="${OS_CODE}-pgdg"
  if curl -fsI --max-time 20 \
       "https://apt.postgresql.org/pub/repos/apt/dists/${pg_suite}/InRelease" >/dev/null 2>&1 \
     && fetch_keys /etc/apt/keyrings/pgdg.asc \
          https://www.postgresql.org/media/keys/ACCC4CF8.asc; then
    if add_repo /etc/apt/sources.list.d/pgdg.sources \
         "https://apt.postgresql.org/pub/repos/apt" "$pg_suite" main \
         /etc/apt/keyrings/pgdg.asc; then
      apt-get update -qq 2>&1 | grep -E '^E:' | sed 's/^/    /'
    fi
    pg_pkg="postgresql-client-${PG_MAJOR}"
    [[ -n "$PG_MAJOR" ]] || pg_pkg="$(apt-cache pkgnames postgresql-client- 2>/dev/null \
                                      | grep -E '^postgresql-client-[0-9]+$' | sort -V | tail -1)"
    if [[ -n "$pg_pkg" ]] && apt_installable "$pg_pkg"; then
      log "PostgreSQL client: ${pg_pkg} (PGDG ${pg_suite})"
      soft "$pg_pkg" DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq "$pg_pkg" libpq-dev || true
      # Older clients are superseded, not deleted: marked automatic, they go with
      # the next `apt autoremove` — unless a local server of that major needs them.
      for p in $(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'postgresql-client-[0-9]*' 2>/dev/null \
                 | awk '$1 == "installed" {print $2}'); do
        [[ "$p" == "$pg_pkg" ]] || apt-mark auto "$p" >/dev/null 2>&1
      done
    else
      warn "PGDG has no ${pg_pkg:-postgresql-client} here — using Ubuntu's"
      soft "postgresql-client" DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq postgresql-client libpq-dev || true
    fi
  elif have psql; then
    log "psql $(psql --version | awk '{print $3}') already present (no PGDG repo for ${OS_CODE})"
  else
    log "No PGDG repo for ${OS_CODE} — using Ubuntu's postgresql-client ($(apt_cand postgresql-client))"
    soft "postgresql-client" DEBIAN_FRONTEND=noninteractive \
      apt-get install -y -qq postgresql-client libpq-dev || true
  fi
fi

# ======================================================== system tuning =====
if [[ "$SKIP_SYSCTL" != "1" ]]; then
  log "Raising inotify limits (file watchers + agentic tooling)"
  printf '%s\n' \
    '# managed-by: dev-bootstrap' \
    'fs.inotify.max_user_watches=524288' \
    'fs.inotify.max_user_instances=1024' \
    'fs.inotify.max_queued_events=32768' \
    | tee /etc/sysctl.d/60-inotify.conf >/dev/null
  sysctl --system >/dev/null 2>&1 || true

  # Ubuntu's default soft limit is 1024 open files. tsc --watch, vite, pytest-xdist
  # and several language servers at once blow through that and fail with EMFILE.
  log "Raising the open-file limit (default soft limit is 1024)"
  printf '%s\n' \
    '# managed-by: dev-bootstrap' \
    '*  soft  nofile  65535' \
    '*  hard  nofile  1048576' \
    | tee /etc/security/limits.d/90-dev-nofile.conf >/dev/null
  sub "currently: soft=$(ulimit -Sn) hard=$(ulimit -Hn) (new value applies at next login)"

fi

# ============================================================== hardening ===
# The three things a box with an SSH port deserves, kept deliberately modest:
#   unattended-upgrades   security updates install themselves
#   fail2ban              bans an IP after repeated failed SSH logins
#   ufw                   deny incoming by default; SSH (and mosh) open from
#                         everywhere, everything open from DEV_UFW_TRUST
# DEV_UFW_TRUST is empty by default, so any other port (an app, a dev server)
# must be opened on purpose: `sudo ufw allow from <proxy-ip> to any port <p>`.
# Docker publishes ports through its own iptables chain and bypasses ufw
# entirely — bind containers to 127.0.0.1 unless they must be reachable.
if [[ "$SKIP_HARDENING" != "1" ]]; then
  log "Hardening: unattended-upgrades, fail2ban, ufw"
  hard_pkgs=()
  for p in unattended-upgrades fail2ban ufw; do
    pkg_installed "$p" || { apt_has "$p" && hard_pkgs+=("$p"); }
  done
  (( ${#hard_pkgs[@]} )) && soft "hardening packages" DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq --no-install-recommends "${hard_pkgs[@]}"

  # ---- unattended-upgrades -------------------------------------------------
  if pkg_installed unattended-upgrades; then
    printf '%s\n' \
      "// ${MANAGED#\# }" \
      'APT::Periodic::Update-Package-Lists "1";' \
      'APT::Periodic::Unattended-Upgrade "1";' \
      'APT::Periodic::AutocleanInterval "7";' \
      | tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    sub "unattended-upgrades: security updates daily (Ubuntu's default origins)"
  fi

  # ---- fail2ban ------------------------------------------------------------
  # backend=systemd: Ubuntu ships no rsyslog any more, so /var/log/auth.log is
  # often missing and the stock jail then refuses to start.
  if pkg_installed fail2ban; then
    tee /etc/fail2ban/jail.d/dev-bootstrap-sshd.local >/dev/null <<EOF
${MANAGED}
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${DEV_UFW_TRUST}
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    if systemctl restart fail2ban >/dev/null 2>&1; then
      sub "fail2ban: sshd jail on, 5 failures in 10 min = 1 h ban (trusted ranges ignored)"
    else
      warn "fail2ban did not start — journalctl -u fail2ban"; note_fail "fail2ban"
    fi
  fi

  # ---- ufw -----------------------------------------------------------------
  # SSH is allowed BEFORE the firewall is enabled, on whatever port sshd is
  # really listening on, and enabling is skipped if that rule could not be
  # added. `ufw allow` is idempotent, so a re-run only reports existing rules.
  if have ufw; then
    ssh_ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u | tr '\n' ' ')"
    [[ -z "$ssh_ports" ]] && ssh_ports="22 "
    ufw_ok=1
    for p in $ssh_ports; do
      ufw allow "${p}/tcp" comment 'ssh' >/dev/null 2>&1 || ufw_ok=0
    done
    have mosh && ufw allow 60000:61000/udp comment 'mosh' >/dev/null 2>&1
    for net in $DEV_UFW_TRUST; do
      ufw allow from "$net" comment 'trusted (dev-bootstrap)' >/dev/null 2>&1 \
        || warn "ufw: could not add the trusted range ${net}"
    done
    # Drop trusted ranges an earlier run added that DEV_UFW_TRUST no longer
    # lists (older versions trusted all of RFC 1918 by default).
    for net in $(ufw show added 2>/dev/null \
                 | awk '/^ufw allow from .*trusted \(dev-bootstrap\)/{print $4}' | sort -u); do
      [[ " $DEV_UFW_TRUST " == *" $net "* ]] && continue
      if ufw delete allow from "$net" >/dev/null 2>&1; then
        sub "ufw: removed the old trusted range ${net}"
      else
        warn "ufw: could not remove the old trusted range ${net}"
      fi
    done
    if (( ufw_ok )); then
      if ufw status 2>/dev/null | grep -q '^Status: active'; then
        sub "ufw: already active — rules refreshed (ssh ${ssh_ports}tcp, trusted: ${DEV_UFW_TRUST:-none})"
      else
        ufw default deny incoming  >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        if ufw --force enable >/dev/null 2>&1; then
          sub "ufw: enabled — incoming denied except ssh (${ssh_ports}tcp), trusted: ${DEV_UFW_TRUST:-none}"
        else
          warn "ufw could not be enabled"; note_fail "ufw"
        fi
      fi
    else
      warn "ufw: the ssh rule could not be added — NOT enabling the firewall"; note_fail "ufw"
    fi
  fi
fi

# ============================================================== leftovers ===
# What nothing uses any more goes, so every run lands on the same clean box:
#   * packages apt pulled in only for something since removed (Ubuntu's npm
#     and its node-* libraries, old kernels, a superseded psql client):
#     `apt autoremove --purge`
#   * what removed kernels and Node packages left behind (dpkg state "rc")
#
# Kept whatever apt thinks of them, because purging them destroys data: a
# database server (postgresql-NN deletes its clusters on purge — the debconf
# default is yes) and Docker (purging docker.io wipes /var/lib/docker, volumes
# included). The bootloader stays too: purging grub-pc deletes
# /etc/default/grub, which grub-efi reads as well. Other "rc" leftovers were
# removed by someone, by hand, and may hold data of their own — listed, not
# purged. SKIP_AUTOREMOVE=1 lists the apt part and changes nothing.
LEFTOVER_KEEP_RE='^(postgresql-[0-9]+|mysql-server.*|mariadb-server.*|mssql-server|redis-server|mongodb.*|docker.*|containerd.*|grub.*|shim.*)$'
LEFTOVER_PURGE_RE='^(linux-.*|npm|libnode.*|node-.*|libjs-.*|javascript-common)$'
apt_orphans() { apt-get -s autoremove 2>/dev/null | awk '/^Remv /{sub(/:.*/, "", $2); print $2}'; }
list12() {                     # list12 <lines> -> "N: a b c ..." on one line
  local n; n="$(wc -l <<<"$1")"
  printf '%s: %s%s' "$n" "$(head -12 <<<"$1" | tr '\n' ' ')" "$( (( n > 12 )) && echo '...')"
}

log "Removing what nothing uses any more"
left_n=0

orphans="$(apt_orphans)"
orph_keep="$(grep -E "$LEFTOVER_KEEP_RE" <<<"$orphans")"
if [[ -n "$orph_keep" ]]; then
  warn "kept, though nothing needs them: $(tr '\n' ' ' <<<"$orph_keep")— data or boot"
  sub "if you mean it: apt remove <name> (remove, not purge — purge deletes their data)"
  # Manual from here on: autoremove leaves them alone, now and on later runs.
  mapfile -t keep_pkgs <<<"$orph_keep"
  [[ "$SKIP_AUTOREMOVE" == "1" ]] || apt-mark manual "${keep_pkgs[@]}" >/dev/null 2>&1
  orphans="$(apt_orphans)"
  left_n=$((left_n+1))
fi
orph_show="$(grep -vE "$LEFTOVER_KEEP_RE" <<<"$orphans")"
if [[ -n "$orph_show" ]]; then
  sub "unused packages $(list12 "$orph_show")"
  if [[ "$SKIP_AUTOREMOVE" == "1" ]]; then
    # No command to copy: by hand, autoremove --purge would take the kept ones too.
    sub "SKIP_AUTOREMOVE=1 — left in place"
  elif grep -qE "$LEFTOVER_KEEP_RE" <<<"$orphans"; then
    # apt-mark did not take: autoremove would purge what we just promised to keep.
    warn "could not protect the packages above — not running autoremove"; note_fail "autoremove"
  else
    soft "apt autoremove" DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -qq \
      && sub "removed and purged"
  fi
  left_n=$((left_n+1))
fi

residue="$(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 2>/dev/null | awk '$1 == "rc" {print $2}')"
res_purge="$(grep -E "$LEFTOVER_PURGE_RE" <<<"$residue")"
res_held="$(grep -vE "$LEFTOVER_PURGE_RE" <<<"$residue")"
if [[ -n "$res_purge" ]]; then
  sub "config left by removed kernels / Node packages $(list12 "$res_purge")"
  if [[ "$SKIP_AUTOREMOVE" == "1" ]]; then
    sub "SKIP_AUTOREMOVE=1 — left in place"
  else
    mapfile -t purge_pkgs <<<"$res_purge"
    soft "purge leftover config" dpkg --purge "${purge_pkgs[@]}" >/dev/null 2>&1 && sub "purged"
  fi
  left_n=$((left_n+1))
fi
if [[ -n "$res_held" ]]; then
  sub "removed earlier, config still on disk $(list12 "$res_held")"
  sub "not purged for you (purging can delete data): dpkg --purge <name> once you know what it keeps"
  left_n=$((left_n+1))
fi
(( left_n == 0 )) && sub "nothing left over"

# =============================================================== verify =====
log "Final apt health check"
apt_err="$(apt-get update 2>&1 | grep -E '^(E|W):')"
if [[ -n "$apt_err" ]]; then
  printf '%s\n' "$apt_err" | sed 's/^/    /'
  warn "apt reported the above. Re-run with --clean-only to strip our sources."
  note_fail "apt update"
else
  sub "apt update is clean"
fi


echo
log "Installed"
ver() { printf '    %-16s %s\n' "$1" "${2:--}"; }
ver git      "$(git --version 2>/dev/null | awk '{print $3}')"
ver tmux     "$(tmux -V 2>/dev/null | awk '{print $2}')"
ver node     "$(node --version 2>/dev/null)"
ver npm      "$(npm --version 2>/dev/null)"
ver python3  "$(python3 --version 2>/dev/null | awk '{print $2}')"
ver dotnet   "$(dotnet --list-sdks 2>/dev/null | awk '{print $1}' | tail -1)"
ver psql     "$(psql --version 2>/dev/null | awk '{print $3}')"
# sqlcmd is either the mssql-tools18 build or the go-sqlcmd fallback binary.
sqlcmd_ver="$(/opt/mssql-tools18/bin/sqlcmd -? 2>&1 | awk '/Version/{print $2; exit}')"
[[ -z "$sqlcmd_ver" && -x "$BIN/sqlcmd" ]] && \
  sqlcmd_ver="$("$BIN/sqlcmd" --version 2>/dev/null | awk '{print $NF; exit}') (go-sqlcmd)"
ver sqlcmd   "$sqlcmd_ver"
ver nano     "$(nano --version 2>/dev/null | head -1 | awk '{print $NF}')"
ver micro    "$(micro -version 2>/dev/null | awk -F': ' '/Version/{print $2}')"
ver eza      "$(eza --version 2>/dev/null | awk '/^v/{print $1; exit}')"
ver delta    "$(delta --version 2>/dev/null | awk '{print $2}')"
ver rg       "$(rg --version 2>/dev/null | awk 'NR==1{print $2}')"
ver fzf      "$(fzf --version 2>/dev/null | awk '{print $1}')"
ver gh       "$(gh --version 2>/dev/null | awk 'NR==1{print $3}')"
ver nvim     "$(nvim --version 2>/dev/null | awk 'NR==1{print $2}')"
ver docker   "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
ver lazygit  "$(lazygit --version 2>/dev/null | grep -oE 'version=[^,]+' | cut -d= -f2)"
ver starship "$(starship --version 2>/dev/null | awk 'NR==1{print $2}')"
ver atuin    "$(atuin --version 2>/dev/null | awk '{print $2}')"
ver watchexec "$(watchexec --version 2>/dev/null | awk '{print $2}')"
ver yazi     "$(yazi --version 2>/dev/null | awk '{print $2}')"
ver ufw      "$(ufw status 2>/dev/null | awk '/^Status/{print tolower($2)}')"

echo
if (( ${#FAILED_STEPS[@]} )); then
  warn "Did not complete: ${FAILED_STEPS[*]}"
  warn "Everything else is configured. Re-running retries only these."
  echo
fi
log "Next"
sub "each developer, as themselves (no sudo):  bash dev-bootstrap-user.sh"
sub "usermod -aG docker <user>                 # docker without sudo for others"
sub "bash $0 --clean-only                      # remove this script's apt sources"
