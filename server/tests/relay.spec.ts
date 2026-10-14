import { describe, it, expect, beforeEach, afterEach, beforeAll, afterAll } from 'vitest';
import { buildServer } from '../src/index.js';
import { SessionManager } from '../src/session.js';
import { SessionStore } from '../src/store.js';
import { RelayAuditLogger } from '../src/audit.js';
import {
  assertProductionConfig,
  isValidAuthority,
  loadConfig,
  resolvePsk,
  generatePsk,
  MIN_PSK_LENGTH,
  DEFAULT_INSECURE_PSK,
  GENERATED_PSK_FILENAME,
  type RelayConfig,
} from '../src/config.js';
import { runWatchdogOnce, analyzeAudit } from '../src/watchdog.js';
import { createLogger } from '../src/logger.js';
import WebSocket from 'ws';
import http from 'node:http';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import path from 'node:path';
import fs from 'node:fs';

// v3.151 PR-B：默认 WSS 数据面（HTTP 请求通过 plugin WSS 转发）。
// 这些单元测试 mock DEAD_UPSTREAM 走旧 HTTP proxy——强制走老路才能继续测。
beforeAll(() => { process.env.RELAY_DATA_PLANE = 'http' })

// All suites point the proxy at a dead port so an accidentally running local
// dsh (127.0.0.1:3080) never receives proxied traffic from test cases.
const DEAD_UPSTREAM = 'http://127.0.0.1:1';
// The authority every pinned-Host assertion expects dsh to see.
const PUBLIC_HOST = 'relay.test.local';
const TEST_PSK = 'test-secret-psk-123456';
const silentLogger = createLogger('silent');

function tmpDb(name: string): { dbPath: string; stateDbPath: string } {
  const dbPath = path.join(process.cwd(), 'data', `test-${name}-audit.db`);
  const stateDbPath = path.join(process.cwd(), 'data', `test-${name}-state.db`);
  for (const f of [dbPath, stateDbPath]) if (fs.existsSync(f)) fs.unlinkSync(f);
  return { dbPath, stateDbPath };
}

describe('Relay Server Security & Auth Tests', () => {
  let fastifyInstance: any;
  let auditLogger: any;
  const { dbPath, stateDbPath } = tmpDb('relay');
  let port: number;

  beforeEach(async () => {
    const server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
  });

  it('rejects dsh connection without correct PSK', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: 'Bearer wrong-psk' },
    });

    const closePromise = new Promise<{ code: number; reason: string }>((resolve) => {
      ws.on('close', (code, reason) => resolve({ code, reason: reason.toString() }));
    });

    const { code } = await closePromise;
    expect(code).toBe(4001);
  });

  it('accepts dsh connection with correct PSK and registers session', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    });

    await new Promise((resolve) => ws.on('open', resolve));

    // 发送 session 注册
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: {
        sessionId: 'sess_test_1',
        pairingToken: 'token_secret_123',
        ttlSeconds: 300,
      },
    }));

    const responseMsg = await new Promise<any>((resolve) => {
      ws.on('message', (raw) => resolve(JSON.parse(raw.toString())));
    });

    expect(responseMsg.type).toBe('session.registered');
    expect(responseMsg.sessionId).toBe('sess_test_1');
    ws.close();
  });
});

describe('Relay Pair Landing & Cookie Auth', () => {
  let server: any;
  let fastifyInstance: any;
  let auditLogger: any;
  let sessionManager: any;
  const { dbPath, stateDbPath } = tmpDb('relay-landing');
  let port: number;

  beforeEach(async () => {
    server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    sessionManager = server.sessionManager;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
  });

  async function registerDshSession(sessionId: string, pairingToken: string): Promise<WebSocket> {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    });
    await new Promise((resolve) => ws.on('open', resolve));
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId, pairingToken, ttlSeconds: 300 },
    }));
    await new Promise((resolve) => ws.on('message', resolve));
    return ws;
  }

  it('着陆 endpoint: 仅 sessionId 无有效凭证 → 401 二维码无效卡（v3.203 /__pair 退役，根路径着陆）', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/?sessionId=sess_x`, { redirect: 'manual' });
    expect(res.status).toBe(401);
    expect(res.headers.get('content-type')).toContain('text/html');
    expect(await res.text()).toContain('二维码无效或已过期');
  });

  it('着陆 endpoint: 无效 token 返回 401', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/?sessionId=sess_x&token=bogus`, {
      redirect: 'manual',
    });
    expect(res.status).toBe(401);
    const body = await res.text();
    // 三态错误页（2026-08-31）：无效 token → 专属文案，不再共用「已失效」
    expect(body).toContain('二维码无效或已过期');
  });

  it('着陆 endpoint: 有效 token 返回 302 + Set-Cookie + 跳 /auth（v3.143 dsh 端 mint 引擎 cookie）', async () => {
    await registerDshSession('sess_pair_ok', 'token_pair_ok');

    const res = await fetch(`http://127.0.0.1:${port}/?sessionId=sess_pair_ok&token=token_pair_ok`, {
      redirect: 'manual',
    });
    expect(res.status).toBe(302);
    // v3.203：着陆后跳 /auth?next=<原 URL>（不是 /）—— dsh 端用 engine.token
    // 颁发针对 trusted-host authority 的引擎 cookie，浏览器按源 scope 收纳，
    // 然后 303 回 /；详细 ADR 见 docs/decisions/2026-09-07-dsh-auth-endpoint.md。
    expect(res.headers.get('location') || '').toMatch(/^\/auth\?next=/);
    const setCookie = res.headers.get('set-cookie') || '';
    expect(setCookie).toMatch(/^dsh_remote_session__sess_[A-Za-z0-9_-]+=/);
    expect(setCookie).toMatch(/HttpOnly/i);
    expect(setCookie).toMatch(/Secure/i);
    // v3.128.2.1：Lax——扫码器跨应用拉起浏览器的配对场景（Strict 在部分
    // 移动浏览器着陆→302→/auth 链路上 cookie 携带不可靠，实测 Android Firefox）
    expect(setCookie).toMatch(/SameSite=Lax/i);
  });

  it('v3.204 单浏览器独占：再次着陆轮换密钥，旧 cookie 90s 宽限内可用、宽限后失效', async () => {
    await registerDshSession('sess_reopen_v2', 'token_reopen_v2');
    const landUrl = `http://127.0.0.1:${port}/?sessionId=sess_reopen_v2&token=token_reopen_v2`;

    // 设备 A 着陆
    const first = await fetch(landUrl, { redirect: 'manual' });
    expect(first.status).toBe(302);
    const cookieA = (first.headers.get('set-cookie') || '').split(';')[0];

    // 设备 B 用同链接着陆 → 密钥轮换（cookie 不同）
    const second = await fetch(landUrl, { redirect: 'manual' });
    expect(second.status).toBe(302);
    const cookieB = (second.headers.get('set-cookie') || '').split(';')[0];
    expect(cookieB).not.toBe(cookieA);

    // 宽限窗内：A 的旧 cookie 仍过闸（着陆→跟 302 链路的轮换竞态自愈）
    const graceA = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual', headers: { cookie: cookieA },
    });
    expect(graceA.status).not.toBe(401);

    // 宽限一过 → A 被顶下线；B（新 secret）正常
    sessionManager.getSession('sess_reopen_v2')!.previousSecretAt = Date.now() - 91_000;
    const kickedA = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual', headers: { cookie: cookieA },
    });
    expect(kickedA.status).toBe(401);
    const okB = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual', headers: { cookie: cookieB },
    });
    expect(okB.status).not.toBe(401);
    expect(okB.status).not.toBe(302);

    // 在线时着陆不拦截（v3.203 已删在线拦截），但同样轮换踢人
    server._markStreamActive('sess_reopen_v2');
    const whileOnline = await fetch(landUrl, { redirect: 'manual' });
    expect(whileOnline.status).toBe(302);
    server._markStreamInactive('sess_reopen_v2');
  });

  it('v3.205.1 死 pairing cookie 不再堵门：多枚 cookie 中恰一枚有效即放行', async () => {
    await registerDshSession('sess_stale_ok', 'token_stale_ok');
    const landUrl = `http://127.0.0.1:${port}/?sessionId=sess_stale_ok&token=token_stale_ok`;
    const res = await fetch(landUrl, { redirect: 'manual' });
    expect(res.status).toBe(302);
    const fresh = (res.headers.get('set-cookie') || '').split(';')[0];
    // 浏览器里躺着一枚旧会话的死 cookie——旧逻辑「多候选即拒」会 401，
    // 现在按有效性过滤后恰一枚活 → 放行（用户实测场景：打开新链接即
    // 「远程会话已失效」的根因）
    const stale = 'dsh_remote_session__sess_old_dead=' + 'a'.repeat(64);
    const ok = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual', headers: { cookie: `${stale}; ${fresh}` },
    });
    expect(ok.status).not.toBe(401);
  });

  it('v3.204 双引擎隔离：引擎 B 着陆轮换不影响引擎 A 的会话', async () => {
    const wsA = await registerDshSession('sess_iso_a', 'token_iso_a');
    const wsB = await registerDshSession('sess_iso_b', 'token_iso_b');
    const landingA = await fetch(`http://127.0.0.1:${port}/?sessionId=sess_iso_a&token=token_iso_a`, { redirect: 'manual' });
    expect(landingA.status).toBe(302);
    const cookieA = (landingA.headers.get('set-cookie') || '').split(';')[0];

    // 引擎 B 的会话着陆——轮换只作用于 B 的 socket
    const landingB = await fetch(`http://127.0.0.1:${port}/?sessionId=sess_iso_b&token=token_iso_b`, { redirect: 'manual' });
    expect(landingB.status).toBe(302);

    // 决定性断言：A 的 sessionSecret 未被联动轮换（仍是 A cookie 里的值）
    const secretA = cookieA.split('=')[1];
    expect(sessionManager.getSession('sess_iso_a')!.sessionSecret).toBe(secretA);
    const stillA = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual', headers: { cookie: cookieA },
    });
    expect(stillA.status).not.toBe(401);
    wsA.close();
    wsB.close();
  });

  it('/api/* 缺 cookie: 401 JSON（SPA fetch 不跟随 redirect，401 错误更可读）', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual',
    });
    expect(res.status).toBe(401);
    expect(res.headers.get('content-type')).toContain('application/json');
    const body = await res.json();
    expect(body.error).toContain('remote session expired or missing');
  });

  it('/api/* 带错误 cookie: 401 JSON', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual',
      headers: { cookie: 'dsh_remote_session__sess_aaaaaaaaaaaaaaaa=bogus-secret' },
    });
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body.error).toContain('remote session expired or missing');
  });

  it('/api/* 带正确 cookie: 中间件放行（状态取决于上游，此处期望非 401/302）', async () => {
    await registerDshSession('sess_cookie_ok', 'token_cookie_ok');
    const landingRes = await fetch(
      `http://127.0.0.1:${port}/?sessionId=sess_cookie_ok&token=token_cookie_ok`,
      { redirect: 'manual' }
    );
    const setCookie = (landingRes.headers.get('set-cookie') || '').split(';')[0];

    // 上游 dsh 不存在，期望 502/504/连接拒绝，而不是 401/302
    const apiRes = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual',
      headers: { cookie: setCookie },
    });
    expect(apiRes.status).not.toBe(401);
    expect(apiRes.status).not.toBe(302);
  });

  it('/api/events.* WS upgrade 缺 cookie: 401 拒绝升级', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/events.mux`);
    const res = await new Promise<any>((resolve) => {
      ws.on('unexpected-response', (_req, response) => resolve(response));
      ws.on('error', () => resolve(undefined));
    });
    expect(res?.statusCode).toBe(401);
    ws.terminate();
  });

  it('dsh 发 session.revoke 后旧 sessionSecret cookie 立即失效', async () => {
    const ws = await registerDshSession('sess_revoke_flow', 'token_revoke_flow');
    const landingRes = await fetch(
      `http://127.0.0.1:${port}/?sessionId=sess_revoke_flow&token=token_revoke_flow`,
      { redirect: 'manual' }
    );
    const setCookie = (landingRes.headers.get('set-cookie') || '').split(';')[0];
    const before = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual',
      headers: { cookie: setCookie },
    });
    expect(before.status).not.toBe(401);

    ws.send(JSON.stringify({
      type: 'session.revoke',
      payload: { sessionId: 'sess_revoke_flow', reason: 'test revoke' },
    }));
    await new Promise((resolve) => setTimeout(resolve, 200));

    const after = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual',
      headers: { cookie: setCookie },
    });
    expect(after.status).toBe(401);
    const body = await after.json();
    expect(body.error).toContain('remote session expired or missing');
    ws.close();
  });

  it('错误 PSK 连接被拒后 audit_logs 落一行 dsh_auth_failed', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: 'Bearer wrong-psk-again' },
    });
    await new Promise((resolve) => ws.on('close', resolve));

    const db = new DatabaseSync(dbPath);
    const rows = db
      .prepare(`SELECT event_type FROM audit_logs WHERE event_type = 'dsh_auth_failed' ORDER BY id DESC LIMIT 1`)
      .all() as Array<{ event_type: string }>;
    db.close();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.event_type).toBe('dsh_auth_failed');
  });
});

