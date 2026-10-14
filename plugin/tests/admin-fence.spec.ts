/**
 * v3.282 engine-admin boundary — the plugin half.
 *
 * WHY this file exists separately from host-half.spec.ts: that suite asserts
 * the route is REGISTERED and torn down, and nothing else. It never invokes
 * the handler, which is exactly the seam where this bug lived: the handler
 * answered `POST /dsh-remote/session` to whoever asked, and registration tests
 * stayed green the whole time.
 *
 * The contract under test:
 *   - a request the tunnel forwarded from a paired device carries
 *     `x-dsh-remote-tunnel`, and must be refused for mint / revoke / tunnel
 *     control — those are the host's own admin gestures;
 *   - the read half of the same prefix must keep answering, because the paired
 *     app polls status and renews its credential through it;
 *   - the same routes still work for the admin page on the host, which is the
 *     only caller that matters for them.
 */
import { afterAll, describe, expect, it } from 'vitest';
import { createRequire } from 'node:module';

const require_ = createRequire(import.meta.url);
const hasDshRuntime = ['@deepseek-ai/schemastery', '@deepseek-ai/cordis', 'dsh-remote-relay-client']
  .every((specifier) => { try { require_.resolve(specifier); return true; } catch { return false; } });

if (!hasDshRuntime) {
  // eslint-disable-next-line no-console
  console.warn('[admin-fence] skipped: run `pnpm install` in the repo root to exercise this spec');
}

const describeHost = hasDshRuntime ? describe : describe.skip;
const host = hasDshRuntime ? await import('../src/index.ts') : undefined;
const apply = host?.apply as typeof import('../src/index.ts').apply;
const Config = host?.Config as typeof import('../src/index.ts').Config;

/** Runtime Volatile stub: apply() only ever reads a volatile field via .get(). */
function live<T>(value: T): import('@deepseek-ai/cordis').Volatile<T> {
  return { get: () => value } as unknown as import('@deepseek-ai/cordis').Volatile<T>;
}

/**
 * Config the Host would hand apply(). relay_url points at a closed port so the
 * read-half cases answer without touching the network — the boundary under
 * test is decided before any of that anyway.
 */
function configOf(overrides: Record<string, unknown> = {}): import('../src/index.ts').Config {
  const values: Record<string, unknown> = {
    enabled: true,
    relay_url: 'http://127.0.0.1:1',
    psk: 'test-psk',
    upstream_host: '127.0.0.1',
    upstream_port: 3080,
    data_root: '',
    engine_token: '',
    token_rewrite_prefixes: [],
    ...overrides,
  };
  return Object.fromEntries(
    Object.entries(values).map(([key, value]) => [key, live(value)]),
  ) as unknown as import('../src/index.ts').Config;
}

/** Mount the plugin against a ctx double and hand back its route handler. */
function mountPlugin(configOverrides: Record<string, unknown> = {}): {
  handler: (req: unknown, res: unknown) => Promise<void>;
  dispose: () => void;
} {
  const registered: Array<{ path: string; handler: unknown }> = [];
  const disposers: Array<() => void> = [];
  const ctx = {
    webServer: {
      register: (route: { path: string; handler: unknown }) => {
        registered.push(route);
        return () => { /* keep the record so a disposed route can still be probed */ };
      },
    },
    logger: { info: () => {}, warn: () => {}, error: () => {} },
    effect: (compute: () => unknown) => { disposers.push(compute() as () => void); },
    on: () => () => {},
  } as unknown as import('@deepseek-ai/cordis').Context;
  apply(ctx, configOf(configOverrides));
  return {
    handler: registered[0]!.handler as (req: unknown, res: unknown) => Promise<void>,
    dispose: () => { for (const dispose of disposers) dispose(); },
  };
}

/** A minimal IncomingMessage double — the handler reads method/url/headers. */
function request(method: string, url: string, headers: Record<string, string> = {}): unknown {
  const req = { method, url, headers, on: () => req };
  return req;
}

/** A ServerResponse double that records what the handler answered. */
function response(): { res: unknown; status: () => number; body: () => string } {
  const chunks: string[] = [];
  let statusCode = 200;
  const res = {
    setHeader: () => {},
    end: (body?: string) => { if (body !== undefined) chunks.push(body); },
  };
  return {
    res: new Proxy(res, {
      set(target, key, value) {
        if (key === 'statusCode') statusCode = value as number;
        (target as Record<string, unknown>)[key as string] = value;
        return true;
      },
    }),
    status: () => statusCode,
    body: () => chunks.join(''),
  };
}

/** What the tunnel stamps on a request it forwarded from a paired device. */
const TUNNEL_BORN: Record<string, string> = { 'x-dsh-remote-tunnel': '1' };

describeHost('engine-admin boundary: a paired device may not drive host admin', () => {
  const mounted = mountPlugin();
  afterAll(() => mounted.dispose());

  it('refuses POST /session (mint a pairing) for a tunnel-borne request', async () => {
    const res = response();
    await mounted.handler(request('POST', '/dsh-remote/session', TUNNEL_BORN), res.res);
    expect(res.status()).toBe(403);
    expect(JSON.parse(res.body()).error).toMatch(/not reachable from a paired device/);
  });

  it('refuses DELETE /session (revoke every pairing) for a tunnel-borne request', async () => {
    const res = response();
    await mounted.handler(request('DELETE', '/dsh-remote/session', TUNNEL_BORN), res.res);
    expect(res.status()).toBe(403);
  });

  it('refuses POST /tunnel (cut the tunnel) for a tunnel-borne request', async () => {
    const res = response();
    await mounted.handler(request('POST', '/dsh-remote/tunnel', TUNNEL_BORN), res.res);
    expect(res.status()).toBe(403);
  });

  it('still serves GET /session to a paired device (the app polls status)', async () => {
    const res = response();
    await mounted.handler(request('GET', '/dsh-remote/session', TUNNEL_BORN), res.res);
    expect(res.status()).not.toBe(403);
  });

  it('still serves GET /url-session to a paired device (the app renews its credential)', async () => {
    const res = response();
    await mounted.handler(request('GET', '/dsh-remote/url-session', TUNNEL_BORN), res.res);
    expect(res.status()).not.toBe(403);
  });

  it('serves the same admin routes to the host admin page (no marker = local)', async () => {
    const res = response();
    await mounted.handler(request('POST', '/dsh-remote/session'), res.res);
    // Not 403: the host is the one caller these routes exist for. (A live
    // pairing is minted, which is why the read half above answers.)
    expect(res.status()).not.toBe(403);
  });
});