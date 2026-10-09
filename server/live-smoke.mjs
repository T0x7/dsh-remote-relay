/**
 * 端到端实活验证：本地起 relay（指向真实本地 dsh 引擎 127.0.0.1:3080），跑完整
 * 配对 / 主页加载 / __devices 链路。覆盖 v3.141 单模式化的全栈改动点：
 *  1. /__session 已删除（404 而不是 401）
 *  2. 配对后 GET / 走 preHandler → dsh 返回 303 → cookie 落地
 *  3. 再次 GET / 已带 cookie → dsh 直出 SPA（200）
 *  4. POST /api/session.create 不再被 403 readonly 拦
 *  5. /__devices payload 不含 mode 字段
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { WebSocket } from 'ws';
import { buildServer } from './dist/index.js';

const PSK = process.env.RELAY_PSK ?? 'live-smoke-psk';
const PUBLIC_HOST = process.env.RELAY_PUBLIC_HOST ?? 'relay.example.com';
const ENGINE_PORT = Number(process.env.DSH_ENGINE_PORT ?? 3080);

function readDshBindToken() {
  // engine.token 由 dsh 引擎启动时写盘（chmod 600），等价于进程内 DSH_BIND_TOKEN。
  // dsh 启动时把该值塞进自己 + 子插件的 env；client 经 session.register 送达
  // relay，relay 注入 x-app-token / ?token= 与引擎 BrowserAuth 比对。
  //
  // 落盘目录由**引擎**（而非本仓）决定，且随宿主 App 的 home 而变，所以这里
  // 按顺序探测而不是钉死一个路径——钉死会在换宿主后静默读不到 token。
  // DSH_ENGINE_TOKEN_FILE 永远优先。
  const home = process.env.HOME || os.homedir();
  const candidates = [
    process.env.DSH_ENGINE_TOKEN_FILE,
    path.join(home, '.dsh', 'engine.token'),
    path.join(home, '.agent-stock', 'engine.token'), // legacy host-app home
  ].filter(Boolean);
  const tokenFile = candidates.find((f) => fs.existsSync(f));
  if (!tokenFile) {
    throw new Error(
      `engine.token not found (looked in: ${candidates.join(', ')}) — ` +
        'override with DSH_ENGINE_TOKEN_FILE=...',
    );
  }
  return fs.readFileSync(tokenFile, 'utf8').trim();
}

const ENGINE_TOKEN = readDshBindToken();
console.log(`[live] dsh engine DSH_BIND_TOKEN = ${ENGINE_TOKEN.slice(0, 12)}…`);

const { fastify, sessionManager } = await buildServer({
  psk: PSK,
  dbPath: ':memory:',
  stateDbPath: ':memory:',
  upstream: `http://127.0.0.1:${ENGINE_PORT}`,
  publicHost: PUBLIC_HOST,
  trustProxy: '127.0.0.1,::1',
});

await fastify.listen({ port: 0, host: '127.0.0.1' });
const relayPort = fastify.server.address().port;
const relayBase = `http://127.0.0.1:${relayPort}`;
console.log(`[live] relay listening at ${relayBase}`);

// Step 0: /health 探针
const health = await fetch(`${relayBase}/health`);
console.log(`[step 0] /health → ${health.status}`);
if (health.status !== 200) throw new Error('/health must be 200');

// Step 1: /__session 已删除（v3.141）—— endpoint 撤除后实际是 gate hook 先 401。
// 未配对用户拿到的永远是 401（gate 兜底），因为 /__session 不在
// GATE_EXEMPT_PATHS 白名单里。这是预期行为：从用户视角 endpoint 已不存在。
const sessionOld = await fetch(`${relayBase}/__session`, { redirect: 'manual' });
console.log(`[step 1] /__session → ${sessionOld.status}`);
if (sessionOld.status === 200) throw new Error('__session should be removed in v3.141');
if (sessionOld.status !== 404 && sessionOld.status !== 401) {
  throw new Error(`__session expected 404 or 401 (gate/removed), got ${sessionOld.status}`);
}

// Step 2: PSK WSS session.register
const sessionId = `sess_live_${Date.now().toString(16)}`;
const pairingToken = createHash('sha256').update(`live-${Date.now()}`).digest('hex');
const ws = new WebSocket(`ws://127.0.0.1:${relayPort}/ws/dsh`, {
  headers: { authorization: `Bearer ${PSK}` },
});
await new Promise((resolve, reject) => {
  ws.on('open', resolve);
  ws.on('error', reject);
  setTimeout(() => reject(new Error('ws open timeout')), 3000);
});
const registered = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('session.registered timeout')), 3000);
  ws.on('message', (raw) => {
    const msg = JSON.parse(raw.toString());
    if (msg.type === 'session.registered') { clearTimeout(timer); resolve(msg); }
  });
  ws.send(JSON.stringify({
    type: 'session.register',
    payload: { sessionId, pairingToken, ttlSeconds: 300, engineToken: ENGINE_TOKEN },
    timestamp: Date.now(),
  }));
});
console.log(`[step 2] session.registered → ${JSON.stringify(registered)}`);
if (registered.mode !== undefined) throw new Error('v3.141: registered.mode must be undefined');
if (registered.reusesSecret !== false) throw new Error('first register, reusesSecret must be false');
if (sessionManager.currentEngineToken !== ENGINE_TOKEN) throw new Error('engineToken not stored');

// Step 3: /__pair 着陆
const pairRes = await fetch(
  `${relayBase}/__pair?sessionId=${sessionId}&token=${pairingToken}`,
  { redirect: 'manual' },
);
console.log(`[step 3] /__pair → ${pairRes.status}`);
if (pairRes.status !== 302) throw new Error(`__pair expected 302, got ${pairRes.status}`);
const setCookie = pairRes.headers.get('set-cookie') ?? '';
const cookie = setCookie.split(';')[0];
if (!cookie.startsWith('dsh_remote_session=')) throw new Error('cookie not set');
// v3.143：着陆跳 /auth?next=/（不是 /）—— 让 dsh 端用 engine.token 颁发引擎 cookie。
const location = pairRes.headers.get('location');
if (location !== '/auth?next=/') {
  throw new Error(`__pair redirect target expected /auth?next=/, got ${location}`);
}

// Step 4 (v3.143 + v3.151)：跟 302 访问 /auth?next=/
// v3.151 路径：relay 把 phone HTTP 请求转 http.req 帧发 plugin；plugin 转发到 dsh；
// dsh 用 engine.token 颁发引擎 cookie；302 → / 链一致
// v3.151 live smoke：relay 端启用 WSS 数据面后，我们必须把"假 plugin"加进 WSS
// 通道（接住 http.req 帧 + 打 dsh + 回 http.res 帧）。如果假 plugin 没接住，
// relay 的 WSS 代理会 504（plugin timeout）——这是 v3.151 关键断言。
let fakePluginInflight = 0
let fakePluginFramesReceived = 0
const relayWsBase = relayBase.replace(/^http/, 'ws')
const fakePlugin = new WebSocket(`${relayWsBase}/ws/dsh`, {
  headers: {
    authorization: `Bearer ${process.env.RELAY_PSK ?? 'live-smoke-psk'}`,
    'x-session-ts': Date.now().toString(),
  },
})
await new Promise((resolve, reject) => {
  fakePlugin.on('open', resolve); fakePlugin.on('error', reject)
  setTimeout(() => reject(new Error('fake plugin ws open timeout')), 5000)
})
fakePlugin.on('message', (raw) => {
  const msg = JSON.parse(raw.toString())
  if (msg.type !== 'http.req') return
  fakePluginInflight++
  fakePluginFramesReceived++
  // 重建 outgoing headers：strip dsh_remote_session、注入 host + x-app-token
  const headers = { ...msg.headers }
  headers.host = PUBLIC_HOST
  headers['x-app-token'] = ENGINE_TOKEN
  if (headers.cookie) {
    // strip dsh_remote_session（plugin 真实行为，保留 dsh-auth-*）
    headers.cookie = headers.cookie.split(';').map(c => c.trim()).filter(c => !c.startsWith('dsh_remote_session=')).join('; ')
    if (headers.cookie === '') delete headers.cookie
  }
  const upstream = http.request({
    hostname: '127.0.0.1', port: ENGINE_PORT, method: msg.method, path: msg.path, headers,
  }, (res) => {
    const chunks = []
    let overflow = false
    res.on('data', (c) => {
      if (overflow) return
      if (chunks.reduce((n, x) => n + x.length, 0) + c.length > 4 * 1024 * 1024) {
        overflow = true
        fakePlugin.send(JSON.stringify({ v: 1, type: 'error', id: msg.id, code: 'payload_too_large', message: 'upstream body too large' }))
        upstream.destroy()
        return
      }
      chunks.push(c)
    })
    res.on('end', () => {
      if (overflow) return
      const outHeaders = {}
      for (const [k, v] of Object.entries(res.headers)) {
        if (k.toLowerCase() === 'set-cookie') continue
        if (typeof v === 'string') outHeaders[k] = v
        else if (Array.isArray(v)) outHeaders[k] = v.join(', ')
      }
      const sc = res.headers['set-cookie']
      if (sc) outHeaders['set-cookie'] = Array.isArray(sc) ? sc.join(', ') : sc
      fakePlugin.send(JSON.stringify({
        v: 1, type: 'http.res', id: msg.id, status: res.statusCode ?? 502,
        headers: outHeaders, body: Buffer.concat(chunks).toString('utf8'),
      }))
      fakePluginInflight--
    })
    res.on('error', (err) => {
      fakePlugin.send(JSON.stringify({ v: 1, type: 'error', id: msg.id, code: 'engine_down', message: err.message }))
      fakePluginInflight--
    })
  })
  upstream.on('error', (err) => {
    fakePlugin.send(JSON.stringify({ v: 1, type: 'error', id: msg.id, code: 'engine_down', message: `upstream connect: ${err.message}` }))
    fakePluginInflight--
  })
  if (msg.body && msg.body.length > 0) upstream.write(msg.body)
  upstream.end()
})

// 等 fake plugin 完全就绪
await new Promise(r => setTimeout(r, 200))

const authRes = await fetch(`${relayBase}/auth?next=/`, {
  headers: { cookie, host: PUBLIC_HOST }, redirect: 'manual',
})
console.log(`[step 4] GET /auth?next=/ (WSS data plane) → ${authRes.status}`)
if (authRes.status !== 303) {
  throw new Error(`/auth expected 303 (WSS data plane via fake plugin), got ${authRes.status}`)
}
if (fakePluginFramesReceived === 0) {
  // 这是 v3.151 关键诊断：如果 fake plugin 没收到帧，说明 WSS 数据面没工作
  throw new Error('fake plugin never received http.req frame — WSS data plane broken')
}
console.log(`[step 4]   ↑ fake plugin processed ${fakePluginFramesReceived} http.req frame(s) via WSS data plane`)
const setCookieLine = (authRes.headers.get('set-cookie') ?? '').split(';')[0]
if (!setCookieLine.startsWith('dsh-auth-')) {
  throw new Error(`engine cookie not minted via WSS data plane; got: ${setCookieLine.slice(0, 60)}`)
}
console.log(`[step 4]   ↑ engine cookie minted via WSS data plane: ${setCookieLine.slice(0, 50)}…`)
const bothCookies = `${cookie}; ${setCookieLine}`

// Step 5: 跟 303 访问 /（带双 cookie）——验证 BrowserAuth 接受 cookie 后直出 SPA
const warm = await fetch(`${relayBase}/`, {
  headers: { cookie: bothCookies, host: PUBLIC_HOST }, redirect: 'manual',
})
console.log(`[step 5] GET / (warm) → ${warm.status}`)
if (warm.status !== 200) {
  const text = await warm.text()
  throw new Error(`warm GET / expected 200, got ${warm.status} body=${text.slice(0, 80)}`)
}
const ct = warm.headers.get('content-type') ?? ''
if (!ct.includes('text/html')) throw new Error(`SPA expected text/html, got ${ct}`)
const html = await warm.text()
if (html.length < 200) throw new Error(`SPA body suspiciously small: ${html.length} bytes`)
console.log(`[step 5]   ↑ SPA loaded (${html.length} bytes, ${ct})`)

fakePlugin.close()

// Step 6: POST /api/session.create 不再被 readonly 403 拦
const writeRes = await fetch(`${relayBase}/api/session.create`, {
  method: 'POST',
  headers: { cookie, 'content-type': 'application/json' },
  body: JSON.stringify({ prompt: 'live-smoke' }),
  redirect: 'manual',
});
const writeBody = await writeRes.text().catch(() => '');
console.log(`[step 6] POST /api/session.create → ${writeRes.status} body=${writeBody.slice(0, 80)}`);
if (writeRes.status === 403 && writeBody.includes('read-only')) {
  throw new Error('readonly fence still active — v3.141 enforcement removal regression');
}

// Step 7: /__devices payload 不含 mode
const devices = await fetch(`${relayBase}/__devices`, {
  headers: { authorization: `Bearer ${PSK}` },
});
const devicesBody = await devices.json();
console.log(`[step 7] /__devices → ${devices.status} devices=${devicesBody.devices.length}`);
const mine = devicesBody.devices.find((d) => d.sessionId === sessionId);
if (!mine) throw new Error('our session not in /__devices');
if ('mode' in mine) throw new Error(`v3.141: /__devices payload must not contain 'mode'; got ${JSON.stringify(mine)}`);

ws.close();
await fastify.close();
console.log('[live] OK — all 7 assertions passed');