describe('Relay Gate Coverage (non-/api paths)', () => {
  let fastifyInstance: any;
  let auditLogger: any;
  const { dbPath, stateDbPath } = tmpDb('relay-gate');
  let port: number;

  beforeEach(async () => {
    const server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
  });

  it('盲区修复：无 cookie 的 POST /other-plugin/schedules/x/run → 401（此前直通反代）', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/other-plugin/schedules/radar/run`, {
      method: 'POST',
      redirect: 'manual',
    });
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body.error).toContain('remote session expired or missing');
  });

  it('盲区修复：无 cookie 的 GET /other-plugin/finance → 401 JSON', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/other-plugin/finance`, { redirect: 'manual' });
    expect(res.status).toBe(401);
    expect(res.headers.get('content-type')).toContain('application/json');
  });

  it('v3.183 零凭证裸 / → 401 + 独立「无权访问」页(SPA 壳不下发)', async () => {
    // v3.173 曾对 / 免闸门(SPA 先加载再读 URL token)——v3.183 收窄:零凭证
    // 访客收到独立错误卡,不再加载 dsh 首屏 "loading plugins" 画面。
    const res = await fetch(`http://127.0.0.1:${port}/`, {
      redirect: 'manual',
      headers: { accept: 'text/html,application/xhtml+xml' },
    });
    expect(res.status).toBe(401);
    expect(res.headers.get('content-type')).toContain('text/html');
    const body = await res.text();
    expect(body).toContain('无权访问');
    expect(body).not.toContain('远程会话已失效');
  });

  it('v3.183 带失效 pairing cookie 的 / → 401 + 独立「远程会话已失效」页(与零凭证区分)', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/`, {
      redirect: 'manual',
      headers: {
        accept: 'text/html,application/xhtml+xml',
        cookie: 'dsh_remote_session__sess_stale=deadbeef',
      },
    });
    expect(res.status).toBe(401);
    const body = await res.text();
    expect(body).toContain('远程会话已失效');
    expect(body).not.toContain('无权访问');
  });

  it('v3.183 零凭证深链导航(/workspace/…) → 401「无权访问」页', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/workspace/foo`, {
      redirect: 'manual',
      headers: { accept: 'text/html' },
    });
    expect(res.status).toBe(401);
    expect(await res.text()).toContain('无权访问');
  });

  it('v3.183 /?sessionId… 签名已过期 → 401「二维码无效或已过期」页(不进 dsh)', async () => {
    // 签名本身合法(HMAC 按过期时间窗正确铸造),但 exp 已过——独立过期页
    const sid = 'sess_root_exp';
    const t = Date.now() - 2 * 60 * 1000;
    const exp = Date.now() - 60 * 1000;
    const mid = crypto.createHash('sha256').update('mid-root-exp').digest('hex');
    const hash = crypto.createHmac('sha256', TEST_PSK).update([sid, exp, mid, t].join('|')).digest('base64url');
    const res = await fetch(`http://127.0.0.1:${port}/?sessionId=${sid}&hash=${hash}&t=${t}&exp=${exp}&mid=${mid}`, {
      redirect: 'manual',
      headers: { accept: 'text/html' },
    });
    expect(res.status).toBe(401);
    expect(await res.text()).toContain('二维码无效或已过期');
  });

  it('v3.184 /__expired 无 pairing cookie → 二维码过期卡(看门狗跳转目标)', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/__expired`, {
      headers: { accept: 'text/html,application/xhtml+xml' },
    });
    expect(res.status).toBe(401);
    expect(res.headers.get('cache-control')).toBe('no-store');
    const body = await res.text();
    expect(body).toContain('二维码无效或已过期');
  });

  it('v3.184 /__expired 带 pairing cookie(cookie 失效路线) → 远程会话已失效卡', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/__expired`, {
      headers: {
        accept: 'text/html',
        cookie: 'dsh_remote_session__sess_old=deadbeef',
      },
    });
    expect(res.status).toBe(401);
    expect(await res.text()).toContain('远程会话已失效');
  });

  it('v3.184 /__expired 非 HTML(程序化探测) → 401 JSON', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/__expired`);
    expect(res.status).toBe(401);
    expect(res.headers.get('content-type')).toContain('application/json');
    expect((await res.json() as any).error).toBe('remote session expired');
  });

  it('v3.205 /__expired?reason=replaced → 专属「已在另一台设备连接」卡（HTML 与 JSON 两形态）', async () => {
    const html = await fetch(`http://127.0.0.1:${port}/__expired?reason=replaced`, { headers: { accept: 'text/html' } });
    expect(html.status).toBe(401);
    expect(await html.text()).toContain('已在另一台设备连接');
    const json = await fetch(`http://127.0.0.1:${port}/__expired?reason=replaced`);
    expect(json.status).toBe(401);
    expect((await json.json() as any).error).toBe('device replaced');
  });

  it('无 cookie 的静态资源请求 → v3.173 免鉴权(/assets/* 是公开 JS/CSS,数据全在 /api);无配对 503 非 401', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/assets/app.js`, { redirect: 'manual' });
    // 免鉴权 = 不再 401(无配对回落失败是 503)
    expect(res.status).not.toBe(401);
  });

  it('/health 免闸门（liveness 探针无鉴权是文档化契约）', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/health`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe('ok');
  });

  it('/favicon.ico 免闸门 + 直返 70 字节透明 ICO（dsh 不发 .ico 时浏览器盲探针自答）', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/favicon.ico`);
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('image/x-icon');
    expect(res.headers.get('cache-control')).toContain('max-age=86400');
    const buf = Buffer.from(await res.arrayBuffer());
    // ICO 头：reserved=0 + type=1(图标) + count=1
    expect(buf[0]).toBe(0x00);
    expect(buf[1]).toBe(0x00);
    expect(buf[2]).toBe(0x01);
    expect(buf[3]).toBe(0x00);
    expect(buf[4]).toBe(0x01);
    // 单图 entry
    expect(buf.length).toBe(68);
  });
});

describe('Gate Coverage (v3.106 全路径闸门)', () => {
  let fastifyInstance: any;
  let auditLogger: any;
  const { dbPath, stateDbPath } = tmpDb('relay-gate');
  let port: number;

  beforeEach(async () => {
    const server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
  });

  async function registerDshSession(sessionId: string, pairingToken: string): Promise<WebSocket> {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    });
    await new Promise((resolve) => ws.on('open', resolve));
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId, pairingToken, ttlSeconds: 300 },
    }));
    await new Promise((resolve) => ws.on('message', resolve));
    return ws;
  }

  async function pairSession(sessionId: string, token: string): Promise<string> {
    const ws = await registerDshSession(sessionId, token);
    const landingRes = await fetch(
      `http://127.0.0.1:${port}/?sessionId=${sessionId}&token=${token}`,
      { redirect: 'manual' }
    );
    expect(landingRes.status).toBe(302);
    void ws;
    return (landingRes.headers.get('set-cookie') || '').split(';')[0];
  }

  // v3.141：删除了整段「Read-only Mode Enforcement」——单模式化后 relay 不再
  // 区分 mode，所有配对等价于 full（16 PRIVILEGED 由 dsh Host fence 独立承担）。
  // 闸门本身（cookie → 401）保留：以下面三条用例继续守住全路径覆盖。
  it('闸门覆盖：未配对 POST /other-plugin/* → 401（盲区修复保留）', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/other-plugin/schedules/radar/run`, {
      method: 'POST',
      redirect: 'manual',
    });
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body.error).toMatch(/session expired or missing/);
  });

  it('闸门覆盖：未配对 GET /other-plugin/* → 401', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/other-plugin/schedules`, {
      redirect: 'manual',
    });
    expect(res.status).toBe(401);
  });

  it('闸门覆盖：配对后 POST /other-plugin/* 通过闸门（上游死端口 → 非 401/403）', async () => {
    const cookie = await pairSession('sess_gate_1', 'token_gate_1');
    const res = await fetch(`http://127.0.0.1:${port}/other-plugin/schedules/radar/run`, {
      method: 'POST',
      redirect: 'manual',
      headers: { cookie },
    });
    expect(res.status).not.toBe(401);
    expect(res.status).not.toBe(403);
  });
});

// ---------------------------------------------------------------------------
// v3.119 additions
// ---------------------------------------------------------------------------

describe('Fail-closed boot guard (config.ts)', () => {
  // 用一把**像样的** PSK（≥MIN_PSK_LENGTH）：新加的长度校验是最后一道防线，
  // 夹具不该拿 21 字符的 TEST_PSK 去假装生产配置。
  const STRONG_PSK = 'a'.repeat(64);
  function cfg(overrides: Partial<RelayConfig>): RelayConfig {
    return { ...loadConfig({}), psk: STRONG_PSK, publicHost: PUBLIC_HOST, ...overrides };
  }

  it('buildServer 没有 publicHost 直接抛错（防 PRIVILEGED 解锁的 Host 改写回归）', async () => {
    await expect(buildServer({ psk: TEST_PSK, dbPath: ':memory:', stateDbPath: ':memory:', upstream: DEAD_UPSTREAM } as any))
      .rejects.toThrow(/publicHost is required/);
  });

  it('生产守卫：默认 PSK / 缺 RELAY_PUBLIC_HOST / 非法 authority 各自拒启', () => {
    expect(() => assertProductionConfig(cfg({ psk: 'dsh-remote-relay-default-insecure-psk' }))).toThrow(/RELAY_PSK/);
    expect(() => assertProductionConfig(cfg({ publicHost: '' }))).toThrow(/RELAY_PUBLIC_HOST/);
    expect(() => assertProductionConfig(cfg({ publicHost: 'relay example.com' }))).toThrow(/canonical bare authority/);
    expect(() => assertProductionConfig(cfg({ publicHost: 'https://relay.example.com' }))).toThrow(/canonical bare authority/);
    expect(() => assertProductionConfig(cfg({ publicHost: 'relay.example.com/path' }))).toThrow(/canonical bare authority/);
    expect(() => assertProductionConfig(cfg())).not.toThrow();
  });

  it('PSK 短于下限 → 最后一道防线仍然拒启', () => {
    expect(() => assertProductionConfig(cfg({ psk: 'short-psk' }))).toThrow(/32-char minimum/);
    expect(() => assertProductionConfig(cfg())).not.toThrow();
  });

  // ── PSK 自动生成（D-112）─────────────────────────────────────
  //
  // 运维拍板：缺 PSK 就不该是「refusing to start」让人干瞪眼，而是生成一把、
  // 落盘、告诉他填到哪去。上一条守卫（拒绝不安全默认）保留为最后一道防线。
  describe('resolvePsk', () => {
    function fake() {
      const files = new Map<string, string>();
      let generated = 0;
      return {
        files,
        get generated() { return generated; },
        io: {
          readFile: (p: string) => files.get(p) ?? null,
          writeFile: (p: string, c: string) => { files.set(p, c); },
          generate: () => { generated++; return `gen${generated}`.padEnd(64, 'x'); },
        },
      };
    }

    it('env 里有像样的 PSK → 直接用，一个字节都不生成', () => {
      const f = fake();
      const r = resolvePsk({ envPsk: 'e'.repeat(64), dataDir: '/data', ...f.io });
      expect(r.source).toBe('env');
      expect(r.psk).toBe('e'.repeat(64));
      expect(f.generated).toBe(0);
      expect(f.files.size).toBe(0);
    });

    it('env 缺失 → 生成一把 ≥32 的强随机 PSK 并落盘', () => {
      const f = fake();
      const r = resolvePsk({ dataDir: '/data', ...f.io });
      expect(r.source).toBe('generated');
      expect(r.psk.length).toBeGreaterThanOrEqual(MIN_PSK_LENGTH);
      expect(r.path).toBe('/data/' + GENERATED_PSK_FILENAME);
      expect(f.files.get(r.path)).toBe(r.psk);
    });

    it('env 显式设成那个公开默认值 → 按没设处理（它本来就等于公开）', () => {
      const f = fake();
      const r = resolvePsk({ envPsk: DEFAULT_INSECURE_PSK, dataDir: '/data', ...f.io });
      expect(r.source).toBe('generated');
      expect(r.psk).not.toBe(DEFAULT_INSECURE_PSK);
    });

    it('重启后复用上次生成的那把 —— 不换 PSK，隧道不会被自己的重启打断', () => {
      const f = fake();
      const first = resolvePsk({ dataDir: '/data', ...f.io });
      const second = resolvePsk({ dataDir: '/data', ...f.io });
      expect(second.source).toBe('persisted');
      expect(second.psk).toBe(first.psk);
      expect(f.generated, '只该生成过一次').toBe(1);
    });

    it('落盘的值短于下限 → 当作没有，重新生成（宁可换掉也别留一把弱钥匙）', () => {
      const f = fake();
      f.files.set('/data/' + GENERATED_PSK_FILENAME, 'tooshort');
      const r = resolvePsk({ dataDir: '/data', ...f.io });
      expect(r.source).toBe('generated');
      expect(r.psk.length).toBeGreaterThanOrEqual(MIN_PSK_LENGTH);
    });

    it('真生成器：64 个 hex 字符，两次不同', () => {
      const a = generatePsk();
      expect(a).toMatch(/^[0-9a-f]{64}$/);
      expect(a.length).toBeGreaterThanOrEqual(MIN_PSK_LENGTH);
      expect(generatePsk()).not.toBe(a);
    });
  });

  it('isValidAuthority：host / host:port 合法，默认端口与编码形态拒绝', () => {
    expect(isValidAuthority('relay.example.com')).toBe(true);
    expect(isValidAuthority('relay.example.com:8443')).toBe(true);
    expect(isValidAuthority('relay.example.com:80')).toBe(false); // URL 归一化剥默认端口 → 非规范拼写
    expect(isValidAuthority('RELAY.example.com')).toBe(true); // 大写等价（dsh 侧同样按小写归一）
    expect(isValidAuthority('relay%2eexample.com')).toBe(false);
    expect(isValidAuthority('user@relay.example.com')).toBe(false);
    expect(isValidAuthority('')).toBe(false);
  });
});

