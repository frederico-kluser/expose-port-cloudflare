#!/usr/bin/env bash
# Expose a local port on the internet via a Cloudflare quick tunnel,
# routed through the Host/Origin rewrite proxy so browser-trust fences pass.
#
# Usage: ./expose-port.sh <local-port> [listen-port]
#   <local-port>  the port your local server listens on (e.g. 8080)
#   [listen-port] proxy listen port (default 3100)
#
# Prints the public URL when ready. Stop with ./stop.sh.
set -euo pipefail

PORT="${1:-}"
LISTEN="${2:-3100}"
if [ -z "$PORT" ]; then
  echo "usage: $0 <local-port> [listen-port]" >&2
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

# --- prerequisites -----------------------------------------------------------
command -v cloudflared >/dev/null 2>&1 || {
  echo "ERROR: cloudflared not found. Install it:" >&2
  echo "  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared && chmod +x cloudflared && sudo mv cloudflared /usr/local/bin/" >&2
  exit 1
}
command -v node >/dev/null 2>&1 || {
  echo "ERROR: node not found. The rewrite proxy needs Node.js (node:http only, zero deps)." >&2
  exit 1
}

# --- preflight: is anything listening on the port? ----------------------------
if ! curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/"; then
  echo "WARNING: nothing answered on http://127.0.0.1:${PORT}/ — starting anyway; validate once it is up." >&2
fi

# --- 1. rewrite proxy ---------------------------------------------------------
if [ -f proxy.pid ] && kill -0 "$(cat proxy.pid)" 2>/dev/null; then
  echo "proxy already running (pid $(cat proxy.pid)) — refusing to reuse it for a different upstream port."
  echo "Run ./stop.sh first, then retry." >&2
  exit 1
fi
UPSTREAM_PORT="$PORT" LISTEN_PORT="$LISTEN" nohup node scripts/proxy.mjs > proxy.log 2>&1 &
echo $! > proxy.pid
echo "proxy started (pid $(cat proxy.pid)) on 127.0.0.1:${LISTEN} -> 127.0.0.1:${PORT}"

for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${LISTEN}/__expose-port-health"; then
    echo "proxy health: ok"
    break
  fi
  sleep 0.5
done

# --- 2. cloudflared quick tunnel ----------------------------------------------
if [ -f cloudflared.pid ] && kill -0 "$(cat cloudflared.pid)" 2>/dev/null; then
  echo "cloudflared already running (pid $(cat cloudflared.pid))" >&2
  echo "Run ./stop.sh first, then retry." >&2
  exit 1
fi
nohup cloudflared tunnel --url "http://127.0.0.1:${LISTEN}" --no-autoupdate --loglevel info > tunnel.log 2>&1 &
echo $! > cloudflared.pid
echo "cloudflared started (pid $(cat cloudflared.pid))"

for _ in $(seq 1 60); do
  URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | tail -1 || true)"
  if [ -n "$URL" ]; then
    echo ""
    echo "TUNNEL READY: $URL"
    echo "Validate now: ./status.sh ${PORT}"
    exit 0
  fi
  sleep 1
done

echo "tunnel did not become ready within 60s — check $DIR/tunnel.log" >&2
exit 1
