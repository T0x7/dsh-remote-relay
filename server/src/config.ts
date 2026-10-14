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

import { randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const DEFAULT_INSECURE_PSK = 'dsh-remote-relay-default-insecure-psk';

/**
 * PSK 最短长度（字符）。
 *
 * 32 起步是运维拍板的硬下限：短 PSK 可以被暴力猜，而 PSK 是这套体系里**唯一**
 * 能铸造任意 session 的根秘密。自动生成长度取 64（32 字节 → hex），比下限宽裕
 * 一倍，够用到下一次轮换。
 */
export const MIN_PSK_LENGTH = 32;

/** 自动生成的 PSK 落在数据目录里（不是 `.env`）。 */
export const GENERATED_PSK_FILENAME = 'generated-psk';

/**
 * 生成一把强随机 PSK：32 字节 → 64 个 hex 字符。
 *
 * 用 `crypto.randomBytes` 而不是 `Math.random`：这是根秘密的种子源，
 * 「够随机」不是可选项。
 */
export function generatePsk(): string {
  return randomBytes(32).toString('hex');
}

export type PskSource = 'env' | 'persisted' | 'generated';

export interface PskResolution {
  psk: string;
  source: PskSource;
  /** 持久化位置（`persisted` / `generated`），操作者照着它把值填进 dsh。 */
  path: string;
}

/**
 * 决定本次启动用哪把 PSK。
 *
 * 顺序：`env.RELAY_PSK`（且不是那个公开的不安全默认值）→ 上次自动生成并落盘的值
 * → **现生成一把并落盘**。
 *
 * **为什么自动生成而不是直接拒启。** 之前缺 PSK 的表现是「refusing to start」，
 * 对一个第一次自部署的人来说是：装完了、起不来了、错误信息告诉他去设一个变量，
 * 但**没人告诉他该设成什么值**。生成 + 落盘 + 打印路径，把「不知道填什么」变成
 * 「复制这个文件的内容」，是一步的事。
 *
 * **为什么不回写 `.env`。** 部署形态是 `env_file: .env`（docker compose 在
 * **宿主机**上读它），容器里根本没有这个文件——写不进去，写了也会在容器重建时
 * 蒸发。数据卷（`/app/data`）才是真正跨容器重建存活的地方。
 *
 * 注入 read/write/generate 三个缝是为了测试：真去写磁盘会让守门用例互相污染。
 */
export function resolvePsk(options: {
  envPsk?: string;
  dataDir: string;
  readFile?: (path: string) => string | null;
  writeFile?: (path: string, content: string) => void;
  generate?: () => string;
}): PskResolution {
  const readFile = options.readFile
    ?? ((p: string) => {
      try {
        return fs.readFileSync(p, 'utf8').trim() || null;
      } catch {
        return null;
      }
    });
  const writeFile = options.writeFile
    ?? ((p: string, content: string) => {
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, content, { mode: 0o600 });
    });
  const generate = options.generate ?? generatePsk;

  const fromEnv = options.envPsk?.trim();
  const target = path.join(options.dataDir, GENERATED_PSK_FILENAME);
  // 明确设成那个公开默认值，等同于没设——按没设处理，但 reason 留给调用方播报。
  if (fromEnv && fromEnv !== DEFAULT_INSECURE_PSK) {
    return { psk: fromEnv, source: 'env', path: target };
  }
  const persisted = readFile(target);
  if (persisted && persisted.length >= MIN_PSK_LENGTH) {
    return { psk: persisted, source: 'persisted', path: target };
  }
  const psk = generate();
  writeFile(target, psk);
  return { psk, source: 'generated', path: target };
}


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
    problems.push('RELAY_PSK is unset or the documented insecure default — unset it to have one generated, or set a strong random value (openssl rand -hex 32)');
  } else if (config.psk.length < MIN_PSK_LENGTH) {
    // 正常启动路径下 resolvePsk 已经保证 ≥32；这条是**最后一道防线**，防的是
    // 有人绕过 resolvePsk 直接构造 config 调到这里（buildServer 直调、脚本）。
    problems.push(`RELAY_PSK is ${config.psk.length} chars, below the ${MIN_PSK_LENGTH}-char minimum — unset it to have one generated, or set openssl rand -hex 32`);
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
