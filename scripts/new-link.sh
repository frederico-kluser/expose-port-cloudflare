#!/usr/bin/env bash
# Mint a NEW one-time access link without restarting the tunnel.
#
# The previous password is dead the moment a new one is minted: the proxy
# restarts with a fresh token and in-memory sessions are revoked. The public
# URL stays the same — only the password changes.
#
# Usage: ./new-link.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

if [ -f cloudflared.pid ] && kill -0 "$(cat cloudflared.pid)" 2>/dev/null; then
  : # tunnel is up — good
else
  echo "tunnel is not running — start it with ./scripts/expose-port.sh <url>" >&2
  exit 1
fi
if [ ! -f "$CURRENT_LINK_FILE" ]; then
  echo "no previous link state ($CURRENT_LINK_FILE) — start with ./scripts/expose-port.sh <url>" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CURRENT_LINK_FILE"

# Rotate the proxy with a fresh password (cloudflared keeps running).
if [ -f proxy.pid ] && kill -0 "$(cat proxy.pid)" 2>/dev/null; then
  kill "$(cat proxy.pid)" 2>/dev/null || true
  rm -f proxy.pid
fi
sleep 0.5

TOKEN="$(gen_token)"
UPSTREAM_HOST="$HOST" UPSTREAM_PORT="$PORT" UPSTREAM_PROTO="$PROTO" \
TOKEN="$TOKEN" nohup node scripts/proxy.mjs > proxy.log 2>&1 &
echo $! > proxy.pid

for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:3100/__expose-port-health"; then
    break
  fi
  sleep 0.5
done

PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | tail -1 || true)"
if [ -z "$PUBLIC_URL" ]; then
  echo "no tunnel URL in tunnel.log — start over with ./scripts/expose-port.sh <url>" >&2
  exit 1
fi

save_current_link
print_access_link "${PUBLIC_URL}/?key=${TOKEN}"
echo "previous sessions were revoked (in-memory) — the public URL is unchanged."
