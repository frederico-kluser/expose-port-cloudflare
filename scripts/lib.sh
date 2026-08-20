#!/usr/bin/env bash
# Shared helpers for the expose-port-cloudflare scripts (sourced, not executed).

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT_LINK_FILE="$SKILL_DIR/current-link"

# Parse the target argument into HOST, PORT, PROTO.
# Accepts: 8080 | localhost:8080 | 127.0.0.1:8080 | http://localhost:8080 |
#          https://127.0.0.1:9443/path (path is kept out — it passes through as-is)
parse_target() {
  local input="$1"
  local line
  line="$(TARGET="$input" node -e '
const a = process.env.TARGET
if (/^\d{1,5}$/.test(a)) {
  console.log([ "127.0.0.1", a, "http" ].join(" "))
  process.exit(0)
}
let s = a
if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) s = "http://" + s
let u
try { u = new URL(s) } catch { console.error("cannot parse target: " + a); process.exit(1) }
const proto = u.protocol.replace(":", "")
if (proto !== "http" && proto !== "https") { console.error("unsupported scheme: " + proto); process.exit(1) }
console.log([ u.hostname, u.port || (proto === "https" ? "443" : "80"), proto ].join(" "))
')" || return 1
  HOST="$(cut -d' ' -f1 <<<"$line")"
  PORT="$(cut -d' ' -f2 <<<"$line")"
  PROTO="$(cut -d' ' -f3 <<<"$line")"
}

# Generate a fresh one-time password (256-bit base64url).
gen_token() {
  node -e "console.log(require('node:crypto').randomBytes(24).toString('base64url'))"
}

# Render a QR code of the full link in the terminal (SSH-safe ANSI),
# with graceful fallbacks when qrencode is not installed.
render_qr() {
  local text="$1"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 -o - "$text"
    echo ""
    echo "   (qrencode ANSIUTF8)"
  elif python3 -c 'import qrcode' >/dev/null 2>&1; then
    python3 -c '
import qrcode, sys
qr = qrcode.QRCode(border=1)
qr.add_data(sys.argv[1]); qr.make()
qr.print_ascii(invert=True)
' "$text"
    echo ""
    echo "   (python3-qrcode)"
  else
    echo "   [QR não disponível — instale qrencode: sudo apt install qrencode]"
  fi
}

# Save the current link state for new-link.sh / status.sh (mode 600, gitignored).
save_current_link() {
  umask 177
  {
    echo "HOST=$HOST"
    echo "PORT=$PORT"
    echo "PROTO=$PROTO"
    echo "TOKEN=$TOKEN"
    echo "URL=$PUBLIC_URL"
  } > "$CURRENT_LINK_FILE"
  umask 022
}

# Print the access link block (URL + QR) to the terminal.
print_access_link() {
  local full="$1"
  echo ""
  echo "========================================================"
  echo " ONE-TIME ACCESS LINK"
  echo "   $full"
  echo ""
  echo " Scan the QR (or open the URL) — the password is consumed"
  echo " on first use and removed from the URL. Mint a new link"
  echo " with ./scripts/new-link.sh without restarting the tunnel."
  echo "========================================================"
  echo ""
  render_qr "$full"
  echo ""
}
