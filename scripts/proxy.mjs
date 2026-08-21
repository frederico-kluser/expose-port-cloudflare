#!/usr/bin/env node
/**
 * Rewrite reverse proxy + one-time-password gate for exposing a local server
 * through a Cloudflare Tunnel.
 *
 * Two layers, applied to EVERY request and WebSocket upgrade:
 *
 * 1. Auth gate (link password + session cookie)
 *    The public URL is unusable without the password: requests without a
 *    valid `?key=<TOKEN>` and without a session cookie get 401. A request
 *    carrying the valid key mints a session cookie (HttpOnly, SameSite=Strict,
 *    Secure) and 302-redirects to the clean URL (token stripped from the URL,
 *    Referrer-Policy: no-referrer so the token does not leak through
 *    referrers). The key is REUSABLE by default (every browser holding it gets
 *    in; TOKEN_REUSE=0 restores single-use: the first request burns it).
 *    The cookie authorizes the browser session, including WebSocket upgrades
 *    (browsers send cookies on the WS handshake). Sessions and token state
 *    are in-memory: restarting the proxy revokes everything.
 *
 * 2. Host/Origin rewrite (browser-trust fences)
 *    Vite dev servers reject unknown Hosts since CVE-2025-24010; custom
 *    servers (e.g. agent harnesses) admit only loopback Hosts for API/WS
 *    paths. Rewriting Host -> <upstream>:<port> and Origin -> the same
 *    authority makes both fences pass WITHOUT touching the served project.
 *    A proxy rewriting Host but not Origin would break WebSocket handshakes
 *    (RFC 6455 §10.2) — both are rewritten here.
 *
 * Zero dependencies (node:http/https). Config via environment:
 *   UPSTREAM_HOST   (default 127.0.0.1)
 *   UPSTREAM_PORT   (default 3080)
 *   UPSTREAM_PROTO  (http | https, default http; https uses rejectUnauthorized:false for dev certs)
 *   LISTEN_PORT     (default 3100)
 *   TOKEN           (REQUIRED — the link password, >= 16 chars)
 *   TOKEN_REUSE     (default 1 — the password keeps working for every browser
 *                   until the proxy restarts or a new link is minted; set "0"
 *                   for single-use: the first request burns the password)
 *   TOKEN_TTL_MS    (default 0 = no expiry — token lifetime before first use;
 *                   set > 0 to restore a time limit in ms)
 *   SESSION_TTL_MS  (default 86400000 = 24 h — browser session lifetime)
 */

import http from 'node:http'
import https from 'node:https'
import crypto from 'node:crypto'

const UPSTREAM_HOST = process.env.UPSTREAM_HOST ?? '127.0.0.1'
const UPSTREAM_PORT = Number(process.env.UPSTREAM_PORT ?? 3080)
const UPSTREAM_PROTO = process.env.UPSTREAM_PROTO === 'https' ? 'https' : 'http'
const LISTEN_PORT = Number(process.env.LISTEN_PORT ?? 3100)
const TOKEN = process.env.TOKEN ?? ''
const TOKEN_REUSE = process.env.TOKEN_REUSE !== '0' // default: reusable
const TOKEN_TTL_MS = Number(process.env.TOKEN_TTL_MS ?? 0)
const SESSION_TTL_MS = Number(process.env.SESSION_TTL_MS ?? 24 * 60 * 60 * 1000)
const KEY_PARAM = 'key'
const COOKIE_NAME = '__expose_sid'
const HEALTH_PATH = '/__expose-port-health'
const STATUS_PATH = '/__expose-port-status'

if (TOKEN.length < 16) {
  console.error('[proxy] TOKEN env is required (>= 16 chars) — scripts/expose-port.sh generates it')
  process.exit(1)
}

const transport = UPSTREAM_PROTO === 'https' ? https : http
const REWRITTEN_AUTHORITY = `${UPSTREAM_HOST}:${UPSTREAM_PORT}`
const tokenBuf = Buffer.from(TOKEN)
const sessions = new Map() // sessionId -> expiresAt (ms)
let tokenConsumed = false
const tokenIssuedAt = Date.now()

/** Constant-time token comparison (length fixed at generation). */
function tokenMatches(candidate) {
  if (typeof candidate !== 'string') return false
  const c = Buffer.from(candidate)
  return c.length === tokenBuf.length && crypto.timingSafeEqual(c, tokenBuf)
}

function tokenUsable() {
  return !tokenConsumed && (TOKEN_TTL_MS <= 0 || Date.now() - tokenIssuedAt <= TOKEN_TTL_MS)
}

/** Rewrite the fence-relevant headers for one request. */
function rewriteHeaders(headers) {
  const out = { ...headers }
  out.host = REWRITTEN_AUTHORITY
  if (out.origin !== undefined) out.origin = `http://${REWRITTEN_AUTHORITY}`
  return out
}

function sessionIdFrom(req) {
  const cookie = req.headers.cookie
  if (!cookie) return undefined
  for (const part of cookie.split(';')) {
    const eq = part.indexOf('=')
    if (eq === -1) continue
    const [name, value] = [part.slice(0, eq).trim(), part.slice(eq + 1).trim()]
    if (name === COOKIE_NAME) return value
  }
  return undefined
}

/** Whether the request carries a live session cookie. */
function hasSession(req) {
  const id = sessionIdFrom(req)
  if (id === undefined) return false
  const expiresAt = sessions.get(id)
  if (expiresAt === undefined) return false
  if (expiresAt > Date.now()) return true
  sessions.delete(id)
  return false
}

