#!/usr/bin/env bash
# HELP>
# dev-bootstrap-user.sh (v6) — the per-user half of the Ubuntu dev bootstrap
#
# Run as YOURSELF — not root, not with sudo. It needs no sudo at all: it only
# writes to your home directory. Run dev-bootstrap-system.sh (as root) on the
# machine first; this one configures what that one installed.
#
#   bash dev-bootstrap-user.sh             # everything
#   bash dev-bootstrap-user.sh --help
#
#   DEV_EDITOR=micro bash dev-bootstrap-user.sh
#   DEV_EXTRAS_UPGRADE=1 bash dev-bootstrap-user.sh   # re-fetch mise and bash-preexec
#
# What it does: your shell, tmux, editor, git, psql and Claude Code config;
# per-user tools (npm globals in ~/.local, uv and pipx tools, .NET global
# tools, mise, Claude Code / OpenAI Codex). It ends by removing dangling links
# and stale copies in ~/.local/bin that the system install now provides.
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
#   SKIP_LEGACY_CLEAN=1 bash dev-bootstrap-user.sh   # leave all of the above alone
#   DEV_TMUX_RESET=0    bash dev-bootstrap-user.sh   # never touch a running server
#
# The global git identity (user.name / user.email) is asked for interactively
# near the start of the run. To answer it up front instead:
#
#   GIT_USER_NAME='Your Name' GIT_USER_EMAIL=you@example.com bash dev-bootstrap-user.sh
#   SKIP_GIT_IDENTITY=1 bash dev-bootstrap-user.sh    # never ask, leave git alone
#
# It also asks which folder a login should start in: the folder the tmux
# session opens in, and the one a login shell cds to when tmux is off. The
# answer is remembered, so every re-run after the first is just Enter.
#
#   DEV_START_DIR=/srv/dev/app bash dev-bootstrap-user.sh   # answer up front
#   SKIP_START_DIR=1 bash dev-bootstrap-user.sh             # never ask
#
# And it asks which AI coding agent to install: Claude Code, OpenAI Codex,
# both, or none. That answer is remembered too.
#
#   DEV_AI_AGENTS=both bash dev-bootstrap-user.sh    # claude | codex | both | none
#   SKIP_CLAUDE=1 / SKIP_CODEX=1                     # veto one regardless of the answer
#
# Last, it asks for your SSH public key and adds it to ~/.ssh/authorized_keys
# (Enter skips it):
#
#   DEV_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" bash dev-bootstrap-user.sh
#
# Deliberately NOT using `set -e`: one failing step must never leave the
# setup half-done. Failures are collected and reported at the end.
#
# <HELP
set -uo pipefail

# ---------------------------------------------------------------- settings --
DEV_ROOT="${DEV_ROOT:-/srv/dev}"
DEV_GROUP="${DEV_GROUP:-devgroup}"
DOTNET_TOOLS="${DOTNET_TOOLS:-csharp-ls dotnet-ef}"
DEV_EDITOR="${DEV_EDITOR:-nano}"        # nano | micro | nvim
DEV_TMUX_AUTOSTART="${DEV_TMUX_AUTOSTART:-1}"
DEV_START_DIR="${DEV_START_DIR:-}"      # empty = ask; where a login lands
DEV_AI_AGENTS="${DEV_AI_AGENTS:-}"      # empty = ask; claude | codex | both | none
CLAUDE_PLUGINS="${CLAUDE_PLUGINS:-pyright-lsp typescript-lsp csharp-lsp}"
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
DEV_SSH_PUBKEY="${DEV_SSH_PUBKEY:-}"   # empty = ask; a public key for ~/.ssh/authorized_keys
SKIP_NODE="${SKIP_NODE:-0}"             # the npm globals
SKIP_PYTHON="${SKIP_PYTHON:-0}"
SKIP_DOTNET="${SKIP_DOTNET:-0}"         # the .NET global tools
SKIP_EXTRAS="${SKIP_EXTRAS:-0}"         # mise, bash-preexec, tldr cache, atuin import
DEV_EXTRAS_UPGRADE="${DEV_EXTRAS_UPGRADE:-0}"   # 1 = re-download mise and bash-preexec
SKIP_CLAUDE="${SKIP_CLAUDE:-0}"
SKIP_CODEX="${SKIP_CODEX:-0}"
SKIP_CLAUDE_CONF="${SKIP_CLAUDE_CONF:-0}"
SKIP_TMUX_CONF="${SKIP_TMUX_CONF:-0}"
SKIP_SHELL_CONF="${SKIP_SHELL_CONF:-0}"
SKIP_EDITOR_CONF="${SKIP_EDITOR_CONF:-0}"
SKIP_GIT_CONF="${SKIP_GIT_CONF:-0}"
SKIP_GIT_IDENTITY="${SKIP_GIT_IDENTITY:-0}"
SKIP_INPUTRC="${SKIP_INPUTRC:-0}"
SKIP_LEGACY_CLEAN="${SKIP_LEGACY_CLEAN:-0}"   # 1 = leave old config in place
SKIP_START_DIR="${SKIP_START_DIR:-0}"         # 1 = never ask for a start folder
DEV_TMUX_RESET="${DEV_TMUX_RESET:-1}"         # 0 = do not touch a running server

CONF_DIR="$HOME/.config/dev-bootstrap"
MARKER="# >>> dev-bootstrap >>>"
MARKER_END="# <<< dev-bootstrap <<<"
BACKUP_SUFFIX=".pre-bootstrap"
START_DIR_STATE="$CONF_DIR/start-dir"   # remembers the answer between runs
AI_AGENTS_STATE="$CONF_DIR/ai-agents"   # remembers the agent choice between runs

