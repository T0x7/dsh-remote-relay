import crypto from 'node:crypto';
import { timingSafeEqual } from 'node:crypto';
import type { WebSocket } from 'ws';
import { SessionStore, type StoredSession } from './store.js';

/**
 * In-memory view of a pairing. dshSocket and disconnectedAt are never
 * persisted together: a live socket means the tunnel is bound; a tombstone
 * (socket gone, disconnectedAt set) keeps the sessionSecret alive for the
 * grace window so a reconnect re-binds the SAME secret and existing phone
 * cookies keep working. Before v3.119 a dsh disconnect hard-revoked every
 * session, so the advertised 30-day cookie really lasted only as long as
 * the tunnel WebSocket never dropped.
 *
 * v3.141：删除 v3.106 加入的 `mode` 字段——远程控制单模式化后，配对等价于
 * full；16 PRIVILEGED 方法的拦截由 dsh Host fence 独立完成（与 mode 解耦）。
 * 详见 docs/decisions/2026-09-07-remote-single-mode.md。
 */
export interface ActiveSession {
  sessionId: string;
  pairingToken: string;
  sessionSecret: string;
  createdAt: number;
  expiresAt: number;
  dshSocket?: WebSocket;
  disconnectedAt?: number;
  /** Transient (never persisted): true when registerSession re-bound an
   * existing pairing's secret instead of minting a new one. */
  reusedSecret?: boolean;
  /** Transient (never persisted): last gate-pass timestamp (device activity
   * beacon for /__devices online detection). */
  lastSeen?: number;
  /** v3.128.4：最近一次过闸请求的客户端公网 IP（transient；trustProxy 解
   * 析后的 req.ip）。/__devices 带出供 Mac 卡片展示「谁连着」。 */
  lastSeenIp?: string;
  /** Transient (never persisted): first successful __pair timestamp — 有设备
   * 真正扫过码。插件侧据此决定「过期未扫的二维码要不要续新码」（有设备
   * 在用时绝不轮换，防误踢）。 */
  pairedAt?: number;
  /** First real device connection (gate pass or events WS upgrade with the
   * session cookie). v3.128.2 语义（用户拍板）：配对 URL「无人在线时可再次
   * 使用」——在线拦截 + 着陆轮换密钥维持同刻单客户端；connectedAt 仅作
   * 首连可观测时间戳，不再有 token 消费态。 */
  connectedAt?: number;
  /** v3.128.2.1：轮换前一个 sessionSecret（transient）。着陆轮换后旧 cookie
   * 在 PREVIOUS_SECRET_GRACE_MS 内仍过闸——浏览器/扫码器在「着陆→跟 302
   * 访问 /」链路上可能并行携带旧 cookie（实测 Android Firefox 着陆成功同
   * 秒被闸门拒），宽限窗自愈一切轮换竞态；窗口一过旧设备即被顶下线。 */
  previousSecret?: string;
  previousSecretAt?: number;
  // v3.161：per-session 请求限速（transient，从不落盘）。60 req/min 默认——
  // 挡住配对设备的自动化滥用（已配对 = 走 trusted-host 闸白名单，无限速则
  // SPA 任意频次刷插件敏感路径），同时首屏资源脉冲
  // + ticker 突发远低于 60/min。
  requestWindowMs?: number;
  requestTimestamps?: number[];
}

/** 旧密钥宽限窗：轮换后上一个 cookie 的存活时长。 */
export const PREVIOUS_SECRET_GRACE_MS = 90 * 1000;

/**
 * How much authority a presented secret carries.
 *
 * v3.282: the grace window used to return the session itself, so a device that
 * had just been replaced kept FULL read/write access to the engine for 90
 * seconds — it could still run commands and read every conversation, long
 * after the UI said it had been kicked. The window exists to heal a browser
 * race (the landing request and the redirected request carrying different
 * cookies), which needs the landing page and nothing more. Hence `landing`.
 */
export type SessionAuthLevel = 'full' | 'landing';

/** What a presented secret resolved to, and how much it may do. */
export interface SecretMatch {
  session: ActiveSession;
  level: SessionAuthLevel;
}

/**
 * Digest form of a secret — the only form kept for lookup.
 *
 * WHY: the data plane's primary credential was compared with `===` in a loop
 * over every session, while the PSK right next to it used timingSafeEqual. A
 * secret is a bearer credential that turns up in proxy logs, so the compare
 * that guards it should not leak its prefix through timing.
 */
function secretDigest(secret: string): string {
  return crypto.createHash('sha256').update(secret).digest('hex');
}

