#!/usr/bin/env bash
# List what is currently exposed by this skill: the instance tracked by this
# install (pid files + current-link) and any other quick tunnels / gate proxies
# found on the machine (other installs, the legacy setup, orphans). Read-only —
# never touches processes, never consumes the one-time password.
#
# Usage: ./list.sh   (also: expose-port-cloudflare list)
#
# Process matching is by exact command name (comm) plus a required argument,
# never by a bare substring of the cmdline: a shell that merely *mentions*
# proxy.mjs in its command text must not be reported as a gate proxy.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "== tracked instance =="
for name in cloudflared proxy; do
  if [ -f "$name.pid" ] && kill -0 "$(cat "$name.pid")" 2>/dev/null; then
    echo "$name: RUNNING (pid $(cat "$name.pid"))"
  else
    echo "$name: not running"
  fi
done

TRACKED_PIDS=""
for name in cloudflared proxy; do
  [ -f "$name.pid" ] && TRACKED_PIDS="$TRACKED_PIDS $(cat "$name.pid")"
done
is_tracked() { case " $TRACKED_PIDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

if [ -f current-link ]; then
  # shellcheck disable=SC1090
  . ./current-link
  echo "target: ${PROTO:-http}://${HOST:-?}:${PORT:-?}"
  echo "public URL: ${URL:-none}"
  state="$(curl -fsS --max-time 3 'http://127.0.0.1:3100/__expose-port-status' 2>/dev/null || true)"
  if [ -z "$state" ]; then
    echo "one-time link state: unknown (proxy DOWN)"
  else
    desc="$(printf '%s' "$state" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);let d;if(j.consumed){d="CONSUMED — use ./scripts/new-link.sh"}else if(j.ttlMs<=0){d="unused, no expiry — ready to share"}else if(j.issuedAgoMs>j.ttlMs){d="EXPIRED — use ./scripts/new-link.sh"}else{d="unused — valid for "+Math.ceil((j.ttlMs-j.issuedAgoMs)/60000)+" more min"}console.log(d)})')"
    echo "one-time link state: $desc"
  fi
else
  echo "target: (no current-link state — nothing exposed yet?)"
fi

echo "== untracked quick tunnels / gate proxies =="
found=0
while read -r pid rest; do
  if [ -n "$pid" ] && ! is_tracked "$pid"; then
    echo "cloudflared (quick tunnel): RUNNING (pid $pid) — $rest"
    found=1
  fi
done < <(ps -axo pid=,args= | awk '$2 == "cloudflared" && index($0, "--url") { print }')
while read -r pid rest; do
  if [ -n "$pid" ] && ! is_tracked "$pid"; then
    echo "gate proxy: RUNNING (pid $pid) — $rest"
    found=1
  fi
done < <(ps -axo pid=,args= | awk '$2 == "node" && index($0, "scripts/proxy.mjs") { print }')
[ "$found" = 0 ] && echo "(none)"