for arg in "$@"; do
  case "$arg" in
    --help|-h) if [[ -r "$0" ]]; then
                 sed -n '/^# HELP>$/,/^# <HELP$/p' "$0" | sed '1d;$d; s/^# \{0,1\}//'
               else
                 echo "Reading the script from stdin — save it to a file for the help text:"
                 echo "  curl -fsSL <url> -o dev-bootstrap-user.sh && bash dev-bootstrap-user.sh --help"
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

# ============================================================== preflight ===
[[ $EUID -eq 0 ]] && die "Run as your normal user, not root. The root half is dev-bootstrap-system.sh."
for t in git jq tmux curl; do
  have "$t" || die "$t is missing — run dev-bootstrap-system.sh (as root) on this machine first."
done
log "Host"
sub "$(hostname) — user ${USER}"

mkdir -p "$CONF_DIR" "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
# Ubuntu ships these under alternate binary names.
[[ -x /usr/bin/fdfind ]] && ln -sf /usr/bin/fdfind "$HOME/.local/bin/fd"
[[ -x /usr/bin/batcat ]] && ln -sf /usr/bin/batcat "$HOME/.local/bin/bat"

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

if [[ "$SKIP_GIT_CONF" != "1" \
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

if [[ "$SKIP_START_DIR" != "1" && -z "$DEV_START_DIR" ]] \
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
printf '%s\n' "$DEV_START_DIR" > "$START_DIR_STATE" 2>/dev/null || true

# ---------------------------------------------------------- coding agents ---
# Which AI coding agent to install: Claude Code, OpenAI Codex, both, or none.
# Asked here with the other questions, for the same reason they are.
#
# Precedence: DEV_AI_AGENTS from the environment wins outright and suppresses
# the prompt, then the answer from the last run, then "claude". The choice only
# governs INSTALLATION — an agent that is already on the machine is never
# removed, and the config sections still apply to whatever is present.
# SKIP_CLAUDE=1 / SKIP_CODEX=1 veto an install regardless of the answer.
ai_agents_default="$DEV_AI_AGENTS"
[[ -z "$ai_agents_default" && -s "$AI_AGENTS_STATE" ]] && \
  ai_agents_default="$(head -1 "$AI_AGENTS_STATE")"
[[ -z "$ai_agents_default" ]] && ai_agents_default="claude"

if [[ -z "$DEV_AI_AGENTS" ]] \
   && (exec </dev/tty) 2>/dev/null; then
  log "AI coding agents"
  sub "claude = Claude Code, codex = OpenAI Codex, both, or none"
  ai_answer=""                          # ask_tty fills this in with printf -v
  while :; do
    ask_tty ai_answer "Which?" "$ai_agents_default"
    ai_answer="${ai_answer,,}"
    case "$ai_answer" in
      claude|codex|both|none) DEV_AI_AGENTS="$ai_answer"; break ;;
      *) warn "answer claude, codex, both or none" ;;
    esac
  done
fi

# Nothing was asked (no terminal, or a value from the environment): settle on
# the default and validate it the same way.
[[ -z "$DEV_AI_AGENTS" ]] && DEV_AI_AGENTS="$ai_agents_default"
DEV_AI_AGENTS="${DEV_AI_AGENTS,,}"
case "$DEV_AI_AGENTS" in
  claude|codex|both|none) ;;
  *) warn "DEV_AI_AGENTS='$DEV_AI_AGENTS' is not claude/codex/both/none — using claude"
     DEV_AI_AGENTS="claude" ;;
esac
INSTALL_CLAUDE=0; INSTALL_CODEX=0
[[ "$DEV_AI_AGENTS" == "claude" || "$DEV_AI_AGENTS" == "both" ]] && INSTALL_CLAUDE=1
[[ "$DEV_AI_AGENTS" == "codex"  || "$DEV_AI_AGENTS" == "both" ]] && INSTALL_CODEX=1
[[ "$SKIP_CLAUDE" == "1" ]] && INSTALL_CLAUDE=0
[[ "$SKIP_CODEX"  == "1" ]] && INSTALL_CODEX=0
# Remembered so the next run can offer it as the default, and so this stays
# put when a later run has no terminal to ask from.
printf '%s\n' "$DEV_AI_AGENTS" > "$AI_AGENTS_STATE" 2>/dev/null || true

