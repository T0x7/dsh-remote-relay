/**
 * Dual-face cordis plugin (host half) for dsh-remote-relay.
 *
 * Owns the outbound PSK-authenticated WebSocket tunnel to a public relay
 * and registers the pairing-QR lifecycle routes under `/dsh-remote`.
 * Phones reach dsh through the relay's HTTP/WS reverse proxy.
 *
 * DESIGN — single source of truth for the tunnel:
 *   The tunnel implementation lives in the `dsh-remote-relay-client`
 *   package, NOT here. This module is only the dsh seam: config schema,
 *   route registration, lifecycle, and the settings-card routes. The
 *   same `RemoteTunnelClient` class backs the `dsh-remote-client` CLI, so
 *   a fix (e.g. cross-process pairing adoption) reaches both consumers
 *   from one edit. Do not copy tunnel code into this file.
 *
 * Trust model: dsh's own host trust barrier keeps the configuration plane
 * off the remote channel; this tunnel carries pairing registration and
 * revocation, never configuration data.
 *
 * @module dsh-remote-relay-plugin
 */

import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context, Volatile } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import type {} from '@deepseek-ai/dsh-host-webserver' // ctx.webServer
import { RemoteTunnelClient } from 'dsh-remote-relay-client'

// dsh's settings domain emits this app-wide event after every committed form
// edit (packages/settings: emit('settings/document-updated', ns, revision)).
// Declared locally so this plugin needs no dependency on the settings package
// for one type-only import; the signature matches the upstream declaration
// (module augmentation merges the overloads).
declare module '@deepseek-ai/cordis' {
  interface Events {
    'settings/document-updated'(ns: string, revision: number): void
  }
}

export const name = 'dsh-remote'
export const inject = ['webServer']

/**
 * Route prefix for the pairing lifecycle. NOTE: the relay proxies this
 * prefix verbatim — server and client both pin it here and in
 * `tokenRewritePrefixes` consumers, so renaming this constant is a
 * three-way change (plugin here, relay server route table, tunnel client
 * rewrite prefix).
 */
export const ROUTE_PREFIX = '/dsh-remote'

/**
 * Routes only the dsh host may call — minting a pairing, revoking EVERY
 * pairing, and switching the tunnel by hand.
 *
 * WHY (v3.282): the relay forwards a paired device's request verbatim to this
 * engine's loopback listener, so from here every bridged request looks local.
 * Before this classification existed the code assumed "loopback-only by
 * deployment" — an assumption three hops away proved false: the relay mounts
 * `/dsh-remote/*` on its own public route table, and the tunnel hands over the
 * device's method, path and body untouched. A phone could therefore revoke the
 * pairings it is itself using, or cut the tunnel. Each is self-inflicted denial
 * of service, and the engine has no way to refuse by origin — the request
 * arrives from 127.0.0.1.
 *
 * The read-only half of this prefix stays reachable on purpose: the paired app
 * polls `GET /session` for status (app/lib/services/machines_session_poller.dart)
 * and renews its credential through `GET /url-session`
 * (app/lib/services/session_scheduler.dart).
 *
 * Enforcement is layered. The relay refuses the same three (method, path) pairs
 * before routing — see LOCAL_ADMIN_DENY in server/src/index.ts — AND this
 * handler refuses any request carrying the tunnel's provenance header, so a
 * misconfigured relay cannot widen the boundary either. Keep both lists in step.
 */
const LOCAL_ADMIN_ROUTES: ReadonlySet<string> = new Set([
  'POST session',
  'DELETE session',
  'POST tunnel',
])

/** Header the tunnel stamps on requests it forwarded from a paired device. */
const REMOTE_TUNNEL_MARKER_HEADER = 'x-dsh-remote-tunnel'

/**
 * Whether this request came in over the relay tunnel rather than from a browser
 * sitting on this machine. Node lowercases incoming header names.
 */
function cameThroughTunnel(req: IncomingMessage): boolean {
  const raw = req.headers[REMOTE_TUNNEL_MARKER_HEADER]
  return raw !== undefined && raw !== ''
}

/**
 * Shared-secret fallback. Mirrors the relay's documented insecure default
 * so a misconfigured pair fails *closed* at the relay rather than opening
 * a half-configured channel. Production must override both sides.
 */
export const DEFAULT_INSECURE_PSK = 'dsh-remote-relay-default-insecure-psk'

