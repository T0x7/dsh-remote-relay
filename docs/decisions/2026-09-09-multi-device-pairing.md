# ADR：per-pairing cookie 命名空间化（多设备 / 多窗口并行）

**版本**：v3.172　**状态**：已生效　**日期**：2026-09-09

> 来源：从 `server/src/index.ts:46-56`（`SESSION_COOKIE_PREFIX` /
> `SESSION_COOKIE_PATTERN` / `PAIRING_ID_HEADER` 的定义注释）与
> `server/src/session.ts`、`server/src/index.ts:900-925`（`wssHttpProxy` 的
> 路由段）回填。

## 问题

同一浏览器窗口里同时持有 N 条 pairing 时，cookie 只有一个命名空间，互相撞。

## 做法（Plan A：cookie 命名空间化）

- cookie 名格式：`dsh_remote_session__<sessionId>`（`SESSION_COOKIE_PREFIX`），
  合法形态由 `SESSION_COOKIE_PATTERN` 约束；
- SPA 每次 `/api/*` 请求附 `X-Pairing-Id` header（`PAIRING_ID_HEADER`），
  relay 据此挑对应 cookie 转发到正确的 plugin socket；
- 同一浏览器可同时持有 N 条 pairing cookie，命名空间互不撞。

注意 `index.ts` 里 **同时存在** `SESSION_COOKIE_NAME = 'dsh_remote_session'`（旧名）
与 `SESSION_COOKIE_PREFIX = 'dsh_remote_session__'`（v3.172 起的命名空间名）——
两者并存是历史遗留，写断言时别锚死到 `=` 那一位。

## sessionId 字符集放宽

从收紧状态放宽为 `[A-Za-z0-9_-]+`（与 `session.ts` 的 `rawSid` 同步），既兼容
plugin `mintShareLink` 生成的 hex sid，也兼容测试里的可读 sid（如
`sess_pair_ok`）。

**安全边界靠 256-bit pairingToken，不靠 sid 的熵** —— 这是放宽的前提，写代码
时别把 sid 当安全凭据用。

## 谁引用了这份 ADR

`server/src/index.ts:46`（定义处直接引用 `决策 1.5`）。