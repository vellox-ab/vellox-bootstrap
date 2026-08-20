# dev-bootstrap — reference manual

Everything `dev-bootstrap.sh` installs and configures, what each piece is for,
where it lives on disk, how the pieces fit together, and how to turn each one
off. Written so that a person — or an AI session with this repository open —
can answer "how does X work on this machine?" without reading the script.

Script version: **5.7.0**. Targets Ubuntu 24.04 (noble) and 26.04 (resolute).

---

## 1. How the script works

### 1.1 Run model

- Run as a normal user, never root. `sudo` is requested once up front and kept
  alive by a background `sudo -n true` loop for the whole run.
- **No `set -e`.** A failing step is recorded in `FAILED_STEPS` and the run
  continues. The summary at the end lists what did not complete; a re-run
  retries only those steps, because every section checks "already present?"
  first.
- **Idempotent.** Running it ten times lands on the same machine state.
- **Self-cleaning.** Every apt source and keyring this script has *ever*
  created (`LEGACY_SOURCES`, `LEGACY_KEYS`, and anything carrying the text
  `managed-by: dev-bootstrap`) is removed at the start of each run and
  re-derived for the release it is running on. Sources it did not create are
  listed but never touched. `--clean-only` does just the removal.
- Two questions are asked near the start, reading from `/dev/tty` so they
  also work when piped from curl: the **git identity** and the **start
  folder**. Both can be pre-answered with environment variables and both are
  skipped when there is no terminal.

### 1.2 Sections, in execution order

| # | Section | Skip flag | What it does |
|---|---|---|---|
| 1 | preflight | — | OS/arch/apt detection, sudo, `~/.local/bin`, `~/.config/dev-bootstrap` |
| 2 | git identity / start folder | `SKIP_GIT_IDENTITY`, `SKIP_START_DIR` | the two prompts |
| 3 | cleanup | — | remove our old apt artifacts |
| 4 | system packages | `SKIP_SYSTEM` | one apt transaction for `BASE_PKGS` |
| 5 | node | `SKIP_NODE` | Node ≥ `NODE_MAJOR` + npm globals |
| 6 | python | `SKIP_PYTHON` | uv, pipx tools |
| 7 | .NET | `SKIP_DOTNET` | SDK + global tools |
| 8 | claude code | `SKIP_CLAUDE` | native installer |
| 9 | extra tools | `SKIP_EXTRAS` | GitHub-release tools, mise, bash-preexec |
| 10 | docker | `SKIP_DOCKER` | docker-ce or docker.io, group, lazydocker, dive |
| 11 | claude code conf | `SKIP_CLAUDE_CONF` | status line, settings seed, LSP plugins |
| 12 | old shell config | `SKIP_LEGACY_CLEAN` | neutralise earlier setups |
| 13 | tmux.conf | `SKIP_TMUX_CONF` | write + hot-reload |
| 14 | shell config | `SKIP_SHELL_CONF` | write `rc.sh`, hook `.bashrc`, login bridge |
| 15 | completions | `SKIP_SHELL_CONF` | pre-generate completion files |
| 16 | inputrc | `SKIP_INPUTRC` | readline |
| 17 | editor config | `SKIP_EDITOR_CONF` | bat theme, nano, micro, nvim, starship, atuin, lazygit, tealdeer, fastfetch, psql |
| 18 | rc.sh tail | `SKIP_SHELL_CONF` | fastfetch + tmux autostart appended last |
| 19 | git config | `SKIP_GIT_CONF` | global git settings, delta, difftastic |
| 20 | MS SQL tooling | `SKIP_MSSQL` | sqlcmd/bcp/ODBC |
| 21 | postgres | `SKIP_POSTGRES` | psql from PGDG |
| 22 | system tuning | `SKIP_SYSCTL` | inotify, nofile, ssh keepalive |
| 23 | hardening | `SKIP_HARDENING` | unattended-upgrades, fail2ban, ufw |
| 24 | verify | — | apt health, login-shell probe, version table |

