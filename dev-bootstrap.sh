#!/usr/bin/env bash
# HELP>
# dev-bootstrap.sh (v5) — Ubuntu developer machine bootstrap
#
# Supports Ubuntu 24.04 LTS (noble) and 26.04 LTS (resolute) from one file.
# Everything release-specific is detected at runtime; there is nothing to edit
# per machine.
#
# Idempotent AND self-cleaning: every re-run first removes the apt sources and
# keyrings that earlier versions of this script created, then re-derives them
# for the release it is actually running on. It never touches sources it did
# not create.
#
# Run as your normal user (NOT root, NOT with sudo).
#
#   bash dev-bootstrap.sh                  # everything
#   bash dev-bootstrap.sh --clean-only     # only remove our apt artifacts
#   bash dev-bootstrap.sh --help
#
#   SKIP_MSSQL=1 bash dev-bootstrap.sh     # skip a section
#   DEV_ROOT=/srv/dev DEV_EDITOR=micro bash dev-bootstrap.sh
#
# Config files (~/.tmux.conf, ~/.inputrc, ~/.nanorc, ~/.psqlrc, the micro and
# Claude Code files) are written WHOLE — they belong to this script. What was
# there before the first run is kept once, forever, as <file>.pre-bootstrap; a
# symlink in their place is removed rather than written through; and settings
# from an earlier setup that would fight this one are cleared out first:
#
#   * dev-bootstrap blocks left in shell startup files by older runs
#   * a hand-rolled tmux autostart, which would stop this config from loading
#     at all (commented out, with the file backed up)
#   * options and key bindings still live in a RUNNING tmux server: sourcing a
#     config never unsets anything, so the server is put back to stock first
#
#   SKIP_LEGACY_CLEAN=1 bash dev-bootstrap.sh   # leave all of the above alone
#   DEV_TMUX_RESET=0    bash dev-bootstrap.sh   # never touch a running server
#
# The global git identity (user.name / user.email) is asked for interactively
# near the start of the run. To answer it up front instead:
#
#   GIT_USER_NAME='Your Name' GIT_USER_EMAIL=you@example.com bash dev-bootstrap.sh
#   SKIP_GIT_IDENTITY=1 bash dev-bootstrap.sh    # never ask, leave git alone
#
# It also asks which folder a login should start in: the folder the tmux
# session opens in, and the one a login shell cds to when tmux is off. The
# answer is remembered, so every re-run after the first is just Enter.
#
#   DEV_START_DIR=/srv/dev/app bash dev-bootstrap.sh   # answer up front
#   SKIP_START_DIR=1 bash dev-bootstrap.sh             # never ask
#
# Deliberately NOT using `set -e`: a single failing repo must never leave the
# machine half-configured. Failures are collected and reported at the end.
#
# <HELP
set -uo pipefail

# ---------------------------------------------------------------- settings --
DEV_ROOT="${DEV_ROOT:-/srv/dev}"
DEV_GROUP="${DEV_GROUP:-devgroup}"
NODE_MAJOR="${NODE_MAJOR:-22}"          # minimum acceptable Node major
DOTNET_MAJOR="${DOTNET_MAJOR:-}"        # empty = newest SDK the distro offers
DOTNET_TOOLS="${DOTNET_TOOLS:-csharp-ls dotnet-ef}"
PG_MAJOR="${PG_MAJOR:-18}"              # preferred PGDG client major
DEV_EDITOR="${DEV_EDITOR:-nano}"        # nano | micro | vim
DEV_TMUX_AUTOSTART="${DEV_TMUX_AUTOSTART:-1}"
DEV_START_DIR="${DEV_START_DIR:-}"      # empty = ask; where a login lands
CLAUDE_PLUGINS="${CLAUDE_PLUGINS:-pyright-lsp typescript-lsp csharp-lsp}"
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
SKIP_SYSTEM="${SKIP_SYSTEM:-0}"
SKIP_NODE="${SKIP_NODE:-0}"
SKIP_PYTHON="${SKIP_PYTHON:-0}"
SKIP_DOTNET="${SKIP_DOTNET:-0}"
SKIP_MSSQL="${SKIP_MSSQL:-0}"
SKIP_POSTGRES="${SKIP_POSTGRES:-0}"
SKIP_CLAUDE="${SKIP_CLAUDE:-0}"
SKIP_CLAUDE_CONF="${SKIP_CLAUDE_CONF:-0}"
SKIP_TMUX_CONF="${SKIP_TMUX_CONF:-0}"
SKIP_SHELL_CONF="${SKIP_SHELL_CONF:-0}"
SKIP_EDITOR_CONF="${SKIP_EDITOR_CONF:-0}"
SKIP_SYSCTL="${SKIP_SYSCTL:-0}"
SKIP_GIT_CONF="${SKIP_GIT_CONF:-0}"
SKIP_GIT_IDENTITY="${SKIP_GIT_IDENTITY:-0}"
SKIP_INPUTRC="${SKIP_INPUTRC:-0}"
SKIP_LEGACY_CLEAN="${SKIP_LEGACY_CLEAN:-0}"   # 1 = leave old config in place
SKIP_START_DIR="${SKIP_START_DIR:-0}"         # 1 = never ask for a start folder
DEV_TMUX_RESET="${DEV_TMUX_RESET:-1}"         # 0 = do not touch a running server
CLEAN_ONLY=0

CONF_DIR="$HOME/.config/dev-bootstrap"
MARKER="# >>> dev-bootstrap >>>"
MARKER_END="# <<< dev-bootstrap <<<"
MANAGED="# managed-by: dev-bootstrap -- safe to delete, regenerated on re-run"
BACKUP_SUFFIX=".pre-bootstrap"
START_DIR_STATE="$CONF_DIR/start-dir"   # remembers the answer between runs

for arg in "$@"; do
  case "$arg" in
    --clean-only) CLEAN_ONLY=1 ;;
    # "$0" is "bash" when the script is piped in from curl, and there is no
    # file to read the help out of — point at the repo instead of failing.
    --help|-h) if [[ -r "$0" ]]; then
                 sed -n '/^# HELP>$/,/^# <HELP$/p' "$0" | sed '1d;$d; s/^# \{0,1\}//'
               else
                 echo "Reading the script from stdin — save it to a file for the help text:"
                 echo "  curl -fsSL <url> -o dev-bootstrap.sh && bash dev-bootstrap.sh --help"
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
hp() { printf '%s' "${1/#$HOME/\~}"; }          # print a path as ~/...

# ------------------------------------------------------- taking a file over --
# Every dotfile below is written WHOLE: the file belongs to this script, and a
# re-run has to land on exactly the same content no matter what was there
# first. Two things must survive that:
#   * the version you had before the very first run — kept once, forever, as
#     <file>.pre-bootstrap, and never overwritten by a later run
#   * a file that is not really a file: a symlink from a dotfile manager
#     (stow, chezmoi, oh-my-tmux) is written THROUGH by `cat >`, silently
#     rewriting whatever it points at somewhere else
ADOPTED=()                     # what was moved aside, printed in the summary

# claim <path> — make <path> safe to overwrite. Non-zero means "do not write".
claim() {
  local f="$1" tgt
  if [[ -L "$f" ]]; then
    tgt="$(readlink "$f")"
    rm -f "$f"
    warn "$(hp "$f") was a symlink to $(hp "$tgt") — replaced with a real file"
    sub "$(hp "$tgt") itself is untouched; re-link it by hand if you want it back"
    ADOPTED+=("$(hp "$f") — symlink to $(hp "$tgt") removed")
    return 0
  fi
  [[ -e "$f" ]] || return 0
  if [[ -d "$f" ]]; then
    warn "$(hp "$f") is a directory, not a file — skipped"
    note_fail "$(hp "$f") is a directory"; return 1
  fi
  if lsattr -d "$f" 2>/dev/null | awk '{print $1}' | grep -q i; then
    warn "$(hp "$f") is immutable (chattr +i) — left alone"
    note_fail "$(hp "$f") is immutable"; return 1
  fi
  if [[ ! -w "$f" ]]; then
    warn "$(hp "$f") is not writable — left alone"
    note_fail "$(hp "$f") is not writable"; return 1
  fi
  # Only ever back up something we did not write ourselves, and only when no
  # backup exists yet — otherwise run two would replace your original with a
  # copy of our own generated file.
  if [[ ! -e "${f}${BACKUP_SUFFIX}" ]] && ! grep -qs "dev-bootstrap" "$f"; then
    cp -p "$f" "${f}${BACKUP_SUFFIX}"
    sub "kept your old $(basename "$f") as $(basename "$f")${BACKUP_SUFFIX}"
    ADOPTED+=("$(hp "$f") — backed up to $(basename "$f")${BACKUP_SUFFIX}")
  fi
  return 0
}

# strip_block <file> — remove every dev-bootstrap block, not just the first.
# sed restarts the range after each end marker, so duplicates left by older
# runs (or by a version of this script that hooked a different file) all go.
strip_block() {
  [[ -f "$1" ]] || return 0
  grep -qF "$MARKER" "$1" || return 0
  sed -i "/$(printf '%s' "$MARKER" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MARKER_END" | sed 's/[][\.*^$/]/\\&/g')/d" "$1"
}

# login_rc_path — the ONE file a login shell reads: bash takes the first of
# these that exists and never looks at the others.
login_rc_path() {
  local f
  for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

apt_has()  { apt-cache show "$1" >/dev/null 2>&1; }
apt_cand() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}'; }
apt_installable() { apt-cache policy "$1" 2>/dev/null | grep -qE 'Candidate: [0-9]'; }

# ============================================================== preflight ===
[[ $EUID -eq 0 ]] && die "Run as your normal user, not root. sudo is used where needed."
have sudo || die "sudo is required."
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

sudo -v || die "sudo authentication failed."
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

mkdir -p "$CONF_DIR" "$HOME/.local/bin"