# ----------------------------------------------------------- ssh public key -
# The key you log in to this machine with, added to ~/.ssh/authorized_keys.
# DEV_SSH_PUBKEY answers up front; Enter at the prompt skips it. Asked every
# run, because a key already in the file is simply reported as such.
#
# ssh_key_ok <line> — one public key line, nothing else: no options prefix, no
# second line, and ssh-keygen must be able to read it.
ssh_key_ok() {
  [[ "$1" != *$'\n'* ]] || return 1
  [[ "$1" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] || return 1
  ssh-keygen -l -f - <<<"$1" >/dev/null 2>&1
}
if [[ -z "$DEV_SSH_PUBKEY" ]] && (exec </dev/tty) 2>/dev/null; then
  log "SSH public key"
  sub "paste the ONE line from your id_ed25519.pub (or id_rsa.pub) to log in with"
  sub "it — Enter to skip"
  while :; do
    ssh_answer=""                        # ask_tty fills this in with printf -v
    ask_tty ssh_answer "Key" ""
    [[ -z "$ssh_answer" ]] && break
    if ssh_key_ok "$ssh_answer"; then DEV_SSH_PUBKEY="$ssh_answer"; break; fi
    if [[ "$ssh_answer" == *PRIVATE* ]]; then
      warn "that is a PRIVATE key — it never leaves your own computer. Paste the .pub file."
    else
      warn "that is not a public key line"
    fi
    # A multi-line paste would otherwise feed its remaining lines to the next prompts.
    while IFS= read -r -t 0.3 _ </dev/tty; do :; done
  done
fi

# ==================================================================== node ==
# Node itself comes from the system half (NodeSource); the globals live in
# ~/.local, per user.
if [[ "$SKIP_NODE" != "1" ]]; then
  if have npm; then
    npm config set prefix "$HOME/.local" >/dev/null 2>&1 || true
    npm config set fund false >/dev/null 2>&1 || true
    log "Installing / updating global npm tooling"
    # pyright and typescript-language-server are here for a reason: the
    # pyright-lsp / typescript-lsp plugins only *declare* the server command,
    # they never install it. Without these two the plugins load and do nothing.
    # typescript stays on 6: 7 is the native compiler and ships no tsserver.js,
    # so outside a project with its own typescript the language server falls
    # back to the global one and exits ("Could not find a valid TypeScript").
    # shortcut: typescript pinned to 6; move to latest once typescript-language-server runs on 7.
    # yarn: Node 26 ships no corepack, so `yarn` has to come from npm.
    NPM_GLOBALS=(npm@latest pnpm yarn typescript@6 tsx typescript-language-server pyright
                 eslint prettier npm-check-updates nodemon pm2 mssql @ast-grep/cli)
    # Globals an older version of this script installed and this one does not:
    # removed, so a re-run lands on NPM_GLOBALS rather than on whatever piled up.
    NPM_RETIRED=(ts-node)
    for p in "${NPM_RETIRED[@]}"; do
      [[ -d "$HOME/.local/lib/node_modules/$p" ]] || continue
      npm uninstall -g --silent "$p" >/dev/null 2>&1 && sub "removed retired global: $p"
    done
    if ! npm install -g --silent "${NPM_GLOBALS[@]}" 2>/dev/null; then
      # npm installs all or nothing, so one bad package would cost every other.
      warn "bulk npm install failed — retrying one by one"
      for p in "${NPM_GLOBALS[@]}"; do
        npm install -g --silent "$p" >/dev/null 2>&1 || { warn "  could not install: $p"; note_fail "npm:$p"; }
      done
    fi
    # @ast-grep/cli ships as both `ast-grep` and `sg`. The latter shadows
    # /usr/bin/sg (the setgid helper) in interactive shells — harmless, but
    # worth knowing; scripts still get the system one.
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
      # Upgrade first: `pipx install` of a tool that is already there changes
      # nothing and still exits 0, so it never reached the upgrade.
      pipx upgrade "$pkg" >/dev/null 2>&1 || pipx install "$pkg" >/dev/null 2>&1 \
        || { warn "pipx: $pkg failed"; note_fail "pipx:$pkg"; }
    done
    # harlequin: a TUI SQL IDE. The postgres adapter comes as an extra, the
    # SQL Server one (through the msodbcsql18 driver) as a separate package.
    if pipx list --short 2>/dev/null | grep -q '^harlequin '; then
      pipx upgrade harlequin >/dev/null 2>&1 || true
    else
      pipx install 'harlequin[postgres]' >/dev/null 2>&1 \
        || { warn "pipx: harlequin failed"; note_fail "pipx:harlequin"; }
    fi
    have harlequin && pipx inject harlequin harlequin-odbc >/dev/null 2>&1 || true
  fi
fi

# =================================================================== .NET ===
# The SDK comes from the system half when the distro carries one. When it does
# not, Microsoft's installer puts a private copy in ~/.dotnet.
if [[ "$SKIP_DOTNET" != "1" ]]; then
  if ! have dotnet && [[ ! -x "$HOME/.dotnet/dotnet" ]]; then
    log "No system .NET SDK — using Microsoft's installer (~/.dotnet)"
    soft "dotnet (dot.net installer)" bash -c \
      'curl -fsSL --max-time 300 https://dot.net/v1/dotnet-install.sh \
         | bash -s -- --channel LTS --install-dir "$HOME/.dotnet" --no-path' || true
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
if [[ "$INSTALL_CLAUDE" == "1" ]]; then
  if have claude || [[ -x "$HOME/.local/bin/claude" ]]; then
    log "Claude Code already present ($("$HOME/.local/bin/claude" --version 2>/dev/null | awk '{print $1}'))"
  else
    log "Installing Claude Code (native installer, per-user, auto-updating)"
    soft "claude-code" bash -c 'curl -fsSL --max-time 120 https://claude.ai/install.sh | bash' || true
  fi
fi

# ============================================================ openai codex ==
# An npm global (OpenAI's install channel besides Homebrew), so it lands in
# ~/.local/bin like the other npm tools and every re-run upgrades it. That
# makes it depend on the node section — with SKIP_NODE=1 on a box without npm
# there is nothing to install with, and the run says so.
if [[ "$INSTALL_CODEX" == "1" ]]; then
  if have npm; then
    log "Installing / updating OpenAI Codex (npm global, per-user)"
    soft "openai-codex" npm install -g --silent @openai/codex || true
  elif have codex || [[ -x "$HOME/.local/bin/codex" ]]; then
    log "OpenAI Codex already present ($("$HOME/.local/bin/codex" --version 2>/dev/null | awk '{print $NF}')) — no npm to update it with"
  else
    warn "OpenAI Codex is installed via npm, and npm is missing — re-run without SKIP_NODE=1"
    note_fail "openai-codex"
  fi
fi

# ============================================================ extra tools ===
# The tools themselves come from the system half; what is per user is here.
if [[ "$SKIP_EXTRAS" != "1" ]]; then
  log "Extra tools (per-user parts)"
  # mise: one version manager for node/python/go/... driven by a .mise.toml in
  # the project. It does nothing until a project pins a tool, so the apt node
  # and dotnet stay the defaults. Its own installer, because the release
  # assets are per-libc and it self-updates from there.
  if [[ "$DEV_EXTRAS_UPGRADE" != "1" ]] && have mise; then
    sub "$(printf '%-11s' mise) already present"
  else
    soft "mise" \
      bash -c 'curl -fsSL --max-time 120 https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh >/dev/null 2>&1' \
      && sub "$(printf '%-11s' mise) $("$HOME/.local/bin/mise" --version 2>/dev/null | awk '{print $1}')"
  fi

  # bash-preexec: atuin's hook into bash. Not packaged; one file, pinned to
  # master like upstream's own instructions.
  if [[ "$DEV_EXTRAS_UPGRADE" == "1" || ! -s "$CONF_DIR/bash-preexec.sh" ]]; then
    curl -fsSL --max-time 30 -o "$CONF_DIR/bash-preexec.sh.new" \
        https://raw.githubusercontent.com/rcaloras/bash-preexec/master/bash-preexec.sh \
      && grep -q '__bp_install' "$CONF_DIR/bash-preexec.sh.new" \
      && mv "$CONF_DIR/bash-preexec.sh.new" "$CONF_DIR/bash-preexec.sh" \
      && sub "$(printf '%-11s' bash-preexec) fetched" \
      || { rm -f "$CONF_DIR/bash-preexec.sh.new"; warn "could not fetch bash-preexec — atuin will not record history"; note_fail "bash-preexec"; }
  fi

  # tealdeer needs its page cache before the first `tldr`.
  have tldr && { tldr --update >/dev/null 2>&1 || warn "tldr: could not fetch the page cache"; }

  # atuin: pull the existing bash history in once, so Ctrl-R is useful from
  # the first shell rather than starting empty.
  if have atuin && [[ ! -s "$HOME/.local/share/atuin/history.db" ]]; then
    atuin import auto >/dev/null 2>&1 && sub "$(printf '%-11s' atuin) imported ~/.bash_history"
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
  #
  # Every claude call gets </dev/null and a --foreground timeout. claude puts a
  # TTY it finds on stdin into raw mode, and a plain `timeout` runs its child in
  # a background process group — so that child gets SIGTTOU the moment it
  # touches the terminal and is STOPPED by the kernel, not killed. The timeout
  # never fires on a stopped process, and the script sits there forever.
  if ! claude plugin marketplace list </dev/null 2>/dev/null | grep -qF claude-plugins-official; then
    sub "adding the claude-plugins-official marketplace"
    timeout --foreground 180 claude plugin marketplace add anthropics/claude-plugins-official </dev/null >/dev/null 2>&1 \
      || warn "could not add the plugin marketplace"
  fi
  for cc_plug in $CLAUDE_PLUGINS; do
    if claude plugin list </dev/null 2>/dev/null | grep -qF "$cc_plug"; then
      sub "plugin ${cc_plug} already installed"
    else
      sub "installing plugin ${cc_plug}"
      timeout --foreground 180 claude plugin install "${cc_plug}@claude-plugins-official" </dev/null >/dev/null 2>&1 \
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
  # so do start-dir and ai-agents: this run's memory of the prompt answers.
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rm -rf "$f"; sub "removed stale $(hp "$f")"; legacy_cleaned=$((legacy_cleaned+1))
  done < <(find "$CONF_DIR" -mindepth 1 -maxdepth 1 \
             ! -name 'local*' ! -name rc.sh ! -name theme.sh ! -name completions \
             ! -name start-dir ! -name ai-agents ! -name bash-preexec.sh 2>/dev/null)

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
# Coloured man pages through bat. col strips the overstrike bold/underline
# that bat's man syntax does not expect; MANROFFOPT=-c keeps groff from
# emitting the SGR escapes that would double-format it.
if command -v batcat >/dev/null 2>&1 && command -v col >/dev/null 2>&1; then
  export MANPAGER="sh -c 'col -bx | batcat -l man -p'"
  export MANROFFOPT="-c"
fi
alias e='$EDITOR'
alias sue='sudoedit'
# neovim took over from vim; the muscle memory keeps working.
if command -v nvim >/dev/null 2>&1; then
  alias vim='nvim'
  alias vi='nvim'
  alias vimdiff='nvim -d'
fi

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

# ---- OpenAI Codex -----------------------------------------------------------
alias cx='codex'
alias cxc='codex resume --last'        # resume the most recent session
alias cxr='codex resume'               # pick a session from a list

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
command -v lazygit >/dev/null 2>&1 && alias lg='lazygit'
# git dft  = difftool through difftastic (structural diff); git dlog = log -p
# with it. Set up in ~/.gitconfig by the bootstrap; these are just reminders.

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
# mousefix: switch mouse capture off again after a TUI (nano, vim, claude…)
# crashed or was killed and left it on — drags then stop selecting in the pane.
alias mousefix="printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l'"
# dev <name>: attach to (or create) a tmux session rooted in the project folder
dev() {
  local root="${DEV_ROOT:-/srv/dev}"
  local name="${1:-}"
  if [ -z "$name" ]; then tmux new-session -A -s dev -c "$root"; return; fi
  local dir="$root/$name"
  [ -d "$dir" ] || { echo "No such project: $dir" >&2; return 1; }
  tmux new-session -A -s "$name" -c "$dir"
}

# ---- docker -----------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  alias d='docker'
  alias dc='docker compose'
  alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
  alias dimg='docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"'
  alias dlog='docker logs -f --tail 200'
  alias dprune='docker system prune -f'
  command -v lazydocker >/dev/null 2>&1 && alias lzd='lazydocker'
fi

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
# mise: per-project tool versions from .mise.toml / .tool-versions / .nvmrc.
# Inert until a project pins something — the apt node and dotnet stay default.
# mise no longer reads .nvmrc / .node-version unless told to.
export MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS="${MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS:-node}"
command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"
# watchexec: `wx -e cs dotnet test`, `wx -r -- npm start`. It honours
# .gitignore, which is what entr never did.
command -v watchexec >/dev/null 2>&1 && alias wx='watchexec --clear'
# trippy ships its binary as `trip`
command -v trip >/dev/null 2>&1 && alias trippy='trip'

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

# y — yazi, and the shell follows it: quitting with q leaves you in the folder
# you navigated to (Q quits without changing directory).
if command -v yazi >/dev/null 2>&1; then
  y() {
    local tmp cwd
    tmp="$(mktemp -t yazi-cwd.XXXXXX)" || return 1
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp" 2>/dev/null)" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
      builtin cd -- "$cwd" || true
    fi
    rm -f -- "$tmp"
  }
fi

# tshare user:password [port] — serve the "dev" tmux session in a browser
# (ttyd). Credentials are required on purpose: it is a full shell. Reachable
# only from DEV_UFW_TRUST networks, unless you opened the port in ufw yourself.
tshare() {
  command -v ttyd >/dev/null 2>&1 || { echo "tshare: ttyd is not installed" >&2; return 1; }
  case "${1:-}" in *:*) ;; *) echo "usage: tshare user:password [port]" >&2; return 2 ;; esac
  local port="${2:-7681}"
  echo "http://$(hostname -I 2>/dev/null | awk '{print $1}'):${port}/  (Ctrl-C here to stop)"
  ttyd -W -p "$port" -c "$1" tmux new-session -A -s dev
}

