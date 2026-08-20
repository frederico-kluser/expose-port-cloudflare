# expose-port-cloudflare

**Expose any local port on the internet through a Cloudflare Tunnel — protected by a one-time password shown as a QR code in the terminal.**

No account, no domain, no changes to your project. The skill mints a random password,
appends it to the public URL, prints the full link as a **QR code** (scan and open),
**consumes the password on first access** (the URL is cleaned and the token dies), and
hands the redeeming browser a secure session cookie. Anyone without the password gets
**401** — on HTTP **and** WebSocket.

This is an [agent skill](SKILL.md) (Claude Code / agent-compatible) with executable
scripts. The target is parsed smartly: `8080`, `localhost:8080`, `http://localhost:8080`
or `https://host:9443/path` all work.

## Why the gate and the proxy exist

A plain `cloudflared tunnel --url http://127.0.0.1:8080` leaves the service **public and
unauthenticated** — anyone with the link can use it. Two failure classes also break
naive tunnels:

- **No auth**: quick-tunnel URLs are random but shareable; nothing stops an unintended
  holder from using the service.
- **Host-validation fences** — Vite rejects tunnel hostnames with `403` since
  CVE-2025-24010; custom servers (e.g. agent harnesses) often admit only loopback hosts
  for API/WebSocket paths. Result: *the page opens, the app is dead*.
- **Origin mismatch** — a proxy that rewrites `Host` but not `Origin` breaks WebSocket
  handshakes (RFC 6455 §10.2).

This skill solves all three with one zero-dependency Node proxy, **without touching the
project being exposed**.

## Architecture

```
Browser ── scan QR → https://*.trycloudflare.com/?key=<one-time password>
             │  Cloudflare edge (TLS, HTTP/2, WebSocket via extended CONNECT)
             ▼
        cloudflared (quick tunnel, outbound-only, no account needed)
             │  http://127.0.0.1:3100
             ▼
        scripts/proxy.mjs (Node, zero deps) — on EVERY request and WS upgrade:
          1. AUTH GATE    401 without key+cookie; valid key → consume, mint
                          HttpOnly/SameSite=Strict/Secure cookie, 302 → clean
                          URL (key stripped, no-referrer); cookie = authorized
          2. REWRITE      Host + Origin → <upstream>, so fences pass
             ▼
        your local server (untouched)
```

## Quick start

```sh
git clone https://github.com/frederico-kluser/expose-port-cloudflare.git
cd expose-port-cloudflare
./scripts/expose-port.sh http://localhost:8080   # prints link + QR
# ── scan with your phone — the password is consumed on first access ──
./scripts/new-link.sh    # another password, same URL, previous sessions revoked
./scripts/status.sh      # live checks (401 = gate active; never burns the password)
./scripts/stop.sh
```

Requirements: [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/),
Node.js (any modern LTS; `node:http` only, no dependencies), and optionally
[`qrencode`](https://fukuchi.org/works/qrencode/) for the terminal QR (graceful fallbacks).

## Security model

| Property | How |
|---|---|
| No access without the password | 401 on every path (HTTP + WS upgrade) without key/cookie |
| Single-use password | Consumed server-side on first use; re-use → 401; 10-min TTL before first use |
| Clean URL after redemption | 302 to the key-stripped URL + `Referrer-Policy: no-referrer` |
| Session cookie | `HttpOnly`, `SameSite=Strict`, `Secure`, host-scoped, 24 h, in-memory store |
| Token comparison | Constant-time (`crypto.timingSafeEqual`), 256-bit random |
| No persistent secrets | Token/sessions are in-memory — restarting the proxy revokes everything |
| Fences still pass | Host + Origin rewritten to the loopback upstream |

## Validation matrix (what was verified end to end through a live tunnel)

| Check | Expected |
|---|---|
| `GET /` (no key, no cookie) | `401` |
| `GET /?key=invalid` | `401` |
| `GET /?key=<real>` (first use) | `302` → clean `Location`, `Set-Cookie` (HttpOnly/SameSite=Strict/Secure), `no-referrer` |
| Re-using the consumed key | `401` |
| `GET /` with the redeemed cookie | `200` |
| WebSocket upgrade with cookie (`curl --http1.1`) | `101` |
| WebSocket upgrade without cookie | rejected (socket destroyed) |
| New link via `new-link.sh` | old key `401`, new key `302`; public URL unchanged |
| Idle WebSocket (>2 min, no heartbeat) | survived in testing; treat drops as possible, prefer apps with pings/reconnect |

## Security — read before sharing

- The password **is** the gate: whoever scans the QR can use the service. It is
  single-use — mint another link for the next person. The bare URL is useless (401).
- Exposing an **agent/admin/dashboard** server publicly remains high-risk (Elastic
  classifies reverse-tunnel exposure of agent-managed admin apps as high severity —
  T1572). Prefer a built preview over a dev server, and keep sessions short.
- Quick tunnels are for **test/development**: no SLA, ~200 in-flight requests max (HTTP 429),
  no SSE, and the URL **changes on every cloudflared restart**.
- For production, use a **named tunnel** with your domain and put **Cloudflare Access**
  in front for identity-aware auth. Steps in [SKILL.md](SKILL.md) §Named tunnel.

## License

MIT — see [LICENSE](LICENSE).

*Built from two verified deep-research passes (105 + 78 agents, adversarial 3-vote
verification) on Cloudflare Tunnel mechanics, one-time-URL-token patterns, WebSocket
idle behavior, and reverse-tunnel security — validated live end to end.*
