# vellox-bootstrap

Two scripts bootstrap an Ubuntu developer machine:

| Script | Run as | Does |
| --- | --- | --- |
| `dev-bootstrap-system.sh` | **root**, once per machine | apt packages, Node, .NET SDK, Postgres/SQL Server clients, Docker, extra tools in `/usr/local/bin`, kernel and file limits, hardening |
| `dev-bootstrap-user.sh` | **each developer, as themselves** — no sudo | shell, tmux, editor, git and Claude Code config; npm globals, uv/pipx tools, .NET global tools, mise, Claude Code / Codex |

Run the system one first: the user one configures what it installed, and
stops early if `git`, `jq`, `tmux` or `curl` is missing.

Supports **Ubuntu 24.04 LTS (noble)** and **26.04 LTS (resolute)**.
Everything release-specific is detected at runtime, so there is nothing to
edit per machine.

For what every installed tool does, where its config lives and how the
pieces fit together, see **[MANUAL.md](MANUAL.md)** — written so a person or
an AI session can answer "how does X work on this machine?" without reading
the scripts.

## Usage

```bash
sudo bash dev-bootstrap-system.sh                 # the machine (asks nothing)
sudo bash dev-bootstrap-system.sh --clean-only    # only remove the apt artifacts we created
bash dev-bootstrap-user.sh                        # you (asks identity, start folder, agent)
bash dev-bootstrap-system.sh --help               # either script
```

### On a brand-new server

```bash
curl -fsSL https://raw.githubusercontent.com/vellox-ab/vellox-bootstrap/main/dev-bootstrap-system.sh | sudo bash
curl -fsSL https://raw.githubusercontent.com/vellox-ab/vellox-bootstrap/main/dev-bootstrap-user.sh | bash
```

Keeping the files around is nicer — re-runs, `--help` and `--clean-only` all
work from them:

```bash
for f in dev-bootstrap-system.sh dev-bootstrap-user.sh; do
  curl -fsSL "https://raw.githubusercontent.com/vellox-ab/vellox-bootstrap/main/$f" -o "$f"
done
sudo bash dev-bootstrap-system.sh && bash dev-bootstrap-user.sh
```

A new developer on an existing machine only needs the user script.

Sections can be skipped, and a few settings overridden, with environment
variables (with `sudo`, put them after it: `sudo SKIP_MSSQL=1 bash ...`):

```bash
sudo SKIP_MSSQL=1 bash dev-bootstrap-system.sh
sudo DEV_EXTRAS_UPGRADE=1 bash dev-bootstrap-system.sh   # re-fetch the GitHub-release tools
sudo NODE_MAJOR=current bash dev-bootstrap-system.sh     # newest Node major, not newest LTS
DEV_ROOT=/srv/dev DEV_EDITOR=micro bash dev-bootstrap-user.sh
```

| Variable | Script | Default | Meaning |
| --- | --- | --- | --- |
| `NODE_MAJOR` | system | `lts` | `lts` (newest LTS), `current` (newest major) or a major number |
| `DOTNET_MAJOR` | system | empty | Pin an SDK major; empty takes the newest the distro has |
| `PG_MAJOR` | system | empty | Pin a PGDG client major; empty takes the newest |
| `DEV_UFW_TRUST` | system | empty | Networks ufw allows on every port and fail2ban never bans |
| `DEV_EXTRAS_UPGRADE` | both | `0` | `1` re-downloads the GitHub-release tools (system) and mise / bash-preexec (user) |
| `DEV_ROOT` | user | `/srv/dev` | Shared development folder |
| `DEV_GROUP` | user | `devgroup` | Group that owns `DEV_ROOT` (you are warned if not in it) |
| `DOTNET_TOOLS` | user | `csharp-ls dotnet-ef` | .NET global tools to install |
| `DEV_EDITOR` | user | `nano` | `nano`, `micro` or `nvim` |
| `DEV_TMUX_AUTOSTART` | user | `1` | Attach tmux on login |
| `DEV_START_DIR` | user | asked for | Folder every login starts in; setting it skips the prompt |
| `DEV_AI_AGENTS` | user | asked for | `claude`, `codex`, `both` or `none`; setting it skips the prompt |
| `DEV_TMUX_RESET` | user | `1` | Clear stale options/bindings out of a running tmux server before reloading |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | user | empty | Git identity; setting **both** skips the prompt |
| `CLAUDE_PLUGINS` | user | `pyright-lsp typescript-lsp csharp-lsp` | Plugins to install from `claude-plugins-official` |