# ---- fastfetch on the first shell of a login --------------------------------
# Once per login, not per pane: inside tmux only the server's very first pane
# (%0) shows it, and a plain login shell only when tmux is not about to take
# the screen anyway. DEV_FASTFETCH=0 in local.sh turns it off.
__fastfetch_once() {
  [ "${DEV_FASTFETCH:-1}" = "1" ]      || return
  [ -z "${__DEV_FASTFETCH_SHOWN:-}" ]  || return   # `reload` must not repeat it
  command -v fastfetch >/dev/null 2>&1 || return
  case "$-" in *i*) ;; *) return ;; esac
  if [ -n "${TMUX:-}" ]; then
    [ "${TMUX_PANE:-}" = "%0" ] || return
  else
    shopt -q login_shell || return
    if [ "${DEV_TMUX_AUTOSTART:-1}" = "1" ] && [ -z "${NO_TMUX:-}" ] \
       && [ ! -f "$HOME/.no-auto-tmux" ] && command -v tmux >/dev/null 2>&1; then
      return
    fi
  fi
  __DEV_FASTFETCH_SHOWN=1
  fastfetch
}

# ---- history: atuin -----------------------------------------------------------
# atuin records every command into SQLite (with cwd, duration, exit code) and
# owns Ctrl-R; fzf keeps Ctrl-T and Alt-C. It must come AFTER the fzf init so
# its Ctrl-R binding wins, and it needs bash-preexec to see commands at all.
# --disable-up-arrow keeps the prefix search on Up/Down from ~/.inputrc.
# Guarded so that `reload` (re-sourcing this file) does not stack a second
# copy of every hook.
if command -v atuin >/dev/null 2>&1 && [ -r "$HOME/.config/dev-bootstrap/bash-preexec.sh" ] \
   && ! declare -F __atuin_precmd >/dev/null 2>&1; then
  . "$HOME/.config/dev-bootstrap/bash-preexec.sh"
  eval "$(atuin init bash --disable-up-arrow)"
