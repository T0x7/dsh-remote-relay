import Fastify from 'fastify';
import fastifyRateLimit from '@fastify/rate-limit';
import fastifyHttpProxy from '@fastify/http-proxy';
import fastifyCookie from '@fastify/cookie';
import { WebSocket as WsBrowserSide, WebSocketServer as WsNoServer } from 'ws';
import type { Duplex } from 'node:stream';
import http from 'node:http';
import type { IncomingHttpHeaders, OutgoingHttpHeaders } from 'node:http';
import crypto from 'node:crypto';
import { URL, pathToFileURL } from 'node:url';
import path from 'node:path';
import { SessionManager } from './session.js';
import { SessionStore } from './store.js';
import { RelayAuditLogger } from './audit.js';
import { createLogger, type RelayLogger } from './logger.js';
import { loadConfig, assertProductionConfig, resolvePsk, DEFAULT_INSECURE_PSK, parseWsBridgePaths } from './config.js';
import type { RegisterSessionPayload, RevokeSessionPayload } from './protocol.js';
import { createHmac, timingSafeEqual } from 'node:crypto';

const DEFAULT_DSH_UPSTREAM = 'http://127.0.0.1:3080';
const SESSION_COOKIE_NAME = 'dsh_remote_session';
// v3.203：/__pair 着陆端点退役（根路径 / 是唯一着陆入口，见根路径闸门）。
// v3.184：独立过期页——已加载 SPA 的 401 连击看门狗（plugin client 注入）在
// 判定凭证死亡后 location.replace 到这里。免闸门（本身就是错误页，无数据）。
const EXPIRED_LANDING_PATH = '/__expired';
const SESSION_COOKIE_MAX_AGE_SEC = 30 * 24 * 60 * 60; // 30 天

// 1×1 透明 ICO（ICO 头 + 1×1 32-bit BMP），70 字节常量；浏览器对任何站点
// 都会自动盲请求 /favicon.ico，dsh 仅发 favicon.svg，relay 自答 ICO 字节
// 即可消掉控制台 404 红字和未配对状态下的额外 401 探测。
const FAVICON_ICO_BYTES = Buffer.from([
  0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x18, 0x00,
  0x30, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x01, 0x00,
  0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
])

// v3.171/v3.176：根路径签名 URL 的边界常量（verifyRootLanding 使用）
//   SHARE_LINK_MAX_AGE_MS = 30 天（与 SESSION_COOKIE_MAX_AGE_SEC 同步；超过即拒）
//   SHARE_LINK_MAX_FUTURE_SKEW_MS = 5 分钟（mint 时间晚于 now 太多=时钟漂移/篡改）
const SHARE_LINK_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000
const SHARE_LINK_MAX_FUTURE_SKEW_MS = 5 * 60 * 1000

/**
 * D-111：唯一享受「过期凭证也能过闸门」待遇的路径。
 *
 * 精确匹配（不是前缀），否则 `/dsh-remote/url-session-something` 这类路径会跟着
 * 一起被放宽——口子必须窄到「只能铸出下一把钥匙」。
 */
const URL_SESSION_REARM_PATH = '/dsh-remote/url-session'

// v3.172：per-pairing cookie 命名空间化（Plan A：浏览器一窗口多 pairing）。
// cookie 名格式 `dsh_remote_session__<sessionId>`——同一浏览器可同时持有
// N 条 pairing cookie（每 pairing 一条），命名空间互不撞。
// X-Pairing-Id header 由 SPA 在每次 /api/* 请求时附上，relay 据此挑对应 cookie
// 转发到正确 plugin socket。详见 docs/decisions/2026-09-09-multi-device-pairing.md 决策 1.5。
// sessionId 字符集放宽到 [A-Za-z0-9_-]+ —与 session.ts rawSid 同步,既兼容
// plugin mintShareLink 生成的 hex sid,也兼容测试用可读 sid('sess_pair_ok' 等);
// 安全边界靠 256-bit pairingToken,不靠 sid 熵。
const SESSION_COOKIE_PREFIX = 'dsh_remote_session__'
const SESSION_COOKIE_PATTERN = /^dsh_remote_session__(sess_[A-Za-z0-9_-]+)$/
const PAIRING_ID_HEADER = 'x-pairing-id'

function pairingCookieName(sessionId: string): string {
  return `${SESSION_COOKIE_PREFIX}${sessionId}`
}

/** 从 cookie 名反解 sessionId；非法格式返回 null。 */
function parsePairingCookieName(name: string): string | null {
  const m = name.match(SESSION_COOKIE_PATTERN)
  return m ? m[1]! : null
}

/** 在一组 cookie 里挑出合法 pairing cookie。
 *  - `pairingIdHeader` 提供则精确匹配（多 cookie 场景下必传，防止路由到错的 pairing）
 *  - 未提供 + 仅 1 个候选 → 选它（兼容旧 SPA / 单 pairing）
 *  - 未提供 + 多个候选 → 按 `isValid` 过滤（v3.205.1），恰好一枚有效即选它
 *  - 0 候选 / 多枚均有效（无 header）→ null
 * 调用方需要再用 sessionManager.getSessionBySecret 验。 */
function pickPairingCookie(
  cookies: Record<string, string | undefined> | undefined,
  pairingIdHeader: string | string[] | undefined,
  isValid?: (sessionId: string, secret: string) => boolean,
): { sessionId: string; secret: string } | null {
  if (!cookies) return null
  const candidates: { sessionId: string; secret: string }[] = []
  for (const [name, value] of Object.entries(cookies)) {
    if (typeof value !== 'string' || value.length === 0) continue
    const sid = parsePairingCookieName(name)
    if (sid) candidates.push({ sessionId: sid, secret: value })
  }
  if (candidates.length === 0) return null
  if (pairingIdHeader) {
    // sessionId 是精确标识(区分大小写)——header 值必须与 cookie 名里的
    // sessionId 完全一致;不做 toLowerCase(会破坏含大写字母的自定义 sid)。
    const wanted = String(pairingIdHeader)
    return candidates.find(c => c.sessionId === wanted) ?? null
  }
  if (candidates.length === 1) return candidates[0]!
  // v3.205.1：浏览器长期使用会积累死 pairing cookie（旧会话 / 被轮换顶替的
  // secret），旧逻辑「多候选无 header 即拒」会让一枚陈年死 cookie 永久堵死
  // 新 cookie——用户实测：打开新链接即「远程会话已失效」。改为先按有效性
  // 过滤，恰好一枚有效即选它。v3.204 引擎级独占后同引擎同时至多一枚活
  // cookie；多枚「都有效」只剩跨引擎并存场景，维持需显式 x-pairing-id。
  if (isValid) {
    const valid = candidates.filter((c) => isValid(c.sessionId, c.secret))
    return valid.length === 1 ? valid[0]! : null
  }
  return null
}

/** v3.183：根路径着陆 query 验证（URL 会话路线，v3.176 QR 即此形态）。
 *
 * 字段白名单 + 长度白名单 + 时间窗 + HMAC 验签，拼接顺序 sid|exp|mid|t
 * （与 plugin computeShareLinkHash 相同）。不要求 token 字段——v3.176.2 起
 * 根路径链接不再带 token（dsh BrowserAuth 对 query 含 token 的 / 会 303 剥
 * query）。token-only 的旧式根路径链接由调用方按 pairingToken 校验兜底。 */
function verifyRootLanding(q: Record<string, unknown>, psk: string): { ok: true } | { ok: false; reason: string } {
  const sid = q.sessionId
  const hash = q.hash
  const t = q.t
  const exp = q.exp
  const mid = q.mid
  if (typeof sid !== 'string' || !/^sess_[A-Za-z0-9_-]+$/.test(sid)) return { ok: false, reason: 'bad sid' }
  if (typeof hash !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(hash)) return { ok: false, reason: 'bad hash' }
  if (typeof t !== 'string' || !/^[0-9]{1,20}$/.test(t)) return { ok: false, reason: 'bad t' }
  if (typeof exp !== 'string' || !/^[0-9]{1,20}$/.test(exp)) return { ok: false, reason: 'bad exp' }
  if (typeof mid !== 'string' || !/^[a-f0-9]{64}$/.test(mid)) return { ok: false, reason: 'bad mid' }
  const tMs = Number(t)
  const expMs = Number(exp)
  const now = Date.now()
  if (now > expMs) return { ok: false, reason: 'expired' }
  if (now - tMs > SHARE_LINK_MAX_AGE_MS) return { ok: false, reason: 'mint too old' }
  if (tMs - now > SHARE_LINK_MAX_FUTURE_SKEW_MS) return { ok: false, reason: 'mint in future' }
  const expected = createHmac('sha256', psk)
    .update([sid, expMs, mid, tMs].join('|'))
    .digest('base64url')
  const a = Buffer.from(expected)
  const b = Buffer.from(hash)
  if (a.length !== b.length || !timingSafeEqual(a, b)) return { ok: false, reason: 'bad signature' }
  return { ok: true }
}

/** v3.173：URL 会话 token 验证（第三条路——浏览器多设备，不依赖 cookie jar）。
 *
 * Bearer 格式:`Bearer <sid>.<exp>.<mid>.<t>.<hash>`
 *   - sid = sessionId(精确标识,含下划线无点)
 *   - exp = 过期时间戳 ms
 *   - mid = 设备指纹 sha256 hex(客户端 informational)
 *   - t   = mint 时间戳 ms
 *   - hash = base64url(HMAC-SHA256(psk, sid|exp|mid|t))——与 share-link 同一拼接顺序
 *
 * 与 verifyShareLink 完全同构,只是签名从 URL query 移到 Authorization header
 * (避免每个 /api 请求的 query 都带 token,缩小日志泄露面)。TTL 由 exp 承载,
 * 默认 24h(plugin mintUrlSession),可配。
 *
 * 返回 sessionId(验签 + 未过期 + session 存活)或 null。失败原因不入返回——
 * 由调用方记 audit(reason 在日志侧给出)。
 */
function verifyUrlSessionToken(auth: string, psk: string, sessionManager: SessionManager): string | null {
  const parts = auth.slice('Bearer '.length).split('.')
  if (parts.length !== 5) return null
  const [sid, exp, mid, t, hash] = parts as [string, string, string, string, string]
  if (!/^sess_[A-Za-z0-9_-]+$/.test(sid)) return null
  if (!/^[0-9]{1,20}$/.test(exp) || !/^[0-9]{1,20}$/.test(t)) return null
  if (!/^[a-f0-9]{64}$/.test(mid)) return null
  if (!/^[A-Za-z0-9_-]{43}$/.test(hash)) return null
  const now = Date.now()
  const tMs = Number(t)
  if (now > Number(exp)) return null
  if (now - tMs > SHARE_LINK_MAX_AGE_MS) return null // mint 太旧(防重放)
  if (tMs - now > SHARE_LINK_MAX_FUTURE_SKEW_MS) return null // mint 在未来(防时钟漂移)
  const expected = createHmac('sha256', psk)
    .update([sid, exp, mid, t].join('|'))
    .digest('base64url')
  const a = Buffer.from(expected)
  const b = Buffer.from(hash)
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null
  // session 存活(未撤销 / 未过期)
  if (!sessionManager.getSession(sid)) return null
  return sid
}

/**
 * D-111：只为**重铸凭证**这一个端点放宽「exp 已过」这一项。
 *
 * **为什么要有这个口子。** URL 会话的 TTL 只有 24h，App 靠「过期前 2h 续期」
 * 续命——也就是说**这把钥匙的寿命，取决于用户有没有恰好在第 22 小时打开过
 * App**。错过一次窗口就是终局：`_realMint`（App 侧 `session_scheduler.dart`）
 * 用**旧 bearer** 调 `GET /dsh-remote/url-session` 铸新链接，而闸门
 * [verifyUrlSessionToken] 第一条就是 `if (now > exp) return null`——**换钥匙的
 * 门要用旧钥匙开**，先有鸡还是先有蛋。
 *
 * 真机代价（小米 2109119BC）：一台没在正确时间打开过 App 的手机，凭证静静过期，
 * 控制台永远挂着「正在重连…」，而重连永远不会成功。
 *
 * **口子有多窄**（安全边界，务必保持）：
 * 1. 只对 `/dsh-remote/url-session` 生效——**铸不出任何业务数据**；
 * 2. 仍然要求签名正确（HMAC 比对在下面，一字不改）；
 * 3. 仍然要求 session 在 relay 侧存活（未撤销）；
 * 4. 仍然要求 mint 不老于 30 天 cap（和 `SHARE_LINK_MAX_AGE_MS` 同一条），
 *    所以**过了 30 天上限的凭证照样进不来**——这个口子是「续命」，不是「复活」；
 * 5. 铸出来的新 bearer 照旧 24h，走的仍是完整闸门。
 *
 * 换句话说：放宽的只有「过期 ≠ 立即失效」这一条，其余全部照旧。
 */
