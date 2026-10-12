/**
 * 真引擎冒烟的共享底座 —— `smoke/relay.mjs` 与 `smoke/engine-contract.mjs` 都从这里起
 * 同一副家当（relay + 客户端隧道 + 假 plugin），各自只跑自己那部分断言。
 *
 * 为什么要有这层：这两个入口验证的是**同一条链路**的两类断言，重复一份起
 * 服务/搭隧道的代码只会让两边走样（改一处忘另一处）。harness 里只放「怎么把
 * 环境搭起来」，不放「该断言什么」——断言归各自文件，且必须注明是 relay 自身
 * 的契约还是某个引擎版本的契约。
 *
 * 需要真实 dsh 引擎在 `127.0.0.1:3080`（可用 DSH_ENGINE_PORT 改）。没有它就
 * 直接报错退出——这是**手动**入口，不进 CI（CI 跑的是 `scripts/e2e-stub.sh`，
 * 那个用桩上游，不需要真引擎）。
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { WebSocket } from 'ws';
import { buildServer } from '../dist/index.js';

export const PSK = process.env.RELAY_PSK ?? 'live-smoke-psk';

/**
 * 带超时的 fetch。
 *
 * 旧 `live-smoke.mjs` 里的 fetch 全裸奔——数据面或引擎一挂，脚本就**永久**
 * 阻塞，表现为「跑着跑着就没声了」，既不报错也不退出。本地手动跑时最难查的
 * 就是这种（像卡死、实际是等一个永远不会来的响应）。15s 足够覆盖本地回环。
 */
export function timedFetch(url, init = {}, ms = 15000) {
  return fetch(url, { ...init, signal: AbortSignal.timeout(ms) });
}
// 注意：RELAY_PSK / RELAY_PUBLIC_HOST 不是可选项——`import dist/index.js` 会在
// 模块顶层读 env 并跑 assertProductionConfig，PSK 用文档里的 insecure 默认值
// 或 publicHost 留空都会直接拒绝启动（这正是这个脚本一度没人能跑的原因）。
// npm scripts 里已经预设了本地值；直接 node 跑时请自己带上。
// 冒烟用的 publicHost 必须落在**引擎 trusted-host** 里，否则引擎 BrowserAuth
// 不会 mint 引擎 cookie（/auth 回 403）。默认是文档占位域名；要跑通请用你部署
// 时那个中继域名：`DSH_SMOKE_PUBLIC_HOST=<域名>`（会同时覆盖 RELAY_PUBLIC_HOST）。
export const PUBLIC_HOST =
  process.env.DSH_SMOKE_PUBLIC_HOST ?? process.env.RELAY_PUBLIC_HOST ?? 'relay.example.com';
export const ENGINE_PORT = Number(process.env.DSH_ENGINE_PORT ?? 3080);

/**
 * 读 dsh 的绑定 token（引擎启动时写盘，chmod 600，等价于进程内 DSH_BIND_TOKEN）。
 *
 * 候选路径是有意保留的三条：环境变量永远优先，其次是引擎现行目录，再其次是
 * legacy 宿主目录。**这里的目录名是运行时真实路径，不是文档里的示例**——改成
 * 占位符会让脚本静默找不到 token，报错还难懂，所以代码里必须写真名；对外描述
 * 时才用中性说法。
 */
export function readDshBindToken() {
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

/** 计数用的小工具：断言失败时把实际值一并打出来。 */
export function expectEq(actual, expected, what) {
  if (actual !== expected) {
    throw new Error(`${what}: expected ${expected}, got ${actual}`);
  }
}

export function expectTrue(cond, what) {
  if (!cond) throw new Error(what);
}

/**
 * 起好 relay + 假 plugin，返回接下来跑断言需要的全部句柄。
 *
 * 「假 plugin」是这段代码的核心：它占住 WSS 数据面的另一端，接住 relay 转发来的
 * `http.req` 帧、真的打引擎、再把 `http.res` 帧送回去。少了它，relay 的数据面
 * 会 504（plugin timeout）——所以它必须真的转发，不能打桩。
 */
export async function startStack() {
  const engineToken = readDshBindToken();
  console.log(`[harness] dsh engine DSH_BIND_TOKEN = ${engineToken.slice(0, 12)}…`);

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
  console.log(`[harness] relay listening at ${relayBase}`);

  // ---- 客户端侧：PSK 鉴权的 WSS，注册一条会话 ----
  const sessionId = `sess_smoke_${Date.now().toString(16)}`;
  const pairingToken = createHash('sha256').update(`smoke-${Date.now()}`).digest('hex');
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
      payload: { sessionId, pairingToken, ttlSeconds: 300, engineToken },
      timestamp: Date.now(),
    }));
  });
  console.log(`[harness] session.registered → ${JSON.stringify(registered)}`);

  const stack = {
    fastify, sessionManager, relayBase, ws,
    engineToken, sessionId, pairingToken, registered,
    /** relay 经数据面转发给插件的 http.req 帧计数 */
    framesReceived: () => stack._frames ?? 0,
    async close() {
      ws.close();
      await fastify.close();
    },
  };
  attachDataPlane(stack, ws, engineToken);
  return stack;
}

