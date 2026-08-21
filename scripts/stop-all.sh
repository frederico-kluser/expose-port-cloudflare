#!/usr/bin/env bash
# Stop EVERYTHING this skill may have started: the tracked instance AND any
# other quick tunnels / gate proxies on the machine (other installs, the legacy
# dsh-cloudflare-tunnel setup, orphans whose pid files went stale). Named
# (account) tunnels are NOT touched.
#
# Usage: ./stop-all.sh   (also: expose-port-cloudflare stop-all)
#
# Matching is by exact command name (comm) plus a required argument, never by a
# bare substring of the cmdline: a shell that merely *mentions* proxy.mjs in
# its command text must not be killed along with the gate.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

killed=0
stop_matching() {
  local label="$1" awkcond="$2" pid rest
  while read -r pid rest; do
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "stopping $label (pid $pid)"
      kill "$pid" 2>/dev/null || true
      killed=1
    fi
  done < <(ps -axo pid=,args= | awk "$awkcond { print }")
}

# Proxies first (they hold the gate port and sessions), then quick tunnels.
stop_matching "gate proxy" '$2 == "node" && index($0, "scripts/proxy.mjs")'
stop_matching "cloudflared (quick tunnel)" '$2 == "cloudflared" && index($0, "--url")'

rm -f cloudflared.pid proxy.pid

# Wait briefly for the gate port to free up.
for _ in $(seq 1 10); do
  curl -fsS -o /dev/null --max-time 1 'http://127.0.0.1:3100/__expose-port-health' 2>/dev/null || break
  sleep 0.3
done

left="$(ps -axo pid=,args= | awk '$2 == "node" && index($0, "scripts/proxy.mjs") { print $1 }' | tr '\n' ' ')"
if [ -n "$left" ]; then
  echo "WARNING: still running: $left" >&2
  exit 1
fi
if [ "$killed" = 1 ]; then
  echo "stopped everything — verify with: expose-port-cloudflare list"
else
  echo "nothing was running"
fi