function verifyUrlSessionTokenForRearm(
  auth: string,
  psk: string,
  sessionManager: SessionManager,
): string | null {
  const parts = auth.slice('Bearer '.length).split('.')
  if (parts.length !== 5) return null
  const [sid, exp, mid, t, hash] = parts as [string, string, string, string, string]
  if (!/^sess_[A-Za-z0-9_-]+$/.test(sid)) return null
  if (!/^[0-9]{1,20}$/.test(exp) || !/^[0-9]{1,20}$/.test(t)) return null
  if (!/^[a-f0-9]{64}$/.test(mid)) return null
  if (!/^[A-Za-z0-9_-]{43}$/.test(hash)) return null
  const now = Date.now()
  const tMs = Number(t)
  // 唯一被放宽的：**没有** `if (now > Number(exp)) return null`。
  if (now - tMs > SHARE_LINK_MAX_AGE_MS) return null // 30 天 cap 照旧
  if (tMs - now > SHARE_LINK_MAX_FUTURE_SKEW_MS) return null // 时钟漂移照旧
  const expected = createHmac('sha256', psk)
    .update([sid, exp, mid, t].join('|'))
    .digest('base64url')
  const a = Buffer.from(expected)
  const b = Buffer.from(hash)
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null
  // 撤销 / 不存在 → 照旧拒。这个口子救的是「过期」，救不了「被吊销」。
  if (!sessionManager.getSession(sid)) return null
  return sid
}

/**
 * Paths that never require a session cookie: the liveness probe (documented
 * no-auth), the QR landing itself (it is how a phone EARNS the cookie), and
 * the dsh outbound tunnel (PSK-authenticated inside its own WS handler —
 * note @fastify/websocket routes upgrades through the fastify lifecycle, so
 * this exemption is what keeps the PSK gate the ONLY gate there).
 * Everything else — /api/*, plugin HTTP routes (any prefix), SPA assets —
 * requires a paired cookie. Before this set existed the gate only covered
 * /api/*, leaving e.g. POST <plugin-route>/<job>/run reachable by
 * anyone who knew the relay domain (dsh's Host fence passes the trusted
 * relay hostname by design).
 * v3.183：根路径 / 有自己的着陆闸门（见 onRequest hook 内）——签名 URL 会话
 * query 验签放行、已配对 cookie/Bearer 走公共流程，零凭证 → 独立「无权访问」
 * 页，SPA 壳不再对匿名访客下发。/assets/* 与 /plugins/* 仍免鉴权（公开构建
 * 产物，渲染不出页面）。
 */
// v3.156.1：'/auth' 进白名单——落地 → 302 → /auth 链上浏览器可能带旧
// secret cookie（Firefox 实测：轮换后的新 cookie 未随 302 发出），gate 拒
// 之则 dsh-auth 引擎 cookie 永远拿不到 → WS mux 401 → SPA 卡 connecting。
// /auth 自带 X-App-Token 闸（plugin 注入 engine token，dsh BrowserAuth 验证），
// 安全性不依赖 relay cookie，白名单不削弱防护。
const GATE_EXEMPT_PATHS = new Set(['/health', '/ws/dsh', '/__devices', '/auth', EXPIRED_LANDING_PATH, '/favicon.ico']);

/**
 * Engine-admin routes that must NEVER be reachable through this relay.
 *
 * WHY: the tunnel forwards a paired device's request verbatim to the engine's
 * loopback listener, so the engine cannot tell a phone from the local browser —
 * both arrive as 127.0.0.1, from the tunnel process. Anything the local admin
 * page can do is therefore remote-reachable too. Minting a pairing, revoking
 * EVERY pairing, and switching the tunnel are exactly the operations a device
 * must not perform on the machine it controls: each is self-inflicted denial of
 * service for every device on that engine.
 *
 * Read-only routes of the same plugin (`GET /dsh-remote/session` for status,
 * `GET /dsh-remote/url-session` for credential renewal) stay reachable — the
 * paired app depends on them (see app/lib/services/session_scheduler.dart and
 * machines_session_poller.dart). This list is the WRITE/lifecycle half only.
 *
 * Mirrored by `LOCAL_ADMIN_ROUTES` in plugin/src/index.ts. The tunnel stamps
 * `x-dsh-remote-tunnel` on every forwarded request and the plugin refuses those
 * routes when it sees that header, so the boundary survives a misconfigured
 * relay as well as a compromised one. Both sides pin their own list in specs;
 * changing one without the other is a security regression.
 */
const LOCAL_ADMIN_DENY: ReadonlySet<string> = new Set([
  'POST /dsh-remote/session',
  'DELETE /dsh-remote/session',
  'POST /dsh-remote/tunnel',
]);

/**
 * v3.200：/auth 的 sec-fetch-site 归一化（实测 Android Chrome 153，2026-10-02）。
 *
 * 手机扫码进 SPA 的固定动线是「外部 app 唤起浏览器 → 配对 URL → 302 /auth」。
 * 外部 app（相机 / adb intent）唤起的导航，按 Fetch 规范 initiator 是不透明
 * 来源，Chrome 因此标 `sec-fetch-site: cross-site`；而 dsh 引擎
 * BrowserAuth.mintCookieForTrustedHost 的 isTrustedApiRequest 无条件拒
 * cross-site 标记 → 引擎回 403 'forbidden' → 手机永久停在 /auth，引擎
 * trusted-host cookie 永远拿不到（这就是本仓 __devices 里那些从未 paired
 * 的历史 session 的来源）。
 *
 * v3.156.1 已把 /auth 放进 relay 侧 GATE_EXEMPT_PATHS，它的防护是 relay
 * 自己注入的 X-App-Token（手机伪造不了）；引擎侧那道 cross-site 闸在这条
 * 动线上是重复防护，却挡了正常流量。只在 /auth 剥掉该标记——其余路径原样
 * 透传，引擎 fence 对 /api/* 的纵深防御不受影响。
 */
function normalizeAuthFetchSite(headers: Record<string, string>, barePath: string): void {
  if (barePath !== '/auth') return
  delete headers['sec-fetch-site']
}

/** 错误卡片骨架：单客户端策略（2026-08-31）落地后，配对失败必须能区分
 * 原因——被其他设备使用 / 无效过期 / 已配对设备被顶替或断开，各自的
 * 处置动作不同（换码 vs 重扫 vs 到 Mac 上看状态）。 */
