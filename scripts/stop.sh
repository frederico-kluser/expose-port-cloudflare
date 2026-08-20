#!/usr/bin/env bash
# Stop the Cloudflare tunnel and the rewrite proxy.
# Usage: ./stop.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

for name in cloudflared proxy; do
  if [ -f "$name.pid" ]; then
    pid="$(cat "$name.pid")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" && echo "$name stopped (pid $pid)"
    else
      echo "$name not running (stale pid $pid)"
    fi
    rm -f "$name.pid"
  fi
done
