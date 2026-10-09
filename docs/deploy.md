# Self-hosting guide — deploy dsh-remote-relay on your own VPS

This is the complete walkthrough for running your own relay so your phone can
reach the dsh engine on your home/office machine from anywhere. Everything a
third-party operator needs; no reference to any specific deployment.

[中文用户] 本指南为自部署完整步骤：公网 VPS 跑 relay + nginx + watchdog，
家里/办公室的机器跑 dsh 引擎 + 隧道客户端，手机扫码即用。

## Topology

The deployment is deliberately split across two machines:

```
                    ┌─────────────── your VPS (public) ───────────────┐
 phone browser ───▶ │ nginx :443 (TLS) ─▶ relay :8080 ── watchdog     │
     (anywhere)     │                       │                          │
                    └───────────────────────┼──────────────────────────┘
                                            │ outbound WSS tunnel
                                            │ /ws/dsh  (PSK-authenticated,
                                            │ dialed FROM home — zero
                                            ▼           inbound ports)
                    ┌──────────── your machine (private) ──────────────┐
                    │ dsh-remote-relay-client (CLI or dsh plugin)      │
                    │   └─▶ dsh engine 127.0.0.1:3080                 │
                    └──────────────────────────────────────────────────┘
```

All proxied traffic rides the outbound tunnel. The VPS never opens a port to
your home machine, and your engine keeps binding loopback only.

## Prerequisites

- A VPS with Docker + Docker Compose v2, 1 vCPU / 1 GB is plenty.
- A domain name you control, with a subdomain you can point at the VPS
  (e.g. `relay.example.com`).
- Ports `80` and `443` open in the VPS firewall / cloud security group.
- On your local machine: dsh ≥ 0.1.7 and either the
  `dsh-remote-relay-plugin` dsh plugin or the `dsh-remote-client` CLI.
- Roughly synchronized clocks on both machines (the tunnel auth window is
  ±30 s — default OS NTP is fine).

## 1. DNS & firewall

Create an `A` record (or `AAAA`) for `relay.example.com` → your VPS IP.
Wait for it to resolve before issuing TLS certs — certbot checks it.

Open inbound `80`/`443` on the VPS. Do **not** open `8080`: the relay
container publishes nothing; nginx is the only entrance.

## 2. Get the code and configure

```bash
git clone <this repository> && cd dsh-remote-relay/server
cp .env.example .env
```

Edit `.env`:

```bash
# required — generate ONCE at first init and never regenerate casually:
#   openssl rand -hex 32
RELAY_PSK=<64 hex chars>

# required — the exact public authority phones will use.
# Must be a bare host (or host:port), identical to the dsh --trusted-host
# entry you will set locally. Spelling matters, no scheme, no path.
RELAY_PUBLIC_HOST=relay.example.com

# optional — how long the relay waits for the engine before answering 504.
# Default 180000 (180s). Coupled to `EngineRpc.defaultCallTimeout` (195s) in
# the App: raise one without the other and the smaller silently wins. It sits
# this high because a real host answers `session/list` in ~85s once the
# session count is in the thousands; see
# docs/internal/engine-session-list-degradation-report-20261004.md.
WSS_PROXY_TIMEOUT_MS=180000
```

**About `RELAY_PSK`** — this is the relay's front-door key: the local tunnel
client must present the same value to connect. Treat it as one-time setup:

- **Generate once** at first initialization (`openssl rand -hex 32`), and keep
  using that same value. Regenerating rotates the key — legitimate when you
  suspect a leak, but then every local client must be updated too.
- **It lives in `server/.env` on the VPS** (the file you just created; the
  compose stack reads it at startup). To read it back later — e.g. when
  pairing a new Mac — run on the VPS:

  ```bash
  grep RELAY_PSK .env
  # or, if the stack is already running:
  docker compose exec relay printenv RELAY_PSK
  ```

