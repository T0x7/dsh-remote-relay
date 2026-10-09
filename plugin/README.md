# dsh-remote-relay-plugin

The dsh framework plugin for [dsh-remote-relay](../README.md). Adds remote
control of your local dsh engine to the dsh UI, and keeps the engine's
configuration plane off the remote channel.

This package is a **thin seam**, not a second implementation:

```
plugin (this package)  ──config schema · routes · settings card──┐
                                                              ├──▶ client/  tunnel implementation
plugin (this package)  ──remote gating · auth watchdogs─────────┘
```

The tunnel lives in `dsh-remote-relay-client` and is imported, never copied.
The `dsh-remote-client` CLI uses the exact same class, so a fix (for example
cross-process pairing adoption) reaches both from one edit.

## Install

Not published to npm yet — install from local tarballs. Pack both packages from
a checkout of this repo (the plugin depends on `dsh-remote-relay-client` by
name, so both tarballs have to be installed in one command):

```bash
pnpm install && pnpm -r build   # once, at the repo root
scripts/pack-local.sh           # → dist-local/*.tgz
```

```bash
dsh plugin --profile <your-profile> add \
  dist-local/dsh-remote-relay-client-<v>.tgz \
  dist-local/dsh-remote-relay-plugin-<v>.tgz
```

The plugin's tarball resolves the client by name (`workspace:*` is rewritten at
pack time), and that name is not on npm until the client is published. If pnpm
still tries the registry, add
`"pnpm": { "overrides": { "dsh-remote-relay-client": "file:<abs path to the client tgz>" } }`
to the profile's `package.json` and re-run the same `add`. A tarball install
needs **no build permission** (unlike a git dependency, whose `prepare` pnpm
gates behind an explicit allow) — that is exactly why the tarball is the
recommended form until these packages reach npm.

### Configure in the dsh UI (recommended)

The configuration entry lives on the plugin's own page: **Plugins → 远程控制
(dsh-remote-relay-plugin) → 配置**. Fill in the relay connection form at the
top of the card:

| field | meaning | where the value comes from |
|---|---|---|
| 启用出站中继隧道 (`enabled`) | master switch; the tunnel dials out on engine boot when on. Ships **off** so a fresh install opens no public channel | — |
| 中继地址 (`relay_url`) | your relay origin, e.g. `https://relay.example.com` | the domain you pointed at the VPS |
| 共享密钥 (`psk`) | must match the relay's `RELAY_PSK`. Write-only — it is never read back | generated once on the VPS at init (`openssl rand -hex 32`); read it back from the relay's `.env` — see `docs/deploy.md` §2 |
| 本机引擎地址 / 端口 | the local dsh the data plane fulfils traffic against (usually left at the defaults) | — |
| 引擎绑定令牌 (`engine_token`) | only when the engine runs with a bind token | your dsh engine's bind token |

The same page also shows the pairing QR and the pairing link (below the
form): 开启远程控制 generates a 24h QR; the link text under it opens the same
URL session in a browser.

**Settings → 远程控制** is a different surface on purpose: it renders the
card **without the configuration form** — status, QR and devices only. The
remote channel hides the Plugins panel (its management plane is
PRIVILEGED-heavy), so that Settings section is the surface a paired phone can
actually open, and it must not even carry the local engine's
relay-credential editor, read-only or not.

Edits are written through the Host's config editor, validated against the
plugin's `Config` schema, and persisted into your profile's
`cordis.patch.yml` — no hand-editing required, and no engine restart. A
refused value is rejected and the field snaps back to the accepted one.

On a **remote** (non-loopback) page no configuration surface exists at all:
the Plugins panel is gated off and the Settings section carries no form.
Configure from a loopback page.

### Configure by hand (equivalent)

The same fields can be set in your profile's patch layer — see
[`cordis.patch.yml`](cordis.patch.yml) for the shipped defaults:

```yaml
- insert:
    - id: dsh-remote
      name: 'dsh-remote-relay-plugin'
      config:
        enabled: true
        relay_url: 'https://relay.example.com'
        psk: '<same RELAY_PSK as the relay>'
```

| key | default | meaning |
|-----|---------|---------|
| `enabled` | `false` | master switch; the tunnel dials out on engine boot when true |
| `relay_url` | `http://127.0.0.1:8080` | relay origin |
| `psk` | insecure default | shared secret; **must match the relay's `RELAY_PSK`** |
| `upstream_host` / `upstream_port` | `127.0.0.1` / `3080` | local engine the data plane fulfils traffic against |
| `engine_token` | *(empty)* | engine bind token, when the engine requires one (write-only) |
| `data_root` | *(empty)* | pairing persistence override; falls back to `DSH_REMOTE_DATA_ROOT`, then `~/.dsh-remote-relay` |
| `token_rewrite_prefixes` | `[]` | plugin realtime WS paths whose `?token=` is rewritten to the engine token |

The relay refuses to boot in production on the default PSK, so a forgotten
override fails **closed** rather than opening a half-configured channel.

