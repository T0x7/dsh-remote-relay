/**
 * dsh-remote-relay client — dials the relay's `/ws/dsh` tunnel, registers
 * pairings, and fulfils the relay's http.req / ws.upgrade data-plane frames
 * against the local dsh engine (127.0.0.1:<upstreamPort>).
 *
 * Config resolution order (per access, so updateConfig() and env changes
 * take effect live): constructor config field > env > default.
 *   publicHost     config.publicHost      > RELAY_PUBLIC_HOST  > relayUrl authority
 *   upstreamPort   config.upstreamPort    > DSH_BIND_PORT      > 3080
 *   upstreamHost   config.upstreamHost    > DSH_BIND_HOST      > 127.0.0.1
 *   engineToken    config.engineToken     > DSH_BIND_TOKEN     > '' (skips engine-cookie mint)
 *   dataRoot       config.dataRoot        > DSH_REMOTE_DATA_ROOT > ~/.dsh-remote-relay
 */

import WebSocket from 'ws';
import crypto, { createHash, createHmac } from 'node:crypto';
import { readFileSync, writeFileSync, chmodSync, mkdirSync, renameSync } from 'node:fs';
import { homedir, hostname, networkInterfaces } from 'node:os';
import { join, dirname } from 'node:path';

export interface RemoteRelayConfig {
  relayUrl: string;
  psk: string;
  enabled: boolean;
  /** Authority the local engine should see on bridged requests (== dsh
   * --trusted-host entry). Falls back to RELAY_PUBLIC_HOST, then to the
   * relayUrl's own authority — which is the right default for a
   * phone-reaches-relay-host deployment. */
  publicHost?: string;
  /** Local engine bind. Defaults: 127.0.0.1:3080 (env DSH_BIND_HOST / DSH_BIND_PORT). */
  upstreamHost?: string;
  upstreamPort?: number;
  /** Engine X-App-Token (dsh lockdown); falls back to DSH_BIND_TOKEN. When
   * empty the client skips the engine-cookie mint entirely (generic upstreams). */
  engineToken?: string;
  /** Persistence dir for pairings + install-id. Falls back to
   * DSH_REMOTE_DATA_ROOT, then ~/.dsh-remote-relay. */
  dataRoot?: string;
  /** WS path prefixes whose ?token= query is rewritten to the engine token
   * when bridged (paths a public browser cannot know the real token for).
   * Defaults to the realtime path of whichever dsh plugin needs it; override
   * (or set [] to disable) when the engine serves no such route. */
  tokenRewritePrefixes?: string[];
}

export interface RemoteSessionInfo {
  sessionId: string;
  pairingToken: string;
  qrUrl: string;
  expiresAt: number;
  /** First-creation epoch ms (persistence GC anchor, matches relay 30-day cap). */
  createdAt: number;
}

/** Tunnel-level connection state surfaced on the settings card. */
export type TunnelState = 'connected' | 'connecting' | 'reconnecting' | 'disabled' | 'manual-off';

/**
 * Header this tunnel stamps on every request it forwards from a paired device.
 *
 * WHY (v3.282): the engine's HTTP listener sees every bridged request arrive
 * from 127.0.0.1, i.e. byte-for-byte "local". Without a marker the plugin
 * cannot tell a phone from the admin page sitting next to it, and its admin
 * routes (mint a pairing / revoke every pairing / switch the tunnel) become
 * remote-reachable — each one is a denial of service against the device doing
 * it. The stamp is the engine side of that boundary: the plugin refuses those
 * routes when it sees this header.
 *
 * Trust rule: the value is set ONLY here, and any device-supplied copy is
 * stripped before it is set, so a paired device can neither forge nor suppress
 * the marker. Stripping also covers `x-forwarded-*`, which would otherwise let
 * a device spoof its provenance for anything downstream that trusts it.
 *
 * Every upstream header set this client builds goes through
 * {@link markForwardedAsRemote} — HTTP requests and bridged WS upgrades share
 * `buildUpstreamHeadersInline`, which is the single place the stamp is applied.
 */
export const REMOTE_TUNNEL_MARKER_HEADER = 'x-dsh-remote-tunnel';
const REMOTE_TUNNEL_MARKER_VALUE = '1';

/** Provenance headers a paired device must never pass through to the engine. */
const DEVICE_FORBIDDEN_HEADERS = [
  REMOTE_TUNNEL_MARKER_HEADER,
  'forwarded',
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-proto',
] as const;

/**
 * Mark one forwarded request as tunnel-borne.
 *
 * Call it on every header set this client builds for the engine (HTTP requests
 * and bridged WS upgrades alike); omitting it re-opens the engine-admin hole
 * for WS-borne traffic.
 * @param out - the header set about to be sent upstream; mutated in place.
 * @returns the same object, for call-site chaining.
 */
export function markForwardedAsRemote(out: Record<string, string>): Record<string, string> {
  for (const name of DEVICE_FORBIDDEN_HEADERS) delete out[name]
  out[REMOTE_TUNNEL_MARKER_HEADER] = REMOTE_TUNNEL_MARKER_VALUE
  return out
}

/**
 * End-to-end engine health as seen from the data plane (v3.177).
 *
 * 'connected' only means the tunnel WS to the relay is up — it says nothing
 * about whether the engine behind it actually answers. This flag carries that
 * missing fact, observed for free at two points the client already touches:
 * the /auth cookie mint (per fresh mint, ~never — 25-day cache) and proxied
 * /api responses (every console request). unknown means no evidence yet and
 * must not be painted as a fault.
 */
export type EngineHealth = 'ok' | 'unreachable' | 'unknown';

/** Relay-side absolute pairing lifetime cap (30 days) — drop older rows on load. */
const SESSION_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;

/**
 * Multi-slot pairing store with crash/restart persistence.
 *
 * v2 契约（2026-08-31 卡片三缺陷修复）：此前插件只保留最后一个配对会话
 * （单槽、纯内存）——测试/新配对会顶掉正式配对，引擎一重启全部丢失，
 * 30 天 cookie 的承诺无法兑现。现在：
 *  - 多会话 Map：每次「开启」新增一条，互不顶替；重连补注册全部。
 *  - 落盘 <dataRoot>/remote-sessions.json（DSH_REMOTE_DATA_ROOT 可覆
 *    盖，chmod 600，原子写）：引擎重启后自动恢复并补注册，已配对设备的
 *    cookie 在 relay 30 天寿命内持续有效。pairingToken 落盘属密钥级数据，
 *    文件权限与 engine.token 同级对待。
 *
 * v3.141：单模式化——`mode` 字段从 `RemoteSessionInfo` 与持久化文件中删除；
 * 远程控制等价于完整控制（16 PRIVILEGED 由 dsh Host fence 独立承担）。
 */
function dataRoot(instanceRoot?: string): string {
  return instanceRoot ?? process.env.DSH_REMOTE_DATA_ROOT ?? join(homedir(), '.dsh-remote-relay')
}

/**
 * Durable tunnel state — one document, one writer.
 *
 * v3.282: the disconnect intent lived in a private field, so it died with the
 * process while `config.enabled` kept living in the Host's document. The card
 * therefore showed "enabled: false" and "已手动断开中继" at the same time,
 * and only a manual re-enable could clear it. Both facts now have owners and
 * both survive a restart: `enabled` is the Host's switch, `manualOff` is this
 * document's, and the state readout derives from them in one place.
 */
interface PersistedState {
  version: number;
  sessions: RemoteSessionInfo[];
  /** User turned the relay off by hand. Outlives the process on purpose. */
  manualOff: boolean;
}

function emptyState(): PersistedState {
  return { version: 1, sessions: [], manualOff: false };
}

function loadState(instanceRoot?: string): PersistedState {
  try {
    const raw = JSON.parse(
      readFileSync(join(dataRoot(instanceRoot), 'remote-sessions.json'), 'utf-8'),
    ) as Partial<PersistedState>;
    const now = Date.now();
    const sessions = (raw.sessions ?? []).filter(
      (s) => s && typeof s.sessionId === 'string' && typeof s.pairingToken === 'string'
        && now - (s.createdAt ?? 0) < SESSION_MAX_AGE_MS,
    );
    return { version: 1, sessions, manualOff: raw.manualOff === true };
  } catch {
    // Missing or corrupt file: start clean. A damaged pairing store must not
    // wedge the tunnel, and a damaged disconnect flag must not strand it in a
    // state the user cannot reason about — it falls back to "not off".
    return emptyState();
  }
}

