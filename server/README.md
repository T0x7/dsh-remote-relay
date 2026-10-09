# dsh-remote-relay (server)

Secure reverse proxy + WebSocket relay that lets a phone reach a local dsh
engine running on `127.0.0.1:3080` without exposing the engine's `/api` to
the public internet. Hardened for public deployment.

The relay is the **second gate** in the two-gate remote-control trust model:

1. **First gate** — phone scans a QR containing a signed session URL (or a
   legacy one-time pairing link). The relay verifies it and the phone talks
   to the relay root; the URL signature / pairing cookie pins subsequent
   requests to one session.
2. **Second gate** — EVERY path except `/health`, `/auth`, `/__devices`
   (PSK-authenticated) and `/ws/dsh` (PSK-authenticated outbound tunnel)
   requires credentials: `/api/*` HTTP, `/api/events.*` + `/api/remote.mux`
   (+ `RELAY_WS_BRIDGE_PATHS`) WebSocket upgrades, plugin HTTP routes
   (any prefix — including `/dsh-remote/*` for this project's own pairing
   routes), and SPA assets alike.

The local dsh engine is the **first trust gate**: start it with
`--trusted-host <RELAY_PUBLIC_HOST>` so the dsh `/api` fence accepts requests
arriving via the relay hostname, while the PRIVILEGED method gate
(`settings.*` / `credentials.*` / `host.*` / `agentPreset.*` /
`llm.discoverModels` / `tool.invoke`) stays loopback-only — **enforced by the
relay pinning the Host header** (see "Host pinning" below).

The relay itself is a proxy plus two SQLite stores: the append-only audit log
and the persisted pairing state. It does not own any user credentials beyond
the per-session secrets.

## Architecture

```
phone browser ─HTTPS/WSS─→ nginx (TLS) ─→ relay:8080 ─HTTP/WS─→ dsh engine:127.0.0.1:3080
                                               │
                                               ├─ /                  (signed-URL landing gate)
                                               ├─ /__pair            (legacy pairing landing)
                                               ├─ /api/*   onRequest (gate: cookie / Bearer / signed URL)
                                               ├─ /api/events.*       (upgrade gate check)
                                               ├─ /ws/dsh            (engine-side outbound PSK tunnel)
                                               └─ everything else     (gate + proxy → dsh SPA)

watchdog (same image, separate container) ─ every 5 min ─→ reads audit DB
        └→ alerts: pino log + watchdog_alert rows + RELAY_ALERT_WEBHOOK_URL
```

The phone browser loads the dsh SPA directly from the relay origin. All
`fetch('/api/...')` and WebSocket upgrades carry credentials set at landing
time and pass through to the dsh engine.

## Host pinning

dsh classifies every `/api` request by its **Host header**: loopback unlocks
the PRIVILEGED methods, a `--trusted-host` entry passes the basic fence but
not PRIVILEGED, anything else gets 403. The proxy dependency
(`@fastify/http-proxy` → `reply-from`) **rewrites Host to the upstream
authority (`127.0.0.1:3080`) by default** — which would present all relayed
traffic to dsh as loopback. The relay therefore:

- requires `RELAY_PUBLIC_HOST` (bare authority, same spelling as the dsh
  `--trusted-host` entry) — `buildServer()` refuses to construct without it;
- pins that authority into every proxied HTTP request
  (`rewriteRequestHeaders`) and every WS upgrade, so client Host forgery is
  irrelevant;
- refuses production boot on the default PSK or a missing/invalid
  `RELAY_PUBLIC_HOST` (`assertProductionConfig`).

## Session lifetime

Pairings are persisted to `data/relay-state.db` and survive relay restarts.
A tunnel drop **tombstones** the sessions instead of revoking them: if the
tunnel reconnects within the grace window (default 600 s,
`RELAY_SESSION_GRACE_SEC`) and re-registers the same pairing, the original
session secret is re-bound — phone sessions keep working across relay
restarts, engine restarts and network blips. The client side re-registers
its retained pairings on every tunnel (re)connect. Absolute cap:
`RELAY_SESSION_MAX_AGE_SEC` (default 30 days) from first pairing; past the
grace window or the cap, credentials fail closed (401 → re-scan).