Start the engine with `--trusted-host <relay host>` so its own trust barrier
accepts relay-bridged traffic.

## What the card does

The card renders on two surfaces: the plugin's own configuration page in the
dsh **Plugins** panel (`plugins.bundle.config`, keyed by this package's npm
name — the slot the dsh plugin spec assigns to a third-party bundle's
configuration), and a **Settings** nav section kept deliberately reachable
over the remote channel (the Plugins panel itself is gated off remotely
because its management plane is PRIVILEGED-heavy). Both show a "Remote
Control" card with the tunnel state, a pairing QR with a live countdown, and
a global disconnect. Behind it:

- `GET /dsh-remote/session` — tunnel state, retained pairings, active QR, device presence
- `POST /dsh-remote/session` — mint a pairing
- `DELETE /dsh-remote/session` — revoke all pairings (device cookies die immediately)
- `GET /dsh-remote/url-session` — signed 24h link for browser multi-device use
- `POST /dsh-remote/tunnel` — manual connect / disconnect

## Remote gating

Over a non-loopback origin the client half hides the PRIVILEGED-heavy UI
entries (Models, Plugins, Agent-presets, workspace pickers) by injecting a
stylesheet, so a remote operator meets a working UI instead of raw 403s. The
hidden set is pinned by `tests/remote-capability-invariants.spec.ts`.

The auth injector covers `/api/*` and `/dsh-remote/*` — dsh core plus this
plugin's own routes, which is the complete surface of a standalone
deployment. An engine that also hosts other plugins with their own HTTP
routes should add those prefixes in `src/client/index.ts` (`AUTH_PREFIXES`)
before building; the pairing-cookie path authorizes every same-origin
request regardless of the list, so only URL-session (Bearer) entry is
affected.

## Testing

From the repo root, one command installs, builds, runs every suite and checks
the built client bundle:

```bash
pnpm verify
```

Or the long form — **build first**, because the browser-half specs exercise the
built `lib/client.js`, not the sources:

```bash
pnpm install && pnpm -r build && pnpm -r test
```

Layers, and what each one can see:

| spec | covers | needs |
|---|---|---|
| `host-half.spec.ts` | `apply()` — Config defaults, the `webServer` route, its disposer on teardown, `ctx.logger` use, and that no `default` export shadows the named ones | devDependencies |
| `loader-composition.e2e.ts` | the bundle manifest contract (bare-name row, `dsh.client.platform`, `exports['./client']`, name consistency across manifest/patch/build) — always runs | nothing |
| `loader-composition.e2e.ts` | the REAL composition: `dsh` booted through its Loader with this bundle's row present, via `@deepseek-ai/dsh-loader-smoke` | devDependencies + a `dsh` binary on `PATH` |
| `client-bundle.spec.ts` | the built `lib/client.js` — one factory registered under the package name, no `export`/`import` (it runs as a plain script), no undeclared `@deepseek-ai/dsh-client-*` require | `pnpm build` |
| `gating` / `auth-watchdog` | the client half's pure DOM logic (remote gating CSS, URL-session injection, the 401 and device-replaced watchdogs) | nothing |
| `relay-config-form.spec.ts` | the relay form's value rules — type coercion, port range, secret write-only state | nothing |
| `remote-capability-invariants.spec.ts` | the PRIVILEGED-method mirror the remote gating depends on | nothing |

Specs whose requirements are unmet **skip with a printed reason** rather than
failing, so a bare checkout is green and CI (which installs, builds and has
`dsh`) runs the full set. A green run that also reports skips is not the same as
a green run without them — check the printed reasons.

### Trying it in a real dsh before you publish

`dsh plugin add` needs the package resolvable by name, and this package depends
on `dsh-remote-relay-client` by name — so a real bundle install needs the client
on npm first. To exercise the host half before that, use the local-test
overlay, which mounts the same rows straight from your checkout:

```bash
pnpm verify                                                   # builds lib/index.js
dsh --profile <name> \
  --patch ~/path/to/dsh-remote-relay/plugin/cordis.local-test.patch.yml \
  --dump-config
```

`--dump-config` composes the tree without booting, and the row appears
attributed to the patch file with its path resolved to `file:///…/lib/index.js`.
Omit `--dump-config` to boot for real. The overlay covers the **host half
only** — the browser half loads through the package manifest, so it needs a
genuine bundle install. See the header of `cordis.local-test.patch.yml` for
exactly what each step does and does not prove.

Why the real-composition layer exists: the dsh testing policy
(`packages/AGENTS.md` rule 7) requires a product-visible plugin to prove
itself by booting a test-only `cordis.yml` through the Loader, because a
hand-built context cannot observe the failure modes that matter — a row
mounted from a subpath silently loses its browser half, a peer range the
running dsh rejects skips the bundle with a warning instead of throwing, and
a fiber that mounts but ends FAILED is invisible to a unit test.

## License

MIT
