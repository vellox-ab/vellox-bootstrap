# vellox-bootstrap

`dev-bootstrap.sh` — one-file bootstrap for an Ubuntu developer machine.

Supports **Ubuntu 24.04 LTS (noble)** and **26.04 LTS (resolute)** from the same
file. Everything release-specific is detected at runtime, so there is nothing to
edit per machine.

## Usage

Run as your normal user — **not** root, **not** with `sudo`. The script asks for
`sudo` where it needs it and keeps the credential alive for the duration.

```bash
bash dev-bootstrap.sh                  # everything
bash dev-bootstrap.sh --clean-only     # only remove the apt artifacts we created
bash dev-bootstrap.sh --help
```

### On a brand-new server

```bash
curl -fsSL https://raw.githubusercontent.com/vellox-ab/vellox-bootstrap/main/dev-bootstrap.sh | bash
```

Keeping the file around is nicer — re-runs, `--help` and `--clean-only` all
work from it:

```bash
curl -fsSL https://raw.githubusercontent.com/vellox-ab/vellox-bootstrap/main/dev-bootstrap.sh \
  -o dev-bootstrap.sh && bash dev-bootstrap.sh
```

Sections can be skipped, and a few settings overridden, with environment
variables:

```bash
SKIP_MSSQL=1 bash dev-bootstrap.sh
DEV_ROOT=/srv/dev DEV_EDITOR=micro bash dev-bootstrap.sh
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `DEV_ROOT` | `/srv/dev` | Shared development folder |
| `DEV_GROUP` | `devgroup` | Group that owns `DEV_ROOT` |
| `NODE_MAJOR` | `22` | Minimum acceptable Node major version |
| `DOTNET_MAJOR` | empty | Pin an SDK major; empty takes the newest the distro has |
| `DOTNET_TOOLS` | `csharp-ls dotnet-ef` | .NET global tools to install |
| `PG_MAJOR` | `18` | Preferred PGDG client major version |
| `DEV_EDITOR` | `nano` | `nano`, `micro` or `vim` |
| `DEV_TMUX_AUTOSTART` | `1` | Attach tmux on login |
| `DEV_TMUX_RESET` | `1` | Clear stale options/bindings out of a running tmux server before reloading |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | empty | Git identity; setting **both** skips the prompt |
| `CLAUDE_PLUGINS` | `pyright-lsp typescript-lsp csharp-lsp` | Plugins to install from `claude-plugins-official` |

Skip flags: `SKIP_SYSTEM`, `SKIP_NODE`, `SKIP_PYTHON`, `SKIP_MSSQL`,
`SKIP_DOTNET`, `SKIP_POSTGRES`, `SKIP_CLAUDE`, `SKIP_TMUX_CONF`, `SKIP_SHELL_CONF`,
`SKIP_EDITOR_CONF`, `SKIP_SYSCTL`, `SKIP_GIT_CONF`, `SKIP_GIT_IDENTITY`,
`SKIP_CLAUDE_CONF`, `SKIP_INPUTRC`, `SKIP_LEGACY_CLEAN` — set any of them to `1`.

### Git identity

Near the start of the run the script asks for the name and email to use as the
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
GIT_USER_NAME='Your Name' GIT_USER_EMAIL=you@example.com bash dev-bootstrap.sh
SKIP_GIT_IDENTITY=1 bash dev-bootstrap.sh    # never ask, leave the identity alone
```

The prompt reads from `/dev/tty`, so it also works when the script is piped into
`bash`. With no terminal attached it is skipped, and the git section warns if the
identity is still unset at the end.

## What it installs and configures

- **System packages** — build toolchain, `git`/`git-lfs`/`gh`/`git-delta`,
  archive tools, `tmux`, editors (`vim`, `nano`, `micro`), modern CLI tools
  (`ripgrep`, `fd`, `fzf`, `bat`, `eza`, `zoxide`, `direnv`, `jq`, `yq`, `just`,
  `dust`, `duf`, `btop`, `hyperfine`, `tokei`, …), networking and diagnostic
  tools, `sqlite3`, `shellcheck`, `shfmt`, ODBC and build headers.
