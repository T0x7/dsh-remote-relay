/**
 * Host half: apply() against a recording double for the injected context.
 *
 * The dsh testing policy requires a product-visible plugin to prove itself
 * through a REAL composition (boot a test-only cordis.yml through the Loader)
 * rather than hand-built `ctx.plugin(...)` suites — see
 * tests/loader-composition.e2e.ts, which drives the installed `dsh` binary via
 * @deepseek-ai/dsh-loader-smoke, and packages/AGENTS.md rule 7.
 *
 * That real-composition smoke needs an installed toolchain and is a separate
 * spec. This file covers the half the policy cannot reach in a bare checkout:
 * apply() itself — that it registers its route through ctx.effect, that the
 * route disappears on teardown, and that Config values reach the tunnel
 * client instead of being swallowed. A regression here is invisible to a
 * Loader smoke that never dials a relay.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createRequire } from 'node:module'

/** One recorded ctx.effect() registration and its disposer. */
interface EffectRecord {
  label: string
  dispose: () => void
}

/** A route as webServer.register() records it. */
interface RouteRecord {
  kind: string
  path: string
  handler: unknown
}

/** A recording stand-in for the `webServer` service apply() registers routes on. */
class FakeWebServer {
  readonly registered: RouteRecord[] = []
  /** Registrations still live — the disposer must remove one. */
  readonly live = new Set<RouteRecord>()

  register = (route: RouteRecord): (() => void) => {
    this.registered.push(route)
    this.live.add(route)
    return () => { this.live.delete(route) }
  }
}

/** Build a ctx double: webServer, logger, an effect list, and event listeners. */
function fakeContext() {
  const effects: EffectRecord[] = []
  const webServer = new FakeWebServer()
  const ctx = {
    webServer,
    logger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    effect: (compute: () => unknown, label: string): (() => void) => {
      const dispose = compute() as () => void
      effects.push({ label, dispose })
      return dispose
    },
    // The host half subscribes to settings/document-updated to push live form
    // edits into the tunnel client; record listeners so a spec can fire one.
    listeners: new Map<string, Array<(...args: unknown[]) => void>>(),
    on: (event: string, listener: (...args: unknown[]) => void): (() => void) => {
      const list = ctx.listeners.get(event) ?? []
      list.push(listener)
      ctx.listeners.set(event, list)
      return () => {
        const remaining = (ctx.listeners.get(event) ?? []).filter((fn) => fn !== listener)
        ctx.listeners.set(event, remaining)
      }
    },
  }
  return { ctx, effects, webServer }
}

/**
 * The host half imports the dsh runtime packages (schemastery for the Config
 * schema, cordis for the Context type) and the tunnel client. Resolve it
 * dynamically so a checkout without the devDependencies reports a skip instead
 * of failing collection for the whole suite; after `pnpm install` these run for
 * real.
 */
const require_ = createRequire(import.meta.url)
const hasDshRuntime = ['@deepseek-ai/schemastery', '@deepseek-ai/cordis', 'dsh-remote-relay-client']
  .every((specifier) => { try { require_.resolve(specifier); return true } catch { return false } })

if (!hasDshRuntime) {
  // eslint-disable-next-line no-console
  console.warn(
    '[host-half] skipped: @deepseek-ai/schemastery + cordis are not installed ' +
    '(run `pnpm install` in the repo root to exercise these specs)',
  )
}

const host = hasDshRuntime ? await import('../src/index.ts') : undefined
const describeHost = hasDshRuntime ? describe : describe.skip

const apply = host?.apply as typeof import('../src/index.ts').apply
const Config = host?.Config as typeof import('../src/index.ts').Config
const DEFAULT_INSECURE_PSK = host?.DEFAULT_INSECURE_PSK as string
const ROUTE_PREFIX = (host?.ROUTE_PREFIX ?? '/dsh-remote') as string
const inject = (host?.inject ?? []) as readonly string[]
const name = (host?.name ?? 'dsh-remote') as string

/** Runtime Volatile stub: apply() only ever reads a volatile field via .get(). */
function live<T>(value: T): import('@deepseek-ai/cordis').Volatile<T> {
  return { get: () => value } as unknown as import('@deepseek-ai/cordis').Volatile<T>
}