fi

# ---- prompt registration ----------------------------------------------------
# Registered here, last, on purpose. zoxide, direnv and mise all install their
# hooks by *prepending* to PROMPT_COMMAND, so whichever hook is added last ends
# up at the front of the chain — and the prompt has to be at the front, because
# it reads $? first thing, and a hook running ahead of it would leave its own
# exit status (always 0) there instead of the command's.
#
# starship draws the prompt when it is installed (DEV_PROMPT=bash in local.sh
# picks the built-in one instead); its init handles the ordering itself. The
# history flush moves out of __prompt so that it happens on either path.
__hist_flush() { [ -n "${HISTFILE:-}" ] && history -a; }
if command -v starship >/dev/null 2>&1 && [ "${DEV_PROMPT:-starship}" = "starship" ]; then
  # Prepended, never appended: zoxide leaves a trailing ";" behind, and
  # "...;;__hist_flush" is a syntax error on every single prompt.
  case "${PROMPT_COMMAND:-}" in
    *__hist_flush*) ;;
    "")             PROMPT_COMMAND="__hist_flush" ;;
    *)              PROMPT_COMMAND="__hist_flush;$PROMPT_COMMAND" ;;
  esac
  declare -F starship_precmd >/dev/null 2>&1 || eval "$(starship init bash)"
else
  case "${PROMPT_COMMAND:-}" in
    *__prompt*) ;;                                        # already registered
    "")         PROMPT_COMMAND="__prompt" ;;
    *)          PROMPT_COMMAND="__prompt;$PROMPT_COMMAND" ;;
  esac