- **Node.js** — from NodeSource when the distro version is older than
  `NODE_MAJOR`.
- **Python** — `python3` with `venv`/`pip`/`dev`, `pipx`, `uv`, and the pipx
  tools `ruff`, `black`, `isort`, `ipython`, `httpie`, `sqlfluff`, `pre-commit`
  and `pgcli`.
- **.NET** — the SDK from Ubuntu itself (26.04 → 10.0, 24.04 → 8.0); if the
  release carries none, Microsoft's official installer puts a private copy in
  `~/.dotnet`. Global tools from `DOTNET_TOOLS` land in `~/.dotnet/tools`:
  `dotnet-ef` for EF Core, and `csharp-ls` because that is the binary the
  `csharp-lsp` plugin runs. `DOTNET_ROOT` is exported **only** for the private
  install — setting it against an apt-installed SDK breaks every `dotnet`
  command.
- **Claude Code** — installed to `~/.local/bin/claude` (alias `cc`), plus:
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
- **tmux** — a full `tmux.conf` with Catppuccin Mocha, vi copy mode, sane splits
  and navigation, applied to a running server as well as to new ones (see
  [Existing config on the machine](#existing-config-on-the-machine)).
- **Shell** — `~/.config/dev-bootstrap/rc.sh` with PATH, truecolor, a shared-dev
  umask, history tuning, a git-aware Catppuccin prompt, and aliases for listing,
  git, databases, tmux, Python and misc tools. Your own overrides live in
  `~/.config/dev-bootstrap/local.sh` and are never overwritten.
- **Completions and `inputrc`** — history search on the arrow keys, word-wise
  movement, working Home/End in every terminal flavour.
- **Editor config** — for whichever `DEV_EDITOR` you chose.
- **git config** — the identity you are asked for, global defaults, `delta` as
  the pager, `tag.sort=version:refname`.
- **Microsoft SQL tooling** — `sqlcmd` / `bcp` (`mssql-tools18`) and the
  `msodbcsql18` ODBC driver. Microsoft publishes no SQL packages for 26.04
  (resolute), so the script probes their repos live and installs the newest
  suite that actually has them (25.10 today), pinned so nothing *else* from
  that suite can leak in. If the repo route fails it installs the checksum-
  verified `.deb` files straight from the pool, and failing that, go-sqlcmd.
- **PostgreSQL client** — `psql` from PGDG, plus a `psql` pager setup.
- **System tuning** — raised inotify limits (file watchers and agentic tooling),
  open-file limit lifted from the 1024 default, SSH keepalives.

At the end it verifies the login-shell wiring, prints the version of everything
it installed, and lists anything that did not complete.

## Existing config on the machine

A box that has been set up before does not become this box just because new
files are written — the old settings keep running. So before anything is
written, the script clears out what would fight it. `SKIP_LEGACY_CLEAN=1` turns
all of it off.

- **The files it writes, it owns.** `~/.tmux.conf`, `~/.inputrc`, `~/.nanorc`,
  `~/.psqlrc`, `~/.gitignore_global`, the micro config and
  `~/.claude/statusline.sh` are written whole, so a re-run always lands on the
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
  them for the release it is actually running on. Sources it did not create are
  listed but never touched.
- **No `set -e`.** A single failing repo must never leave the machine
  half-configured. Failures are collected and reported at the end, and
  re-running retries only those steps.
- **apt 3.x aware.** apt ≥ 3 verifies signatures with `sqv` and treats duplicate
  `Signed-By` values for one repo as a fatal error — the cleanup pass exists
  largely to keep that from happening.

## Version

Current version: **5.5.0** (see `VERSION`).
