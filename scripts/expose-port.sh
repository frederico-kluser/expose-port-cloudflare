#!/usr/bin/env bash
# Expose a local server on the internet via a Cloudflare quick tunnel,
# protected by a one-time password shown as a QR code in the terminal.
#
# Usage: ./expose-port.sh <target>
#   <target>  the local server, in any of these forms:
#     8080
#     localhost:8080
#     127.0.0.1:8080
#     http://localhost:8080
#     https://127.0.0.1:9443/path   (https upstream = dev/self-signed certs)
#
# Prints the public URL + QR. The password lives in the URL (?key=...),
# is consumed on first access, and the URL is cleaned right after.
# Stop with ./stop.sh; mint another password with ./new-link.sh.
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "usage: $0 <http://host:port | host:port | port>" >&2
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

# --- prerequisites -----------------------------------------------------------
command -v cloudflared >/dev/null 2>&1 || {
  echo "ERROR: cloudflared not found. Install it:" >&2
  echo "  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared && chmod +x cloudflared && sudo mv cloudflared /usr/local/bin/" >&2
  exit 1
}
command -v node >/dev/null 2>&1 || {
  echo "ERROR: node not found. The gate proxy needs Node.js (node:http only, zero deps)." >&2
  exit 1
}

# --- parse the target ---------------------------------------------------------
parse_target "$TARGET"
echo "target: ${PROTO}://${HOST}:${PORT}"

# --- preflight: is anything listening? -----------------------------------------
if ! curl -fsS -o /dev/null --max-time 3 "http://${HOST}:${PORT}/"; then
  echo "WARNING: nothing answered on http://${HOST}:${PORT}/ — starting anyway; validate once it is up." >&2
fi

# --- 1. gate proxy with a fresh one-time password ------------------------------
if [ -f proxy.pid ] && kill -0 "$(cat proxy.pid)" 2>/dev/null; then
  echo "proxy already running — run ./scripts/stop.sh first (or ./scripts/new-link.sh to rotate the password)." >&2
  exit 1
fi
TOKEN="$(gen_token)"
UPSTREAM_HOST="$HOST" UPSTREAM_PORT="$PORT" UPSTREAM_PROTO="$PROTO" \
TOKEN_REUSE="${TOKEN_REUSE:-1}" TOKEN_TTL_MS="${TOKEN_TTL_MS:-0}" \
TOKEN="$TOKEN" nohup node scripts/proxy.mjs > proxy.log 2>&1 &
echo $! > proxy.pid
echo "gate proxy started (pid $(cat proxy.pid)) on 127.0.0.1:3100 -> ${PROTO}://${HOST}:${PORT}"

for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:3100/__expose-port-health"; then
    echo "proxy health: ok"
    break
  fi
  sleep 0.5
done

# --- 2. cloudflared quick tunnel ------------------------------------------------
if [ -f cloudflared.pid ] && kill -0 "$(cat cloudflared.pid)" 2>/dev/null; then
  echo "cloudflared already running — run ./scripts/stop.sh first." >&2
  exit 1
fi
nohup cloudflared tunnel --url "http://127.0.0.1:3100" --no-autoupdate --loglevel info > tunnel.log 2>&1 &
echo $! > cloudflared.pid
echo "cloudflared started (pid $(cat cloudflared.pid))"

for _ in $(seq 1 60); do
  PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | tail -1 || true)"
  if [ -n "$PUBLIC_URL" ]; then
    save_current_link
    print_access_link "${PUBLIC_URL}/?key=${TOKEN}"
    echo "TUNNEL READY: $PUBLIC_URL"
    echo "Validate now: ./scripts/status.sh"
    exit 0
  fi
  sleep 1
done

echo "tunnel did not become ready within 60s — check $DIR/tunnel.log" >&2
exit 1