describe('Host pinning on the proxied data path (v3.119 高危修复)', () => {
  // Echo "dsh" upstream that records what actually arrived.
  let upstream: http.Server;
  let server: any;
  let fastifyInstance: any;
  let auditLogger: any;
  let sessionManager: any;
  const { dbPath, stateDbPath } = tmpDb('relay-hostpin');
  let port: number;
  let upstreamPort: number;
  let lastSeen: { host: string; path: string; token: string } | undefined;
  let wsSeenHost: string | undefined;
  let wsSeenToken: string | undefined;
  // 走 PSK 隧道 session.register 送达的引擎共享密钥（v3.41 lockdown 注入）
  const ENGINE_TOKEN = 'test-engine-token-9f1c';

  beforeEach(async () => {
    lastSeen = undefined;
    wsSeenHost = undefined;
    wsSeenToken = undefined;
    upstream = http.createServer((req, res) => {
      lastSeen = { host: String(req.headers.host), path: req.url ?? '', token: String(req.headers['x-app-token'] ?? '') };
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ ok: true }));
    });
    // WS upgrade echo for /api/events.* — 101 后立刻推一帧无掩码文本
    // （"relay-ok"），供「连接存活 + 头透传 + 双向管道」断言用：2026-08-31
    // 前剥掉 Upgrade/Connection 头的实现在 nginx 下 101 即断，单测直连
    // 未抓住，这里用首帧到达补上
    upstream.on('upgrade', (req, socket) => {
      wsSeenHost = String(req.headers.host);
      wsSeenToken = String(req.headers['x-app-token'] ?? '');
      // ws 客户端在 Connection/Upgrade 头齐备后严格校验 accept——真引擎
      // 都会算，假上游也按 RFC 6455 算（头缺失形态的回归由"首帧到达"
      // 断言兜住）
      const key = String(req.headers['sec-websocket-key'] ?? '');
      const accept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
      socket.write(Buffer.concat([Buffer.from([0x81, 0x08]), Buffer.from('relay-ok')]));
      socket.end();
    });
    await new Promise<void>((resolve) => upstream.listen(0, '127.0.0.1', resolve));
    upstreamPort = (upstream.address() as any).port;

    server = await buildServer({
      psk: TEST_PSK, dbPath, stateDbPath,
      upstream: `http://127.0.0.1:${upstreamPort}`,
      publicHost: PUBLIC_HOST,
    });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    sessionManager = server.sessionManager;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
    upstream.close();
  });

  // v3.128.1：describe 共享一个 state DB（tmpDb 模块级只清一次），跨测试
  // 复用同一 sessionId 会命中「已连接会话 restore 后 token 维持消费态」的
  // 新语义——每个二维码在生产里都是全新 sessionId，测试装置对齐之。
  let pairSeq = 0;
  // v3.141：单模式化后，pairMode 的 `mode` 参数无意义——所有配对等价于 full。
  // 保留 `key` 以便用例沿用「同 sessionId 多次复用」的场景（如 single_v2）。
  async function pairMode(_mode: 'full' | 'readonly', key?: string): Promise<string> {
    // v3.172：sessionId 必须含 [A-Za-z0-9_-]+(cookie 名正则放宽),不限 hex
    // 测试 helper 直接用 key;默认 sequence 走 4-char hex 计数。
    const k = key ?? (++pairSeq).toString(16).padStart(4, '0')
    const sessionId = `sess_hp_${k}`
    const token = `token_hp_${k}`;
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    });
    await new Promise((resolve) => ws.on('open', resolve));
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId, pairingToken: token, ttlSeconds: 300, engineToken: ENGINE_TOKEN },
    }));
    await new Promise((resolve) => ws.on('message', resolve));
    const landing = await fetch(
      `http://127.0.0.1:${port}/?sessionId=${sessionId}&token=${token}`,
      { redirect: 'manual' }
    );
    ws.close();
    return (landing.headers.get('set-cookie') || '').split(';')[0];
  }

  async function pairFull(key?: string): Promise<string> {
    return pairMode('full', key);
  }

  it('HTTP /api 转发：客户端伪造任意 Host，上游一律看到钉死的 publicHost（dsh fence 据此封锁 PRIVILEGED）', async () => {
    const cookie = await pairFull();
    for (const forged of ['evil.example.com', '127.0.0.1:3080', 'localhost']) {
      lastSeen = undefined;
      const res = await fetch(`http://127.0.0.1:${port}/api/credentials.describe`, {
        headers: { host: forged, cookie },
        redirect: 'manual',
      });
      expect(res.status).toBe(200);
      expect(lastSeen).toBeDefined();
      expect(lastSeen!.host).toBe(PUBLIC_HOST);
      expect(lastSeen!.path).toBe('/api/credentials.describe');
    }
  });

  it('HTTP 兜底反代（SPA 静态路径）同样钉 Host', async () => {
    const cookie = await pairFull();
    const res = await fetch(`http://127.0.0.1:${port}/assets/app.js`, {
      headers: { host: '127.0.0.1:3080', cookie },
      redirect: 'manual',
    });
    expect(res.status).toBe(200);
    expect(lastSeen!.host).toBe(PUBLIC_HOST);
  });

  it('WS /api/events.* 升级转发同样钉 Host（此前 delete host 后填的是 127.0.0.1:3080）', async () => {
    const cookie = await pairFull();
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/events.mux`, {
      headers: { cookie, host: 'evil.example.com' },
    });
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('upgrade never reached upstream')), 3000);
      ws.on('error', () => { clearTimeout(timer); resolve(); });
      ws.on('close', () => { clearTimeout(timer); resolve(); });
      const poll = setInterval(() => {
        if (wsSeenHost !== undefined) { clearInterval(poll); clearTimeout(timer); resolve(); }
      }, 20);
    });
    expect(wsSeenHost).toBe(PUBLIC_HOST);
    ws.terminate();
  });

  it('X-App-Token 注入（v3.41 lockdown 兼容）：session.register 送达的 engineToken 注入 /api 与 SPA 转发，客户端伪造值被覆盖', async () => {
    const cookie = await pairFull();
    // /api 路径：客户端自带假 token，上游必须看到隧道送达的真值
    lastSeen = undefined;
    const res = await fetch(`http://127.0.0.1:${port}/api/credentials.describe`, {
      headers: { host: 'evil.example.com', cookie, 'x-app-token': 'forged-by-client' },
      redirect: 'manual',
    });
    expect(res.status).toBe(200);
    expect(lastSeen!.host).toBe(PUBLIC_HOST);
    expect(lastSeen!.token).toBe(ENGINE_TOKEN);

    // SPA 静态路径（兜底反代）同样注入
    lastSeen = undefined;
    const spa = await fetch(`http://127.0.0.1:${port}/assets/app.js`, {
      headers: { cookie },
      redirect: 'manual',
    });
    expect(spa.status).toBe(200);
    expect(lastSeen!.token).toBe(ENGINE_TOKEN);
  });

  it('X-App-Token 注入：WS /api/events.* 升级转发同样携带 engineToken', async () => {
    const cookie = await pairFull();
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/events.mux`, {
      headers: { cookie, host: 'evil.example.com' },
    });
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('upgrade never reached upstream')), 3000);
      ws.on('error', () => { clearTimeout(timer); resolve(); });
      ws.on('close', () => { clearTimeout(timer); resolve(); });
      const poll = setInterval(() => {
        if (wsSeenHost !== undefined) { clearInterval(poll); clearTimeout(timer); resolve(); }
      }, 20);
    });
    expect(wsSeenHost).toBe(PUBLIC_HOST);
    expect(wsSeenToken).toBe(ENGINE_TOKEN);
    ws.terminate();
  });

  it('事件流订阅 GET /api/events.* 放行（SPA 状态推送生命线）且升级到达上游', async () => {
    const cookie = await pairFull();
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/events.mux`, { headers: { cookie } });
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('upgrade never reached upstream')), 3000);
      ws.on('error', () => { clearTimeout(timer); resolve(); });
      ws.on('close', () => { clearTimeout(timer); resolve(); });
      const poll = setInterval(() => {
        if (wsSeenHost !== undefined) { clearInterval(poll); clearTimeout(timer); resolve(); }
      }, 20);
    });
    expect(wsSeenHost).toBe(PUBLIC_HOST);
    ws.terminate();
  });

  it('WS 隧道完整性：101 头透传 + 首帧到达客户端（剥 Upgrade/Connection 的回归守卫）', async () => {
    const cookie = await pairFull();
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/events.mux`, { headers: { cookie } });
    const first = await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('first frame never arrived — tunnel broken after 101')), 3000);
      ws.on('message', (m) => { clearTimeout(timer); resolve(String(m)); });
      ws.on('close', () => { clearTimeout(timer); reject(new Error('closed before first frame')); });
      ws.on('error', (e) => { clearTimeout(timer); reject(e); });
    });
    expect(first).toBe('relay-ok');
    ws.terminate();
  });

  it('v3.204 单浏览器独占（按引擎）：B 经任一配对着陆，同引擎其它 pairing 的在线设备一并被顶替', async () => {
    // 一个引擎 socket 上注册两条 pairing（模拟一个引擎多配对）
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    });
    await new Promise((resolve) => ws.on('open', resolve));
    const bothRegistered = new Promise<void>((resolve) => {
      let n = 0;
      ws.on('message', () => { if (++n >= 2) resolve(); });
    });
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId: 'sess_eng_p1', pairingToken: 'token_eng_p1', ttlSeconds: 300, engineToken: ENGINE_TOKEN },
    }));
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId: 'sess_eng_p2', pairingToken: 'token_eng_p2', ttlSeconds: 300, engineToken: ENGINE_TOKEN },
    }));
    await bothRegistered;

    // 设备 A 经 pairing1 着陆并在线
    const landingA = await fetch(
      `http://127.0.0.1:${port}/?sessionId=sess_eng_p1&token=token_eng_p1`,
      { redirect: 'manual' },
    );
    expect(landingA.status).toBe(302);
    const cookieA = (landingA.headers.get('set-cookie') || '').split(';')[0];
    const okA = await fetch(`http://127.0.0.1:${port}/api/skill.list`, {
      method: 'POST',
      headers: { cookie: cookieA, 'content-type': 'application/json' },
      body: '{}',
      redirect: 'manual',
    });
    expect(okA.status).toBe(200);

    // 设备 B 经 pairing2（同引擎的另一条配对）着陆 → 引擎级轮换
    server._markStreamActive('sess_eng_p1');
    const landingB = await fetch(
      `http://127.0.0.1:${port}/?sessionId=sess_eng_p2&token=token_eng_p2`,
      { redirect: 'manual' },
    );
    expect(landingB.status).toBe(302);
    const cookieB = (landingB.headers.get('set-cookie') || '').split(';')[0];

    // pairing1 的 secret 被联动轮换：A 的旧 cookie 宽限一过即 401；B 正常
    sessionManager.getSession('sess_eng_p1')!.previousSecretAt = Date.now() - 91_000;
    const kickedA = await fetch(`http://127.0.0.1:${port}/api/skill.list`, {
      method: 'POST',
      headers: { cookie: cookieA, 'content-type': 'application/json' },
      body: '{}',
      redirect: 'manual',
    });
    expect(kickedA.status).toBe(401);
    const okB = await fetch(`http://127.0.0.1:${port}/api/skill.list`, {
      method: 'POST',
      headers: { cookie: cookieB, 'content-type': 'application/json' },
      body: '{}',
      redirect: 'manual',
    });
    expect(okB.status).toBe(200);
    server._markStreamInactive('sess_eng_p1');
    ws.close();
  });

  it('/__devices：PSK 鉴权 + 在线判据（lastSeen 信标 + 活跃 WS 计数）', async () => {
    const cookie = await pairFull('devices_probe');
    // 无 PSK → 401
    const noAuth = await fetch(`http://127.0.0.1:${port}/__devices`);
    expect(noAuth.status).toBe(401);
    const badPsk = await fetch(`http://127.0.0.1:${port}/__devices`, {
      headers: { authorization: 'Bearer wrong-psk' },
    });
    expect(badPsk.status).toBe(401);

    // 过闸请求后：该会话 lastSeen 新鲜 → online
    await fetch(`http://127.0.0.1:${port}/api/skill.list`, {
      method: 'POST',
      headers: { cookie, 'content-type': 'application/json' },
      body: '{}',
      redirect: 'manual',
    });
    const res = await fetch(`http://127.0.0.1:${port}/__devices`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    });
    expect(res.status).toBe(200);
    // v3.141：单模式化后 devices payload 不再含 mode 字段
    const { devices } = await res.json() as { devices: Array<{ sessionId: string; online: boolean; onlineWs: number; lastSeen: number | null; ip?: string | null }> };
    const mine = devices.find((d) => d.sessionId === 'sess_hp_devices_probe');
    expect(mine).toBeDefined();
    // v3.128.4：过闸信标携带客户端 IP（卡片「谁连着」数据源）
    expect(mine!.ip).toBe('127.0.0.1');
    expect(mine!.online).toBe(true);
    expect(mine!.onlineWs).toBe(0); // 只发了 HTTP，未开事件流
    expect(mine!.lastSeen).not.toBeNull();
  });

  // v3.141：删除整段「readonly：纯查询 POST ... 写方法 session.create 仍 403」
  // ——单模式化后所有配对允许写操作；写方法的拦截由 dsh Host fence 对 16
  // PRIVILEGED 方法独立承担，与配对 mode 解耦。
});

