#!/usr/bin/env bash
# Port registry helper for vellox-srv10. The data lives in /srv/ports.tsv (see PORTS.md for the scheme).
#
#   bash ports.sh                       # same as list
#   bash ports.sh list [solution]       # the registry, optionally one solution
#   bash ports.sh check                 # compare the registry with what is listening right now
#   bash ports.sh next                  # next free solution number and its dev/prod blocks
#   bash ports.sh free <port>           # is <port> unregistered and not listening?
#   bash ports.sh add <port> <solution> <dev|prod|infra|legacy> <service> [note]
#
# Exit code of `check` is 1 when something listens that is not registered, so it can run in CI or cron.

set -euo pipefail

REGISTRY="${PORTS_FILE:-/srv/ports.tsv}"
[ -r "$REGISTRY" ] || { echo "ERROR: $REGISTRY not found" >&2; exit 1; }

# Registry rows without comments and blank lines, tab-separated: port solution env service note
rows() { grep -vE '^\s*(#|$)' "$REGISTRY"; }

# Host ports something is bound to right now: host sockets plus docker-published ports.
listening() {
  {
    ss -tlnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}'
    docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' | grep -oE ':[0-9]+->' | tr -d ':->'
  } | grep -E '^[0-9]+$' | sort -u
}

cmd_list() {
  local filter="${1:-}"
  {
    printf 'PORT\tSOLUTION\tENV\tSERVICE\tNOTE\n'
    rows | { if [ -n "$filter" ]; then grep -i -- "$filter"; else cat; fi; } | sort -n
  } | column -t -s $'\t'
}

cmd_check() {
  local rc=0
  echo "== duplicate ports in $REGISTRY"
  dup="$(rows | cut -f1 | sort | uniq -d)"
  if [ -n "$dup" ]; then echo "$dup" | sed 's/^/  /'; rc=1; else echo "  none"; fi

  echo "== listening but not in the registry (register it or stop it)"
  unknown="$(comm -23 <(listening) <(rows | cut -f1 | sort -u))"
  if [ -n "$unknown" ]; then
    for p in $unknown; do
      who="$(ss -tlnpH "sport = :$p" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -1 | cut -d'"' -f2)"
      [ -n "$who" ] || who="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E ":$p->" | awk '{print $1}' | head -1)"
      printf '  %s\t%s\n' "$p" "${who:-(owner needs sudo ss -tlnp)}"
    done
    rc=1
  else
    echo "  none"
  fi

  echo "== legacy ports still in use (migration pending)"
  rows | awk -F'\t' '$3=="legacy"' | while IFS=$'\t' read -r port sol env svc note; do
    if listening | grep -qx "$port"; then printf '  %s\t%s %s\t%s\n' "$port" "$sol" "$svc" "$note"; fi
  done

  echo "== registered prod/infra ports with nothing listening (not deployed, or down)"
  rows | awk -F'\t' '$3=="prod" || $3=="infra"' | while IFS=$'\t' read -r port sol env svc note; do
    listening | grep -qx "$port" || printf '  %s\t%s %s\n' "$port" "$sol" "$svc"
  done
  return $rc
}

cmd_next() {
  # Solution numbers in use: NN from every 3NNS/4NNS port in the registry.
  used="$(rows | cut -f1 | awk '$1>=3000 && $1<5000 {printf "%02d\n", int(($1%1000)/10)}' | sort -u)"
  for nn in $(seq -w 1 99); do
    if ! echo "$used" | grep -qx "$nn"; then
      printf 'next free solution number: %s  (dev 3%s0-3%s9, prod 4%s0-4%s9)\n' "$nn" "$nn" "$nn" "$nn" "$nn"
      return 0
    fi
  done
  echo "no free block left" >&2; return 1
}

cmd_free() {
  local p="${1:?port}"
  local ok=0
  if rows | cut -f1 | grep -qx "$p"; then echo "$p is registered:"; rows | awk -F'\t' -v p="$p" '$1==p' | sed 's/^/  /'; ok=1; fi
  if listening | grep -qx "$p"; then echo "$p is listening right now"; ok=1; fi
  [ $ok -eq 0 ] && echo "$p is free"
  return $ok
}

cmd_add() {
  local port="${1:?port}" sol="${2:?solution}" env="${3:?env}" svc="${4:?service}" note="${5:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || { echo "ERROR: port must be a number" >&2; exit 1; }
  case "$env" in dev|prod|infra|legacy) ;; *) echo "ERROR: env must be dev, prod, infra or legacy" >&2; exit 1 ;; esac
  if rows | cut -f1 | grep -qx "$port"; then echo "ERROR: $port is already registered" >&2; rows | awk -F'\t' -v p="$port" '$1==p' >&2; exit 1; fi
  case "$env" in
    dev)  [[ "$port" =~ ^3[0-9]{3}$ ]] || echo "warning: dev ports are 3NNS by convention" >&2 ;;
    prod) [[ "$port" =~ ^4[0-9]{3}$ ]] || echo "warning: prod ports are 4NNS by convention" >&2 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$port" "$sol" "$env" "$svc" "$note" >> "$REGISTRY"
  echo "added: $port $sol $env $svc ${note:+($note)}"
}

case "${1:-list}" in
  list)  shift; cmd_list "$@" ;;
  check) cmd_check ;;
  next)  cmd_next ;;
  free)  shift; cmd_free "$@" ;;
  add)   shift; cmd_add "$@" ;;
  -h|--help|help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command: $1" >&2; exit 1 ;;
esac
