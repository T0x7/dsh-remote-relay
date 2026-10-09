# dsh-remote App 实施计划（v1）

> 依据：[`app-design.md`](app-design.md)（12 节设计案，决策已全部收敛）+
> [`app-ui-mockups.html`](app-ui-mockups.html)（15 屏 mockup）。
> 状态：计划（2026-09-30 制定）。开工即按本计划执行，完成项随做随勾。

**执行纪律**（违反任何一条即返工）：

1. 每个任务 = 代码 + 对应层测试，同一次提交；不许"先写完再补测试"。
2. 契约类型（relay/engine）双侧 hand-copy + 测试互钉；变更必须与上游形状同批核对。
3. 不改 `server/`、`client/`、`plugin/` 任何一行（v1 零改动承诺）；`app/` 不进 pnpm workspace。
4. 新增依赖过必要性审查：允许清单 `flutter_secure_storage` / `mobile_scanner` / `local_auth` /
   `intl`；网络一律 `dart:io` 原生（HttpClient + WebSocket）——证书锁定需要底层控制，**不引第三方 http 库**。
5. 所有用户可见文案走 intl 资源键（zh/en 同 PR）；错误走 §7.2 ErrorCode 模型，禁止裸字符串。

## 0. 总览

| 阶段 | 内容 | 粗估（单人） | 出口判据 |
|---|---|---|---|
| M0 | 杀三件运行时风险（过闸/pinning/4001） | 1–2 天 | 三项实测结论回填 §10；风险清零或有备选 |
| M1 | 机器管理 + 状态 + 会话管理 + 安全基线 | 1.5–2 周 | 自动验收全绿 + 真机冒烟通过（§6 门定义）；7 天试用期**与 M2 并行**，不阻塞开工 |
| M2 | 控制台（对话/任务/主机 + 三类挂起交互） | ~2 周 | 对话与任务操作全流程（真实引擎验收）；开源物料齐 |

依赖链：M0.5（pinning）→ M1.2（网络层）；M1 全部 → M2；M2.1（契约抄录）→ M2.2/3/4。

## 1. M0 原型验证（先杀风险，再盖楼）

| # | 任务 | 产出 | 验收（DoD） | 风险与备选 |
|---|---|---|---|---|
| T0.1 | 脚手架 | `flutter create app`（org 定名、Material 3 深色主题骨架、en/zh intl 就位、目录按 §6 布局） | `flutter analyze`/`flutter test` 绿 | — |
| T0.2 | 凭证组装 | `lib/credentials/`：签名 URL 解析、Bearer 组装、畸形 query 拒绝 | dart 单元对 `protocol.md` 算法全覆盖（含 43 位 hash 校验、mid 格式） | — |
| T0.3 | 集成测试台 v0 | 测试 helper：spawn `node server/dist/index.js`（随机端口/测试 PSK）+ Node 假引擎（静态 `/dsh-remote/session`）+ Dart 侧铸签名 URL | CI 可重复跑；不起真机器/真 dsh | server 未 build 则显式 skip 并打印原因（对齐仓库 skip 纪律） |
| T0.4 | **实测① 过闸** | 真机/模拟器：粘贴链接 → `GET /dsh-remote/session` 200；401 时走失效路径 | 真机截图 + 结论记入 §10 | — |
| T0.5 | **实测③ pinning** | `badCertificateCallback` + TOFU pin 表；分别对自签 relay 测 HttpClient 与 `WebSocket.connect` | 两条链路都能按 pin 表放行/拒绝；**若 WS 不走回调** → 备选：自定义 SecurityContext 注入 pin 证书，结论记入 §10 | 全设计最大单点风险；备选路径已预研 |
| T0.6 | **实测② 4001 自愈** | 连 `events.*?token=`；触发他方 landing（浏览器扫新码）→ 观察 close(4001) → 同 Bearer 重连成功 | 时序记录 + 结论记入 §10；重连逻辑沉淀为 `EventsSocket` 雏形 | — |
| T0.7 | 风险回填 | 设计案 §10 更新三项结论 | 文档与实测一致 | — |

## 2. M1 MVP（机器管理 + 状态 + 会话管理 + 安全基线）

**数据层**（T1.1–T1.3，无 UI 依赖，先行）

| # | 任务 | 产出（文件） | DoD |
|---|---|---|---|
| T1.1 | 机器/凭证存储 | `lib/machines/store.dart`、`lib/credentials/credential_store.dart`（secure_storage） | 单元全绿；删除机器=元数据+凭证+pin 同删（§12 本地数据清单） |
| T1.2 | 会话时钟 | `lib/credentials/session_clock.dart`：exp 倒计时、T-2h 续期调度（退避+补试）、**三因判别**、30 天本地记录 | 单元覆盖 §4 全部分支（过期/吊销/上限/续期成功失败） |
| T1.3 | 错误模型 | `lib/api/error_code.dart`：§7.2 全表映射 + zh/en 文案资源 | 表驱动单元测试逐行对 §7.2 |

**网络层**（依赖 T0.5 结论）

