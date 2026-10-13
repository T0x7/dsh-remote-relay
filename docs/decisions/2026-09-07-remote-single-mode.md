# ADR：远程控制单模式化 —— 删除 `mode` 字段、撤除 `/__session`

**版本**：v3.141　**状态**：已生效　**日期**：2026-09-07

> 来源：从 `server/src/protocol.ts:21`、`server/src/session.ts:14`、
> `server/src/index.ts:1144`、`server/src/store.ts:49,99` 的注释回填。

## 做了什么

v3.106 引入的 `mode?: 'readonly' | 'full'` 在 v3.141 被**删除**：远程控制单模式化后，
配对即等价于 full。连带撤除 `/__session` 端点。

三处代码对同一件事的表述：

- `protocol.ts`：「删除了 v3.106 的 `mode?: 'readonly'|'full'` 字段（v3.141 起单模式化）」
- `session.ts`：「删除 v3.106 加入的 `mode` 字段——远程控制单模式化后，配对等价于 [full]」
- `index.ts:1144`：「忽略上游仍可能带过来的 `payload.mode`（旧 plugin 过渡期）」

## 数据库的平滑遗留

`store.ts` 保留了 v3.106 加的 `mode` 列 —— **保留但既不写也不读**，为的是让旧库
不必迁移即可启动（`store.ts:49`、`:99` 都写明这是「平滑遗留库」）。所以：

- 想要彻底清掉这一列，需要一次显式的库迁移；
- 在此之前，任何「查一下 mode 字段」的代码都会看到它，但读出来也没有意义。

## `/__session` 撤除后的实际表现

端点没了，但**未配对用户拿到的不是 404 而是 401** —— 因为它不在
`GATE_EXEMPT_PATHS` 白名单里，gate 兜底先拦下（`index.ts` Step 1 注释原文）。
从用户视角「端点已不存在」这个结论不变，但断言必须接受 404/401 两种形态。

这条现在是 `server/smoke/engine-contract.mjs` 里 `session-endpoint-removed`
契约的期望值（`since: v3.141`）。