# ------------------------------------------------------------ git identity --
# Asked here rather than down in the git section: the package installs in
# between take several minutes, and a prompt that only shows up after them is
# missed by anyone who walked away from the machine.
#
# Precedence: GIT_USER_NAME / GIT_USER_EMAIL from the environment win outright
# (and suppress the prompt entirely, so an unattended run never blocks), then
# whatever git already has globally — offered as the default you can accept
# with Enter — then what is typed here.
#
# Reading from /dev/tty rather than stdin keeps this working when the script is
# piped into bash (curl ... | bash). With no controlling terminal there is
# nothing to read from, so the prompt is skipped and the git section warns.
ask_tty() {                    # ask_tty <varname> <question> <default>
  local __name="$1" question="$2" default="$3" reply=""
  if [[ -n "$default" ]]; then
    printf '    %-14s [%s]: ' "$question" "$default" >/dev/tty
  else
    printf '    %-14s ' "$question:" >/dev/tty
  fi
  IFS= read -r reply </dev/tty || reply=""
  reply="${reply#"${reply%%[![:space:]]*}"}"    # trim leading whitespace
  reply="${reply%"${reply##*[![:space:]]}"}"    # trim trailing whitespace
  [[ -z "$reply" ]] && reply="$default"
  printf -v "$__name" '%s' "$reply"
}

GIT_IDENT_FROM_ENV=0
[[ -n "$GIT_USER_NAME" && -n "$GIT_USER_EMAIL" ]] && GIT_IDENT_FROM_ENV=1

if [[ "$CLEAN_ONLY" != "1" && "$SKIP_GIT_CONF" != "1" \
      && "$SKIP_GIT_IDENTITY" != "1" && "$GIT_IDENT_FROM_ENV" != "1" ]]; then
  # git may not be installed yet on a fresh box; an empty default is fine.
  if have git; then
    [[ -z "$GIT_USER_NAME"  ]] && GIT_USER_NAME="$(git config --global user.name  2>/dev/null || true)"
    [[ -z "$GIT_USER_EMAIL" ]] && GIT_USER_EMAIL="$(git config --global user.email 2>/dev/null || true)"
  fi
  if (exec </dev/tty) 2>/dev/null; then
    log "Git identity"
    sub "stamped on every commit you make on this machine (git config --global)"
    while :; do
      ask_tty GIT_USER_NAME "Full name" "$GIT_USER_NAME"
      [[ -n "$GIT_USER_NAME" ]] && break
      warn "a name is required — or re-run with SKIP_GIT_IDENTITY=1 to skip this"
    done
    # The default stays the value we started with: a rejected answer must never
    # come back as something Enter would accept.
    git_email_default="$GIT_USER_EMAIL"
    while :; do
      ask_tty GIT_USER_EMAIL "Email" "$git_email_default"
      [[ "$GIT_USER_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] && break
      warn "that does not look like an email address"
    done
    sub "commits will be authored as: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
  fi
fi

# ---------------------------------------------------------- start folder ----
# Where a login lands: the folder the tmux session opens in, and the folder a
# login shell cds to when the tmux autostart is off. Asked here, next to the
# identity, for the same reason — a question that only appears after twenty
# minutes of package installs is a question nobody is there to answer.
#
# Precedence: DEV_START_DIR from the environment wins outright and suppresses
# the prompt, then the answer from the last run, then DEV_ROOT if it exists,
# then $HOME. Whatever comes out is offered as the default you can take with
# Enter, so a re-run is just Enter.
start_dir_default="$DEV_START_DIR"
[[ -z "$start_dir_default" && -s "$START_DIR_STATE" ]] && \
  start_dir_default="$(head -1 "$START_DIR_STATE")"
[[ -z "$start_dir_default" && -d "$DEV_ROOT" ]] && start_dir_default="$DEV_ROOT"
[[ -z "$start_dir_default" ]] && start_dir_default="$HOME"

if [[ "$CLEAN_ONLY" != "1" && "$SKIP_START_DIR" != "1" && -z "$DEV_START_DIR" ]] \
   && (exec </dev/tty) 2>/dev/null; then
  log "Start folder"
  sub "every login starts here: the tmux session opens in it, and so does a"
  sub "login shell when the tmux autostart is off"
  start_answer=""; start_create=""      # ask_tty fills these in with printf -v
  while :; do
    ask_tty start_answer "Folder" "$start_dir_default"
    # read never expands a tilde, and a trailing slash would show up in every
    # prompt and every status line.
    start_answer="${start_answer/#\~/$HOME}"
    start_answer="${start_answer%/}"; [[ -z "$start_answer" ]] && start_answer="/"
    if [[ "$start_answer" != /* ]]; then
      warn "that has to be a full path — starting with / (or ~)"
      continue
    fi
    if [[ -d "$start_answer" ]]; then
      if [[ -r "$start_answer" && -x "$start_answer" ]]; then
        DEV_START_DIR="$start_answer"; break
      fi
      warn "$start_answer exists but you cannot cd into it"
      continue
    fi
    warn "$start_answer does not exist yet"
    ask_tty start_create "Create it? (y/n)" "y"
    if [[ "$start_create" == [Yy]* ]]; then
      if mkdir -p "$start_answer" 2>/dev/null; then
        sub "created $start_answer"
        DEV_START_DIR="$start_answer"; break
      fi
      warn "could not create it — no permission, or a file is in the way"
    fi
  done
  sub "logins will start in ${DEV_START_DIR}"
fi

# Nothing was asked (no terminal, SKIP_START_DIR, or a value from the
# environment): settle on the default and normalise it the same way.
[[ -z "$DEV_START_DIR" ]] && DEV_START_DIR="$start_dir_default"
DEV_START_DIR="${DEV_START_DIR/#\~/$HOME}"
DEV_START_DIR="${DEV_START_DIR%/}"; [[ -z "$DEV_START_DIR" ]] && DEV_START_DIR="/"
[[ -d "$DEV_START_DIR" ]] || \
  warn "start folder $DEV_START_DIR does not exist — logins will fall back to \$HOME"
# Remembered so the next run can offer it as the default, and so this stays
# put when a later run has no terminal to ask from.
[[ "$CLEAN_ONLY" == "1" ]] || printf '%s\n' "$DEV_START_DIR" > "$START_DIR_STATE" 2>/dev/null || true

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
  /etc/apt/preferences.d/mssql-release.pref
)
LEGACY_KEYS=(
  /etc/apt/keyrings/microsoft-prod.gpg
  /etc/apt/keyrings/microsoft.asc
  /etc/apt/keyrings/nodesource.gpg
  /etc/apt/keyrings/nodesource.asc
  /etc/apt/keyrings/pgdg.gpg
  /etc/apt/keyrings/pgdg.asc
)
removed=0
for f in "${LEGACY_SOURCES[@]}" "${LEGACY_KEYS[@]}"; do
  if [[ -e "$f" ]]; then sudo rm -f "$f"; sub "removed  $f"; removed=$((removed+1)); fi
done
# Anything else carrying our marker (e.g. from a future rename) goes too.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  sudo rm -f "$f"; sub "removed  $f"; removed=$((removed+1))
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
  sudo apt-get update 2>&1 | grep -E '^(E|W):' | sed 's/^/    /'
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
  sudo tee "$file" >/dev/null <<EOF
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
  sudo install -d -m 0755 /etc/apt/keyrings
  sudo install -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
  gpg --show-keys --with-colons "$dest" 2>/dev/null | awk -F: '/^fpr:/{print "        key " $10}'
  return 0
}

# ========================================================== system packages ==
if [[ "$SKIP_SYSTEM" != "1" ]]; then
  log "Updating apt index"
  sudo apt-get update 2>&1 | grep -E '^(E|W):' | sed 's/^/    /'

  # One list for both releases; anything absent on this release is skipped
  # rather than failing the whole install.
  BASE_PKGS=(
    build-essential pkg-config make cmake
    git git-lfs gh git-delta
    curl wget ca-certificates gnupg apt-transport-https software-properties-common lsb-release
    unzip zip p7zip-full xz-utils zstd unrar-free
    tmux vim nano micro less pspg
    jq yq ripgrep fd-find fzf bat tree eza zoxide direnv vivid sd glow
    htop btop ncdu iotop lsof strace du-dust duf hyperfine
    net-tools dnsutils iputils-ping traceroute mtr-tiny socat openssh-client rsync
    sqlite3 shellcheck shfmt acl attr
    bash-completion moreutils entr just plocate dos2unix pv tokei trash-cli
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
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${WANT[@]}"; then
    warn "bulk install failed — retrying one by one to isolate the problem"
    for p in "${WANT[@]}"; do
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$p" \
        >/dev/null 2>&1 || { warn "  could not install: $p"; note_fail "pkg:$p"; }
    done
  fi

  # Ubuntu ships these under alternate binary names.
  [[ -x /usr/bin/fdfind ]] && ln -sf /usr/bin/fdfind "$HOME/.local/bin/fd"
  [[ -x /usr/bin/batcat ]] && ln -sf /usr/bin/batcat "$HOME/.local/bin/bat"
  sudo git lfs install --system >/dev/null 2>&1 || true
fi

# ==================================================================== node ==
if [[ "$SKIP_NODE" != "1" ]]; then
  cur_node="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
  [[ "$cur_node" =~ ^[0-9]+$ ]] || cur_node=0
  distro_node="$(apt_cand nodejs | cut -d. -f1)"
  [[ "$distro_node" =~ ^[0-9]+$ ]] || distro_node=0

  if (( cur_node >= NODE_MAJOR )); then
    log "Node.js v$(node --version | sed 's/^v//') already present"
  elif (( distro_node >= NODE_MAJOR )); then
    # 26.04 ships a current Node; no third-party repo needed.
    log "Installing Node.js ${distro_node}.x from Ubuntu ${OS_VER}"
    soft "nodejs (distro)" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs npm
  else
    # 24.04 ships 18.x, which is EOL — use NodeSource.
    log "Ubuntu ${OS_VER} offers Node ${distro_node}.x; installing ${NODE_MAJOR}.x from NodeSource"
    if fetch_keys /etc/apt/keyrings/nodesource.asc \
         https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key; then
      if add_repo /etc/apt/sources.list.d/nodesource.sources \
           "https://deb.nodesource.com/node_${NODE_MAJOR}.x" nodistro main \
           /etc/apt/keyrings/nodesource.asc; then
        sudo apt-get update -qq 2>&1 | grep -E '^E:' | sed 's/^/    /'
        soft "nodejs (NodeSource)" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
      fi
    else
      warn "could not fetch the NodeSource key"; note_fail "nodejs"
    fi
  fi

  if have npm; then
    npm config set prefix "$HOME/.local" >/dev/null 2>&1 || true
    npm config set fund false >/dev/null 2>&1 || true
    log "Installing global npm tooling"
    # pyright and typescript-language-server are here for a reason: the
    # pyright-lsp / typescript-lsp plugins only *declare* the server command,
    # they never install it. Without these two the plugins load and do nothing.
    npm install -g --silent npm@latest typescript ts-node tsx eslint prettier \
      typescript-language-server pyright pnpm \
      nodemon pm2 mssql 2>/dev/null || warn "some npm globals failed"
  fi
fi

# ================================================================== python ==
if [[ "$SKIP_PYTHON" != "1" ]]; then
  if have uv; then
    log "uv $(uv --version 2>/dev/null | awk '{print $2}') already present"
  else
    log "Installing uv"
    soft "uv" bash -c 'curl -fsSL --max-time 60 https://astral.sh/uv/install.sh | sh' || true
  fi
  if have pipx; then
    log "Installing pipx tools"
    pipx ensurepath >/dev/null 2>&1 || true
    for pkg in ruff black isort ipython httpie sqlfluff pre-commit pgcli; do
      pipx install "$pkg" >/dev/null 2>&1 || pipx upgrade "$pkg" >/dev/null 2>&1 \
        || { warn "pipx: $pkg failed"; note_fail "pipx:$pkg"; }
    done
  fi
fi

# =================================================================== .NET ===
# Ubuntu ships .NET itself now (26.04 -> 10.0, 24.04 -> 8.0), and that is the
# path of least resistance: no extra apt source to conflict with, and security
# updates arrive with the distro. DOTNET_MAJOR pins one; empty means "newest the
# distro offers". Only if the distro has none does Microsoft's official
# installer put a private copy in ~/.dotnet.
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
      soft "$dn_pkg" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$dn_pkg"
    else
      log "Ubuntu ${OS_VER} carries no .NET SDK — using Microsoft's installer (~/.dotnet)"
      soft "dotnet (dot.net installer)" bash -c \
        'curl -fsSL --max-time 300 https://dot.net/v1/dotnet-install.sh \
           | bash -s -- --channel LTS --install-dir "$HOME/.dotnet" --no-path' || true
    fi
  fi

  # Global tools live in ~/.dotnet/tools. csharp-ls is not optional decoration:
  # it is the binary the csharp-lsp plugin shells out to.
  if have dotnet || [[ -x "$HOME/.dotnet/dotnet" ]]; then
    export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
    export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
    log "Installing .NET global tools"
    dn_have="$(dotnet tool list -g 2>/dev/null | awk 'NR>2{print $1}')"
    for dn_t in $DOTNET_TOOLS; do
      if grep -qx "$dn_t" <<<"$dn_have"; then
        sub "${dn_t} already installed"
      else
        sub "installing ${dn_t}"
        dotnet tool install -g "$dn_t" >/dev/null 2>&1 \
          || dotnet tool update -g "$dn_t" >/dev/null 2>&1 \
          || { warn "dotnet tool failed: ${dn_t}"; note_fail "dotnet-tool:${dn_t}"; }
      fi
    done
  fi
fi

# ============================================================= claude code ==
if [[ "$SKIP_CLAUDE" != "1" ]]; then
  if have claude || [[ -x "$HOME/.local/bin/claude" ]]; then
    log "Claude Code already present ($("$HOME/.local/bin/claude" --version 2>/dev/null | awk '{print $1}'))"
  else
    log "Installing Claude Code (native installer, per-user, auto-updating)"
    soft "claude-code" bash -c 'curl -fsSL --max-time 120 https://claude.ai/install.sh | bash' || true
  fi
fi

# ======================================================== claude code conf ==
# Two files, two very different policies:
#
#   ~/.claude/statusline.sh    fully ours — regenerated on every run
#   ~/.claude/settings.json    yours — this only fills in keys that are NOT
#                              already there
#
# settings.json is a file you also edit from inside a session (/config,
# /statusline, /doctor), so a re-run must never undo a choice you made there.
# Delete a key and re-run to get our default back. MCP servers are deliberately
# left alone: configure those by hand.
if [[ "$SKIP_CLAUDE_CONF" != "1" ]] && have claude; then
  log "Configuring Claude Code"
  mkdir -p "$HOME/.claude"

  # ---- status line ---------------------------------------------------------
  # Catppuccin Mocha, to match tmux/bat/delta/fzf. The session JSON arrives on
  # stdin; every field is optional, so each one is guarded.
  claim "$HOME/.claude/statusline.sh" && cat > "$HOME/.claude/statusline.sh" <<'STATUSLINE'
#!/usr/bin/env bash
# ~/.claude/statusline.sh — managed by dev-bootstrap.sh, regenerated on re-run.
# Renders: Opus · project · branch* · 38% ctx · $0.42
IFS= read -r -d '' IN || true
j() { printf '%s' "$IN" | jq -r "$1 // empty" 2>/dev/null; }

mauve=$'\033[38;2;203;166;247m'; blue=$'\033[38;2;137;180;250m'
green=$'\033[38;2;166;227;161m'; peach=$'\033[38;2;250;179;135m'
red=$'\033[38;2;243;139;168m';   grey=$'\033[38;2;108;112;134m'
text=$'\033[38;2;205;214;244m';  off=$'\033[0m'

cwd="$(j '.workspace.current_dir')"
model="$(j '.model.display_name')"
dir="$(basename "${cwd:-$PWD}")"
pct="$(j '.context_window.used_percentage')"; pct="${pct%%.*}"; pct="${pct:-0}"
cost="$(j '.cost.total_cost_usd')"
style="$(j '.output_style.name')"

branch="$(git -C "${cwd:-$PWD}" branch --show-current 2>/dev/null)"
if [[ -n "$branch" ]]; then
  git -C "${cwd:-$PWD}" diff --quiet --ignore-submodules HEAD 2>/dev/null || branch+="*"
fi

if   (( pct < 50 )); then pc="$green"
elif (( pct < 80 )); then pc="$peach"
else                      pc="$red"; fi

out="${mauve}${model}${off}"
out+=" ${grey}·${off} ${blue}${dir}${off}"
[[ -n "$branch" ]] && out+=" ${grey}·${off} ${green}${branch}${off}"
out+=" ${grey}·${off} ${pc}${pct}% ctx${off}"
[[ -n "$cost"   ]] && out+=" ${grey}·${off} ${text}$(printf '$%.2f' "$cost")${off}"
[[ -n "$style" && "$style" != "default" ]] && out+=" ${grey}·${off} ${text}${style}${off}"
printf '%s' "$out"
STATUSLINE
  chmod +x "$HOME/.claude/statusline.sh"
  sub "wrote ~/.claude/statusline.sh (Catppuccin Mocha)"

  # ---- settings ------------------------------------------------------------
  # `$def * .` deep-merges with the RIGHT side winning, so everything already in
  # the file — your hooks, tui, MCP entries, any theme you picked — survives.
  if have jq; then
    cc_set="$HOME/.claude/settings.json"
    [[ -s "$cc_set" ]] || printf '{}\n' > "$cc_set"
    cc_def='{
      "theme": "dark",
      "statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 0 },
      "alwaysThinkingEnabled": true,
      "autoUpdatesChannel": "stable",
      "cleanupPeriodDays": 90,
      "includeCoAuthoredBy": false
    }'
    cc_tmp="$(mktemp)"
    if jq --argjson def "$cc_def" '$def * .' "$cc_set" > "$cc_tmp" 2>/dev/null && [[ -s "$cc_tmp" ]]; then
      # Compared by content, not by bytes: Claude Code writes this file with its
      # own formatting, and jq's differs — a byte comparison would "change" it on
      # every single run.
      if [[ "$(jq -S . "$cc_tmp")" == "$(jq -S . "$cc_set")" ]]; then
        sub "settings.json already has every key we would seed"
      else
        cp -p "$cc_set" "${cc_set}.bak"
        cat "$cc_tmp" > "$cc_set"          # keeps the original mode and inode
        sub "seeded the missing keys in ~/.claude/settings.json (old file: settings.json.bak)"
      fi
    else
      warn "the Claude Code settings file is not valid JSON — leaving it untouched"
      note_fail "claude settings.json"
    fi
    rm -f "$cc_tmp"
  else
    warn "jq is missing — skipping the settings.json merge"
  fi

  # ---- plugins -------------------------------------------------------------
  # Language servers, so Claude can resolve definitions and read diagnostics
  # instead of grepping for them.
  #
  # The marketplace has to be added before anything can be installed from it: a
  # fresh ~/.claude knows no marketplaces at all, and `plugin install` then fails
  # with "not found in marketplace". Adding it records the source in
  # settings.json (extraKnownMarketplaces) and clones it, so this is a one-off
  # per machine — repeating it is harmless but slow, hence the check.
  if ! claude plugin marketplace list 2>/dev/null | grep -qF claude-plugins-official; then
    sub "adding the claude-plugins-official marketplace"
    timeout 180 claude plugin marketplace add anthropics/claude-plugins-official >/dev/null 2>&1 \
      || warn "could not add the plugin marketplace"
  fi
  for cc_plug in $CLAUDE_PLUGINS; do
    if claude plugin list 2>/dev/null | grep -qF "$cc_plug"; then
      sub "plugin ${cc_plug} already installed"
    else
      sub "installing plugin ${cc_plug}"
      timeout 180 claude plugin install "${cc_plug}@claude-plugins-official" >/dev/null 2>&1 \
        || { warn "could not install the ${cc_plug} plugin"; note_fail "plugin:${cc_plug}"; }
    fi
  done

  # An LSP plugin only DECLARES the server command — it never installs it. A
  # plugin whose binary is missing loads fine and then does nothing at all, so
  # it is worth saying so out loud. The servers themselves come from the node
  # section (pyright, typescript-language-server) and the .NET one (csharp-ls).
  for cc_pair in "pyright-lsp:pyright-langserver" \
                 "typescript-lsp:typescript-language-server" \
                 "csharp-lsp:csharp-ls"; do
    cc_plug="${cc_pair%%:*}"; cc_bin="${cc_pair##*:}"
    [[ " $CLAUDE_PLUGINS " == *" $cc_plug "* ]] || continue
    if have "$cc_bin" || [[ -x "$HOME/.local/bin/$cc_bin" || -x "$HOME/.dotnet/tools/$cc_bin" ]]; then
      sub "${cc_plug} → ${cc_bin} found"
    else
      warn "${cc_plug} is installed but ${cc_bin} is not on PATH — that language server will not start"
      note_fail "lsp:${cc_bin}"
    fi
  done
fi

# ======================================================= old shell config ===
# Writing our own files is not enough on a machine that has been set up before:
# what was already there keeps running. Three kinds of leftover actually bite,
# and they are dealt with here, before anything new is written.
#
#   1. a stale "# >>> dev-bootstrap >>>" block in a startup file this run no
#      longer hooks — it would source an rc.sh a second time, or one that is
#      no longer there
#   2. a tmux autostart of your own. `exec tmux` replaces the shell and
#      `tmux attach` blocks until you detach, so in both cases every line
#      after it — including the block that loads all of this — never runs
#   3. settings pointed somewhere else entirely by the environment. Those can
#      only be reported: they are not in this user's shell files.
#
# SKIP_LEGACY_CLEAN=1 turns the whole section off and leaves everything as is.
LOGIN_HAD_OURS=0
if [[ "$SKIP_LEGACY_CLEAN" != "1" ]]; then
  log "Clearing settings from earlier setups that would fight this one"
  legacy_cleaned=0
  RC_FILES=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login"
            "$HOME/.profile" "$HOME/.bash_aliases")

  # ---- 1. our own blocks, wherever they ended up ---------------------------
  # Only when the shell config is actually being rewritten: stripping the block
  # under SKIP_SHELL_CONF=1 would leave the shell with nothing at all.
  if [[ "$SKIP_SHELL_CONF" != "1" ]]; then
    for f in "${RC_FILES[@]}"; do
      grep -qsF "$MARKER" "$f" || continue
      [[ "$f" != "$HOME/.bashrc" ]] && LOGIN_HAD_OURS=1
      strip_block "$f"
      sub "removed the old dev-bootstrap block from $(hp "$f")"
      legacy_cleaned=$((legacy_cleaned+1))
    done
  fi

  # ---- 2. a competing tmux autostart ---------------------------------------
  # Left alone when our own autostart is off (DEV_TMUX_AUTOSTART=0) — with
  # nothing to compete with, yours is simply the one that runs.
  # Matched narrowly: an `exec tmux`, or a bare `tmux attach|new|new-session`
  # command. Aliases and function bodies (which is where `alias ta='tmux
  # attach -t'` lives) are skipped, and so is anything already commented out.
  if [[ "$DEV_TMUX_AUTOSTART" == "1" ]]; then
    for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      [[ -f "$f" ]] || continue
      tmux_lines="$(grep -nE '^[[:space:]]*[^#]*\btmux\b' "$f" 2>/dev/null \
        | grep -vE '\balias\b|\bfunction\b|\(\)|dev-bootstrap|__auto_tmux' \
        | grep -E '\bexec[[:space:]]+tmux\b|\btmux\b([[:space:]]+-[^[:space:]]+)*[[:space:]]+(a|at|att|attach|attach-session|new|new-session)\b' \
        | cut -d: -f1)"
      [[ -z "$tmux_lines" ]] && continue
      claim "$f" || continue
      while read -r ln; do
        [[ -n "$ln" ]] || continue
        sub "$(hp "$f") line ${ln}: $(sed -n "${ln}p" "$f" | sed 's/^[[:space:]]*//')"
        sed -i "${ln}s|^|# disabled by dev-bootstrap (competing tmux autostart): |" "$f"
      done <<< "$tmux_lines"
      warn "commented out a tmux autostart of your own in $(hp "$f")"
      sub "ours takes over: session \"dev\", with the opt-outs listed at the end"
      sub "to keep yours instead: DEV_TMUX_AUTOSTART=0, and restore the lines above"
      ADOPTED+=("$(hp "$f") — your tmux autostart commented out")
      legacy_cleaned=$((legacy_cleaned+1))
    done
  fi

  # ---- 3. what cannot be overwritten from here -----------------------------
  if [[ -n "${INPUTRC:-}" && "${INPUTRC}" != "$HOME/.inputrc" ]]; then
    warn "INPUTRC=${INPUTRC} — readline reads that file and ignores ~/.inputrc"
    sub "it comes from outside this shell (/etc/environment, PAM, the SSH client)"
  fi
  if [[ -n "${GIT_CONFIG_GLOBAL:-}" ]]; then
    warn "GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL} — the git settings below go there"
  fi
  if [[ -f "$HOME/.gitconfig" && -f "$HOME/.config/git/config" ]]; then
    warn "both ~/.gitconfig and ~/.config/git/config exist — git reads both"
    sub "we write to ~/.gitconfig, which is read last and therefore wins"
  fi
  [[ -f /etc/tmux.conf ]] && \
    sub "/etc/tmux.conf is system-wide and read first — ~/.tmux.conf overrides it"
  if [[ -d "$HOME/.tmux/plugins/tpm" ]]; then
    warn "the tmux plugin manager is installed but nothing loads it any more"
    sub "the new ~/.tmux.conf has no TPM line — the plugins just sit there"
    sub "rm -rf ~/.tmux/plugins to be done with them"
  fi
  [[ -e "$HOME/.tmux.conf.local" ]] && \
    sub "found ~/.tmux.conf.local (oh-my-tmux) — nothing reads it any more"
  [[ -f "$HOME/.bash_aliases" ]] && \
    sub "your ~/.bash_aliases still loads, and earlier than ours — ours win on a clash"

  # ---- 4. our own generated files that no longer belong to any section -----
  # rc.sh, theme.sh and completions/ are regenerated below, so whatever else is
  # in there came from an older version of this script and is now dead weight:
  # nothing sources it any more. Anything called local* is yours and stays, and
  # so does start-dir: it is this run's memory of the start-folder answer.
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rm -rf "$f"; sub "removed stale $(hp "$f")"; legacy_cleaned=$((legacy_cleaned+1))
  done < <(find "$CONF_DIR" -mindepth 1 -maxdepth 1 \
             ! -name 'local*' ! -name rc.sh ! -name theme.sh ! -name completions \
             ! -name start-dir 2>/dev/null)

  (( legacy_cleaned == 0 )) && sub "nothing left over to clean"
fi

# ============================================================== tmux.conf ===
# tmux_reload — hand the new config to a server that is ALREADY running.
#
# Sourcing a config never *un*sets anything. Every option and every key binding
# from the config that was in force when the server started is still in force
# afterwards, so an old ~/.tmux.conf keeps its bindings until the last session
# dies — the classic "I rewrote tmux.conf and half of it did nothing".
#
# So: put the running server back to stock first, then apply ours on top.
#   options — `set -u` on a global option restores its built-in default
#   bindings — there is no "reset keys" command, so the defaults are read out
#              of a throwaway server started with -f /dev/null. list-keys
#              prints exactly the bind-key commands that recreate them, which
#              means the output can be sourced straight back in.
# Any of that failing is not fatal: the config is on disk either way, and a
# fresh server (or `tmux kill-server`) always starts clean.
tmux_reload() {
  tmux info &>/dev/null || return 0        # no server: nothing stale to clear
  if [[ "$DEV_TMUX_RESET" != "1" ]]; then
    tmux source-file "$HOME/.tmux.conf" 2>/dev/null || true
    return 0
  fi
  local scope id o keys t
  for scope in -g -gw; do
    tmux show-options $scope 2>/dev/null | cut -d' ' -f1 | cut -d'[' -f1 | sort -u \
      | while read -r o; do [[ -n "$o" ]] && tmux set $scope -u "$o" 2>/dev/null; done
  done
  # Session- and window-local values shadow the globals we just reset.
  while read -r id; do
    [[ -n "$id" ]] || continue
    tmux show-options -t "$id" 2>/dev/null | cut -d' ' -f1 | cut -d'[' -f1 \
      | while read -r o; do [[ -n "$o" ]] && tmux set -t "$id" -u "$o" 2>/dev/null; done
  done < <(tmux list-sessions -F '#{session_id}' 2>/dev/null)
  while read -r id; do
    [[ -n "$id" ]] || continue
    tmux show-options -w -t "$id" 2>/dev/null | cut -d' ' -f1 | cut -d'[' -f1 \
      | while read -r o; do [[ -n "$o" ]] && tmux set -w -t "$id" -u "$o" 2>/dev/null; done
  done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null)

  keys="$(mktemp)"
  if tmux -L dev-bootstrap-probe -f /dev/null start-server \; list-keys >"$keys" 2>/dev/null \
     && [[ -s "$keys" ]]; then
    tmux -L dev-bootstrap-probe kill-server 2>/dev/null
    for t in prefix root copy-mode copy-mode-vi; do tmux unbind -a -T "$t" 2>/dev/null; done
    tmux source-file "$keys" 2>/dev/null \
      || warn "could not put the default tmux key bindings back — tmux kill-server will"
  else
    tmux -L dev-bootstrap-probe kill-server 2>/dev/null
    warn "could not read tmux's default key bindings"
    sub "bindings from your old config may survive until \`tmux kill-server\`"
  fi
  rm -f "$keys"
  if tmux source-file "$HOME/.tmux.conf" 2>/dev/null; then
    sub "reloaded the running tmux server (old options and bindings cleared)"
  else
    warn "the running tmux server did not accept the new config"
    note_fail "tmux reload"
  fi
}

if [[ "$SKIP_TMUX_CONF" != "1" ]]; then
  log "Writing ~/.tmux.conf"
  claim "$HOME/.tmux.conf" && cat > "$HOME/.tmux.conf" <<'TMUXCONF'
# ~/.tmux.conf — managed by dev-bootstrap.sh
# Theme: Catppuccin Mocha

# ---- prefix -----------------------------------------------------------------
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# ---- terminal / colours -----------------------------------------------------
# Truecolor matters: TUIs like Claude Code, micro and vim look wrong without it.
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc,xterm-256color:Tc,alacritty:Tc"
set -as terminal-features ",*:RGB"
set -g focus-events on
set -sg escape-time 0          # no delay on ESC — critical for vim/TUI apps
set -g history-limit 200000
set -g display-time 2000
set -g set-clipboard on
setw -g monitor-activity off

# ---- sane behaviour ---------------------------------------------------------
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
setw -g automatic-rename on
set -g allow-rename off
setw -g aggressive-resize on
set -g detach-on-destroy off   # jump to another session instead of dropping out

# ---- splits & navigation ----------------------------------------------------
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"
unbind '"'
unbind %

bind -n M-Left  select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up    select-pane -U
bind -n M-Down  select-pane -D

bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

bind -n S-Left  previous-window
bind -n S-Right next-window

# ---- copy mode (vi) ---------------------------------------------------------
setw -g mode-keys vi
bind Enter copy-mode
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-selection-and-cancel
bind -T copy-mode-vi Escape send -X cancel
bind P paste-buffer

# ---- misc -------------------------------------------------------------------
bind r source-file ~/.tmux.conf \; display "tmux.conf reloaded"
bind S set-window-option synchronize-panes \; display "sync-panes #{?pane_synchronized,ON,OFF}"
bind X confirm-before -p "kill-session #S? (y/n)" kill-session

# ============================ Catppuccin Mocha ===============================
# base #1e1e2e  mantle #181825  surface0 #313244  surface1 #45475a
# text #cdd6f4  subtext0 #a6adc8  overlay0 #6c7086
# blue #89b4fa  mauve #cba6f7  green #a6e3a1  peach #fab387  red #f38ba8
set -g status-position bottom
set -g status-interval 5
set -g status-justify left
set -g status-style "bg=#181825,fg=#a6adc8"

set -g status-left-length 40
set -g status-right-length 100
set -g status-left "#[bg=#89b4fa,fg=#1e1e2e,bold] #S #[bg=#181825,fg=#89b4fa,nobold]"
set -g status-right "#[fg=#6c7086]#(cut -d' ' -f1-3 /proc/loadavg) #[fg=#585b70]| #[fg=#cba6f7]#(whoami)@#H #[bg=#89b4fa,fg=#1e1e2e,bold] %a %d %b %H:%M "

setw -g window-status-format "#[fg=#6c7086] #I #[fg=#a6adc8]#W#{?window_zoomed_flag, ,} "
setw -g window-status-current-format "#[bg=#313244,fg=#89b4fa,bold] #I #[fg=#cdd6f4]#W#{?window_zoomed_flag, ,} "
setw -g window-status-activity-style "fg=#fab387"

set -g pane-border-style "fg=#313244"
set -g pane-active-border-style "fg=#89b4fa"
set -g message-style "bg=#89b4fa,fg=#1e1e2e,bold"
set -g message-command-style "bg=#313244,fg=#cdd6f4"
set -g mode-style "bg=#585b70,fg=#cdd6f4"
set -g display-panes-active-colour "#89b4fa"
set -g display-panes-colour "#6c7086"
set -g clock-mode-colour "#89b4fa"
TMUXCONF
  tmux_reload
fi

# ============================================================ shell config ==
if [[ "$SKIP_SHELL_CONF" != "1" ]]; then
  log "Writing $CONF_DIR/rc.sh"

  # The settings below are *script-time* variables. Expanding them here (rather
  # than referencing $DEV_ROOT/$DEV_EDITOR from inside the quoted heredoc, where
  # they are unset at shell-startup time and silently fall back to the default)
  # is what makes DEV_EDITOR=micro / DEV_ROOT=/somewhere actually take effect.
  cat > "$CONF_DIR/rc.sh" <<EOF
# Managed by dev-bootstrap.sh — re-running the script overwrites this file.
# Put your own additions in ~/.config/dev-bootstrap/local.sh instead.

# ---- values baked in when the bootstrap ran (env still wins) ----------------
export DEV_ROOT="\${DEV_ROOT:-${DEV_ROOT}}"
export DEV_EDITOR="\${DEV_EDITOR:-${DEV_EDITOR}}"
export DEV_START_DIR="\${DEV_START_DIR:-${DEV_START_DIR}}"
DEV_TMUX_AUTOSTART="\${DEV_TMUX_AUTOSTART:-${DEV_TMUX_AUTOSTART}}"
EOF

  cat >> "$CONF_DIR/rc.sh" <<'RCFILE'

# ---- locale (box-drawing chars in tmux/micro need UTF-8) --------------------
# Only LANG is set. LC_ALL is deliberately left alone: exporting it (even empty)
# overrides every other LC_* and breaks per-category locale overrides.
case "${LANG:-}" in
  *UTF-8|*utf8) ;;
  *) export LANG=C.UTF-8 ;;
esac

# ---- PATH -------------------------------------------------------------------
# Idempotent: re-sourcing this file (or a .bashrc that grew duplicate PATH
# lines over time) must not grow $PATH without bound.
__path_prepend() {
  case ":$PATH:" in *":$1:"*) ;; *) PATH="$1${PATH:+:$PATH}" ;; esac
}
__path_append() {
  case ":$PATH:" in *":$1:"*) ;; *) PATH="${PATH:+$PATH:}$1" ;; esac
}
__path_dedupe() {
  local IFS=: p out=
  for p in $PATH; do
    [ -n "$p" ] || continue
    case ":$out:" in *":$p:"*) ;; *) out="${out:+$out:}$p" ;; esac
  done
  PATH="$out"
}
__path_prepend "$HOME/.local/bin"
[ -d /opt/mssql-tools18/bin ] && __path_append /opt/mssql-tools18/bin
# .NET: global tools (dotnet-ef, csharp-ls, ...) always; ~/.dotnet only when it
# holds a private SDK. DOTNET_ROOT is set ONLY in that case — pointing it at
# ~/.dotnet while dotnet came from apt (/usr/lib/dotnet) breaks every command.
[ -d "$HOME/.dotnet/tools" ] && __path_append "$HOME/.dotnet/tools"
if [ -x "$HOME/.dotnet/dotnet" ]; then
  __path_append "$HOME/.dotnet"
  export DOTNET_ROOT="$HOME/.dotnet"
