# 决策记录

本目录记录**这个仓库自己的**设计决策，以及**哪些设计在哪个版本被废弃**。

## ⚠️ 关于这些文档的来源（重要）

这些 ADR 是 **2026-10-13 从代码注释回填**的：当时的决策文档没有随代码保存，
但代码里散落着大量「v3.xxx：xxx 退役 / 移除 / 推翻」这样的注释，测试和报告也
反复引用 `docs/decisions/...` 的路径——**那些路径当时全部指向不存在的文件**。

所以每份文档都遵守同一原则：

- **只写代码里可确证的事实**（行为、版本号、为什么改、不再做什么）；
- **不臆造原始决策过程**（当时的讨论、备选方案、拍板人一律不补——没有就是没有）；
- 顶部的「来源」小节写明这份 ADR 的事实是从哪些代码位置回填的。

要补历史，请以原始记录为准补进本文档，不要凭推测改写。

## 索引

| ADR | 版本 | 一句话 | 谁引用它 |
|---|---|---|---|
| [2026-08-30-relay-public-hardening](2026-08-30-relay-public-hardening.md) | — | 公网暴露的安全基线：PSK / Host 头 / BrowserAuth 三道闸 | `server/src/store.ts` |
| [2026-09-07-remote-single-mode](2026-09-07-remote-single-mode.md) | v3.141 | `mode` 字段删除，`/__session` 端点撤除——远程控制单模式化 | `server/src/protocol.ts`、`session.ts`、`store.ts`、`smoke/engine-contract.mjs` |
| [2026-09-07-dsh-auth-endpoint](2026-09-07-dsh-auth-endpoint.md) | v3.156.1 / v3.200 | 引擎 `/auth` 端点与 relay 白名单、cross-site 归一化 | `server/tests/relay.spec.ts` |
| [2026-09-09-multi-device-pairing](2026-09-09-multi-device-pairing.md) | v3.172 | per-pairing cookie 命名空间化 + `X-Pairing-Id` | `server/src/index.ts` |
| [2026-09-14-relay-remote-control-url-fix](2026-09-14-relay-remote-control-url-fix.md) | v3.203 | `/auth` 兜底路由：cookie 丢失时也能找到插件 | `server/src/index.ts` |
| [2026-09-15-relay-pair-retirement](2026-09-15-relay-pair-retirement.md) | v3.203 | `__pair` 着陆端点退役，根路径 `/` 是唯一入口 | `server/src/index.ts`、`client/src/tunnel.ts` |
| [2026-10-13-import-no-boots-relay](2026-10-13-import-no-boots-relay.md) | — | `import dist/index.js` 不再自启 relay（守卫从环境变量改成进程入口判定） | `server/src/index.ts`、`server/tests/boot-side-effect.spec.ts` |

## 跨仓引用（不在本仓）

跨仓路径一律写成 `<repo>:<path>` 形式（如 `host-app:docs/decisions/xxx.md`）——
**带前缀就不是本仓文件**，工具和读者都不会去本仓找它。本仓文档才用裸路径。

- `host-app:docs/decisions/2026-10-06-dsh-import-header-title-invisible.md`
  （ADR，v3.273）——属于 **host-app / dsh 仓**（涉及
  `scripts/dsh_import_session.mjs`），不是本仓文档。
  引用它的地方：`docs/internal/engine-ghost-session-rows-report-20261006.md`。

## 一个真实的教训

上面这些 ADR 缺失的代价是实实在在的：`server/live-smoke.mjs` 整段建立在
`/__pair` 上，而「该端点在 v3.203 退役」这条信息**只存在于 `server/src/index.ts`
的一句注释里**。写脚本的人没看到，脚本就在仓库里烂了几个月没人发现，直到
2026-10-12 整理冒烟测试时才被翻出来（当时的报错是 `gate_auth_missing` 401）。

**注释保不住记忆**——它只活在改动附近，搜索时找不到，读上下文的人也不会碰。
「这个设计还在吗」应该是一个可查的问题，而不是靠考古。