function saveState(state: PersistedState, instanceRoot?: string): void {
  const file = join(dataRoot(instanceRoot), 'remote-sessions.json')
  try {
    mkdirSync(dirname(file), { recursive: true })
    // Unique tmp name per writer: the previous fixed `${file}.tmp` let two
    // processes in one data root interleave write→rename and lose a document.
    const tmp = `${file}.${process.pid}.tmp`
    writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 })
    chmodSync(tmp, 0o600)
    renameSync(tmp, file)
  } catch {
    // 落盘失败不阻塞隧道（内存态仍完整；下次变更重试）
  }
}

/** v3.171：URL 签名链接配套辅助。
 *  install_id 持久化到 <dataRoot>/install-id（chmod 600），首次读失败时
 *  生成 UUID 并落盘；mac 失败回退 "unknown"——产线都是 Mac，unknown 不会
 *  真出现；只是防御远端 headless 环境。
 *  mid = sha256(hostname + mac + install_id)——客户端自检"此链接只在我这台设备打开",
 *  relay 端不强制 mid 校验（避免移动网络 IP 变 + multi-device 用户误伤）。
 *  hash = base64url(HMAC-SHA256(secret, sid|exp|mid|t))——防篡改 + 时序锁,
 *  relay 端用同一 RELAY_PSK 验签。 */
function installIdPath(instanceRoot?: string): string {
  return join(dataRoot(instanceRoot), 'install-id')
}

function readOrCreateInstallId(instanceRoot?: string): string {
  try {
    return readFileSync(installIdPath(instanceRoot), 'utf-8').trim()
  } catch {
    const id = crypto.randomUUID()
    try {
      mkdirSync(dirname(installIdPath(instanceRoot)), { recursive: true })
      writeFileSync(installIdPath(), id, { mode: 0o600 })
      try { chmodSync(installIdPath(), 0o600) } catch {}
    } catch {
      // 容错：落盘失败用内存值（mid 退化为 ephemeral——下次启动会变，
      // 同一设备两次启动之间的 share-link 会失效；可接受）
    }
    return id
  }
}

function primaryMacAddress(): string {
  try {
    const ifaces = networkInterfaces()
    for (const list of Object.values(ifaces)) {
      if (!list) continue
      for (const iface of list) {
        if (!iface.internal && iface.mac && iface.mac !== '00:00:00:00:00:00') {
          return iface.mac.replace(/:/g, '')
        }
      }
    }
  } catch {}
  return 'unknown'
}

function computeMid(instanceRoot?: string): string {
  return createHash('sha256')
    .update(`${hostname()}::${primaryMacAddress()}::${readOrCreateInstallId(instanceRoot)}`)
    .digest('hex')
}

function computeShareLinkHash(secret: string, sid: string, exp: number, mid: string, t: number): string {
  // 与 relay verifyShareLink 必须用同一拼接顺序：sid|exp|mid|t
  const msg = [sid, exp, mid, t].join('|')
  return createHmac('sha256', secret).update(msg).digest('base64url')
}

/** Relay 侧设备在线快照（/__devices 响应，PSK 鉴权 HTTP）。 */
export interface RemoteDeviceInfo {
  sessionId: string;
  createdAt: number;
  lastSeen: number | null;
  onlineWs: number;
  online: boolean;
  /** relay 侧已有设备真正扫过码（__pair 成功过）。 */
  paired: boolean;
}

export class RemoteTunnelClient {
  private ws: WebSocket | null = null;
  private config: RemoteRelayConfig;
  /** Retained pairings keyed by sessionId (multi-slot). */
  private sessions = new Map<string, RemoteSessionInfo>();
  private reconnectTimer: NodeJS.Timeout | null = null;
  private isManualClosed = false;
  private reconnectDelayMs: number;
  /** Revocation delivery budget; injectable so specs need not wait it out. */
  private readonly deliveryWaitMs: number;
  private tunnelState: TunnelState = 'disabled';
  /** v3.177 数据面实测的引擎健康（见 EngineHealth 注释）。进程内状态，不落盘。 */
  private engineHealth: EngineHealth = 'unknown';
  /** 用户手动断联（区别于网络掉线）：断开期间 close 不触发重连，直到
   * 手动重连或引擎重启（config.enabled 仍为 true）。 */
  private manualOff = false;
  /** v3.152.4 PR-WS-bridge：每个 relay ws.upgrade 帧对应一个 dsh 侧
   * WebSocket 连接（id → ws）。上行帧（phone→dsh）经此写入；close 时清理。 */
  private bridgedWs = new Map<string, WebSocket>();
  /** v3.161：当前正在累积大响应（接近 MAX_RESP_BODY）的 http.req id 数。
   * 超过并发上限即拒新进大请求——挡 SPA 用 ?limit=999999999 之类把 plugin
   * 进程拉满内存的 DoS。MAX_BODY 已经是硬上限，并发是软上限（先到先得）。 */
  private pendingLargeResponses = 0
  private static MAX_PENDING_LARGE_RESPONSES = 8
  /**
   * The single writer for the durable state document.
   *
   * Every mutation of `sessions` or `manualOff` goes through here, so there is
   * one place that knows the on-disk shape and one place that honours
   * `persist: false`.
   */
  private persist(): void {
    if (!this.persistenceEnabled) return
    saveState(
      { version: 1, sessions: [...this.sessions.values()], manualOff: this.manualOff },
      this.dataRootDir,
    )
  }

  /** v3.161:audit 帧 helper——经 /ws/dsh 数据面发往 relay，由 relay 写 audit
   * DB（同 plugin console.warn 双轨：mac 本地看得到 + 远程 watchdog 也能分析）。 */
  private reportAudit(sessionId: string | undefined, eventType: string, details?: string): void {
    console.warn(`[dsh-remote-client][audit] ${eventType}${details ? ' ' + details : ''}`)
    this.sendDataPlaneFrame({
      v: 1, type: 'audit', payload: {
        eventType,
        sessionId: sessionId ?? '',
        details: details ?? '',
      },
    })
  }
  /** v3.154：WSS 心跳。空闲隧道被 NAT 掐成半开后 close 不触发、
   * scheduleReconnect 永不跑（2026-09-07 实锤：连接 ~8 分钟后 relay 侧
   * 已断，Mac TCP 仍 ESTABLISHED，手机报 plugin_not_connected 假死最长
   * 到 TCP 自身超时）。30s ping；连续 2 周期无 pong 视为死链，terminate
   * 强制走既有 close → scheduleReconnect 链。 */
  private heartbeatTimer: NodeJS.Timeout | null = null;
  private missedPongs = 0;

  /** Resolved persistence root (constructor option > env > ~/.dsh-remote-relay). */
  private readonly dataRootDir: string | undefined;
  /** Persistence on ⇒ the shared sessions file is the cross-process contract. */
  private readonly persistenceEnabled: boolean;

  constructor(config: RemoteRelayConfig, options?: { reconnectDelayMs?: number; persist?: boolean; dataRoot?: string; deliveryWaitMs?: number }) {
    this.config = config;
    // Injectable so tests can exercise the reconnect path without a 5s wait.
    this.reconnectDelayMs = options?.reconnectDelayMs ?? 5000;
    /** Revocation delivery budget; injectable so specs need not wait it out. */
    this.deliveryWaitMs = options?.deliveryWaitMs ?? 4000;
    this.dataRootDir = options?.dataRoot;
    // 测试可用 persist:false 隔离文件系统 —— 这个开关曾经只挡住「读」，写盘
    // 照旧发生，于是跑一次单测就会覆盖用户真实的 remote-sessions.json。
    this.persistenceEnabled = options?.persist !== false;
    const persisted = this.persistenceEnabled ? loadState(this.dataRootDir) : emptyState();
    for (const s of persisted.sessions) this.sessions.set(s.sessionId, s)
    this.manualOff = persisted.manualOff
    this.tunnelState = config.enabled ? 'connecting' : 'disabled'
  }

