# dsh-remote-relay

Reach a local dsh engine from anywhere — without exposing it to the public
internet.

A four-part system for secure remote control of a machine-bound dsh
instance:

- **`server/`** (`dsh-remote-relay`) — a hardened reverse proxy + WebSocket
  relay you deploy on a cheap public VPS (Docker compose with nginx TLS
  included). It is the public edge: TLS termination, session gating, rate
  limiting, append-only audit log and a watchdog with webhook alerting.
- **`client/`** (`dsh-remote-relay-client`) — a headless CLI/library that
  runs next to the dsh engine on your machine. It dials **out** to the relay
  over a PSK-authenticated WebSocket tunnel and fulfils proxied HTTP/WS
  traffic locally. Zero inbound ports.
- **`plugin/`** (`dsh-remote-relay-plugin`) — the dsh framework plugin. It is a thin
  seam: it owns the pairing-QR settings card and route registration, and
  delegates the tunnel itself to `client/`. Use it when you want remote
  control managed from inside the dsh UI; use the CLI when you want it
  managed from a terminal or a service unit.
- **`app/`** (`dsh_remote_app`) — the Flutter remote-control app (iOS +
  Android, one codebase). Pair by scanning the same QR, then continue the
  machine's sessions from your pocket: streaming conversations, approval and
  question cards, jobs, models, context ring, subagent teams. Credentials in
  the platform keystore, TOFU-pinned relay, zero telemetry. See
  [app/README.md](app/README.md).

Your phone scans a QR (or opens a signed URL), lands on the relay origin,
and loads the dsh SPA straight from there — full remote control, with the
engine's PRIVILEGED surface staying loopback-only. The app pairs through the
same surface and keeps working when the browser can't.

```
phone ─HTTPS/WSS─→ nginx(TLS) ─→ relay (VPS) ~~~PSK tunnel /ws/dsh~~~ client ─→ dsh engine (127.0.0.1:3080)
                                    │
                                    ├─ session gate (signed URL / pairing cookie / Bearer)
                                    ├─ rate limit + readonly/query fences
                                    ├─ SQLite audit log (append-only)
                                    └─ watchdog (burst / probe / downtime alerts → webhook)
```

## The two-gate trust model

1. **Engine gate** — dsh binds loopback and serves `/api` only to requests
   whose Host is loopback or a `--trusted-host` entry; the 16 PRIVILEGED
   methods (`settings.*`, `credentials.*`, `host.*`, …) stay loopback-only.
2. **Relay gate** — the client pins the trusted authority into every
   bridged request (`Host` header), and the relay requires credentials
   (signed-URL query, pairing cookie, or `Bearer` session token) on every
   path except its own health/PSK endpoints.

Losing either gate still leaves the other holding: a leaked relay domain
serves nothing without a pairing, and the engine never trusts the public
directly.

## Quickstart

**Full self-hosting walkthrough (DNS, TLS, pairing, troubleshooting):
[`docs/deploy.md`](docs/deploy.md)** — the condensed version:

**1. VPS — start the relay**

```bash
cd server
cp .env.example .env
#   RELAY_PSK=$(openssl rand -hex 32)
#   RELAY_PUBLIC_HOST=relay.example.com
bash deploy/gen-selfsigned.sh relay.example.com   # or certbot
docker compose --profile tls up -d --build
```

**2. Local machine — pair with the relay**

```bash
cd client
pnpm install && pnpm build
dsh-remote-client pair --relay-url https://relay.example.com --psk <same RELAY_PSK>
# → prints a terminal QR; scan it with your phone
```

**3. Local machine — keep the tunnel alive**

```bash
dsh-remote-client serve --relay-url https://relay.example.com --psk <same RELAY_PSK>
```

`serve` and `pair` may run in any order — `serve` adopts pairings minted by
`pair` at runtime (and re-registers everything it holds on every reconnect).

(Start dsh with `--trusted-host relay.example.com` so its fence accepts
relay-bridged traffic.)

**Alternative — manage pairing from the dsh UI**