Skip flags — set any of them to `1`:

- system: `SKIP_SYSTEM`, `SKIP_NODE` (NodeSource), `SKIP_DOTNET` (the SDK),
  `SKIP_MSSQL`, `SKIP_POSTGRES`, `SKIP_EXTRAS`, `SKIP_DOCKER`,
  `SKIP_HARDENING`, `SKIP_SYSCTL`, `SKIP_AUTOREMOVE`
- user: `SKIP_NODE` (npm globals), `SKIP_PYTHON`, `SKIP_DOTNET` (global
  tools), `SKIP_EXTRAS` (mise, bash-preexec, tldr cache, atuin import),
  `SKIP_CLAUDE`, `SKIP_CODEX`, `SKIP_CLAUDE_CONF`, `SKIP_TMUX_CONF`,
  `SKIP_SHELL_CONF`, `SKIP_EDITOR_CONF`, `SKIP_GIT_CONF`, `SKIP_GIT_IDENTITY`,
  `SKIP_INPUTRC`, `SKIP_LEGACY_CLEAN`, `SKIP_START_DIR`

The three questions below are all asked by the user script.

### Git identity

Near the start of the run the user script asks for the name and email to use as the
global git identity, and writes them to `user.name` / `user.email` in
`~/.gitconfig`:

```
==> Git identity
    stamped on every commit you make on this machine (git config --global)
    Full name:     Your Name
    Email:         you@example.com
```

Whatever git already has is offered as the default — press Enter to keep it. The
email is checked for a basic `local@domain.tld` shape. Answering up front, or not
at all:

```bash
GIT_USER_NAME='Your Name' GIT_USER_EMAIL=you@example.com bash dev-bootstrap-user.sh
SKIP_GIT_IDENTITY=1 bash dev-bootstrap-user.sh    # never ask, leave the identity alone
```

The prompt reads from `/dev/tty`, so it also works when the script is piped into
`bash`. With no terminal attached it is skipped, and the git section warns if the
identity is still unset at the end.

### Start folder

Right after the identity, the script asks which folder a login should start in:

```
==> Start folder
    every login starts here: the tmux session opens in it, and so does a
    login shell when the tmux autostart is off
    Folder         [/srv/dev]:
```

The default is your previous answer, or `DEV_ROOT` if it exists, or `$HOME` — so
the first run is one keystroke and every re-run after it is just Enter. A `~` is
expanded, a relative path is refused, and a folder that does not exist yet is
offered for creation.

The answer ends up in two places at login: `tmux new-session -c` when the tmux
autostart creates the `dev` session, and a `cd` for a login shell that starts in
`$HOME` when it does not. A shell that was deliberately started somewhere else
(`ssh host -t 'cd /x && bash -l'`, a new tmux pane, VS Code) is never moved.

```bash
DEV_START_DIR=/srv/dev/app bash dev-bootstrap-user.sh   # answer up front
SKIP_START_DIR=1 bash dev-bootstrap-user.sh             # never ask
```

To change it later, re-run with `DEV_START_DIR=...`, or set it in
`~/.config/dev-bootstrap/local.sh` — that file is sourced before either of the
two places above reads the value, so it takes effect on the next login with no
re-run at all.

### AI coding agents

The third question is which AI coding agent to install:

```
==> AI coding agents
    claude = Claude Code, codex = OpenAI Codex, both, or none
    Which?         [claude]:
```

The default is your previous answer (`claude` on the first run), so a re-run is
just Enter. The choice only governs installation: an agent already on the
machine is never removed, and the config sections still apply to whatever is
present.

```bash
DEV_AI_AGENTS=both bash dev-bootstrap-user.sh    # answer up front (claude|codex|both|none)
SKIP_CLAUDE=1 / SKIP_CODEX=1                # veto one regardless of the answer
```

