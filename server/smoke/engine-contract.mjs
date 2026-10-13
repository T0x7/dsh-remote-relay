/**
 * L3 · 引擎契约（真引擎冒烟，**随引擎版本变化**部分）
 *
 * ⚠️ 这个文件里的每一条都不是 relay 的责任，而是**「某个引擎版本必须满足的
 * 行为」**。引擎升级后这里失败，多半不是 relay 坏了，而是引擎变了——请更新下面
 * 的版本标注与期望值，而不是去改 relay。
 *
 * 与 `relay.mjs` 的分工：relay 自己该保证的东西在那里；这里是「relay 依赖引擎
 * 的当前行为」这份清单。历史上两者混在一个文件里（`live-smoke.mjs`），导致引擎
 * 一升级就假失败、且看代码的人会误以为 relay 依赖某个引擎版本。
 *
 * 手动运行：`npm run smoke:engine`（需要真实 dsh 在 127.0.0.1:3080）。
 */
import { startStack, landOnRoot, timedFetch, expectEq, expectTrue, PUBLIC_HOST } from './harness.mjs';

/**
 * 契约表。改引擎时**只改这里**，并且把 `since` 更新成新版本。
 * `id` 保持稳定——它在回归记录里被引用。
 */
const CONTRACT = [
  {
    id: 'session-endpoint-removed',
    since: 'v3.141',
    what: '/__session 端点已撤除：未配对用户拿到 401（gate 兜底）而不是 200',
  },
  {
    id: 'single-mode-no-mode-field',
    since: 'v3.141',
    what: 'session.registered 的响应里不再有 mode 字段（单模式化）',
  },
  {
    id: 'pair-lands-on-auth',
    since: 'v3.143',
    what: '根路径着陆后跳 /auth?next=<着陆URL>（不是裸 /），让引擎侧用 token 颁发 cookie',
  },
  {
    id: 'auth-303-via-wss',
    since: 'v3.151',
    what: '/auth 经 WSS 数据面拿到引擎 303 与 dsh-auth-* cookie',
  },
  {
    id: 'readonly-fence-removed',
    since: 'v3.141',
    what: 'POST /api/session.create 不再被 readonly fence 403 拦',
  },
  {
    id: 'devices-payload-no-mode',
    since: 'v3.141',
    what: '/__devices 的 payload 不含 mode 字段',
  },
];

const stack = await startStack();
const { relayBase, sessionId, pairingToken, registered } = stack;
let passed = 0;
const ok = (id) => {
  const row = CONTRACT.find((c) => c.id === id);
  console.log(`  ✓ [${row.since}] ${row.what}`);
  passed++;
};

// ---- /__session 已撤除 ----
const sessionOld = await timedFetch(`${relayBase}/__session`, { redirect: 'manual' });
expectTrue(sessionOld.status !== 200, '__session should be removed');
expectTrue(
  sessionOld.status === 404 || sessionOld.status === 401,
  `__session expected 404 or 401 (gate/removed), got ${sessionOld.status}`,
);
ok('session-endpoint-removed');

// ---- 注册响应里没有 mode ----
expectTrue(registered.mode === undefined, 'registered.mode must be undefined');
ok('single-mode-no-mode-field');

// ---- 着陆跳 /auth?next=… ----
// 注意 `next` 带的是**完整回跳 URL**（URL 编码的原始着陆地址），不是裸 `/`——
// 那是 `/__pair` 时代的形态。断言只锚前缀 + 可解码，别锚死整串：回跳地址里含
// relay 端口与一次性 token，逐字节比对会让这条断言每换端口就假失败。
const { pairRes, cookie, location } = await landOnRoot(relayBase, sessionId, pairingToken);
expectEq(pairRes.status, 302, 'root landing expected 302');
expectTrue(
  typeof location === 'string' && location.startsWith('/auth?next='),
  `root landing should redirect to /auth?next=…, got ${location}`,
);
const nextTarget = decodeURIComponent(String(location).slice('/auth?next='.length));
expectTrue(
  nextTarget.includes(sessionId),
  `next should point back at the landing URL, got ${nextTarget}`,
);
ok('pair-lands-on-auth');

// ---- /auth 经数据面拿到 303 + 引擎 cookie ----

const authRes = await timedFetch(`${relayBase}/auth?next=/`, {
  headers: { cookie, host: PUBLIC_HOST }, redirect: 'manual',
});
if (authRes.status === 403) {
  // 403 来自引擎 BrowserAuth，且与 x-app-token 无关（直连验证过：不带 token
  // 同样是 403）——是引擎不认本次用的 publicHost（直连 curl 试过三个 host：
  // 127.0.0.1:3080 与 localhost:3080 回 504，局域网 IP 回 403）。这是**环境**
  // 不满足，不是 relay 坏了，所以给可操作的提示而不是裸断言。
  throw new Error(
    `/auth got 403 — 本机引擎的 trusted-host 不包含本次用的 publicHost ` +
    `(${PUBLIC_HOST})。用你部署时那个中继域名重跑，例如：\n` +
    `  DSH_SMOKE_PUBLIC_HOST=<你的中继域名> npm run smoke:engine\n` +
    `（该值决定 relay 转发给引擎时的 Host 头；引擎 BrowserAuth 只对 trusted-host mint cookie）`,
  );
}
expectEq(authRes.status, 303, '/auth expected 303 (WSS data plane)');
const setCookieLine = (authRes.headers.get('set-cookie') ?? '').split(';')[0];
expectTrue(setCookieLine.startsWith('dsh-auth-'), 'engine cookie not minted');
ok('auth-303-via-wss');

// ---- readonly fence 已移除 ----
const writeRes = await timedFetch(`${relayBase}/api/session.create`, {
  method: 'POST',
  headers: { cookie, 'content-type': 'application/json' },
  body: JSON.stringify({ prompt: 'smoke:engine' }),
  redirect: 'manual',
});
const writeBody = await writeRes.text().catch(() => '');
expectTrue(
  !(writeRes.status === 403 && writeBody.includes('read-only')),
  'readonly fence still active — enforcement removal regression',
);
ok('readonly-fence-removed');

// ---- /__devices payload 不含 mode ----
const devices = await timedFetch(`${relayBase}/__devices`, {
  headers: { authorization: `Bearer ${process.env.RELAY_PSK ?? 'live-smoke-psk'}` },
});
const mine = (await devices.json()).devices.find((d) => d.sessionId === sessionId);
expectTrue(mine, 'our session not in /__devices');
expectTrue(!('mode' in mine), `__devices must not contain 'mode'; got ${JSON.stringify(mine)}`);
ok('devices-payload-no-mode');

await stack.close();
console.log(`\n[smoke:engine] OK — ${passed} 条引擎契约全部通过`);
console.log('[smoke:engine] 引擎升级后若这里失败：改契约表的 since 与期望值，不要改 relay');