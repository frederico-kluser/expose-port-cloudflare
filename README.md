# expose-port-cloudflare

**Expose any local port on the internet with a Cloudflare Tunnel — no account, no domain, no changes to your project.**

This repository is an [agent skill](SKILL.md) (Claude Code / agent-compatible) with
**executable scripts** that take a local server (`http://127.0.0.1:<port>`) and hand you a
public `https://*.trycloudflare.com` URL in seconds — including for servers that
validate `Host`/`Origin` headers (Vite dev servers, custom browser-trust fences),
which break naive tunnels.

## Why it exists

Plain `cloudflared tunnel --url http://127.0.0.1:8080` works for trivial servers, but
fails silently for a common class of modern dev servers:

- **Host-validation fences** — Vite rejects tunnel hostnames with `403` since
  CVE-2025-24010; custom servers (e.g. agent harnesses) often admit only loopback
  hosts for API/WebSocket paths. Result: *the page opens, the app is dead*.
- **Origin mismatch** — a proxy that rewrites `Host` but not `Origin` breaks
  WebSocket handshakes (RFC 6455 §10.2).

This skill ships a zero-dependency rewrite proxy that fixes both, **without touching
the project being exposed** — everything lives in this folder.

## Architecture

```
Browser ── https://*.trycloudflare.com
             │  Cloudflare edge (TLS, HTTP/2, WebSocket via extended CONNECT)
             ▼
        cloudflared (quick tunnel, outbound-only, no account needed)
             │  http://127.0.0.1:3100
             ▼
        scripts/proxy.mjs (Node, zero deps)
             │  rewrites Host + Origin → 127.0.0.1:<your-port>
             ▼
        your local server (untouched)
```

## Quick start

```sh
git clone https://github.com/frederico-kluser/expose-port-cloudflare.git
cd expose-port-cloudflare
./scripts/expose-port.sh 8080        # your local server's port
# ... prints: TUNNEL READY: https://xxxx-xxx-xxx.trycloudflare.com
./scripts/status.sh 8080 /api        # live checks through the tunnel
./scripts/stop.sh                    # done: stop tunnel + proxy
```

Requirements: [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/) and Node.js (any modern LTS; only `node:http`, no dependencies).

## As an agent skill

Install globally so any agent can call it whenever a port needs to be public:

```sh
mkdir -p ~/.claude/skills
ln -s "$PWD" ~/.claude/skills/expose-port-cloudflare
```

The [SKILL.md](SKILL.md) frontmatter description carries trigger phrases in English and
Portuguese ("expose local port", "public URL for localhost", "abrir uma porta na
internet", "expor o servidor local"…). It encodes the verified knowledge behind the
scripts: fence diagnosis, the `--http1.1` WebSocket-test gotcha, idle-timeout
behavior, security posture, and the named-tunnel upgrade path.

## Validation matrix (what the skill verifies before you share a URL)

| Check | Expected |
|---|---|
| `GET /` through the tunnel | `200` |
| App paths (e.g. `/api`) | NOT `403` (a `404` is the app's own answer — fine) |
| WebSocket upgrade (with `curl --http1.1`) | `101` |
| Idle WebSocket (>2 min, no heartbeat) | survived in testing; treat drops as possible and prefer apps with pings/reconnect |

## Security — read before sharing

- Quick-tunnel URLs are **public and unauthenticated**. Anyone with the link can use the
  service. Never expose an unauthenticated agent, admin, or dashboard server this way.
- Quick tunnels are for **test/development**: no SLA, ~200 in-flight requests max (HTTP 429),
  no SSE, and the URL **changes on every restart**.
- For production, use a **named tunnel** with your domain and put **Cloudflare Access** in
  front for real authentication. Steps in [SKILL.md](SKILL.md) §Named tunnel.

## License

MIT — see [LICENSE](LICENSE).

*Built from a verified deep-research pass (105-agent adversarial review) on Cloudflare
Tunnel mechanics, Vite/CVE-2025-24010 Host validation, WebSocket idle timeouts, and
reverse-tunnel security — validated end-to-end against a live agent harness.*
