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
| `PG_MAJOR` | `18` | Preferred PGDG client major version |
| `DEV_EDITOR` | `nano` | `nano`, `micro` or `vim` |
| `DEV_TMUX_AUTOSTART` | `1` | Attach tmux on login |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | empty | Baked into the global git config |

Skip flags: `SKIP_SYSTEM`, `SKIP_NODE`, `SKIP_PYTHON`, `SKIP_MSSQL`,
`SKIP_POSTGRES`, `SKIP_CLAUDE`, `SKIP_TMUX_CONF`, `SKIP_SHELL_CONF`,
`SKIP_EDITOR_CONF`, `SKIP_SYSCTL`, `SKIP_GIT_CONF`, `SKIP_INPUTRC` — set any of
them to `1`.

## What it installs and configures

- **System packages** — build toolchain, `git`/`git-lfs`/`gh`/`git-delta`,
  archive tools, `tmux`, editors (`vim`, `nano`, `micro`), modern CLI tools
  (`ripgrep`, `fd`, `fzf`, `bat`, `eza`, `zoxide`, `direnv`, `jq`, `yq`, `just`,
  `dust`, `duf`, `btop`, `hyperfine`, `tokei`, …), networking and diagnostic
  tools, `sqlite3`, `shellcheck`, `shfmt`, ODBC and build headers.
- **Node.js** — from NodeSource when the distro version is older than
  `NODE_MAJOR`.
- **Python** — `python3` with `venv`/`pip`/`dev`, `pipx`, and `uv`.
- **Claude Code** — installed to `~/.local/bin/claude` (alias `cc`).
- **tmux** — a full `tmux.conf` with Catppuccin Mocha, vi copy mode, sane splits
  and navigation.
- **Shell** — `~/.config/dev-bootstrap/rc.sh` with PATH, truecolor, a shared-dev
  umask, history tuning, a git-aware Catppuccin prompt, and aliases for listing,
  git, databases, tmux, Python and misc tools. Your own overrides live in
  `~/.config/dev-bootstrap/local.sh` and are never overwritten.
- **Completions and `inputrc`** — history search on the arrow keys, word-wise
  movement, working Home/End in every terminal flavour.
- **Editor config** — for whichever `DEV_EDITOR` you chose.
- **git config** — global defaults, `delta` as the pager, `tag.sort=version:refname`.
- **Microsoft SQL tooling** — `sqlcmd` / `mssql-tools18` and the ODBC driver.
- **PostgreSQL client** — `psql` from PGDG, plus a `psql` pager setup.
- **System tuning** — raised inotify limits (file watchers and agentic tooling),
  open-file limit lifted from the 1024 default, SSH keepalives.

At the end it verifies the login-shell wiring, prints the version of everything
it installed, and lists anything that did not complete.

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

Current version: **5.0.0** (see `VERSION`).
