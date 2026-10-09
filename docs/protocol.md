# dsh-remote-relay wire protocol

Everything crossing the tunnel (`/ws/dsh`) is JSON text frames. There are
two planes on the same WebSocket:

- **Control plane** — pairing lifecycle (`session.*`).
- **Data plane** — proxied HTTP and WebSocket traffic (`http.*`, `ws.*`,
  `error`, `audit`).

Both sides hand-copy the frame types (server `src/session.ts` + `src/index.ts`,
client `src/tunnel.ts`); each side's test suite pins the shared shapes, so a
one-sided change turns a test red. This document is the human-readable
authority.

## Tunnel authentication

The client opens `GET wss://<relay>/ws/dsh` with:

- `Authorization: Bearer <RELAY_PSK>` — constant-time compared against the
  server's PSK;
- `x-session-ts: <epoch-ms>` — must be within ±30 s of the relay clock
  (replay window).

A wrong PSK or stale timestamp is refused and audited (`psk_fail`).

## Control plane

Client → relay:

```jsonc
// register (or re-register) a pairing; sent on every tunnel (re)connect
{ "type": "session.register", "payload": {
    "sessionId": "sess_<16 hex>",
    "pairingToken": "<64 hex>",
    "ttlSeconds": 300,
    "engineToken": "<optional engine X-App-Token, in-memory only>"
}, "timestamp": 1690000000000 }

// revoke a pairing (kills the phone's credential server-side)
{ "type": "session.revoke", "payload": { "sessionId": "sess_…", "reason": "User revoked" }, "timestamp": … }
```

Relay → client:

```jsonc
{ "type": "session.registered", "sessionId": "sess_…", "reusesSecret": false, … }
// reusesSecret=true means the grace window re-bound the original session
// secret instead of minting a new one (phone cookies survive tunnel blips)
```

Registering the **same** `sessionId` + `pairingToken` after a tunnel drop
within `RELAY_SESSION_GRACE_SEC` re-binds the original secret — this is the
rebind contract the client relies on when it re-registers every retained
pairing on reconnect.

## Data plane (`v: 1`)

All data-plane frames carry `v: 1` and an `id` correlating request/response.

| frame | direction | fields | purpose |
|-------|-----------|--------|---------|
| `http.req` | relay → client | `id, method, path, headers, body?` | phone HTTP request to fulfil against the local engine |
| `http.res` | client → relay | `id, status, headers, body` | response; body is a UTF-8 string (clients must send `accept-encoding: identity` upstream — see limits) |
| `ws.upgrade` | relay → client | `id, path, headers` | phone WebSocket upgrade to bridge |
| `ws.accept` | client → relay | `id` | upgrade succeeded; frames may flow |
| `ws.frame` | both | `id, dir: "up"\|"down", opcode: 1\|2, payload` | WS payload; `dir=up` phone→engine, `down` engine→phone; `opcode 2` (binary) payload is base64, `opcode 1` (text) is UTF-8 |
| `ws.close` | both | `id, code?, reason?` | either side closed the bridged WS |
| `error` | both | `id, code, message` | per-request failure; codes: `payload_too_large`, `concurrency_exceeded`, `engine_down`, … |
| `audit` | client → relay | `payload: { eventType, sessionId, details }` | client-side security events appended to the relay's audit DB |

### Header rules for `http.req` fulfilment

The client MUST, before hitting the local engine:

1. strip any incoming `dsh_remote_session*` cookies (relay-gate credentials
   never reach the engine);
2. set `host` to the trusted public authority (`RELAY_PUBLIC_HOST` /
   `publicHost` config) — this is what keeps the engine's PRIVILEGED fence
   closed;
3. if an engine token is configured, inject `x-app-token`;
4. force `accept-encoding: identity` (JSON-frame bodies are UTF-8 strings;
   compressed upstream bytes would be corrupted by the text encoding).

### Size limits

| limit | value | enforced by |
|-------|-------|-------------|
| `http.req` body | 4 MiB | both sides |
| `http.res` body | 32 MiB | client (relay mirrors) |
| concurrent large (>1 MiB) responses | 8 | client (503-style `concurrency_exceeded` beyond) |
| `ws.frame` payload | 4 MiB | both sides |

## Signed session URLs (QR / share links)

Root-path URLs carry their own credential; the SPA reads the query and sends
`Authorization: Bearer <sessionId>.<exp>.<mid>.<t>.<hash>` on `/api`
requests. No cookie is issued.

```
https://<relay>/?sessionId=<sid>&hash=<h>&t=<ms>&exp=<ms>&mid=<m>[&name=<hostname>][&app_version=<v>]

hash = base64url(HMAC-SHA256(RELAY_PSK, "<sid>|<exp>|<mid>|<t>"))
mid  = sha256("<hostname>::<primary-mac>::<install-id>")     # machine binding, self-check only
ttl  = t..exp, 60 s … 86400 s (24 h max)
```

The relay verifies the HMAC, the time window, and the sessionId's
registration state; `token` as a query parameter is deliberately absent
(upstream SPAs 303-strip it).

## Legacy pairing landing

`GET /__pair?sessionId=<sid>&token=<pairingToken>` validates the token and
issues `dsh_remote_session__<sid>=<secret>; HttpOnly; Secure;
SameSite=Strict` before redirecting to `/auth?next=/`. Retained for links
shared before signed-URL migration; new pairings use signed URLs only.

## Engine RPC (the `/api` surface behind the tunnel)

This document covers the **relay's own tunnel frames**. Engine calls that ride
inside the tunnel (`POST /api/<endpoint>`, `$events` streams, `$events/result`)
have their own, separately maintained reference: **[engine-rpc-errata.md](engine-rpc-errata.md)**,
which records the wire shapes proven against a live engine — including the
ones that a hand-written client gets wrong.

## Keepalive

- Client: WS-level ping every 30 s; two missed pongs → terminate + reconnect.
- Client: public-IP probe every 60 s (ipify/ip.sb/icanhazip); an egress IP
  change terminates the socket immediately (half-open NAT flap guard).
- Relay: stale-close identity guard — a reconnecting tunnel's new socket
  kicks the old one only after verifying registration identity.