fi

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
  have mise      && gen_comp mise      mise completion bash
  have atuin     && gen_comp atuin     atuin gen-completions --shell bash
  have starship  && gen_comp starship  starship completions bash
  have watchexec && gen_comp watchexec watchexec --completions bash
  have docker    && gen_comp docker    docker completion bash
  have difft     && gen_comp difft     difft --generate-completions bash
  have ya        && gen_comp ya        ya completions bash
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
  log "Configuring editors, bat theme, psql, starship, atuin, lazygit"

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
# Mouse: click positions the cursor. nano cannot drag-select — Shift+drag uses
# the terminal's own selection instead, and Alt-M toggles nano's mouse off.
set mouse
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

  # ------------------------------------------------------------- neovim ----
  # No plugin manager on purpose: nothing to clone on first start, nothing to
  # break over ssh. Sane defaults, a built-in dark scheme, space as leader.
  if have nvim; then
    mkdir -p "$HOME/.config/nvim"
    claim "$HOME/.config/nvim/init.lua" && cat > "$HOME/.config/nvim/init.lua" <<'NVIMRC'
-- ~/.config/nvim/init.lua — managed by dev-bootstrap.sh
-- Plugin-free defaults. Put your own additions in ~/.config/nvim/lua/local.lua
vim.g.mapleader = " "
vim.g.maplocalleader = " "
local o = vim.opt
o.number = true
o.cursorline = true
o.signcolumn = "yes"
o.mouse = "a"
o.clipboard = "unnamedplus"        -- xclip / wl-clipboard, or OSC 52 over ssh
o.termguicolors = true
o.expandtab = true
o.shiftwidth = 4
o.tabstop = 4
o.smartindent = true
o.ignorecase = true
o.smartcase = true
o.wrap = false
o.scrolloff = 6
o.splitright = true
o.splitbelow = true
o.undofile = true
o.updatetime = 300
o.list = true
o.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
pcall(vim.cmd.colorscheme, "habamax")

local map = vim.keymap.set
map("n", "<Esc>", "<cmd>nohlsearch<CR>")
map("n", "<leader>w", "<cmd>w<CR>", { desc = "save" })
map("n", "<leader>q", "<cmd>q<CR>", { desc = "quit" })
map("n", "<leader>e", "<cmd>Explore<CR>", { desc = "file browser" })
map("n", "<C-h>", "<C-w>h"); map("n", "<C-j>", "<C-w>j")
map("n", "<C-k>", "<C-w>k"); map("n", "<C-l>", "<C-w>l")

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "javascript", "typescript", "json", "yaml", "html", "css", "lua" },
  callback = function() vim.bo.shiftwidth = 2; vim.bo.tabstop = 2 end,
})
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "go", "make" },
  callback = function() vim.bo.expandtab = false end,
})
pcall(require, "local")
NVIMRC
  fi

  # ----------------------------------------------------------- starship ----
  # The same Catppuccin Mocha as tmux/bat/delta, and no Nerd Font glyphs — a
  # plain ssh terminal has none, and eza runs with --icons=never for the same
  # reason. Layout mirrors the built-in prompt: user@host dir (branch*) / $.
  if have starship; then
    claim "$HOME/.config/starship.toml" && cat > "$HOME/.config/starship.toml" <<'STARSHIP'
# ~/.config/starship.toml — managed by dev-bootstrap.sh
"$schema" = 'https://starship.rs/config-schema.json'
add_newline = false
palette = "catppuccin_mocha"
format = """
$username$hostname$directory$git_branch$git_status$dotnet$nodejs$python$docker_context$cmd_duration$line_break$character"""

[username]
show_always = true
style_user = "mauve"
style_root = "bold red"
format = "[$user]($style)"

[hostname]
ssh_only = false
style = "overlay0"
format = "[@$hostname]($style) "

[directory]
style = "blue"
truncation_length = 4
truncate_to_repo = true
read_only = " ro"
format = "[$path]($style)[$read_only]($read_only_style) "

[git_branch]
symbol = ""
style = "peach"
format = "[($branch)]($style)"

[git_status]
style = "peach"
format = "[$all_status$ahead_behind]($style) "
ahead = ">${count}"
behind = "<${count}"
diverged = "<>${ahead_count}/${behind_count}"
conflicted = "!"
modified = "*"
staged = "+"
untracked = "?"
stashed = "\\$"
deleted = "x"
renamed = "r"

[dotnet]
symbol = ".NET "
style = "mauve"
heuristic = true
format = "[$symbol($version)]($style) "

[nodejs]
symbol = "node "
style = "green"
format = "[$symbol($version)]($style) "

[python]
symbol = "py "
style = "yellow"
format = '[${symbol}${pyenv_prefix}(${version})(\($virtualenv\))]($style) '

[docker_context]
symbol = "docker "
style = "sky"
only_with_files = true
format = "[$symbol$context]($style) "

[cmd_duration]
min_time = 2_000
style = "yellow"
format = "[$duration]($style) "

[character]
success_symbol = "[\\$](green)"
error_symbol = "[\\$](red)"
vimcmd_symbol = "[<](green)"