function errorCard(title: string, body: string): string {
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title}</title>
  <style>
    body { font-family: -apple-system, sans-serif; background: #121212; color: #e0e0e0;
           height: 100vh; display: flex; align-items: center; justify-content: center; padding: 24px; }
    .card { max-width: 360px; padding: 24px; border: 1px solid #b71c1c; border-radius: 12px;
            background: #1e1e1e; text-align: center; }
    h1 { font-size: 18px; margin: 0 0 12px; color: #e57373; }
    p { font-size: 14px; line-height: 1.6; color: #aaa; margin: 0 0 16px; white-space: pre-line; }
  </style>
</head>
<body>
  <div class="card">
    <h1>${title}</h1>
    <p>${body}</p>
  </div>
</body>
</html>`;
}

// 场景①：token 对不上会话（旧码 / 篡改 / 引擎重启后旧会话不存在）
const PAIR_INVALID_HTML = errorCard(
  '二维码无效或已过期',
  '二维码生成后有时效，且引擎/中继重启后旧码会失效。\n\n请到 Mac 的远程控制卡片刷新获取新二维码（无配对时刷新会自动出新码）。'
);
// 场景②：已配对设备的 cookie 失效（引擎离线超宽限 / 被新设备顶替 / 手动断开 / 超 30 天）
const PAIR_LANDING_ERROR_HTML = errorCard(
  '远程会话已失效',
  '本设备的配对已失效，可能原因：\n· 另一台设备刚用链接连接了这台 Mac（同时仅 1 台，新设备独占）\n· Mac 引擎离线超过宽限窗口（重启/睡眠后重连会轮换密钥）\n· Mac 上手动断开了中继\n· 超过 30 天有效期\n\n请到 Mac 的远程控制卡片重新生成二维码扫码。'
);
// 场景③（v3.183）：零凭证访问——裸域名 / 无任何配对凭证。独立「无权访问」页，
// SPA 壳不再下发（v3.173 曾对 / 整体免闸门，零凭证访客也能加载出 dsh 首屏
// "loading plugins" 画面，2026-09-11 公网实证）。
const NO_ACCESS_HTML = errorCard(
  '无权访问',
  '这是私有远程控制中继，仅限已配对设备使用。\n\n请在本地 dsh 端的「远程控制」卡片生成二维码，扫码后访问。'
);
// 场景④（v3.205）：设备被新设备顶替——着陆轮换时 relay 以 close(4001)
// 掐断旧设备事件流，SPA 收码即跳此页（实时踢人；90s 宽限只保在途请求）。
const DEVICE_REPLACED_HTML = errorCard(
  '已在另一台设备连接',
  '这台 Mac 同时仅允许 1 台设备在线，你的会话已被新连接的设备顶替。\n\n如需继续使用，请到 Mac 的远程控制卡片重新生成二维码扫码（会顶替对方）。'
);

function parseUpstreamHost(upstream: string) {
  const url = new URL(upstream);
  return {
    hostname: url.hostname,
    port: url.port || (url.protocol === 'https:' ? '443' : '80'),
  };
}

/**
 * Client IP for the bare-upgrade paths (no fastify lifecycle, hence no req.ip).
 *
 * v3.282: these handlers read X-Forwarded-For unconditionally, so any client
 * could set the header and forge its IP into audit records and rate-limit
 * buckets — the per-IP PSK brute-force alarm could never fire. XFF is now
 * honoured only when the DIRECT peer is a configured proxy; fastify's own
 * `req.ip` keeps the same rule on the HTTP paths.
 *
 * Exact-IP match by design: the default trust list is the local nginx hop
 * (`127.0.0.1,::1`); deployments with docker-network hops list the exact
 * container IP in RELAY_TRUST_PROXY.
 */
export function resolveClientIp(remoteAddress: string | undefined, xffHeader: string | undefined, trustedProxiesCsv: string): string {
  const direct = remoteAddress || 'unknown';
  const trusted = trustedProxiesCsv.split(',').map((entry) => entry.trim()).filter(Boolean);
  if (!trusted.includes(direct)) return direct;
  const firstHop = xffHeader?.split(',')[0]?.trim();
  return firstHop || direct;
}

/** Which proxy IPs XFF may come from (same list fastify's trustProxy uses). */
let trustProxyCsv = '127.0.0.1,::1';

/**
 * Audit-safe cookie fingerprint: how many cookies and how long each value is.
 *
 * v3.282: the old fingerprint sliced the first 36 bytes of the header into
 * audit details — pino redacts `cookie` on the log path, but the SQLite audit
 * store is a different sink and kept the prefix forever. Cookie values ARE
 * bearer credentials; only their shape belongs in an audit trail.
 */
export function cookieFingerprint(cookieHeader: string | undefined): string {
  if (!cookieHeader) return 'NONE';
  const parts = cookieHeader.split(';').map((part) => {
    const eq = part.indexOf('=');
    const name = (eq === -1 ? part : part.slice(0, eq)).trim();
    const valueLen = eq === -1 ? 0 : part.length - eq - 1;
    return `${name || '?'}:len=${valueLen}`;
  });
  return `${parts.length}条 ${parts.join(',')}`;
}

/** Constant-time secret comparison — the PSK check is remotely reachable. */
function secretEquals(a: string, b: string): boolean {
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  return bufA.length === b.length && bufA.length === bufB.length && crypto.timingSafeEqual(bufA, bufB);
}

export interface BuildServerOptions {
  psk?: string;
  dbPath?: string;
  stateDbPath?: string;
  upstream?: string;
  /**
   * Authority dsh should see on relayed requests (RELAY_PUBLIC_HOST). dsh's
   * Host fence classifies requests by this header: the 16 PRIVILEGED methods
   * pass only for loopback authorities. @fastify/http-proxy rewrites Host to
   * the upstream (127.0.0.1:3080) by default — presenting every relayed
   * request as loopback and unlocking PRIVILEGED remotely — so the relay
   * refuses to build without an explicit pin. Must match a dsh
   * --trusted-host entry.
   */
  publicHost?: string;
  /** CSV of proxy IPs/CIDRs for X-Forwarded-For trust (fastify trustProxy). */
  trustProxy?: string;
  /**
   * Extra absolute WebSocket paths (beyond /api/events.* and /api/remote.mux)
   * whose upgrades are bridged to the engine (RELAY_WS_BRIDGE_PATHS CSV).
   * Deployments that expose plugin-owned realtime streams list them here;
   * default is none.
   */
  wsBridgePaths?: string[];
  sessionGraceMs?: number;
  sessionMaxAgeMs?: number;
  logger?: RelayLogger;
}

export async function buildServer(options: BuildServerOptions = {}) {
  // The fallback MUST be the shared config constant, never a second
  // hardcoded literal: assertProductionConfig() compares against
  // DEFAULT_INSECURE_PSK, so a divergent literal here would let a
  // default-PSK boot slip past the production guard in any refactor
  // that routes startup through buildServer().
  const psk = options.psk || process.env.RELAY_PSK || DEFAULT_INSECURE_PSK;
  // Fail-closed: without a pinned public Host the proxy layer would present
  // relayed requests to dsh as loopback (unlocking the 16 PRIVILEGED
  // methods). See config.ts for the full rationale.
  const publicHost = options.publicHost || process.env.RELAY_PUBLIC_HOST || '';
  if (!publicHost) {
    throw new Error('buildServer: publicHost is required (RELAY_PUBLIC_HOST) — the proxy must pin the Host dsh sees, or PRIVILEGED methods unlock remotely');
  }
  // Injectable for tests — they must point at a dead port so an accidentally
  // running local dsh never receives proxied traffic from test cases.
  const dshUpstream = options.upstream || process.env.DSH_UPSTREAM || DEFAULT_DSH_UPSTREAM;
  // Extra WS upgrade paths to bridge (plugin-owned realtime streams).
  const wsBridgePaths = options.wsBridgePaths ?? parseWsBridgePaths(process.env.RELAY_WS_BRIDGE_PATHS);
  const logger = options.logger ?? createLogger();
  // v3.282：裸 upgrade 路径与 fastify 共用同一份信任名单。
  trustProxyCsv = options.trustProxy || process.env.RELAY_TRUST_PROXY || '127.0.0.1,::1';
  const fastify = Fastify({
    logger: false,
    // v3.282：显式 4MB——此前靠默认 1MB 兜底，与隧道数据面 MAX_REQ_BODY
    // (4MiB) 不一致：本机直连引擎放行的请求体经 relay 会被 413。
    bodyLimit: 4 * 1024 * 1024,
    // Only the nginx hop (default loopback; docker deployments set the nginx
    // container IP). trustProxy:true would let any client spoof
    // X-Forwarded-For — bypassing the per-IP rate limit and forging audit IPs.
    trustProxy: trustProxyCsv,
  });

  const auditLogger = new RelayAuditLogger(options.dbPath);
  const sessionManager = new SessionManager({
    graceMs: options.sessionGraceMs,
    maxAgeMs: options.sessionMaxAgeMs,
    store: new SessionStore(options.stateDbPath),
  });

  /** v3.205.1：pairing cookie 有效性判据（死 cookie 过滤）——secret 能定位到
   *  活会话（含 90s 轮换宽限）且 sessionId 一致，防串号。 */
  const isValidPairingCookie = (sid: string, secret: string): boolean =>
    sessionManager.getSessionBySecret(secret)?.sessionId === sid;

  // 1. 速率限制（防暴力扫描/反代被刷）。上限取 300/min：dsh SPA 首屏的静态
  //    资源脉冲（数打请求）+ API 突发必须过得去，同时仍挡住无脑刷请求。
  fastify.register(fastifyRateLimit, {
    max: 300,
    timeWindow: '1 minute',
    errorResponseBuilder: (req, context) => {
      auditLogger.log({
        eventType: 'rate_limit_exceeded',
        ip: req.ip,
        userAgent: req.headers['user-agent'],
        details: `Max: ${context.max}, Window: ${context.after}`,
      });
      logger.warn({ ip: req.ip, url: req.url }, 'rate_limit_exceeded');
      return {
        statusCode: 429,
        error: 'Too Many Requests',
        message: 'Rate limit exceeded, please retry later.',
      };
    },
  });

  // 2. WebSocket 插件（保留用于 /ws/dsh 出站通道）——v3.152.4 PR-WS-bridge
  // 后这个 plugin 不再注册（@fastify/websocket 会装全局 upgrade listener
  // 抢在我们总 handler 之前 destroy 不在 ws 路由表里的 socket，如 /api/events.*）。
  // /ws/dsh 改用裸 WebSocketServer（见 buildServer 顶部的 wsTunnelServer）。

  // 3. Cookie 解析（用于扫码后的 sessionSecret 校验）
  fastify.register(fastifyCookie, { secret: psk });

  // 设备在线判据的活跃 WS 计数表（/__devices 与 __pair 着陆拦截共用）：
  // sessionId → 活跃 /api/events.* WS 连接数，upgrade 成功 +1、双侧 close -1。
  // v3.152.3：暴露给单测注入 stream 计数——此前用 lastSeen 触发拦截，
  // 实际把 Mac 本机 engine 自己的过闸请求误当设备在线（用户开 App 看
  // 「已有设备在线」二维码不可用）。改后只用 liveStreams > 0 判在线。
  const liveStreams = new Map<string, number>();
  const _markStreamActive = (sessionId: string): void => {
    liveStreams.set(sessionId, (liveStreams.get(sessionId) ?? 0) + 1)
  }
  const _markStreamInactive = (sessionId: string): void => {
    const n = (liveStreams.get(sessionId) ?? 1) - 1
    if (n > 0) liveStreams.set(sessionId, n)
    else liveStreams.delete(sessionId)
  }
  // 在线信标窗口：过闸请求（lastSeen）在此窗口内视为设备在线
  const ONLINE_BEACON_MS = 60_000;

  // 4. 健康检查
  fastify.get('/health', async () => ({ status: 'ok', time: Date.now() }));

  // 4b. /favicon.ico：浏览器盲探针自答。dsh 只发 favicon.svg，relay 直返
  //     1×1 透明 ICO 字节（70 字节常量），免去未配对状态下的额外 401 探测
  //     和浏览器控制台 404 红字。公开产物性质，cache-control 24h。
  fastify.get('/favicon.ico', async (_req, reply) => {
    return reply
      .header('cache-control', 'public, max-age=86400')
      .type('image/x-icon')
      .send(FAVICON_ICO_BYTES)
  })

  // 4a. v3.184：独立过期页（免闸门）。plugin client 的 401 连击看门狗在凭证
  //     死亡后 location.replace 到这里。按浏览器是否带着 pairing cookie 选卡：
  //     URL 会话路线（无 cookie）→「二维码无效或已过期」（链接 24h exp 到期，
  //     重新扫码）；cookie 路线（cookie 在但已失效）→「远程会话已失效」。
  //     无论哪种，都绝不会进到 dsh 页面。
  fastify.get(EXPIRED_LANDING_PATH, async (req, reply) => {
    const hasPairingCookie = Object.entries(req.cookies ?? {})
      .some(([name, value]) => typeof value === 'string' && value.length > 0 && parsePairingCookieName(name) !== null)
    const wantsHtml = (req.headers.accept ?? '').includes('text/html')
    // v3.205：?reason=replaced——实时踢人路径（WS close 4001 → SPA 跳转带此参），
    // 专属「已在另一台设备连接」卡；其余沿用按 cookie 选卡逻辑。
    const isReplaced = (req.query as { reason?: string }).reason === 'replaced'
    const card = isReplaced ? DEVICE_REPLACED_HTML : hasPairingCookie ? PAIR_LANDING_ERROR_HTML : PAIR_INVALID_HTML
    if (wantsHtml) {
      return reply.code(401).header('cache-control', 'no-store').type('text/html; charset=utf-8').send(card)
    }
    return reply.code(401).header('cache-control', 'no-store').send({
      error: isReplaced ? 'device replaced' : 'remote session expired',
      hint: 're-scan the QR code on the dsh host, or re-open the original share link',
    })
  })

  // 5. (v3.203) /__pair 着陆端点已退役——根路径 / 是唯一着陆入口（签名
  //    query 验证 + pairing cookie 颁发 + /auth 跳板都在 onRequest 根路径
  //    闸门里完成，见下文「根路径着陆闸门」）。旧 share-link（30 分钟 TTL）
  //    早已全部自然过期，无兼容存量；相关 verifyShareLink / PAIR_ONLINE_HTML
  //    / 在线拦截 / 着陆轮换密钥逻辑一并移除。
  //    ADR: docs/decisions/2026-09-15-relay-pair-retirement.md

  // 6. Session-cookie gate: ALL paths except GATE_EXEMPT_PATHS (liveness +
  //    QR landing). Two failure shapes:
  //    - /api/* → 401 JSON. SPA fetch does not follow redirects, and a 302 to
  //      the landing page would make response.json() throw SyntaxError — 401
  //      gives the SPA's !response.ok branch a readable transport failure.
  //    - everything else (browser navigation, plugin routes, assets) → 401
  //      with the HTML error card when the caller accepts HTML (phones that
  //      lost their cookie get an actionable page instead of a broken SPA),
  //      JSON otherwise.
  fastify.addHook('onRequest', async (req, reply) => {
    const path = (req.url ?? '').split('?')[0]!;
    // v3.282 engine-admin boundary. Checked FIRST — before every exemption —
    // so no future GATE_EXEMPT_PATHS entry can widen it by accident.
    if (LOCAL_ADMIN_DENY.has(`${req.method} ${path}`)) {
      auditLogger.log({
        sessionId: '',
        eventType: 'remote_admin_blocked',
        ip: req.ip,
        userAgent: req.headers['user-agent'],
        details: `${req.method} ${path} refused to a paired device (engine-admin boundary)`,
      });
      return reply.code(403).header('cache-control', 'no-store').send({
        error: 'engine admin route is not reachable from a paired device',
        hint: 'pairing, revocation and tunnel control live on the dsh host only',
      });
    }
    if (GATE_EXEMPT_PATHS.has(path)) return;

    // v3.173→v3.183：/assets/* 与 /plugins/* 维持免鉴权——script/link 标签
    // 带不了 Authorization header，URL 会话路线又不颁 cookie，不豁免则 SPA
    // bootstrap 脚本 401（"HTML did not preload dsh-client-modules/client.js"）；
    // 两者是 dsh 公开构建产物，单独拿到渲染不出任何页面。
    // **根路径 / 不再免鉴权**（v3.183）：v3.173 的豁免让零凭证访客也能加载
    // 出 dsh SPA 壳（公网裸域名直接出现 "loading plugins" 首屏，2026-09-11
    // 实证——plugin 的 v3.176 引擎 cookie 注入会替任何被转发的请求过掉 dsh
    // BrowserAuth，dsh 侧第二道闸对中继流量失效）。改为根路径着陆闸门（下），
    // 零凭证/失效凭证一律独立错误页，SPA 壳不下发。
    if (path.startsWith('/assets/') || path.startsWith('/plugins/')) return;

    // v3.183：根路径着陆闸门。三类放行：
    //   ① 签名 URL 会话 query（v3.176 QR 形态 ?sessionId&hash&t&exp&mid）——
    //      verifyRootLanding 验签 + session 存活；
    //   ② 旧格式 ?sessionId&token（无签名族字段）——按 pairingToken 校验；
    //   ③ 无 query → 落入下方 Bearer / pairing cookie 公共流程（已配对设备
    //      直达主页的既有路径）。
    // ①② 过检后走统一着陆动作：颁 pairing cookie + 302 /auth 跳板（v3.203
    // 起 /__pair 退役，这里是唯一着陆入口）。其余（过期签名 / 坏 token /
    // 未知 session）→ 401 独立过期卡，不进 dsh。
    if (path === '/') {
      const q = req.query as Record<string, unknown>
      const hasPairingQuery = Boolean(q.sessionId || q.token || q.hash || q.t || q.exp || q.mid)
      if (hasPairingQuery) {
        const sid = typeof q.sessionId === 'string' ? q.sessionId : ''
        const isSigned = Boolean(q.hash || q.t || q.exp || q.mid)
        let reason = ''
        if (isSigned) {
          const v = verifyRootLanding(q, psk)
          if (!v.ok) reason = v.reason
          else if (!sessionManager.getSession(sid)) reason = 'session not found'
        } else {
          const session = typeof q.token === 'string' ? sessionManager.getSessionByToken(q.token) : undefined
          if (!session) reason = 'bad pairing token'
          else if (session.sessionId !== sid) reason = 'sid mismatch'
        }
        if (reason) {
          auditLogger.log({
            sessionId: sid,
            eventType: 'root_landing_failed',
            ip: req.ip,
            userAgent: req.headers['user-agent'],
            // v3.203 audit 脱敏（承 v3.171 /__pair 语义，v3.183 迁移根路径时
            // 意外丢失）：失败 URL 的 query 可能携带完整签名族字段，hash/mid
            // 值只留前 8 字符指纹再落库，防审计库/备份泄露可重放的签名材料。
            details: `${(req.url ?? '')
              .replace(/([?&](?:hash|mid)=)([A-Za-z0-9_-]{8})[A-Za-z0-9_-]*/g, '$1$2…')
              .slice(0, 200)} reason=${reason}`,
          })
          logger.warn({ ip: req.ip, sessionId: sid, reason }, 'root_landing_failed')
          return reply.code(401).type('text/html; charset=utf-8').send(PAIR_INVALID_HTML)
        }
        // 着陆放行：按引擎轮换密钥 → 颁 pairing cookie → 跳 /auth 让 dsh
        // BrowserAuth 颁引擎 cookie——后续 GET / 需要两枚 cookie 同时在场
        // （relay 闸门认 dsh_remote_session__<sid>，dsh 认 dsh-auth-*）。
        // v3.176 根路径 URL 会话起此即主链路；/__pair 着陆端点 v3.203 退役
        // 后这里是唯一着陆入口（history：本段曾以「v3.199.3+ patch」线上
        // 热修形态存在，2026-09-15 回填仓库）。
        // v3.204 单浏览器独占（按引擎，用户拍板）：着陆即轮换同引擎全部
        // pairing 的 sessionSecret——旧设备进入 90s previousSecret 宽限，
        // 宽限一过被顶下线（401 看门狗跳「远程会话已失效」页）。
        const landed = sessionManager.getSession(sid)
        sessionManager.markSeen(sid, req.ip)
        if (landed) {
          landed.pairedAt = landed.pairedAt ?? Date.now()
          const rotated = sessionManager.rotateAllOnSocket(landed.dshSocket, sid)
          if (rotated === undefined) {
            return reply.code(401).type('text/html; charset=utf-8').send(PAIR_INVALID_HTML)
          }
          auditLogger.log({
            sessionId: sid,
            eventType: 'landing_secret_rotated',
            ip: req.ip,
            userAgent: req.headers['user-agent'],
            details: `engine-wide rotation rotated=${rotated.rotated} target=${sid}`,
          })
          // v3.205 实时踢人：以 close(4001, 'device_replaced') 掐断所有用被顶替
          // 旧 secret 授权的浏览器事件流——SPA（plugin client 注入的看门狗）
          // 收码即跳「已在另一台设备连接」页，不再等 90s 宽限后的 401 轮询。
          // 90s previousSecret 宽限照旧保留（保护 B 的着陆链路竞态 + A 在途
          // HTTP）；A 的可见退出即时发生。dropStream 幂等，浏览器侧 close
          // handler 的清账兜底。
          let evictedStreams = 0
          for (const [id, bridged] of [...wssBridgedWs.entries()]) {
            if (rotated.evictedSecrets.includes(bridged.authorizedSecret)) {
              wssBridgedWs.delete(id)
              bridged.dropStream()
              try { bridged.ws.close(4001, 'device_replaced') } catch { /* already closing */ }
              evictedStreams++
            }
          }
          if (evictedStreams > 0) {
            auditLogger.log({
              sessionId: sid,
              eventType: 'device_replaced_streams_closed',
              ip: req.ip,
              details: `closed=${evictedStreams}`,
            })
          }
          reply.setCookie(pairingCookieName(sid), rotated.secret, {
            httpOnly: true,
            secure: true,
            // Lax（v3.128.2.1 语义，承自 /__pair）：扫码器跨应用拉起浏览器
            // 打开链接是 Lax 的设计场景；Strict 在部分移动浏览器对着陆→
            // 302→/ 链路的 cookie 携带不可靠。
            sameSite: 'lax',
            maxAge: SESSION_COOKIE_MAX_AGE_SEC,
            path: '/',
          })
        }
        const fwdProto = typeof req.headers['x-forwarded-proto'] === 'string' ? req.headers['x-forwarded-proto'] : 'http'
        const nextUrl = new URL(req.url ?? '/', `${fwdProto}://${req.headers.host ?? 'localhost'}`).toString()
        return reply.redirect(`/auth?next=${encodeURIComponent(nextUrl)}`, 302)
      }
      // 无 query：不提前 return，落入下方 Bearer / cookie 公共闸门
    }

    // v3.173 URL 会话 token(第三条路)——Authorization: Bearer <sid>.<exp>.<mid>.<t>.<hash>
    // 浏览器多设备场景:SPA 从 URL 读 sessionId+token 注入 header,gate 直接验,
    // 不依赖 cookie jar。验不过 → 401(显式带 Bearer = 客户端选了会话模式,不回退 cookie)。
    const auth = req.headers.authorization;
    if (typeof auth === 'string' && auth.startsWith('Bearer ')) {
      const sessionId = verifyUrlSessionToken(auth, psk, sessionManager);
      if (sessionId) {
        (req as unknown as { urlSessionId?: string }).urlSessionId = sessionId;
        sessionManager.markSeen(sessionId, req.ip);
        return;
      }
      // D-111：exp 过了但签名对、session 还在、30 天 cap 未到 → 只放行「重铸凭证」
      // 这一个端点。path 精确匹配，其它一切（含全部数据面）照旧 401。
      if (path === URL_SESSION_REARM_PATH) {
        const rearmId = verifyUrlSessionTokenForRearm(auth, psk, sessionManager);
        if (rearmId) {
          (req as unknown as { urlSessionId?: string }).urlSessionId = rearmId;
          sessionManager.markSeen(rearmId, req.ip);
          auditLogger.log({
            eventType: 'api_auth_url_session_rearm',
            ip: req.ip,
            userAgent: req.headers['user-agent'],
            details: `${path} expired-token rearm for sid=${rearmId}`,
          });
          logger.info({ sid: rearmId }, 'url_session_rearm_expired_token_allowed');
          return;
        }
      }
      auditLogger.log({
        eventType: 'api_auth_missing',
        ip: req.ip,
        userAgent: req.headers['user-agent'],
        details: `${path} url-session-token: sid=${auth.slice(7, 7 + 24)}… invalid`,
      });
      logger.warn({ ip: req.ip, method: req.method, url: req.url }, 'api_auth_missing_url_session');
      const wantsHtml = (req.headers.accept ?? '').includes('text/html');
      if (!path.startsWith('/api/') && wantsHtml) {
        return reply.code(401).type('text/html; charset=utf-8').send(PAIR_LANDING_ERROR_HTML);
      }
      return reply.code(401).send({
        error: 'remote session expired or missing',
        hint: 're-open the original share link to re-authenticate',
      });
    }

    // v3.172 Plan A：从命名空间化 cookie 挑合法 pairing——
    // X-Pairing-Id 缺省时按唯一性自动选，多 cookie 场景下 SPA 必须显式传。
    const pairing = pickPairingCookie(req.cookies, req.headers[PAIRING_ID_HEADER], isValidPairingCookie)
    const match = pairing ? sessionManager.authenticateSecret(pairing.secret) : undefined
    const session = match?.session
    if (!session || !pairing || session.sessionId !== pairing.sessionId) {
      const isApi = path.startsWith('/api/');
      // v3.128.2.1 观测：闸门拒绝时记录实际收到的 cookie 指纹（截断），
      // 区分「完全没带」「带了旧值」——着陆成功同秒被拒的定位依赖它
      const cookieHdr = String(req.headers.cookie ?? '');
      // v3.282：指纹只记名字与值长度——值本身是 bearer 凭证，pino 的 redact
      // 管不到 SQLite 审计库。
      const cookieFp = cookieFingerprint(req.headers.cookie as string | undefined);
      auditLogger.log({
        eventType: isApi ? 'api_auth_missing' : 'gate_auth_missing',
        ip: req.ip,
        userAgent: req.headers['user-agent'],
        details: `${path} cookie=${cookieFp}`,
      });
      logger.warn({ ip: req.ip, method: req.method, url: req.url, cookie: cookieFp }, isApi ? 'api_auth_missing' : 'gate_auth_missing');
      const wantsHtml = (req.headers.accept ?? '').includes('text/html');
      if (!isApi && wantsHtml) {
        // v3.183：零凭证（连 cookie 头都没有）→「无权访问」页；带了 cookie
        // 但验不过（旧值/被顶替/超期）→ 既有「远程会话已失效」页。两者都不
        // 再放行到 dsh。
        return reply.code(401).type('text/html; charset=utf-8').send(cookieHdr ? PAIR_LANDING_ERROR_HTML : NO_ACCESS_HTML);
      }
      return reply.code(401).send({
        error: 'remote session expired or missing',
        hint: 're-scan the QR code on the dsh host to re-pair',
      });
    }

    // v3.282：宽限期内被顶替的旧 cookie 只够「着陆」——拿到那一次重定向，
    // 让浏览器换上轮换后的新 cookie 继续走完链路。它不再拥有数据面读写权：
    // 此前 90 秒里旧设备仍可读全部会话、执行命令，而界面早已显示它被踢下线。
    if (match?.level === 'landing' && !(req.method === 'GET' && path === '/')) {
      auditLogger.log({
        sessionId: session.sessionId,
        eventType: 'landing_grace_scope_refused',
        ip: req.ip,
        userAgent: req.headers['user-agent'],
        details: `${req.method} ${path} refused: replaced device holds a grace-window cookie`,
      })
      logger.warn({ sid: session.sessionId, method: req.method, url: req.url }, 'landing_grace_scope_refused')
      const wantsHtml = (req.headers.accept ?? '').includes('text/html')
      if (wantsHtml) {
        return reply.code(403).type('text/html; charset=utf-8').send(DEVICE_REPLACED_HTML)
      }
      return reply.code(403).send({
        error: 'this pairing was replaced on another device',
        hint: 'continue on the device that landed last',
      })
    }

    // v3.128.1：带 cookie 过闸 = 设备真正连接（幂等首次打点，消费配对
    // token）。
    sessionManager.markConnected(session.sessionId);

    // v3.161：per-session 速率限制——60 req/min。trusted-host 闸白名单让
    // 配对设备能调任意插件路由（v3.156），没有限速就会被自动化
    // 滥用（刷插件 job、刷 sessions.archive 等）。onRequest 是每条闸
    // 过请求必经点——单点拦截；超过 60/min 直接 429 + audit。
    const RATE_LIMIT_PER_MIN = 60
    const count = sessionManager.markRequest(session.sessionId)
    if (count > RATE_LIMIT_PER_MIN) {
      auditLogger.log({
        sessionId: session.sessionId,
        eventType: 'session_rate_limit_exceeded',
        ip: req.ip,
        userAgent: req.headers['user-agent'],
        details: `count=${count} limit=${RATE_LIMIT_PER_MIN}/min`,
      })
      logger.warn({ sessionId: session.sessionId, ip: req.ip, count }, 'session_rate_limit_exceeded')
      return reply.code(429).type('application/json').send({
        error: 'rate limit exceeded for this pairing session',
        limit: RATE_LIMIT_PER_MIN,
        windowSeconds: 60,
        hint: 'slow down or re-pair to reset',
      })
    }

    // /api/events.* 的 WS upgrade 由本文件尾部的裸 server 'upgrade' 转发器
    // 独占（101 + raw pipe）。@fastify/websocket 会把同一 upgrade 事件再送
    // 进 fastify 路由（fastify.routing → 命中兜底反代按普通请求处理 →
    // onResponse 钩子 destroy socket）——两路写同一 socket，101 后毫秒级被
    // 硬断（2026-08-31 公网实证：SPA 事件流 11s 循环重连、0.1s close 1005）。
    // hijack 掉路由侧；配对校验已在上面完成，未配对仍 401。
    if (
      path.startsWith('/api/events.') &&
      (req.headers.upgrade ?? '').toLowerCase() === 'websocket'
    ) {
      reply.hijack();
      return;
    }

    if (path.startsWith('/api/')) {
      auditLogger.log({
        sessionId: session.sessionId,
        eventType: 'api_request_relayed',
        ip: req.ip,
        userAgent: req.headers['user-agent'],
        details: path,
      });
    }

    // 设备活跃信标（transient）：/__devices 的在线判据之一；v3.128.4 附带
    // 客户端 IP（fastify trustProxy 已配置，req.ip 即 nginx 转发的真实公网 IP）
    sessionManager.markSeen(session.sessionId, req.ip);
  });

  // 6a. 设备在线列表（PSK 鉴权，供 dsh 插件侧卡片轮询）：
  //     在线判据 = 活跃 /api/events.* WS 连接 > 0，或 60s 内有过闸请求。
  //     与隧道同源的 PSK（Bearer），不进 cookie 闸门（GATE_EXEMPT）。
  fastify.get('/__devices', async (req, reply) => {
    const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    if (!token || !secretEquals(token, psk)) {
      auditLogger.log({
        eventType: 'devices_auth_failed',
        ip: req.ip,
        userAgent: req.headers['user-agent'],
      });
      return reply.code(401).send({ error: 'invalid or missing PSK' });
    }
    const now = Date.now();
    const devices = sessionManager.listSessions().map((s) => {
      const ws = liveStreams.get(s.sessionId) ?? 0;
      const fresh = s.lastSeen !== undefined && now - s.lastSeen < ONLINE_BEACON_MS;
      return {
        sessionId: s.sessionId,
        createdAt: s.createdAt,
        lastSeen: s.lastSeen ?? null,
        /** v3.128.4：最近过闸请求的客户端公网 IP（Mac 卡片展示「谁连着」；
         * 落地形态为内存态，relay 重启后首条请求重建）。 */
        ip: s.lastSeenIp ?? null,
        onlineWs: ws,
        online: ws > 0 || fresh,
        paired: s.pairedAt != null,
      };
    });
    return { devices };
  });

  // 7+8. 反向代理（/api/* 与其余 SPA 路径）→ dsh host。
  //    Host 钉扎：@fastify/http-proxy 底层的 reply-from 无条件执行
  //    headers.host = <upstream host>（即 127.0.0.1:3080）——那会让 dsh 把
  //    所有中继请求当作 loopback，16 个 PRIVILEGED 方法全部解锁。这里用
  //    rewriteRequestHeaders（在 reply-from 改写之后应用）把 Host 钉回
  //    RELAY_PUBLIC_HOST，dsh fence 按这个值判定：基础 /api 放行
  //    （trusted-host），PRIVILEGED 保持 403。
  // X-App-Token 注入：v3.41 lockdown 后引擎要求所有请求带 token（relay
  // 设计早于 lockdown——手机/浏览器不可能知道轮换值）。插件在 dsh 进程内
  // 读 DSH_BIND_TOKEN，随 session.register 经 PSK 隧道送达，此处注入转发
  // 头。客户端自带的 x-app-token 一律覆盖/剥除（值只有引擎与 relay 知道，
  // 注入的 Host 钉扎请求仍按 RELAY_PUBLIC_HOST 判定，PRIVILEGED 照旧被 fence
  // 挡在 403——token 注入不会放大远程能力）。
  // v3.200：同 WSS 数据面——/auth 的 cross-site 标记在 http 回退通道上同样要剥。
  const pinPublicHost = (headers: IncomingHttpHeaders, barePath = ''): IncomingHttpHeaders => {
    const pinned: IncomingHttpHeaders = { ...headers, host: publicHost };
    const engineToken = sessionManager.currentEngineToken;
    if (engineToken) pinned['x-app-token'] = engineToken;
    else delete pinned['x-app-token'];
    normalizeAuthFetchSite(pinned as Record<string, string>, barePath);
    return pinned;
  };
  // v3.143：删 v3.140 的 `?token=` preHandler——该尝试用 engine.token
  // （DSH_BIND_TOKEN）冒充 BrowserAuth.launchToken 是错的（实测 live
  // smoke 步骤 4 仍 401）。正解见 docs/decisions/2026-09-07-dsh-auth-endpoint.md：
  // dsh 端 /auth 用 engine.token 颁发针对 trusted-host authority 的引擎
  // cookie；relay 侧无需任何 ?token= 注入，浏览器按 URL 源 scope 收纳。
  const proxyCommon = {
    upstream: dshUpstream,
    websocket: false,
    replyOptions: {
      rewriteRequestHeaders: (req: unknown, headers: IncomingHttpHeaders) =>
        pinPublicHost(headers, ((req as { url?: string } | undefined)?.url ?? '').split('?')[0] ?? ''),
    },
  } as const;

  // v3.151 PR-B：WSS 数据面 HTTP 代理——当 plugin 已连接 /ws/dsh 时，
  // 用 http.req/http.res 帧而非 @fastify/http-proxy 转发。
  //   RELAY_DATA_PLANE=wss   → WSS 数据面（默认 / 此版）
  //   RELAY_DATA_PLANE=http   → 旧 HTTP proxy（v3.143 baseline，回退通道）
  const useWssDataPlane = (process.env.RELAY_DATA_PLANE ?? 'wss') === 'wss'

  // v3.151：plugin ↔ WSS 数据面状态（process 级别共享——同一 relay 只有一个 plugin）
  // 由 /ws/dsh handler 写，由 wssHttpProxy 读
  // v3.162：单 plugin 策略显式化——新连接注册即踢旧（terminate）；close 侧
  // 有身份守卫，只有「当前 socket」的 close 才清状态，迟到的 stale close 无害。
  interface WssPendingHttp {
    resolve: (frame: { type: string; [k: string]: unknown }) => void
    timer: NodeJS.Timeout
    startedAt: number
    /** v3.170：归属 pairing 的 pairingToken。teardownWssDataPlane(key) 时
     *  按此过滤，A pairing 断连不会影响 B pairing 的 in-flight 请求。 */
    pairingKey: PairingKey
  }
  const wssPendingHttp = new Map<string, WssPendingHttp>()
  // v3.170：per-pairing socket Map — 每个 pairing（pairingToken）一个 WSS
  // 出站连接。多 dsh engine / 多设备场景下不同 pairing 共存，互不踢；
  // 同 pairing 重连时按 v3.162 旧行为踢旧（防 plugin_not_connected 死锁）。
  // 配对 key 取 pairingToken 而非 sessionId：sessionId 是公开 URL 一部分
  // 可枚举，pairingToken 才是鉴权凭证（plugin mint 的 32 字节 hex）。
  type PairingKey = string
  const wssPluginSockets = new Map<PairingKey, WsBrowserSide>()
  const wssPluginReady = new Map<PairingKey, boolean>()

  // v3.152.4 PR-WS-bridge：浏览器侧 WS 桥状态。/api/events.* 的 upgrade
  // 不再走老 raw socket（指向 VPS 本地 3080——SSH 隧道拆除后无人监听，
  // SPA 事件流 502 → 页面卡"无法访问"），改发 ws.upgrade 帧给 plugin、
  // 由其 node:ws client 连 dsh，双向 ws.frame 桥接。浏览器侧握手 + 帧
  // 编解码用 ws 包 noServer 模式（handleUpgrade 在收到 plugin 的
  // ws.accept 之后才执行——dsh 真接受升级才回 101，不撒谎）。
  // v3.282：帧上限 4MB——ws 默认 100MiB/帧，一条 /api/events.* 桥接就能把
  // relay 与引擎内存打满。与 plugin 侧请求体/响应体上限同族（4MiB）。
  const WS_FRAME_LIMIT = 4 * 1024 * 1024;
  const wssNoServer = new WsNoServer({ noServer: true, maxPayload: WS_FRAME_LIMIT })
  // v3.152.4：/ws/dsh（plugin 出站通道）也走裸 WebSocketServer——
  // 替代 @fastify/websocket（避免它的全局 upgrade listener 抢在我们总
  // handler 之前 destroy 不匹配路径）。handleUpgrade 拿到 ws 实例后，PSK 校验 +
  // session.register + WSS 数据面消息分发 与原本 fastify 装饰器 cb 同款。
  const wsTunnelServer = new WsNoServer({ noServer: true, maxPayload: WS_FRAME_LIMIT })
  interface WssPendingUpgrade {
    req: http.IncomingMessage
    socket: Duplex
    head: Buffer
    timer: NodeJS.Timeout
    sessionId: string
    /** 设备在线计数扣减（幂等；upgrade 计 +1 后由 close/timeout/error 任一触发一次扣） */
    dropStream: () => void
    /** v3.170：归属 pairing；同 WssPendingHttp.pairingKey 的过滤作用。 */
    pairingKey: PairingKey
    /** v3.205：本连接升级鉴权时凭以通过的 sessionSecret——着陆轮换时按它
     * 精确识别"旧设备"的流（close 4001），不误伤刚用新 secret 建立的流。 */
    authorizedSecret: string
  }
  const wssPendingUpgrades = new Map<string, WssPendingUpgrade>()
  const wssBridgedWs = new Map<string, { ws: WsBrowserSide; dropStream: () => void; pairingKey: PairingKey; authorizedSecret: string }>()
  /** wssBridgedWs 条目的 dropStream 与 pending 期共用同一闭包（幂等计数） */

  // v3.170：把"当前 plugin 唯一引用"改为 Map。Map 里有 socket + ready
  // 标记；close handler 的"身份守卫"和"踢旧"按 pairing key 匹配。
  // 见 2026-09-09-multi-device-pairing.md 决策 1 + per-pairing-socket-design.md §4。

  // v3.170：把单 socket 上的 ready 检查改为按 pairingKey 查询。用于
  // wssHttpProxy 在转发前判定「目标 pairing 的 plugin 是否在线」。
  const wssBridgeReadyFor = (key: PairingKey): boolean => {
    const s = wssPluginSockets.get(key)
    return s !== undefined && (wssPluginReady.get(key) ?? false) && s.readyState === s.OPEN
  }
  // 兼容旧调用点（preClose hook、preClose 全局清理）；遍历所有 socket 检查 ready。
  const wssAnyReady = (): boolean => {
    for (const [key] of wssPluginSockets) {
      if (wssBridgeReadyFor(key)) return true
    }
    return false
  }

  /** v3.162 + v3.170：WSS 数据面 in-flight 清理（幂等）。
   *  - 无参：对全部 pairing 清（preClose / 全局断开场景）
   *  - 带 key：只清该 pairing 的 in-flight（踢旧 / 该 pairing close 场景）
   * 两个调用方：
   *  ① 当前 plugin socket 的 close handler（真断链；key 可选——按该 socket 的
   *     pairingKey 清；无 key 时全局清）
   *  ② 新 /ws/dsh 注册时的踢旧路径（key = 被踢 pairing 的 key；旧连接 in-flight
   *     请求无法由新连接应答，立即写回 503）
   * 旧 socket 迟到的 close 会被身份守卫早退，不会二次执行。 */
  const teardownWssDataPlane = (onlyPairingKey?: PairingKey): void => {
    const matchesKey = (k: PairingKey | undefined) =>
      onlyPairingKey === undefined || k === onlyPairingKey
    for (const [id, pending] of wssPendingHttp) {
      if (!matchesKey(pending.pairingKey)) continue
      clearTimeout(pending.timer);
      try {
        (pending as unknown as { reply?: { code: (c: number) => { type: (t: string) => { send: (b: unknown) => unknown } } } }).reply?.code?.(503)?.type?.('application/json')?.send?.({ error: 'wss_data_plane_disconnected', id });
      } catch {}
    }
    // 只清属于该 pairing 的 pending（注意：Map 是按 msg.id 索引，需要遍历）
    for (const [id, pending] of [...wssPendingHttp.entries()]) {
      if (matchesKey(pending.pairingKey)) wssPendingHttp.delete(id)
    }
    // v3.152.4：WS 桥全部失去载体——断浏览器侧 + 扣计数
    for (const [id, pendingWs] of wssPendingUpgrades) {
      if (!matchesKey(pendingWs.pairingKey)) continue
      clearTimeout(pendingWs.timer);
      pendingWs.dropStream();
      pendingWs.socket.destroy();
    }
    for (const [id, pendingWs] of [...wssPendingUpgrades.entries()]) {
      if (matchesKey(pendingWs.pairingKey)) wssPendingUpgrades.delete(id)
    }
    for (const [id, bridged] of wssBridgedWs) {
      if (!matchesKey(bridged.pairingKey)) continue
      bridged.dropStream();
      try { bridged.ws.close(1012, 'relay tunnel disconnected') } catch {}
    }
    for (const [id, bridged] of [...wssBridgedWs.entries()]) {
      if (matchesKey(bridged.pairingKey)) wssBridgedWs.delete(id)
    }
  }

  if (useWssDataPlane) {
    // D-045: raised from 30 s. A real host answers `session/list` in ~85 s
    // (1583 sessions, 78% of the 1.8 MB body being per-session projections),
    // so a 30 s ceiling turned every "browse or resume a session" request
    // into a guaranteed 504 — the App's core path, not a corner case.
    //
    // Overridable by env so the next tuning is a container restart instead of
    // a code change plus a redeploy, which is the tax that made this constant
    // worth hardcoding in the first place.
    //
    // **Coupled to `EngineRpc.defaultCallTimeout` (195 s) in the App.** The App
    // must give up *after* the relay, or a raised ceiling here would be
    // unreachable; the smaller of the two always wins. Both files say so.
    const WSS_PROXY_TIMEOUT_MS = Number(process.env.WSS_PROXY_TIMEOUT_MS ?? 180_000)
    // Inline UUID v4 generation (same implementation as the WSS protocol
    // helper; kept inline so the relay has no cross-package import, and no
    // dynamic import either — /app is a flat layout inside the container,
    // so a relative path would not resolve).
    const newFrameId = (): string => {
      const bytes = new Uint8Array(16)
      crypto.getRandomValues(bytes)
      bytes[6] = (bytes[6]! & 0x0f) | 0x40
      bytes[8] = (bytes[8]! & 0x3f) | 0x80
      const hex: string[] = []
      for (const b of bytes) hex.push(b.toString(16).padStart(2, '0'))
      return `${hex.slice(0, 4).join('')}-${hex.slice(4, 6).join('')}-${hex.slice(6, 8).join('')}-${hex.slice(8, 10).join('')}-${hex.slice(10, 16).join('')}`
    }
    const wssHttpProxy = async (req: import('fastify').FastifyRequest, reply: import('fastify').FastifyReply) => {
      // v3.170/v3.173：per-pairing 路由——优先 URL 会话 token(gate 已验,locals
      // 里有 sessionId),其次 cookie 命名空间 + X-Pairing-Id。
      let targetSocket: WsBrowserSide | undefined
      let targetPairingKey: PairingKey | undefined
      const urlSessionId = (req as unknown as { urlSessionId?: string })?.urlSessionId
      if (urlSessionId) {
        const session = sessionManager.getSession(urlSessionId)
        if (session && session.pairingToken) {
          targetPairingKey = session.pairingToken
          targetSocket = wssPluginSockets.get(targetPairingKey)
        }
      }
      if (!targetSocket) {
        const pairing = pickPairingCookie(req.cookies, req.headers[PAIRING_ID_HEADER], isValidPairingCookie)
        if (pairing) {
          const session = sessionManager.getSessionBySecret(pairing.secret)
          if (session && session.pairingToken && session.sessionId === pairing.sessionId) {
            targetPairingKey = session.pairingToken
            targetSocket = wssPluginSockets.get(targetPairingKey)
          }
        }
      }
      // v3.173：/assets/* 与 /(静态资源)gate 已免鉴权——无 URL token / 无 cookie
      // 时回落到"任一在线 pairing"的 socket(dsh 的 JS/CSS 是所有 pairing 同版本
      // 产物,内容一致;仅用于 SPA 首屏加载,不含 /api 数据)。
      // v3.176.1：/plugins/* 同级回落——首屏 preload 脚本(script 标签)无凭证,
      // 与 /assets/* 同为公开构建产物(详见 gate 处注释)。
      // v3.203：/auth 同级回落（回填线上热修 Patch B，ADR
      // docs/decisions/2026-09-14-relay-remote-control-url-fix）——着陆 302
      // 跳板的 /auth 正常浏览器会带上刚
      // 颁的 pairing cookie 走 per-pairing 路由；此回落只兜极端 cookie 丢失
      // （隐私模式拦截重定向链 Set-Cookie 等），引擎 cookie 单独过不了闸门。
      // 注意 req.url 含 query(如 /?sessionId=...&hash=...)——判 path 必须剥 query。
      const barePath = (req.url ?? '').split('?')[0] ?? ''
      if (!targetSocket && (barePath.startsWith('/assets/') || barePath.startsWith('/plugins/') || barePath === '/' || barePath === '/auth')) {
        for (const [key, s] of wssPluginSockets.entries()) {
          if (wssBridgeReadyFor(key)) {
            targetPairingKey = key
            targetSocket = s
            break
          }
        }
      }
      if (!targetSocket || !targetPairingKey || !wssBridgeReadyFor(targetPairingKey)) {
        void reply.code(503).type('application/json').send({
          error: 'plugin_not_connected',
          hint: 'dsh remote client has not registered with relay for this pairing; check the local dsh engine + remote client state',
        })
        return reply
      }
      const id = newFrameId()
      const headers: Record<string, string> = {}
      for (const [k, v] of Object.entries(req.headers)) {
        if (typeof v === 'string') headers[k] = v
        else if (Array.isArray(v)) headers[k] = v.join(', ')
      }
      headers.host = publicHost
      normalizeAuthFetchSite(headers, barePath)

      let body: string | undefined
      if (req.body !== undefined && req.body !== null) {
        body = typeof req.body === 'string' ? req.body : JSON.stringify(req.body)
      }

      const frame = {
        v: 1 as const,
        type: 'http.req' as const,
        id,
        method: req.method,
        path: req.url,
        headers,
        body,
      }

      return new Promise<typeof reply>((resolvePromise) => {
        const timer = setTimeout(() => {
          wssPendingHttp.delete(id)
          auditLogger.log({ eventType: 'wss_proxy_timeout', ip: req.ip, userAgent: req.headers['user-agent'], details: `${req.method} ${req.url} id=${id.slice(0, 8)}` })
          void reply.code(504).type('application/json').send({ error: 'plugin_timeout', id })
          resolvePromise(reply)
        }, WSS_PROXY_TIMEOUT_MS)

        wssPendingHttp.set(id, {
          resolve: (resFrame) => {
            clearTimeout(timer)
            wssPendingHttp.delete(id)
            if (resFrame.type === 'error') {
              auditLogger.log({ eventType: 'wss_proxy_engine_error', ip: req.ip, userAgent: req.headers['user-agent'], details: `${req.method} ${req.url} ${resFrame.code}: ${resFrame.message}` })
              void reply.code(502).type('application/json').send({ error: resFrame.code, message: resFrame.message })
            } else {
              // v3.151：strip 传输层头——dsh 响应可能带 transfer-encoding: chunked，
              // 与 Fastify 自身的 content-length 管理冲突（HTTPParserError）。
              // body 已是完整 string，让 Fastify 自己算 content-length。
              for (const [k, v] of Object.entries((resFrame.headers ?? {}) as Record<string, string>)) {
                const lk = k.toLowerCase()
                if (lk === 'set-cookie' || lk === 'transfer-encoding' || lk === 'content-length') continue
                reply.header(k, v)
              }
              const sc = (resFrame.headers as Record<string, string>)['set-cookie']
              if (sc) reply.header('set-cookie', sc)
              // v3.203：v3.176.2 的「3xx Location 补回凭证字段」救援已移除——
              // 根路径闸门对带凭证 query 的 / 一律在闸门层 302 着陆，不再透传
              // 给 dsh，「dsh 303 剥 query 导致失联」场景不复存在。
              const resStatus = (resFrame.status as number) ?? 502
              void reply.code(resStatus).send((resFrame.body as string | undefined) ?? '')
            }
            resolvePromise(reply)
          },
          timer,
          startedAt: Date.now(),
          pairingKey: targetPairingKey,
        })

        try {
          targetSocket.send(JSON.stringify(frame))
        } catch (err) {
          clearTimeout(timer)
          wssPendingHttp.delete(id)
          auditLogger.log({ eventType: 'wss_proxy_send_failed', ip: req.ip, userAgent: req.headers['user-agent'], details: `${req.method} ${req.url}: ${(err as Error).message}` })
          void reply.code(502).type('application/json').send({ error: 'plugin_send_failed' })
          resolvePromise(reply)
        }
      })
    }

    // v3.152.2：catch-all 代理——此前只注册 /、/api/*、/auth，SPA 的
    // /assets/*（JS/CSS/字体）与插件路由全部落 relay 404，
    // 手机端白屏（2026-09-07 实证）。补 /* 通配（fastify find-my-way 静态
    // 路由优先级高于通配，/__pair、/__devices、/health 不受影响）。
    fastify.route({ method: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'] as const, url: '/api/*', handler: wssHttpProxy })
    // Plugin HTTP routes need no per-prefix registration: the `/*` catch-all
    // below proxies them with the same gate (the onRequest credential hook is
    // global). `/dsh-remote/*` is this project's own pairing-lifecycle prefix
    // (dsh-remote-relay-plugin's ROUTE_PREFIX) — registered separately so the
    // remote-control surface has its own name in the route table and audit log.
    // v3.282: registering it does NOT mean a paired device may call it — the
    // credential hook refuses LOCAL_ADMIN_DENY (mint / revoke / tunnel control)
    // before routing, and only the read-only half of that prefix (status +
    // url-session renewal, which the paired app depends on) reaches the engine.
    fastify.route({ method: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'] as const, url: '/dsh-remote/*', handler: wssHttpProxy })
    fastify.route({ method: ['GET', 'HEAD', 'OPTIONS'] as const, url: '/assets/*', handler: wssHttpProxy })
    fastify.route({ method: ['GET', 'HEAD', 'OPTIONS'] as const, url: '/', handler: wssHttpProxy })
    fastify.route({ method: ['GET'] as const, url: '/auth', handler: wssHttpProxy })
    fastify.route({ method: ['GET', 'HEAD', 'OPTIONS'] as const, url: '/*', handler: wssHttpProxy })
    logger.info({ mode: 'wss_data_plane' }, 'relay_started_in_wss_mode')
  } else {
    fastify.register(fastifyHttpProxy, { ...proxyCommon, prefix: '/api', rewritePrefix: '/api' })
    fastify.register(fastifyHttpProxy, { ...proxyCommon, prefix: '/', rewritePrefix: '/' })
    logger.info({ mode: 'http_proxy' }, 'relay_started_in_http_mode')
  }

  // 9. WS upgrade 反向代理：/api/events.* → dsh host
  //    @fastify/http-proxy 的 websocket 支持跟 @fastify/websocket 冲突
  //    （双 socket 分配），所以我们自己用 raw http.request 处理 upgrade
  //    upgrade 前先做 cookie 校验（找不到对应 session 则拒绝）
  fastify.server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url || '', `http://${req.headers.host}`);
    if (url.pathname === '/ws/dsh') {
      wsTunnelServer.handleUpgrade(req, socket, head, (ws) => {
        handleTunnelConnection(ws, req)
      })
      return
    }
    // v3.154.2：dsh 0.1.2 把事件流路径从 /api/events.* 迁到 /api/remote.mux
    // （REMOTE_STREAM_MUX_PATH）——白名单漏掉它会被下方 destroy 掐断，手机
    // SPA 能起但 WS 数据流连不上，workspace/会话全空。两条路径并存兼容。
    // 额外路径：插件自有的实时 WS（如行情流）直连 origin
    // `wss://<RELAY_PUBLIC_HOST>/<plugin-path>`，不进白名单会被 destroy 掐断
    // → SPA 卡 connecting / disconnected。通过 RELAY_WS_BRIDGE_PATHS 声明，
    // 复用同 handleEventsBridgeUpgrade 链：cookie 闸 + ws.upgrade 帧，
    // `?token=` 走 url.search 透传到 dsh 端对应 upgrade 处理。
    if (
      url.pathname.startsWith('/api/events.') ||
      url.pathname === '/api/remote.mux' ||
      wsBridgePaths.includes(url.pathname)
    ) {
      handleEventsBridgeUpgrade(req, socket, head, url)
      return
    }
    socket.destroy();
  });

  // 10. dsh 本地客户端反向连接入口（WSS /ws/dsh）——v3.152.4：改用裸
  // WebSocketServer.handleUpgrade（替代 @fastify/websocket，避免全局
  // upgrade listener 抢在我们总 handler 之前 destroy 不匹配路径）。
  // handleTunnelConnection 在 upgrade 总 handler 里被回调。
  // v3.152.4：必须在 Fastify 的 preClose 阶段清理升级后的 WS。
  // 升级 socket 已从 Node HTTP server 的连接表移除，因此 closeAllConnections()
  // 看不到它们；若等 onClose 才 terminate，Fastify 会先等待 server.close()
  // 回调，形成死等（测试 hook 10s timeout，生产优雅停机也会卡）。
  fastify.addHook('preClose', async () => {
    for (const [, pendingWs] of wssPendingUpgrades) {
      clearTimeout(pendingWs.timer)
      try { pendingWs.socket.destroy() } catch { /* ignore */ }
    }
    wssPendingUpgrades.clear()
    wsTunnelServer.clients.forEach((ws) => { try { ws.terminate() } catch { /* ignore */ } })
    wssNoServer.clients.forEach((ws) => { try { ws.terminate() } catch { /* ignore */ } })
    for (const [, bridged] of wssBridgedWs) {
      try { bridged.ws.terminate() } catch { /* ignore */ }
    }
    wssBridgedWs.clear()
  })

  function handleTunnelConnection(socket: WsBrowserSide, req: http.IncomingMessage) {
    // v3.282：XFF 只信直连为受信代理的请求——裸 IncomingMessage 没有
    // fastify 的 .ip，原实现无条件取首跳，任何客户端可伪造审计 IP 并
    // 让 per-IP 暴破告警永不触发。
    const ip = resolveClientIp(req.socket.remoteAddress, req.headers['x-forwarded-for']?.toString(), trustProxyCsv)
    const authHeader = req.headers['authorization'] || '';
    const token = authHeader.replace(/^Bearer\s+/i, '');

      if (!secretEquals(token, psk)) {
        auditLogger.log({
          eventType: 'dsh_auth_failed',
          ip: ip,
          userAgent: req.headers['user-agent'],
          details: 'Invalid or missing PSK',
        });
        logger.warn({ ip: ip }, 'dsh_auth_failed');
        socket.close(4001, 'Unauthorized PSK');
        return;
      }

auditLogger.log({
        eventType: 'dsh_connected',
        ip: ip,
        userAgent: req.headers['user-agent'],
      });
      logger.info({ ip: ip }, 'dsh_tunnel_connected');

      // v3.170：per-pairing socket Map。踢旧决策从「WSS 升级时」移到「register
      // 帧到达时」——WSS upgrade 拿不到 pairingToken，register 帧才有。每个
      // socket 通过本地变量 socketPairingKey 关联它的归属 pairing；close
      // handler 身份守卫按 Map 反向查找验证。
      // 多 dsh engine / 多设备场景下不同 pairing 共存，互不踢；同 pairing
      // 重连时按 v3.162 旧行为踢旧（防 plugin_not_connected 死锁）。
      // 详见 2026-09-09-per-pairing-socket-design.md §4.2。
      let socketPairingKey: PairingKey | null = null

      // v3.282：maxPayload 超限时 ws 先 emit 'error' 再 close——没有监听的
      // 'error' 会以未捕获异常炸掉 relay 进程。引擎侧隧道是最高价值链路，
      // 必须自带兜底。
      socket.on('error', (err) => {
        logger.warn({ err: (err as Error).message }, 'dsh_tunnel_ws_error')
        try { socket.close(1011, 'ws error') } catch { /* already closing */ }
      })

      socket.on('message', (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          switch (msg.type) {
            case 'session.register': {
              const payload = msg.payload as RegisterSessionPayload;
              const pairingKey: PairingKey = payload.pairingToken
              socketPairingKey = pairingKey
              // v3.141：忽略上游仍可能带过来的 `payload.mode`（旧 plugin 过渡
              // 期间残留字段）——所有配对恒为 full，enforcement 由 dsh Host fence
              // 独立承担（详见 docs/decisions/2026-09-07-remote-single-mode.md）。
              const session = sessionManager.registerSession(
                payload.sessionId,
                payload.pairingToken,
                payload.ttlSeconds || 300,
                socket,
                payload.engineToken,
              );
              // v3.170：per-pairing 踢旧——同 pairingToken 已有 socket 且仍
              // OPEN 才踢；跨 pairing 共存（这是设计意图，文档明文）。
              const oldSocket = wssPluginSockets.get(pairingKey)
              if (oldSocket && oldSocket !== socket && oldSocket.readyState === oldSocket.OPEN) {
                auditLogger.log({
                  eventType: 'dsh_tunnel_replaced',
                  sessionId: payload.sessionId,
                  ip,
                  userAgent: req.headers['user-agent'],
                  details: `per-pairing kick: same pairingToken ${pairingKey.slice(0, 8)}…`,
                });
                logger.warn({ ip, sessionId: payload.sessionId }, 'dsh_tunnel_replaced_kicking_old');
                // 同 pairing 的旧连接 in-flight 请求无法由新连接应答（新插件
                // 不认识那些 id）——只清该 pairing 的数据面。
                teardownWssDataPlane(pairingKey)
                try { oldSocket.terminate() } catch { /* already closing */ }
              }
              // 登记到 per-pairing Map（新连接或重连均覆盖旧 entry）
              wssPluginSockets.set(pairingKey, socket)
              wssPluginReady.set(pairingKey, true)
              logger.info({ ip, sessionId: payload.sessionId }, 'wss_data_plane_ready')
              socket.send(JSON.stringify({
                type: 'session.registered',
                sessionId: payload.sessionId,
                reusesSecret: session.reusedSecret === true,
                timestamp: Date.now(),
              }));
              auditLogger.log({
                sessionId: payload.sessionId,
                eventType: 'session_registered',
                ip: ip,
              });
              logger.info({ sessionId: payload.sessionId, ip: ip }, 'session_registered');
              break;
            }
            case 'session.revoke': {
              const payload = msg.payload as RevokeSessionPayload;
              sessionManager.revokeSession(payload.sessionId, payload.reason);
              // v3.170：plugin 主动撤销时，同步清 per-pairing socket Map。
              // session.revoke 通常出现在「断开中继」按钮触发 → 配对彻底撤
              // 销场景；同时挂载的同一 pairing socket 也该一并下线，避免
              // 出现"session 已撤销但 socket 还在 30 分钟"的口径不一。
              if (socketPairingKey) {
                if (wssPluginSockets.get(socketPairingKey) === socket) {
                  wssPluginSockets.delete(socketPairingKey)
                  wssPluginReady.delete(socketPairingKey)
                  teardownWssDataPlane(socketPairingKey)
                }
                socketPairingKey = null
              }
              auditLogger.log({
                sessionId: payload.sessionId,
                eventType: 'session_revoked_by_dsh',
                ip: ip,
              });
              logger.info({ sessionId: payload.sessionId, ip: ip }, 'session_revoked_by_dsh');
              break;
            }
            case 'http.res': {
              // v3.151 PR-B：WSS 数据面响应——dispatch 到对应 pending request
              const pending = wssPendingHttp.get(msg.id)
              if (pending) pending.resolve(msg)
              else logger.warn({ id: msg.id?.slice?.(0, 8) }, 'wss_http_res_orphan')
              break;
            }
            case 'error': {
              // v3.151 PR-B：plugin 报告某个 id 出错——dispatch 到对应 pending
              const pending = wssPendingHttp.get(msg.id)
              if (pending) pending.resolve(msg)
              // v3.152.4：也可能是 WS 桥的 upgrade 失败（engine_down 等）——
              // 未完成浏览器握手的断 socket + 扣计数
              const pendingWs = wssPendingUpgrades.get(msg.id)
              if (pendingWs) {
                clearTimeout(pendingWs.timer);
                wssPendingUpgrades.delete(msg.id);
                pendingWs.dropStream();
                pendingWs.socket.destroy();
              }
              break;
            }
            case 'ws.accept': {
              // v3.152.4 PR-WS-bridge：plugin 侧 dsh WS 已建立——现在才对
              // 浏览器做 101 握手（不撒谎原则：dsh 拒绝升级时浏览器收不到
              // 假 101）。v3.170：登记到 wssBridgedWs 时附 pairingKey 维度，
              // teardownWssDataPlane(pairingKey) 才能正确隔离多 pairing 场景。
              const pendingWs = wssPendingUpgrades.get(msg.id)
              if (!pendingWs) break;
              clearTimeout(pendingWs.timer);
              wssPendingUpgrades.delete(msg.id);
wssNoServer.handleUpgrade(pendingWs.req, pendingWs.socket, pendingWs.head, (browserWs) => {
                // v3.282：同隧道 socket——maxPayload/帧解析错误先走 'error'，
                // 无监听即未捕获异常。浏览器事件流不允许带走 relay。
                browserWs.on('error', (err) => {
                  logger.warn({ err: (err as Error).message }, 'events_bridge_ws_error')
                  try { browserWs.close(1011, 'ws error') } catch { /* already closing */ }
                })
                // v3.206：桥接建立时再校验授权密钥仍是当前 sessionSecret——堵住
                // 「A 着陆→SPA 还在加载→B 着陆轮换→A 的事件流才建」的时间竞态
                // （v3.205 着陆时掐断覆盖 WS 已在飞的场景；此处覆盖 WS 后到的场景）。
                // 90s previousSecret 宽限不延伸到桥接创建：宽限保护的是 HTTP 着陆
                // 链路竞态和在途请求，A 仍能在宽限里发完最后一波 /api，但 WS 一
                // 开就踢——避免 90s 内仍有双向实时流存在的“鬼活”状态。
                // setImmediate：让 101 升级响应先 flush 再发 close 帧；浏览器侧
                // 才能稳定观察到 close code 4001（而非 1006/握手异常）。
                const liveSession = sessionManager.getSession(pendingWs.sessionId)
                if (liveSession && liveSession.sessionSecret !== pendingWs.authorizedSecret) {
                  pendingWs.dropStream()
                  setImmediate(() => { try { browserWs.close(4001, 'device_replaced') } catch { /* socket gone */ } })
                  return
                }
                const dropStream = pendingWs.dropStream;
                wssBridgedWs.set(msg.id, { ws: browserWs as WsBrowserSide, dropStream, pairingKey: socketPairingKey ?? '', authorizedSecret: pendingWs.authorizedSecret });
                browserWs.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
                  const buf = Buffer.isBuffer(data) ? data : Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
                  // v3.282：上行与下行同限——此前只有下行(plugin→浏览器)有 4MB
                  // 检查，上行(浏览器→plugin)无限，一条桥接可持续推巨帧打满两端。
                  if (buf.length > WS_FRAME_LIMIT) {
                    browserWs.close(1009, 'payload too large');
                    wssBridgedWs.delete(msg.id);
                    dropStream();
                    return;
                  }
                  const payload = isBinary ? buf.toString('base64') : buf.toString('utf8');
                  // v3.170：上行帧必须由当前 pairing 的 socket 转发——不再用
                  // 全局单值；闭包持有当前 socket 引用，安全。
                  try {
                    socket.send(JSON.stringify({
                      v: 1, type: 'ws.frame', id: msg.id, dir: 'up',
                      opcode: isBinary ? 2 : 1, payload,
                    }));
                  } catch { /* 隧道刚断——close 帧会兜底 */ }
                });
                browserWs.on('close', () => {
                  wssBridgedWs.delete(msg.id);
                  dropStream();
                  try { socket.send(JSON.stringify({ v: 1, type: 'ws.close', id: msg.id, code: 1000, reason: '' })) } catch {}
                });
                browserWs.on('error', () => { try { browserWs.close() } catch {} });
              });
              break;
            }
            case 'ws.frame': {
              // v3.152.4：plugin → 浏览器下行帧（dsh 事件流推送）
              if (msg.dir !== 'down') break;
              const bridged = wssBridgedWs.get(msg.id);
              if (!bridged) break;
              const payload: string = typeof msg.payload === 'string' ? msg.payload : '';
              if (payload.length > 4 * 1024 * 1024) {
                bridged.ws.close(1009, 'payload too large');
                wssBridgedWs.delete(msg.id);
                bridged.dropStream();
                break;
              }
              try {
                bridged.ws.send(msg.opcode === 2 ? Buffer.from(payload, 'base64') : payload);
              } catch { /* 浏览器侧已断——close 帧会兜底 */ }
              break;
            }
            case 'ws.close': {
              // v3.152.4：dsh 侧关闭——未完成握手的断 socket + 扣计数；已建立的关浏览器 WS
              const pendingWs = wssPendingUpgrades.get(msg.id);
              if (pendingWs) {
                clearTimeout(pendingWs.timer);
                wssPendingUpgrades.delete(msg.id);
                pendingWs.dropStream();
                pendingWs.socket.destroy();
                break;
              }
              const bridged = wssBridgedWs.get(msg.id);
              if (bridged) {
                wssBridgedWs.delete(msg.id);
                bridged.dropStream();
                try { bridged.ws.close(Number(msg.code) || 1000, String(msg.reason ?? '')) } catch {}
              }
              break;
            }
            case 'audit': {
              // v3.161：plugin → relay 审计事件。Plugin 不持久化日志；让 relay
              // 落审计 DB（同一 sqlite，watchdog 也读）。事件类型白名单防滥用
              // ——必须 plugin_ 前缀（≤64 字符），否则静默拒。
              const payload = msg.payload as { eventType?: string; sessionId?: string; details?: string } | undefined
              const eventType = typeof payload?.eventType === 'string' ? payload.eventType : ''
              if (!eventType.startsWith('plugin_') || eventType.length > 64) {
                logger.warn({ ip }, 'audit_rejected_invalid_type')
                break
              }
              // plugin 一条 /ws/dsh 可能承载多个 pairing session——要求 plugin
              // 自带 sessionId；只接受 1-64 字符（防注入）；找不到就当 orphan 记。
              const rawSid = typeof payload?.sessionId === 'string' ? payload.sessionId : ''
              const sid = /^[A-Za-z0-9_-]{1,64}$/.test(rawSid) ? rawSid : undefined
              auditLogger.log({
                sessionId: sid,
                eventType,
                ip,
                details: typeof payload?.details === 'string' ? payload.details.slice(0, 240) : undefined,
              });
              break;
            }
          }
        } catch (err: any) {
          socket.send(JSON.stringify({
            type: 'error',
            error: err.message,
            timestamp: Date.now(),
          }));
        }
      });

      socket.on('close', () => {
        sessionManager.clearDsh(socket);
        // v3.170 身份守卫：per-pairing Map 查询——只有当前 socket 是 Map 里
        // 该 pairingKey 对应的 socket 时，才清理 state。镜像 v3.162 的 plugin
        // 侧教训（旧 socket 迟到的 close 不得清掉新连接的注册）。
        const pk = socketPairingKey
        if (!pk || wssPluginSockets.get(pk) !== socket) {
          auditLogger.log({
            eventType: 'dsh_stale_close_ignored',
            ip,
            details: pk ? `pairingToken=${pk.slice(0, 8)}…` : 'no_pairing_key',
          });
          logger.info({ ip }, 'dsh_stale_close_ignored');
          return;
        }
        wssPluginSockets.delete(pk);
        wssPluginReady.delete(pk);
        // v3.170：只清该 pairing 的 in-flight；其他 pairing 不受影响。
        teardownWssDataPlane(pk);
        auditLogger.log({
          eventType: 'dsh_disconnected',
          ip: ip,
        });
        logger.info({ ip: ip }, 'dsh_tunnel_disconnected');
      });
  }

  // v3.152.4 PR-WS-bridge：/api/events.* upgrade 处理（被总 upgrade
  // handler 分发调用）。cookie 校验 → 计数 → 发 ws.upgrade 帧给 plugin
  // → 等 ws.accept 才做浏览器侧 101 握手（不撒谎原则）。
  function handleEventsBridgeUpgrade(req: http.IncomingMessage, socket: Duplex, head: Buffer, url: URL) {
    // v3.173：URL 会话 token 优先——WS 不能带自定义 header,SPA 把
    // `<sid>.<exp>.<mid>.<t>.<hash>` 放 query ?token=。cookie 路线兜底。
    const wsToken = url.searchParams.get('token')
    if (wsToken) {
      const sessionId = verifyUrlSessionToken(`Bearer ${wsToken}`, psk, sessionManager)
      if (sessionId) {
        const session = sessionManager.getSession(sessionId)!
        // 与 cookie 分支共享的后半段(tail 统一记 audit,带 url-session 来源)。
        // URL token 路线无独立 pairing.secret——其授权凭证就是 token 本身；
        // 落在岸后 URL token 用完即弃，正常不会触达此后的轮换场景。v3.206 桥
        // 接创建时校验默认回退 current secret 即可。
        handleEventsBridgeUpgradeTail(session, req, socket, head, url, true, session.sessionSecret)
        return
      }
      auditLogger.log({
        eventType: 'ws_upgrade_auth_missing',
        ip: req.socket.remoteAddress ?? 'unknown',
        userAgent: req.headers['user-agent'],
        details: `${url.pathname} url-session-token invalid`,
      });
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }

    const cookieHeader = req.headers['cookie'] || '';
    // v3.172 Plan A：解析所有合法 pairing cookie——单 pairing 时取第一个,
    // 多 pairing 时按 X-Pairing-Id header 挑(客户端缺失则 401,避免路由错).
    const cookies: Record<string, string> = {}
    for (const part of cookieHeader.split(';')) {
      const eq = part.indexOf('=')
      if (eq < 0) continue
      const k = part.slice(0, eq).trim()
      const v = part.slice(eq + 1).trim()
      if (k) cookies[k] = v
    }
    const pairing = pickPairingCookie(cookies, req.headers[PAIRING_ID_HEADER], isValidPairingCookie)
    // pairing.secret 必须归属于 pairing.sessionId——防"用 A 的 cookie 试图
    // 通过 B pairing 的闸门"这种串号。
    const session = (pairing && sessionManager.getSessionBySecret(pairing.secret)) || undefined
    if (!pairing || !session || session.sessionId !== pairing.sessionId) {
      auditLogger.log({
        eventType: 'ws_upgrade_auth_missing',
        ip: req.socket.remoteAddress ?? 'unknown',
        userAgent: req.headers['user-agent'],
        details: url.pathname,
      });
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    handleEventsBridgeUpgradeTail(session, req, socket, head, url, false, pairing.secret)
  }

  // v3.173：events upgrade 验完 session 后的公共后半段(URL token 与 cookie
  // 两路共用)——计数 → 发 ws.upgrade 帧给 plugin → 等 ws.accept 才做浏览器
  // 侧 101 握手(不撒谎原则)。
  function handleEventsBridgeUpgradeTail(session: import('./session.js').ActiveSession, req: http.IncomingMessage, socket: Duplex, head: Buffer, url: URL, fromUrlSession = false, authorizedSecret: string = session.sessionSecret) {

    auditLogger.log({
      sessionId: session.sessionId,
      eventType: 'ws_upgrade_relayed',
      ip: req.socket.remoteAddress ?? 'unknown',
      userAgent: req.headers['user-agent'],
      details: fromUrlSession ? `${url.pathname} (url-session-token)` : url.pathname,
    });

    if (useWssDataPlane) {
      // v3.170：events.* upgrade 也按 pairing 路由——从 session 取 pairingToken
      // 再查 socket。不能用全局 wssAnyReady（多 pairing 时其他 pairing 在线不
      // 代表本 pairing 在线）。
      const sessionPairingKey: PairingKey = session.pairingToken
      const pluginSocket = wssPluginSockets.get(sessionPairingKey)
      if (!pluginSocket || !wssBridgeReadyFor(sessionPairingKey)) {
        socket.write('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }
      const wsClientIp = resolveClientIp(req.socket.remoteAddress, req.headers['x-forwarded-for']?.toString(), trustProxyCsv);
      const wsFrameId = crypto.randomUUID();
      sessionManager.markConnected(session.sessionId);
      sessionManager.markSeen(session.sessionId, wsClientIp);
      liveStreams.set(session.sessionId, (liveStreams.get(session.sessionId) ?? 0) + 1);
      let streamCounted = true;
      const dropStreamOnce = () => {
        if (!streamCounted) return;
        streamCounted = false;
        const n = (liveStreams.get(session.sessionId) ?? 1) - 1;
        if (n > 0) liveStreams.set(session.sessionId, n);
        else liveStreams.delete(session.sessionId);
      };

      const timer = setTimeout(() => {
        wssPendingUpgrades.delete(wsFrameId);
        dropStreamOnce();
        socket.destroy();
      }, 30_000);
      wssPendingUpgrades.set(wsFrameId, { req, socket, head, timer, sessionId: session.sessionId, dropStream: dropStreamOnce, pairingKey: sessionPairingKey, authorizedSecret });

      const upHeaders: Record<string, string> = { host: publicHost };
      if (typeof req.headers.cookie === 'string') upHeaders.cookie = req.headers.cookie;
      const engineToken = sessionManager.currentEngineToken;
      if (engineToken) upHeaders['x-app-token'] = engineToken;
      if (typeof req.headers['user-agent'] === 'string') upHeaders['user-agent'] = req.headers['user-agent'];
      if (typeof req.headers['sec-websocket-protocol'] === 'string') upHeaders['sec-websocket-protocol'] = req.headers['sec-websocket-protocol'];

      try {
        pluginSocket.send(JSON.stringify({
          v: 1, type: 'ws.upgrade', id: wsFrameId,
          path: url.pathname + url.search, headers: upHeaders,
        }));
      } catch {
        clearTimeout(timer);
        wssPendingUpgrades.delete(wsFrameId);
        dropStreamOnce();
        socket.destroy();
      }
      return;
    }

    // 旧 HTTP 数据面回退通道（RELAY_DATA_PLANE=http）——用裸 http.request
    // 与 dsh 握手后双向 pipe（v3.143 baseline）
    const { hostname, port } = parseUpstreamHost(dshUpstream);
    sessionManager.markConnected(session.sessionId);
    const wsClientIp = resolveClientIp(req.socket.remoteAddress, req.headers['x-forwarded-for']?.toString(), trustProxyCsv);
    sessionManager.markSeen(session.sessionId, wsClientIp);
    liveStreams.set(session.sessionId, (liveStreams.get(session.sessionId) ?? 0) + 1);
    let streamCounted = true;
    const dropStream = () => {
      if (!streamCounted) return;
      streamCounted = false;
      const n = (liveStreams.get(session.sessionId) ?? 1) - 1;
      if (n > 0) liveStreams.set(session.sessionId, n);
      else liveStreams.delete(session.sessionId);
    };
    socket.on('close', dropStream);
    const headers: OutgoingHttpHeaders = { ...req.headers, host: publicHost };
    const engineToken = sessionManager.currentEngineToken;
    if (engineToken) headers['x-app-token'] = engineToken;
    else delete headers['x-app-token'];

    const proxyReq = http.request({
      hostname,
      port: Number(port),
      path: url.pathname + url.search,
      method: 'GET',
      headers,
    });
    proxyReq.on('upgrade', (proxyRes, proxySocket, proxyHead) => {
      const statusLine = `HTTP/1.1 ${proxyRes.statusCode} ${proxyRes.statusMessage}\r\n`;
      const headerLines = Object.entries(proxyRes.headers)
        .map(([k, v]) => `${k}: ${Array.isArray(v) ? v.join(', ') : v}\r\n`)
        .join('');
      socket.write(statusLine + headerLines + '\r\n');
      if (proxyHead.length) socket.write(proxyHead);
      proxySocket.pipe(socket);
      socket.pipe(proxySocket);
      proxySocket.on('error', () => socket.destroy());
      proxySocket.on('close', dropStream);
    });
    proxyReq.on('error', (err) => {
      auditLogger.log({
        eventType: 'ws_proxy_error',
        ip: req.socket.remoteAddress ?? 'unknown',
        userAgent: req.headers['user-agent'],
        details: `${url.pathname}: ${err.message}`,
      });
      logger.warn({ url: url.pathname, err: err.message }, 'ws_proxy_error');
      socket.destroy();
    });
    proxyReq.end();
  }

  // v3.152.4：测试期间 fastifyInstance.close() 默认 keep-alive 等满 10s
  // 才返回——同时 patch 内部两个 close 入口都强关 active connections。
  const httpServer = fastify.server as unknown as { forceCloseConnections?: boolean; closeAllConnections?: () => void; closeIdleConnections?: () => void; close(cb?: () => void): void }
  const originalClose = httpServer.close.bind(httpServer)
  httpServer.close = ((cb?: () => void) => {
    try { httpServer.closeAllConnections?.() } catch { /* ignore */ }
    try { httpServer.closeIdleConnections?.() } catch { /* ignore */ }
    return originalClose(cb)
  }) as typeof httpServer.close
  httpServer.forceCloseConnections = true
  const originalFastifyClose = fastify.close.bind(fastify) as unknown as (...args: unknown[]) => Promise<unknown>
  ;(fastify as unknown as { close: typeof originalFastifyClose }).close = ((...callArgs: unknown[]) => {
    try { httpServer.closeAllConnections?.() } catch { /* ignore */ }
    try { httpServer.closeIdleConnections?.() } catch { /* ignore */ }
    return originalFastifyClose(...callArgs as Parameters<typeof originalFastifyClose>)
  }) as typeof originalFastifyClose

return { fastify, sessionManager, auditLogger, _markStreamActive, _markStreamInactive, wsTunnelServer, wssNoServer };
}

/**
 * 只有当本模块就是**进程入口**时才自启 relay。
 *
 * `buildServer` 是库形态：smoke、一次性诊断脚本都会 import 这个模块。原来的
 * `NODE_ENV !== 'test'` 守卫挡不住它们——`server/smoke/harness.mjs` import 之后
 * 会**顺带 listen 默认端口 8080**，于是一台谁也没关的幽灵 relay 占着端口，且
 * 进程永不退出：`smoke:relay` 5 条断言全绿、打印 OK 之后卡住不动，只能 Ctrl-C。
 * 将来任何 import 本模块的工具都会踩同一个坑（症状还特别隐蔽：断言全绿）。
 *
 * 判定用「是不是进程入口」而不是环境变量：环境变量是「调用方要记得配」的约定，
 * 入口判定是 Node 自己的事实。直接 `node dist/index.js` 启动（Dockerfile CMD、
 * npm start、e2e-stub.sh、Dart 集成测试台的 spawn）行为完全不变。
 */
const isProcessEntry = process.argv[1]
  ? import.meta.url === pathToFileURL(process.argv[1]).href
  : false;

if (isProcessEntry && process.env.NODE_ENV !== 'test' && !process.env.VITEST) {
  const config = loadConfig();
  // PSK 决议：env 里有一把像样的就用它；没有（或等于那个公开默认值）就用上次
  // 自动生成落盘的；再没有就**现生成一把并落盘**，只打印路径不打印值——密钥
  // 不进日志，操作者照着路径 `cat` 出来填进 dsh 的 remote.relay.psk。
  const pskResolution = resolvePsk({
    envPsk: process.env.RELAY_PSK,
    dataDir: path.dirname(config.dbPath),
  });
  config.psk = pskResolution.psk;
  // Fail-closed boot: refuse to serve on the default PSK or without a pinned
  // public Host — both silently break the two-gate trust model.
  assertProductionConfig(config);

  if (pskResolution.source !== 'env') {
    console.warn(
      [
        '',
        '  ┌─ relay PSK 需要你做一件事 ─────────────────────────────',
        `  │ 本次启动用的是${pskResolution.source === 'generated' ? '**新生成**的' : '上次生成的'} RELAY_PSK，`,
        `  │ 保存在：${pskResolution.path}`,
        '  │ dsh 客户端的 remote.relay.psk 必须填成同一把，否则隧道连不上。',
        `  │ 查看：cat ${pskResolution.path}`,
        '  └────────────────────────────────────────────────────────',
        '',
      ].join('\n'),
    );
  }

  const { fastify } = await buildServer({
    psk: config.psk,
    dbPath: config.dbPath,
    stateDbPath: config.stateDbPath,
    upstream: config.upstream,
    publicHost: config.publicHost,
    trustProxy: config.trustProxy,
    wsBridgePaths: config.wsBridgePaths,
  });
  const logger = createLogger();

  fastify.listen({ port: config.port, host: config.host }, (err: Error | null, address: string) => {
    if (err) {
      logger.error({ err: err.message }, 'listen_failed');
      process.exit(1);
    }
    logger.info(
      { address, upstream: config.upstream, publicHost: config.publicHost, graceSec: config.sessionGraceSec, maxAgeSec: config.sessionMaxAgeSec },
      'relay_started'
    );
  });
}