  public updateConfig(newConfig: Partial<RemoteRelayConfig>) {
    const previous = this.config
    this.config = { ...this.config, ...newConfig };
    if (!this.config.enabled) {
      this.disconnect();
      return;
    }
    // v3.282：身份字段（拨向哪里、以什么身份）必须比对重拨。原先只做浅合并、
    // 仅在 socket 非 OPEN 时重连，于是改 relay_url 后徽章显示新地址而 socket
    // 还在旧中继；改 psk 后新铸的会话用新密钥签名、隧道却仍用旧密钥鉴权。
    const identityChanged =
      previous.relayUrl !== this.config.relayUrl || previous.psk !== this.config.psk
    if (identityChanged) {
      this.disconnect();
      this.connect();
      return;
    }
    // 从 disabled 回到 enabled 时清掉手动断开意图，否则隧道会拨出去而卡片
    // 仍报「已手动断开」——与本文件原本那个 bug 方向相反，一样是谎话。
    this.manualOff = false;
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) this.connect();
  }

  /**
   * Dial the relay.
   *
   * @param force - an explicit user action (enable / re-enable), which clears a
   * previous manual disconnect. It deliberately does NOT bypass `enabled`:
   * the revoke path used to pass force to reach an otherwise unreachable relay,
   * which meant revoking from a disabled engine quietly brought the tunnel
   * back and left it connected.
   */
  public connect(force = false) {
    // v3.282: force no longer bypasses the master switch. The revocation path
    // used to rely on that to reach a switched-off relay, and paid for it by
    // leaving the engine dialed — "turn the remote off, then revoke" silently
    // turned it back on. Delivery now dials explicitly and always restores.
    if (!this.config.enabled) return;
    this.dial(force);
  }

  /**
   * Open the socket. The one place a tunnel is created.
   * @param force - an explicit user action, which clears a manual disconnect.
   * @param ignoreSwitches - dial even when `enabled` is false. Reserved for
   * delivering one frame on a switched-off engine (see withTemporaryTunnel);
   * every caller must restore the prior state afterwards.
   */
  private dial(force = false, ignoreSwitches = false) {
    if (!this.config.relayUrl) return;
    if (!ignoreSwitches && !this.config.enabled) return;
    // v3.282：在途拨号就是那次拨号。此前没有这道闸，两次并发的 updateConfig 会
    // 开出两条 socket，而 disconnect() 只关得掉一条——剩下那条既不注册也不
    // 心跳，没有任何东西会回收它。
    if (this.ws && (this.ws.readyState === WebSocket.CONNECTING || this.ws.readyState === WebSocket.OPEN)) return;
    // 显式用户动作（开启远程/重新开启）解除手动断开标记——卡片「断开中继」
    // 已同时撤销全部配对，恢复唯一路径就是重新走配对流程
    if (force && this.manualOff) {
      this.manualOff = false;
      this.persist();
    }
    this.isManualClosed = false;

    try {
      const wsUrl = this.config.relayUrl.replace(/^http/, 'ws') + '/ws/dsh';
      this.tunnelState = this.reconnectTimer ? 'reconnecting' : 'connecting';
      const socket = new WebSocket(wsUrl, {
        headers: {
          authorization: `Bearer ${this.config.psk}`,
          // v3.150：A1 时间戳窗 — relay 校验 |now - ts| < 30s
          'x-session-ts': Date.now().toString(),
        },
      });
      this.ws = socket;

      socket.on('open', () => {
        // 旧连接的延迟 close 事件不得动新连接（快速断开→重开场景的竞态）
        if (this.ws !== socket) return;
        this.tunnelState = 'connected';
        this.reconnectTimer = null;
        // Re-register EVERY retained pairing on each (re)connect. The relay
        // (v3.119+) keeps each pairing's sessionSecret across tunnel drops
        // within its grace window, so re-registering with the SAME
        // sessionId + pairingToken re-binds the original secret and phone
        // cookies keep working. The old `Date.now() < expiresAt` guard meant
        // any disconnect later than 5 minutes after pairing silently killed
        // every phone's 30-day cookie.
        for (const session of this.sessions.values()) {
          this.registerSession(session.sessionId, session.pairingToken);
        }
        this.startHeartbeat(socket);
        this.startSessionAdoption(socket);
      });

      socket.on('pong', () => {
        if (this.ws !== socket) return;
        this.missedPongs = 0;
      });

      socket.on('message', (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          // v3.151 PR-B：WSS 数据面——relay 经同通道转发 phone 的 HTTP/WS 请求
          if (msg.type === 'session.registered') {
            console.log(`[dsh-remote-client] pairing session ${msg.sessionId} registered on relay`);
          } else if (msg.type === 'http.req') {
            // 收到 phone 的 HTTP 请求 — 经 WSS 反代，本地打 dsh。
            // v3.282:拒绝必须接住——handleHttpReq 里有同步抛点（http.request
            // 对非法 method/path 直接 TypeError），而 void 链上的未捕获 rejection
            // 在默认 --unhandled-rejections=throw 下会杀死整个引擎进程。
            this.handleHttpReq(msg).catch((err) => {
              console.error(`[dsh-remote-client] http bridge crashed for id=${String(msg.id).slice(0, 8)}:`, (err as Error).message)
              this.sendDataPlaneFrame({ v: 1, type: 'error', id: msg.id, code: 'bridge_error', message: 'request could not be fulfilled' })
            })
          } else if (msg.type === 'ws.upgrade') {
            this.handleWsUpgrade(msg).catch((err) => {
              console.error(`[dsh-remote-client] ws bridge crashed for id=${String(msg.id).slice(0, 8)}:`, (err as Error).message)
              this.sendDataPlaneFrame({ v: 1, type: 'error', id: msg.id, code: 'bridge_error', message: 'upgrade could not be fulfilled' })
              this.sendDataPlaneFrame({ v: 1, type: 'ws.close', id: msg.id, code: 1011, reason: 'bridge error' })
            })
          } else if (msg.type === 'ws.frame' && msg.dir === 'up') {
            // v3.152.4 PR-WS-bridge：phone→dsh 上行帧——写入对应桥接连接。
            // opcode 2（binary）时 payload 是 base64，与下行约定对称。
            const bridged = this.bridgedWs.get(msg.id)
            if (bridged && bridged.readyState === WebSocket.OPEN) {
              try {
                bridged.send(msg.opcode === 2 ? Buffer.from(msg.payload, 'base64') : String(msg.payload))
              } catch (err) {
                console.error('[dsh-remote-client] ws up-frame write failed:', (err as Error).message)
              }
            }
          } else if (msg.type === 'ws.close') {
            // relay 侧浏览器断开（或超时）——关闭对应 dsh 连接并清账
            const bridged = this.bridgedWs.get(msg.id)
            if (bridged) {
              this.bridgedWs.delete(msg.id)
              try { bridged.close(msg.code ?? 1000, msg.reason ?? '') } catch { /* already closed */ }
            }
          } else if (msg.type === 'error' && typeof msg.id === 'string') {
            // relay 报某个 id 出错 — 上层 inflight ctx 自处理
            console.warn(`[dsh-remote-client] wss data-plane error id=${msg.id.slice(0, 8)} ${msg.code}: ${msg.message}`);
          }
        } catch (err) {
          console.error('[dsh-remote-client] wss message parse failed:', (err as Error).message);
        }
      });

      socket.on('close', () => {
        // 身份校验：旧 socket 的 close 是异步到达的——此时 this.ws 可能已经
        // 是 revokeAll 临时拉起的新连接，无条件置空会把新连接引用清掉
        // （2026-08-31 撤销丢失/状态卡 connecting 的根因）
        if (this.ws !== socket) return;
        this.stopHeartbeat();
        this.ws = null;
        if (!this.isManualClosed && this.config.enabled) {
          this.tunnelState = 'reconnecting';
          this.scheduleReconnect();
        } else {
          this.tunnelState = this.config.enabled ? 'connecting' : 'disabled';
        }
      });

      socket.on('error', () => {
        // 'close' follows; reconnect/backoff handled there
      });
    } catch {
      this.tunnelState = this.config.enabled ? 'reconnecting' : 'disabled';
      if (this.config.enabled) this.scheduleReconnect();
    }
  }

  /** Mint a new pairing alongside existing ones (v3.170 起多 pairing 共存).
   *
   * 旧单客户端策略 (v3.141-v3.169):revokes every existing pairing first
   * ——「新设备配对 = 顶替旧设备」。这一策略在多 dsh engine 共存场景下
   * 与 relay v3.162 的"踢旧"叠加成 5 秒级乒乓,见
   * docs/decisions/2026-09-09-multi-device-pairing.md 决策 2。
   *
   * 新行为:sessions Map 多槽保留所有历史 pairing(M01 v2 + v3.128.2 已有
   * 多槽逻辑,只是 createSession 入口会清),新配对 = 在 Map 末尾追加。
   * 撤销走专门的 revokeSession(sessionId) 单 pairing API;revokeAllSessions
   * 保留为「断开中继」按钮的全清场景。 */
  public createSession(): RemoteSessionInfo {
    const sessionId = `sess_${crypto.randomBytes(8).toString('hex')}`;
    const pairingToken = crypto.randomBytes(32).toString('hex');
    // v3.176(用户拍板):QR 也走根路径 URL 会话——`/?sessionId&token&hash&t&exp&mid`
    // 手机扫码打开 = 一条 24h 签名的 URL 会话链接,SPA 注入 Bearer,全程不颁
    // cookie、不走 /__pair。旧 30 天 /__pair 长效链接退役(端点保留兼容已分享
    // 的旧链接);过期后手机重新扫码即可。expiresAt 与 URL TTL 对齐(24h),
    // 卡片倒计时如实反映链接剩余寿命。无 psk 时 fallback 旧格式(异常配置)。
    const ttlSeconds = 24 * 60 * 60;
    const expiresAt = Date.now() + ttlSeconds * 1000;

    const info: RemoteSessionInfo = { sessionId, pairingToken, qrUrl: '', expiresAt, createdAt: Date.now() };
    // 无 psk 的异常配置兜底（v3.203 起 /__pair 退役）：降级为不带签名的
    // 旧格式根路径链接 ?sessionId&token——relay 根路径闸门按 pairingToken
    // 校验后同样走「颁 pairing cookie + /auth 跳板」着陆动作。
    info.qrUrl = this.config.psk
      ? this.buildSignedUrl(info, ttlSeconds)
      : `${this.config.relayUrl.replace(/\/$/, '')}/?sessionId=${sessionId}&token=${pairingToken}`;
    this.sessions.set(sessionId, info);
    this.persist();

    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.registerSession(sessionId, pairingToken);
    } else {
      // 显式用户动作(点击"开启远程")覆盖 enabled 开关
      this.connect(true);
      // 连接建立后由 'open' 处理器补注册
    }

    return info;
  }

  /** All retained pairings (card status view). */
  public getSessions(): RemoteSessionInfo[] {
    return [...this.sessions.values()];
  }

  /** First pairing whose QR window is still open (card QR view). */
  public getSession(): RemoteSessionInfo | null {
    // Expired pairings hide the QR (card contract) but the session objects are
    // RETAINED for re-registration on tunnel reconnects — the relay's grace
    // window keeps the already-issued cookie alive; showing a dead QR is the
    // only thing expiry should govern here.
    const now = Date.now()
    for (const s of this.sessions.values()) {
      if (s.expiresAt > now) return s
    }
    return null
  }

  /** Mint a URL session link (v3.173 第三条路,浏览器多设备不依赖 cookie)。
   * **根路径 `/?` 而非 `/__pair`**——URL 会话是"持续会话入口",SPA 打开后
   * 从 location.search 读 sessionId/exp/mid/t/hash 组装
   * `Authorization: Bearer <sid>.<exp>.<mid>.<t>.<hash>` 发 /api 请求,
   * relay gate 直接验签,**不颁 cookie、不 302**。per-tab 隔离——每个 tab
   * 地址栏就是自己的凭证(zcode 同形态)。
   *
   * history：v3.171 曾有 mintShareLink()（/__pair 着陆 + 30 分钟 TTL 的
   * 分享链接），v3.176 QR 全面切根路径 URL 会话后无调用方，v3.203 删除
   * （/__pair 端点同步退役，见
   * docs/decisions/2026-09-15-relay-pair-retirement.md）。
   */
  /** v3.176:构造根路径签名 URL——mintUrlSession 与 createSession 的 QR 共用。
   *  `/?sessionId&hash&t&exp&mid[&name][&app_version]`,SPA 打开即注入
   *  Bearer(URL 会话),不颁 cookie、不 302。
   *  v3.176.2:不再带 token 字段——dsh BrowserAuth.authorizeIndex 对 query
   *  含 token 的 / 请求一律 303 到干净 /(剥掉全部 query),SPA 落地时地址栏
   *  已无凭证 → installUrlSessionAuth 静默跳过 → 全部 401 卡 connecting。
   *  无 token 时 dsh 直接按 isAuthenticated 出 200,query 原样保留。 */
  private buildSignedUrl(target: RemoteSessionInfo, ttlSeconds: number, options?: { name?: string; appVersion?: string }): string {
    const t = Date.now()
    const exp = t + ttlSeconds * 1000
    const mid = computeMid(this.dataRootDir)
    const hash = computeShareLinkHash(this.config.psk, target.sessionId, exp, mid, t)
    const url = new URL('/', this.config.relayUrl)
    url.searchParams.set('sessionId', target.sessionId)
    url.searchParams.set('hash', hash)
    url.searchParams.set('t', t.toString())
    url.searchParams.set('exp', exp.toString())
    url.searchParams.set('mid', mid)
    if (options?.name || hostname()) {
      url.searchParams.set('name', options?.name ?? hostname())
    }
    if (options?.appVersion) {
      url.searchParams.set('app_version', options.appVersion)
    }
    return url.toString()
  }

  public mintUrlSession(sessionId?: string, options?: { ttlSeconds?: number; name?: string; appVersion?: string }): string {
    if (!this.config.psk) {
      throw new Error('No PSK configured; cannot mint url session')
    }
    const target = sessionId ? this.sessions.get(sessionId) : [...this.sessions.values()][0]
    if (!target) {
      throw new Error('No active pairing; pair first before sharing')
    }
    const ttlSeconds = options?.ttlSeconds ?? 24 * 60 * 60
    if (!Number.isFinite(ttlSeconds) || ttlSeconds < 60 || ttlSeconds > 86400) {
      throw new Error('ttlSeconds must be in [60, 86400]')
    }
    return this.buildSignedUrl(target, ttlSeconds, options)
  }

  /** 隧道级手动开关（卡片「断开中继 / 重新连接」按钮）。
   *
   * off：isManualClosed 挡住自动重连，manual-off 状态供卡片渲染；已配对
   * 设备的 cookie 在 relay 宽限期内（默认 600s）重连可保活，超时需重新扫
   * 码——卡片文案负责交代这一后果。
   *
   * v3.282：这个意图现在**落盘**。此前它只活在进程内存里，于是引擎一重启
   * 就按 config.enabled 悄悄重连，而卡片仍记得自己被手动关过；两个事实分属
   * 两处存储，界面同时显示「未启用」和「已手动断开」这种自相矛盾的状态。
   * 落盘后重启保持断开，与卡片文案承诺的恢复路径（点「开启远程控制」）一致。
   */
  public setTunnelEnabled(on: boolean): { state: TunnelState; relayUrl: string } {
    if (on) {
      this.manualOff = false;
      this.persist();
      this.isManualClosed = false;
      this.connect(true);
    } else {
      this.manualOff = true;
      this.persist();
      this.disconnect();
      this.tunnelState = 'manual-off';
    }
    return this.getConnectionState();
  }

  /**
   * Tunnel-level state for the settings card status line.
   *
   * v3.282: the two "off" facts are decided BEFORE the socket, because
   * `updateConfig` guarantees a disabled/manual-off tunnel has no socket. The
   * previous order let a live socket win, which is how a connected tunnel
   * reported itself as disconnected — and, symmetrically, how one dialed while
   * the card claimed the user had switched it off.
   */
  public getConnectionState(): { state: TunnelState; relayUrl: string; manualOff: boolean; engine: EngineHealth } {
    if (!this.config.enabled) {
      this.tunnelState = 'disabled'
    } else if (this.manualOff) {
      this.tunnelState = 'manual-off';
    } else if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.tunnelState = 'connected'
    } else if (this.tunnelState !== 'reconnecting') {
      this.tunnelState = 'connecting'
    }
    return { state: this.tunnelState, relayUrl: this.config.relayUrl, manualOff: this.manualOff, engine: this.engineHealth }
  }

  /**
 * Run `work` with a usable tunnel, dialling one only if none is live, and put
 * the tunnel back exactly as it was afterwards.
 *
 * WHY: revoking a pairing has to REACH the relay or "断开即失效" is a lie, so a
 * switched-off engine must still dial for a moment. Both revoke paths used to
 * do this by hand and restored only when the prior state was `manualOff` — so
 * "disable the remote, then revoke" left the tunnel connected, and the card
 * reported a state nobody had asked for.
 *
 * @param work - receives the live socket (or null when the relay never
 * answered) and reports whether the frame was delivered.
 * @returns what `work` reported.
 */