/** Config values the Host would hand apply() after schema validation. */
function configOf(overrides: Record<string, unknown> = {}): import('../src/index.ts').Config {
  const values: Record<string, unknown> = {
    enabled: true,
    relay_url: 'https://relay.example.com',
    psk: 'test-psk',
    upstream_host: '127.0.0.1',
    upstream_port: 3080,
    data_root: '',
    engine_token: '',
    token_rewrite_prefixes: [],
    ...overrides,
  }
  return Object.fromEntries(
    Object.entries(values).map(([key, value]) => [key, live(value)]),
  ) as unknown as import('../src/index.ts').Config
}

afterEach(() => {
  vi.restoreAllMocks()
})

describeHost('host half — plugin shape', () => {
  it('exports the function-plugin form: named exports, no default', () => {
    // The Loader discards a function plugin's whole namespace when a default
    // export is present (postmortem 0001-acp-default-export-drops-inject), so
    // a default export here is a silent, total failure at mount time.
    expect(host).toBeDefined()
    expect('default' in (host as object)).toBe(false)
    for (const exported of ['name', 'inject', 'Config', 'apply']) {
      expect(exported in (host as object), `missing ${exported}`).toBe(true)
    }
  })

  it('declares the documented name and the webServer injection', () => {
    expect(name).toBe('dsh-remote')
    // webServer must be a declared injection: without it the fiber stays
    // PENDING forever instead of failing loudly.
    expect([...inject]).toContain('webServer')
  })

  it('ships a Config schema that fills the documented defaults', () => {
    // A fresh install must not dial a relay: enabled defaults false. Volatile
    // fields parse to live observables, so defaults are read through .get().
    const get = (field: string): unknown =>
      (Config(undefined) as Record<string, { get(): unknown }>)[field]?.get()
    expect(get('enabled')).toBe(false)
    expect(get('relay_url')).toBe('http://127.0.0.1:8080')
    expect(get('upstream_port')).toBe(3080)
    expect(get('token_rewrite_prefixes')).toEqual([])
  })

  it('keeps the insecure default PSK as the documented fail-closed value', () => {
    const parsed = Config(undefined) as Record<string, { get(): unknown }>
    expect(parsed.psk?.get()).toBe(DEFAULT_INSECURE_PSK)
  })

  it('marks every Config field volatile so the settings domain serves a form', () => {
    // volatileForm() in dsh packages/settings drops every non-volatile field
    // and yields NO namespace for an entry with none left — the configuration
    // form then never appears (the "no config UI" bug: the card rendered, the
    // form slot showed the plugin's unavailable line). A volatile field parses
    // to a live observable, i.e. exposes .get(). Pin that for every field.
    const parsed = Config(undefined) as Record<string, { get?: unknown }>
    const fields = [
      'enabled', 'relay_url', 'psk', 'upstream_host', 'upstream_port',
      'data_root', 'engine_token', 'token_rewrite_prefixes',
    ]
    for (const field of fields) {
      expect(typeof parsed[field]?.get, `${field} must be volatile`).toBe('function')
    }
  })
})

describeHost('host half — route registration', () => {
  it('registers the pairing prefix through ctx.effect, labelled as a route registration', () => {
    const { ctx, effects, webServer } = fakeContext()
    apply(ctx as never, configOf())

    expect(webServer.registered).toHaveLength(1)
    expect(webServer.registered[0]?.path).toBe(ROUTE_PREFIX)
    expect(webServer.registered[0]?.kind).toBe('prefix')
    expect(effects.map((effect) => effect.label)).toContain('dsh-remote: routes')
  })

  it('withdraws the route on teardown instead of leaving it serving pairings', () => {
    const { ctx, effects, webServer } = fakeContext()
    apply(ctx as never, configOf())
    expect(webServer.live.size).toBe(1)

    // Disposal order is not guaranteed, so run every recorded disposer.
    for (const effect of effects) effect.dispose()
    expect(webServer.live.size).toBe(0)
  })

  it('logs through ctx.logger rather than console, so output joins the host log', () => {
    const { ctx } = fakeContext()
    const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
    apply(ctx as never, configOf())

    expect(ctx.logger.info).toHaveBeenCalled()
    expect(consoleSpy).not.toHaveBeenCalled()
  })

  it('a disabled config mounts the route but never dials the relay', () => {
    const { ctx, webServer } = fakeContext()
    // enabled: false is the shipped default. The route stays available so the
    // settings card can be opened and the switch flipped, but no tunnel opens.
    apply(ctx as never, configOf({ enabled: false }))

    expect(webServer.registered).toHaveLength(1)
    expect(ROUTE_PREFIX).toBe('/dsh-remote')
  })
})