## What it installs and configures

- **System packages** — build toolchain, `git`/`git-lfs`/`gh`/`git-delta`,
  archive tools, `tmux`, editors (`neovim`, `nano`, `micro`), modern CLI tools
  (`ripgrep`, `fd`, `fzf`, `bat`, `eza`, `zoxide`, `direnv`, `jq`, `yq`, `just`,
  `dust`, `duf`, `btop`, `procs`, `hyperfine`, `tokei`, `tldr`, …), networking
  and diagnostic tools (`mosh`, `gping`, `trippy`, `lnav`, `ttyd`, `age`),
  `sqlite3`, `shellcheck`, `shfmt`, ODBC and build headers.
- **Extra tools** — the ones apt does not have on every release, installed from
  apt where it does (26.04 carries most of them) and from the project's latest
  GitHub release otherwise — a `.deb` through apt when one is published, a
  binary in `/usr/local/bin` (for every user) if not:
  - `lazygit` (`lg`) with a Catppuccin config and delta as its pager
  - `starship` as the prompt, same palette and layout as the built-in one, no
    Nerd Font glyphs (`DEV_PROMPT=bash` in `local.sh` brings the old one back)
  - `atuin` for shell history — SQLite, fuzzy **Ctrl-R**, your existing
    `~/.bash_history` imported once; local only, no sync account. fzf keeps
    Ctrl-T and Alt-C, and Up/Down keep the prefix search from `~/.inputrc`
  - `mise` for per-project tool versions (`.mise.toml`, `.nvmrc`, …); inert
    until a project pins something, so the apt Node and .NET stay the defaults
  - `watchexec` (`wx`) instead of `entr` — recursive and `.gitignore`-aware
  - `difftastic` as `git dft` / `git dlog` / `git dshow`; delta stays the pager
  - `yazi` (`y`, the shell follows it), `jless`, `croc`, `sops`, `onefetch`,
    `fastfetch` (shown once per login, `DEV_FASTFETCH=0` turns it off),
    `harlequin` (TUI SQL IDE, Postgres + ODBC adapters), `ast-grep`
- **Docker** — `docker-ce` with buildx and the compose plugin from Docker's own
  repo, or Ubuntu's `docker.io` + `docker-compose-v2` while that repo has no
  suite for the release yet; whoever ran `sudo` is added to the `docker` group
  (others: `sudo usermod -aG docker <user>`). An
  installed docker-ce keeps its source so `apt upgrade` updates it — the
  script never upgrades it itself, as that restarts every container. Plus
  `lazydocker` (`lzd`) and `dive`.
- **Hardening** — `unattended-upgrades` for security updates, `fail2ban` on
  sshd (systemd backend, trusted ranges ignored), and `ufw` with incoming
  denied by default — SSH (on whatever port sshd really listens on) and mosh
  open from everywhere, everything open from `DEV_UFW_TRUST` — empty by
  default, so it is safe on production and any other port is opened on
  purpose. Trusted ranges an earlier run added are removed when no longer
  listed. The SSH rule is added *before* the firewall is enabled, and
  enabling is skipped if that rule failed.
- **Node.js** — the newest LTS (or `NODE_MAJOR=current` / a pinned major)
  from NodeSource on both releases, upgraded on every run, plus the latest
  npm globals: `npm`, `pnpm`, `yarn`, `typescript@6`, `tsx`,
  `typescript-language-server`, `pyright`, `eslint`, `prettier`,
  `npm-check-updates`, `nodemon`, `pm2`, `mssql`, `@ast-grep/cli`.
  TypeScript stays on 6 globally: 7 ships no `tsserver.js`, which the
  TypeScript language server needs.
- **Python** — `python3` with `venv`/`pip`/`dev`, `pipx`, `uv`, and the pipx
  tools `ruff`, `black`, `isort`, `ipython`, `httpie`, `sqlfluff`, `pre-commit`,
  `pgcli` and `harlequin`.