### 1.3 Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `DEV_ROOT` | `/srv/dev` | shared project folder; `dev <name>` opens `$DEV_ROOT/<name>` |
| `DEV_GROUP` | `devgroup` | group expected to own `DEV_ROOT` (only checked, never created) |
| `DEV_START_DIR` | asked | folder every login lands in |
| `DEV_EDITOR` | `nano` | `nano`, `micro` or `nvim`; becomes `$EDITOR` and `core.editor` |
| `DEV_TMUX_AUTOSTART` | `1` | attach tmux on interactive login |
| `DEV_TMUX_RESET` | `1` | reset a running tmux server before reloading the config |
| `NODE_MAJOR` | `22` | minimum Node major |
| `DOTNET_MAJOR` | empty | pin an SDK major; empty = newest the distro offers |
| `DOTNET_TOOLS` | `csharp-ls dotnet-ef` | .NET global tools |
| `PG_MAJOR` | `18` | preferred PGDG client |
| `CLAUDE_PLUGINS` | `pyright-lsp typescript-lsp csharp-lsp` | Claude Code plugins |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | empty | both set = no prompt |
| `DEV_UFW_TRUST` | `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16` | networks ufw allows and fail2ban ignores |
| `DEV_EXTRAS_UPGRADE` | `0` | `1` re-downloads every GitHub-release tool |

Runtime knobs that go in `~/.config/dev-bootstrap/local.sh` (read by every
shell, no re-run needed): `DEV_PROMPT=bash`, `DEV_FASTFETCH=0`,
`DEV_PROMPT_GIT=0`, `DEV_PROMPT_GIT_DIRTY=0`, `DEV_START_DIR=...`.

### 1.4 File ownership model

Two kinds of files:

**Written whole (the script owns them).** A re-run always produces the same
content. Before the first overwrite, `claim()` copies what was there to
`<file>.pre-bootstrap` — once, never refreshed. A symlink in the way (stow,
chezmoi) is removed rather than written through. Immutable or unwritable files
are skipped with a warning.

```
~/.tmux.conf                         ~/.config/starship.toml
~/.inputrc                           ~/.config/atuin/config.toml
~/.nanorc                            ~/.config/lazygit/config.yml
~/.psqlrc                            ~/.config/nvim/init.lua
~/.gitignore_global                  ~/.config/tealdeer/config.toml
~/.config/micro/settings.json        ~/.config/fastfetch/config.jsonc
~/.config/micro/colorschemes/catppuccin-mocha.micro
~/.claude/statusline.sh
~/.config/dev-bootstrap/rc.sh        (regenerated; never backed up)
~/.config/dev-bootstrap/theme.sh
~/.config/dev-bootstrap/completions/*.bash
```

**Merged / appended (yours).**

- `~/.bashrc` and the login file (`~/.bash_profile`, `.bash_login` or
  `.profile`, whichever bash reads first): a block between
  `# >>> dev-bootstrap >>>` and `# <<< dev-bootstrap <<<` is replaced on every
  run; everything else is untouched.
- `~/.gitconfig`: individual keys set with `--replace-all`; `safe.directory`
  is *added*, never replaced.
- `~/.claude/settings.json`: only missing keys are seeded (jq deep-merge,
  existing values win).
- `~/.ssh/config`: keepalive block appended once if absent.

**Yours entirely, never written:** `~/.config/dev-bootstrap/local.sh` (and
anything named `local*` in that directory), `~/.config/nvim/lua/local.lua`.

State the script keeps for itself: `~/.config/dev-bootstrap/start-dir` (the
last start-folder answer) and `~/.config/dev-bootstrap/bash-preexec.sh`.
Anything else in that directory is treated as a leftover from an older version
and deleted on the next run.

### 1.5 System files written (root)

| File | Purpose |
|---|---|
| `/etc/apt/sources.list.d/{nodesource,pgdg,mssql-release,docker}.sources` | deb822 sources, each with `Signed-By` |
| `/etc/apt/keyrings/{nodesource,pgdg,microsoft,docker}.asc` | armoured keys |
| `/etc/apt/preferences.d/mssql-release.pref` | pin: only the two SQL packages may come from a foreign suite |
| `/etc/apt/apt.conf.d/20auto-upgrades` | unattended-upgrades schedule |
| `/etc/fail2ban/jail.d/dev-bootstrap-sshd.local` | sshd jail |
| `/etc/sysctl.d/60-inotify.conf` | inotify limits |
| `/etc/security/limits.d/90-dev-nofile.conf` | open-file limits |

All carry `managed-by: dev-bootstrap` and the apt ones are removed by
`--clean-only`.

---

## 2. The shell

### 2.1 Load order

1. bash starts. A **login** shell reads the first of `~/.bash_profile`,
   `~/.bash_login`, `~/.profile` — the script makes sure that file sources
   `~/.bashrc` (the "login bridge"), because without it SSH logins get none of
   the config. An **interactive non-login** shell (a new tmux pane) reads
   `~/.bashrc` directly.
