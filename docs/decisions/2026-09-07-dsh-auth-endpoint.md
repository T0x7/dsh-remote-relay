# ADR：引擎 `/auth` 端点与 relay 白名单

**版本**：v3.156.1（进白名单）、v3.200（cross-site 归一化）　**状态**：已生效
**日期**：2026-09-07 / 2026-09-14

> 来源：从 `server/src/index.ts:190-230`（`GATE_EXEMPT_PATHS` 与
> `normalizeAuthFetchSite` 的注释）、`server/tests/relay.spec.ts:155` 回填。

## 这条链路是什么

着陆 `302 /auth` → 手机跟到 `/auth` → relay 把请求经数据面送到**引擎**的 `/auth` →
引擎用 `engine.token` 校验后颁发 `dsh-auth-*` cookie → 再 `303` 到 `/` 直出 SPA。
后续 `GET /` 需要**两枚 cookie 同时在场**：relay 闸门认
`dsh_remote_session__<sid>`，引擎认 `dsh-auth-*`。

## v3.156.1：`/auth` 进 `GATE_EXEMPT_PATHS`

原因（代码注释原话）：落地 → 302 → `/auth` 链上，浏览器可能带**旧** secret
cookie（Firefox 实测：轮换后的新 cookie 未随 302 发出），gate 拒之则
`dsh-auth` 引擎 cookie 永远拿不到 → WS mux 401 → SPA 卡在 connecting。

安全性不依赖 relay cookie：`/auth` 自带 **X-App-Token** 闸（plugin 注入 engine
token，dsh BrowserAuth 验证），手机伪造不了。所以进白名单不削弱防护。

## v3.200：`/auth` 剥掉 `sec-fetch-site`

手机扫码的固定动线是「外部 app（相机 / adb intent）唤起浏览器 → 配对 URL →
302 /auth」。按 Fetch 规范，这种导航的 initiator 是不透明来源，Chrome 标
`sec-fetch-site: cross-site`；而引擎 `BrowserAuth.mintCookieForTrustedHost` 的
`isTrustedApiRequest` **无条件拒 cross-site** → 引擎回 403 `forbidden` → 手机
永久停在 `/auth`。

（实测环境：Android Chrome 153，2026-10-02。）

**只在 `/auth` 上剥这一个头**，其余路径原样透传 —— 引擎 fence 对 `/api/*` 的纵深
防御不受影响。这个旁路的注释里还记着：`/__devices` 里那批「从未 paired」的历史
session 就是这个 bug 的产物。

## 谁引用了这份 ADR

`server/tests/relay.spec.ts:155`（「然后 303 回 /；详细 ADR 见
`docs/decisions/2026-09-07-dsh-auth-endpoint.md`」——这个链接在本仓重建之前是死链）。