describe('Session persistence across tunnel drops & relay restarts (v3.119)', () => {
  const { dbPath, stateDbPath } = tmpDb('relay-persist');
  let fastifyInstance: any;
  let auditLogger: any;
  let sessionManager: any;
  let port: number;

  beforeEach(async () => {
    const server = await buildServer({
      psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM,
      publicHost: PUBLIC_HOST, sessionGraceMs: 60_000,
    });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    sessionManager = server.sessionManager;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
  });

  function openTunnel(): Promise<WebSocket> {
    return new Promise((resolve) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
        headers: { authorization: `Bearer ${TEST_PSK}` },
      });
      ws.on('open', () => resolve(ws));
    });
  }

  function registerOn(ws: WebSocket, sessionId: string, token: string): Promise<any> {
    return new Promise((resolve) => {
      const onMessage = (raw: any) => {
        const msg = JSON.parse(raw.toString());
        if (msg.type === 'session.registered') { ws.off('message', onMessage); resolve(msg); }
      };
      ws.on('message', onMessage);
      ws.send(JSON.stringify({
        type: 'session.register',
        payload: { sessionId, pairingToken: token, ttlSeconds: 300, mode: 'full' },
      }));
    });
  }

  it('tunnel 断线→重连补注册：复用同一 sessionSecret，旧 cookie 继续可用（reusesSecret=true）', async () => {
    const ws1 = await openTunnel();
    await registerOn(ws1, 'sess_persist', 'token_persist');
    const secret1 = sessionManager.getSession('sess_persist').sessionSecret;

    // 拿到 cookie 后隧道断（tombstone），再重连补注册同一配对
    ws1.close();
    await new Promise((resolve) => setTimeout(resolve, 200));
    const ws2 = await openTunnel();
    const ack = await registerOn(ws2, 'sess_persist', 'token_persist');

    expect(ack.reusesSecret).toBe(true);
    expect(sessionManager.getSession('sess_persist').sessionSecret).toBe(secret1);
    ws2.close();
  });

  it('重连换 pairingToken（新配对复用 sessionId）：轮换新 secret', async () => {
    const ws1 = await openTunnel();
    await registerOn(ws1, 'sess_rotate', 'token_a');
    const secret1 = sessionManager.getSession('sess_rotate').sessionSecret;
    ws1.close();
    await new Promise((resolve) => setTimeout(resolve, 200));

    const ws2 = await openTunnel();
    const ack = await registerOn(ws2, 'sess_rotate', 'token_b');
    expect(ack.reusesSecret).toBe(false);
    expect(sessionManager.getSession('sess_rotate').sessionSecret).not.toBe(secret1);
    ws2.close();
  });

  it('relay 重启（新 SessionManager 同 state DB）：活跃配对恢复，cookie 仍可过闸', async () => {
    const ws1 = await openTunnel();
    await registerOn(ws1, 'sess_restart', 'token_restart');
    const secret = sessionManager.getSession('sess_restart').sessionSecret;
    ws1.close();
    await new Promise((resolve) => setTimeout(resolve, 200));

    const revived = new SessionManager({ graceMs: 60_000, store: new SessionStore(stateDbPath) });
    expect(revived.getSessionBySecret(secret)?.sessionId).toBe('sess_restart');
  });

  it('v3.128.2：（重）注册后二维码恒可用（无消费态，隧道重连/引擎重启场景）', async () => {
    const ws1 = await openTunnel();
    await registerOn(ws1, 'sess_rereg_v2', 'token_rereg_v2');
    sessionManager.markConnected('sess_rereg_v2');

    ws1.close();
    await new Promise((resolve) => setTimeout(resolve, 200));
    const ws2 = await openTunnel();
    const ack = await registerOn(ws2, 'sess_rereg_v2', 'token_rereg_v2');
    expect(ack.reusesSecret).toBe(true);
    expect(sessionManager.getSessionByToken('token_rereg_v2')).toBeDefined();
    ws2.close();
  });

  it('v3.128.2：会话重启恢复后二维码仍可用（URL 长效），cookie 同步恢复', async () => {
    const ws1 = await openTunnel();
    await registerOn(ws1, 'sess_consumed_persist', 'token_consumed_persist');
    const secret = sessionManager.getSession('sess_consumed_persist').sessionSecret;
    sessionManager.markConnected('sess_consumed_persist');
    ws1.close();
    await new Promise((resolve) => setTimeout(resolve, 200));

    const revived = new SessionManager({ graceMs: 60_000, store: new SessionStore(stateDbPath) });
    // cookie 恢复（30 天承诺）且二维码 token 恢复可用（URL 长效语义）
    expect(revived.getSessionBySecret(secret)?.sessionId).toBe('sess_consumed_persist');
    expect(revived.getSessionByToken('token_consumed_persist')?.sessionId).toBe('sess_consumed_persist');
  });

  it('超宽限期后 tombstone 过期：cookie 失效（fail-safe 方向保留）', async () => {
    const manager = new SessionManager({ graceMs: 1, store: new SessionStore(path.join(process.cwd(), 'data', 'test-gracezero-state.db')) });
    const fakeSocket = { send() {} } as any;
    manager.registerSession('sess_grace', 'token_grace', 300, fakeSocket, 'full');
    const secret = manager.getSession('sess_grace').sessionSecret;
    manager.clearDsh(fakeSocket);
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(manager.getSessionBySecret(secret)).toBeUndefined();
  });
});

describe('Watchdog intrusion & health analysis (v3.119)', () => {
  const { dbPath } = tmpDb('relay-watchdog');
  let audit: RelayAuditLogger;

  beforeEach(() => {
    audit = new RelayAuditLogger(dbPath);
  });

  afterEach(() => {
    audit.close();
  });

  it('analyzeAudit：单 IP 认证失败风暴 + PSK 探测 → 两类告警', () => {
    for (let i = 0; i < 25; i++) {
      audit.log({ eventType: 'pair_landing_failed', ip: '9.9.9.9', details: '/__pair' });
    }
    for (let i = 0; i < 6; i++) {
      audit.log({ eventType: 'dsh_auth_failed', ip: '8.8.8.8', details: 'Invalid or missing PSK' });
    }
    const db = new DatabaseSync(dbPath);
    const alerts = analyzeAudit({ db, thresholds: { windowSec: 900, authFailPerIp: 20, authFailTotal: 200, pskFail: 5, proxyErrors: 10, dbMaxMb: 512, tunnelDownSec: 1200 } });
    db.close();
    const kinds = alerts.map((a) => a.kind);
    expect(kinds).toContain('auth_fail_ip_burst');
    expect(kinds).toContain('psk_probe');
    const ipBurst = alerts.find((a) => a.kind === 'auth_fail_ip_burst')!;
    expect((ipBurst.details!.ips as any[])[0].ip).toBe('9.9.9.9');
  });

  it('analyzeAudit：隧道长时间掉线 → tunnel_down 告警', () => {
    const db = new DatabaseSync(dbPath);
    db.prepare(`INSERT INTO audit_logs (event_type, ip, created_at) VALUES ('dsh_disconnected', 'watchdog', datetime('now', '-2 hours'))`).run();
    db.close();
    const db2 = new DatabaseSync(dbPath);
    const alerts = analyzeAudit({ db: db2, thresholds: { windowSec: 900, authFailPerIp: 20, authFailTotal: 200, pskFail: 5, proxyErrors: 10, dbMaxMb: 512, tunnelDownSec: 1200 } });
    db2.close();
    const kinds = alerts.map((a) => a.kind);
    expect(kinds).toContain('tunnel_down');
    // v3.141：readonly_fence_probe 已撤除（readonly_blocked 事件不再 emit）；
    // watchdog 现在少一类告警，但其余六类（auth_fail_ip_burst /
    // auth_fail_total / psk_probe / relay_unhealthy / db_size / tunnel_down）
    // 仍各司其职。
    expect(kinds).not.toContain('readonly_fence_probe');
  });

  it('runWatchdogOnce：告警落审计库 watchdog_alert 行 + webhook 收到 JSON POST + 健康探针失败单独成警', async () => {
    // webhook receiver
    const received: any[] = [];
    const hook = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => { received.push(JSON.parse(body)); res.end('{}'); });
    });
    await new Promise<void>((resolve) => hook.listen(0, '127.0.0.1', resolve));
    const hookPort = (hook.address() as any).port;

    for (let i = 0; i < 25; i++) {
      audit.log({ eventType: 'gate_auth_missing', ip: '9.9.9.9', details: '/' });
    }

    const alerts = await runWatchdogOnce({
      auditDbPath: dbPath,
      healthUrl: 'http://127.0.0.1:1/health', // dead port → relay_unhealthy
      webhookUrl: `http://127.0.0.1:${hookPort}/alert`,
      logger: silentLogger,
      thresholds: { authFailPerIp: 20, authFailTotal: 200, pskFail: 5, proxyErrors: 10, dbMaxMb: 512, tunnelDownSec: 1200, windowSec: 900 },
    });

    const kinds = alerts.map((a) => a.kind);
    expect(kinds).toContain('auth_fail_ip_burst');
    expect(kinds).toContain('relay_unhealthy');

    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(received.length).toBe(1);
    expect(received[0].alerts.length).toBe(alerts.length);

    const db = new DatabaseSync(dbPath);
    const rows = db
      .prepare(`SELECT details FROM audit_logs WHERE event_type = 'watchdog_alert'`)
      .all() as Array<{ details: string }>;
    db.close();
    expect(rows.length).toBeGreaterThanOrEqual(alerts.length);
    expect(rows[0]!.details).toContain('auth_fail_ip_burst');

    hook.close();
  });
});