- **Copy it to the local side once** (password manager, scp, AirDrop — just
  not a public channel), then paste it into the dsh UI:
  **Plugins → 远程控制 (dsh-remote-relay-plugin) → 配置 → 共享密钥** — see
  [`plugin/README.md`](../plugin/README.md#configure-in-the-dsh-ui-recommended).
  The value is write-only there: it never displays again after saving.
- Rotating later (VPS `.env` + the local form, same new value on both ends)
  does **not** break already-paired phones — they ride per-session secrets,
  not the PSK.

Optional but recommended:

```bash
# watchdog alerts (Bark / ntfy / any JSON POST endpoint)
RELAY_ALERT_WEBHOOK_URL=https://your-webhook.example/xxx

# ONLY if you also expose plugin-owned realtime WebSockets through the
# relay (e.g. a market-data plugin): list their absolute paths, CSV.
RELAY_WS_BRIDGE_PATHS=
```

The relay **refuses to boot** with the default PSK or without
`RELAY_PUBLIC_HOST` — that is the fail-closed production guard, not an error
to work around.

`DSH_UPSTREAM` only matters for the single-box fallback data plane
(`RELAY_DATA_PLANE=http`); in the normal split topology all traffic rides the
tunnel and you can leave the default.

## 3. TLS

### Test drive — self-signed (5 minutes)

```bash
bash deploy/gen-selfsigned.sh relay.example.com
docker compose --profile tls up -d --build
```

Phones will warn about the untrusted cert — fine for a trial, not for
production.

### Production — Let's Encrypt

The nginx template only redirects on :80 (no ACME location), so issue with
certbot standalone **before** bringing the stack up (nothing else may hold
:80):

```bash
sudo certbot certonly --standalone -d relay.example.com
# certbot writes /etc/letsencrypt/live/relay.example.com/
mkdir -p deploy/certs
sudo cp /etc/letsencrypt/live/relay.example.com/fullchain.pem deploy/certs/
sudo cp /etc/letsencrypt/live/relay.example.com/privkey.pem  deploy/certs/
sudo chown $USER deploy/certs/*.pem && chmod 600 deploy/certs/privkey.pem

docker compose --profile tls up -d --build
```

Renewal (Let's Encrypt certs last 90 days) — standalone needs :80 free, so
briefly stop the nginx container:

```bash
docker compose stop nginx
sudo certbot renew --quiet
sudo cp /etc/letsencrypt/live/relay.example.com/*.pem deploy/certs/ 2>/dev/null || true
docker compose start nginx
```

Put that in a monthly cron/systemd timer on the VPS.

## 4. Start and verify the relay

> **已经在跑的机器请先读 `server/docker-compose.prod.yml` 的文件头。** 上面
> 这些命令是**从零自托管**的形态（bridge 网段 + 项目内 nginx + 0.0.0.0:8080）。
> 在一台已经跑着 relay 的机器上直接执行，会因为项目名不同而派生出一个
> **空数据卷**——手机配对当场全丢——并且去抢 8080 端口。已有部署请用
> `docker compose -f docker-compose.prod.yml up -d --build`。

```bash
docker compose --profile tls up -d --build
docker compose ps                 # relay + watchdog + nginx all healthy
curl -s https://relay.example.com/health   # JSON — the only unauthenticated path
```

Then confirm the gate is closed to strangers:

```bash
curl -sI https://relay.example.com/ | head -1
# expect a 4xx access-denied — zero-credential visitors get nothing
```

If the relay container exits immediately, read its reason in
`docker compose logs relay` — it will be the PSK / PUBLIC_HOST guard.

## 5. Local side — your machine running dsh

Two interchangeable ways to keep the tunnel alive.

**Option A — the dsh plugin (managed from the dsh UI):**

```bash
dsh plugin --profile <your-profile> add dsh-remote-relay-plugin
```

Then override the shipped defaults in the profile patch layer (see
[`plugin/cordis.patch.yml`](../plugin/cordis.patch.yml) for the keys):

```yaml
- id: dsh-remote
  config:
    enabled: true
    relay_url: 'https://relay.example.com'
    psk: '<same RELAY_PSK>'
```

**Option B — the headless CLI:**

```bash
dsh-remote-client serve --relay-url https://relay.example.com --psk <same RELAY_PSK>
```

And in **both** cases start dsh itself with the trusted host — the engine's
fence must accept relay-bridged requests:

```bash
dsh --profile <your-profile> --host 127.0.0.1 --port 3080 \
    --trusted-host relay.example.com
```

`--trusted-host` must match `RELAY_PUBLIC_HOST` **character for character**
(same spelling, no scheme). A mismatch shows up later as dsh answering 403
to every relayed call.

## 6. Pair your phone

Mint a pairing (prints a QR in the terminal):

```bash
dsh-remote-client pair --relay-url https://relay.example.com --psk <same RELAY_PSK>
```

or open the plugin's own page in the local dsh UI — **Plugins → 远程控制
(dsh-remote-relay-plugin)** — and click 开启远程控制 to mint the QR on the
card (the Settings → 远程控制 section shows the same QR without the
configuration form). Scan it with the phone — the browser
lands on the relay origin and the dsh SPA loads with full remote control.

Pairings survive restarts on both sides (state lives in the VPS volume
`relay-data`; re-bind window `RELAY_SESSION_GRACE_SEC`, absolute cap
`RELAY_SESSION_MAX_AGE_SEC`). Past either limit the phone simply gets 401 —
re-scan.

## 7. Operations

| task | command |
|---|---|
| follow logs | `docker compose logs -f relay watchdog` |
| inspect the audit trail | `sqlite3 /var/lib/docker/volumes/<project>_relay-data/_data/relay-audit.db 'SELECT created_at,event_type,ip,details FROM audit_logs ORDER BY id DESC LIMIT 50;'` (`<project>` = the compose project name, usually the directory name) |
| rotate the PSK | change `RELAY_PSK` on the VPS **and** locally, `docker compose up -d`, restart the tunnel — existing phone pairings are unaffected (they ride session secrets, not the PSK) |
| tune the engine wait | change `WSS_PROXY_TIMEOUT_MS` on the VPS, `docker compose up -d` — **and** change `EngineRpc.defaultCallTimeout` in the App to stay above it, or the smaller of the two wins and the other is dead code |
| upgrade | `git pull && docker compose --profile tls up -d --build` — the `relay-data` volume carries pairings across upgrades |
| back up | back up the `relay-data` volume — `relay-state.db` holds session secrets at rest; treat it like a secret store |
| kick every phone | Settings card → disconnect-all, or `DELETE /dsh-remote/session` — device cookies die immediately |

## 8. Troubleshooting

| symptom | cause → fix |
|---|---|
| relay container exits at boot | fail-closed guard: unset/default `RELAY_PSK` or missing/invalid `RELAY_PUBLIC_HOST` — the log names which |
| tunnel never connects; audit shows `psk_fail` | PSK differs between VPS and client — re-copy it; also check clock sync (±30 s window) |
| phone loads the SPA but every call 403s | dsh was started without `--trusted-host`, or its spelling differs from `RELAY_PUBLIC_HOST` |
| phone gets 401 after working before | pairing expired past the grace/cap window, or revoked — re-scan the QR |
| 503 `plugin_not_connected` | tunnel down: check the local client/plugin state and the VPS `/health` |
| a plugin's realtime WebSocket won't connect through the relay | its path is not in `RELAY_WS_BRIDGE_PATHS` on the VPS (and, if it authenticates by `?token=`, not in the plugin's `token_rewrite_prefixes` locally) |
| cert warnings on the phone | you are still on the self-signed cert — switch to Let's Encrypt (step 3) |
| `host.docker.internal` unresolved (Linux VPS, single-box mode) | add `extra_hosts: ["host.docker.internal:host-gateway"]` to the relay service, or point `DSH_UPSTREAM` at the host IP |

## Security notes for operators

- Treat the VPS shell, `relay-state.db`, and `.env` as secrets — anyone with
  the PSK can open a tunnel; anyone with the state DB can impersonate paired
  sessions.
- The watchdog alerts on auth-failure bursts, PSK probing, proxy error
  bursts and long tunnel downtime — wire `RELAY_ALERT_WEBHOOK_URL` and pay
  attention to it.
- Losing the relay host loses **nothing** about your engine: wipe the VPS,
  redeploy, re-pair. The engine's privileged surface stays loopback-only
  regardless ([Host pinning](../server/README.md#host-pinning)).