[palettes.catppuccin_mocha]
rosewater = "#f5e0dc"
flamingo = "#f2cdcd"
pink = "#f5c2e7"
mauve = "#cba6f7"
red = "#f38ba8"
maroon = "#eba0ac"
peach = "#fab387"
yellow = "#f9e2af"
green = "#a6e3a1"
teal = "#94e2d5"
sky = "#89dceb"
sapphire = "#74c7ec"
blue = "#89b4fa"
lavender = "#b4befe"
text = "#cdd6f4"
subtext1 = "#bac2de"
subtext0 = "#a6adc8"
overlay2 = "#9399b2"
overlay1 = "#7f849c"
overlay0 = "#6c7086"
surface2 = "#585b70"
surface1 = "#45475a"
surface0 = "#313244"
base = "#1e1e2e"
mantle = "#181825"
crust = "#11111b"
STARSHIP
  fi

  # -------------------------------------------------------------- atuin ----
  # Local only: no account, no sync, no update nags. The filter list mirrors
  # HISTIGNORE so the noise that is kept out of bash history stays out here.
  if have atuin; then
    mkdir -p "$HOME/.config/atuin"
    claim "$HOME/.config/atuin/config.toml" && cat > "$HOME/.config/atuin/config.toml" <<'ATUIN'
# ~/.config/atuin/config.toml — managed by dev-bootstrap.sh
auto_sync = false
update_check = false
sync_frequency = "0"
search_mode = "fuzzy"
filter_mode = "host"
style = "compact"
inline_height = 25
show_preview = true
show_help = false
enter_accept = false
keymap_mode = "emacs"
history_filter = [
  "^ls$", "^ll$", "^la$", "^l$", "^cd$", "^cd -$", "^\\.\\.$", "^pwd$",
  "^exit$", "^clear$", "^reload$", "^history$", "^gs$", "^h$",
]
cwd_filter = []
ATUIN
  fi

  # ------------------------------------------------------------ lazygit ----
  if have lazygit; then
    lg_dir="$HOME/.config/lazygit"
    mkdir -p "$lg_dir"
    claim "$lg_dir/config.yml" && cat > "$lg_dir/config.yml" <<'LAZYGIT'
# ~/.config/lazygit/config.yml — managed by dev-bootstrap.sh
gui:
  nerdFontsVersion: ""          # no Nerd Font over plain ssh
  showFileTree: true
  showRandomTip: false
  border: rounded
  theme:                        # Catppuccin Mocha
    activeBorderColor:   ["#89b4fa", bold]
    inactiveBorderColor: ["#a6adc8"]
    optionsTextColor:    ["#89b4fa"]
    selectedLineBgColor: ["#313244"]
    cherryPickedCommitBgColor: ["#45475a"]
    cherryPickedCommitFgColor: ["#89b4fa"]
    unstagedChangesColor: ["#f38ba8"]
    defaultFgColor:      ["#cdd6f4"]
    searchingActiveBorderColor: ["#f9e2af"]
  authorColors:
    "*": "#b4befe"
git:
  paging:
    colorArg: always
    pager: delta --dark --paging=never --line-numbers
  autoFetch: true
  autoRefresh: true
  branchLogCmd: git log --graph --color=always --abbrev-commit --decorate --date=relative --pretty=medium {{branchName}} --
update:
  method: never
LAZYGIT
  fi

  # ----------------------------------------------------------- tealdeer ----
  # Refresh the page cache by itself instead of nagging about its age.
  if have tldr; then
    mkdir -p "$HOME/.config/tealdeer"
    claim "$HOME/.config/tealdeer/config.toml" && cat > "$HOME/.config/tealdeer/config.toml" <<'TLDR'
# ~/.config/tealdeer/config.toml — managed by dev-bootstrap.sh
[updates]
auto_update = true
auto_update_interval_hours = 168

[style.command_name]
foreground = "blue"
bold = true
[style.example_code]
foreground = "green"
[style.example_variable]
foreground = "yellow"
underline = true
TLDR
  fi

  # ---------------------------------------------------------- fastfetch ----
  # What matters on a server, nothing that needs a GPU or a display.
  if have fastfetch; then
    mkdir -p "$HOME/.config/fastfetch"
    claim "$HOME/.config/fastfetch/config.jsonc" && cat > "$HOME/.config/fastfetch/config.jsonc" <<'FASTFETCH'
// ~/.config/fastfetch/config.jsonc — managed by dev-bootstrap.sh
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": { "type": "small", "padding": { "top": 1, "right": 3 } },
  "display": { "separator": "  ", "color": { "keys": "blue", "title": "magenta" } },
  "modules": [
    "title",
    "separator",
    "os",
    "kernel",
    "uptime",
    "packages",
    "shell",
    "terminal",
    "cpu",
    "memory",
    "swap",
    { "type": "disk", "folders": "/" },
    "localip",
    "break",
    "colors"
  ]
}
FASTFETCH
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
\set activity 'select pid, age(clock_timestamp(), query_start) as age, usename, state, left(query, 80) as query from pg_stat_activity where state <> \'idle\' and pid <> pg_backend_pid() order by age desc nulls last;'
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

# ---- system summary, then tmux autostart ------------------------------------
__fastfetch_once
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
  # Listed as "dark<TAB>Catppuccin Mocha", so a whole-line match never hits.
  if delta --list-syntax-themes 2>/dev/null | awk -F'\t' '$NF == "Catppuccin Mocha" {f=1} END {exit !f}'; then
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
# difftastic: structural, syntax-aware diffs. Not the pager (delta stays the
# default view) but one command away: `git dft` / `git dlog` / `git dshow`.
if have difft; then
  sub "difftastic available as git dft / dlog / dshow"
  gitset diff.tool difftastic
  gitset difftool.prompt false
  gitset difftool.difftastic.cmd 'difft "$LOCAL" "$REMOTE"'
  gitset pager.difftool true
  gitset alias.dft  "difftool"
  gitset alias.dlog "-c diff.external=difft log -p --ext-diff"
  gitset alias.dshow "-c diff.external=difft show --ext-diff"
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