`data/relay-state.db` holds session secrets at rest — treat the data volume
like a secret store.

## Configuration

| env | default | description |
|-----|---------|-------------|
| `RELAY_PSK` | *(none — production refuses the insecure default)* | shared secret the local client sends as `Authorization: Bearer <psk>` when dialing `/ws/dsh` |
| `RELAY_PUBLIC_HOST` | *(required)* | authority dsh should see on relayed requests; must match a dsh `--trusted-host` entry (bare `host` or `host:port`) |
| `DSH_UPSTREAM` | `http://127.0.0.1:3080` | where to proxy `/api/*` and `/` to |
| `RELAY_TRUST_PROXY` | `127.0.0.1,::1` | CSV of proxy IPs/CIDRs trusted for `X-Forwarded-For` (the nginx hop). `trustProxy: true` semantics are deliberately avoided — a client-spoofed XFF must not drive the rate limiter or audit IPs |
| `PORT` / `HOST` | `8080` / `0.0.0.0` | listen socket |
| `AUDIT_DB_PATH` / `STATE_DB_PATH` | `data/relay-audit.db` / `data/relay-state.db` | SQLite paths (WAL) |
| `RELAY_SESSION_GRACE_SEC` | `600` | tunnel-drop re-bind window |
| `RELAY_WS_BRIDGE_PATHS` | *(empty)* | CSV of extra absolute WS paths to bridge to dsh beyond the core event streams (`/api/events.*`, `/api/remote.mux`) — list plugin-owned realtime endpoints here; anything else is refused on upgrade |
| `RELAY_SESSION_MAX_AGE_SEC` | `2592000` | absolute session lifetime (30 days) |
| `RELAY_ALERT_WEBHOOK_URL` | *(empty)* | watchdog alert JSON POST target |
| `LOG_LEVEL` | `info` | pino level (`silent` to disable) |

Watchdog envs: `WATCHDOG_INTERVAL_SEC` (300) · `WATCHDOG_HEALTH_URL` ·
`WATCHDOG_WINDOW_SEC` (900) · `WATCHDOG_AUTH_FAIL_PER_IP` (20) ·
`WATCHDOG_AUTH_FAIL_TOTAL` (200) · `WATCHDOG_PSK_FAIL` (5) ·
`WATCHDOG_READONLY_BLOCKED` (30) · `WATCHDOG_PROXY_ERRORS` (10) ·
`WATCHDOG_TUNNEL_DOWN_SEC` (1200) · `WATCHDOG_DB_MAX_MB` (512).

## Deploy (docker compose — recommended)

Full step-by-step for a fresh VPS — DNS, Let's Encrypt, first-run
verification, troubleshooting, operations — lives in
[`../docs/deploy.md`](../docs/deploy.md). Condensed:

```bash
cd server
cp .env.example .env
#   RELAY_PSK=$(openssl rand -hex 32)     # same value as the client config
#   RELAY_PUBLIC_HOST=relay.example.com   # same value as dsh --trusted-host
bash deploy/gen-selfsigned.sh relay.example.com   # test certs; use certbot for prod

# start relay + watchdog + nginx (TLS) on the fixed 172.28.0.0/24 network
docker compose --profile tls up -d --build

# start the local dsh side
dsh --host 127.0.0.1 --port 3080 --trusted-host relay.example.com
```

The compose file pins container IPs (relay `.5`, watchdog `.6`, nginx `.10`)
so `RELAY_TRUST_PROXY=172.28.0.10` trusts exactly the nginx hop. The relay
itself publishes no port; nginx terminates TLS, passes
`X-Forwarded-For`/`X-Forwarded-Proto`, and keeps WS upgrades alive
(`deploy/nginx-relay.conf.template`). Without the `tls` profile you can run
relay + watchdog behind a host nginx — copy the proxy directives from the
template (`Host` passthrough is no longer load-bearing since the relay pins
it, but XFF is).