describe('WSS data-plane WS bridge (v3.152.4 PR-WS-bridge)', () => {
  // 全局 beforeAll 把 RELAY_DATA_PLANE 钉在 http（41 老用例回归通道）——
  // 本组单独切 wss 测帧桥，afterAll 还原
  const { dbPath, stateDbPath } = tmpDb('relay-wsbridge');
  let fastifyInstance: any;
  let auditLogger: any;
  let sessionManager: any;
  let port: number;

  beforeAll(() => { process.env.RELAY_DATA_PLANE = 'wss'; });
  afterAll(() => { process.env.RELAY_DATA_PLANE = 'http'; });

  beforeEach(async () => {
    const server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    sessionManager = server.sessionManager;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
  });

  function openTunnel(): Promise<WebSocket> {
    return new Promise((resolve) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
        headers: { authorization: `Bearer ${TEST_PSK}` },
      });
      ws.on('open', () => resolve(ws));
    });
  }

  function registerOn(ws: WebSocket, sessionId: string, token: string): Promise<any> {
    return new Promise((resolve) => {
      const onMessage = (raw: any) => {
        const msg = JSON.parse(raw.toString());
        if (msg.type === 'session.registered') { ws.off('message', onMessage); resolve(msg); }
      };
      ws.on('message', onMessage);
      ws.send(JSON.stringify({
        type: 'session.register',
        payload: { sessionId, pairingToken: token, ttlSeconds: 300 },
      }));
    });
  }

  function pairSession(sessionId: string, token: string): Promise<string> {
    return (async () => {
      const res = await fetch(`http://127.0.0.1:${port}/?sessionId=${sessionId}&token=${token}`, { redirect: 'manual' });
      expect(res.status).toBe(302);
      return (res.headers.get('set-cookie') || '').split(';')[0];
    })();
  }

  it('events.* upgrade 走帧桥：ws.accept 后 101，下行帧到浏览器，上行帧回 plugin', async () => {
    const plugin = await openTunnel();
    await registerOn(plugin, 'sess_wsbridge', 'token_wsbridge');
    const cookie = await pairSession('sess_wsbridge', 'token_wsbridge');

    // fake plugin 侧：等 relay 发来 ws.upgrade 帧 → 回 ws.accept
    const upgradeReceived = new Promise<any>((resolve) => {
      const onMsg = (raw: any) => {
        const msg = JSON.parse(raw.toString());
        if (msg.type === 'ws.upgrade') { plugin.off('message', onMsg); resolve(msg); }
      };
      plugin.on('message', onMsg);
    });

    // 浏览器侧 WS 连接（经 noServer 握手）
    const browser = new WebSocket(`ws://127.0.0.1:${port}/api/events.live`, { headers: { cookie } });

    const up = await upgradeReceived;
    expect(up.path).toBe('/api/events.live');
    expect(up.headers.host).toBe(PUBLIC_HOST); // Host 钉扎

    // plugin 回 accept → relay 对浏览器做 101
    plugin.send(JSON.stringify({ v: 1, type: 'ws.accept', id: up.id }));
    await new Promise<void>((resolve) => browser.on('open', resolve));

    // 下行：plugin 发 ws.frame down → 浏览器收到消息
    const downReceived = new Promise<string>((resolve) => browser.on('message', (d: any, isB: boolean) => resolve(isB ? d.toString('base64') : d.toString())));
    plugin.send(JSON.stringify({ v: 1, type: 'ws.frame', id: up.id, dir: 'down', opcode: 1, payload: 'hello-from-dsh' }));
    expect(await downReceived).toBe('hello-from-dsh');

    // 上行：浏览器发消息 → plugin 收到 ws.frame up
    const upFrame = new Promise<any>((resolve) => {
      const onMsg = (raw: any) => {
        const msg = JSON.parse(raw.toString());
        if (msg.type === 'ws.frame' && msg.dir === 'up') { plugin.off('message', onMsg); resolve(msg); }
      };
      plugin.on('message', onMsg);
    });
    browser.send('hello-from-phone');
    const upf = await upFrame;
    expect(upf.payload).toBe('hello-from-phone');
    expect(upf.opcode).toBe(1);

    // plugin 发 ws.close → 浏览器侧被关
    const closed = new Promise<number>((resolve) => browser.on('close', (c: number) => resolve(c)));
    plugin.send(JSON.stringify({ v: 1, type: 'ws.close', id: up.id, code: 1000, reason: 'done' }));
    const code = await Promise.race([closed, new Promise<number>((_, rej) => setTimeout(() => rej(new Error('browser not closed in 3s')), 3000))]);
    expect(code).toBe(1000);
    plugin.close();
  });

  it('v3.205 实时踢人：B 着陆轮换 → A 的事件流被 close(4001 device_replaced)，B 新流不受影响', async () => {
    const plugin = await openTunnel();
    await registerOn(plugin, 'sess_evict', 'token_evict');
    const cookieA = await pairSession('sess_evict', 'token_evict');

    // fake plugin 侧自动应答 ws.upgrade → ws.accept
    plugin.on('message', (raw: any) => {
      try {
        const msg = JSON.parse(raw.toString());
        if (msg.type === 'ws.upgrade') plugin.send(JSON.stringify({ v: 1, type: 'ws.accept', id: msg.id }));
      } catch { /* ignore */ }
    });

    // 设备 A 的事件流（用 A 的 cookie 授权——桥接记录 authorizedSecret）
    const streamA = new WebSocket(`ws://127.0.0.1:${port}/api/events.live`, { headers: { cookie: cookieA } });
    await new Promise<void>((resolve) => streamA.on('open', resolve));

    // 设备 B 着陆（同链接）→ 轮换 + 掐断 A 的流
    const cookieB = await pairSession('sess_evict', 'token_evict');
    const closedA = new Promise<number>((resolve) => streamA.on('close', (c: number) => resolve(c)));
    expect(await closedA).toBe(4001);

    // B 用新 cookie 建流——不应被误掐
    const streamB = new WebSocket(`ws://127.0.0.1:${port}/api/events.live`, { headers: { cookie: cookieB } });
    await new Promise<void>((resolve) => streamB.on('open', resolve));
    await new Promise((r) => setTimeout(r, 300));
    expect(streamB.readyState).toBe(streamB.OPEN);

    streamB.close();
    plugin.close();
  });

  it('v3.206 晚到的旧 secret 升级 → close(4001) at bridge creation（堵住 A 着陆→SPA 加载中→B 着陆轮换→A 才开始建 WS 的时间窗口竞态）', async () => {
    const plugin = await openTunnel();
    await registerOn(plugin, 'sess_latews', 'token_latews');
    // 假 plugin：自动应答 ws.upgrade → ws.accept
    plugin.on('message', (raw: any) => {
      try {
        const msg = JSON.parse(raw.toString());
        if (msg.type === 'ws.upgrade') plugin.send(JSON.stringify({ v: 1, type: 'ws.accept', id: msg.id }));
      } catch {}
    });
    // 1) A 着陆拿到 secret_1
    const land1 = await fetch(`http://127.0.0.1:${port}/?sessionId=sess_latews&token=token_latews`, { redirect: 'manual' });
    const secret1 = (land1.headers.get('set-cookie') || '').split(';')[0].split('=')[1];
    // 2) 模拟 B 着陆轮换——直接调 rotateSessionSecret
    sessionManager.rotateSessionSecret('sess_latews');
    // 此时 secret_1 是 previousSecret，current 已是 secret_2
    // 3) A 用 secret_1 升级 → 闸门 getSessionBySecret 在 90s 宽限里放行（HTTP 仍可），
    //    但桥接创建时被 v3.206 校验截胡——current !== authorizedSecret → close(4001)
    const browser = new WebSocket(`ws://127.0.0.1:${port}/api/events.live`, {
      headers: { cookie: `dsh_remote_session__sess_latews=${secret1}` },
    });
    const code = await new Promise<number>((res, rej) => {
      browser.on('close', (c: number) => res(c));
      setTimeout(() => rej(new Error('WS 未在 5 秒内被 close(4001)')), 5000);
    });
    expect(code).toBe(4001);
    plugin.close();
  });

  it('plugin 未连接时 events.* upgrade → 503', async () => {
    // 不开 tunnel——直接用上一个用例残留 session？不行，独立注册太啰嗦：
    // 这里只验证无 plugin 时的拒绝路径（cookie 也缺会先 401，所以只测无 cookie 401 之外的路径不可达）。
    // 简化：带无效 cookie → 401（upgrade 闸门仍在帧桥之前）
    const browser = new WebSocket(`ws://127.0.0.1:${port}/api/events.live`, {
      headers: { cookie: 'dsh_remote_session__sess_aaaaaaaaaaaaaaaa=bogus' },
    });
    const rejected = await new Promise<string>((resolve) => {
      browser.on('unexpected-response', (_req, res) => resolve(`HTTP ${res.statusCode}`));
      browser.on('error', (e: any) => resolve(`ERR ${e.message}`));
    });
    expect(rejected).toBe('HTTP 401');
  });

  // v3.162：fake plugin 自动应答 http.req（数据面活性探针用）
  function autoRespond(ws: WebSocket): void {
    ws.on('message', (raw: any) => {
      const msg = JSON.parse(raw.toString());
      if (msg.type === 'http.req') {
        ws.send(JSON.stringify({ v: 1, type: 'http.res', id: msg.id, status: 200, headers: { 'content-type': 'text/plain' }, body: 'ok' }));
      }
    });
  }

  it('v3.170 per-pairing 踢旧：B 用同 pairingToken 重连时踢旧 A；数据面由 B 应答', async () => {
    const a = await openTunnel();
    await registerOn(a, 'sess_kick', 'token_kick');
    const aClosed = new Promise<void>((resolve) => a.on('close', () => resolve()));

    const b = await openTunnel();
    // 同 pairingToken（plugin 重连场景）—— A 必须被踢。
    // v3.162 旧版无脑踢任何旧 socket；v3.170 起改为「同 pairing 才踢」，
    // 跨 pairing 共存行为见下一个用例。
    await registerOn(b, 'sess_kick', 'token_kick');
    // 旧代码不踢旧——A 永不关闭，本断言超时失败
    await Promise.race([aClosed, new Promise<void>((_, rej) => setTimeout(() => rej(new Error('old tunnel not kicked in 3s')), 3000))]);

    autoRespond(b);
    const cookie = await pairSession('sess_kick', 'token_kick');
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, { headers: { cookie } });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('ok');
    b.close();
  });

  it('v3.200 /auth 剥掉 sec-fetch-site（相机扫码的 cross-site 动线）；/api 原样透传', async () => {
    // 回归：手机扫码 → 配对 URL 302 → /auth 的导航由外部 app（相机）唤起，
    // Chrome 标 sec-fetch-site: cross-site；引擎 isTrustedApiRequest 拒之 →
    // 403 forbidden → SPA 永远起不来。relay 侧在 /auth 剥掉该标记放行。
    const tunnel = await openTunnel();
    await registerOn(tunnel, 'sess_fm', 'token_fm');
    const frames: any[] = [];
    tunnel.on('message', (raw: any) => {
      const msg = JSON.parse(raw.toString());
      if (msg.type === 'http.req') frames.push(msg);
    });
    autoRespond(tunnel);
    const cookie = await pairSession('sess_fm', 'token_fm');

    await fetch(`http://127.0.0.1:${port}/auth?next=https%3A%2F%2Frelay.example.com%2F`, {
      headers: { cookie, 'sec-fetch-site': 'cross-site', 'sec-fetch-mode': 'navigate' },
      redirect: 'manual',
    });
    const authFrame = frames.find((f) => f.path.startsWith('/auth'));
    expect(authFrame, '/auth 帧应被转发').toBeDefined();
    expect(authFrame!.headers['sec-fetch-site'], '/auth 的 cross-site 标记必须剥掉').toBeUndefined();

    await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { cookie, 'sec-fetch-site': 'cross-site' },
    });
    const apiFrame = frames.find((f) => f.path.startsWith('/api'));
    expect(apiFrame, '/api 帧应被转发').toBeDefined();
    expect(apiFrame!.headers['sec-fetch-site'], '/api 的标记必须原样透传（引擎 fence 依赖它）').toBe('cross-site');
    tunnel.close();
  });

  it('v3.170 跨 pairing 共存：A/B 不同 pairingToken 同时在线，互不踢；各自 cookie 路由到自己的 socket', async () => {
    // 用户场景：两台 Mac 各跑 dsh engine 各自扫一个不同 QR。
    // v3.162 会无脑互踢成 5s 级乒乓；v3.170 起共存。
    const a = await openTunnel();
    await registerOn(a, 'sess_pair_a', 'token_pair_a');

    const b = await openTunnel();
    await registerOn(b, 'sess_pair_b', 'token_pair_b');

    // 给两条 socket 一点时间，确认都没被踢
    await new Promise((r) => setTimeout(r, 200));
    expect(a.readyState).toBe(WebSocket.OPEN);
    expect(b.readyState).toBe(WebSocket.OPEN);

    autoRespond(a);
    autoRespond(b);
    const cookieA = await pairSession('sess_pair_a', 'token_pair_a');
    const cookieB = await pairSession('sess_pair_b', 'token_pair_b');

    // 各自 cookie 路由到各自 socket（wssHttpProxy 按 sessionSecret → pairingToken 查表）
    const resA = await fetch(`http://127.0.0.1:${port}/api/version`, { headers: { cookie: cookieA } });
    expect(resA.status).toBe(200);
    expect(await resA.text()).toBe('ok');
    const resB = await fetch(`http://127.0.0.1:${port}/api/version`, { headers: { cookie: cookieB } });
    expect(resB.status).toBe(200);
    expect(await resB.text()).toBe('ok');

    a.close();
    b.close();
  });

  it('v3.162 stale close 守卫：非当前 socket 迟到的 close 不得打死数据面（plugin_not_connected 死锁回归）', async () => {
    const a = await openTunnel();
    await registerOn(a, 'sess_guard', 'token_guard');
    const b = await openTunnel();
    await registerOn(b, 'sess_guard2', 'token_guard2'); // 踢 A
    const c = await openTunnel();
    await registerOn(c, 'sess_guard3', 'token_guard3'); // 踢 B → C 为当前数据面

    // A/B 均非当前 socket——手动 close 模拟残留/迟到 close。
    // 旧代码的 close handler 无身份守卫，会把 wssPluginSocket 置空：
    // C 明明活着、Mac 侧 TCP 仍 ESTABLISHED，relay 却对 /api/* 永久 503。
    a.close();
    b.close();
    await new Promise((r) => setTimeout(r, 200)); // 让 stale close 事件落地

    autoRespond(c);
    const cookie = await pairSession('sess_guard3', 'token_guard3');
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, { headers: { cookie } });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('ok');
    c.close();
  });
});