# ===================================================================== ssh ===
if [[ -n "$DEV_SSH_PUBKEY" ]]; then
  log "SSH public key"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ak="$HOME/.ssh/authorized_keys"
  if ! ssh_key_ok "$DEV_SSH_PUBKEY"; then
    warn "DEV_SSH_PUBKEY is not a single public key line — not added"; note_fail "ssh key"
  elif [[ -f "$ak" ]] && awk '{for (i = 1; i <= NF; i++) print $i}' "$ak" \
         | grep -qxF "$(awk '{print $2}' <<<"$DEV_SSH_PUBKEY")"; then
    sub "already in ~/.ssh/authorized_keys"
  else
    # A file without a final newline would glue our key onto its last one.
    [[ -s "$ak" && -n "$(tail -c1 "$ak")" ]] && printf '\n' >> "$ak"
    printf '%s\n' "$DEV_SSH_PUBKEY" >> "$ak"
    sub "added to ~/.ssh/authorized_keys: $(ssh-keygen -l -f - <<<"$DEV_SSH_PUBKEY" 2>/dev/null)"
  fi
  [[ -f "$ak" ]] && chmod 600 "$ak"
  # sshd (StrictModes) ignores authorized_keys when home or ~/.ssh is writable by others.
  if [[ -n "$(find "$HOME" "$HOME/.ssh" -maxdepth 0 -perm /022 2>/dev/null)" ]]; then
    warn "your home or ~/.ssh is group/world-writable — sshd will ignore the key: chmod go-w ~ ~/.ssh"
    note_fail "ssh key (permissions)"
  fi
fi

if ! grep -q "ServerAliveInterval" "$HOME/.ssh/config" 2>/dev/null; then
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  printf 'Host *\n    ServerAliveInterval 60\n    ServerAliveCountMax 5\n    AddKeysToAgent yes\n' \
    >> "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"
fi

# ====================================================== shared dev folder ===
if [[ -d "$DEV_ROOT" ]] && getent group "$DEV_GROUP" >/dev/null 2>&1; then
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$DEV_GROUP"; then
    warn "$USER is not in $DEV_GROUP — sudo usermod -aG $DEV_GROUP $USER (then re-login)"
  fi
fi

# ============================================================== leftovers ===
# Dangling links in ~/.local/bin (an npm or pipx tool removed under them), and
# copies an older, single-script bootstrap put there that the system half now
# installs for everyone: ~/.local/bin is first on PATH, so a stale copy hides
# the system one. A copy that is NEWER than the system one stays — going back
# a version can break data the newer one already migrated (atuin's history.db).
log "Removing what nothing uses any more"
left_n=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rm -f "$f"; sub "removed dangling link $(hp "$f")"; left_n=$((left_n+1))
done < <(find "$HOME/.local/bin" -maxdepth 1 -xtype l 2>/dev/null)
for b in lazygit starship atuin watchexec difft yazi ya trip onefetch jless croc sops \
         fastfetch procs dive lazydocker sqlcmd; do
  mine="$HOME/.local/bin/$b"
  [[ -f "$mine" && ! -L "$mine" ]] || continue
  sys=""
  for d in /usr/local/bin /usr/bin /opt/mssql-tools18/bin; do
    [[ -x "$d/$b" ]] && { sys="$d/$b"; break; }
  done
  [[ -n "$sys" ]] || continue
  if [[ "$b" == sqlcmd ]]; then
    # go-sqlcmd fallback vs. the real mssql-tools18: different products, versions do not compare.
    [[ "$sys" == /opt/* ]] || continue
  else
    mv_="$("$mine" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
    sv_="$("$sys"  --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
    [[ -n "$mv_" && -n "$sv_" ]] && dpkg --compare-versions "$sv_" ge "$mv_" || continue
  fi
  rm -f "$mine"; sub "removed ~/.local/bin/$b — $sys is at least as new"; left_n=$((left_n+1))
done
(( left_n == 0 )) && sub "nothing left over"

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
log "Installed (per user)"
ver() { printf '    %-16s %s\n' "$1" "${2:--}"; }
ver uv       "$("$HOME/.local/bin/uv" --version 2>/dev/null | awk '{print $2}')"
ver claude   "$("$HOME/.local/bin/claude" --version 2>/dev/null | awk '{print $1}')"
ver codex    "$("$HOME/.local/bin/codex" --version 2>/dev/null | awk '{print $NF}')"
ver mise     "$(mise --version 2>/dev/null | awk '{print $1}')"
ver dotnet   "$(dotnet --list-sdks 2>/dev/null | awk '{print $1}' | tail -1)"
ver pnpm     "$(pnpm --version 2>/dev/null)"
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
[[ -x "$HOME/.local/bin/claude" ]] || have claude && \
  sub "claude                       # authenticate once; 'cc' is the shortcut"
[[ -x "$HOME/.local/bin/codex" ]] || have codex && \
  sub "codex                        # authenticate once; 'cx' is the shortcut"
sub "touch ~/.no-auto-tmux        # if you don't want tmux on login"
sub "lg / y / lzd / tldr <cmd>     # lazygit, yazi, lazydocker, quick examples"
sub "Ctrl-R                       # atuin history search (fzf keeps Ctrl-T, Alt-C)"
sub "DEV_START_DIR=/path bash $0  # change where logins start"
sub "\$EDITOR ~/.config/dev-bootstrap/local.sh   # your own aliases, never overwritten"
sub "ls ~/.*.pre-bootstrap        # the config you had before the first run"