private async withTemporaryTunnel(work: (ws: WebSocket | null) => boolean): Promise<boolean> {
  const hadLiveSocket = !!this.ws && this.ws.readyState === WebSocket.OPEN
  const manualBefore = this.manualOff
  let ws = this.ws
  if (!hadLiveSocket) {
    this.dial(true, true)
    ws = await this.waitForOpenSocket()
  }
  try {
    return work(ws && ws.readyState === WebSocket.OPEN ? ws : null)
  } finally {
    if (!hadLiveSocket) {
      // Unconditional restore: whatever the pre-call intent was, it is again.
      this.disconnect()
      this.manualOff = manualBefore
      this.tunnelState = manualBefore ? 'manual-off' : (this.config.enabled ? 'connecting' : 'disabled')
    }
  }
}

/** Poll briefly for the socket the temporary dial just opened. */
private async waitForOpenSocket(): Promise<WebSocket | null> {
  return new Promise<WebSocket | null>((resolve) => {
    const timer = setTimeout(() => { clearInterval(poll); resolve(null); }, this.deliveryWaitMs);
    const poll = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        clearInterval(poll); clearTimeout(timer); resolve(this.ws);
      }
    }, 50);
  })
}

/** Revoke a single pairing (v3.170 多 pairing 共存后的细粒度撤销).
   * 卡片 UI 列出每个 pairing 时,「撤销此 pairing」按钮对应此接口。
   * 同 revokeAllSessions 的"送达守卫":隧道不在时临时拉起送达再收回,
   * 否则宽限期内设备仍可访问,「撤销即失效」破功。 */
  public async revokeSession(sessionId: string): Promise<boolean> {
    const session = this.sessions.get(sessionId);
    if (!session) return false;
    // v3.282: delivered 落进结果——relay 不可达时不能删本地记录却报成功，
    // 否则设备在宽限期内仍可访问，而这份副本已毁、永不再补发。
    const delivered = await this.withTemporaryTunnel((ws) => {
      if (!ws) return false;
      ws.send(JSON.stringify({
        type: 'session.revoke',
        payload: { sessionId, reason: 'User revoked' },
        timestamp: Date.now(),
      }));
      return true
    });
    if (!delivered) {
      this.reportAudit(sessionId, 'revoke_not_delivered', 'relay unreachable; local copy kept')
      return false;
    }
    this.sessions.delete(sessionId);
    this.persist();
    return true;
  }

  /** Revoke every retained pairing (card「断开中继」). 撤销必须送达 relay
   * 才会立即杀掉设备 cookie——隧道不在时(手动断开先于撤销等)临时拉起
   * 连接送达后再收回,否则宽限期内设备仍可访问,「断开即失效」破功。 */
  public async revokeAllSessions(): Promise<number> {
    const sessions = [...this.sessions.values()];
    if (sessions.length === 0) return 0;

    // v3.282:同 revokeSession —— 送达失败就不清本地记录。原先无论 relay 是否
    // 真的收到都 clear() 并返回条数，把「撤销」变成了本地删除。
    const delivered = await this.withTemporaryTunnel((ws) => {
      if (!ws) return false;
      for (const session of sessions) {
        ws.send(JSON.stringify({
          type: 'session.revoke',
          payload: { sessionId: session.sessionId, reason: 'User revoked' },
          timestamp: Date.now(),
        }));
      }
      return true
    });
    if (!delivered) {
      this.reportAudit(undefined, 'revoke_not_delivered', `relay unreachable; ${sessions.length} pairing(s) kept`)
      return 0;
    }
    this.sessions.clear();
    this.persist();
    return sessions.length
  }

  /** @deprecated 单槽时代接口；保留供旧调用兼容，语义 = revokeAll。 */
  public revokeCurrentSession() {
    this.revokeAllSessions()
  }

  public disconnect() {
    this.isManualClosed = true;
    this.stopHeartbeat();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      try {
        this.ws.close();
      } catch {}
      this.ws = null;
    }
    this.tunnelState = 'disabled';
    // v3.152.4：隧道断开 = 全部桥接 WS 失去载体——统一关闭清账，
    // 防 relay 侧重连后 bridgedWs 里残留死连接吃上行帧
    for (const [, bridged] of this.bridgedWs) {
      try { bridged.close(1006, 'tunnel closed') } catch { /* already closed */ }
    }
    this.bridgedWs.clear();
    // 配对记录保留（disconnect 只停隧道；恢复 enabled 时 'open' 补注册）
  }

  /** 设备在线列表（卡片 3s 轮询场景 → 3s 缓存 + 2s 超时；失败沿用上次
   * 快照，relay 不可达时返回 null 由卡片降级为仅本地配对数）。 */
  private devicesCache: { at: number; data: RemoteDeviceInfo[] | null } = { at: 0, data: null };

  public async getDevices(): Promise<RemoteDeviceInfo[] | null> {
    if (this.devicesCache.data && Date.now() - this.devicesCache.at < 3000) {
      return this.devicesCache.data;
    }
    try {
      const res = await fetch(`${this.config.relayUrl.replace(/\/$/, '')}/__devices`, {
        headers: { authorization: `Bearer ${this.config.psk}` },
        signal: AbortSignal.timeout(2000),
      });
      if (res.ok) {
        const data = await res.json() as { devices?: RemoteDeviceInfo[] };
        const devices = Array.isArray(data.devices) ? data.devices : [];
        this.devicesCache = { at: Date.now(), data: devices };
        return devices;
      }
    } catch {
      // 超时/网络错误：沿用旧快照
    }
    return this.devicesCache.data;
  }

  private registerSession(sessionId: string, pairingToken: string) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({
        type: 'session.register',
        // engineToken: v3.41 lockdown 后引擎要求所有请求带 X-App-Token——
        // relay 侧凭此值注入转发头。随引擎每次启动轮换，靠（重）注册自动
        // 同步；经 PSK 隧道传输，不落盘。
        // v3.141：单模式化后 session.register payload 不再带 mode 字段。
        payload: {
          sessionId,
          pairingToken,
          ttlSeconds: 300,
          engineToken: this.resolveEngineToken(),
        },
        timestamp: Date.now(),
      }));
    }
  }