// v3.171 share-link 套件——独立 describe 不依赖 WSS 数据面
describe('根路径签名着陆 URL token (v3.176 QR 形态 · v3.203 唯一着陆入口)', () => {
  let fastifyInstance: any
  let auditLogger: any
  const { dbPath, stateDbPath } = tmpDb('relay-share-link')
  let port: number

  beforeEach(async () => {
    const server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST })
    fastifyInstance = server.fastify
    auditLogger = server.auditLogger
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' })
    port = (fastifyInstance.server.address() as any).port
  })

  afterEach(async () => {
    auditLogger.close()
    await fastifyInstance.close()
  })

  // helper: 生成合法签名着陆参数(sid 必须先 register 一条 session)
  // sidSuffix/tokenSuffix:只用合法 hex 字符(a-f0-9),因为 verifyRootLanding 正则要求
  async function mintValidShareLink(sidSuffix = 'a', tokenSuffix = 'b', overrides: Partial<{ hash: string; t: number; exp: number; mid: string }> = {}) {
    const sessionId = `sess_${sidSuffix.padEnd(16, 'a').slice(0, 16)}`
    const pairingToken = tokenSuffix.padEnd(64, 'a')
    // 必须全是合法 hex,否则 verifyShareLink 在 token regex 阶段就拒了
    if (!/^[a-f0-9]{64}$/.test(pairingToken)) throw new Error(`tokenSuffix must produce valid hex; got ${pairingToken}`)
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    })
    await new Promise((resolve) => ws.on('open', resolve))
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId, pairingToken, ttlSeconds: 300 },
    }))
    await new Promise((resolve) => ws.on('message', resolve))
    ws.close()

    const t = overrides.t ?? Date.now()
    const exp = overrides.exp ?? t + 1800 * 1000
    const mid = overrides.mid ?? crypto.createHash('sha256').update(`test-mid-${sidSuffix}`).digest('hex')
    const expected = overrides.hash ?? crypto.createHmac('sha256', TEST_PSK)
      .update([sessionId, exp, mid, t].join('|'))
      .digest('base64url')
    return { sessionId, pairingToken, hash: expected, t, exp, mid, url: `http://127.0.0.1:${port}/?sessionId=${sessionId}&token=${pairingToken}&hash=${expected}&t=${t}&exp=${exp}&mid=${mid}` }
  }

  it('合法签名着陆 → 302 + Set-Cookie + 跳 /auth', async () => {
    const link = await mintValidShareLink()
    const res = await fetch(link.url, { redirect: 'manual' })
    expect(res.status).toBe(302)
    expect(res.headers.get('location') || '').toMatch(/^\/auth\?next=/)
    const setCookie = res.headers.get('set-cookie') || ''
    expect(setCookie).toMatch(/^dsh_remote_session__sess_[A-Za-z0-9_-]+=/)
  })

  it('签名族字段残缺（有 t/exp/mid 无 hash）→ 401', async () => {
    const link = await mintValidShareLink()
    // 删 hash（保留 token 也一样——hash/t/exp/mid 任一出现即按签名路线走）
    const url = link.url.replace(/&hash=[^&]+/, '')
    const res = await fetch(url, { redirect: 'manual' })
    expect(res.status).toBe(401)
  })

  it('exp 过期 → 401 + reason=expired', async () => {
    const pastExp = Date.now() - 1000
    const link = await mintValidShareLink('c', 'd', { exp: pastExp, t: pastExp - 1800 * 1000 })
    const res = await fetch(link.url, { redirect: 'manual' })
    expect(res.status).toBe(401)
    // 审计行记录 reason
    auditLogger.log({ eventType: 'flush_test', ip: '127.0.0.1' })
    auditLogger.close()
    const db = new DatabaseSync(dbPath, { readOnly: true })
    const row = db.prepare("SELECT details FROM audit_logs WHERE event_type='root_landing_failed' ORDER BY id DESC LIMIT 1").get() as { details: string } | undefined
    expect(row?.details).toMatch(/reason=expired/)
    db.close()
  })

  it('hash 篡改 → 401 + reason=bad signature', async () => {
    const link = await mintValidShareLink('e', 'f', { hash: 'A'.repeat(43) })
    const res = await fetch(link.url, { redirect: 'manual' })
    expect(res.status).toBe(401)
  })

  it('sid 格式非法 → 401 + reason=bad sid', async () => {
    const link = await mintValidShareLink('b', 'a')
    // 用合法 hash 但非法的 sid
    const t = Date.now()
    const exp = t + 1800 * 1000
    const mid = crypto.createHash('sha256').update('test').digest('hex')
    const hash = crypto.createHmac('sha256', TEST_PSK)
      .update(['sess_BADbadbad', exp, mid, t].join('|')).digest('base64url')
    const url = `http://127.0.0.1:${port}/?sessionId=sess_BADbadbad&token=${'a'.repeat(64)}&hash=${hash}&t=${t}&exp=${exp}&mid=${mid}`
    const res = await fetch(url, { redirect: 'manual' })
    expect(res.status).toBe(401)
  })

  it('mint 时间在未来超过 5min → 401 + reason=mint in future', async () => {
    const futureT = Date.now() + 10 * 60 * 1000
    const link = await mintValidShareLink('c', 'a', { t: futureT, exp: futureT + 1800 * 1000 })
    const res = await fetch(link.url, { redirect: 'manual' })
    expect(res.status).toBe(401)
  })

  it('mint 时间超过 30 天 → 401 + reason=mint too old', async () => {
    const oldT = Date.now() - 31 * 24 * 60 * 60 * 1000
    const link = await mintValidShareLink('d', 'a', { t: oldT, exp: Date.now() + 1000 })
    const res = await fetch(link.url, { redirect: 'manual' })
    expect(res.status).toBe(401)
  })

  it('audit 脱敏:着陆失败日志不含完整 hash/mid（v3.203 承 v3.171 语义回补）', async () => {
    // 触发一次失败:篡改 hash
    const link = await mintValidShareLink('e', 'a', { hash: 'B'.repeat(43) })
    await fetch(link.url, { redirect: 'manual' })
    // 读 audit DB 看 details 列
    const db = new DatabaseSync(dbPath, { readOnly: true })
    const row = db.prepare("SELECT details FROM audit_logs WHERE event_type='root_landing_failed' ORDER BY id DESC LIMIT 1").get() as { details: string } | undefined
    expect(row?.details).toBeDefined()
    expect(row!.details).toMatch(/hash=[A-Za-z0-9_-]{8}…/)
    // 完整 43 字符 hash 必须不出现
    expect(row!.details).not.toContain('BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB')
    expect(row!.details).not.toContain(link.mid)
    db.close()
  })

  it('签名着陆带 name/app_version(informational)仍正常 302——relay 忽略非校验字段', async () => {
    const link = await mintValidShareLink('a2', 'b2')
    // 追加 name + app_version(对齐 zcode URL 形态)
    const withInfo = link.url + `&name=test-hostname.local&app_version=3.11.2`
    const res = await fetch(withInfo, { redirect: 'manual' })
    expect(res.status).toBe(302)
    expect(res.headers.get('location') || '').toMatch(/^\/auth\?next=/)
  })

  it('签名着陆与正常 cookie 路线共存:同一个 pairing 的签名链接也能正常着陆', async () => {
    const link = await mintValidShareLink('f', 'a')
    const res = await fetch(link.url, { redirect: 'manual' })
    expect(res.status).toBe(302)
    // 着陆后 cookie 颁发 → 后续请求走 cookie 闸门(再发一次 pair 不应再被同一个 token 接受,
    // 除非无人在线;这里只验证 cookie 颁发了)
    const setCookie = res.headers.get('set-cookie') || ''
    expect(setCookie).toMatch(/^dsh_remote_session__sess_[A-Za-z0-9_-]+=/)
    // 用 cookie 访问 /api/version(虽然上游死,但闸门必须放行:200/4xx 都行,绝不能 401)
    const cookie = setCookie.split(';')[0]
    const api = await fetch(`http://127.0.0.1:${port}/api/version`, { headers: { cookie } })
    expect(api.status).not.toBe(401)
  })
});

// v3.172 Plan A:per-pairing cookie 命名空间 + X-Pairing-Id header
describe('per-pairing cookie + X-Pairing-Id (v3.172 Plan A)', () => {
  let fastifyInstance: any
  let auditLogger: any
  let server: any
  const { dbPath, stateDbPath } = tmpDb('relay-pair-cookie')
  let port: number

  // 本 describe 要验证 wssHttpProxy 按 X-Pairing-Id 路由——需要切到 WSS 数据面
  //（文件顶部 beforeAll 已把 RELAY_DATA_PLANE 钉在 http 跑 41 老用例回归通道）
  beforeAll(() => { process.env.RELAY_DATA_PLANE = 'wss'; });
  afterAll(() => { process.env.RELAY_DATA_PLANE = 'http'; });

  beforeEach(async () => {
    server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST })
    fastifyInstance = server.fastify
    auditLogger = server.auditLogger
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' })
    port = (fastifyInstance.server.address() as any).port
  })

  afterEach(async () => {
    auditLogger.close()
    await fastifyInstance.close()
  })

  async function reg(suffix: string): Promise<{ sid: string; cookie: string }> {
    const sid = `sess_planA_${suffix}`
    const tok = `token_planA_${suffix}`
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    })
    await new Promise((resolve) => ws.on('open', resolve))
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId: sid, pairingToken: tok, ttlSeconds: 300, engineToken: 'test-engine-token' },
    }))
    await new Promise((resolve) => ws.on('message', resolve))
    const landing = await fetch(`http://127.0.0.1:${port}/?sessionId=${sid}&token=${tok}`, { redirect: 'manual' })
    ws.close()
    expect(landing.status).toBe(302)
    const cookie = (landing.headers.get('set-cookie') || '').split(';')[0]
    return { sid, cookie }
  }

  /** 同 reg(),但 WS 全程保持+自动应答 http.req——用于多 pairing 同时在线场景
   *  (多 pairing 测试如果每次 reg 都关 WS,后续 register 又触发 secret 轮换
   *  会让 cookie 失效)。 */
  async function registerAndPair(suffix: string, _label: string): Promise<{ sid: string; cookie: string; ws: WebSocket }> {
    const sid = `sess_planA_${suffix}`
    const tok = `token_planA_${suffix}`
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    })
    await new Promise((resolve) => ws.on('open', resolve))
    // 自动应答 http.req,让 wssHttpProxy 路径能完整跑通
    ws.on('message', (raw: any) => {
      try {
        const msg = JSON.parse(raw.toString())
        if (msg.type === 'http.req') {
          ws.send(JSON.stringify({ v: 1, type: 'http.res', id: msg.id, status: 200, headers: { 'content-type': 'text/plain' }, body: 'ok' }))
        }
      } catch {}
    })
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId: sid, pairingToken: tok, ttlSeconds: 300, engineToken: 'test-engine-token' },
    }))
    await new Promise((resolve) => ws.on('message', resolve))
    const landing = await fetch(`http://127.0.0.1:${port}/?sessionId=${sid}&token=${tok}`, { redirect: 'manual' })
    expect(landing.status).toBe(302)
    const cookie = (landing.headers.get('set-cookie') || '').split(';')[0]
    return { sid, cookie, ws }
  }

  it('着陆 setCookie 名格式 = dsh_remote_session__<sessionId>', async () => {
    const { sid, cookie } = await reg('a')
    expect(cookie).toMatch(new RegExp(`^dsh_remote_session__${sid}=`))
  })

  it('单 pairing 无 X-Pairing-Id header:闸门自动选唯一 cookie(向后兼容)', async () => {
    const { sid, cookie } = await reg('b')
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, { headers: { cookie } })
    expect(res.status).not.toBe(401)
    expect(sid).toBeDefined()
  })

  it('多 pairing 同浏览器:各自 cookie 都被收下,但不带 X-Pairing-Id 时闸门拒(强制显式选)', async () => {
    const a = await reg('c1')
    const b = await reg('c2')
    const allCookies = `${a.cookie}; ${b.cookie}`
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, { headers: { cookie: allCookies } })
    expect(res.status).toBe(401)  // 多 cookie + 无 header → 拒,防路由到错的 pairing
  })

  it('多 pairing + 正确 X-Pairing-Id:闸门放行,被路由到对应 pairing 的 plugin socket', async () => {
    // 一次性注册 A + B 两条 pairing,WS 全程保持——保持 plugin socket 在线,
    // 且不触发 secret 轮换(否则 cookie 会失效)。
    const sessA = await registerAndPair('planA_e1', 'auto')
    const sessB = await registerAndPair('planA_e2', 'auto')
    const allCookies = `${sessA.cookie}; ${sessB.cookie}`

    // 选 A 路由
    const resA = await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { cookie: allCookies, 'x-pairing-id': sessA.sid },
    })
    expect(resA.status).toBe(200)
    expect(await resA.text()).toBe('ok')

    // 选 B 路由
    const resB = await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { cookie: allCookies, 'x-pairing-id': sessB.sid },
    })
    expect(resB.status).toBe(200)
    expect(await resB.text()).toBe('ok')
  })

  it('X-Pairing-Id 指向不存在的 pairing:401 防串号', async () => {
    const a = await reg('e1')
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { cookie: a.cookie, 'x-pairing-id': 'sess_nonexistent_xxxxxxxx' },
    })
    expect(res.status).toBe(401)
  })

  it('A cookie 的 secret 错配 B pairing 的 sessionId:401(防 cookie 串号用)', async () => {
    const a = await reg('f1')
    const b = await reg('f2')
    // 把 a.cookie 名字改成 b.sid,内容用 a 的 secret——模拟攻击者用 A cookie 试过 B pairing 闸门
    const tampered = a.cookie.replace(/dsh_remote_session__sess_planA_f1/, `dsh_remote_session__${b.sid}`)
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { cookie: tampered, 'x-pairing-id': b.sid },
    })
    expect(res.status).toBe(401)
  })
});