function keyFrom(urlStr) {
  try {
    return new URL(urlStr, 'http://proxy').searchParams.get(KEY_PARAM)
  } catch {
    return null
  }
}

/** Path + query with the one-time key removed (the redirect target). */
function stripKey(urlStr) {
  const u = new URL(urlStr, 'http://proxy')
  u.searchParams.delete(KEY_PARAM)
  return u.pathname + (u.search !== '' ? u.search : '')
}

function sendUnauthorized(req, res) {
  // Path only — never log the query string (it may carry the key).
  const path = new URL(req.url, 'http://proxy').pathname
  console.log(`[proxy] 401 ${req.method} ${path} (no valid key, no session cookie)`)
  res.writeHead(401, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'referrer-policy': 'no-referrer',
  })
  res.end('<!doctype html><meta charset="utf-8"><title>401 Unauthorized</title>'
    + '<h1>401 Unauthorized</h1>'
    + '<p>This link requires the password from the terminal. Mint a new link with '
    + '<code>./scripts/expose-port.sh &lt;url&gt;</code> or <code>./scripts/new-link.sh</code>.</p>')
}

/**
 * Accept the token, mint a session, and redirect to the clean URL. In reusable
 * mode (default) the token stays valid for every browser; in single-use mode
 * (TOKEN_REUSE=0) the first request burns it.
 */
function redeemToken(req, res) {
  if (!TOKEN_REUSE) tokenConsumed = true
  const sid = crypto.randomBytes(24).toString('base64url')
  sessions.set(sid, Date.now() + SESSION_TTL_MS)
  console.log(`[proxy] key accepted (${TOKEN_REUSE ? 'reusable' : 'single-use'}) — session minted`)
  res.writeHead(302, {
    location: stripKey(req.url),
    'set-cookie': `${COOKIE_NAME}=${sid}; Path=/; HttpOnly; SameSite=Strict; Secure; Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`,
    'referrer-policy': 'no-referrer',
    'cache-control': 'no-store',
  })
  res.end()
}

/** Gate: true when the request may reach the upstream. */
function authorize(req, res) {
  if (hasSession(req)) return true
  const key = keyFrom(req.url)
  if (key !== null) {
    if (tokenMatches(key) && tokenUsable()) {
      redeemToken(req, res)
      return false
    }
    // Wrong, expired, or already-consumed token.
    sendUnauthorized(req, res)
    return false
  }
  sendUnauthorized(req, res)
  return false
}

const server = http.createServer((req, res) => {
  if (req.url === HEALTH_PATH) {
    res.writeHead(200, { 'content-type': 'text/plain' })
    res.end('ok')
    return
  }
  // Loopback status for status.sh: token state only — never the token itself.
  if (req.url === STATUS_PATH) {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({
      consumed: tokenConsumed,
      reusable: TOKEN_REUSE,
      ttlMs: TOKEN_TTL_MS,
      issuedAgoMs: Date.now() - tokenIssuedAt,
    }))
    return
  }
  if (!authorize(req, res)) return
  const upstream = transport.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: req.method,
    path: req.url,
    headers: rewriteHeaders(req.headers),
    rejectUnauthorized: false, // dev certs; the tunnel edge terminates public TLS
  }, (upRes) => {
    // no-referrer on every response: the one-time key lives in the query
    // string and must never leak through a Referer (OWASP Forgot Password CS).
    res.writeHead(upRes.statusCode, { ...upRes.headers, 'referrer-policy': 'no-referrer' })
    upRes.pipe(res)
  })
  upstream.on('error', (err) => {
    console.error(`[proxy] upstream error: ${err.message}`)
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' })
    res.end(`proxy error: ${err.message}`)
  })
  req.pipe(upstream)
})

// WebSocket upgrades: same gate, then relay with the header rewrite.
// RFC 6455 sanctions cookie auth on the upgrade (the handshake is a plain
// HTTP GET) — reject with 401 before any frame flows, per the OWASP/WS
// guidance, rather than dropping the socket silently.
server.on('upgrade', (req, socket, head) => {
  if (!hasSession(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n'
      + 'Connection: close\r\n'
      + 'Referrer-Policy: no-referrer\r\n'
      + 'Content-Length: 0\r\n\r\n')
    socket.end()
    return
  }
  const upstream = transport.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: 'GET',
    path: req.url,
    headers: rewriteHeaders(req.headers),
    rejectUnauthorized: false,
  })
  upstream.on('upgrade', (upRes, upSocket, upHead) => {
    socket.write('HTTP/1.1 101 Switching Protocols\r\n')
    for (const [name, value] of Object.entries(upRes.headers)) {
      socket.write(`${name}: ${value}\r\n`)
    }
    socket.write('\r\n')
    if (upHead?.length > 0) socket.write(upHead)
    socket.pipe(upSocket).pipe(socket)
  })
  upstream.on('response', () => {
    socket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n')
  })
  upstream.on('error', (err) => {
    console.error(`[proxy] upgrade error: ${err.message}`)
    socket.destroy()
  })
  upstream.end(head)
})

server.listen(LISTEN_PORT, '127.0.0.1', () => {
  console.log(`[proxy] gate + rewrite listening on 127.0.0.1:${LISTEN_PORT} -> ${UPSTREAM_PROTO}://${UPSTREAM_HOST}:${UPSTREAM_PORT}`)
  console.log(`[proxy] token active (${TOKEN_REUSE ? 'reusable' : 'single-use'}), TTL ${TOKEN_TTL_MS > 0 ? `${TOKEN_TTL_MS / 1000}s` : 'unlimited (no expiry)'}, consumed=${tokenConsumed}`)
})