// v3.151 PR-B：WSS 数据面 HTTP 请求处理——relay 把 phone 的 HTTP 请求转过来。
// 本地用 node:http 打 dsh (127.0.0.1:3080)，按 A4 注入 host/x-app-token + strip dsh_remote_session，
// 然后把响应回填 http.res 帧。
  // 内联 A4 头过滤（与 docs/protocol.md 的 buildUpstreamHeaders 规范同语义；
  // 不能 import——plugin 在 .app bundle 里没有 services/ 兄弟目录）
  private buildUpstreamHeadersInline(phoneHeaders: Record<string, string>, publicHost: string, engineToken: string | undefined): Record<string, string> {
    const out: Record<string, string> = { ...phoneHeaders }
    if (typeof out.cookie === 'string' && out.cookie.length > 0) {
      out.cookie = out.cookie.split(';').map(c => c.trim()).filter(c => !c.startsWith('dsh_remote_session=')).join('; ')
      if (out.cookie === '') delete out.cookie
    }
    out.host = publicHost
    if (engineToken) out['x-app-token'] = engineToken
    // v3.152.1：钉 identity——http.res 帧的 body 走 utf8 字符串（JSON 帧），
    // dsh 返回 gzip/br 二进制时 toString('utf8') 会注入 U+FFFD 损坏 payload，
    // 浏览器按 content-encoding: gzip 解压失败报 Content Encoding Error
    // （curl 无 Accept-Encoding 逃过、Firefox 必现，2026-09-07 实证）。
    // plugin↔dsh 是 localhost 零成本；phone↔relay 段由 nginx 继续可压。
    out['accept-encoding'] = 'identity'
    // v3.282：来源标记——本函数产出的头只可能来自隧道，任何设备自带的
    // x-dsh-remote-tunnel / x-forwarded-* 在这里被剥掉后由隧道自己盖上。
    return markForwardedAsRemote(out)
  }

  private async handleHttpReq(msg: { id: string; method: string; path: string; headers: Record<string, string>; body?: string }): Promise<void> {
    const http = await import('node:http')
    // v3.154.1 拆分双向限额：请求体维持 4 MiB；响应体放宽到 32 MiB——
    // dsh 0.1.2 的 49 包合并 client bundle 已达 ~4.5MB，超旧 4 MiB 上限后
    // 手机端 SPA 卡 "Failed to load plugins"（payload_too_large），本机直连
    // 3080 不走本路径故难复现。
    const MAX_REQ_BODY = 4 * 1024 * 1024
    const MAX_RESP_BODY = 32 * 1024 * 1024
    if (msg.body !== undefined && msg.body.length > MAX_REQ_BODY) {
      this.sendDataPlaneFrame({ v: 1, type: 'error', id: msg.id, code: 'payload_too_large', message: `body exceeds ${MAX_REQ_BODY} bytes` })
      return
    }
    const upstreamHeaders = this.buildUpstreamHeadersInline(msg.headers, this.resolvePublicHost(), this.resolveEngineToken())
    // v3.177:与 WS 桥共用同一注入语义（总是剔除陈旧 dsh-auth-* + 无条件
    // 重签）。v3.176 的 `!includes('dsh-auth-')` 判断是这起 401 事故的根因：
    // 引擎重启轮换 token 后，手机带着旧签名 cookie，includes 命中 → 跳过
    // mint → 401 死循环。
    await this.applyEngineCookie(upstreamHeaders, 'http')
    const req = http.request({
      hostname: this.resolveUpstreamHost(),
      port: this.resolveUpstreamPort(),
      method: msg.method,
      path: msg.path,
      headers: upstreamHeaders,
    }, (res) => {
      const chunks: Buffer[] = []
      let totalBytes = 0
      let overflow = false
      // v3.161：大响应并发上限——响应累计超过 1 MiB 即占用一个「大响应槽」，
      // 同时在途 ≤ 8（MAX_PENDING_LARGE_RESPONSES）。SPA 用 ?limit=999999999
      // 之类并发打满时第 9 个起直接 503，而不是把 plugin 进程内存拉爆
      // （32 MiB × N 累积峰值 = DoS 面）。槽位在 end/error/overflow 时释放。
      let holdingLargeSlot = false
      const releaseLargeSlot = () => {
        if (holdingLargeSlot) {
          holdingLargeSlot = false
          this.pendingLargeResponses = Math.max(0, this.pendingLargeResponses - 1)
        }
      }
      res.on('data', (c: Buffer) => {
        if (overflow) return
        totalBytes += c.byteLength
        if (!holdingLargeSlot && totalBytes > 1024 * 1024) {
          if (this.pendingLargeResponses >= RemoteTunnelClient.MAX_PENDING_LARGE_RESPONSES) {
            overflow = true
            releaseLargeSlot()
            this.reportAudit(undefined, 'plugin_large_response_concurrency_exceeded',
              `${msg.method} ${msg.path} at ${totalBytes}B, pending=${this.pendingLargeResponses}`)
            this.sendDataPlaneFrame({ v: 1, type: 'error', id: msg.id, code: 'concurrency_exceeded', message: 'too many large responses in flight' })
            req.destroy()
            return
          }
          holdingLargeSlot = true
          this.pendingLargeResponses += 1
        }
        if (totalBytes > MAX_RESP_BODY) {
          overflow = true
          releaseLargeSlot()
          this.reportAudit(undefined, 'plugin_response_too_large',
            `${msg.method} ${msg.path} > ${MAX_RESP_BODY}B`)
          this.sendDataPlaneFrame({ v: 1, type: 'error', id: msg.id, code: 'payload_too_large', message: 'upstream body too large' })
          req.destroy()
          return
        }
        chunks.push(c)
      })
      res.on('end', () => {
        releaseLargeSlot()
        if (overflow) return
        // v3.177:/api 响应码就是免费的端到端健康探针——2xx 证明「隧道+引擎
        // 认证」全链路通，401 证明引擎认证面在拒（fresh cookie 仍 401 只可
        // 能是 token 失配/引擎半死）。只看 /api/*：插件自有路由不过引擎认证，
        // 它们的 200/401 与引擎健康无关。
        if (msg.path.startsWith('/api/')) {
          if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
            this.engineHealth = 'ok'
          } else if (res.statusCode === 401) {
            this.engineHealth = 'unreachable'
          }
        }
        const headers: Record<string, string> = {}
        for (const [k, v] of Object.entries(res.headers)) {
          const lk = k.toLowerCase()
          if (lk === 'set-cookie' || lk === 'transfer-encoding' || lk === 'content-length') continue
          if (typeof v === 'string') headers[k] = v
          else if (Array.isArray(v)) headers[k] = v.join(', ')
        }
        const sc = res.headers['set-cookie']
        if (sc) headers['set-cookie'] = Array.isArray(sc) ? sc.join(', ') : sc
        const body = Buffer.concat(chunks).toString('utf8')
        this.sendDataPlaneFrame({
          v: 1,
          type: 'http.res',
          id: msg.id,
          status: res.statusCode ?? 502,
          headers,
          body,
        })
      })
      res.on('error', (err) => {
        releaseLargeSlot()
        this.sendDataPlaneFrame({ v: 1, type: 'error', id: msg.id, code: 'engine_down', message: err.message })
      })
    })
    req.on('error', (err) => {
      this.sendDataPlaneFrame({ v: 1, type: 'error', id: msg.id, code: 'engine_down', message: `upstream connect: ${err.message}` })
    })
    if (msg.body && msg.body.length > 0) req.write(msg.body)
    req.end()
  }

  // v3.151 PR-B：WS upgrade 桥接（v3.151 PR-WS-bridge 完整版）。MVP 版本：建立 dsh WS 客户端，
  // 双向 ws.frame 透传。简化：每个 id 一个 node:ws client。
  // v3.157：Firefox 的 WebSocket 握手不携带 SameSite=Strict cookie（fetch 会
  // 带、WS 不带——浏览器差异），dsh mux 闸只认 dsh-auth 引擎 cookie →
  // 手机/浏览器 WS 永远 401、SPA 卡 connecting。修：透传 cookie 无 dsh-auth
  // 时 plugin 自己向 /auth 用 X-App-Token 换一枚注入（进程内缓存 25 天）。
  private engineCookieCache: { value: string; expiresAt: number } | null = null

  /**
   * v3.177：HTTP 数据面与 WS 桥共用的引擎 cookie 注入——两处必须同一语义，
   * 各写各的已经出过一次事故（v3.176 把 v3.157.1 的「总是替换」抄成
   * 「没有才加」：引擎重启轮换 token 后，浏览器携带的陈旧 dsh-auth-* 命中
   * includes 判断 → 跳过 mint → 死 cookie 透传 → /api 全线 401，而
   * /dsh-remote/* 不过引擎认证，机器卡照常绿灯。2026-10-10 实证）。
   *
   * 语义：先剔除全部旧 dsh-auth-*（引擎 token 轮换后旧签名必失效，保留
   * 没有意义），再用本进程持有的当前 token 无条件 mint 一枚注入。mint 失败
   * 时按降级透传（不带 dsh-auth），并把 engineHealth 标为 unreachable——
   * 这就是「隧道在线但引擎不应答」黄态的信号源之一。
   */
  private async applyEngineCookie(headers: Record<string, string>, surface: 'http' | 'ws'): Promise<void> {
    const kept = String(headers.cookie ?? '')
      .split(';').map(c => c.trim()).filter(c => c !== '' && !c.startsWith('dsh-auth-')).join('; ')
    if (kept) {
      headers.cookie = kept
    } else {
      delete headers.cookie
    }
    const minted = await this.mintEngineCookie()
    if (minted) {
      headers.cookie = kept ? `${kept}; ${minted}` : minted
    } else if (this.resolveEngineToken()) {
      console.warn(`[dsh-remote-client] ${surface} bridge: engine cookie mint failed, relaying without dsh-auth`)
    }
  }

  private async mintEngineCookie(): Promise<string | null> {
    const http = await import('node:http')
    const now = Date.now()
    if (this.engineCookieCache && now < this.engineCookieCache.expiresAt) {
      return this.engineCookieCache.value
    }
    const publicHost = this.resolvePublicHost()
    const engineToken = this.resolveEngineToken()
    if (!engineToken) return Promise.resolve(null)
    return new Promise((resolve) => {
      const req = http.request({
        hostname: '127.0.0.1',
        port: this.resolveUpstreamPort(),
        method: 'GET',
        path: '/auth?next=/',
        headers: { host: publicHost, ...(engineToken ? { 'x-app-token': engineToken } : {}) },
      }, (res) => {
        res.resume()
        res.on('end', () => {
          const sc = res.headers['set-cookie']
          const first = Array.isArray(sc) ? sc[0] : sc
          const pair = first?.split(';')[0]
          if (res.statusCode === 303 && pair && pair.includes('=')) {
            this.engineCookieCache = { value: pair, expiresAt: now + 25 * 24 * 60 * 60 * 1000 }
            this.engineHealth = 'ok'
            resolve(pair)
          } else {
            // 有 token 却签不出（非 303）＝引擎认证面不应答。缓存清掉，
            // 下一个请求会重试而不是吃 25 天的旧命中。
            this.engineCookieCache = null
            this.engineHealth = 'unreachable'
            resolve(null)
          }
        })
        res.on('error', () => {
          this.engineHealth = 'unreachable'
          resolve(null)
        })
      })
      req.on('error', () => {
        this.engineHealth = 'unreachable'
        resolve(null)
      })
      req.end()
    })
  }

  private async handleWsUpgrade(msg: { id: string; path: string; headers: Record<string, string> }): Promise<void> {
    const upstreamHeaders = this.buildUpstreamHeadersInline(msg.headers, this.resolvePublicHost(), this.resolveEngineToken())
    // v3.177:改用与 HTTP 数据面共用的 applyEngineCookie——语义不变（本处
    // v3.157.1 起就是「总是替换」），只是收敛到一个实现，防止再次各写各的。
    await this.applyEngineCookie(upstreamHeaders, 'ws')
    // v3.160：插件自有的实时行情 WS 在公网浏览器没有 Electron
    // contextBridge，SPA 只能发占位 token——转发时改写 query token 为本进程
    // 的 DSH_BIND_TOKEN（同 cookie bootstrap 信任模型：relay 的
    // dsh_remote_session cookie 闸已把来源限定为配对设备，plugin 是唯一
    // token 持有者）。带真 token 的直连请求不受影响（值相同）。改写范围由
    // tokenRewritePrefixes 显式配置，默认为空。
    let upstreamPath = msg.path
    // v3.282：path 必须以 / 开头，否则拼接出的地址会被 URL 解析器读成
    // 别的 authority——`ws://127.0.0.1:3080@evil.com/x` 的 host 是 evil.com，
    // 而上面刚盖上的引擎令牌会跟着发过去。relay 侧本应保证规范形状，这里
    // 不再信任它：不合形状的请求按 bad_request 回，绝不去连。
    if (!upstreamPath.startsWith('/')) {
      this.reportAudit(undefined, 'ws_upgrade_bad_path', `path=${upstreamPath.slice(0, 64)}`)
      this.sendDataPlaneFrame({ v: 1, type: 'error', id: msg.id, code: 'bad_request', message: 'path must start with /' })
      return
    }
    const rewritePrefixes = this.resolveTokenRewritePrefixes()
    if (rewritePrefixes.some((p) => upstreamPath.startsWith(p)) && this.resolveEngineToken()) {
      const qi = upstreamPath.indexOf('?')
      if (qi >= 0) {
        const search = new URLSearchParams(upstreamPath.slice(qi + 1))
        if (search.has('token')) {
          const supplied = search.get('token') ?? ''
          search.set('token', this.resolveEngineToken())
          upstreamPath = upstreamPath.slice(0, qi) + '?' + search.toString()
          // v3.161 审计：realtime token 改写是权限敏感操作——记原 token 指纹
          // （前 8 字符 + 长度，不含真值）供事后回溯谁触发了改写。
          this.reportAudit(undefined, 'plugin_realtime_token_rewritten',
            `supplied=${supplied.slice(0, 8)}…(${supplied.length}B)`)
        }
      }
    }
    const ws = new WebSocket(`ws://${this.resolveUpstreamHost()}:${this.resolveUpstreamPort()}${upstreamPath}`, { headers: upstreamHeaders })
    const MAX_BODY = 4 * 1024 * 1024
    // v3.152.4：登记进 bridgedWs——上行帧（ws.frame dir=up）与 relay 主动
    // 关闭（ws.close）都按 id 找回这条连接
    this.bridgedWs.set(msg.id, ws)
    ws.on('open', () => {
      this.sendDataPlaneFrame({ v: 1, type: 'ws.accept', id: msg.id })
    })
    ws.on('message', (data: Buffer | string, isBinary: boolean) => {
      // v3.160：node:ws 的 message data 对 text frame 也是 Buffer（不是
      // string）——旧代码 `typeof data === 'string'` 恒 false，text JSON 帧
      // 被误走 base64 编码、opcode 却仍标 1（text）。浏览器按 text 收到
      // base64 字符串 → JSON parse 失败 → SPA mux "invalid Remote stream
      // frame" close 4002 → workspace/session stream 全断（公网实测
      // workspace/follow 的 error 帧以 "eyJ..." 到达浏览器定位）。
      // 与 relay 侧上行（isBinary ? base64 : utf8）对齐成同语义。
      const opcode = isBinary ? 2 : 1
      const payload = isBinary
        ? Buffer.from(data as Buffer).toString('base64')
        : Buffer.from(data as Buffer).toString('utf8')
      if (payload.length > MAX_BODY) {
        ws.close(1009, 'payload too large')
        this.sendDataPlaneFrame({ v: 1, type: 'ws.close', id: msg.id, code: 1009, reason: 'payload too large' })
        return
      }
      this.sendDataPlaneFrame({ v: 1, type: 'ws.frame', id: msg.id, dir: 'down', opcode: opcode as 1 | 2, payload })
    })
    ws.on('close', (code: number, reason: Buffer) => {
      this.bridgedWs.delete(msg.id)
      this.sendDataPlaneFrame({ v: 1, type: 'ws.close', id: msg.id, code: code ?? 1000, reason: reason?.toString() ?? '' })
    })
    ws.on('error', (err: Error) => {
      this.sendDataPlaneFrame({ v: 1, type: 'error', id: msg.id, code: 'engine_down', message: err.message })
    })
  }

  // ---- config resolution: constructor field > env > default (per access) ----

  private resolvePublicHost(): string {
    if (this.config.publicHost) return this.config.publicHost;
    if (process.env.RELAY_PUBLIC_HOST) return process.env.RELAY_PUBLIC_HOST;
    // The authority the phone actually used — the engine must trust this host
    // (dsh --trusted-host) for bridged requests to pass its fence.
    return new URL(this.config.relayUrl).host;
  }

  private resolveUpstreamHost(): string {
    return this.config.upstreamHost ?? process.env.DSH_BIND_HOST ?? '127.0.0.1';
  }

  private resolveUpstreamPort(): number {
    return this.config.upstreamPort ?? (Number(process.env.DSH_BIND_PORT) || 3080);
  }

  private resolveEngineToken(): string {
    return this.config.engineToken ?? process.env.DSH_BIND_TOKEN ?? '';
  }

  private resolveTokenRewritePrefixes(): string[] {
    // Opt-in, no default: deployments that expose plugin-owned realtime WS
    // endpoints through the relay pass the prefix(es) explicitly (CLI flag or
    // plugin config). Baking a private deployment's route name here would make
    // this library carry a coupling it cannot honour for anyone else; an
    // unconfigured bridge simply never rewrites, which is the safe no-op.
    return this.config.tokenRewritePrefixes ?? [];
  }

  private sendDataPlaneFrame(frame: unknown): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return
    try { this.ws.send(JSON.stringify(frame)) } catch (err) {
      console.error('[dsh-remote-client] data plane send failed:', (err as Error).message)
    }
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, this.reconnectDelayMs);
  }

  /** v3.154：30s ping 保活 + 死链检测。ping 让 NAT 持续见到流量（半开
   * 防患），pong 缺席两周期说明对端/中间设备已死——terminate 立即触发
   * close 走重连，不再等 TCP 自身超时（默认可达 2h）。 */
  private startHeartbeat(socket: WebSocket) {
    this.stopHeartbeat();
    this.startIpWatch(socket);  // v3.188：NAT flap 探测（IP 变则 terminate）
    this.missedPongs = 0;
    this.heartbeatTimer = setInterval(() => {
      if (this.ws !== socket || socket.readyState !== WebSocket.OPEN) {
        this.stopHeartbeat();
        return;
      }
      if (this.missedPongs >= 2) {
        console.warn('[dsh-remote-client] wss heartbeat: dead tunnel (2 missed pongs), terminating for reconnect');
        socket.terminate();
        return;
      }
      this.missedPongs += 1;
      try { socket.ping(); } catch { /* close/terminate follows */ }
    }, 30_000);
  }

  private stopHeartbeat() {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    this.stopIpWatch();  // v3.188
    this.stopSessionAdoption();
  }

  // ------------------------------------------------------------------ //
  // 跨进程配对收养（CLI 多进程形态）。一次性 `pair` 命令在自己的进程里
  // 落盘配对 + 用自己的短命隧道注册；长跑的 `serve` 进程必须把这些配对
  // 收养进内存并经自己的活隧道补注册——否则 pair 进程退出后 relay 宽限
  // 窗口一过，配对 tombstone，扫码落地 fail-closed。连接期间每 2s 扫一
  // 次共享落盘文件，出现内存里没有的 sessionId 即收养 + register。
  // ------------------------------------------------------------------ //
  private adoptionTimer: NodeJS.Timeout | null = null;
  private static ADOPTION_INTERVAL_MS = 2_000;

  private startSessionAdoption(socket: WebSocket): void {
    this.stopSessionAdoption();
    if (!this.persistenceEnabled) return;
    this.adoptionTimer = setInterval(() => {
      if (this.ws !== socket || socket.readyState !== WebSocket.OPEN) {
        this.stopSessionAdoption();
        return;
      }
      for (const s of loadState(this.dataRootDir).sessions) {
        if (this.sessions.has(s.sessionId)) continue;
        this.sessions.set(s.sessionId, s);
        console.log(`[dsh-remote-client] adopted pairing ${s.sessionId} (minted by another process)`);
        this.registerSession(s.sessionId, s.pairingToken);
      }
    }, RemoteTunnelClient.ADOPTION_INTERVAL_MS);
  }

  private stopSessionAdoption(): void {
    if (this.adoptionTimer !== null) {
      clearInterval(this.adoptionTimer);
      this.adoptionTimer = null;
    }
  }


  // ------------------------------------------------------------------ //
  // v3.188：出网 IP 探测（防 NAT flap / ISP 双栈切换脑裂）
  //
  // 心跳/重连能发现对端已死，但**单端 NAT 切换**会让两端的 TCP 一边看 FIN
  // 一边还 ESTABLISHED（半开连接），plugin 的 heartbeat 要等 30s×2=60s 才能
  // 察觉，且这段时间里真消息都丢了（你看到「会话加载不出来」就是这个窗口）。
  //
  // 修法：每 60s HTTP 探测一次本机公网出口 IP（iPify/ip.sb/icanhazip 三个
  // endpoint 任一成功即可——多源冗余降级）。IP 变了立即 terminate 当前 socket，
  // close 走 scheduleReconnect 链走 `connect(true)` 重建，配套 dsh webserver 的
  // trusted-host 不需重配（hostname 不变只是 IP 变）。
  //
  // 探测失败两次/三轮=不主动 close（避免上游限流时误判；NAT flap 期间
  // 任何请求都可能瞬时 503）。失败的探测只记 audit，不动 socket。
  // ------------------------------------------------------------------ //
  private ipWatchTimer: NodeJS.Timeout | null = null;
  private lastSeenPublicIp: string | null = null;
  private ipProbeFailStreak = 0;
  private static IP_PROBE_INTERVAL_MS = 60_000;
  private static IP_PROBE_TIMEOUT_MS = 8_000;
  private static IP_PROBE_FAIL_TOLERANCE = 3;
  // 三个轻量公网 IP endpoint——任何 HTTPS 都能抓到纯文本 IP，JSON 没必要。
  // 选 iPify/ip.sb/icanhazip 是因为它们最少响应头、最少依赖第三方 JS、
  // curl 跑得通——v3.188 实测。
  private static IP_PROBE_ENDPOINTS = [
    'https://api.ipify.org',
    'https://api.ip.sb/ip',
    'https://icanhazip.com',
  ];

  private startIpWatch(socket: WebSocket): void {
    this.stopIpWatch();
    // 启动后 5s 首探（避免 connect 立即撞 iPify 限速），之后每 60s
    this.ipWatchTimer = setTimeout(() => {
      void this.probePublicIp(socket);
      this.ipWatchTimer = setInterval(() => {
        if (this.ws !== socket || socket.readyState !== WebSocket.OPEN) {
          this.stopIpWatch();
          return;
        }
        void this.probePublicIp(socket);
      }, RemoteTunnelClient.IP_PROBE_INTERVAL_MS);
    }, 5_000);
  }

  private stopIpWatch(): void {
    if (this.ipWatchTimer !== null) {
      clearTimeout(this.ipWatchTimer);
      clearInterval(this.ipWatchTimer);
      this.ipWatchTimer = null;
    }
  }

  private async probePublicIp(socket: WebSocket): Promise<void> {
    const ip = await this._fetchPublicIp();
    if (ip === null) {
      this.ipProbeFailStreak += 1;
      if (this.ipProbeFailStreak === RemoteTunnelClient.IP_PROBE_FAIL_TOLERANCE) {
        console.warn(`[dsh-remote-client] public IP probe: ${this.ipProbeFailStreak} 次连续失败（NAT flap 期间上游限流属正常，不强制 close socket）`);
        this.reportAudit(undefined, 'ip_probe_failing',
          `streak=${this.ipProbeFailStreak} (容忍期内,不动 socket)`);
      }
      return;
    }
    this.ipProbeFailStreak = 0;
    if (this.lastSeenPublicIp === null) {
      // 首次建立基准——NAT flap 后第一次探到就锁住，后续变了才触发
      this.lastSeenPublicIp = ip;
      console.log(`[dsh-remote-client] public IP baseline set: ${ip}`);
      return;
    }
    if (ip !== this.lastSeenPublicIp) {
      const oldIp = this.lastSeenPublicIp;
      this.lastSeenPublicIp = ip;
      console.warn(`[dsh-remote-client] public IP changed ${oldIp} → ${ip}（NAT flap / ISP 切换）；terminate tunnel for reconnect`);
      this.reportAudit(undefined, 'nat_flap_detected', `${oldIp} → ${ip}`);
      try { socket.terminate(); } catch { /* 已经关了 */ }
    }
  }

  private async _fetchPublicIp(): Promise<string | null> {
    // 不引 https 模块——Node 内置 fetch 18+ 自带，connector stdlib。
    // 单 endpoint 失败立即试下一个；任一返回纯 IP 就用。
    const validate = (s: string): string | null => {
      const v = s.trim();
      // 简单 IPv4 校验（避免 HTML 错误页伪装成 IP）
      return /^(\d{1,3}\.){3}\d{1,3}$/.test(v) ? v : null;
    };
    for (const ep of RemoteTunnelClient.IP_PROBE_ENDPOINTS) {
      try {
        const ac = new AbortController();
        const timer = setTimeout(
          () => { ac.abort(); },
          RemoteTunnelClient.IP_PROBE_TIMEOUT_MS);
        const r = await fetch(ep, {
          method: 'GET',
          signal: ac.signal,
          headers: { 'accept': 'text/plain' },
        });
        clearTimeout(timer);
        if (!r.ok) continue;
        const text = await r.text();
        const ip = validate(text);
        if (ip !== null) return ip;
      } catch { /* 下一源 */ }
    }
    return null;
  }
}
