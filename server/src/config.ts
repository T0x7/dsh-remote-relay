/**
 * Centralised env parsing + the fail-closed production boot guard.
 *
 * Why a boot guard: the relay is the public edge of the remote-control trust
 * model. Two historical foot-guns must be impossible to ship silently —
 *
 * 1. running on the documented insecure default PSK (anyone who knows it can
 *    open the /ws/dsh tunnel, self-register a pairing and mint a cookie), and
 * 2. proxying without a pinned public Host. @fastify/http-proxy rewrites the
 *    Host header to the upstream authority (`headers.host = url.host`, i.e.
 *    `127.0.0.1:3080`), which presents every relayed request to dsh as
 *    loopback — unlocking the 16 PRIVILEGED methods the capability matrix
 *    promises are loopback-only. RELAY_PUBLIC_HOST is the authority dsh
 *    should see instead (it must be listed in dsh's --trusted-host).
 */

import path from 'node:path';

export const DEFAULT_INSECURE_PSK = 'dsh-remote-relay-default-insecure-psk';

/**
 * RELAY_PUBLIC_HOST must be a bare authority (`host` or `host:port`) in
 * canonical form — the same spelling dsh's assertTrustedAuthority accepts,
 * so the two configs can be copy-paste identical. Anything a URL parse would
 * silently rewrite (percent-encoding, embedded path/userinfo, `:80` default
 * port) is rejected loudly instead of authorising a different grant than the
 * operator wrote.
 */
export function isValidAuthority(value: string): boolean {
  if (!value || /[\s%/]/.test(value)) return false;
  try {
    const url = new URL(`http://${value}`);
    if (url.pathname !== '/' || url.username !== '' || url.password !== '' || url.search !== '' || url.hash !== '') {
      return false;
    }
    const canonical = url.port === '' ? url.hostname : `${url.hostname}:${url.port}`;
    return canonical === value.toLowerCase();
  } catch {
    return false;
  }
}

export interface RelayConfig {
  port: number;
  host: string;
  psk: string;
  /** Authority dsh should see on relayed requests (== dsh --trusted-host entry). */
  publicHost: string;
  upstream: string;
  /** CSV of proxy IPs/CIDRs trusted for X-Forwarded-For (the nginx hop). */
  trustProxy: string;
  dbPath: string;
  stateDbPath: string;
  /** How long a paired session survives its dsh tunnel dropping (re-bind window). */
  sessionGraceSec: number;
  /** Absolute cap on a pairing's cookie lifetime, anchored at first pairing. */
  sessionMaxAgeSec: number;
  alertWebhookUrl: string;
  /**
   * Extra absolute WebSocket paths (beyond dsh core's /api/events.* and
   * /api/remote.mux) whose upgrades the relay bridges to the engine —
   * e.g. plugin-owned realtime streams. Comma-separated CSV via
   * RELAY_WS_BRIDGE_PATHS; default none. Each entry must start with '/'.
   */
  wsBridgePaths: string[];
}

/** Parse the RELAY_WS_BRIDGE_PATHS CSV into a validated absolute-path list. */
export function parseWsBridgePaths(csv: string | undefined): string[] {
  if (!csv) return [];
  return csv
    .split(',')
    .map((p) => p.trim())
    .filter((p) => p.length > 0 && p.startsWith('/'));
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): RelayConfig {
  return {
    port: Number(env.PORT) || 8080,
    host: env.HOST || '0.0.0.0',
    psk: env.RELAY_PSK || DEFAULT_INSECURE_PSK,
    publicHost: env.RELAY_PUBLIC_HOST || '',
    upstream: env.DSH_UPSTREAM || 'http://127.0.0.1:3080',
    trustProxy: env.RELAY_TRUST_PROXY || '127.0.0.1,::1',
    dbPath: env.AUDIT_DB_PATH || path.join(process.cwd(), 'data', 'relay-audit.db'),
    stateDbPath: env.STATE_DB_PATH || path.join(process.cwd(), 'data', 'relay-state.db'),
    sessionGraceSec: Number(env.RELAY_SESSION_GRACE_SEC) || 600,
    sessionMaxAgeSec: Number(env.RELAY_SESSION_MAX_AGE_SEC) || 30 * 24 * 60 * 60,
    alertWebhookUrl: env.RELAY_ALERT_WEBHOOK_URL || '',
    wsBridgePaths: parseWsBridgePaths(env.RELAY_WS_BRIDGE_PATHS),
  };
}

/**
 * Throw (with an actionable message) when a production boot would run on an
 * unsafe configuration. Tests and dev servers construct SessionManager /
 * buildServer directly with explicit values and never pass through here.
 */
export function assertProductionConfig(config: RelayConfig): void {
  const problems: string[] = [];
  if (!config.psk || config.psk === DEFAULT_INSECURE_PSK) {
    problems.push('RELAY_PSK is unset or the documented insecure default — set a strong random value (openssl rand -hex 32)');
  }
  if (!config.publicHost) {
    problems.push('RELAY_PUBLIC_HOST is unset — without it the proxy presents requests to dsh as loopback (Host: 127.0.0.1:3080), which unlocks the 16 PRIVILEGED methods remotely');
  } else if (!isValidAuthority(config.publicHost)) {
    problems.push(`RELAY_PUBLIC_HOST=${JSON.stringify(config.publicHost)} is not a canonical bare authority (host or host:port, matching dsh --trusted-host)`);
  }
  if (problems.length > 0) {
    throw new Error(`refusing to start — unsafe relay configuration:\n  - ${problems.join('\n  - ')}`);
  }
}