Instead of the CLI, install the plugin into your dsh profile. It adds a
"Remote Control" card (the plugin's own page in the Plugins panel, plus a
Settings nav section that stays reachable over the remote channel) that shows tunnel
state and renders a pairing QR, and it routes its lifecycle under
`/dsh-remote/`:

```bash
# Not on npm yet — pack both tarballs from a checkout, then install them together
pnpm install && pnpm -r build && scripts/pack-local.sh   # → dist-local/*.tgz
dsh plugin --profile <your-profile> add \
  dist-local/dsh-remote-relay-client-<v>.tgz \
  dist-local/dsh-remote-relay-plugin-<v>.tgz
```

Then set the same relay URL and PSK in the profile's patch layer — see
[`plugin/cordis.patch.yml`](plugin/cordis.patch.yml) for the config keys.
Leave `enabled: false` until the relay is up; a forgotten PSK override fails
closed at the relay rather than opening a channel.

Full runbooks: [`server/README.md`](server/README.md) ·
[`client/README.md`](client/README.md) · wire protocol:
[`docs/protocol.md`](docs/protocol.md) · plugin shows up as "异常" in the
host, or a profile install silently does nothing:
[`docs/profile-install-troubleshooting.md`](docs/profile-install-troubleshooting.md).

## Repo layout

```
server/    relay server (Fastify + ws + SQLite; Dockerfile, compose, nginx template)
client/    tunnel client (headless CLI + library, vitest) — the tunnel's single source of truth
plugin/    dsh framework plugin (settings card + routes; depends on client/)
app/       Flutter remote-control app (Android + iOS) + dsh_remote_core (Dart client)
scripts/   repo tooling: ARB key check, secret scan, profile packaging
docs/      protocol + engine-RPC references + deploy guide
```

The tunnel implementation exists **once**, in `client/`. The plugin imports it
rather than vendoring a copy, so a fix (for example cross-process pairing
adoption) reaches both consumers from a single edit. Protocol types are
deliberately hand-copied between server and client (they evolve together and
each side's test suite pins the shared shapes — see `docs/protocol.md` for
the authoritative frame reference).

## Security notes

- Production refuses to boot on the insecure default PSK or a missing
  `RELAY_PUBLIC_HOST` (fail-closed).
- Session secrets live in `server/data/relay-state.db` — treat that volume
  like a secret store. Client pairings live in `~/.dsh-remote-relay/`
  (chmod 600).
- Signed URLs are HMAC-SHA256 over the PSK with a ≤24 h TTL and a
  machine-binding `mid` hash; expired links fail closed.
- The watchdog raises webhook alerts on auth-failure bursts, PSK probing,
  proxy-error bursts, tunnel downtime and audit-DB growth.

## Documentation

- [`docs/protocol.md`](docs/protocol.md) — tunnel wire protocol (authoritative frame reference)
- [`docs/engine-rpc-errata.md`](docs/engine-rpc-errata.md) — **engine `/api` RPC 勘误表**：
  实测正确的信封形状与易错点（写引擎客户端前必读）
- [`docs/app-field-notes.md`](docs/app-field-notes.md) — Flutter app 真机踩坑与修复纪实
- [`docs/device-testing.md`](docs/device-testing.md) — **真机测试方案**：三层体系 +
  adb 控制真机手册 + 环境陷阱速查（跑回归前读）
- [`docs/engine-contract-m2.md`](docs/engine-contract-m2.md) — 引擎契约字段级引用
- [`docs/deploy.md`](docs/deploy.md) — VPS deployment
- [`app/README.md`](app/README.md) · [`app/TESTING.md`](app/TESTING.md) — app 开发与验收

> Working on the engine-facing client? Read the errata table **first** — most
> integration bugs in this project traced back to a hand-copied contract that
> the real engine never accepted.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the one-command verification path
(`pnpm verify`) and the leak-guard expectations. [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
sets the ground rules.

**Found a security issue?** Do not open a public issue — follow
[SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE).
