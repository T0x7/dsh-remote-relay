# dsh-remote-relay-client

The client half of [dsh-remote-relay](../README.md): pairs a local dsh engine
with a relay server over a PSK-authenticated **outbound** WebSocket tunnel.

Your machine dials out; nothing listens inbound. The client fulfils the
relay's proxied HTTP and WebSocket traffic against the local engine, so the
engine's own API is never exposed to the internet.

This package is the **single source of truth for the tunnel** — the
`dsh-remote-relay-plugin` framework plugin imports it rather than vendoring a copy.

## Install

This package is **not published to npm yet** — build it from a checkout:

```bash
git clone https://github.com/T0x7/dsh-remote-relay.git
cd dsh-remote-relay
pnpm install          # links the `dsh-remote-client` bin into node_modules/.bin
pnpm -r build
```

Then run the CLI either as `npx dsh-remote-client …`, or as
`node_modules/.bin/dsh-remote-client …`, or put that directory on your `PATH`
(e.g. via `pnpm link --global`).

## CLI

```bash
dsh-remote-client serve  --relay-url https://relay.example.com --psk <PSK>
dsh-remote-client pair   --relay-url https://relay.example.com --psk <PSK>
dsh-remote-client list
dsh-remote-client share  --ttl 3600
dsh-remote-client devices
dsh-remote-client revoke <id|all>
```

`pair` prints a terminal QR and exits. `serve` keeps the tunnel alive and
**adopts** pairings minted by a separate `pair` process at runtime, so the
two commands may run in any order. Every one-shot command disconnects
explicitly before exiting.

The CLI reads its own env names before the library's:

| CLI flag | CLI env | library env (fallback) |
|----------|---------|------------------------|
| `--relay-url` | `DSH_REMOTE_RELAY_URL` | *(none — required)* |
| `--psk` | `DSH_REMOTE_PSK` | `RELAY_PSK` |
| `--data-root` | `DSH_REMOTE_DATA_ROOT` | `DSH_REMOTE_DATA_ROOT` |

It exits with a clear error if either the URL or the PSK is missing.

## Library

```ts
import { RemoteTunnelClient } from 'dsh-remote-relay-client'

const client = new RemoteTunnelClient({
  enabled: true,
  relayUrl: 'https://relay.example.com',
  psk: process.env.RELAY_PSK!,
})
client.connect()
```

## Configuration

Every field below `relayUrl` falls back to an env var, then to a default:

| field | env | default |
|-------|-----|---------|
| `relayUrl` | *(none — required)* | — pass it, or use the CLI's `--relay-url` |
| `psk` | `RELAY_PSK` | *(required)* |
| `publicHost` | `RELAY_PUBLIC_HOST` | the `relayUrl` authority — the right default when phone and relay share a host |
| `upstreamHost` | `DSH_BIND_HOST` | `127.0.0.1` |
| `upstreamPort` | `DSH_BIND_PORT` | `3080` |
| `engineToken` | `DSH_BIND_TOKEN` | *(empty — engine cookie mint is skipped)* |
| `dataRoot` | `DSH_REMOTE_DATA_ROOT` | `~/.dsh-remote-relay` |
| `tokenRewritePrefixes` | — | `[]` (no rewrite). Pass plugin realtime WS prefixes, e.g. `['/my-plugin/realtime']`, when the relay bridges them |

`publicHost` matters: dsh classifies every `/api` request by its `Host`
header, and the client pins this authority into bridged requests so the
relay can never present remote traffic as loopback.

## Persistence

Pairings and a machine-binding `install-id` (chmod 600) live under
`dataRoot`. Treat the directory as a secret store.

## Testing

```bash
pnpm test
```

## License

MIT