| # | 任务 | 产出 | DoD |
|---|---|---|---|
| T1.4 | HTTP 客户端 | `lib/api/relay_http.dart`：Bearer 注入、`Accept-Language`、429 退避、TOFU per-host pin、超时→`network.unreachable` | 集成台全链路：200/401/429/自签放行/指纹变更拦截 |
| T1.5 | 事件流 | `lib/api/events_socket.dart`：WS + `?token=`、4001 静默自愈、前台生命周期绑定（§5 并发策略：仅当前机器） | 集成台模拟 4001/断网恢复 |
| T1.6 | relay 契约 | `lib/api/relay.dart`：`/dsh-remote/*` 五路由类型（与 server 测试形状互钉） | 契约测试双侧绿 |

**UI**（依赖数据+网络）

| # | 任务 | 屏 | DoD |
|---|---|---|---|
| T1.7 | 机器列表 + 三态卡 | A | Widget 测试三态；倒计时芯片色阶单元 |
| T1.8 | 配对流 | B/C/J | 扫码（mobile_scanner）+ 粘贴；**先验证后入库**；失败卡文案对齐 |
| T1.9 | 机器详情 + 逃生舱 | D | 两进度条双时钟；吊销/断开二次确认；"在浏览器打开"走 url-session 铸链 |
| T1.10 | 失效页 | I | 三因判别驱动文案切换（Widget 测试） |
| T1.11 | 设置 + 锁屏 | G/H | local_auth；TOFU pin 管理；前台提醒开关 |
| T1.12 | 前台提醒路由 | — | 隧道断开/任务完成→L3/L4（§5 清单） |

**M1 收尾**：Golden 基线（关键屏 × zh/en × 130%）；`app/TESTING.md` v1（15 屏手动清单）；真机一周稳定运行（§10 出口）。

## 3. M2 控制台

| # | 任务 | 产出 | DoD |
|---|---|---|---|
| T2.1 | engine 契约抄录 | `lib/api/engine.dart` + 事件类型：**最小集**——会话 CRUD、消息收发、`approval/request`、`question`（AskUserQuestion 结构 + plan-review）、`modelCatalog`+selectModel、`contextPressure/Breakdown`、tokenUsage | 与 dsh-root 源形状互钉的契约测试；**只抄最小集**，其余增量 |
| T2.2 | 会话域 | `lib/console/sessions/`：列表/恢复/新建（屏 M，子代理缩进挂父） | 与 web 共用会话两端接力实测 |
| T2.3 | 对话 UI | `lib/console/chat/`：气泡流（用户/agent/lineage/工具节点简化）、composer（挂起态换提问入口）、审批卡、ctxbar（屏 E） | Widget：审批/提问回调经事件流回传（假引擎断言） |
| T2.4 | 提问/计划审批 | 屏 P：多问题批量、单/多选、跳过、plan-review（approve/decline 原样 label） | 单元对 AskUserQuestion 边界（multiSelect/custom/skip） |
| T2.5 | 模型与思考等级 | 屏 K：provider 分组 + efforts chips + 跟随默认 | 目录全引擎下发，App 零硬编码（契约测试断言无内置清单） |
| T2.6 | 上下文/统计 | 屏 L + 统计胶囊：同一投影口径 | 数值与 web 一致性抽查 |
| T2.7 | 团队页 | 屏 N：目录 + 只读输出 + lineage 索引 | 子会话只读（不可输入）断言 |
| T2.8 | 任务/主机页 | 屏 F + 主机指标（events.host） | 三态任务卡 |
| T2.9 | 开源物料 | `app/README.md`（构建指引/能力边界）、截图、CHANGELOG、CI workflow（§12） | fork 即 build；CI 全绿 |

## 4. 风险登记册

### M2 内部执行序（2026-10-02 拆解，随做随勾）

> T2.1 拆细：传输底座先行，域模型随后。传输底座不依赖任何域字段，可与契约
> 抄录并行——已按此并行开工（见 `app/PROGRESS.md` D-009/D-010/D-011）。

| # | 任务 | 依赖 | 产出 | 状态 |
|---|---|---|---|---|
| T2.1a | 传输底座 | — | `engine_rpc.dart`（单播 JSON-RPC 信封）+ `engine_mux.dart`（`/api/remote.mux` 多路复用） | ✓ core 93/93 |
| T2.1b | 契约抄录 | — | `docs/engine-contract-m2.md`（12 项逐字段 + `文件:行号`） | 进行中 |
| T2.1c | 域模型 | T2.1b | `lib/api/engine.dart`：会话/消息/审批/提问/模型目录/上下文 | 待 |
| T2.1d | 错误映射 | T2.1b | code → `ErrorCode` 全表（`toAppError` 不再一律 unknown） | 待 |
| T2.1e | 集成床 | T2.1c | 假引擎实现 M2 最小集，契约双向互钉 | 待 |

**T2.1a 先行的理由**：控制面是 JSON-RPC 信封 + mux 多路复用（不是逐端点
REST），这个底座一旦搞错，后面每个域模型都会跟着错；且它与域字段无关，是唯一
可以与契约抄录真正并行的部分。

