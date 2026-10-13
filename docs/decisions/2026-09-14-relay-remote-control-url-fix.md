# ADR：`/auth` 兜底路由 —— cookie 丢失时仍能找到插件

**版本**：v3.203　**状态**：已生效　**日期**：2026-09-14

> 来源：从 `server/src/index.ts:925-945`（`wssHttpProxy` 的兜底段）回填。
> 该处注释注明「回填线上热修 Patch B」。

## 问题

`/auth` 正常走 per-pairing 路由（URL 会话 token → pairing cookie → `X-Pairing-Id`）。
但极端情况下手机会**丢 cookie**：隐私模式拦重定向链的 `Set-Cookie`、浏览器策略
丢弃第三方 cookie 等。此时 `/auth` 既无 URL token 也无 cookie，per-pairing 路由
找不到插件 socket → 503 → 手机永久停在 `/auth`。

## 做法

`/auth`（与 `/assets/*`、`/plugins/*`、根路径 `/` 同级）增加一条**兜底**：没有
凭证时，回落到「**任一在线且 bridge ready 的 pairing**」的 socket。

理由：这四条路径要么是公开构建产物（`/assets/*`、`/plugins/*`，所有 pairing 同版本，
内容一致），要么是着陆跳板本身，不含 `/api` 业务数据。

## 注意

- 判 path 必须**剥掉 query** —— `req.url` 含 `?sessionId=…&hash=…`，直接比字符串会
  永远不匹配。
- 引擎的 `dsh-auth-*` cookie 单独过不了闸门，所以这个兜底只解决「找得到插件」，
  cookie 仍由引擎按 trusted-host 颁发（见
  [2026-09-07-dsh-auth-endpoint](2026-09-07-dsh-auth-endpoint.md)）。

## 顺带移除的一处救援

同批还移除了 v3.176.2 的「**3xx Location 补回凭证字段**」救援逻辑
（`index.ts:1001`）：根路径闸门对带凭证 query 的 `/` 一律在**闸门层**就 302 着陆，
不再透传给 dsh，所以「dsh 303 剥掉 query 导致失联」这个场景不复存在，该补丁失去
存在意义。