fi
__path_dedupe
export PATH

# ---- .NET -------------------------------------------------------------------
# NOLOGO drops the first-run banner that otherwise lands in the middle of build
# output; the telemetry opt-out is the documented DOTNET_CLI_TELEMETRY_OPTOUT.
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

# ---- truecolor --------------------------------------------------------------
# micro, bat, delta and Claude Code all check COLORTERM for 24-bit support.
export COLORTERM="${COLORTERM:-truecolor}"

# ---- shared-dev umask -------------------------------------------------------
# 002 keeps group-write on files created in /srv/dev (Ubuntu uses user-private
# groups, so this is safe in $HOME too).
umask 002

# ---- editors / pagers -------------------------------------------------------
export EDITOR="${DEV_EDITOR:-nano}"
export VISUAL="$EDITOR"
export PAGER="less"
# -R colour, -F quit if it fits on one screen, -i smart-case search.
# -X is deliberately NOT set: on less >= 530 it is no longer needed to make -F
# behave, and it breaks the alternate screen (output litters the scrollback).
export LESS="-R -F -i"
export LESSHISTFILE="$HOME/.cache/less-history"
export MANPAGER="less -R"
alias e='$EDITOR'
alias sue='sudoedit'

# ---- theme: Catppuccin Mocha ------------------------------------------------
# micro checks MICRO_TRUECOLOR, not COLORTERM — without this it silently
# degrades to the 256-colour approximation.
export MICRO_TRUECOLOR=1
# BAT_THEME is resolved at install time (Catppuccin if the theme installed
# cleanly, a built-in fallback otherwise) to avoid a warning on every call.
[ -f "$HOME/.config/dev-bootstrap/theme.sh" ] && . "$HOME/.config/dev-bootstrap/theme.sh"
export BAT_THEME="${BAT_THEME:-OneHalfDark}"
command -v vivid >/dev/null 2>&1 && \
  LS_COLORS="$(vivid generate catppuccin-mocha 2>/dev/null)" && export LS_COLORS