/**
 * Plugin config (cordis.patch.yml supplies the base layer).
 *
 * Every field is `volatile()`: dsh's settings domain serves a namespace (and
 * therefore a configuration form) ONLY for entries whose Config schema has
 * volatile fields — `volatileForm()` in packages/settings drops everything
 * else. A volatile field is also LIVE: the loader hands an observable and a
 * settings-form commit re-evaluates it in place, so each read goes through
 * `.get()` (same pattern as the vendored web-search-cn plugin).
 */
export interface Config {
  /** Dial the public relay and register the outbound WSS tunnel on engine boot. */
  enabled: Volatile<boolean>
  /** Relay origin (wss://…/ws/dsh dial target) the tunnel connects to. */
  relay_url: Volatile<string>
  /** Shared secret the tunnel authenticates to the relay with (rotate with the relay). */
  psk: Volatile<string>
  /** Local dsh engine origin the data plane fulfils traffic against. */
  upstream_host: Volatile<string>
  upstream_port: Volatile<number>
  /**
   * Persistence root override. Defaults to the client package's
   * `DSH_REMOTE_DATA_ROOT` (falling back to ~/.dsh-remote-relay).
   */
  data_root: Volatile<string>
  /**
   * dsh engine bind token, for engines started with one. The client library
   * falls back to DSH_BIND_TOKEN, but a dsh plugin cannot assume that env var
   * is exported into its process — this field is the plugin-owned way to
   * supply it. Empty means "unset"; the engine cookie mint is then skipped.
   */
  engine_token: Volatile<string>
  /**
   * WebSocket path prefixes whose `?token=` query the tunnel rewrites to
   * the engine bind token before forwarding (plugin-owned realtime streams
   * exposed through the relay). Opt-in; default rewrites nothing.
   */
  token_rewrite_prefixes: Volatile<string[]>
}

export const Config = z.object({
  enabled: z.boolean().default(false).volatile(),
  relay_url: z.string().default('http://127.0.0.1:8080').volatile(),
  psk: z.string().role('secret').default(DEFAULT_INSECURE_PSK).volatile(),
  upstream_host: z.string().default('127.0.0.1').volatile(),
  upstream_port: z.number().default(3080).volatile(),
  data_root: z.string().default('').volatile(),
  // role('secret') keeps the value out of form responses and remote reads
  // (packages/settings redactSecrets). Same treatment as the PSK.
  engine_token: z.string().role('secret').default('').volatile(),
  token_rewrite_prefixes: z.array(z.string()).default([]).volatile(),
})

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.statusCode = status
  res.setHeader('Content-Type', 'application/json; charset=utf-8')
  res.end(JSON.stringify(body))
}

/** Cap request bodies read by the tunnel route (action JSON). */
const MAX_BODY_BYTES = 64 * 1024

function readJsonBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    req.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        req.destroy()
        reject(new Error('body too large'))
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      try {
        resolve(chunks.length === 0 ? {} : JSON.parse(Buffer.concat(chunks).toString('utf8')))
      } catch (err) {
        reject(err)
      }
    })
    req.on('error', reject)
  })
}

export function apply(ctx: Context, config: Config) {
  // All fields are volatile (see Config): resolve LAZILY through .get() so
  // both the initial construction and every later updateConfig() read the
  // committed values. Empty-string fields mean "unset": the client package
  // resolves its own env/default chain (DSH_BIND_HOST / DSH_BIND_PORT /
  // DSH_BIND_TOKEN / DSH_REMOTE_DATA_ROOT) when they are not passed here.
  const resolveConfig = () => ({
    enabled: config.enabled.get() !== false,
    relayUrl: config.relay_url.get() || 'http://127.0.0.1:8080',
    psk: config.psk.get() || DEFAULT_INSECURE_PSK,
    upstreamHost: config.upstream_host.get() || undefined,
    upstreamPort: config.upstream_port.get() || undefined,
    dataRoot: config.data_root.get() || undefined,
    engineToken: config.engine_token.get() || undefined,
    tokenRewritePrefixes: [...config.token_rewrite_prefixes.get()],
  })
  const client = new RemoteTunnelClient(resolveConfig())

  if (config.enabled.get() !== false) client.connect()

  // Live config: a settings-form commit for THIS entry re-evaluates the
  // volatile fields in place and dsh emits settings/document-updated with the
  // entry id. Push the new options into the running client — updateConfig
  // disconnects when disabled and (re)connects when enabled, and the pairing
  // store survives in-process (same dataRoot). Without this listener a form
  // edit would only take effect after an engine restart.
  ctx.on('settings/document-updated', (ns: string) => {
    if (ns === name) client.updateConfig(resolveConfig())
  })

  // webServer.register returns a disposer that removes the route. It has to
  // go through ctx.effect so unloading this plugin (HMR switching the row
  // off, profile edit) actually withdraws /dsh-remote/* — otherwise the route
  // would outlive the plugin and keep serving pairing endpoints.
  ctx.effect(() => ctx.webServer.register({
    kind: 'prefix',
    path: ROUTE_PREFIX,
    handler: (req: IncomingMessage, res: ServerResponse): void => {
      void dispatch(req, res, client)
    },
  }), 'dsh-remote: routes')

  ctx.effect(() => {
    return () => {
      client.disconnect()
    }
  }, 'dsh-remote')

  ctx.logger.info('dsh-remote: tunnel routes mounted under %s', ROUTE_PREFIX)
}