2. `~/.bashrc` → our block → `~/.config/dev-bootstrap/rc.sh`.
3. `rc.sh`, top to bottom: locale → PATH → .NET env → truecolor → umask →
   editors/pagers → theme (`theme.sh`, `vivid`, fzf colours) → history →
   `__prompt` definition → aliases and functions → zoxide, direnv, mise hooks
   → fzf key bindings → bash-completion + pre-generated completions →
   helpers → **atuin** (bash-preexec + init) → **prompt registration**
   (starship or `__prompt`) → `local.sh` → `__start_dir` → `__fastfetch_once`
   → `__auto_tmux`.
4. `__auto_tmux` never returns on a real login (it `exec`s into tmux), which
   is why it is appended *last* by a separate section ("rc.sh tail") and why
   nothing may be appended after it.

### 2.2 PATH

`~/.local/bin` is prepended (npm globals, pipx, uv, claude, every
GitHub-release binary). Appended when present: `/opt/mssql-tools18/bin`,
`~/.dotnet/tools`, `~/.dotnet` (private SDK only). The helpers
`__path_prepend/append/dedupe` make re-sourcing safe.

### 2.3 Prompt — starship

`starship` draws the prompt when installed. Config: `~/.config/starship.toml`.

- Layout mirrors the old bash prompt: `user@host  dir (branch*)` on line one,
  `$` on line two, red `$` after a failed command.
- Segments: username (always), hostname, directory (truncated to 4, or to
  the repo root), git branch + ASCII status (`*` modified, `+` staged, `?`
  untracked, `!` conflicted, `>n`/`<n` ahead/behind), `.NET`, `node`, `py`
  (with venv), `docker` context (only when compose/Dockerfile present),
  command duration over 2 s.
- Palette: Catppuccin Mocha, defined under `[palettes.catppuccin_mocha]`.
- **No Nerd Font glyphs** anywhere (same policy as `eza --icons=never`): a
  plain ssh terminal has none.
- Registration: `starship init bash` is evaluated last in `rc.sh`, guarded by
  `declare -F starship_precmd` so `reload` does not register it twice. Because
  bash-preexec is loaded first, starship hooks in through `precmd_functions`.
- `__hist_flush` (`history -a` after every command, so other panes see it) is
  prepended to `PROMPT_COMMAND` — prepended, because zoxide leaves a trailing
  `;` and appending would produce `;;`.

**Fallback:** `DEV_PROMPT=bash` in `local.sh`, or starship missing → the
built-in `__prompt` function (same colours, git-aware; `DEV_PROMPT_GIT=0`
drops the git segment, `DEV_PROMPT_GIT_DIRTY=0` keeps the branch but skips
the dirty check, which is the expensive half in a large tree).

### 2.4 History — atuin

`atuin` records every command into `~/.local/share/atuin/history.db` (SQLite)
with cwd, duration, exit status and host, and replaces **Ctrl-R** with a
fuzzy full-screen search. Config: `~/.config/atuin/config.toml`.

- Local only: `auto_sync = false`, `update_check = false`. No account.
- `filter_mode = "host"` (this machine's history; Ctrl-R again cycles to
  session / directory / global), `search_mode = "fuzzy"`, compact style,
  `enter_accept = false` (Enter puts the command on the line, you press Enter
  again to run it).
- `history_filter` mirrors `HISTIGNORE` (`ls`, `cd`, `exit`, …).
- Started with `atuin init bash --disable-up-arrow`, so **Up/Down keep the
  readline prefix search** from `~/.inputrc`.
- Requires **bash-preexec** (`~/.config/dev-bootstrap/bash-preexec.sh`,
  fetched from upstream master) to see commands; it is sourced immediately
  before `atuin init`. Both are guarded against double-init.
- On first install the script runs `atuin import auto`, pulling the existing
  `~/.bash_history` in.
- fzf keeps **Ctrl-T** (file picker with bat preview) and **Alt-C** (cd).
  The atuin init is placed *after* the fzf init so its Ctrl-R binding wins.
- Plain bash history still works as before (`HISTSIZE=100000`, `histappend`,
  timestamps, `ignoreboth:erasedups`); atuin is additive.

Useful: `atuin stats`, `atuin search --cwd . foo`, `atuin history list --cmd-only | tail`.

### 2.5 Aliases and functions (rc.sh)