# fzf, themed to match
export FZF_DEFAULT_OPTS="
  --height 45% --layout=reverse --border=rounded --info=inline
  --color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8
  --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc
  --color=marker:#a6e3a1,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8
  --color=border:#585b70"
if command -v fdfind >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --follow --exclude .git --exclude node_modules'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND='fdfind --type d --hidden --follow --exclude .git --exclude node_modules'
fi
# Preview panes for the built-in bindings.
command -v batcat >/dev/null 2>&1 && \
  export FZF_CTRL_T_OPTS="--preview 'batcat --style=numbers --color=always --line-range=:200 {}'"
export FZF_CTRL_R_OPTS="--reverse"

# ---- history ----------------------------------------------------------------
export HISTSIZE=100000
export HISTFILESIZE=200000
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT="%F %T "
# Noise that is never worth recalling and only pushes real history out.
export HISTIGNORE='ls:ll:la:l:cd:cd -:..:...:pwd:exit:clear:reload:history:gs:h'
shopt -s histappend cmdhist checkwinsize 2>/dev/null
# globstar   -> **/ recursion;  direxpand -> tab-completing $VAR/ expands it
# checkjobs  -> warn instead of silently killing background jobs on exit
# no_empty_cmd_completion -> don't scan all of $PATH on a bare TAB
shopt -s globstar direxpand checkjobs no_empty_cmd_completion 2>/dev/null

