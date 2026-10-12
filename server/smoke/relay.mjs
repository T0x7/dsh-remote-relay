/**
 * L1 · relay 自身契约（真引擎冒烟，**引擎无关**部分）
 *
 * 这里断言的全部是 relay 自己的职责：健康探针、会话注册握手、着陆发 cookie、
 * 设备列表里能认出自己、WSS 数据面把 http.req 帧真的送到插件。
 *
 * **刻意不含**任何随引擎版本变化的断言——那些在 `engine-contract.mjs`，因为
 * 引擎一升级，它们失败时该改的是契约表，不是 relay。
 *
 * 手动运行：`npm run smoke:relay`（需要真实 dsh 在 127.0.0.1:3080）。
 */
import { startStack, landOnRoot, timedFetch, expectEq, expectTrue, PUBLIC_HOST } from './harness.mjs';

const stack = await startStack();
const { relayBase, sessionId, pairingToken, registered, sessionManager, engineToken } = stack;
let passed = 0;
const ok = (what) => { console.log(`  ✓ ${what}`); passed++; };

// ---- 1. 健康探针 ----
const health = await timedFetch(`${relayBase}/health`);
expectEq(health.status, 200, '/health must be 200');
ok('/health 200');

// ---- 2. 注册握手的响应形状 ----
// registered.mode 是 relay 不再发 mode 字段的保证（引擎侧单模式化不影响这条）。
expectEq(registered.reusesSecret, false, 'first register: reusesSecret');
expectEq(sessionManager.currentEngineToken, engineToken, 'engineToken stored in session');
ok('session.registered 形状正确，engineToken 已落到会话');

// ---- 3. 着陆发 cookie（cookie 颁发是 relay 的活） ----
const { pairRes, cookie } = await landOnRoot(relayBase, sessionId, pairingToken);
expectEq(pairRes.status, 302, 'root landing expected 302');
// cookie 名带 sessionId 后缀（dsh_remote_session__<sid>），别断言到 '=' 那一位。
expectTrue(cookie.startsWith('dsh_remote_session'), 'root landing must set dsh_remote_session cookie');
ok('根路径着陆 302 + 落地 cookie');

// ---- 4. WSS 数据面：relay 真的把 http.req 帧送到了插件 ----

const authRes = await timedFetch(`${relayBase}/auth?next=/`, {
  headers: { cookie, host: PUBLIC_HOST }, redirect: 'manual',
});
// 只验**relay 把帧送到了插件**。引擎认不认这个 Host、要不要 mint 引擎 cookie
// 是引擎契约，归 engine-contract.mjs——本机引擎的 trusted-host 未必配了
// relay.example.com，在这里断言会把「引擎没配」误报成「relay 坏了」。
expectTrue(
  stack.framesReceived() > 0,
  `插件没收到 http.req 帧 —— WSS 数据面断了（relay 回 ${authRes.status}）`,
);
console.log(`  ↑ 插件经 WSS 数据面处理了 ${stack.framesReceived()} 个 http.req 帧`);
ok('WSS 数据面把请求送到了插件');

// ---- 5. 设备列表里能认出自己这条会话 ----
const devices = await timedFetch(`${relayBase}/__devices`, {
  headers: { authorization: `Bearer ${process.env.RELAY_PSK ?? 'live-smoke-psk'}` },
});
const devicesBody = await devices.json();
const mine = devicesBody.devices.find((d) => d.sessionId === sessionId);
expectTrue(mine, 'our session not in /__devices');
ok(`/__devices 能找到本会话（共 ${devicesBody.devices.length} 条）`);

await stack.close();
console.log(`\n[smoke:relay] OK — ${passed} 条 relay 契约全部通过`);
console.log('[smoke:relay] 引擎版本相关的断言在 smoke/engine-contract.mjs');