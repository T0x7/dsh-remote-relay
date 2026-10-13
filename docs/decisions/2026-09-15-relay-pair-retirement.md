# ADR：`/__pair` 着陆端点退役，根路径 `/` 成为唯一着陆入口

**版本**：v3.203　**状态**：已生效　**日期**：2026-09-15

> 来源：从 `server/src/index.ts:21,437-441,474,511`、`client/src/tunnel.ts:376,383,430` 的
> 注释回填。原始决策文档当时未随代码保存，本文只记录可确证的事实。

## 做了什么

`/__pair?sessionId=…&token=…` 这个着陆端点在 v3.203 **整体退役**，根路径 `/` 成为唯一
着陆入口。随之移除的还有一整串配套逻辑：

- 旧 share-link 的 30 分钟 TTL ——「早已全部自然过期，无兼容存量」
- `verifyShareLink` / `PAIR_ONLINE_HTML`（配对在线拦截页）
- 在线拦截逻辑
- 着陆时的密钥轮换（现由根路径闸门统一处理）

## 为什么

着陆能力整体迁到根路径 `/` 的**签名 query 闸门**里（见
[2026-09-09-multi-device-pairing](2026-09-09-multi-device-pairing.md) 与
`server/src/index.ts` 的「根路径着陆闸门」段）：一条路径同时承担签名校验、颁
pairing cookie、302 `/auth` 跳板三件事，少一个端点就少一处「哪个是入口」的歧义。

## 现在是什么行为

根路径 `/` 按 `req.query` 分三类放行（`server/src/index.ts` 根路径闸门）：

1. **签名族** `?sessionId&hash&t&exp&mid` —— `verifyRootLanding` 验签 + session 存活
2. **旧格式** `?sessionId&token` —— 按 pairingToken 校验（仍受支持）
3. **无 query** —— 落入 Bearer / pairing cookie 的公共流程

过检后统一动作：颁 pairing cookie → 302 `/auth` 跳板。过期签名 / 坏 token /
未知 session 一律 401 独立过期卡，不进 dsh。

## 谁引用了这份 ADR

- `server/src/index.ts:441`
- `client/src/tunnel.ts:430`

## 已经付出代价的一处

`server/live-smoke.mjs`（旧版真引擎冒烟，2026-10-12 整理时删除）整段建立在
`/__pair` 上：第 3 步请求 `/__pair` 必然 401（`gate_auth_missing`），脚本**从来没跑
通过**。这条信息当时只写在 `server/src/index.ts:21` 的一句注释里。

现在真引擎冒烟改走根路径，见 `server/smoke/harness.mjs` 的 `landOnRoot()`。