# ---- prompt (Catppuccin, git-aware, exit-status aware) ----------------------
# Tuning knobs (set in local.sh):
#   DEV_PROMPT_GIT=0        no git segment at all
#   DEV_PROMPT_GIT_DIRTY=0  keep the branch name, drop the "*" dirty check
#                           (the dirty check is the expensive half in a big
#                            work tree — it has to stat the whole index)
__prompt() {
  local ec=$?
  # Flush this command to disk so other tmux panes see it immediately.
  # Guarded: HISTFILE is unset in some non-interactive contexts, and an
  # unguarded `history -a` then prints an error before every single prompt.
  [ -n "${HISTFILE:-}" ] && history -a
  local reset='\[\e[0m\]'
  local mauve='\[\e[38;2;203;166;247m\]' blue='\[\e[38;2;137;180;250m\]'
  local green='\[\e[38;2;166;227;161m\]' red='\[\e[38;2;243;139;168m\]'
  local grey='\[\e[38;2;108;112;134m\]'  peach='\[\e[38;2;250;179;135m\]'
  local br="" b=""
  if [ "${DEV_PROMPT_GIT:-1}" = "1" ]; then
    # One fork in the common case: symbolic-ref fails outside a work tree, so
    # it doubles as the "am I in a repo?" test that rev-parse used to do.
    if b=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) \
       || b=$(git rev-parse --short HEAD 2>/dev/null); then
      if [ "${DEV_PROMPT_GIT_DIRTY:-1}" = "1" ]; then
        # GIT_OPTIONAL_LOCKS=0: never take index.lock just to draw a prompt,
        # which otherwise races with a concurrent git command in another pane.
        GIT_OPTIONAL_LOCKS=0 git diff --quiet --ignore-submodules HEAD 2>/dev/null \
          || b="$b*"
      fi
      br=" ${peach}(${b})"
    fi
  fi
  local mark="${green}\$" ; [ "$ec" -ne 0 ] && mark="${red}\$"
  PS1="${mauve}\u${grey}@\h ${blue}\w${br}${reset}\n${mark}${reset} "
}
# NOTE: __prompt is deliberately NOT registered here. It is hooked into
# PROMPT_COMMAND at the very bottom of this file, after zoxide and direnv have
# installed their own hooks — see "prompt registration" there for why.

# ---- Claude Code ------------------------------------------------------------
# NOTE: this shadows /usr/bin/cc (the C compiler) in *interactive* shells only.
# Makefiles and scripts are unaffected. Use `command cc` or `\cc` for the compiler.
alias cc='claude'
alias ccc='claude --continue'          # resume the most recent session
alias ccr='claude --resume'            # pick a session from a list
alias ccp='claude --permission-mode plan'
alias ccdoc='claude doctor'

# ---- listing ----------------------------------------------------------------
#   ll   long listing, human sizes, no dotfiles   (the everyday one)
#   la   long listing including dotfiles
#   l    bare one-per-line names
#   lt   tree, 2 levels        lt3  tree, 3 levels
#   ltr  newest last           lsz  biggest first
#   ldot just the dotfiles
# eza gets --git (per-file status column) and long-iso timestamps, which sort
# and diff far better than the locale-dependent default.
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first --icons=never'
  alias l='eza -1 --group-directories-first --icons=never'
  alias ll='eza -lgh --group-directories-first --icons=never --time-style=long-iso --git'
  alias la='eza -lagh --group-directories-first --icons=never --time-style=long-iso --git'
  alias lt='eza --tree --level=2 --group-directories-first --icons=never'
  alias lt3='eza --tree --level=3 --group-directories-first --icons=never'
  alias ltr='eza -lgh --icons=never --time-style=long-iso --sort=modified'
  alias lsz='eza -lgh --icons=never --time-style=long-iso --sort=size --reverse'
  alias ldot='eza -lgdh --icons=never --time-style=long-iso .*'
else
  # Plain coreutils fallback — same names, so muscle memory survives a box
  # where eza is not available.
  alias ls='ls --color=auto --group-directories-first'
  alias l='ls -1'
  alias ll='ls -lh --color=auto --group-directories-first'
  alias la='ls -lAh --color=auto --group-directories-first'
  alias lt='ls -R --color=auto'
  alias lt3='ls -R --color=auto'
  alias ltr='ls -lhtr --color=auto'
  alias lsz='ls -lhS --color=auto'
  alias ldot='ls -lhd --color=auto .*'
fi

# ---- general ----------------------------------------------------------------
alias ..='cd ..'
alias ...='cd ../..'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ports='ss -tulpn'
alias myip='curl -s ifconfig.me; echo'
alias reload='source ~/.bashrc'
alias path='echo "$PATH" | tr ":" "\n"'

# ---- git --------------------------------------------------------------------
alias gs='git status -sb'
alias ga='git add'
alias gc='git commit'
alias gca='git commit --amend'
alias gp='git push'
alias gpl='git pull --rebase'
alias gd='git diff'
alias gds='git diff --staged'
alias gl='git log --oneline --graph --decorate -20'
alias gll='git log --oneline --graph --decorate --all'
alias gb='git branch -vv'
alias gco='git checkout'
alias gsw='git switch'
alias gst='git stash'

# ---- databases --------------------------------------------------------------
# sqlcmd 18 defaults to encrypted connections; -C trusts self-signed dev certs.
alias sqlcmd='sqlcmd -C'
alias pg='pgcli'
alias pgl='psql -l'

# ---- tmux -------------------------------------------------------------------
alias ta='tmux attach -t'
alias tl='tmux list-sessions'
alias tn='tmux new -s'
alias tk='tmux kill-session -t'
# dev <name>: attach to (or create) a tmux session rooted in the project folder
dev() {
  local root="${DEV_ROOT:-/srv/dev}"
  local name="${1:-}"
  if [ -z "$name" ]; then tmux new-session -A -s dev -c "$root"; return; fi
  local dir="$root/$name"
  [ -d "$dir" ] || { echo "No such project: $dir" >&2; return 1; }
  tmux new-session -A -s "$name" -c "$dir"
}

# ---- python -----------------------------------------------------------------
alias py='python3'
alias venv='python3 -m venv .venv && source .venv/bin/activate'
alias act='source .venv/bin/activate'

# ---- misc tools -------------------------------------------------------------
command -v batcat >/dev/null 2>&1 && alias cat='batcat --paging=never --style=plain'
command -v fdfind >/dev/null 2>&1 && alias fd='fdfind'
# dust/duf are NOT aliased over du/df on purpose: their flags differ, so a
# reflexive `du -sh *` would fail. They keep their own names.
command -v trash-put >/dev/null 2>&1 && alias trash='trash-put'
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"

# fzf: `fzf --bash` (0.48+) emits key bindings AND completion in one go and is
# the only form upstream supports. The example files under /usr/share/doc are
# Debian-specific, move between releases, and ship key-bindings only — so they
# are a fallback, not the primary path.
if command -v fzf >/dev/null 2>&1; then
  if __fzf_init="$(fzf --bash 2>/dev/null)" && [ -n "$__fzf_init" ]; then
    eval "$__fzf_init"
  else
    for __f in /usr/share/doc/fzf/examples/key-bindings.bash \
               /usr/share/doc/fzf/examples/completion.bash; do
      [ -r "$__f" ] && . "$__f"
    done
    unset __f
  fi
  unset __fzf_init
fi

# System bash-completion (Ubuntu's own .bashrc normally does this, but this
# file must stand on its own — it is also sourced from ~/.bash_profile).
if ! declare -F _init_completion >/dev/null 2>&1; then
  if [ -r /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -r /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi
# Completions generated at bootstrap time (gh, npm, uv, just, ...). Generating
# them here instead of running `gh completion -s bash` on every shell start
# keeps startup free of extra forks.
if [ -d "$HOME/.config/dev-bootstrap/completions" ]; then
  for __f in "$HOME/.config/dev-bootstrap/completions/"*.bash; do
    [ -r "$__f" ] && . "$__f"
  done
  unset __f
fi

# Tab-complete `dev <project>` from the directories under $DEV_ROOT.
_dev_complete() {
  local root="${DEV_ROOT:-/srv/dev}" cur="${COMP_WORDS[COMP_CWORD]}" d
  COMPREPLY=()
  while IFS= read -r d; do
    [ -n "$d" ] && COMPREPLY+=("$d")
  done < <(cd "$root" 2>/dev/null && compgen -d -- "$cur")
}
complete -F _dev_complete dev

# ---- helpers ----------------------------------------------------------------
mkcd() { mkdir -p "$1" && cd "$1" || return 1; }

extract() {
  [ -f "${1:-}" ] || { echo "extract: no such file: ${1:-<none>}" >&2; return 1; }
  case "$1" in
    *.tar.bz2|*.tbz2)  tar xjf  "$1" ;;
    *.tar.gz|*.tgz)    tar xzf  "$1" ;;
    *.tar.xz|*.txz)    tar xJf  "$1" ;;
    *.tar.zst|*.tzst)  tar --zstd -xf "$1" ;;
    *.tar)             tar xf   "$1" ;;
    *.zip|*.jar|*.whl) unzip    "$1" ;;
    *.7z)              7z x     "$1" ;;
    *.rar)             unrar-free -x "$1" ;;
    *.bz2)             bunzip2  "$1" ;;
    *.gz)              gunzip   "$1" ;;
    *.xz)              unxz     "$1" ;;
    *.zst)             unzstd   "$1" ;;
    *) echo "extract: unsupported format: $1" >&2; return 1 ;;
  esac
}

# Extract into a directory named after the archive, so a "tar bomb" cannot
# scatter hundreds of files into $PWD.
extractd() {
  [ -f "${1:-}" ] || { echo "extractd: no such file: ${1:-<none>}" >&2; return 1; }
  local dir; dir="$(basename "$1")"
  dir="${dir%.*}"; dir="${dir%.tar}"
  mkdir -p "$dir" || return 1
  local abs; abs="$(readlink -f "$1")"
  ( cd "$dir" && extract "$abs" )
}

# backup <file> — timestamped copy next to the original
backup() {
  [ -e "${1:-}" ] || { echo "backup: no such file: ${1:-<none>}" >&2; return 1; }
  local dest; dest="$1.$(date +%Y%m%d-%H%M%S).bak"   # one `date`, one timestamp
  cp -a "$1" "$dest" && echo "$dest"
}

# serve [port] — static HTTP server for the current directory
serve() { python3 -m http.server "${1:-8000}"; }

# h <pattern> — grep your shell history
h() { if [ $# -eq 0 ]; then history; else history | grep -i -- "$*"; fi; }

# ff <pattern> — find files by name anywhere below $PWD
ff() { if command -v fdfind >/dev/null 2>&1; then fdfind --hidden --follow "$@"; else find . -iname "*$1*"; fi; }

# mkvenv — create + activate .venv, preferring uv (much faster than venv)
mkvenv() {
  if command -v uv >/dev/null 2>&1; then uv venv .venv || return 1
  else python3 -m venv .venv || return 1; fi
  . .venv/bin/activate
}

# ---- prompt registration ----------------------------------------------------
# Registered here, last, on purpose. zoxide and direnv both install their hooks
# by *prepending* to PROMPT_COMMAND, so whichever hook is added last ends up at
# the front of the chain. __prompt has to be at the front: its first statement
# is `local ec=$?`, and if a zoxide/direnv hook ran ahead of it that $? would be
# the hook's exit status (always 0) instead of the command you actually ran —
# the red "$" on failure would never appear.
case "${PROMPT_COMMAND:-}" in
  *__prompt*) ;;                                        # already registered
  "")         PROMPT_COMMAND="__prompt" ;;
  *)          PROMPT_COMMAND="__prompt;$PROMPT_COMMAND" ;;
esac

# ---- your own overrides -----------------------------------------------------
# Sourced before the two things below that read DEV_START_DIR, so setting it in
# local.sh is enough to move where you land — no re-run needed.
[ -f "$HOME/.config/dev-bootstrap/local.sh" ] && . "$HOME/.config/dev-bootstrap/local.sh"

# ---- land in the start folder ----------------------------------------------
# Only on a real LOGIN shell, and only when it started in $HOME: a shell that
# was put somewhere on purpose stays there. That covers `ssh host -t "cd /x &&
# bash -l"`, a new tmux pane (which inherits the pane's directory), VS Code,
# and every non-login shell, none of which should be moved.
#
# With the tmux autostart on this is usually a no-op — the session below is
# opened with -c "$DEV_START_DIR" already — but it is what makes the folder
# take effect when tmux is off, opted out of, or not installed.
__start_dir() {
  [ -n "${DEV_START_DIR:-}" ] || return
  shopt -q login_shell         || return
  [ "$PWD" = "$HOME" ]         || return
  [ -d "$DEV_START_DIR" ]      || return
  cd "$DEV_START_DIR" 2>/dev/null || true
}
__start_dir