- **.NET** — the SDK from Ubuntu itself (26.04 → 10.0, 24.04 → 8.0); if the
  release carries none, Microsoft's official installer puts a private copy in
  `~/.dotnet`. Global tools from `DOTNET_TOOLS` land in `~/.dotnet/tools`:
  `dotnet-ef` for EF Core, and `csharp-ls` because that is the binary the
  `csharp-lsp` plugin runs. `DOTNET_ROOT` is exported **only** for the private
  install — setting it against an apt-installed SDK breaks every `dotnet`
  command.
- **Claude Code** — installed to `~/.local/bin/claude` (alias `cc`) when chosen
  at the agents prompt (the default), plus:
  - `~/.claude/statusline.sh`, a Catppuccin Mocha status line showing model,
    directory, git branch, context use and session cost. Fully managed —
    rewritten on every run.
  - defaults seeded into `~/.claude/settings.json`: `theme`, the status line,
    `alwaysThinkingEnabled`, `autoUpdatesChannel: stable`,
    `cleanupPeriodDays: 90`, `includeCoAuthoredBy: false`. Only keys that are
    **missing** are added, so anything you set with `/config` survives a re-run,
    and MCP servers are never touched — configure those by hand.
  - the `claude-plugins-official` marketplace, and the language-server plugins
    in `CLAUDE_PLUGINS` — Pyright, TypeScript and C# — which give Claude real
    definitions and diagnostics instead of grep, at zero context cost (the
    servers run out of process).

    An LSP plugin only *declares* its server command; it never installs it. So
    the servers come from the other sections — `pyright` and
    `typescript-language-server` as npm globals, `csharp-ls` as a .NET tool —
    and the run ends by checking each declared server is really on `PATH`,
    because a plugin whose binary is missing loads happily and then does
    nothing.

  Worth doing by hand afterwards: run `/fewer-permission-prompts` in a session
  once you have a week of history. It reads your transcripts and writes a
  correct `permissions.allow` list for the commands you keep approving — better
  than any list guessed up front.
- **OpenAI Codex** — installed as an npm global (`@openai/codex`) when chosen at
  the agents prompt, so it lands in `~/.local/bin/codex`; every re-run
  upgrades it. Aliases `cx`, `cxc` (resume latest), `cxr`
  (resume picker). Its config (`~/.codex/`) is left entirely alone.