async function dispatch(req: IncomingMessage, res: ServerResponse, client: RemoteTunnelClient): Promise<void> {
  const method = (req.method ?? 'GET').toUpperCase()
  const leaf = (req.url ?? '').split('?')[0]!.split('/').filter(Boolean)[1]

  // v3.282 engine-admin boundary. The relay refuses these same (method, leaf)
  // pairs before it routes; refusing again here is what makes the boundary
  // hold when the relay in front of this engine is misconfigured, replaced, or
  // simply an older build that predates the rule.
  if (cameThroughTunnel(req) && LOCAL_ADMIN_ROUTES.has(`${method} ${leaf}`)) {
    sendJson(res, 403, {
      error: 'engine admin route is not reachable from a paired device',
      hint: 'pairing, revocation and tunnel control live on the dsh host only',
    })
    return
  }

  if (leaf === 'session' && method === 'POST') {
    // Single-mode pairing: every pairing grants full control. The
    // configuration plane is kept off the remote channel by dsh's host
    // trust barrier plus the relay gate, not by a per-pairing mode flag.
    sendJson(res, 200, client.createSession())
    return
  }
  if (leaf === 'session' && method === 'DELETE') {
    // await: revocation must reach the relay (the tunnel is dialed up
    // briefly if needed) or device cookies stay valid — this is the
    // implementation point of the "disconnect invalidates" promise.
    const revoked = await client.revokeAllSessions()
    sendJson(res, 200, { ok: true, revoked })
    return
  }
  if (leaf === 'session' && method === 'GET') {
    // Lazy mint + code renewal:
    //  a) no pairing at all      -> mint one (QR stays ready after restart)
    //  b) pairing exists but the window expired and the relay reports no
    //     device ever scanned it -> renew (never kicks a live device)
    //  c) a device is paired, or the relay is unreachable -> never rotate
    // Manual disconnect never triggers this: disconnect means terminate.
    if (client.getConnectionState().state === 'connected') {
      if (client.getSessions().length === 0) {
        client.createSession()
      } else if (client.getSession() === null) {
        const devices = await client.getDevices()
        if (devices !== null && devices.length > 0 && !devices.some((d) => d.paired)) {
          client.createSession()
        }
      }
    }
    // Card contract: tunnel state + all retained pairings + the active QR
    // session + a relay-side device presence snapshot ("online N / paired
    // M"). `devices` is null when the relay is unreachable; the card
    // degrades rather than breaking.
    sendJson(res, 200, {
      tunnel: client.getConnectionState(),
      active: client.getSession(),
      sessions: client.getSessions(),
      devices: await client.getDevices(),
    })
    return
  }
  if (leaf === 'url-session' && method === 'GET') {
    // Signed session link (multi-device browser entry, root path /?).
    // mintUrlSession returns a 24h signed bearer the SPA lifts from
    // location.search; the gate verifies it without minting a cookie.
    // Reachable from a paired device BY DESIGN — it is how the phone renews
    // its credential (app/lib/services/session_scheduler.dart). It mints a
    // link, it does not change this engine's configuration.
    try {
      const url = client.mintUrlSession()
      sendJson(res, 200, { url })
    } catch (err) {
      sendJson(res, 400, { error: (err as Error).message })
    }
    return
  }
  if (leaf === 'tunnel' && method === 'POST') {
    // Manual tunnel switch ("disconnect relay / reconnect"). Local-admin:
    // refused for tunnel-borne requests above, and by the relay in front.
    let action = ''
    try {
      const body = (await readJsonBody(req)) as { action?: unknown }
      if (body.action === 'connect' || body.action === 'disconnect') {
        action = body.action
      } else {
        sendJson(res, 400, { error: 'action must be "connect" or "disconnect"' })
        return
      }
    } catch {
      sendJson(res, 400, { error: 'invalid JSON body' })
      return
    }
    sendJson(res, 200, client.setTunnelEnabled(action === 'connect'))
    return
  }
  sendJson(res, 404, { error: 'not found' })
}
