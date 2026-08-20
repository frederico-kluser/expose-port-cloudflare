#!/usr/bin/env bash
# Show tunnel status and run live checks through the public URL.
# Usage: ./status.sh [local-port] [extra-path ...]
#   [local-port]   port of the local server (for the fence probe)
#   [extra-path]   extra paths to check through the tunnel (e.g. /api)
#                  — a 403 here means a browser-trust fence is rejecting the
#                  tunnel host (Host validation); the proxy should prevent it.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

PORT="${1:-}"
shift || true

echo "== processes =="
for name in cloudflared proxy; do
  if [ -f "$name.pid" ] && kill -0 "$(cat "$name.pid")" 2>/dev/null; then
    echo "$name: running (pid $(cat "$name.pid"))"
  else
    echo "$name: not running"
  fi
done

echo "== proxy health =="
curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:3100/__expose-port-health" \
  && echo "proxy: ok (127.0.0.1:3100)" || echo "proxy: DOWN"

echo "== public URL =="
URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log 2>/dev/null | tail -1 || true)"
echo "${URL:-none yet}"

if [ -z "$URL" ]; then
  echo "no URL yet — tunnel not ready"
  exit 0
fi

echo "== live checks through the tunnel =="
check() {
  local path="$1"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL$path")"
  echo "$path: HTTP $code"
}
check "/"
if [ -n "$PORT" ]; then
  # Fence probe: a 403 where the app itself answers 404/200 locally means the
  # tunnel hostname is being rejected by Host validation (see SKILL.md §Fences).
  local_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT}/")"
  for p in "$@"; do
    tunnel_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL$p")"
    if [ "$tunnel_code" = "403" ] && [ "$local_code" != "403" ]; then
      echo "$p: HTTP $tunnel_code  <-- FENCE BLOCKING (403 onde o app responde $local_code localmente)"
    else
      echo "$p: HTTP $tunnel_code"
    fi
  done
fi
echo "websocket upgrade probe (if the app has WS, expect 101):"
for ws in "$@"; do
  echo "ws${ws}: HTTP $(curl -s --http1.1 -o /dev/null -w '%{http_code}' --max-time 8 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' \
    "$URL$ws")"
done