/** Constant-time equality over fixed-length digests. */
function digestEquals(a: string, b: string): boolean {
  const left = Buffer.from(secretDigest(a));
  const right = Buffer.from(secretDigest(b));
  return timingSafeEqual(left, right);
}

export interface SessionManagerOptions {
  /** Re-bind window after the dsh tunnel drops (ms). Default 10 min. */
  graceMs?: number;
  /** Absolute cookie lifetime cap anchored at first pairing (ms). Default 30 days. */
  maxAgeMs?: number;
  store?: SessionStore;
}

export class SessionManager {
  private sessions: Map<string, ActiveSession> = new Map();
  private tokenMap: Map<string, string> = new Map();
  /**
   * Digest index for the data plane's primary credential. The plaintext
   * sessionSecret still lives on the session (the engine and the store need
   * it), but nothing LOOKS UP by it: a presented value is hashed and matched
   * here, so a request costs one hash plus one map probe instead of a linear
   * scan whose exit point depends on where the match sits.
   */
  private secretIndex: Map<string, string> = new Map();
  private graceMs: number;
  private maxAgeMs: number;
  private store?: SessionStore;
  /** Tunnel-level engine shared secret (latest session.register payload).
   * Injected as X-App-Token on relayed requests; in-memory only — every
   * engine (re)boot re-registers and rotates it. */
  private engineToken = '';

  constructor(options: SessionManagerOptions = {}) {
    this.graceMs = options.graceMs ?? 10 * 60 * 1000;
    this.maxAgeMs = options.maxAgeMs ?? 30 * 24 * 60 * 60 * 1000;
    this.store = options.store;
    this.restore();
  }

  /** Revive persisted pairings after a relay restart; drop stale rows. */
  private restore(): void {
    if (!this.store) return;
    const now = Date.now();
    for (const record of this.store.load()) {
      if (now > record.createdAt + this.maxAgeMs) {
        this.store.remove(record.sessionId);
        continue;
      }
      if (record.disconnectedAt != null && now > record.disconnectedAt + this.graceMs) {
        this.store.remove(record.sessionId);
        continue;
      }
      const session: ActiveSession = {
        ...record,
        disconnectedAt: record.disconnectedAt ?? undefined,
        connectedAt: record.connectedAt ?? undefined,
      };
      this.sessions.set(session.sessionId, session);
      this.tokenMap.set(session.pairingToken, session.sessionId);
      this.secretIndex.set(secretDigest(session.sessionSecret), session.sessionId);
    }
  }

  public registerSession(
    sessionId: string,
    pairingToken: string,
    ttlSeconds: number,
    dshSocket: WebSocket,
    engineToken?: string,
  ): ActiveSession {
    // Tunnel-level refresh before the reuse dance: every (re)registration
    // carries the engine's current DSH_BIND_TOKEN (rotates per boot).
    if (engineToken) this.engineToken = engineToken;
    const now = Date.now();
    const existing = this.sessions.get(sessionId);

    // Re-register of a known pairing (tunnel reconnect or relay restart):
    // reuse the original sessionSecret so cookies already on phones stay
    // valid. A different pairingToken for the same sessionId is not a flow
    // the plugin produces (each QR gets a fresh sessionId) — treat it as a
    // NEW pairing and rotate the secret.
    const reuse =
      existing &&
      existing.pairingToken === pairingToken &&
      !this.isExpired(existing, now);
    const sessionSecret = reuse ? existing.sessionSecret : crypto.randomBytes(32).toString('hex');

    this.revokeSession(sessionId, 're-registered');

    const session: ActiveSession = {
      sessionId,
      pairingToken,
      sessionSecret,
      createdAt: reuse ? existing.createdAt : now,
      expiresAt: now + ttlSeconds * 1000,
      dshSocket,
      disconnectedAt: undefined,
      reusedSecret: Boolean(reuse),
      // v3.128.1：复用配对时连接态必须随迁——否则重注册会把已消费 token
      // 当成「未连接」复活
      connectedAt: reuse ? existing.connectedAt : undefined,
    };
    this.sessions.set(sessionId, session);
    this.tokenMap.set(pairingToken, sessionId);
    this.secretIndex.set(secretDigest(sessionSecret), sessionId);
    this.store?.upsert(this.toStored(session));
    return session;
  }

  /** Latest engine shared secret delivered over the tunnel (may predate a
   * brief tunnel drop — the SSH data path is independent and the engine only
   * rotates tokens across boots, which always re-register). */
  public get currentEngineToken(): string {
    return this.engineToken;
  }

  public getSession(sessionId: string): ActiveSession | undefined {
    const session = this.sessions.get(sessionId);
    if (!session || !this.isExpired(session, Date.now())) return session;
    this.revokeSession(sessionId, 'session-expired');
    return undefined;
  }