# ---- auto-attach tmux on login ---------------------------------------------
# Lands you in a tmux session named "dev" rooted at $DEV_START_DIR.
# Deliberately conservative: only for real interactive logins.
# Escape hatches:
#   touch ~/.no-auto-tmux        (permanent, per user)
#   ssh server -t 'bash -l'      -> still tmux
#   ssh server                   -> non-interactive, never tmux
#   NO_TMUX=1 (if you can set it before bash starts)
__auto_tmux() {
  [ -n "${NO_TMUX:-}" ]              && return   # opt out for this shell
  [ -f "$HOME/.no-auto-tmux" ]       && return   # opt out permanently
  [ -n "${TMUX:-}" ]                 && return   # already inside tmux
  [ -n "${SSH_ORIGINAL_COMMAND:-}" ] && return   # forced command / rsync / scp
  [ -n "${VSCODE_INJECTION:-}" ]     && return   # VS Code Remote
  [ "${TERM_PROGRAM:-}" = "vscode" ] && return
  [ -n "${INSIDE_EMACS:-}" ]         && return
  case "$TERM" in dumb|unknown|"") return ;; esac
  case "$-" in *i*) : ;; *) return ;; esac       # interactive only
  command -v tmux >/dev/null 2>&1    || return
  [ -t 0 ] && [ -t 1 ]               || return   # real tty on both ends

  # -c only applies when the session is CREATED; attaching to a session that
  # already exists keeps that session's own directory, which is correct.
  local root="${DEV_START_DIR:-${DEV_ROOT:-/srv/dev}}"
  [ -d "$root" ] || root="$HOME"
  tmux new-session -A -s dev -c "$root"
}
# NOTE: __auto_tmux is only *defined* here. The call that runs it is appended
# at the very end of the script — see "rc.sh tail" — because it never returns.
RCFILE

  # Hook into .bashrc exactly once, replacing any previous block. The "old
  # shell config" section above already stripped these, unless it was skipped.
  touch "$HOME/.bashrc"
  strip_block "$HOME/.bashrc"
  {
    echo "$MARKER"
    echo "[ -f \"$CONF_DIR/rc.sh\" ] && . \"$CONF_DIR/rc.sh\""
    echo "$MARKER_END"
  } >> "$HOME/.bashrc"

  # ------------------------------------------------- login-shell wiring -----
  # A *login* shell (ssh host, `bash -l`, a console login) reads the FIRST of
  # ~/.bash_profile, ~/.bash_login, ~/.profile that exists — and stops there.
  # Ubuntu's stock ~/.profile sources ~/.bashrc, so everything works out of the
  # box. But the moment a ~/.bash_profile appears (hand-written, or dropped in
  # by an installer) ~/.profile is skipped entirely, and unless that file
  # sources ~/.bashrc itself the login shell gets NO aliases, NO prompt and NO
  # PATH from this bootstrap. That failure is silent and very easy to misread
  # as "the script didn't install anything".
  login_rc="$(login_rc_path)" || { login_rc="$HOME/.bash_profile"; touch "$login_rc"; }
  # LOGIN_HAD_OURS was recorded before the blocks were stripped, so a re-run
  # reports "refreshed" instead of re-raising the first-run warning every time.
  grep -qF "$MARKER" "$login_rc" 2>/dev/null && LOGIN_HAD_OURS=1
  strip_block "$login_rc"
  if grep -qE '^[^#]*(\.|source)[[:space:]]+.*\.bashrc' "$login_rc"; then
    sub "$(basename "$login_rc") already sources ~/.bashrc"
  else
    {
      echo ""
      echo "$MARKER"
      echo "# A login shell does not read ~/.bashrc on its own. Without this,"
      echo "# aliases (ll, la, gs...), the prompt and PATH are missing on login."
      echo '[ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"'
      echo "$MARKER_END"
    } >> "$login_rc"
    if (( LOGIN_HAD_OURS )); then
      sub "$(basename "$login_rc") -> ~/.bashrc bridge refreshed"
    else
      warn "$(basename "$login_rc") did not source ~/.bashrc — added it"
      sub "this is why 'll' and the prompt were missing on login"
    fi
  fi

  # A hand-rolled `exec tmux` in the login file runs before our block and never
  # returns, so flag it rather than silently fighting it.
  if grep -qE '^[^#]*exec[[:space:]]+tmux' "$login_rc"; then
    warn "$(basename "$login_rc") runs 'exec tmux' before anything else"
    sub "it replaces the shell, so lines after it never execute"
    sub "it also competes with this script's own tmux autostart (session 'dev')"
    sub "keep one of the two: either remove that block, or set DEV_TMUX_AUTOSTART=0"
  fi
fi

# ============================================================ completions ===
# Generated once, here, instead of `eval "$(gh completion -s bash)"` on every
# shell start — each of those is a fork, and they add up on a slow box.
if [[ "$SKIP_SHELL_CONF" != "1" ]]; then
  log "Generating shell completions"
  COMP_DIR="$CONF_DIR/completions"
  rm -rf "$COMP_DIR"; mkdir -p "$COMP_DIR"
  gen_comp() {                          # gen_comp <name> <command...>
    local name="$1"; shift
    local tmp; tmp="$(mktemp)"
    if "$@" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      mv "$tmp" "$COMP_DIR/${name}.bash"; sub "$name"
    else
      rm -f "$tmp"
    fi
  }
  have gh   && gen_comp gh   gh completion -s bash
  have npm  && gen_comp npm  npm completion
  have uv   && gen_comp uv   uv generate-shell-completion bash
  have uvx  && gen_comp uvx  uvx --generate-shell-completion bash
  have just && gen_comp just just --completions bash
  have rg   && gen_comp rg   rg --generate complete-bash
  have pipx && gen_comp pipx bash -c 'register-python-argcomplete pipx'
  compgen -G "$COMP_DIR/*.bash" >/dev/null || sub "(none generated)"
fi

# =============================================================== inputrc ====
# Readline behaviour. This is the single highest-value quality-of-life change
# on a bare Ubuntu box and costs nothing at runtime.
if [[ "$SKIP_INPUTRC" != "1" ]]; then
  log "Writing ~/.inputrc"
  claim "$HOME/.inputrc" && cat > "$HOME/.inputrc" <<'INPUTRC'
# ~/.inputrc — managed by dev-bootstrap.sh
$include /etc/inputrc

# ---- completion -------------------------------------------------------------
set completion-ignore-case on        # Tab-complete regardless of case
set completion-map-case on           # treat - and _ as equivalent while doing so
set show-all-if-ambiguous on         # one Tab lists matches, no double-tap
set show-all-if-unmodified on
set completion-query-items 200
set page-completions off
set colored-stats on                 # colour completions by file type
set colored-completion-prefix on
set visible-stats on                 # append / @ * to completion entries
set mark-symlinked-directories on
set skip-completed-text on           # don't duplicate text you already typed
set match-hidden-files off           # bare Tab doesn't spray dotfiles

# ---- editing ----------------------------------------------------------------
set bell-style none
set enable-bracketed-paste on        # pasted newlines don't auto-execute
set echo-control-characters off
set horizontal-scroll-mode off

# ---- history search on the arrow keys ---------------------------------------
# Type a prefix, then Up: cycles only through history entries starting with it.
# With an empty line it behaves exactly like plain Up/Down, so nothing is lost.
"\e[A": history-search-backward
"\e[B": history-search-forward
"\eOA": history-search-backward
"\eOB": history-search-forward

# ---- word-wise movement (Ctrl / Alt + arrows) -------------------------------
"\e[1;5C": forward-word
"\e[1;5D": backward-word
"\e[1;3C": forward-word
"\e[1;3D": backward-word
"\e[5C":   forward-word
"\e[5D":   backward-word
"\e[3;5~": kill-word
"\e[3~":   delete-char

# ---- home / end in every terminal flavour -----------------------------------
"\e[H": beginning-of-line
"\e[F": end-of-line
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\eOH": beginning-of-line
"\eOF": end-of-line
INPUTRC
fi

# =========================================================== editor config ==
if [[ "$SKIP_EDITOR_CONF" != "1" ]]; then
  log "Configuring editors, bat theme and psql"

  # ----------------------------------------------------------- bat theme ----
  # bat has no built-in Catppuccin; fetch the .tmTheme and rebuild its cache.
  # The resolved name is written to theme.sh so the shell never has to probe
  # (an unknown BAT_THEME makes bat warn on every single invocation).
  bat_bin="$(command -v batcat || command -v bat || true)"
  if [[ -n "$bat_bin" ]]; then
    bat_cfg="$("$bat_bin" --config-dir)"
    if ! "$bat_bin" --list-themes --color=never 2>/dev/null | grep -qx "Catppuccin Mocha"; then
      mkdir -p "$bat_cfg/themes"
      if curl -fsSL --max-time 30 -o "$bat_cfg/themes/Catppuccin Mocha.tmTheme" \
           "https://raw.githubusercontent.com/catppuccin/bat/main/themes/Catppuccin%20Mocha.tmTheme"; then
        "$bat_bin" cache --build >/dev/null 2>&1 || true
      else
        warn "could not fetch the Catppuccin bat theme — using OneHalfDark"
        rm -f "$bat_cfg/themes/Catppuccin Mocha.tmTheme"
      fi
    fi
    if "$bat_bin" --list-themes --color=never 2>/dev/null | grep -qx "Catppuccin Mocha"; then
      echo 'export BAT_THEME="Catppuccin Mocha"' > "$CONF_DIR/theme.sh"
    else
      echo 'export BAT_THEME="OneHalfDark"' > "$CONF_DIR/theme.sh"
    fi
  fi

  # ---------------------------------------------------------------- nano ----
  # nano accepts #rgb (12-bit) on any 256-colour terminal but rejects #rrggbb
  # unless TERM advertises direct colour — under tmux-256color a hex-heavy
  # nanorc errors on every launch. These are Catppuccin rounded to 12-bit.
  claim "$HOME/.nanorc" && cat > "$HOME/.nanorc" <<'NANORC'
## ~/.nanorc — managed by dev-bootstrap.sh

## --- behaviour -------------------------------------------------------------
set linenumbers          # line numbers in the margin
set mouse                # click to position cursor, drag to select
set softwrap             # wrap long lines visually...
set atblanks             # ...at word boundaries, not mid-word
set tabstospaces
set tabsize 4
set autoindent
set smarthome            # Home toggles: first character <-> column 1
set trimblanks           # strip trailing whitespace on wrapped lines
set zap                  # Del/Backspace remove the whole selection
set indicator            # scrollbar-style position indicator
set minibar              # filename + position in the bottom bar
set stateflags           # show modified/insert flags in the minibar
set historylog           # remember search/replace history
set positionlog          # reopen files at the last cursor position
set multibuffer          # ^R reads into a new buffer
set nonewlines           # don't silently add a trailing newline
set wordbounds           # smarter ctrl+arrow word jumps
set casesensitive
set tabsize 4

