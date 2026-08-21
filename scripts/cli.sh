#!/usr/bin/env bash
# expose-port-cloudflare CLI entry — dispatches subcommands to the scripts.
#
#   expose-port-cloudflare <target>   expose a local server (default)
#     <target> = 8080 | host:port | http(s)://host:port[/path]
#   expose-port-cloudflare list       what is running now (read-only)
#   expose-port-cloudflare stop       stop the tracked tunnel + proxy
#   expose-port-cloudflare stop-all   stop every quick tunnel + gate proxy
#   expose-port-cloudflare help       this help
#
# Installed as ~/.local/bin/expose-port-cloudflare by install.sh; re-run
# install.sh to refresh it. Arguments after the subcommand pass through.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1:-}" in
  list) shift; exec "$DIR/scripts/list.sh" "$@" ;;
  stop) shift; exec "$DIR/scripts/stop.sh" "$@" ;;
  stop-all|stopall|stopAll) shift; exec "$DIR/scripts/stop-all.sh" "$@" ;;
  --help|-h|help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  '')
    echo "usage: expose-port-cloudflare <http://host:port | host:port | port>" >&2
    echo "       expose-port-cloudflare list | stop | stop-all" >&2
    exit 2 ;;
  *) exec "$DIR/scripts/expose-port.sh" "$@" ;;
esac