`docker compose logs -f relay watchdog` follows the structured logs;
`docker inspect` health status reflects the `/health` probe.

## Run (bare metal)

```bash
pnpm install && pnpm build
RELAY_PSK=<psk> RELAY_PUBLIC_HOST=relay.example.com \
  DSH_UPSTREAM=http://127.0.0.1:3080 node dist/index.js
node dist/watchdog.js          # watchdog loop (or WATCHDOG_ONCE=1 for one pass)
pnpm test
```

## Routes

| method | path | purpose |
|--------|------|---------|
| GET    | `/health` | liveness probe (no auth; watchdog + docker healthcheck) |
| GET    | `/` | signed-URL landing gate — validates `?sessionId&hash&t&exp&mid`, serves the dsh SPA with the query intact (SPA injects it as `Authorization: Bearer`); zero-credential visitors get an access-denied page |
| GET    | `/__pair?sessionId=&token=` | legacy pairing landing — validate pairing token, issue cookie, redirect to `/auth?next=/` |
| GET/POST etc. | `/api/*` | proxied to dsh; requires gate credentials |
| any    | `/dsh-remote/*` and other plugin/SPA paths | proxied to dsh; requires gate credentials |
| WS     | `/api/events.mux`, `/api/events.host`, `/api/remote.mux`, `RELAY_WS_BRIDGE_PATHS` entries | proxied to dsh; gate checked on upgrade |
| WS     | `/ws/dsh` | outbound tunnel from the local client; `Authorization: Bearer <RELAY_PSK>` + `x-session-ts` (±30 s window), constant-time compare |
| GET    | `/__devices` | device presence snapshot; `Authorization: Bearer <RELAY_PSK>` |
| GET    | `/auth?next=` | proxied to dsh BrowserAuth (exempt from the gate — it carries its own X-App-Token check upstream) |

## Wire protocol

The client↔relay tunnel carries two planes over `/ws/dsh`:

- **Control plane** (JSON): `session.register` / `session.registered` /
  `session.revoke`.
- **Data plane** (JSON frames, `v: 1`): `http.req` / `http.res` /
  `ws.upgrade` / `ws.accept` / `ws.frame` / `ws.close` / `error` / `ping` /
  `pong` — the relay turns phone HTTP requests and WS upgrades into frames
  and the client fulfils them against the local engine.

Full frame reference: [`../docs/protocol.md`](../docs/protocol.md).

## Audit & watchdog

Every landing, proxied API call, WS upgrade, auth failure and gate block is
written to `data/relay-audit.db` (SQLite, WAL). The watchdog container
re-reads it every 5 minutes and raises `watchdog_alert` events (also POSTed
to `RELAY_ALERT_WEBHOOK_URL`) on: per-IP / total auth-failure bursts, PSK
probing, gate probing, upstream proxy error bursts, relay health failures,
long tunnel downtime, and audit DB size overflow. Inspect manually:

```sql
SELECT created_at, event_type, session_id, ip, details
FROM audit_logs ORDER BY id DESC LIMIT 100;
```

## Logging

Operational logs are pino JSON lines on **stdout** (`LOG_LEVEL` to tune;
secrets redacted). Docker logging drivers collect and rotate them —
`docker compose logs -f relay` to follow. Per-request truth lives in the
audit DB, not the log stream.

## Live smoke (optional, against a real local dsh)

```bash
pnpm build
node live-smoke.mjs   # needs a real dsh on 127.0.0.1:3080 + engine.token on disk
```

Overridables: `RELAY_PSK`, `RELAY_PUBLIC_HOST`, `DSH_ENGINE_PORT`,
`DSH_ENGINE_TOKEN_FILE`.

## Why this design

The relay does **not** serve its own SPA — the phone loads the dsh SPA
directly, which already supports the mobile viewport. The dsh trust model is
unchanged: dsh binds loopback and serves `/api` to requests whose Host is
loopback or trustedHosts; the relay terminates TLS, authenticates the phone,
and pins the trusted authority into every upstream request. Two gates are
better than one — losing either gate still leaves the other holding.