## --- syntax highlighting ---------------------------------------------------
include /usr/share/nano/*.nanorc
include /usr/share/nano/extra/*.nanorc

## --- colours (Catppuccin Mocha, 3-digit hex) ------------------------------
## nano accepts #rgb (12-bit) on any 256-colour terminal, but rejects #rrggbb
## unless TERM advertises direct colour. These are Mocha rounded to 12-bit.
set titlecolor      bold,#112,#8bf
set promptcolor     bold,#112,#caf
set statuscolor     bold,#112,#ae9
set errorcolor      bold,#fff,#f8a
set selectedcolor   #112,#8bf
set spotlightcolor  #112,#fea
set numbercolor     #667
set keycolor        #9ed
set functioncolor   #ae9
set scrollercolor   #8bf
set stripecolor     ,#333
set minicolor       bold,#cdf

## --- handy keys ------------------------------------------------------------
## Familiar desktop-style shortcuts on top of nano's defaults.
bind ^S savefile main
bind ^Q exit all
bind ^F whereis all
bind ^H replace all
bind ^Z undo main
bind ^Y redo main
bind ^A mark main
bind ^C copy main
bind ^X cut main
bind ^V paste all
bind ^G gotoline main
bind ^D chopwordright main
bind ^L linter main
unbind ^J main
NANORC

  # Self-repair: nano 7.2 (24.04) and 8.x (26.04) differ on which colour forms
  # and function names they accept. Comment out whatever this nano rejects
  # rather than shipping a config that errors on every launch.
  for _ in 1 2 3; do
    nano_err="$(TERM=vt100 timeout 5 nano --rcfile="$HOME/.nanorc" /dev/null </dev/null 2>&1 \
                | strings | grep -oE "on line [0-9]+" | awk '{print $3}' | sort -run)"
    [[ -z "$nano_err" ]] && break
    while read -r ln; do
      [[ -n "$ln" ]] && sed -i "${ln}s|^|## unsupported by nano $(nano --version | head -1 | awk '{print $NF}'): |" "$HOME/.nanorc"
    done <<< "$nano_err"
    warn "nano rejected rc lines ($(tr '\n' ' ' <<< "$nano_err")) — commented out"
  done

  # --------------------------------------------------------------- micro ----
  if have micro; then
    mkdir -p "$HOME/.config/micro/colorschemes"
    claim "$HOME/.config/micro/colorschemes/catppuccin-mocha.micro" && \
    cat > "$HOME/.config/micro/colorschemes/catppuccin-mocha.micro" <<'MICROTHEME'
color-link default              "#cdd6f4,#1e1e2e"
color-link comment              "#6c7086"
color-link identifier           "#89b4fa"
color-link identifier.class     "#f9e2af"
color-link identifier.macro     "#f38ba8"
color-link identifier.var       "#cdd6f4"
color-link constant             "#fab387"
color-link constant.number      "#fab387"
color-link constant.string      "#a6e3a1"
color-link constant.string.char "#94e2d5"
color-link constant.bool        "#fab387"
color-link statement            "#cba6f7"
color-link preproc              "#f38ba8"
color-link type                 "#f9e2af"
color-link type.keyword         "#cba6f7"
color-link special              "#f5c2e7"
color-link symbol               "#94e2d5"
color-link symbol.brackets      "#9399b2"
color-link symbol.tag           "#89b4fa"
color-link symbol.operator      "#89dceb"
color-link error                "bold #f38ba8"
color-link todo                 "bold #f9e2af"
color-link ignore               "#cdd6f4"
color-link underlined           "underline #89b4fa"

color-link statusline           "#1e1e2e,#89b4fa"
color-link statusline.inactive  "#a6adc8,#313244"
color-link tabbar               "#cdd6f4,#181825"
color-link tabbar.active        "bold #1e1e2e,#89b4fa"
color-link indent-char          "#45475a"
color-link line-number          "#6c7086,#1e1e2e"
color-link current-line-number  "bold #89b4fa,#1e1e2e"
color-link cursor-line          "#313244"
color-link color-column         "#313244"
color-link divider              "#45475a"
color-link scrollbar            "#585b70"
color-link gutter-error         "#f38ba8"
color-link gutter-warning       "#f9e2af"
color-link line-length-indicator "#313244"

color-link selection            "#cdd6f4,#585b70"
color-link hlsearch             "#1e1e2e,#f9e2af"
color-link match-brace          "bold #1e1e2e,#89b4fa"
color-link message              "#a6e3a1,#1e1e2e"
color-link error-message        "#1e1e2e,#f38ba8"

color-link diff-added           "#a6e3a1"
color-link diff-modified        "#f9e2af"
color-link diff-deleted         "#f38ba8"
MICROTHEME
    # JSON takes no comments, so this one carries no marker of ours: the
    # backup below is made once, on the first run, and never refreshed.
    claim "$HOME/.config/micro/settings.json" && \
    cat > "$HOME/.config/micro/settings.json" <<'MICROSET'
{
    "colorscheme": "catppuccin-mocha",
    "autoindent": true,
    "autosave": 0,
    "clipboard": "terminal",
    "cursorline": true,
    "diffgutter": true,
    "eofnewline": true,
    "ignorecase": true,
    "smartpaste": true,
    "hlsearch": true,
    "incsearch": true,
    "keepautoindent": true,
    "matchbrace": true,
    "mouse": true,
    "mkparents": true,
    "rmtrailingws": true,
    "ruler": true,
    "relativeruler": false,
    "savecursor": true,
    "saveundo": true,
    "scrollbar": true,
    "softwrap": true,
    "wordwrap": true,
    "statusformatl": "$(filename) $(modified)($(line),$(col)) $(opt:filetype)",
    "statusformatr": "$(bind:ToggleKeyMenu): bindings, $(bind:ToggleHelp): help",
    "sucmd": "sudo",
    "syntax": true,
    "tabmovement": true,
    "tabsize": 4,
    "tabstospaces": true,
    "*.md": { "softwrap": true, "wordwrap": true, "tabstospaces": true },
    "*.go": { "tabstospaces": false },
    "*.py": { "tabsize": 4, "tabstospaces": true },
    "*.sql": { "tabsize": 4, "tabstospaces": true },
    "Makefile": { "tabstospaces": false }
}
MICROSET
  fi

  # ---------------------------------------------------------------- psql ----
  claim "$HOME/.psqlrc" && cat > "$HOME/.psqlrc" <<'PSQLRC'
-- ~/.psqlrc — managed by dev-bootstrap.sh
\set QUIET 1

\pset null '[null]'
\pset linestyle unicode
\pset border 2
\timing on

\set COMP_KEYWORD_CASE lower
\set HISTFILE ~/.psql_history- :DBNAME
\set HISTCONTROL ignoredups
\set HISTSIZE 20000
\set VERBOSITY verbose
\set ON_ERROR_ROLLBACK interactive
\set PROMPT1 '%[%033[38;5;183m%]%n%[%033[0m%]@%[%033[38;5;117m%]%/%[%033[0m%] %# '
\set PROMPT2 '  ... %# '

-- shortcuts
\set version 'select version();'
\set activity 'select pid, age(clock_timestamp(), query_start) as age, usename, state, left(query, 80) as query from pg_stat_activity where query != \'<IDLE>\' and query not ilike \'%pg_stat_activity%\' order by age desc;'
\set locks 'select l.pid, d.datname, l.mode, l.granted, left(a.query, 60) as query from pg_locks l join pg_stat_activity a using (pid) left join pg_database d on d.oid = l.database order by l.pid;'
\set dbsize 'select datname, pg_size_pretty(pg_database_size(datname)) as size from pg_database order by pg_database_size(datname) desc;'
\set tablesize 'select schemaname, relname, pg_size_pretty(pg_total_relation_size(relid)) as total from pg_catalog.pg_statio_user_tables order by pg_total_relation_size(relid) desc limit 25;'
\set uptime 'select now() - pg_postmaster_start_time() as uptime;'

\unset QUIET
PSQLRC

  if have pspg; then
    grep -q "PSQL_PAGER" "$CONF_DIR/rc.sh" 2>/dev/null || cat >> "$CONF_DIR/rc.sh" <<'PSPGRC'

# ---- psql pager -------------------------------------------------------------
export PSQL_PAGER='pspg --style=21 --no-mouse --quit-if-one-screen'
export PSPG='--style=21'
PSPGRC
  fi
fi

# ============================================================= rc.sh tail ===
# Must come after EVERY other append to rc.sh. __auto_tmux does not return once
# it attaches, so anything written below its call is dead code on an interactive
# login — which is exactly what happened to the pspg exports above while this
# call still lived at the bottom of the RCFILE heredoc. Keeping the call here,
# past the last writer, makes "the autostart is last" true by construction
# rather than by luck of section ordering.
if [[ "$SKIP_SHELL_CONF" != "1" ]]; then
  cat >> "$CONF_DIR/rc.sh" <<'RCTAIL'

# ---- tmux autostart ---------------------------------------------------------
# Keep this last: __auto_tmux does not return, so later lines would never run.
[ "${DEV_TMUX_AUTOSTART:-1}" = "1" ] && __auto_tmux
RCTAIL
fi

# ============================================================ git config ====
if [[ "$SKIP_GIT_CONF" != "1" ]]; then
log "Configuring git"
# --replace-all, not a plain set: `git config --global key value` FAILS outright
# ("cannot overwrite multiple values with a single value") when the key is in
# the file twice, which is the normal state of a ~/.gitconfig that has been
# hand-edited a few times or merged from two dotfile repos. --replace-all
# collapses the duplicates into our value instead of aborting.
gitset() { git config --global --replace-all "$1" "$2"; }

# An include pulled in AFTER our settings wins over them, and it is not ours
# to edit — so say so rather than leaving you to wonder why a value is ignored.
while IFS= read -r inc; do
  [[ -z "$inc" ]] && continue
  warn "your git config includes ${inc} — anything set there overrides the settings below"
done < <(git config --global --get-all include.path 2>/dev/null)

gitset init.defaultBranch main
gitset pull.rebase true
gitset rebase.autoStash true
gitset fetch.prune true
gitset push.default current
gitset push.autoSetupRemote true
gitset diff.colorMoved zebra
gitset diff.algorithm histogram
gitset diff.mnemonicPrefix true
gitset diff.renames copies
gitset merge.conflictstyle zdiff3
gitset rerere.enabled true
gitset rerere.autoupdate true
gitset core.editor "$DEV_EDITOR"
gitset core.autocrlf input
gitset color.ui auto
gitset column.ui auto
gitset branch.sort -committerdate      # most recent branch first
gitset tag.sort version:refname        # v1.10 after v1.9, not before
gitset log.date iso
gitset commit.verbose true             # show the diff while writing a message
gitset help.autocorrect prompt
gitset credential.helper "cache --timeout=28800"
# safe.directory takes a literal path or a trailing /* (one level, no recursion
# into nested repos). Verified against git 2.53 on a root-owned repo under /srv/dev.
# Added, never --replace-all'd: that would wipe every other safe.directory you
# have. Adding it only when it is missing keeps the list free of duplicates too.
git config --global --get-all safe.directory 2>/dev/null | grep -qxF "${DEV_ROOT}/*" \
  || git config --global --add safe.directory "${DEV_ROOT}/*" || true
gitset alias.st "status -sb"
gitset alias.lg "log --oneline --graph --decorate --all"
gitset alias.last "log -1 HEAD --stat"
gitset alias.unstage "reset HEAD --"
gitset alias.amend "commit --amend --no-edit"
gitset alias.wip "commit -am wip --no-verify"
gitset alias.undo "reset --soft HEAD~1"
gitset alias.branches "branch -a --sort=-committerdate"
gitset alias.recent "for-each-ref --sort=-committerdate --count=15 --format='%(refname:short)  %(committerdate:relative)' refs/heads/"

# delta: syntax-highlighted, side-by-side-capable diff pager. Only wired up if
# it actually installed, and the theme is probed rather than assumed — an
# unknown syntax-theme makes delta fail on every diff.
if have delta; then
  sub "wiring git diffs through delta"
  gitset core.pager "delta"
  gitset interactive.diffFilter "delta --color-only"
  gitset delta.navigate true          # n / N jump between files
  gitset delta.line-numbers true
  gitset delta.hyperlinks false
  gitset delta.dark true
  if delta --list-syntax-themes 2>/dev/null | grep -qx "Catppuccin Mocha"; then
    gitset delta.syntax-theme "Catppuccin Mocha"
  else
    gitset delta.syntax-theme "OneHalfDark"
  fi
  gitset merge.conflictstyle zdiff3
else
  # Leave any previous delta wiring behind rather than pointing core.pager at a
  # binary that is no longer installed. --unset-all, because the same file may
  # carry the key more than once.
  [[ "$(git config --global --get core.pager 2>/dev/null)" == delta* ]] && \
    git config --global --unset-all core.pager
  [[ "$(git config --global --get interactive.diffFilter 2>/dev/null)" == delta* ]] && \
    git config --global --unset-all interactive.diffFilter
fi
# Identity, as collected at the top of the run (env > prompt > what git had).
if [[ -n "$GIT_USER_NAME" && -n "$GIT_USER_EMAIL" ]]; then
  gitset user.name  "$GIT_USER_NAME"
  gitset user.email "$GIT_USER_EMAIL"
  sub "identity: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
else
  [[ -n "$GIT_USER_NAME"  ]] && gitset user.name  "$GIT_USER_NAME"
  [[ -n "$GIT_USER_EMAIL" ]] && gitset user.email "$GIT_USER_EMAIL"
fi
if ! git config --global --get user.email >/dev/null 2>&1; then
  warn "git identity not set — re-run on a terminal to be asked for it, or set it by hand:"
  warn "  git config --global user.name 'Your Name'"
  warn "  git config --global user.email 'you@example.com'"
fi
claim "$HOME/.gitignore_global" && cat > "$HOME/.gitignore_global" <<'GITIGNORE'
# ~/.gitignore_global — managed by dev-bootstrap.sh
.DS_Store
*.swp
*~
.venv/
__pycache__/
node_modules/
.env
.env.local
.direnv/
.claude/settings.local.json
*.pyc
.mypy_cache/
.pytest_cache/
.ruff_cache/
.ipynb_checkpoints/
Thumbs.db
GITIGNORE
gitset core.excludesfile "$HOME/.gitignore_global"
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
# Microsoft's documented way in, but it only reaches the maintainer script if
# sudo passes it through — which is why every install below goes through
# `sudo env`. Seeding the answers as well covers the case where the config
# script never runs (a plain `dpkg -i`, or a package configured out of band).
ms_eula_preseed() {
  have debconf-set-selections || return 0
  printf '%s\n' \
    'msodbcsql18 msodbcsql/ACCEPT_EULA boolean true' \
    'msodbcsql18 msodbcsql/accept_eula boolean true' \
    'mssql-tools18 mssql-tools/accept_eula boolean true' \
    | sudo debconf-set-selections 2>/dev/null
}

# ms_apt_install <target...> — targets are package names or local .deb paths.
# Only mssql-tools18 is ever named: msodbcsql18 comes along as its dependency
# when it is missing and is left alone when it is already installed. Asking for
# msodbcsql18 by name would make apt reinstall it, and its preinst aborts the
# transaction with "ODBC Driver 18 for SQL Server detected!" when the driver is
# already registered with odbcinst.
ms_apt_install() {
  sudo env ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive \
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
    [[ "$pkg" == msodbcsql18 ]] && dpkg -s msodbcsql18 >/dev/null 2>&1 && continue
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
  ms_done=0
  if [[ -x "$MS_BIN/sqlcmd" ]]; then
    log "sqlcmd already installed"
    sub "$MS_BIN/sqlcmd  ($(dpkg-query -W -f='${Version}' mssql-tools18 2>/dev/null || echo 'not from a package'))"
    ms_done=1
  else
    log "Installing the Microsoft SQL tooling"
    ms_eula_preseed

    # ---- route 1: a Microsoft repo that is already configured here ----------
    if apt_installable mssql-tools18; then
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
            sudo tee /etc/apt/preferences.d/mssql-release.pref >/dev/null <<EOF
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
          sudo apt-get update -qq 2>&1 | grep -E '^E:' | sed 's/^/    /'
          if apt_installable mssql-tools18; then
            sub "candidate $(apt_cand mssql-tools18) from ${ms_relver}/${ms_suite}"
            ms_apt_install mssql-tools18 && ms_done=1
          else
            warn "the ${ms_suite} source produced no installable candidate — removing it again"
            sudo rm -f /etc/apt/sources.list.d/mssql-release.sources \
                       /etc/apt/preferences.d/mssql-release.pref
            sudo apt-get update -qq >/dev/null 2>&1 || true
          fi
        fi
      else
        warn "could not download the Microsoft signing keys"
      fi
    fi

    # ---- route 3: the .deb files straight from the pool ---------------------
    if (( ! ms_done )) && [[ -n "$ms_base" ]]; then
      warn "repo route did not work — installing the .deb files from the pool"
      ms_pool_install "$ms_base" "$ms_idx" && ms_done=1
    fi
    [[ -n "$ms_idx" ]] && rm -f "$ms_idx"

    # ---- last resort: go-sqlcmd --------------------------------------------
    if (( ! ms_done )); then
      [[ -n "$ms_base" ]] || warn "no Microsoft repo carries mssql-tools18 for ${ARCH}"
      warn "falling back to go-sqlcmd (static binary: sqlcmd only — no bcp, no ODBC driver)"
      if curl -fsSL --max-time 300 \
           "https://github.com/microsoft/go-sqlcmd/releases/latest/download/sqlcmd-linux-${ARCH}.tar.bz2" \
           | tar xj -C "$HOME/.local/bin" sqlcmd 2>/dev/null; then
        sub "installed $HOME/.local/bin/sqlcmd"
        note_fail "mssql-tools18 (go-sqlcmd installed instead)"
      else
        warn "that failed too — this machine has no sqlcmd"
        note_fail "mssql-tools18"
      fi
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
if [[ "$SKIP_POSTGRES" != "1" ]]; then
  if have psql; then
    log "psql $(psql --version | awk '{print $3}') already present"
  else
    pg_suite="${OS_CODE}-pgdg"
    if curl -fsI --max-time 20 \
         "https://apt.postgresql.org/pub/repos/apt/dists/${pg_suite}/InRelease" >/dev/null 2>&1 \
       && fetch_keys /etc/apt/keyrings/pgdg.asc \
            https://www.postgresql.org/media/keys/ACCC4CF8.asc; then
      log "Installing PostgreSQL client ${PG_MAJOR} (PGDG ${pg_suite})"
      if add_repo /etc/apt/sources.list.d/pgdg.sources \
           "https://apt.postgresql.org/pub/repos/apt" "$pg_suite" main \
           /etc/apt/keyrings/pgdg.asc; then
        sudo apt-get update -qq 2>&1 | grep -E '^E:' | sed 's/^/    /'
      fi
      if apt_installable "postgresql-client-${PG_MAJOR}"; then
        soft "postgresql-client-${PG_MAJOR}" sudo DEBIAN_FRONTEND=noninteractive \
          apt-get install -y -qq "postgresql-client-${PG_MAJOR}" libpq-dev || true
      else
        warn "PGDG has no client ${PG_MAJOR} here — using Ubuntu's"
        soft "postgresql-client" sudo apt-get install -y -qq postgresql-client libpq-dev || true
      fi
    else
      log "No PGDG repo for ${OS_CODE} — using Ubuntu's postgresql-client ($(apt_cand postgresql-client))"
      soft "postgresql-client" sudo apt-get install -y -qq postgresql-client libpq-dev || true
    fi
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
    | sudo tee /etc/sysctl.d/60-inotify.conf >/dev/null
  sudo sysctl --system >/dev/null 2>&1 || true

  # Ubuntu's default soft limit is 1024 open files. tsc --watch, vite, pytest-xdist
  # and several language servers at once blow through that and fail with EMFILE.
  log "Raising the open-file limit (default soft limit is 1024)"
  printf '%s\n' \
    '# managed-by: dev-bootstrap' \
    '*  soft  nofile  65535' \
    '*  hard  nofile  1048576' \
    | sudo tee /etc/security/limits.d/90-dev-nofile.conf >/dev/null
  sub "currently: soft=$(ulimit -Sn) hard=$(ulimit -Hn) (new value applies at next login)"

  if ! grep -q "ServerAliveInterval" "$HOME/.ssh/config" 2>/dev/null; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    printf 'Host *\n    ServerAliveInterval 60\n    ServerAliveCountMax 5\n    AddKeysToAgent yes\n' \
      >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
  fi
fi

# ====================================================== shared dev folder ===
if [[ -d "$DEV_ROOT" ]] && getent group "$DEV_GROUP" >/dev/null 2>&1; then
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$DEV_GROUP"; then
    warn "$USER is not in $DEV_GROUP — sudo usermod -aG $DEV_GROUP $USER (then re-login)"
  fi
fi

# =============================================================== verify =====
log "Final apt health check"
apt_err="$(sudo apt-get update 2>&1 | grep -E '^(E|W):')"
if [[ -n "$apt_err" ]]; then
  printf '%s\n' "$apt_err" | sed 's/^/    /'
  warn "apt reported the above. Re-run with --clean-only to strip our sources."
  note_fail "apt update"
else
  sub "apt update is clean"
fi

# The check that would have caught the silent failure this script now fixes:
# does a real interactive LOGIN shell actually end up with our config loaded?
# SSH_CONNECTION is scrubbed because a hand-written `exec tmux` block in the
# login file is usually gated on it, and would hijack the probe.
#
# The probe MUST NOT share this script's controlling terminal. `bash -i` sets up
# job control at startup: if it cannot find a tty on stderr it opens /dev/tty
# directly, and if that terminal's foreground process group is not its own it
# SIGTTINs itself and waits to be foregrounded. Plain `timeout` puts its child
# in a NEW process group, so the probe is by definition not in the foreground —
# it stops dead, and because a stopped process never acts on SIGTERM the
# `timeout 20` never fires either. Run the script from a real terminal (a tmux
# pane, ssh, the console) and it hangs here forever; run it with output piped
# and it passes, because then /dev/tty cannot be opened at all.
#
# setsid drops the controlling terminal entirely, so job control is never
# initialised and none of the above can happen. `timeout --foreground` also
# works, but leaves an interactive bash free to reprogram the real terminal.
probe_cmd=(bash -lic 'alias ll 2>/dev/null; echo "EDITOR=$EDITOR"')
if have setsid && setsid --help 2>&1 | grep -q -- '--wait'; then
  probe_sh=(setsid --wait timeout -k 5 20 "${probe_cmd[@]}")
else
  # No usable setsid: keep the probe in this script's (foreground) process
  # group instead, so it is never a background reader of the terminal.
  probe_sh=(timeout --foreground -k 5 20 "${probe_cmd[@]}")
fi
log "Login-shell wiring"
probe="$(env -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY \
         "${probe_sh[@]}" </dev/null 2>/dev/null)"
if grep -q "alias ll=" <<<"$probe"; then
  sub "ll / la / lt available on login"
  sub "$(grep -o 'EDITOR=.*' <<<"$probe" | head -1)"
  sub "start folder: $DEV_START_DIR"
else
  warn "a login shell still does not load $CONF_DIR/rc.sh"
  warn "check ~/.bash_profile — something before our block may be exiting early"
  note_fail "login-shell wiring"
fi

echo
log "Installed"
ver() { printf '    %-16s %s\n' "$1" "${2:--}"; }
ver git      "$(git --version 2>/dev/null | awk '{print $3}')"
ver tmux     "$(tmux -V 2>/dev/null | awk '{print $2}')"
ver node     "$(node --version 2>/dev/null)"
ver npm      "$(npm --version 2>/dev/null)"
ver python3  "$(python3 --version 2>/dev/null | awk '{print $2}')"
ver uv       "$("$HOME/.local/bin/uv" --version 2>/dev/null | awk '{print $2}')"
ver claude   "$("$HOME/.local/bin/claude" --version 2>/dev/null | awk '{print $1}')"
ver dotnet   "$(dotnet --list-sdks 2>/dev/null | awk '{print $1}' | tail -1)"
ver psql     "$(psql --version 2>/dev/null | awk '{print $3}')"
# sqlcmd is either the mssql-tools18 build or the go-sqlcmd fallback binary.
sqlcmd_ver="$(/opt/mssql-tools18/bin/sqlcmd -? 2>&1 | awk '/Version/{print $2; exit}')"
[[ -z "$sqlcmd_ver" && -x "$HOME/.local/bin/sqlcmd" ]] && \
  sqlcmd_ver="$("$HOME/.local/bin/sqlcmd" --version 2>/dev/null | awk '{print $NF; exit}') (go-sqlcmd)"
ver sqlcmd   "$sqlcmd_ver"
ver nano     "$(nano --version 2>/dev/null | head -1 | awk '{print $NF}')"
ver micro    "$(micro -version 2>/dev/null | awk -F': ' '/Version/{print $2}')"
ver eza      "$(eza --version 2>/dev/null | awk '/^v/{print $1; exit}')"
ver delta    "$(delta --version 2>/dev/null | awk '{print $2}')"
ver rg       "$(rg --version 2>/dev/null | awk 'NR==1{print $2}')"
ver fzf      "$(fzf --version 2>/dev/null | awk '{print $1}')"
ver gh       "$(gh --version 2>/dev/null | awk 'NR==1{print $3}')"

if (( ${#ADOPTED[@]} )); then
  echo
  log "Config that was already here"
  for a in "${ADOPTED[@]}"; do sub "$a"; done
  sub "the *.pre-bootstrap copies are yours — this script never touches them again"
fi

echo
if (( ${#FAILED_STEPS[@]} )); then
  warn "Did not complete: ${FAILED_STEPS[*]}"
  warn "Everything else is configured. Re-running retries only these."
  echo
fi
log "Next"
sub "exec bash -l                 # pick up PATH, theme, aliases"
sub "ll                           # long listing (also: la lt lt3 ltr lsz ldot)"
sub "claude                       # authenticate once; 'cc' is the shortcut"
sub "touch ~/.no-auto-tmux        # if you don't want tmux on login"
sub "DEV_START_DIR=/path bash $0  # change where logins start"
sub "\$EDITOR ~/.config/dev-bootstrap/local.sh   # your own aliases, never overwritten"
sub "ls ~/.*.pre-bootstrap        # the config you had before the first run"
sub "bash $0 --clean-only         # remove this script's apt sources"