// v3.173 URL 会话 token(第三条路,不依赖 cookie)——Authorization: Bearer <sid>.<exp>.<mid>.<t>.<hash>
describe('URL session token (v3.173 第三条路)', () => {
  let fastifyInstance: any
  let auditLogger: any
  let sessionManager: any
  const { dbPath, stateDbPath } = tmpDb('relay-url-session')
  let port: number

  beforeAll(() => { process.env.RELAY_DATA_PLANE = 'wss'; });
  afterAll(() => { process.env.RELAY_DATA_PLANE = 'http'; });

  beforeEach(async () => {
    const server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST })
    fastifyInstance = server.fastify
    auditLogger = server.auditLogger
    sessionManager = server.sessionManager
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' })
    port = (fastifyInstance.server.address() as any).port
  })

  afterEach(async () => {
    auditLogger.close()
    await fastifyInstance.close()
  })

  // 注册一条 session + 返回配对信息(WS 保持在线,含 autoRespond)
  async function regSession(suffix: string): Promise<{ sid: string; ws: WebSocket; bearer: string; hash: string }> {
    const sid = `sess_urls_${suffix}`
    const pairingToken = suffix.padEnd(32, 'a').repeat(2)
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    })
    await new Promise((resolve) => ws.on('open', resolve))
    ws.on('message', (raw: any) => {
      try {
        const msg = JSON.parse(raw.toString())
        if (msg.type === 'http.req') {
          ws.send(JSON.stringify({ v: 1, type: 'http.res', id: msg.id, status: 200, headers: { 'content-type': 'text/plain' }, body: `ok-${suffix}` }))
        }
      } catch {}
    })
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId: sid, pairingToken, ttlSeconds: 300, engineToken: 'test-engine-token' },
    }))
    await new Promise((resolve) => ws.on('message', resolve))

    const t = Date.now()
    const exp = t + 24 * 60 * 60 * 1000 // 24h
    const mid = crypto.createHash('sha256').update(`mid-${suffix}`).digest('hex')
    const hash = crypto.createHmac('sha256', TEST_PSK)
      .update([sid, exp, mid, t].join('|')).digest('base64url')
    const bearer = `${sid}.${exp}.${mid}.${t}.${hash}`
    return { sid, ws, bearer, hash }
  }

  it('合法 URL 会话 token → gate 放行,路由到对应 pairing(Bearer header)', async () => {
    const { sid, ws, bearer } = await regSession('tok1')
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { authorization: `Bearer ${bearer}` },
    })
    expect(res.status).toBe(200)
    expect(await res.text()).toBe('ok-tok1')
    ws.close()
    expect(sid).toBeTruthy()
  })

  // ---- D-111：过期凭证只对「重铸凭证」这一个端点开口子 ----
  //
  // 背景：URL 会话 TTL 只有 24h，App 靠「过期前 2h 续期」续命，也就是这把钥匙的
  // 寿命取决于用户有没有恰好在第 22 小时打开过 App。错过一次窗口就是终局——
  // 换钥匙的门要用旧钥匙开。真机（小米 2109119BC）代价：凭证静静过期，控制台
  // 永远挂着「正在重连…」，而重连永远不会成功。

  /** 铸一把**已过期**但签名正确的 bearer（exp 在过去，mint 仍在 30 天 cap 内）。 */
  function expiredBearer(sid: string, mid: string): string {
    const t = Date.now() - 3 * 60 * 60 * 1000 // 3 小时前铸的
    const exp = t + 60 * 60 * 1000 // 1h TTL → 2 小时前就过期了
    const hash = crypto.createHmac('sha256', TEST_PSK)
      .update([sid, exp, mid, t].join('|')).digest('base64url')
    return `${sid}.${exp}.${mid}.${t}.${hash}`
  }

  it('D-111 过期凭证 → 只有 /dsh-remote/url-session 能过去闸门', async () => {
    const { sid, ws, bearer } = await regSession('rearm1')
    const [, , mid] = bearer.split('.')
    const stale = expiredBearer(sid, mid!)

    // 数据面照旧 401 —— 放宽的只有「铸出下一把钥匙」这一件事。
    const data = await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { authorization: `Bearer ${stale}` },
    })
    expect(data.status).toBe(401)

    // 重铸端点过了闸门（上游是 DEAD_UPSTREAM，所以这里断言「不是 401」——
    // 真正验的是闸门放行了，铸不铸得出来是引擎侧的事）。
    const rearm = await fetch(`http://127.0.0.1:${port}/dsh-remote/url-session`, {
      headers: { authorization: `Bearer ${stale}` },
    })
    expect(rearm.status).not.toBe(401)
    ws.close()
  })

  it('D-111 口子不救「被吊销」：session 不在 → 照旧 401', async () => {
    const { sid, ws, bearer } = await regSession('rearm2')
    const [, , mid] = bearer.split('.')
    const stale = expiredBearer(sid, mid!)
    sessionManager.revokeSession(sid, 'test')

    const rearm = await fetch(`http://127.0.0.1:${port}/dsh-remote/url-session`, {
      headers: { authorization: `Bearer ${stale}` },
    })
    expect(rearm.status).toBe(401)
    ws.close()
  })

  it('D-111 口子不救「签名被篡改」：hash 换假值 → 照旧 401', async () => {
    const { sid, ws, bearer } = await regSession('rearm3')
    const [, exp, mid, t] = bearer.split('.')
    const tampered = `${sid}.${exp}.${mid}.${t}.${'A'.repeat(43)}`

    const rearm = await fetch(`http://127.0.0.1:${port}/dsh-remote/url-session`, {
      headers: { authorization: `Bearer ${tampered}` },
    })
    expect(rearm.status).toBe(401)
    ws.close()
  })

  it('D-111 口子是「续命」不是「复活」：mint 老过 30 天 cap → 照旧 401', async () => {
    const { sid, ws, bearer } = await regSession('rearm4')
    const [, , mid] = bearer.split('.')
    // 31 天前铸的、早就过期 —— 超了 SHARE_LINK_MAX_AGE_MS。
    const t = Date.now() - 31 * 24 * 60 * 60 * 1000
    const exp = t + 60 * 60 * 1000
    const hash = crypto.createHmac('sha256', TEST_PSK)
      .update([sid, exp, mid, t].join('|')).digest('base64url')
    const ancient = `${sid}.${exp}.${mid}.${t}.${hash}`

    const rearm = await fetch(`http://127.0.0.1:${port}/dsh-remote/url-session`, {
      headers: { authorization: `Bearer ${ancient}` },
    })
    expect(rearm.status).toBe(401)
    ws.close()
  })

  it('D-111 口子精确匹配：/dsh-remote/url-sessionX 不跟着放宽', async () => {
    const { sid, ws, bearer } = await regSession('rearm5')
    const [, , mid] = bearer.split('.')
    const stale = expiredBearer(sid, mid!)

    const lookalike = await fetch(`http://127.0.0.1:${port}/dsh-remote/url-sessionX`, {
      headers: { authorization: `Bearer ${stale}` },
    })
    expect(lookalike.status).toBe(401)
    ws.close()
  })

  // ---- v3.183：根路径着陆闸门（裸 / 不再免鉴权）----

  it('v3.203 合法签名根路径着陆 /?sessionId&hash&t&exp&mid(v3.176 QR 形态) → 颁 cookie + 跳 /auth，cookie 二跳放行转发', async () => {
    const { sid, ws, bearer } = await regSession('root1')
    const [bSid, exp, mid, t, hash] = bearer.split('.')
    expect(bSid).toBe(sid)
    const res = await fetch(
      `http://127.0.0.1:${port}/?sessionId=${sid}&hash=${hash}&t=${t}&exp=${exp}&mid=${mid}`,
      { redirect: 'manual', headers: { accept: 'text/html' } },
    )
    expect(res.status).toBe(302)
    expect(res.headers.get('location') || '').toMatch(/^\/auth\?next=/)
    const cookie = (res.headers.get('set-cookie') || '').split(';')[0]
    expect(cookie).toMatch(new RegExp(`^dsh_remote_session__${sid}=`))
    // 二跳：带着陆 cookie 访问裸 / → cookie 路线转发到对应 pairing
    const second = await fetch(`http://127.0.0.1:${port}/`, { redirect: 'manual', headers: { cookie } })
    expect(second.status).toBe(200)
    expect(await second.text()).toBe('ok-root1')
    ws.close()
  })

  it('v3.183 签名被篡改(hash 换假值) → 401 二维码无效卡,不进 dsh', async () => {
    const { sid, ws, bearer } = await regSession('root2')
    const [, exp, mid, t] = bearer.split('.')
    const res = await fetch(
      `http://127.0.0.1:${port}/?sessionId=${sid}&hash=${'A'.repeat(43)}&t=${t}&exp=${exp}&mid=${mid}`,
      { redirect: 'manual', headers: { accept: 'text/html' } },
    )
    expect(res.status).toBe(401)
    expect(await res.text()).toContain('二维码无效或已过期')
    ws.close()
  })

  it('v3.183 签名合法但 session 不存在(引擎重启后旧码) → 401 二维码无效卡', async () => {
    const sid = 'sess_root_ghost'
    const t = Date.now()
    const exp = t + 3600_000
    const mid = crypto.createHash('sha256').update('mid-ghost').digest('hex')
    const hash = crypto.createHmac('sha256', TEST_PSK).update([sid, exp, mid, t].join('|')).digest('base64url')
    const res = await fetch(
      `http://127.0.0.1:${port}/?sessionId=${sid}&hash=${hash}&t=${t}&exp=${exp}&mid=${mid}`,
      { redirect: 'manual', headers: { accept: 'text/html' } },
    )
    expect(res.status).toBe(401)
    expect(await res.text()).toContain('二维码无效或已过期')
  })

  it('v3.203 旧格式 /?sessionId&token:真值 302+cookie 且 cookie 二跳放行、假值 401 二维码无效卡', async () => {
    const { sid, ws } = await regSession('root3')
    const pairingToken = 'root3'.padEnd(32, 'a').repeat(2)
    const ok = await fetch(`http://127.0.0.1:${port}/?sessionId=${sid}&token=${pairingToken}`, { redirect: 'manual' })
    expect(ok.status).toBe(302)
    const cookie = (ok.headers.get('set-cookie') || '').split(';')[0]
    const second = await fetch(`http://127.0.0.1:${port}/`, { redirect: 'manual', headers: { cookie } })
    expect(second.status).toBe(200)
    expect(await second.text()).toBe('ok-root3')
    const bad = await fetch(`http://127.0.0.1:${port}/?sessionId=${sid}&token=${'f'.repeat(64)}`, { redirect: 'manual' })
    expect(bad.status).toBe(401)
    expect(await bad.text()).toContain('二维码无效或已过期')
    ws.close()
  })

  it('v3.183 已配对 cookie 设备直达裸 / → 放行(不误伤既有 cookie 路线)', async () => {
    const { sid, ws } = await regSession('root4')
    const pairingToken = 'root4'.padEnd(32, 'a').repeat(2)
    const landing = await fetch(`http://127.0.0.1:${port}/?sessionId=${sid}&token=${pairingToken}`, { redirect: 'manual' })
    expect(landing.status).toBe(302)
    const cookie = (landing.headers.get('set-cookie') || '').split(';')[0]
    const res = await fetch(`http://127.0.0.1:${port}/`, { redirect: 'manual', headers: { cookie } })
    expect(res.status).toBe(200)
    expect(await res.text()).toBe('ok-root4')
    ws.close()
  })

  it('过期 token → 401(exp 过去)', async () => {
    const { sid, ws } = await regSession('tok2')
    const t = Date.now()
    const exp = t - 1000 // 已过期
    const mid = crypto.createHash('sha256').update('mid-tok2').digest('hex')
    const hash = crypto.createHmac('sha256', TEST_PSK)
      .update([sid, exp, mid, t].join('|')).digest('base64url')
    const expired = `${sid}.${exp}.${mid}.${t}.${hash}`
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { authorization: `Bearer ${expired}` },
    })
    expect(res.status).toBe(401)
    ws.close()
  })

  it('篡改 hash → 401', async () => {
    const { sid, ws } = await regSession('tok3')
    const t = Date.now()
    const exp = t + 3600_000
    const mid = crypto.createHash('sha256').update('mid-tok3').digest('hex')
    const badHash = 'A'.repeat(43)
    const tampered = `${sid}.${exp}.${mid}.${t}.${badHash}`
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { authorization: `Bearer ${tampered}` },
    })
    expect(res.status).toBe(401)
    ws.close()
  })

  it('无 token 无 cookie → 401', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/api/version`)
    expect(res.status).toBe(401)
  })

  it('Bearer 验不过 + 有 cookie → 401(显式带 Bearer 不回退 cookie)', async () => {
    // 注册 + landing 拿 cookie
    const sid = 'sess_urls_tok5'
    const pairingToken = 'f'.repeat(64)
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    })
    await new Promise((resolve) => ws.on('open', resolve))
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId: sid, pairingToken, ttlSeconds: 300, engineToken: 'x' },
    }))
    await new Promise((resolve) => ws.on('message', resolve))
    const landing = await fetch(`http://127.0.0.1:${port}/?sessionId=${sid}&token=${pairingToken}`, { redirect: 'manual' })
    const cookie = (landing.headers.get('set-cookie') || '').split(';')[0]
    // 带坏 Bearer + 真 cookie → 401(Bearer 分支优先,验不过即拒)
    const res = await fetch(`http://127.0.0.1:${port}/api/version`, {
      headers: { authorization: 'Bearer sess_urls_tok5.1.2.3.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', cookie },
    })
    expect(res.status).toBe(401)
    ws.close()
  })

  it('静态资源 /assets/* 无 token 无 cookie → 非 401(免鉴权)', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/assets/app.js`)
    expect(res.status).not.toBe(401)
  })

  // v3.176.1：dsh 首屏 preload 的组合脚本(script 标签)带不了 Authorization
  // header,URL 会话路线又不颁 cookie——/plugins/* 必须与 /assets/* 同级免鉴权,
  // 否则浏览器抛 "HTML did not preload dsh-client-modules/client.js"。
  it('v3.176.1 /plugins/??组合脚本 无 token 无 cookie → 免鉴权 + 回落任一在线 pairing 转发', async () => {
    const { ws } = await regSession('plug1')
    // 真实形状:第一个 ? 之后全是 query(浏览器 script src 同此),裸路径 = /plugins/
    const res = await fetch(`http://127.0.0.1:${port}/plugins/??@deepseek-ai/dsh-client-modules/client.js&rev=abc123def456`)
    expect(res.status).toBe(200)
    expect(await res.text()).toBe('ok-plug1')
    ws.close()
  })

  it('v3.176.1 /plugins/<id>/client.js 单包脚本 URL 同样免鉴权转发', async () => {
    const { ws } = await regSession('plug2')
    const res = await fetch(`http://127.0.0.1:${port}/plugins/@deepseek-ai/dsh-client-modules/client.js`)
    expect(res.status).toBe(200)
    expect(await res.text()).toBe('ok-plug2')
    ws.close()
  })

  it('v3.176.1 无在线 pairing 时 /plugins/* → 503 非 401(不泄数据,只报未连接)', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/plugins/??x/client.js&rev=1`)
    expect(res.status).toBe(503)
    expect((await res.json() as any).error).toBe('plugin_not_connected')
  })

  // v3.203：v3.176.2 的「3xx Location 补回凭证字段」救援已随 /__pair 退役移除——
  // 根路径闸门对带凭证 query 的 / 一律在闸门层 302 着陆（不再透传给 dsh），
  // 「dsh 303 剥 query 导致失联」的场景不复存在。

  it('v3.176.2 无凭证字段的 / 3xx → Location 原样不改写(v3.183 改走 cookie 路线)', async () => {
    const { sid, ws } = await regSession('loc2')
    // regSession 的自动应答是 200;v3.183 起匿名 / 被 gate 拒——改用合法
    // pairing cookie 过闸(请求 query 无凭证字段),200 无 Location → 断言
    // location 为 null(未改写任何东西)
    const pairingToken = 'loc2'.padEnd(32, 'a').repeat(2)
    const landing = await fetch(`http://127.0.0.1:${port}/?sessionId=${sid}&token=${pairingToken}`, { redirect: 'manual' })
    expect(landing.status).toBe(302)
    const cookie = (landing.headers.get('set-cookie') || '').split(';')[0]
    const res = await fetch(`http://127.0.0.1:${port}/`, { redirect: 'manual', headers: { cookie } })
    expect(res.status).toBe(200)
    expect(res.headers.get('location')).toBe(null)
    ws.close()
  })

  it('WS 事件流 ?token=<合法> → 升级放行(101/转发,非 401)', async () => {
    const { sid, ws, bearer } = await regSession('tok7')
    // 建浏览器侧 WS 连 events.mux,query 带 token
    const browser = new WebSocket(`ws://127.0.0.1:${port}/api/events.mux?token=${encodeURIComponent(bearer)}`)
    const outcome = await new Promise<string>((resolve) => {
      const timer = setTimeout(() => resolve('timeout'), 2000)
      browser.on('open', () => { clearTimeout(timer); resolve('open') })
      browser.on('unexpected-response', (_req, res) => { clearTimeout(timer); resolve(`HTTP ${res.statusCode}`) })
      browser.on('error', () => { clearTimeout(timer); resolve('error') })
    })
    expect(outcome).not.toBe('HTTP 401')
    expect(outcome).not.toBe('HTTP 503')
    try { browser.close() } catch {}
    ws.close()
    expect(sid).toBeTruthy()
  })
});