/**
 * 在**同一条** WSS 上兼做两件事：插件登记 + 数据面转发。
 *
 * 为什么必须同一条：relay 只把**发过 `session.register` 的连接**登记进
 * `wssPluginSockets`（按 pairingToken 索引），也只有它会把手机侧的 HTTP 请求
 * 路由过去。旧 `live-smoke.mjs` 开了两条 WSS——第一条发了 register（于是被
 * relay 当成插件），第二条「假 plugin」从不发消息（于是根本不是插件）：请求
 * 发给第一条、无人应答，Step 4 必然超时。**这个脚本从来没跑通过第 3 步**
 * （`/__pair` 早在 v3.203 退役），所以这条错误也就一直没被发现。
 */
function attachDataPlane(stack, ws, engineToken) {
  let framesReceived = 0;
  ws.on('message', (raw) => {
    const msg = JSON.parse(raw.toString());
    if (msg.type !== 'http.req') return;
    framesReceived++;
    stack._frames = framesReceived;
    const headers = { ...msg.headers };
    headers.host = PUBLIC_HOST;
    headers['x-app-token'] = engineToken;
    if (headers.cookie) {
      // strip dsh_remote_session（plugin 真实行为，保留 dsh-auth-*）
      headers.cookie = headers.cookie.split(';')
        .map(c => c.trim())
        .filter(c => !c.startsWith('dsh_remote_session'))
        .join('; ');
      if (headers.cookie === '') delete headers.cookie;
    }
    const upstream = http.request({
      hostname: '127.0.0.1', port: ENGINE_PORT, method: msg.method, path: msg.path, headers,
    }, (res) => {
      const chunks = [];
      let overflow = false;
      res.on('data', (c) => {
        if (overflow) return;
        if (chunks.reduce((n, x) => n + x.length, 0) + c.length > 4 * 1024 * 1024) {
          overflow = true;
          ws.send(JSON.stringify({
            v: 1, type: 'error', id: msg.id, code: 'payload_too_large',
            message: 'upstream body too large',
          }));
          upstream.destroy();
          return;
        }
        chunks.push(c);
      });
      res.on('end', () => {
        if (overflow) return;
        const outHeaders = {};
        for (const [k, v] of Object.entries(res.headers)) {
          if (k.toLowerCase() === 'set-cookie') continue;
          if (typeof v === 'string') outHeaders[k] = v;
          else if (Array.isArray(v)) outHeaders[k] = v.join(', ');
        }
        const sc = res.headers['set-cookie'];
        if (sc) outHeaders['set-cookie'] = Array.isArray(sc) ? sc.join(', ') : sc;
        ws.send(JSON.stringify({
          v: 1, type: 'http.res', id: msg.id, status: res.statusCode ?? 502,
          headers: outHeaders, body: Buffer.concat(chunks).toString('utf8'),
        }));
      });
      res.on('error', (err) => {
        ws.send(JSON.stringify({
          v: 1, type: 'error', id: msg.id, code: 'engine_down', message: err.message,
        }));
      });
    });
    upstream.on('error', (err) => {
      ws.send(JSON.stringify({
        v: 1, type: 'error', id: msg.id, code: 'engine_down',
        message: `upstream connect: ${err.message}`,
      }));
    });
    if (msg.body && msg.body.length > 0) upstream.write(msg.body);
    upstream.end();
  });
}

/**
 * 着陆拿 cookie（relay 侧行为，两个入口都要用）。
 *
 * **走根路径 `/` 而不是 `/__pair`**：v3.203 起 `/__pair` 已退役，根路径是唯一
 * 着陆入口（签名 query 验签 + 颁 pairing cookie + 302 /auth 跳板）。旧
 * `live-smoke.mjs` 还停在 `/__pair`，那个端点早就不存在了——脚本能拿到 401
 * 不是配置问题，是端点退役了。这里用根路径仍受支持的旧格式
 * `?sessionId&token`（pairingToken 校验），签名族
 * `?sessionId&hash&t&exp&mid` 由客户端那条路径覆盖。
 */
export async function landOnRoot(relayBase, sessionId, pairingToken) {
  const pairRes = await timedFetch(
    `${relayBase}/?sessionId=${sessionId}&token=${pairingToken}`,
    { redirect: 'manual' },
  );
  const setCookie = pairRes.headers.get('set-cookie') ?? '';
  const cookie = setCookie.split(';')[0];
  return { pairRes, cookie, location: pairRes.headers.get('location') };
}