  public getSessionByToken(pairingToken: string): ActiveSession | undefined {
    const sessionId = this.tokenMap.get(pairingToken);
    if (!sessionId) return undefined;
    const session = this.sessions.get(sessionId);
    if (!session) {
      this.tokenMap.delete(pairingToken);
      return undefined;
    }
    // v3.128.2：二维码窗口（expiresAt）不再连坐撤销整个会话——URL 的生死
    // 由会话生命周期（maxAge/grace/显式撤销）决定，窗口只影响插件卡片展示。
    // 此前这里 revokeSession 会把在线设备的 cookie 一起杀掉。
    return session;
  }

  /**
   * Resolve a presented secret to its session and the authority it carries.
   *
   * v3.282: two changes at once. The lookup is now a digest probe (constant
   * time, O(1)), and a hit on the PREVIOUS secret returns `landing` rather
   * than the session itself — a replaced device keeps enough access to finish
   * the redirect that carried it, and nothing else. The WS bridge already
   * re-checked the current secret on connect; the HTTP data plane now honours
   * the same rule instead of waving a stale cookie through for 90 seconds of
   * full control.
   */
public authenticateSecret(sessionSecret: string): SecretMatch | undefined {
    const now = Date.now();
    const sessionId = this.secretIndex.get(secretDigest(sessionSecret));
    if (sessionId === undefined) return undefined;
    const session = this.sessions.get(sessionId);
    if (!session) return undefined;
    if (this.isExpired(session, now)) {
      this.revokeSession(sessionId, 'session-expired');
      return undefined;
    }
    // A digest can only be in the index if it was one of this session's two
    // secrets; decide which by a constant-time compare against each.
    if (digestEquals(session.sessionSecret, sessionSecret)) {
      return { session, level: 'full' };
    }
    if (
      session.previousSecret !== undefined &&
      digestEquals(session.previousSecret, sessionSecret) &&
      session.previousSecretAt !== undefined &&
      now - session.previousSecretAt < PREVIOUS_SECRET_GRACE_MS
    ) {
      return { session, level: 'landing' };
    }
    return undefined;
  }

  public getSessionBySecret(sessionSecret: string): ActiveSession | undefined {
    return this.authenticateSecret(sessionSecret)?.session;
  }

  public revokeSession(sessionId: string, _reason?: string): void {
    const session = this.sessions.get(sessionId);
    if (!session) return;
    this.tokenMap.delete(session.pairingToken);
    // v3.282:索引必须跟着撤销走，否则被吊销的凭证摘要仍能命中一个空壳。
    this.secretIndex.delete(secretDigest(session.sessionSecret));
    if (session.previousSecret !== undefined) {
      this.secretIndex.delete(secretDigest(session.previousSecret));
    }
    this.sessions.delete(sessionId);
    this.store?.remove(sessionId);
  }

  /**
   * dsh tunnel dropped: tombstone the sessions instead of revoking them, so a
   * quick reconnect (relay restart, network blip, dsh engine restart) re-binds
   * the same secrets. After the grace window they expire naturally on next
   * access — the fail-safe direction (cookie stops working) is preserved.
   */
  public clearDsh(dshSocket: WebSocket): void {
    const now = Date.now();
    for (const [sessionId, session] of this.sessions.entries()) {
      if (session.dshSocket === dshSocket) {
        delete session.dshSocket;
        session.disconnectedAt = now;
        this.store?.upsert(this.toStored(session));
        void sessionId;
      }
    }
  }

  /** Expired = past the absolute cookie cap, or tombstoned beyond grace. */
  private isExpired(session: ActiveSession, now: number): boolean {
    if (now > session.createdAt + this.maxAgeMs) return true;
    if (session.disconnectedAt != null && now > session.disconnectedAt + this.graceMs) return true;
    return false;
  }

  private toStored(session: ActiveSession): StoredSession {
    return {
      sessionId: session.sessionId,
      pairingToken: session.pairingToken,
      sessionSecret: session.sessionSecret,
      createdAt: session.createdAt,
      expiresAt: session.expiresAt,
      disconnectedAt: session.disconnectedAt ?? null,
      connectedAt: session.connectedAt ?? null,
    };
  }

  /** 设备活跃信标（transient，不落盘）：任意过闸请求由 gate hook 打点。
   * /__devices 据此 + 活跃 WS 计数判定设备是否在线；ip 为该次请求的
   * 客户端公网 IP（trustProxy 解析后），供卡片展示。 */
  public markSeen(sessionId: string, ip?: string): void {
    const session = this.sessions.get(sessionId);
    if (session) {
      session.lastSeen = Date.now();
      if (ip !== undefined && ip !== '') session.lastSeenIp = ip;
    }
  }