- **tmux** — a full `tmux.conf` with Catppuccin Mocha, vi copy mode, sane splits
  and navigation, applied to a running server as well as to new ones (see
  [Existing config on the machine](#existing-config-on-the-machine)).
- **Shell** — `~/.config/dev-bootstrap/rc.sh` with PATH, truecolor, a shared-dev
  umask, history tuning, the starship prompt (with the git-aware Catppuccin
  bash prompt as fallback), coloured man pages through bat, aliases for
  listing, git, docker, databases, tmux, Python and misc tools, and the start
  folder every login lands in. Your own overrides live in
  `~/.config/dev-bootstrap/local.sh` and are never overwritten.
- **Completions and `inputrc`** — history search on the arrow keys, word-wise
  movement, working Home/End in every terminal flavour.
- **Editor and tool config** — nano, micro and a plugin-free neovim
  `init.lua`, plus `starship.toml`, atuin, lazygit, tealdeer and fastfetch
  configs — all Catppuccin Mocha, all written whole and backed up once.
- **git config** — the identity you are asked for, global defaults, `delta` as
  the pager, `difftastic` as the difftool, `tag.sort=version:refname`.
- **Microsoft SQL tooling** — `sqlcmd` / `bcp` (`mssql-tools18`) and the
  `msodbcsql18` ODBC driver. Microsoft publishes no SQL packages for 26.04
  (resolute), so the script probes their repos live and installs the newest
  suite that actually has them (25.10 today), pinned so nothing *else* from
  that suite can leak in. If the repo route fails it installs the checksum-
  verified `.deb` files straight from the pool, and failing that, go-sqlcmd.
- **PostgreSQL client** — the newest `psql` / `pg_dump` from PGDG, `libpq-dev`,
  plus a `psql` pager setup.
- **System tuning** — raised inotify limits (file watchers and agentic tooling),
  open-file limit lifted from the 1024 default (system); SSH keepalives in
  `~/.ssh/config` (user).

At the end it verifies the login-shell wiring, prints the version of everything
it installed, and lists anything that did not complete.

## Existing config on the machine

A box that has been set up before does not become this box just because new
files are written — the old settings keep running. So before anything is
written, the script clears out what would fight it. `SKIP_LEGACY_CLEAN=1` turns
all of it off.

- **The files it writes, it owns.** `~/.tmux.conf`, `~/.inputrc`, `~/.nanorc`,
  `~/.psqlrc`, `~/.gitignore_global`, the micro, neovim, starship, atuin,
  lazygit, tealdeer and fastfetch configs and `~/.claude/statusline.sh` are
  written whole, so a re-run always lands on the
  same content. What was there before the *first* run is kept as
  `<file>.pre-bootstrap`, once — a later run never overwrites that copy with
  one of our own generated files. The exception stays the exception:
  `~/.claude/settings.json` is yours, and only missing keys are seeded.
- **Symlinks are removed, not written through.** If a dotfile manager (stow,
  chezmoi, oh-my-tmux) has `~/.tmux.conf` pointing into a repo, `cat >` would
  silently rewrite the file in that repo. The link goes instead; its target is
  left exactly as it is.
- **Old `dev-bootstrap` blocks go**, in every startup file — including one left
  behind in a file this run no longer hooks, and duplicates from older runs.
- **A tmux autostart of your own is commented out** (with the file backed up
  first). `exec tmux` replaces the shell and `tmux attach` blocks until you
  detach, so either way every line after it — including the one that loads all
  of this — never runs. Ours is the one that stays; set
  `DEV_TMUX_AUTOSTART=0` if you would rather keep yours.
- **A running tmux server is put back to stock before the new config is
  applied.** Sourcing a config never *un*sets anything, so options and key
  bindings from the config that was live when the server started survive until
  the last session dies — the classic "I rewrote `tmux.conf` and half of it did
  nothing". Global, per-session and per-window options are reset to their
  defaults, the default key bindings are read out of a throwaway server started
  with `-f /dev/null` and replayed, and only then is `~/.tmux.conf` sourced.
  `DEV_TMUX_RESET=0` leaves a running server alone.
- **git settings are written with `--replace-all`.** A plain
  `git config --global key value` *fails* when the key appears twice in
  `~/.gitconfig`, which is the normal state after a few hand edits or a merged
  dotfile repo. `safe.directory` is the one that is added rather than replaced,
  so the entries you added yourself survive.
- **What cannot be overwritten is reported**: an `INPUTRC` or
  `GIT_CONFIG_GLOBAL` pointing elsewhere, a `~/.gitconfig` `include.path` that
  overrides everything below it, a leftover TPM plugin tree, `/etc/tmux.conf`.

Everything moved aside is listed again at the end of the run.

## Design notes

- **Idempotent and self-cleaning.** Every re-run first removes the apt sources
  and keyrings that earlier versions of this script created, then re-derives
  them for the release it is actually running on — for tools that are already
  installed too, so apt keeps updating them. Sources it did not create are
  listed but never touched.
- **Leaves nothing unused behind.** npm globals it no longer installs are
  uninstalled, stale copies in `~/.local/bin` go once the system install (apt,
  `/usr/local/bin` or mssql-tools18) provides the same version or newer, and the run ends by removing dangling links,
  running `apt autoremove --purge`, and purging what removed kernels and Node
  packages left behind. Database servers, Docker and the bootloader are never
  removed — purging them deletes data or boot config — and other leftovers
  of packages removed by hand are listed, not purged. `SKIP_AUTOREMOVE=1`
  only lists.
- **System and user are separate.** Everything outside your home directory
  happens in the root script, everything inside it in the user script, so a
  developer without sudo rights can set themselves up on a shared machine.
- **No `set -e`.** A single failing repo must never leave the machine
  half-configured. Failures are collected and reported at the end, and
  re-running retries only those steps.
- **apt 3.x aware.** apt ≥ 3 verifies signatures with `sqv` and treats duplicate
  `Signed-By` values for one repo as a fatal error — the cleanup pass exists
  largely to keep that from happening.

## Version

Current version: **6.0.0** (see `VERSION`).
