# docs/internal — 内部排障记录

这些文档**不是给使用者看的**，它们是开发期的一次性排障记录：某个 dsh 引擎缺陷
在什么机器上、以什么形态复现过、结论是什么。发布前它们被整体挪进这个目录，
原因有二：

1. **时效性**——里面记录的是 2026-10-04 ~ 10-06 那一批引擎/宿主缺陷快照。
   对今天的读者，这些结论多半已经过期，照着排查反而会误导。
2. **环境细节**——真实主机形态、端口占用、profile 目录结构、数据目录布局。
   它们对复现历史有价值，对外部用户没有价值。

如果你在找一个**当前有效**的排障入口，请看上一层：

| 你要找的 | 去哪 |
|---|---|
| 引擎 `/api` RPC 的实测契约与易错点 | [`../engine-rpc-errata.md`](../engine-rpc-errata.md) |
| 引擎契约字段级引用 | [`../engine-contract-m2.md`](../engine-contract-m2.md) |
| App 真机踩坑与修复 | [`../app-field-notes.md`](../app-field-notes.md) |
| 插件装进 profile 不生效 / 显示「异常」 | [`../profile-install-troubleshooting.md`](../profile-install-troubleshooting.md) |
| 真机测试与 adb 手册 | [`../device-testing.md`](../device-testing.md) |

## 目录内容

| 文件 | 一句话 |
|---|---|
| `engine-handoff-20261004.md` | 会话 cwd 落错位置，交接宿主侧修复 |
| `engine-session-list-hang-report-20261004.md` | `session/list` 长时间挂起 |
| `engine-session-list-degradation-report-20261004.md` | `session/list` 退化为秒级，随会话数恶化 |
| `vendor-build-defect-report-20261004.md` | vendor 构建产物不完整导致引擎控制面全灭 |
| `engine-workspace-membership-flicker-report-20261005.md` | 工作区成员关系随机闪烁 |
| `engine-ghost-session-rows-report-20261006.md` | 注册表里的「幽灵」会话行，点开永远进不去 |
| `engine-vanishing-prompt-report-20261006.md` | 提示词在 UI 上消失 |
| `e2e-engine-askuser-changeset.md` | `ask_user` 工具挂载的 E2E 验证改动集 |
| `HANDOFF.md` | 仓库交接说明（地址、待办、已知约束） |

代码注释与测试里对这些报告的引用已同步改到 `docs/internal/` 前缀，改名后
不需要再改代码——引用只是文档指针，不是构建依赖。