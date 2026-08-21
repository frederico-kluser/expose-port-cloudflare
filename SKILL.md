---
name: expose-port-cloudflare
version: "1.1.0"
description: Expor uma porta ou servidor local na internet via Cloudflare Tunnel com proteção por senha de uso único — ninguém sem a senha gerada no momento acessa o conteúdo. A senha sai no terminal como QR code atrelado à URL (é só escanear); no primeiro acesso ela é consumida e removida da URL. Sem conta, sem domínio, sem modificar o projeto servido. Use quando alguém precisar abrir uma porta online, expor um dev server / localhost com link seguro, compartilhar um link público temporário, ou configurar um túnel Cloudflare. Passar a URL local com porta (ex: http://localhost:8080) ou só a porta (8080). Triggers: "abrir uma porta na internet", "expor o servidor local com senha", "link público protegido", "me dá um link que só quem eu quiser acessa", "túnel cloudflare", "expose local port with password", "secure public URL for localhost", "cloudflare tunnel".
---

# Expose a local port online with a Cloudflare Tunnel + one-time password

Turns any local service (`http://127.0.0.1:<port>` or `http://localhost:<port>`) into a
public `https://*.trycloudflare.com` URL **protected by a one-time password**:

- The skill mints a random 256-bit password, appends it to the URL (`?key=…`) and
  renders a **QR code of the full link in the terminal** — the person scans and opens.
- **Nobody without that password can access** the service (HTTP **and** WebSocket):
  requests without the key and without a session cookie get **401**.
- **First access consumes the password** (server-side invalidation) and the browser is
  redirected to the **clean URL** (password removed, `Referrer-Policy: no-referrer`),
  with a secure session cookie (HttpOnly, SameSite=Strict, Secure) keeping the session
  alive for the browser that redeemed it.
- The password has a **10-minute TTL** before first use; sessions last 24 h. Mint a new
  password any time with `new-link.sh` — the public URL stays the same.
- No Cloudflare account, no domain, no DNS, no inbound firewall changes; the served
  project stays **untouched** (all support code lives next to it).

## When to use

- Someone needs a public link to a local server (dev UI, API, dashboard, preview build),
  and access must be limited to whoever holds the password.
- The service listens on `127.0.0.1`/`localhost` only (tunnels work fine — cloudflared
  connects locally).
- You must NOT modify the project being exposed (config files, `allowedHosts`, etc.).

## When NOT to use

- Production exposure → use a **named tunnel** (Cloudflare account + domain) with
  **Cloudflare Access** (identity-aware auth) instead of a shared password.
- You have no `node` — the gate proxy (zero deps, `node:http/https`) needs it.
- The recipient needs to re-open the link repeatedly: the password is single-use; give
  them the QR once and mint another link when needed (`new-link.sh`).

## Prerequisites

```sh
# cloudflared (Linux x86_64):
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared && chmod +x cloudflared && sudo mv cloudflared /usr/local/bin/
# node: any modern LTS (gate proxy, zero deps)
# qrencode (recommended for the terminal QR — falls back gracefully):
sudo apt install qrencode
```

## Execution

Installed globally (via `install.sh`), the skill can be driven from any folder
with the CLI shortcut — `expose-port-cloudflare <port>` runs the same script:

```sh
expose-port-cloudflare http://localhost:8080   # global shortcut, any folder (or:)
cd <sibling-folder>/expose-port-cloudflare     # this skill's folder
./scripts/expose-port.sh http://localhost:8080  # or: 8080 | localhost:8080 | 127.0.0.1:8080 | https://host:9443
# -> prints the one-time access link + QR code to scan
./scripts/new-link.sh    # another password, same public URL (revokes previous sessions)
./scripts/status.sh      # live checks (401 = gate active; never consumes the password)
./scripts/stop.sh        # stop tunnel + proxy
```

The target argument is parsed smartly: a bare port, `host:port`, or a full
`http(s)://host:port[/path]` all work. A path in the target passes through unchanged —
access the app under the same path on the public URL. `https://` upstreams are supported
(dev/self-signed certs accepted — `rejectUnauthorized: false`).

## How it works

```
Browser ── scan QR → https://*.trycloudflare.com/?key=…(one-time password)
             │ Cloudflare edge (TLS, HTTP/2, WebSocket)
             ▼
        cloudflared (quick tunnel, outbound-only, no account)
             │ http://127.0.0.1:3100
             ▼
        scripts/proxy.mjs — TWO layers, every request AND WebSocket upgrade:
        1. AUTH GATE   no key + no session cookie → 401 (WS: socket destroyed)
                       valid key → consumed, session cookie minted,
                                  302 → clean URL (key stripped, no-referrer)
                       session cookie → authorized (incl. WS upgrades)
        2. REWRITE     Host + Origin → <upstream> (loopback), so Host-validation
                       fences (Vite CVE-2025-24010, custom /api fences) pass
             ▼
        your local server (untouched)
```

Key security properties (researched + validated end to end):

- **Constant-time** token comparison (`crypto.timingSafeEqual`), 256-bit random token
  (OWASP magic-link hygiene: ≥128-bit CSPRNG, single-use, short TTL).
- Cookie is **HttpOnly, SameSite=Strict, Secure**, path-scoped to the tunnel host.
  SameSite=Strict is the OWASP-recommended choice here: the QR scan is a same-site
  navigation, so strictness costs nothing and it blocks CSRF in all cross-site
  contexts (Lax would leave any state-changing GET reachable cross-site — OWASP calls
  that "the most common way SameSite defenses fail in practice"). Sessions and token
  state are **in-memory** — a proxy restart revokes everything (restart the proxy =
  kill all sessions; `new-link.sh` does exactly that).
- The token is only ever used once: the first request carrying it consumes it. After
  that, requests with the same key get 401. `?key=` is stripped from the redirect
  target and **every response** carries `Referrer-Policy: no-referrer` — query-string
  tokens leak through Referer, browser history, proxy logs, and network tools, and the
  policy plus the redirect strip covers all four vectors (OWASP Forgot Password CS /
  CSRF CS). Responses also carry `Cache-Control: no-store`.
- WebSocket upgrades are rejected with **401 before any frame flows** — RFC 6455
  sanctions cookie auth on the handshake (it is a plain HTTP GET; browsers send the
  cookie automatically), so the same gate covers WS with no extra code.
- The gate runs **before** the rewrite layer, so it covers HTTP and WebSocket equally.

## Validation (run before handing over the URL)

```sh
URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | tail -1)
curl -s -o /dev/null -w "%{http_code}\n" "$URL/"                    # 401 (gate)
curl -s -o /dev/null -w "%{http_code}\n" "$URL/?key=invalid"        # 401
# consume a real key (print a link first, use its token), then:
curl -s -i "$URL/?key=<REAL_TOKEN>" | head -4                        # 302, clean Location,
#  Set-Cookie HttpOnly/SameSite=Strict/Secure, Referrer-Policy: no-referrer
curl -s -o /dev/null -w "%{http_code}\n" "$URL/?key=<REAL_TOKEN>"   # 401 (consumed)
curl -s -c jar -L -o /dev/null -w "%{http_code}\n" "$URL/?key=<REAL_TOKEN>"  # 200 with cookie
# WebSocket upgrade — MUST use --http1.1 (over HTTP/2 the edge strips
# Connection/Upgrade headers and you get 426/502 instead of 101):
curl -s --http1.1 -b jar -o /dev/null -w "%{http_code}\n" --max-time 8 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  "$URL/<ws-path>"                                                  # 101 = pass
# without the cookie: rejected (socket destroyed / edge 502)
```

## WebSocket caveats (verified empirically)

- Browsers send cookies on the WS handshake (same-origin), so cookie-authenticated
  upgrades pass the gate — confirmed end to end through the tunnel (101).
- Long-idle WS connections can be dropped (close 1006) after ~100 s on Free/Pro plans
  when there is no protocol traffic and the server sends no pings; apps with a
  heartbeat or client-side reconnect are the durable fix. In testing, an idle
  connection survived 160 s — treat drops as possible, not guaranteed.
- Quick tunnels do **not** support SSE, cap in-flight requests at 200 (HTTP 429), and
  carry **no SLA** — test/dev only.

## Security (read before sharing the URL)

- The one-time password **is** the only gate: whoever scans the QR can use the service
  until they close the session. The URL without the password is useless (401), but the
  password is single-use — mint another link for the next person.
- Exposing an **agent/admin/dashboard** server publicly is still high-risk (Elastic
  classifies reverse-tunnel exposure of agent-managed admin apps as high severity —
  T1572); prefer exposing a built preview, not a dev server, and keep sessions short.
- Dev-server source leakage is documented, not theoretical: `@cloudflare/vite-plugin`
  < 1.6.0 served every project-root file (including `.env`, `.dev.vars`) through the
  dev server (CVE-2025-59427) — the gate protects access, but the served project's
  own exposure surface (what the dev server serves) is a separate concern. Prefer a
  **built preview** over `vite dev` for anything shared.
- The tunnel URL **regenerates on every cloudflared restart** — always re-read it from
  `tunnel.log`; passwords minted for the old URL die with it.
- `current-link` (mode 600, gitignored) stores the active token for `new-link.sh` —
  never commit or share it.

## Named tunnel (production: account + domain required)

```sh
cloudflared tunnel login
cloudflared tunnel create <name>                    # UUID + credentials file in ~/.cloudflared/
cloudflared tunnel route dns <name> app.yourdomain.com
# ~/.cloudflared/config.yml:
#   tunnel: <UUID>
#   credentials-file: /home/<user>/.cloudflared/<UUID>.json
#   ingress:
#     - hostname: app.yourdomain.com
#       service: http://127.0.0.1:3100      # the gate proxy — a custom domain is also not loopback
cloudflared tunnel --config ~/.cloudflared/config.yml run <name>
```

With a named tunnel, put **Cloudflare Access** in front for identity-aware auth — the
correct way to expose an agent or admin UI at production scale.
Docs: <https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/>

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `/` returns **401** without key/cookie | Expected — the gate is active. That IS the protection. |
| Key accepted once, then 401 on re-use | Correct: the password is single-use. Mint another with `new-link.sh`. |
| WS handshake returns **426/502** in tests | The test client negotiated HTTP/2 and the edge stripped upgrade headers — re-test with `curl --http1.1`. Browsers are unaffected. |
| WS rejected with a valid session | Session cookie missing in the test client (cookies are host-scoped — use the same host + `-b jar`). Or the proxy restarted (in-memory sessions revoked). |
| App path (e.g. `/api`) returns **403** with a live session | Host-validation fence — confirm cloudflared points at the **proxy** port (3100), not the app port. |
| `proxy: EADDRINUSE` in `proxy.log` | Old proxy still running (stale pid). `./scripts/stop.sh`, then retry. |
| QR shows fallback text | `qrencode` missing — `sudo apt install qrencode` (python3-qrcode is the second fallback). |
| tunnel never becomes ready | Check `tunnel.log` — usually an egress network block (outbound-only needed). |
| "websocket: bad handshake" in cloudflared logs | The origin refused the upgrade — gate rejection (no cookie) or a fence 403. See the rows above. |

## Files

```
SKILL.md                 this file
README.md                human-facing documentation
install.sh               one-command global installer (skill + CLI shortcut, macOS/Linux)
scripts/expose-port.sh   parse target, start gate proxy + quick tunnel, print link + QR
scripts/new-link.sh      mint another one-time password on the same public URL
scripts/status.sh        processes, gate health, live checks (never consumes the password)
scripts/stop.sh          stop tunnel + proxy
scripts/lib.sh           shared helpers: target parsing, token, QR, link state
scripts/proxy.mjs        zero-dep gate proxy (one-time token + session cookie + Host/Origin rewrite)
current-link             (runtime, gitignored) active host/port/token/URL — mode 600
```
