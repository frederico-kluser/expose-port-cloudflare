#!/usr/bin/env bash
# Show tunnel status and run live checks through the public URL.
#
# NOTE: these checks NEVER consume the one-time password — the gate reports:
#   - root without key/cookie  -> 401 (gate active — expected, not an error)
#   - a fresh-key probe is only possible by minting a link (expose-port.sh /
#     new-link.sh) and consuming it on first use.
#
# Usage: ./status.sh [extra-path ...]
#   extra-path: app paths to probe for Host-validation fences (e.g. /api) —
#   with a live session cookie a fence shows as 403 where the app answers
#   404/200 locally; without a cookie the gate returns 401 for everything,
#   so fence probing requires the browser session already open.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "== processes =="
for name in cloudflared proxy; do
  if [ -f "$name.pid" ] && kill -0 "$(cat "$name.pid")" 2>/dev/null; then
    echo "$name: running (pid $(cat "$name.pid"))"
  else
    echo "$name: not running"
  fi
done

echo "== proxy health (gate) =="
curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:3100/__expose-port-health" \
  && echo "proxy: ok (127.0.0.1:3100)" || echo "proxy: DOWN"

echo "== public URL =="
PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log 2>/dev/null | tail -1 || true)"
echo "${PUBLIC_URL:-none yet}"

if [ -z "$PUBLIC_URL" ]; then
  echo "no URL yet — tunnel not ready"
  exit 0
fi

echo "== live checks through the tunnel =="
echo "root (no key, no cookie): HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$PUBLIC_URL/")   <- expect 401 (gate active)"
if [ -f current-link ]; then
  state="$(curl -fsS --max-time 3 'http://127.0.0.1:3100/__expose-port-status' 2>/dev/null || true)"
  if [ -z "$state" ]; then
    echo "one-time link state: unknown (proxy DOWN)"
  else
    desc="$(printf '%s' "$state" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);let d;if(j.consumed){d="CONSUMED — use ./scripts/new-link.sh"}else if(j.ttlMs<=0){d="unused, no expiry — ready to share"}else if(j.issuedAgoMs>j.ttlMs){d="EXPIRED — use ./scripts/new-link.sh"}else{d="unused — valid for "+Math.ceil((j.ttlMs-j.issuedAgoMs)/60000)+" more min"}console.log(d)})')"
    echo "one-time link state: $desc"
  fi
fi
echo "root with INVALID key:  HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$PUBLIC_URL/?key=invalid-invalid-invalid")   <- expect 401"

if [ "$#" -gt 0 ]; then
  echo "extra-path probes (fence check — pass a live session cookie with -b to see through the gate):"
  for p in "$@"; do
    echo "$p: HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$PUBLIC_URL$p")"
  done
fi
