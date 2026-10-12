# 测试分层

这个仓库有四类测试，**跑法、覆盖面、失败含义各不相同**。混着跑或指望一个命令全绿，是这个项目历史上最大的浪费来源——所以先把边界写清楚。

| 层 | 位置 | 上游 | 引擎依赖 | CI | 跑法 |
|---|---|---|---|---|---|
| **L1** relay 契约单测 | `server/tests/` | 桩 | 无 | ✅ | `pnpm --filter dsh-remote-relay test` |
| **L2** 桩上游端到端 | `scripts/e2e-stub.sh` | **桩**（脚本自起的假 SPA） | 无 | ✅ | `bash scripts/e2e-stub.sh` |
| **L3** 引擎契约 | `server/smoke/engine-contract.mjs` | **真引擎** | **强** | ❌ | `npm run smoke:engine` |
| **L4** App 自动化 | `app/test/`、`app/packages/dsh_remote_core/test/` | fake gateway | 无 | ✅ | `flutter test` |

另有 **L5 真机结构冒烟**：`app/integration_test/`，手动、**只许在专用机上跑**（它会清空目标机 App 数据）。

---

## L1 · relay 契约单测（CI）

`server/tests/relay.spec.ts`，纯协议/状态机验证，全部用 fixture，**不碰网络**。改 relay 内部逻辑时跑它——秒级。

```bash
pnpm --filter dsh-remote-relay test
```

**失败意味着**：relay 自己的逻辑坏了。

## L2 · 桩上游端到端（CI）

`scripts/e2e-stub.sh` 在本地起 relay + client + 隧道，配对后用 curl 打一遍落地 URL。关键点：**上游是脚本自己起的桩**（返回固定 HTML），所以它验的是「relay 自己通不通」，**与引擎版本无关**，任何提交都该过。

```bash
bash scripts/e2e-stub.sh    # 通过时退出码 0，并打印 OK
```

**失败意味着**：链路断了（隧道、落地、数据面、gate），且与引擎无关。

## L3 · 引擎契约（手动，⚠️ 会随引擎版本变化）

`server/smoke/engine-contract.mjs` 连**真实 dsh 引擎**（默认 `127.0.0.1:3080`，用 `DSH_ENGINE_PORT` 改），逐条验证**当前引擎版本必须满足的行为**。

```bash
npm run smoke:engine        # 需要本机有真实 dsh 在跑
```

同目录还有 `smoke/relay.mjs`（`npm run smoke:relay`），走同样的真实链路，但只断言 **relay 自己**该保证的东西（健康探针、注册握手、着陆发 cookie、WSS 数据面送达、设备列表自识别）——**与引擎版本无关**，是 L3 的稳定子集。

> **这两册为什么分开**：`relay.mjs` 里的断言是 relay 的责任，引擎升级不该让它们失败。`engine-contract.mjs` 里的断言是**一份契约清单**，每条带 `since: v3.xxx` 标注。
>
> **引擎升级后 L3 失败时，改的是契约表，不是 relay**——把过时的条目删掉或更新期望值，并调整 `since`。历史上这两类断言混在一个文件里（`live-smoke.mjs`），结果就是引擎一升级就假失败，看代码的人也会误以为 relay 依赖某个引擎版本。

## L4 · App 自动化（CI）

Flutter 侧分三批跑，边界见 `app/TESTING.md`：

```bash
cd app
flutter analyze
flutter test packages/dsh_remote_core/test/api    # 引擎契约（纯 Dart）
flutter test test/ui_sweep                         # 界面巡检（清单驱动）
flutter test --exclude-tags golden                 # 其余全部
```

golden 排除是有意的：基线在 macOS 录的，Linux CI 必红；本地全量跑仍保留漂移检测。

---

## 真机相关

- **L5 结构冒烟**：`cd app && flutter test integration_test -d <serial>`，3 例，验证冷启动/Tab/诊断页在真机上真的存在。**会清空目标机 App 数据，只跑专用机。**
- **走查与缺陷记录**：`docs/device-testing.md`。

## 环境要求小结

| 层 | 需要什么 |
|---|---|
| L1 / L2 / L4 | 只要 Node / Flutter，无外部依赖 |
| L3 / L5 | 需要真实引擎（L3）或专用真机（L5） |

L3 找不到引擎 token 时会明确报错并提示 `DSH_ENGINE_TOKEN_FILE`——它按顺序探测 `~/.dsh/engine.token` 与 legacy 宿主目录，两处都没有才失败。