| 风险 | 概率/影响 | 缓解 |
|---|---|---|
| `WebSocket.connect` 不走 badCertificateCallback | 中/高 | T0.5 专项验证；备选：SecurityContext 注入 pin；再备选：WS 经自定义 HttpClient 升级 |
| engine API 抄录面失控 | 中/中 | T2.1 钉死"最小集先行"，跑通对话再增量；契约测试防漂移 |
| 假引擎与真 dsh 行为差异 | 中/中 | M1/M2 出口都含真机/真实引擎验收（§10）；live 冒烟沿用 server 的 live-smoke 思路 |
| Golden 基线跨平台字体差异 | 低/低 | CI 用固定字体环境；golden 按平台分目录 |
| mobile_scanner 权限/机型兼容 | 低/中 | 粘贴链接为等价入口；相机路径走手动清单 |

## 5. 里程碑外部依赖（需要 维护者 配合的事项）

- M1 门的人工验收：真机对真实机器冒烟一次（~30 分钟，清单在 `app/TESTING.md`）。
- M1 试用期（7 天日常使用）与 M2 开发**并行**——试用不是 M2 开工的前置。
- M2 门：真实 dsh 引擎全流程一次（对话+审批+提问+模型切换+两端接力）+ 开源物料终审。
- 发布并入仓库开源（repository.url 迁移是仓库级 HANDOFF 事项，需授权）。

## 6. 阶段门（Gate）：每阶段的标准与验收标准

> 每个门一页汇报（异步发你，**绿灯不需回复即继续下一阶段**；红灯必须等你决策）。
> 进度追踪：本计划任务表随做随勾 + `app/PROGRESS.md` 记决策日志——任何新会话可无损续作。

### 门 0（M0 → M1）

- **进入条件**：本计划被确认（即基线）。
- **内建质量标准（自动）**：`flutter analyze` 0 warning；T0.1–T0.3 单元/集成全绿、无未解释 skip（对齐仓库 verify 纪律）。
- **验收标准（全部自动，本地栈 + 模拟器，不需要人）**：
  1. 模拟器粘贴链接 → 本地真 relay `GET /dsh-remote/session` 200（截图/日志留档）；
  2. 自签端点：HttpClient 与 `WebSocket.connect` 各自按 TOFU pin 表放行/拒绝（或备选路径验证通过）；
  3. curl 触发他方着陆 → App 侧 WS 收 4001 → 同 Bearer 重连成功（时序日志）。
- **红灯条件（唯一找你的情况）**：pinning 主路径与全部备选失效 → 设计变更决策。

### 门 1（M1 → M2）

- **内建质量标准（自动）**：五层测试全绿（单元/Widget/契约/Golden/集成）；契约测试覆盖全部钉住形状；Golden 基线含 zh/en × 130% 关键屏；`app/TESTING.md` v1 齐全。
- **验收标准**：
  - 自动：全部 M1 任务 DoD 达成；集成台复现 §4 凭证生命周期全部分支；
  - 人工（一次 ~30 分钟）：真机 + 真实机器冒烟——扫码→状态→吊销→失效页→重扫，逐项打勾。
- **并行规则**：冒烟通过即开 M2；"7 天日常使用无 P0/P1"作为 M1 正式关闭条件在后台计时，出问题回修优先级高于 M2 新功能。
- **红灯条件**：真机表现与模拟器/本地栈不一致且无法本地复现。

### 门 2（M2 → 发布就绪）

- **内建质量标准（自动）**：五层全绿；契约最小集与 dsh-root 源形状互钉；CI workflow 在 fork 模拟下全绿；README/TESTING/CHANGELOG 审阅级齐全；零遥测/零崩溃收集复核（依赖树断言）。
- **验收标准**：
  - 自动：全部 M2 任务 DoD；设备端四条关键流绿；
  - 人工：真实引擎全流程一次（对话、审批卡、提问/计划审批、模型与档位切换、上下文环、两端接力）+ 开源物料终审（你过目截图与 README）。
- **红灯条件**：真实引擎行为与抄录契约不符且需改 server/client/plugin 才能解（=越出 v1 零改动承诺）。

## 7. 打断协议（什么才找你——除此之外全部自主推进）

仅以下五类情况中断请求你决策，其余一律自行处理并记入 `app/PROGRESS.md`：

1. **阶段门红灯**：验收标准未达成且无既定备选。
2. **设计变更**：任何 tempted 修改 `server/`、`client/`、`plugin/` 的时刻（v1 零改动是不可越的线）。
3. **需要真实环境**：真实机器二维码、真实 dsh 引擎、真机物理设备操作。
4. **白名单外依赖**：`flutter_secure_storage` / `mobile_scanner` / `local_auth` / `intl` 与 `dart:io` 之外任何包。
5. **安全决策**：如 pinning 全备选失效、发现协议层安全隐患。

日常信息流：每完成一个阶段门发一页汇报（结论先行、绿灯免回复）；每完成一批任务在 PROGRESS.md 追加一行（做了什么/改了哪些文件/下一步），你随时可看，不看也不阻塞。