| Name | Expands to |
|---|---|
| `ls l ll la lt lt3 ltr lsz ldot` | eza variants (`--git`, long-iso times, no icons); coreutils fallback |
| `cat` | `batcat --paging=never --style=plain` |
| `fd` | `fdfind` (Ubuntu's binary name) |
| `vim vi vimdiff` | `nvim` |
| `e` / `sue` | `$EDITOR` / `sudoedit` |
| `cc ccc ccr ccp ccdoc` | `claude`, `--continue`, `--resume`, `--permission-mode plan`, `doctor` |
| `gs ga gc gca gp gpl gd gds gl gll gb gco gsw gst` | git shortcuts |
| `lg` | `lazygit` |
| `d dc dps dimg dlog dprune lzd` | docker, compose, formatted ps/images, logs, prune, lazydocker |
| `pg pgl sqlcmd` | `pgcli`, `psql -l`, `sqlcmd -C` (trust dev certs) |
| `ta tl tn tk` | tmux attach/list/new/kill |
| `py venv act` | python3, create venv, activate |
| `wx` | `watchexec --clear` |
| `trippy` | `trip` |
| `trash` | `trash-put` |
| `.. ... df du free ports myip reload path` | the usual |

Functions: `dev [name]` (tmux session rooted in `$DEV_ROOT/name`, with tab
completion), `mkcd`, `extract` / `extractd`, `backup`, `serve [port]`,
`h <pattern>` (grep history), `ff <pattern>` (find files), `mkvenv` (uv),
`y` (yazi — the shell follows it, see §4.5), `tshare user:pass [port]`
(ttyd, see §4.9).

### 2.6 readline — `~/.inputrc`

Case-insensitive completion, one-Tab listing, coloured completions, bracketed
paste, **Up/Down = prefix history search** (type `git` then Up), Ctrl/Alt +
arrows word-wise, Home/End in every terminal flavour.

### 2.7 Completions

Generated once at bootstrap into `~/.config/dev-bootstrap/completions/*.bash`
(gh, npm, uv, uvx, just, rg, pipx, mise, atuin, starship, watchexec, docker,
difft, ya) and sourced by `rc.sh` — instead of `eval "$(x completion bash)"`
forking on every shell start.

### 2.8 Pagers and man pages

`LESS="-R -F -i"`, `PAGER=less`. **Man pages are rendered through bat**:
`MANPAGER="sh -c 'col -bx | batcat -l man -p'"` with `MANROFFOPT=-c`. psql
uses `pspg` (`PSQL_PAGER`).

---

## 3. tmux

Config: `~/.tmux.conf`. Prefix **Ctrl-a**.

- Splits: `|` vertical, `-` horizontal (both open in the current path).
  Navigate with Alt+arrows (no prefix) or prefix + `hjkl`; resize with
  prefix + `HJKL`; Shift+Left/Right switch windows.
- vi copy mode: prefix + Enter, `v` select, `y` copy; `set-clipboard on`.
- `mouse on`, 200 000 line history, `escape-time 0`, truecolor
  (`tmux-256color` + RGB overrides), windows renumber, base index 1,
  `detach-on-destroy off`.
- prefix + `r` reload, `S` sync panes, `X` kill session with confirmation.
- Catppuccin Mocha status bar: session name left; load average, user@host,
  date right.

**Autostart:** every interactive login lands in a session named `dev` rooted
at `DEV_START_DIR`. Opt-outs: `touch ~/.no-auto-tmux` (permanent),
`NO_TMUX=1`, `DEV_TMUX_AUTOSTART=0`. Not triggered for non-interactive
shells, VS Code, emacs, forced SSH commands, or when already inside tmux.

**Hot reload:** when a server is already running, the script first resets it
to stock (`set -u` on every option, default key bindings replayed from a
throwaway `-f /dev/null` server), then sources the new config — because
sourcing never *unsets* anything and stale bindings would otherwise survive.
`DEV_TMUX_RESET=0` disables the reset.

**mosh** is installed; `mosh host` gives an SSH session that survives roaming
and sleep. It needs UDP 60000–61000, which the ufw section opens.

---

## 4. Tools, one by one

### 4.1 Installation mechanics for the "extras"

Tools that apt does not have on every release are listed in `BASE_PKGS`
anyway (absent packages are skipped silently), and then the extras section
runs `gh_bin <repo> <asset-regex> <binary…>` for each:

1. If the binary is already on PATH → "already present", nothing happens
   (unless `DEV_EXTRAS_UPGRADE=1`).
2. Otherwise the latest GitHub release is looked up (via `gh api` when gh is
   authenticated, else the anonymous API — 60 requests/hour) and the first
   asset matching the regex is downloaded.
3. A `.deb` goes through `apt-get install ./file.deb` (tracked by dpkg, man
   page included). Archives are unpacked and the named binaries copied to
   `~/.local/bin`.

Which route each tool takes on each release:

| Tool | 26.04 | 24.04 | Binary |
|---|---|---|---|
| lazygit | apt | release tar | `lazygit` |
| starship | apt | release tar | `starship` |
| atuin | apt | release tar | `atuin` |
| fastfetch | apt | release .deb | `fastfetch` |
| trippy | apt | release tar | `trip` |
| procs | apt | apt | `procs` |
| difftastic | release tar | release tar | `difft` |
| watchexec | release .deb | release .deb | `watchexec` |
| yazi | release .deb | release .deb | `yazi`, `ya` |
| onefetch | release .deb (amd64 only) | same | `onefetch` |
| jless | release zip (amd64 only) | same | `jless` |
| croc | release tar | release tar | `croc` |
| sops | release .deb | release .deb | `sops` |
| lazydocker, dive | release tar / .deb | same | `lazydocker`, `dive` |
| mise | own installer (`mise.run`) | same | `~/.local/bin/mise` |

There is no automatic upgrade for release-installed binaries; apt ones
upgrade with the system. `DEV_EXTRAS_UPGRADE=1 bash dev-bootstrap.sh`
refreshes all of them.

### 4.2 Git tooling

- **git** with global defaults: `pull.rebase`, `rebase.autoStash`,
  `fetch.prune`, `push.autoSetupRemote`, `merge.conflictstyle zdiff3`,
  `rerere` on, histogram diff, `branch.sort -committerdate`,
  `tag.sort version:refname`, `commit.verbose`, `help.autocorrect prompt`,
  credential cache 8 h, `safe.directory $DEV_ROOT/*`, global excludes file.
  Aliases: `st lg last unstage amend wip undo branches recent dft dlog dshow`.
- **delta** — the pager for `git diff/log/show` and `add -p`. Line numbers,
  `n`/`N` to jump between files, Catppuccin syntax theme when bat's theme
  installed, `OneHalfDark` otherwise.
- **difftastic** (`difft`) — structural, syntax-aware diff. Not the default
  view; reach it with `git dft` (difftool), `git dlog` (`log -p`), `git dshow`.
- **lazygit** (`lg`) — terminal git UI. Config
  `~/.config/lazygit/config.yml`: Catppuccin theme, delta as pager, file tree
  view, no Nerd Font, update check off. Inside: `space` stage, `c` commit,
  `P` push, `p` pull, `?` keybindings.
- **gh** — GitHub CLI (`gh auth login` once). Also used by the script to dodge
  API rate limits when authenticated.
- **git-lfs** installed system-wide; **onefetch** prints a repo summary.
- **pre-commit** (pipx) for hook management.

### 4.3 Editors

`DEV_EDITOR` (`nano` default) sets `$EDITOR`, `$VISUAL` and `core.editor`.

- **nano** — `~/.nanorc`: line numbers, mouse, soft wrap, 4-space tabs,
  auto-indent, position/history logs, Catppuccin (12-bit colours because
  nano rejects 24-bit under `tmux-256color`), desktop-style keys (Ctrl-S
  save, Ctrl-Q quit, Ctrl-F find, Ctrl-Z/Y undo/redo, Ctrl-C/X/V). A
  self-repair pass comments out any line this nano version rejects.
- **micro** — `~/.config/micro/settings.json` + Catppuccin colorscheme;
  `MICRO_TRUECOLOR=1`.
- **neovim** — replaced `vim`. `~/.config/nvim/init.lua` is plugin-free on
  purpose (nothing to clone, nothing to break over ssh): numbers, mouse,
  system clipboard (`xclip`/`wl-clipboard`, OSC 52 over ssh), 4-space
  indent (2 for JS/TS/JSON/YAML/HTML/CSS/Lua, tabs for Go/Make), smartcase
  search, persistent undo, `habamax` colorscheme, Space as leader:
  `<leader>w` save, `<leader>q` quit, `<leader>e` file browser, Ctrl-hjkl
  between splits, Esc clears search highlight. Your additions go in
  `~/.config/nvim/lua/local.lua` (loaded if present).

### 4.4 Search, files, text

- **ripgrep** (`rg`), **fd** (`fd` → `fdfind`), **fzf** (Ctrl-T files with
  bat preview, Alt-C directories, `**<Tab>` completion; themed), **bat**
  (`cat`; Catppuccin Mocha theme fetched into bat's theme dir, resolved name
  written to `theme.sh` so the shell never probes), **eza** (`ll` & co.),
  **zoxide** (`z dir`, `zi` interactive — learns from your `cd`s),
  **tree**, **sd** (sed replacement: `sd 'foo' 'bar' file`), **jq**, **yq**,
  **jless** (interactive JSON viewer: `jless file.json`, `curl … | jless`),
  **glow** (markdown in the terminal), **ast-grep** (`ast-grep` / `sg`:
  structural search/rewrite for TS, C#, Python… — note `sg` shadows the
  system setgid helper only in interactive shells), **plocate** (`locate`),
  **trash-cli** (`trash file` instead of `rm`), **dos2unix**, **moreutils**
  (`sponge`, `ts`, `vidir`…), **pv**, **tokei** (code statistics).
- **yazi** (`y`) — TUI file manager. The `y` wrapper passes `--cwd-file` so
  quitting with `q` leaves the shell in the directory you navigated to (`Q`
  quits without). `ya` is its package manager.
- **watchexec** (`wx`) — re-run a command on file changes; recursive,
  respects `.gitignore`, debounced. `wx -e cs -- dotnet test`,
  `wx -r -- npm start` (`-r` restarts a long-running process), `wx -w src
  -- make`. Replaced `entr`.
- **tldr** (tealdeer) — `tldr tar` gives examples instead of a man page.
  Cache fetched at bootstrap and auto-refreshed weekly
  (`~/.config/tealdeer/config.toml`).
- **just** — command runner (`justfile`), **direnv** — per-directory env
  (`.envrc`, `direnv allow`), **hyperfine** — benchmarking.

### 4.5 System and network

- **btop** (the process monitor; `bottom` deliberately not added), **htop**,
  **procs** (modern `ps`: `procs node`, `procs --tree`), **ncdu**, **dust**
  (`dust` — disk usage tree; *not* aliased over `du`), **duf** (`duf` — disk
  free; not aliased over `df`), **iotop**, **lsof**, **strace**.
- **gping** (`gping host1 host2` — graph), **trippy** (`trip host` — TUI
  traceroute + ping; given `cap_net_raw` at install so no sudo needed),
  **mtr**, **dnsutils** (`dig`), **socat**, **net-tools**, `ports` alias
  (`ss -tulpn`).
- **lnav** — log viewer: `lnav /var/log/syslog`, `journalctl -f | lnav`,
  auto-detects formats, `;` for SQL over log lines, `i` histogram.
- **fastfetch** — system summary, shown **once per login**: in tmux only in
  the server's first pane (`TMUX_PANE=%0`), otherwise only on a login shell
  that tmux is not about to take over. `reload` never repeats it.
  `DEV_FASTFETCH=0` disables. Config `~/.config/fastfetch/config.jsonc`.
- **croc** — send a file or folder to any other machine with a code phrase:
  `croc send file` → `croc <code>` on the other side. Relayed, end-to-end
  encrypted, no port forwarding.
- **age** + **sops** — `age-keygen -o key.txt`, then `sops` encrypts
  secrets files (`.env`, YAML, JSON) with age recipients so they can live in
  the repo. `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d secrets.yaml`.
- **ttyd** — see `tshare` below. **mosh** — see §3.

### 4.6 Languages and runtimes

- **Node.js** — from Ubuntu when its version ≥ `NODE_MAJOR` (26.04), else
  NodeSource (24.04 ships 18.x). npm prefix `~/.local`, so globals need no
  sudo. Globals: `npm typescript ts-node tsx eslint prettier
  typescript-language-server pyright pnpm nodemon pm2 mssql @ast-grep/cli`.
- **Python** — `python3`, venv, pip, dev headers; **uv** (`uv venv`, `uv
  pip`, `uvx tool`; `mkvenv` uses it); **pipx** tools: `ruff black isort
  ipython httpie sqlfluff pre-commit pgcli harlequin`.
- **.NET** — SDK from Ubuntu (26.04 → 10.0, 24.04 → 8.0), or Microsoft's
  `dotnet-install.sh` into `~/.dotnet` if the distro has none. `DOTNET_ROOT`
  is exported **only** for that private install. Global tools in
  `~/.dotnet/tools`: `csharp-ls` (the C# language server for Claude),
  `dotnet-ef`. Telemetry off, no logo.
- **mise** — per-project tool versions. It reads `.mise.toml`,
  `.tool-versions`, `.nvmrc`, `.python-version` and swaps the tool on `cd`
  (hooked into the prompt like direnv). **It is inert until a project pins
  something**: with no config file the apt Node and .NET stay in use.
  `mise use node@20` in a project writes the pin and installs that version
  under `~/.local/share/mise`. `mise ls`, `mise doctor`.

### 4.7 Databases

- **PostgreSQL client** — `psql` from PGDG (`postgresql-client-18`,
  falling back to Ubuntu's when PGDG has no suite yet), `libpq-dev`.
  `~/.psqlrc`: unicode borders, `[null]`, timing, lower-case keyword
  completion, per-database history, shortcuts `:activity :locks :dbsize
  :tablesize :uptime :version`. Pager `pspg`.
- **pgcli** (`pg`) — autocompleting psql.
- **harlequin** — TUI SQL IDE (`harlequin -a postgres postgres://…`,
  `harlequin -a odbc "Driver=…"` for SQL Server via the ODBC driver, or a
  sqlite file directly). Installed with the postgres adapter plus
  `harlequin-odbc`.
- **Microsoft SQL** — `sqlcmd` and `bcp` (`mssql-tools18`) plus the
  `msodbcsql18` ODBC driver in `/opt/mssql-tools18/bin`. Microsoft publishes
  no packages for 26.04, so the script probes their repos and installs the
  newest suite that has them (25.10), pinned so nothing *else* leaks from it;
  then the pool `.deb`s (checksum-verified); then go-sqlcmd as last resort.
  EULA pre-accepted. `sqlcmd` is aliased with `-C` (trust dev certificates).
- **sqlite3**, **sqlfluff** (SQL linter), **unixodbc**.

### 4.8 Docker

- **docker-ce** + `docker-buildx-plugin` + `docker-compose-plugin` from
  `download.docker.com` (deb822 source, key in `/etc/apt/keyrings/docker.asc`)
  when that repo has a suite for the release; otherwise Ubuntu's `docker.io`
  + `docker-compose-v2` + `docker-buildx`. Either way the CLI is `docker`
  and `docker compose`.
- The service is enabled, and the user is added to the `docker` group
  (effective at next login — `newgrp docker` for the current one).
- **lazydocker** (`lzd`) — TUI over containers, images, volumes and compose
  projects. **dive** — `dive image:tag` explores image layers and wasted
  space.
- Docker writes its own iptables chains and **bypasses ufw**: a port
  published with `-p` is reachable regardless of the firewall. Bind to
  `127.0.0.1:port:port` when that matters.

### 4.9 Sharing a terminal — `tshare`

`tshare user:password [port]` starts `ttyd` serving the `dev` tmux session
in a browser at `http://<ip>:7681/`, writable, with HTTP basic auth (the
credentials are mandatory by design — it is a full shell). Reachable from the
trusted networks only, unless you `ufw allow 7681/tcp` yourself. Ctrl-C
stops it.

### 4.10 Claude Code

- Installed with the native installer to `~/.local/bin/claude`
  (auto-updating). Aliases `cc`, `ccc` (continue), `ccr` (resume picker),
  `ccp` (plan mode), `ccdoc`.
- `~/.claude/statusline.sh` — Catppuccin status line: model · directory ·
  branch* · context % (green/peach/red) · session cost · output style.
- Seeded settings (only if missing): dark theme, the status line,
  `alwaysThinkingEnabled`, stable update channel, 90-day cleanup,
  `includeCoAuthoredBy: false`.
- Plugins from `claude-plugins-official`: `pyright-lsp`, `typescript-lsp`,
  `csharp-lsp`. A plugin only *declares* its language server; the binaries
  come from the node section (`pyright`, `typescript-language-server`) and
  the .NET section (`csharp-ls`), and the run checks each is on PATH.
- Worth running once after a week of use: `/fewer-permission-prompts`.

---

## 5. Security and system tuning

### 5.1 ufw

Installed and enabled with: default **deny incoming, allow outgoing**;
SSH allowed on **every port sshd actually listens on** (`sshd -T`, default
22); mosh UDP 60000–61000; and **everything allowed from each network in
`DEV_UFW_TRUST`** (default: all of RFC 1918 — `10/8`, `172.16/12`,
`192.168/16`). So on a box reached over a LAN or VPN the firewall only bites
on a public interface, and dev servers on :3000/:5000/:8000 stay reachable.

Safety: the SSH rule is added *before* `ufw --force enable`, and enabling is
skipped if it failed. An already-active ufw only gets the rules refreshed
(`ufw allow` is idempotent). `sudo ufw status numbered` to inspect, `sudo ufw
delete <n>` to remove, `sudo ufw disable` to turn off.

### 5.2 fail2ban

`/etc/fail2ban/jail.d/dev-bootstrap-sshd.local`: sshd jail, `backend =
systemd` (Ubuntu has no `/var/log/auth.log` without rsyslog), 5 failures in
10 minutes → 1 hour ban, `ignoreip` = localhost + `DEV_UFW_TRUST`, so a typo
from your own network never bans you. `sudo fail2ban-client status sshd`,
`sudo fail2ban-client set sshd unbanip <ip>`.

### 5.3 unattended-upgrades

`/etc/apt/apt.conf.d/20auto-upgrades`: package lists daily, unattended
upgrade daily, autoclean weekly. Origins are Ubuntu's defaults (security
pocket). Logs: `/var/log/unattended-upgrades/`.

### 5.4 Kernel and limits

- `fs.inotify.max_user_watches=524288`, `max_user_instances=1024`,
  `max_queued_events=32768` — `dotnet watch`, vite, tsc `--watch` and
  language servers silently break on the defaults.
- Open files: soft 65535, hard 1048576 (`/etc/security/limits.d/`), applied
  at next login; the 1024 default breaks `tsc --watch` and pytest-xdist.
- `~/.ssh/config`: `ServerAliveInterval 60`, `ServerAliveCountMax 5`,
  `AddKeysToAgent yes`.
- `umask 002` in interactive shells so files under `/srv/dev` stay
  group-writable.

---

## 6. Theme

Everything is **Catppuccin Mocha**, without Nerd Font glyphs:

| Where | How |
|---|---|
| tmux | hex colours in `~/.tmux.conf` |
| starship | `[palettes.catppuccin_mocha]` in `starship.toml` |
| bash fallback prompt | truecolor escapes in `__prompt` |
| bat / delta | `.tmTheme` fetched into `$(bat --config-dir)/themes`; name in `theme.sh` |
| fzf | `FZF_DEFAULT_OPTS` colours |
| `ls` colours | `vivid generate catppuccin-mocha` → `LS_COLORS` |
| nano | 12-bit approximations (`#8bf`, `#caf`…) |
| micro | `catppuccin-mocha.micro` colorscheme |
| lazygit | `gui.theme` in `config.yml` |
| Claude status line | truecolor escapes in `statusline.sh` |
| neovim | built-in `habamax` (closest without a plugin) |

Base `#1e1e2e`, text `#cdd6f4`, blue `#89b4fa`, mauve `#cba6f7`, green
`#a6e3a1`, peach `#fab387`, red `#f38ba8`, yellow `#f9e2af`, overlay0
`#6c7086`.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No aliases or prompt after `ssh` | the login file did not source `~/.bashrc`; re-run the script (it adds the bridge and warns), or check `~/.bash_profile` for an early `exit`/`exec` |
| Ctrl-R shows plain bash search | atuin missing, or `bash-preexec.sh` failed to download (the extras section warns); re-run |
| Prompt is the old bash one | starship not installed, or `DEV_PROMPT=bash` in `local.sh` |
| `reload` prints errors about `;;` | fixed in 5.7.0 — re-run to regenerate `rc.sh` |
| tmux keeps old bindings | the server predates the config; `tmux kill-server` or re-run (`DEV_TMUX_RESET=1`) |
| `docker: permission denied` | group membership needs a new login (`newgrp docker`) |
| A published container port is reachable despite ufw | Docker bypasses ufw by design; bind to `127.0.0.1` |
| Locked out of SSH by fail2ban | from a trusted network it cannot happen (`ignoreip`); otherwise `fail2ban-client set sshd unbanip <ip>` from the console |
| `tldr` says cache is missing | `tldr --update` (needs network) |
| `trip` asks for root | `sudo setcap cap_net_raw+ep $(command -v trip)` |
| GitHub-release tool missing after a run | anonymous API limit (60/h) hit — `gh auth login` or wait, then re-run; the summary lists it under "Did not complete" |
| apt errors about duplicate `Signed-By` | another installer added a second source for the same repo; `bash dev-bootstrap.sh --clean-only`, remove the other, re-run |
| `sg` runs ast-grep instead of the setgid tool | expected in interactive shells (`~/.local/bin` first on PATH); use `/usr/bin/sg` or `ast-grep` |

Everything the run could not complete is printed at the end under
**"Did not complete"**; `bash dev-bootstrap.sh` again retries only those.
