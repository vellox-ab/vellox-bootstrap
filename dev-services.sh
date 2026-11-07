#!/usr/bin/env bash
# Shared dev services: a project's dev server runs as the system account vellox-dev (group devgroup), not as one person,
# survives a reboot, and every devgroup member restarts it without a password.
#
#   sudo bash dev-services.sh install /srv/dev/vellox-engine /srv/dev/vellox-one   # installs <repo>/deploy/dev/*.service
#   sudo bash dev-services.sh status
#
# install, per run:
#   1. the account vellox-dev (system, no login, home /var/lib/vellox-dev, primary group devgroup) and git's
#      safe.directory for /srv/dev/* (the repos belong to other people)
#   2. every unit in <repo>/deploy/dev/ copied to /etc/systemd/system/ (a unit must say User=vellox-dev)
#   3. /etc/sudoers.d/vellox-dev-services: devgroup may start, stop and restart exactly those units (listed by name,
#      never a wildcard: a wildcard in sudoers also matches extra arguments)
#   4. devgroup's members in systemd-journal, so journalctl -u <unit> works without sudo (from their next login)
#   5. systemctl daemon-reload, enable and (re)start each installed unit
# Stop the old process on the unit's port first (a user service, a nohup process): the unit cannot start on a busy port.
# Safe to re-run.

set -euo pipefail

ACCOUNT=vellox-dev
GROUP="${DEV_GROUP:-devgroup}"
HOME_DIR=/var/lib/vellox-dev
SUDOERS=/etc/sudoers.d/vellox-dev-services
UNIT_DIR=/etc/systemd/system

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash $0 $*"

# the units this script owns: every installed unit that runs as the account
owned_units() { grep -l "^User=$ACCOUNT\$" "$UNIT_DIR"/*.service 2>/dev/null | xargs -r -n1 basename | sort; }

case "${1:-}" in
  install)
    shift
    [ $# -gt 0 ] || die "name at least one repo: sudo bash $0 install /srv/dev/<repo>"
    getent group "$GROUP" >/dev/null || die "group $GROUP does not exist"

    if ! id "$ACCOUNT" >/dev/null 2>&1; then
      useradd --system --gid "$GROUP" --home-dir "$HOME_DIR" --create-home --shell /usr/sbin/nologin "$ACCOUNT"
      echo "account $ACCOUNT created"
    fi
    runuser -u "$ACCOUNT" -- git config --global --get-all safe.directory 2>/dev/null | grep -qx '/srv/dev/\*' \
      || runuser -u "$ACCOUNT" -- git config --global --add safe.directory '/srv/dev/*'

    installed=()
    for repo in "$@"; do
      repo="${repo%/}"
      case "$repo" in /srv/dev/*) ;; *) die "$repo: only repos under /srv/dev" ;; esac
      shopt -s nullglob
      units=("$repo"/deploy/dev/*.service)
      shopt -u nullglob
      [ ${#units[@]} -gt 0 ] || die "$repo/deploy/dev has no .service file"
      for u in "${units[@]}"; do
        grep -q "^User=$ACCOUNT\$" "$u" || die "$u does not run as $ACCOUNT (User=$ACCOUNT)"
        install -m 0644 "$u" "$UNIT_DIR/$(basename "$u")"
        installed+=("$(basename "$u")")
        echo "unit $(basename "$u") from $repo"
      done
    done

    # sudoers: every owned unit, with and without .service, for start/stop/restart
    tmp="$(mktemp)"
    {
      echo "# Written by /srv/dev/vellox-bootstrap/dev-services.sh - do not edit by hand."
      while read -r unit; do
        for verb in start stop restart; do
          echo "%$GROUP ALL=(root) NOPASSWD: /usr/bin/systemctl $verb $unit, /usr/bin/systemctl $verb ${unit%.service}"
        done
      done < <(owned_units)
    } > "$tmp"
    visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "the sudoers rule did not validate"; }
    install -m 0440 "$tmp" "$SUDOERS"
    rm -f "$tmp"
    echo "sudoers: $SUDOERS"

    for member in $(getent group "$GROUP" | cut -d: -f4 | tr ',' ' '); do
      id -nG "$member" | tr ' ' '\n' | grep -qx systemd-journal || { usermod -aG systemd-journal "$member"; echo "$member added to systemd-journal"; }
    done

    systemctl daemon-reload
    for unit in "${installed[@]}"; do
      systemctl enable "$unit" >/dev/null
      systemctl restart "$unit"
      echo "started $unit"
    done
    ;;
  status)
    for unit in $(owned_units); do systemctl --no-pager --lines=0 status "$unit" || true; done
    ;;
  *)
    die "usage: sudo bash $0 install <repo>... | status"
    ;;
esac