  /** v3.161：per-session 请求计数（sliding-window 1 min）。返回当前窗口
   * 已计次数（同时把这次计入）——onRequest 闸拿这个值做 60/min 限速。
   * 单数组 + 指针，O(1) push/evict，平均内存 ~120B/session。 */
  public markRequest(sessionId: string, now: number = Date.now()): number {
    const session = this.sessions.get(sessionId);
    if (!session) return 0;
    const window = session.requestWindowMs ?? 60_000;
    const cutoff = now - window;
    let ts = session.requestTimestamps;
    if (!ts) {
      ts = [];
      session.requestTimestamps = ts;
    }
    // evict 过期（数组可能保留若干 stale，但通常很短）
    while (ts.length > 0 && ts[0]! <= cutoff) ts.shift();
    ts.push(now);
    return ts.length;
  }

  /** 把已计数的窗口清零（在 429 阻断路径上让客户端能立刻重试小窗口请求）。 */
  public resetRequestCount(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (session?.requestTimestamps) session.requestTimestamps.length = 0;
  }

  /** 全部会话快照（/__devices 设备列表数据源）。 */
  public listSessions(): ActiveSession[] {
    return [...this.sessions.values()];
  }

  /** v3.128.2 语义（用户拍板）：配对 URL「无人在线时可再次使用」。着陆
   * 放行即轮换 sessionSecret 并落盘——旧设备 cookie 即刻失效，维持「同刻
   * 仅 1 台」：最后成功打开 URL 的设备独占入口（其后再有人打开会再次轮
   * 换，逐次顶替）。 */
  public rotateSessionSecret(sessionId: string): string | undefined {
    const session = this.sessions.get(sessionId);
    if (!session) return undefined;
    session.previousSecret = session.sessionSecret;
    // 旧 secret 降级为「仅着陆」，但仍需留在索引里：宽限期就是靠它自愈
    // 着陆→302 链路上的 cookie 竞态，代价是权限等级而不是可否通过。
    this.secretIndex.set(secretDigest(session.previousSecret), session.sessionId);
    session.previousSecretAt = Date.now();
    session.sessionSecret = crypto.randomBytes(32).toString('hex');
    this.secretIndex.set(secretDigest(session.sessionSecret), session.sessionId);
    this.store?.upsert(this.toStored(session));
    return session.sessionSecret;
  }

  /** v3.204 单浏览器独占（按引擎，用户拍板 2026-09-15）：同一引擎 socket
   * 上的全部 pairing 一起换 sessionSecret——着陆方拿新 secret 颁 cookie，
   * 同引擎其它 pairing 的已配对设备进入 PREVIOUS_SECRET_GRACE_MS（90s）
   * 宽限，宽限一过即被顶下线。粒度=引擎 socket：多引擎实例（App/dev）各
   * 自独立互不踢。socket 为 undefined（引擎离线但 10 分钟宽限窗内着陆）
   * 时只轮换目标会话。
   * 返回目标轮换后的新 secret、轮换会话数、被顶替的旧 secret 列表
   * （v3.205：调用方据此 close(4001) 掐断旧设备的事件流，实时踢人）；
   * 目标不存在返回 undefined（调用方回 401 卡）。 */
  public rotateAllOnSocket(socket: WebSocket | undefined, targetSessionId: string): { secret: string; rotated: number; evictedSecrets: string[] } | undefined {
    const target = this.sessions.get(targetSessionId);
    if (!target) return undefined;
    const now = Date.now();
    const evictedSecrets: string[] = [];
    let rotated = 0;
    for (const session of this.sessions.values()) {
      if (socket !== undefined && session.dshSocket !== socket) continue;
      if (this.isExpired(session, now)) continue;
      if (this.rotateSessionSecret(session.sessionId) !== undefined) {
        rotated++;
        // 刚轮换完，previousSecret 即被顶替出去的旧 secret
        if (session.previousSecret !== undefined) evictedSecrets.push(session.previousSecret);
      }
    }
    const secret = this.sessions.get(targetSessionId)?.sessionSecret;
    return secret !== undefined ? { secret, rotated, evictedSecrets } : undefined;
  }

  /** v3.128.2：设备真正连接（带 cookie 过闸 / events WS upgrade）的首次
   * 打点，幂等。仅记录首连时间戳（可观测），无 token 语义。 */
  public markConnected(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (!session || session.connectedAt != null) return;
    session.connectedAt = Date.now();
    this.store?.upsert(this.toStored(session));
  }
}