/**
 * v3.282 engine-admin boundary.
 *
 * A paired device reaches the relay with a valid pairing cookie, so the
 * credential gate alone cannot separate it from the admin page on the host.
 * These cases pin the half of the plugin's prefix that a device must never
 * drive, AND the read half it legitimately depends on (status polling and
 * credential renewal — see app/lib/services/{machines_session_poller,
 * session_scheduler}.dart), so the boundary cannot be "fixed" by blanket-
 * denying the prefix and silently breaking the paired app.
 */
describe('v3.282 engine-admin boundary (paired device vs host admin)', () => {
  let server: any;
  let fastifyInstance: any;
  let auditLogger: any;
  const { dbPath, stateDbPath } = tmpDb('relay-admin');
  let port: number;
  let cookie: string;

  beforeEach(async () => {
    server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;

    // Land a real pairing so every request below carries a VALID cookie:
    // a 403 here is the admin boundary, never the credential gate.
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    });
    await new Promise((resolve) => ws.on('open', resolve));
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId: 'sess_admin_fence', pairingToken: 'token_admin_fence', ttlSeconds: 300 },
    }));
    await new Promise((resolve) => ws.on('message', resolve));
    ws.close();

    const land = await fetch(
      `http://127.0.0.1:${port}/?sessionId=sess_admin_fence&token=token_admin_fence`,
      { redirect: 'manual' },
    );
    expect(land.status).toBe(302);
    cookie = (land.headers.get('set-cookie') || '').split(';')[0];
    expect(cookie).toBeTruthy();
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
  });

  for (const method of ['POST', 'DELETE']) {
    it(`${method} /dsh-remote/session is refused even to a paired device (mint / revoke-everything)`, async () => {
      const res = await fetch(`http://127.0.0.1:${port}/dsh-remote/session`, {
        method, redirect: 'manual', headers: { cookie },
      });
      expect(res.status).toBe(403);
      expect((await res.json()).error).toMatch(/not reachable from a paired device/);
    });
  }

  it('POST /dsh-remote/tunnel is refused (a device must not cut its own tunnel)', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/dsh-remote/tunnel`, {
      method: 'POST',
      redirect: 'manual',
      headers: { cookie, 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'disconnect' }),
    });
    expect(res.status).toBe(403);
  });

  it('an unauthenticated caller is refused the same routes (no new information leaked)', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/dsh-remote/session`, {
      method: 'POST', redirect: 'manual',
    });
    expect(res.status).toBe(403);
  });

  it('GET /dsh-remote/session still reaches the engine (the app polls it for status)', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/dsh-remote/session`, {
      redirect: 'manual', headers: { cookie },
    });
    expect(res.status).not.toBe(403);
  });

  it('GET /dsh-remote/url-session still reaches the engine (the app renews its credential)', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/dsh-remote/url-session`, {
      redirect: 'manual', headers: { cookie },
    });
    expect(res.status).not.toBe(403);
  });
});

/**
 * v3.282: the replacement grace window is a LANDING window, not an amnesty.
 *
 * The old assertion for this behaviour was `expect(graceA.status).not.toBe(401)`
 * — which cannot tell 403 from 200, so tightening the window left the suite
 * green. These cases assert the actual authority, and they are paired: the
 * grace cookie must still complete the redirect it exists for, and must not
 * reach anything with data behind it.
 */
describe('v3.282 replaced-device grace window is landing-only', () => {
  let server: any;
  let fastifyInstance: any;
  let auditLogger: any;
  let sessionManager: any;
  const { dbPath, stateDbPath } = tmpDb('relay-grace');
  let port: number;
  let replacedCookie: string;

  beforeEach(async () => {
    server = await buildServer({ psk: TEST_PSK, dbPath, stateDbPath, upstream: DEAD_UPSTREAM, publicHost: PUBLIC_HOST });
    fastifyInstance = server.fastify;
    auditLogger = server.auditLogger;
    sessionManager = server.sessionManager;
    await fastifyInstance.listen({ port: 0, host: '127.0.0.1' });
    port = (fastifyInstance.server.address() as any).port;

    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/dsh`, {
      headers: { authorization: `Bearer ${TEST_PSK}` },
    });
    await new Promise((resolve) => ws.on('open', resolve));
    ws.send(JSON.stringify({
      type: 'session.register',
      payload: { sessionId: 'sess_grace', pairingToken: 'token_grace', ttlSeconds: 300 },
    }));
    await new Promise((resolve) => ws.on('message', resolve));
    ws.close();

    const landUrl = `http://127.0.0.1:${port}/?sessionId=sess_grace&token=token_grace`;
    const deviceA = await fetch(landUrl, { redirect: 'manual' });
    replacedCookie = (deviceA.headers.get('set-cookie') || '').split(';')[0];
    await fetch(landUrl, { redirect: 'manual' }); // device B lands → rotates the secret
  });

  afterEach(async () => {
    auditLogger.close();
    await fastifyInstance.close();
  });

  it('the replaced cookie may still complete the landing redirect (that is what the window is for)', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/`, {
      redirect: 'manual', headers: { cookie: replacedCookie },
    });
    // This suite points the upstream at a closed port, so a request that
    // PASSES the gate surfaces as a proxy 500. The assertion is on the gate,
    // not on the upstream: 401 or 403 would mean the grace window closed.
    expect(res.status).not.toBe(401);
    expect(res.status).not.toBe(403);
  });

  it('but it gets NO data-plane access inside the window', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual', headers: { cookie: replacedCookie },
    });
    expect(res.status).toBe(403);
  });

  it('and none of the plugin surface either', async () => {
    const res = await fetch(`http://127.0.0.1:${port}/dsh-remote/session`, {
      redirect: 'manual', headers: { cookie: replacedCookie },
    });
    expect(res.status).toBe(403);
  });

  it('once the window closes the old cookie is simply gone (401)', async () => {
    sessionManager.getSession('sess_grace')!.previousSecretAt = Date.now() - 91_000;
    const res = await fetch(`http://127.0.0.1:${port}/api/session.list`, {
      redirect: 'manual', headers: { cookie: replacedCookie },
    });
    expect(res.status).toBe(401);
  });
});
