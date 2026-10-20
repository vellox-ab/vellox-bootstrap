#!/usr/bin/env bash
# Normalise ownership and permissions under /srv/dev and /srv/prod so every member of
# devgroup can work in any project, create new ones, run Claude Code and deploy to prod
# without permission errors, while nobody outside the group gets in.
#
#   sudo bash /srv/dev/vellox-bootstrap/srv-perms.sh              # /srv/dev and /srv/prod
#   sudo bash /srv/dev/vellox-bootstrap/srv-perms.sh /srv/prod    # one tree only
#
# What it does, per tree:
#   1. group          every file and directory belongs to devgroup
#   2. modes          directories 2770 (setgid: new entries inherit the group), files 660
#                     (exec bit kept where one existed), no access for "other", no setuid
#   3. ACLs           access ACL  g:devgroup:rwX   on everything
#                     default ACL u::rwx,g::rwx,g:devgroup:rwx,o::--- on every directory,
#                     so files created by any tool (editors, npm, git, docker, claude) are
#                     group-writable regardless of that tool's umask
#   4. git            every repo gets core.sharedRepository=group, and each devgroup member
#                     gets <tree>/* in their git safe.directory (git refuses to touch repos
#                     owned by another user otherwise)
#
# Safe to re-run at any time; it only ever converges towards the state above. Symlinks are
# never followed. Owners are left as they are: ownership does not matter once the group
# and the ACLs are in place.
#
# Environment: DEV_GROUP (default devgroup).

set -euo pipefail

GROUP="${DEV_GROUP:-devgroup}"
if [ $# -gt 0 ]; then ROOTS=("$@"); else ROOTS=(/srv/dev /srv/prod); fi

log() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Re-exec through sudo by the same path, so a NOPASSWD sudoers rule for /usr/local/sbin/srv-perms matches.
if [ "$(id -u)" -ne 0 ] && [ -z "${SRV_PERMS_NO_SUDO:-}" ]; then
  exec sudo "$0" "$@"
fi

command -v setfacl >/dev/null || die "setfacl not found (apt install acl)"
getent group "$GROUP" >/dev/null || die "group $GROUP does not exist"
MEMBERS="$(getent group "$GROUP" | cut -d: -f4 | tr ',' ' ')"

for root in "${ROOTS[@]}"; do
  case "$root" in /srv/*) ;; *) [ -n "${SRV_PERMS_NO_SUDO:-}" ] || die "refusing to touch $root: only trees under /srv are expected" ;; esac
  root="${root%/}"

  if [ ! -d "$root" ]; then
    log "Creating $root"
    mkdir -p "$root"
  fi

  log "$root: group $GROUP on everything"
  chgrp -R -h "$GROUP" "$root"

  log "$root: directories 2770, files 660 (+x kept), nothing for other"
  # Symbolic mode on purpose: a numeric "chmod 2770" would leave an existing setuid bit on a directory.
  find "$root" -type d ! -perm 2770 -exec chmod u=rwx,g=rwxs,o=,u-s,o-t {} +
  find "$root" -type f \( -perm /o=rwx -o -perm /u=s -o -perm /g=s -o ! -perm -u=rw -o ! -perm -g=rw \) \
    -exec chmod u+rw,g+rw,o-rwx,u-s,g-s {} +
  # A file with an exec bit for the owner gets it for the group too (scripts, binaries in node_modules/.bin).
  find "$root" -type f -perm -u=x ! -perm -g=x -exec chmod g+x {} +

  log "$root: ACLs (g:$GROUP:rwX everywhere, inherited on directories)"
  # Rebuild from scratch so stale per-user entries from earlier experiments do not linger.
  setfacl -R -b "$root"
  setfacl -R -m "g:$GROUP:rwX" "$root"
  find "$root" -type d -exec setfacl -m "d:u::rwx,d:g::rwx,d:g:$GROUP:rwx,d:o::---" {} +

  log "$root: git repositories shared with the group"
  while IFS= read -r -d '' gitdir; do
    repo="$(dirname "$gitdir")"
    git -C "$repo" config core.sharedRepository group 2>/dev/null \
      || git config --file "$gitdir/config" core.sharedRepository group 2>/dev/null \
      || echo "warning: could not set core.sharedRepository in $repo"
    echo "  $repo"
  done < <(find "$root" -maxdepth 3 -name .git -type d -print0)

  # As root: every member's global git config. Unprivileged test runs only touch the caller's.
  if [ "$(id -u)" -eq 0 ]; then users="$MEMBERS"; else users="$(id -un)"; fi
  for u in $users; do
    home="$(getent passwd "$u" | cut -d: -f6)"
    [ -d "$home" ] || continue
    if [ "$u" = "$(id -un)" ]; then as_user=(); else as_user=(sudo -u "$u" -H); fi
    for entry in "$root" "$root/*"; do
      if ! "${as_user[@]}" git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$entry"; then
        "${as_user[@]}" git config --global --add safe.directory "$entry" \
          && echo "  safe.directory $entry added for $u" \
          || echo "warning: could not update safe.directory for $u"
      fi
    done
  done
done

log "Done"
printf 'Members of %s: %s\n' "$GROUP" "$MEMBERS"
printf 'Deploying needs the docker group as well: %s\n' "$(getent group docker | cut -d: -f4)"
