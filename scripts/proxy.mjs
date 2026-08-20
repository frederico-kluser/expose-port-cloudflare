#!/usr/bin/env node
/**
 * Rewrite reverse proxy for exposing a local server through a Cloudflare
 * Tunnel when the server validates Host/Origin (browser-trust fences).
 *
 * Why this exists:
 * - Vite dev servers validate Host since CVE-2025-24010 and reject tunnel
 *   hostnames with HTTP 403 unless listed in server.allowedHosts.
 * - Custom servers (e.g. the DeepSeek Harness /api fence, isTrustedApiRequest)
 *   admit only loopback Hosts (or explicitly trusted authorities) for API and
 *   WebSocket paths.
 * - A proxy that rewrites Host but NOT Origin breaks WebSocket handshakes
 *   (RFC 6455 §10.2 — Origin must match Host when checked).
 *
 * This proxy rewrites BOTH headers: Host -> <upstream_host>:<upstream_port>
 * (loopback) and Origin -> the same authority, so both fences pass without
 * touching the served project. sec-fetch-site is left untouched — same-origin
 * requests from the tunnel page already carry `same-origin`, which fences
 * accept. WebSocket upgrades are relayed with the same rewrite.
 *
 * Zero dependencies (node:http only). Config via environment:
 *   UPSTREAM_HOST (default 127.0.0.1)
 *   UPSTREAM_PORT (default 3080)
 *   LISTEN_PORT   (default 3100)
 */

import http from 'node:http'

const UPSTREAM_HOST = process.env.UPSTREAM_HOST ?? '127.0.0.1'
const UPSTREAM_PORT = Number(process.env.UPSTREAM_PORT ?? 3080)
const LISTEN_PORT = Number(process.env.LISTEN_PORT ?? 3100)
const REWRITTEN_AUTHORITY = `${UPSTREAM_HOST}:${UPSTREAM_PORT}`
const HEALTH_PATH = '/__expose-port-health'

/** Rewrite the fence-relevant headers for one request. */
function rewriteHeaders(headers) {
  const out = { ...headers }
  out.host = REWRITTEN_AUTHORITY
  if (out.origin !== undefined) out.origin = `http://${REWRITTEN_AUTHORITY}`
  return out
}

const server = http.createServer((req, res) => {
  if (req.url === HEALTH_PATH) {
    res.writeHead(200, { 'content-type': 'text/plain' })
    res.end('ok')
    return
  }
  const upstream = http.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: req.method,
    path: req.url,
    headers: rewriteHeaders(req.headers),
  }, (upRes) => {
    res.writeHead(upRes.statusCode, upRes.headers)
    upRes.pipe(res)
  })
  upstream.on('error', (err) => {
    console.error(`[proxy] upstream error: ${err.message}`)
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' })
    res.end(`proxy error: ${err.message}`)
  })
  req.pipe(upstream)
})

// WebSocket upgrades: relay with the same header rewrite, then bridge bytes.
server.on('upgrade', (req, socket, head) => {
  const upstream = http.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: 'GET',
    path: req.url,
    headers: rewriteHeaders(req.headers),
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
  console.log(`[proxy] listening on 127.0.0.1:${LISTEN_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT} (host/origin rewritten)`)
})
