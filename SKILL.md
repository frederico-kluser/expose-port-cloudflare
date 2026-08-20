---
name: expose-port-cloudflare
description: Expor uma porta ou servidor local na internet via Cloudflare Tunnel — sem conta, sem domínio, sem modificar o projeto servido. Use quando alguém precisar abrir uma porta online, expor um dev server / localhost, compartilhar um link público para um serviço local, ou configurar um túnel Cloudflare (quick ou named). Triggers: "abrir uma porta na internet", "expor o servidor local", "me dá um link público", "túnel cloudflare", "expose local port", "public URL for localhost", "cloudflare tunnel".
---

# Expose a local port online with a Cloudflare Tunnel

Turns any `http://127.0.0.1:<port>` service into a public `https://*.trycloudflare.com` URL.
No Cloudflare account, no domain, no DNS, no inbound firewall changes — and the
served project stays **untouched** (all support code lives next to it).

## When to use

- Someone needs a public link to a local server (dev UI, API, dashboard, preview build).
- The service listens on `127.0.0.1` only (tunnels work fine — cloudflared connects locally).
- You must NOT modify the project being exposed (config files, `allowedHosts`, etc.).

## When NOT to use

- Production exposure → use a **named tunnel** (requires Cloudflare account + domain), see §Named tunnel.
- The service must be authenticated → quick tunnels are public and unauthenticated; put **Cloudflare Access** in front (named tunnel required) before sharing the URL.
- You have no `node` — the rewrite proxy (zero deps, `node:http`) needs it. A pure-HTTP service with no Host/Origin validation can skip the proxy (point cloudflared directly at the port), but the proxy is harmless and future-proof — prefer it.

## Prerequisites

```sh
# cloudflared (Linux x86_64):
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared && chmod +x cloudflared && sudo mv cloudflared /usr/local/bin/
# node (for the rewrite proxy): any modern LTS
```

## Execution

```sh
cd <sibling-folder>/expose-port-cloudflare   # this skill's folder
./scripts/expose-port.sh <local-port>        # e.g. 8080 — prints the public URL
./scripts/status.sh <local-port> /api ...    # live checks through the tunnel
./scripts/stop.sh                            # stop tunnel + proxy
```

Always validate end to end before reporting the URL as working (see §Validation).

## Why the rewrite proxy is always in the path

Two failure classes break naive tunnels; both are solved by `scripts/proxy.mjs`
(sits between cloudflared and the app, rewrites `Host` and `Origin` to the
loopback upstream):

1. **Host-validation fences.** Vite dev servers reject unknown hosts with 403
   since CVE-2025-24010 unless the host is in `server.allowedHosts`. Custom
   servers can have their own fence — e.g. DeepSeek Harness' browser-trust
   fence (`isTrustedApiRequest`) admits only loopback Hosts for `/api` and
   WebSocket upgrades. A tunnel hostname fails both → **403** on API/WS paths
   while the static UI still loads (the trap: "the page opens but the app is
   dead").
2. **Origin mismatch.** Any proxy that rewrites `Host` but not `Origin` breaks
   WebSocket handshakes (RFC 6455 §10.2 — when an Origin is attached it must
   match Host). The proxy rewrites **both**, so the handshake passes.

Diagnose a fence before touching the project:

```sh
# Same request locally with a tunnel-style Host:
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: anything.trycloudflare.com" http://127.0.0.1:8080/api/
# 403 → Host fence present → the proxy is mandatory (and sufficient).
# 200/404 → no fence on that path (a 404 is the app's own answer, not a block).
```

## Validation (run these before handing over the URL)

```sh
URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | tail -1)
curl -s -o /dev/null -w "root: %{http_code}\n" "$URL/"
curl -s -o /dev/null -w "api:  %{http_code}\n" "$URL/api/"          # expect NOT 403
# WebSocket upgrade — MUST use --http1.1: over HTTP/2 (ALPN with the Cloudflare
# edge) Connection/Upgrade headers are stripped, and the server answers 426
# "Upgrade Required" instead of 101:
curl -s --http1.1 -o /dev/null -w "ws:   %{http_code}\n" --max-time 8 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  "$URL/<ws-path>"
# 101 = pass. 426 = the upgrade headers were lost (H2) — retest with --http1.1.
# 403  = fence → confirm the proxy is between cloudflared and the app.
```

## WebSocket caveats (verified empirically)

- Cloudflare Tunnel supports WebSockets natively (browsers negotiate via the
  edge's H2 extended CONNECT; the origin sees a plain HTTP/1.1 upgrade).
- Proxies on Free/Pro plans can silently drop long-idle WS connections
  (close code 1006) after ~100 s with zero protocol traffic, unless the server
  sends WS ping frames (browsers auto-answer pongs per RFC 6455). A server
  with no heartbeat + a client with no reconnect = a UI that dies while idle.
  In one production-style test the idle connection survived 160 s, but treat
  the drop as possible: prefer apps that send pings or reconnect.
- Quick tunnels do **not** support SSE, cap in-flight requests at 200 (HTTP 429),
  and carry **no SLA** — test/dev only.

## Security (read before sharing the URL)

- A quick-tunnel URL is **public and unauthenticated**: anyone who has it can
  reach the exposed service. Exposing an agent/admin/dashboard server this way
  is high-risk (Elastic Security Labs classifies reverse-tunnel exposure of
  agent-managed admin apps as high severity — T1572). Exposing a raw `vite dev`
  server can leak source files. Prefer exposing a **built preview**, not the
  dev server, and never an unauthenticated agent or admin surface.
- The URL **regenerates on every cloudflared restart** — always re-read it from
  `tunnel.log` after a restart; tell whoever holds the link that it is ephemeral.

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
#       service: http://127.0.0.1:3100      # the proxy — a custom domain is also not loopback
cloudflared tunnel --config ~/.cloudflared/config.yml run <name>
```

With a named tunnel you can additionally lock the hostname down with Cloudflare
Access (identity-aware auth) — the correct way to expose an agent or admin UI.
Docs: <https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/>

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `/api` (or any app path) returns **403** through the URL but works locally | Host-validation fence. Confirm cloudflared points at the **proxy** listen port, not the app port. The proxy rewrites Host→loopback; that is the fix. |
| WS handshake returns **426** | The test client negotiated HTTP/2 (ALPN) and the edge stripped upgrade headers — re-test with `curl --http1.1`. Browsers are unaffected. |
| WS drops while idle (1006) | Edge idle timeout with no heartbeat (~100 s on Free/Pro). Nothing to fix in the tunnel: the app should ping, or its client should reconnect. |
| `proxy: EADDRINUSE` in `proxy.log` | Old proxy still running (stale pid). `./scripts/stop.sh`, then retry. |
| tunnel never becomes ready | Check `tunnel.log` — usually a network/firewall egress block (outbound-only needed) or cloudflared version issue. |
| "websocket: bad handshake" in cloudflared logs | The origin refused the upgrade — fence rejection (403/destroy). See the fence row. |

## Files

```
SKILL.md             this file
README.md            human-facing documentation
scripts/expose-port.sh   start proxy + quick tunnel, print public URL
scripts/status.sh        processes, proxy health, live checks (root, fence probe, WS probe)
scripts/stop.sh          stop tunnel + proxy
scripts/proxy.mjs        zero-dep Node rewrite proxy (Host/Origin → loopback upstream)
```
