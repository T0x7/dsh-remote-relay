# dsh-remote App 设计案（手机原生远程控制）

> 状态：提案（proposal）。本文是设计依据与决策记录，不是已实现功能的文档。
> 仓库现状引用截至 2026-09-30（v3.206 代际，见 docs/internal/HANDOFF.md）。

## 1. 一句话定位

**App = relay 的原生移动客户端。** 手机这个角色从"扫码进浏览器加载 dsh SPA"升级为"原生应用直连 relay"，两道门信任模型、隧道协议、服务端部署全部不变。

"远程控制他们" = 控制各台机器上的 **通用 dsh 引擎**：agent 对话与任务、隧道与会话状态、配对设备管理。

**与任何具体引擎部署完全解耦**（用户拍板 2026-09-30）：App 只面向 dsh 通用 API 面
（`/api/*`）与本仓管理面（`/dsh-remote/*`），不内置任何特定引擎/插件的路由、任务或
业务概念（如 host-app 的股票任务——与 App 无关，也不进 App 的任何规划）。引擎侧
自有 token 闸（`x-app-token`）属于机器侧 client 配置（`engineToken`），对 App 透明。

**随本仓一起开源**：App 是 monorepo 第四包，与 server/client/plugin 同仓、同 MIT、
同一次 GitHub 开源发布（repository.url 换公网地址是 HANDOFF 既有待办，App 直接搭车）。

## 2. 为什么 v1 可以零协议改动

relay 闸门（`server/src/index.ts`）对手机侧已经有三条凭证路径，其中一条天然为非浏览器客户端准备：

| 路径 | 形态 | 适用 |
|------|------|------|
| pairing cookie | `dsh_remote_session__<sid>=<secret>`（HttpOnly） | 浏览器落地 |
| **URL 会话 Bearer** | `Authorization: Bearer <sid>.<exp>.<mid>.<t>.<hash>` | **原生 HTTP 客户端** |
| WS token query | 桥接 WS 路径上 `?token=<同上 Bearer>` | 原生 WebSocket |

App 需要的三个面，relay 今天都已暴露：

1. **引擎数据面** — `/api/*` 全量代理（HTTP），`/api/events.mux`、`/api/events.host`、`/api/remote.mux` + `RELAY_WS_BRIDGE_PATHS`（WS 桥接）。
2. **远程管理面** — 插件路由 `/dsh-remote/*` 同样过闸代理：`GET session`（隧道态 + 配对 + 设备在线）、`POST session`（铸配对）、`DELETE session`（吊销全部）、`GET url-session`（铸 24h 签名链接）、`POST tunnel`（连接/断开）。
3. **QR 内容即凭证** — QR 编码的就是签名 URL `https://<relay>/?sessionId=&hash=&t=&exp=&mid=[&name=]`，App 扫码后自行组装 Bearer，无需 cookie jar。

`mid` 是**机器**指纹（`sha256(hostname::mac::install-id)`），relay 侧仅 informational（`server/src/index.ts` verifyUrlSessionToken）——App 不需要也无法伪造它，原样携带即可。

**结论：v1 不改 server / client / plugin 任何一行。** 新增 `app/` 一个包。

## 3. 架构

```
┌───────────────── iPhone / Android ─────────────────┐
│  dsh-remote App（Flutter，见 §6）                     │
│                                                     │
│  ┌──────────┐   ┌────────────┐   ┌──────────────┐  │
│  │ 凭证库     │   │ relay API  │   │ engine API   │  │
│  │ Keychain/ │   │ client     │   │ client       │  │
│  │ Keystore  │   │ /dsh-remote/*│ │ /api/* + WS  │  │
│  └──────────┘   └────────────┘   └──────────────┘  │
└──────┬───────────────┬──────────────┬──────────────┘
       │ 扫码配对        │ HTTPS Bearer │ WSS ?token=
       ▼               ▼              ▼
  相机/Deep link ──▶ nginx(TLS) ──▶ relay(VPS) ~~~PSK tunnel~~~ client ──▶ dsh engine
                                     │
                                      （无推送组件——2026-09-30 拍板，见 §5）
```

- **多机器 = 多 relay origin。** 每台机器一个独立 relay + 独立配对；App 以机器列表管理，互不相干。QR 里的 URL 已含 relay origin，扫码即完成全部绑定。
- **App 永不持有 PSK。** PSK 是机器侧凭证（client ↔ relay 隧道鉴权）；App 只持有会话级凭证。这条是安全设计的锚点（§8）。

## 4. 凭证与会话生命周期

```
扫码/粘贴/Deep link
   │  解析 ?sessionId&hash&t&exp&mid&name（★ 不请求该 URL——见 §4.1）
   ▼
组装 Bearer = sid.exp.mid.t.hash ──▶ Keychain（每机器一条）
   │
   ├─ HTTP：Authorization: Bearer …（/api/*、/dsh-remote/*）
   ├─ WS：wss://<relay>/api/events.mux?token=…
   │
   ├─ 续期：exp 前（T-2h）GET /dsh-remote/url-session → 新 24h Bearer
   │        【已确认】dsh webserver 对插件前缀路由不做 Host 校验
   │        （dsh-root packages/host/webserver/src/index.ts 直接 match→handler，
   │        Host fence 仅作用于 /api），插件 dispatch 亦无 loopback 检查
   │        ——远程可达，自续期成立。mintUrlSession() 无参调用给"第一个
   │        retained session"铸 token，不一定是 App 原会话，但同引擎任意
   │        活会话权限等价；零会话时 400（"No active pairing"）。
   │
   ├─ 硬上限：会话绝对寿命 30 天（RELAY_SESSION_MAX_AGE_SEC），到期必重扫
   │
   └─ 吊销：DELETE /dsh-remote/session（App 内一键，或任意机器/设备执行）
            失窃手机 → 任意渠道吊销即失效；audit 落痕
```

### 4.1 与 v3.204「单浏览器独占」的交互（已核实，App 必须遵守）

relay 着陆逻辑（`server/src/index.ts` 根路径闸门）：任何设备**请求签名 URL（landing）**
即轮换同引擎全部 pairing 的 sessionSecret，并 close(4001, 'device_replaced') 掐断所有
旧 secret 授权的事件流（90s previousSecret 宽限）。对 App 的三条推论：

1. **App 永远不做 landing**——扫码只解析 query 组 Bearer，不 GET 该 URL。否则每次
   App 配对都会把正在用的浏览器顶下线（反之亦然）。Bearer 验签只需会话存活
   （machine 侧已注册），不需要 landing 过。
2. **App 的 Bearer 不受轮换影响**：token 凭证是 HMAC(PSK, sid|exp|mid|t)，与
   sessionSecret 无关；轮换不删会话 → HTTP 请求继续有效。
3. **App 的 WS 桥接会被 4001 掐断**：桥接创建时以"当时 current secret"登记授权，
   他方 landing 轮换后命中 evictedSecrets → close(4001)。**同 Bearer 重连即自愈**
   （重连登记新 secret）。App 的 WS 客户端必须把 4001 实现为静默自动重连。

> 附带发现（应回填仓库文档）：plugin `src/index.ts` 中 url-session / tunnel 路由的
> 「loopback-only by deployment / 远程 HTTP 请求进不到这里」注释是**错误认知**——
> webserver 不对插件路由做 Host 校验，远程经 relay 完全可达（上游
> `dsh-root/packages/host-app/host-app-remote` 副本同样只有注释、无校验）。
> 对 App 是利好（自续期 + 隧道开关远程可用）；若产品上真要 loopback-only，需要
> 在 dispatch 里按 `socket.remoteAddress` 实判，而不是依赖错误注释。

App 侧必须实现的闸门协同行为（与 SPA 客户端半边对齐）：

- **401 看门狗**：任何 401 → 会话已死（过期/吊销/30d 到顶），进"重新配对"态，清 Keychain 条目。Bearer 路径无 cookie 轮换，不需要 device-replaced 逻辑。
- **429 退避**：relay 有限流，指数退避重试。
- **体积上限**：单响应 32 MiB、大响应并发 8（`docs/protocol.md`）；聊天历史拉取要分页。

## 5. 功能规划

### v1（MVP）

| 模块 | 内容 | 数据来源 |
|------|------|----------|
| 机器管理 | 多机器列表（名称/状态灯/会话倒计时）、添加（扫码/粘贴/`dshremote://` deep link）、删除；**浏览器逃生舱**（"在浏览器打开完整 Web 界面"——App 铸 `url-session` 链接交系统浏览器，覆盖插件运行面页面与一切长尾界面） | 本地 + `GET /dsh-remote/url-session` |
| 状态面板 | 隧道态（connected/reconnecting）、活跃 QR、在线/已配对设备数 | `GET /dsh-remote/session` |
| 远程控制台（范围 B） | agent 对话 + host 状态（`/api/events.host`）+ 任务列表 + **会话管理**（新建/恢复，与 web 共用引擎侧会话）。对话区对齐 web 信息面：**模型与思考等级**（provider 分组的 modelCatalog + 每模型 `reasoning.efforts`（Off/Low/High/Max）与「跟随默认」，`session.selectModel`——与 web composer 座位互通）、**上下文占用**（contextPressure/Breakdown——占用环 + system/tools/对话三段分解，屏 L）、**审批卡**（`approval/request` 允许/拒绝，屏 E）、**提问卡**（`question`：多问题批量作答——单选/多选/自由文本/可跳过，屏 P；`plan-review` 特化 = markdown 计划 + approve/decline 原样回传；挂起时占 composer 座位，与审批独立结算）、统计胶囊（tok/s、缓存命中，对齐 ui-chat StatsPills）。方法/投影清单从 dsh-root UI 包抄录、测试钉死——仓库既有惯例 | `/api/*` + `/api/events.mux`、`/api/events.host` WS + session 投影 |
| 前台事件提醒 | App 打开期间的即时提示（隧道断开、任务完成、**审批请求**等），走既有 WS 流，**零新组件、无后台推送** | WS 事件流 |
| 会话管理 | 吊销全部配对、隧道手动连接/断开、把当前 QR 屏示给另一台设备配对 | `DELETE/POST /dsh-remote/*` |
| 安全基线 | Keychain/Keystore 存储、生物识别锁、TOFU 证书锁定 | §8 |
| i18n | **仅 zh/en（2026-09-30 拍板）**，v1 随包：跟随系统 + 手动切换；全部文案经 Flutter intl 资源键，零硬编码字符串（引擎下发内容——模型名/目录/错误码——按原文展示，不翻译） | intl |
| 错误与反馈体系 | 四层呈现（L1 全屏/L2 内联卡/L3 横幅/L4 SnackBar）+ 文案三段式 + 统一 ErrorCode 对象模型（§7.2）——横切全部屏幕 | §7.2 |
| **多机器并发策略** | **只有"当前打开的机器"建 events WS**；机器列表页对其余机器做低频状态刷新（`GET /dsh-remote/session`，默认 60s、下拉手动）——省电、省流量，也不占 relay 的桥接并发。切后台即断 WS（前台提醒本就只在打开时） | WS ×1 + 轮询 |

### v1.5

- iOS Shortcuts / Android App Actions：快速指令（问 agent 一句、断开隧道）。
- 主屏小组件：隧道状态 + 会话倒计时。

### 后台推送：不做（2026-09-30 拍板）

评估过并否决：真后台推送需要 push gateway 自托管组件 + iOS 侧 APNs 密钥自备 +
Android 侧 FCM（国行无 GMS 不可靠）——与"源码即产物、零账号服务"形态冲突，且
"App 打开时才知道"已由前台提醒覆盖。前台提醒进 v1（见上表）。若未来确需"手机
被叫"，再按原分析重启（watchdog webhook 是现成起点）；当前不排期、不留桩。

### v2（候选，未排期）

- **会话级审计尾巴**：relay 新端点（session-scoped audit tail），App 可看自己会话的落地/操作记录。作为 relay 可选能力，默认关闭。

## 6. 技术栈（已拍板：Flutter，2026-09-30）

**决定：Flutter。** 用户拍板的理由，也是本设计的硬约束：

1. **iOS + Android 一套源码**——对外提供服务的形态下，双平台一致性优先级高于与
   monorepo 的 TS 类型共享；
2. **源码即产物**——本仓只交付源码，不打 IPA、不上架 App Store、不提供任何
   开发者账号侧服务（EAS/CI 云构建/Firebase 均不引入）；客户自备 Flutter SDK
   与各自平台的签名/账号自行构建（`flutter build apk` / `flutter build ios`）。
   Flutter 的全本地工具链让"拿到源码 → 出包"不经过任何第三方账号，这是选型的
   决定性因素；
3. 零 JS 桥、自带 en/zh i18n（intl）、`flutter_secure_storage` / `mobile_scanner` /
   `local_auth` / `home_widget` 覆盖全部原生能力需求。

历史决策矩阵（保留作记录；"推荐 Expo"已被上述理由推翻——Expo 的自建路径会推着
客户走向 EAS 账号，与源码即产物的形态冲突）：

| 方案 | monorepo 共享 | 原生能力 | 自建出包（客户侧） | 评价 |
|------|--------------|----------|--------------------|------|
| **Flutter**（已定） | 引入 Dart，零共享 | 好 | **完全本地，零账号耦合** | ✅ |
| Expo + React Native | TS 同构 | 好 | EAS 账号牵引，prebuild+xcodebuild 路径重 | 被推翻 |
| Capacitor 壳 | 壳内仍是 relay 上的 SPA | 需桥接 | 同 RN | 本质是"专用浏览器" |
| SwiftUI + Kotlin 双原生 | 零共享 | 最好 | ×2 份源码 | 一套源码诉求直接不满足 |

工程布局——`app/` 是仓库第四个顶级目录，**Flutter 工程，不进 pnpm workspace**
（`pnpm-workspace.yaml` 仍只列 server/client/plugin），也不进 npm 发布链：

```
app/
  lib/
    main.dart
    credentials/     # flutter_secure_storage 封装、Bearer 组装、续期调度
    api/
      relay.dart     # /dsh-remote/* 客户端 + 契约类型（与 server 测试形状互钉）
      engine.dart    # /api/* 子集客户端 + WS 事件流（4001 自愈重连）
    machines/        # 机器列表与配对状态机
    console/         # 控制台 UI
    lock/            # local_auth 生物识别锁
    l10n/            # en/zh（intl）
  test/              # 契约测试：relay/engine 类型与 server 测试形状互钉
```

**交付形态（源码即产物）**：仓库即交付物——不发布 IPA/APK 二进制，无 TestFlight、
无商店、无账号服务。客户路径：clone → `flutter pub get` → `flutter build apk`（或
iOS 侧自备证书 `flutter build ios`）。仓库可附 GitHub Actions 工作流作自建参考
（fork 即用，产物留在客户自己的 Actions 里）。App 内**零遥测、零崩溃收集、零第三方
SDK 依赖**（与 §8 安全姿态一致，也是开源可信度的一部分）。

## 7. 信息架构

```
Tab 机器                       Tab 控制                    Tab 设置
├─ 机器卡片列表                 ├─ 当前机器 agent 控制台      ├─ App 锁（生物识别开关）
│   状态灯/名称/会话倒计时       │   对话流 + 任务操作          ├─ 证书锁定管理（TOFU 列表）
├─ 机器详情                     │   （PRIVILEGED 方法天然      ├─ 前台提醒开关
│   隧道态 / 活跃 QR / 设备      │    403——UI 上直接不出现，    ├─ 语言
│   吊销全部 / 隧道开关          │    对齐 plugin 的 remote     └─ 关于（版本/协议 v:1）
└─ ＋ 添加（扫码/粘贴）           │    gating 隐藏集）
配对流（模态）：扫码 → 确认（relay 域名 + name 参数）→ 完成
```

远程通道的 PRIVILEGED 约束由引擎侧 Host 钉定保证（relay 无法越权），App 的 UI 隐藏只是体验对齐——**安全上不依赖 App 自律**，与 plugin 远程 gating 的定位一致。

### 7.1 UI 视觉设计（v1 已定稿）

高保真 mockup（15 屏 + 状态行为 + 会话生命周期时间线）：**[`app-ui-mockups.html`](app-ui-mockups.html)**（浏览器直接打开）。

- **设计语言**：Material 3（Flutter 原生体系），深色优先、浅色随系统；零账号、零遥测的定位下界面不出现任何登录/云概念。
- **色彩语义**：绿=已连接（常亮）、琥珀=重连中/临期（呼吸动画）、红=失效/危险；主色翡翠绿只用于可执行动作，不与状态色混用。
- **倒计时芯片**按时余着色（≥6h 中性 / 1–6h 琥珀 / <1h 或续期失败红）。
- **等宽字体**专用于 sessionId / relay URL / job id / 证书指纹——凭证明材料与普通文案视觉分离。
- **导航**：底部三 Tab（机器/控制/设置）；配对流、机器详情、锁屏、会话失效为全屏流。
- **控制台对齐 web 信息面**（屏 E/K/L/M/N/P + **工作区/轨迹，见下方「2026-10-05 实现回填」**）：**模型与思考等级**（屏 K——按 provider 分组列出 dsh 实际配置的模型，目录由 `session/modelCatalog` 下发、App 不写死清单；每模型的思考档位 Off/Low/High/Max 与默认值随目录下发，非推理模型仅 Off；顶栏芯片显示"模型 · 档位"，与 web 选择器互通）、上下文占用环 + system/tools/对话三段分解（同一 contextBreakdown 投影）、统计胶囊（速度/缓存命中/轮次）、审批卡（`approval/request`）、**提问卡**（屏 P——`question` 交互：多问题批量作答/单选多选/自由文本/可跳过，plan-review 特化；与审批并列独立，挂起占 composer 座位）、会话列表（与 web 共用引擎侧会话，两端接力）、**子代理团队**（屏 N——会话头徽标进入；目录 = kind + 运行状态，对齐 SubagentCatalogAction；消息带 lineage 标记，子会话只读，对齐 SubagentReadOnlyComposer；会话列表中子代理缩进挂父会话）。

### 2026-10-05 实现回填（真机 E2E 后）

三处 PRD 与实现已经对不上，按实现为准回填：

1. **主机指标（`events.host`）在这个引擎版本里不存在。**
   `dsh-root` 0.1.7-rc.2 的 `packages/host/` 只有目录选择器、静态托管、
   插件清单和遥测传输，**没有 host 事件或路由**，活跃会话的投影集里也没有
   任何 host key（2026-10-02 对着源码核过，`host_pane.dart` 顶部有同样的
   声明）。屏 D / 屏 F 因此**不展示 CPU / 内存 / 温度**，改用真实存在的
   `pluginInventory/list` + 会话数 + 选中模型。这是诚实的降级，不是漏做。
   §2 表格里 `/api/events.host` 那一栏请视为「目标形态，v1 未落地」。

2. **控制台实际是五个分段：对话 / 任务 / 主机 / 工作区 / 轨迹。**
   mockup §02 只有前三个。**工作区**（会话 cwd 的文件浏览，D-036）与
   **轨迹**（事件记录表 + 时间概览，D-042）是 PRD 之外新增的，二者都
   已在真机验证。它们不在 §7.1 原来那句的屏号清单里。

3. **屏 M 的平铺会话列表已被「工作区注册表」取代（D-047）。**
   入口现在先列这台机器的工作区（`workspace/follow`，毫秒级），选中后
   进入该工作区的会话，点会话再进对话页。原因是工程性的、且写在这里以免
   下一个人去找已经不存在的东西：

   - `session/list` 在真机上退化到 132s 且持续恶化（`docs/internal/engine-handoff-20261004.md`
     有实测时间线与根因定位），而中继上限 180s，列表功能一度完全不可用；
   - 引擎的**工作区注册表一直有** Remote 接口（`workspace/follow` 订阅流），
     dsh web 的分组树用的就是它，**不需要改引擎**；
   - 屏 M 原来的两个 DoD —— **子代理缩进挂父**与**搜索** —— 在 D-047 重写时
     丢过一次，已于同批补回（缩进依赖后台 `session/list` 的
     `parentSessionId`，列表未到时按平铺渲染，不假装有层级）。
   - D-055 补上**归档视图与置顶**（引擎侧 `archiveSession` /
     `unarchiveSession` / `pinSession` / `unpinSession`，均为 unary，不碰
     130s 的 `session/list`）。D-046 只读了 `archivedSessionIds` 且只当减法用
     ——被归档的会话在手机上**隐身且无法找回**，读起来就是「App 把我的会话弄丢了」。
     视图三档沿用引擎的 `ArchivedFilter`（`ui-workspace/src/client/tree.ts:230`）：
     默认隐藏 / 混在原位灰显 / 只看看归档（第三档同时作用于搜索）。
   - **不做「删除归档」**，这是刻意的。引擎 `workspace-controller` 的命令面只有
     `create` / `initializeDefault` / `rename` / `delete` / `insertBefore` /
     `insertSessionBefore` / `archiveSession` / `unarchiveSession` / `pinSession` /
     `unpinSession` / `follow`——**没有 purge、没有 deleteArchived**。其中
     `delete` 删的是**工作区注册**（连同归属），不是会话；`archiveSession` 是
     **标记隐藏**（会话记录仍在磁盘上，只是被 `agent/pre-step` 门禁挡住不跑模型步）。
     dsh web 的「归档视图」也同为显示过滤，没有删除。所以「归档清理」若指真删，
     那是引擎尚未定义的能力，App 单方面去删电脑上的会话数据不属于「补 PRD 缺口」。
   - **归档带停止语义**，故两段式：普通 `archiveSession` 不传 `stopActivity`，
     引擎会走 `workspace/session-activity` waterfall 询问还有没有在跑的东西，
     有则以 `workspace/session-active` 拒绝并回传 `details.activity`；只有用户
     在弹窗里逐族看清并点了「停掉并归档」，才发 `stopActivity: true` 去停掉
     电脑上正在跑的 turn / 子代理 / 后台任务 / 定时任务。手机上点一下就静默
     杀掉电脑上的工作，是这个交互必须拒绝的事。
   - **归档与置顶互斥**：引擎在归档的同一次持久化写入里丢掉该会话的 pin，
     取消归档**不会**恢复（`docs/subsystems/workspace.zh.md:130`）。因此
     `unarchiveSession` 里绝不能「顺手 re-pin」，UI 也不暗示会自动恢复。

   `SessionsPage`（含 D-037 的 504 自愈与 60 行截断）目前**无路由可达**，
   保留是有意的：等引擎侧的 `session/list` 修好、打开 App 自动恢复最近会话
   （D-031）恢复快速之后，需要决定是回滚还是清理。
- **插件边界**（与 web 远程 gating 对齐）：插件管理面（Plugins/Models/Agent-presets 面板）远程被 PRIVILEGED 闸死，App **不做原生管理入口**；插件运行面页面经**浏览器逃生舱**覆盖（屏 D 按钮 + §03 卡）——App 铸 `url-session` 链接交系统浏览器开完整 SPA，文案明示 v3.204 轮换副作用（顶替其他浏览器会话，App 自身 Bearer 不受影响）。v1.5 候选：内嵌 WebView 容器。
- **间距与尺寸 Token**（mockup §01 表）：4px 基数网格（4/8/12/16/20/24），全部控件间距取自 token 表；按钮 48（主）/38（紧凑）、输入栏 56、底栏 64+安全区；**触达热区 ≥44×44（iOS）/ ≥48×48（Android）**，视觉尺寸可以小（状态点 9px），热区用 padding 撑。
- **双语布局健壮性**（mockup §01 规则，zh/en 双语版式实测约束）：按钮允许两行、宽度永远由容器决定（不撑宽不溢出）；芯片/机器名 nowrap + ellipsis；时间/数字/错误码等宽且**语言无关**；L3 横幅与页标题高度自适应两行；Tab 标签永远单行（选短词）；跟随系统动态字体至 **130% 布局无损**，关键读数固定等宽防抖动，超出降级单列不横滚。
- **过期是一等界面**（屏 I/J + mockup §03 时间线）：失效页三因判别——relay 的 401 响应体不区分原因，App 本地判别（exp 已过=24h 窗口过期；exp 未到但 401=被吊销或 30 天上限，结合本地第 N/30 天记录）；失效仅影响单台机器；配对扫码**先验证后入库**（401 即二维码失效页）；中继不可达（网络/TLS）与 401（凭证死）在 UI 上严格区分，证书指纹变更单独提示。
- **异常界面行为**已定稿（mockup §03）：401 三因判别、WS 4001 琥珀横幅静默重连、T-2h 续期芯片态、配对验证失败、危险操作二次确认、不可达与过期的区分。

### 7.2 错误与反馈统一设计（v1 已定稿，mockup §04）

横切全部屏幕的错误体系，三件套：

1. **四层呈现**（按"需要用户做什么"分层，不按技术来源）：L1 全屏页（会话失效/证书变更/存储不可用——红，唯一主行动）；L2 内联卡（审批/任务失败/配对失败——就地处理）；L3 横幅（不可达重试中、4001 重连中、续期失败——琥珀，自动消失）；L4 SnackBar（操作成功、429、响应超限——数秒自消）。
2. **文案三段式**：发生了什么（一句具体标题）→ 为什么（用户视角一行，错误码等宽）→ 能做什么（恰好一个主行动 / "正在自动重试（第 N 次）"）。zh/en 双资源键；**绝不裸抛 JSON/stack/原始错误串**。
3. **错误对象模型**：App 内统一 `ErrorCode` 枚举，UI 只认它。映射：HTTP 401→`auth.expired/.revoked/.max_age`（本地三因判别）；429→`ratelimit.hit`；relay `error` 帧→按 code 直映射（`engine_down`/`payload_too_large`/`concurrency_exceeded`）；TLS/超时/DNS→`network.unreachable`（指纹不匹配特判 `tls.cert_changed`）；本地→`pair.qr_invalid`/`renew.failed`/`storage.error`。未枚举引擎错误 → L4 Toast + 原始消息等宽一行，不静默。全部错误入**本地脱敏日志**（token/psk 不落盘）。

### 7.3 服务端错误契约（relay ↔ App 的语言分工）

**原则：API 出码不出文案，UI 才出文案。** relay 不做通用 i18n——它不知道客户端语言（Accept-Language 可伪造且 App 语言设置在 App 里），一个 401 体也不可能同时伺候浏览器和原生客户端。分工：

| relay 错误面 | 现状 | 契约 |
|---|---|---|
| JSON 错误体（API 向） | `{error: '英文 prose', hint}`，429 已带 `limit`/`windowSeconds` 结构化参数 | **语言中立**：稳定 machine `code` + 参数为主（429 形态是正面先例），prose 仅供日志调试；App 按 code 映射本地化文案 |
| `error` 帧（隧道向） | `code + message`（`engine_down`/`payload_too_large`/`concurrency_exceeded`） | **已是契约形态**，不动；App 直映射 code，message 等宽兜底 |
| HTML 着陆错误卡（浏览器向） | 4 张卡硬编码中文（"二维码无效或已过期"等） | 唯一"服务端直接给人看"的界面 → **en/zh 双语静态表**：默认 en，`Accept-Language: zh` 出中文；4 卡 ×2 份文案，零依赖，relay 本体其余部分不引入 i18n |

**401 缺 code 的 v1/v2 演进**（向后兼容增强，非 v1 必需）：

- v1（零服务端改动）：App 本地三因判别（§4.1——exp 已过=过期；exp 未到=吊销或 30 天，结合本地第 N/30 天），够用。
- v2 提案：401 JSON 体**追加** `code: 'session_expired' | 'session_revoked' | 'session_max_age' | 'session_missing'` 字段（保留原 `error`/`hint` 不动）——relay 的 SessionManager 持有会话记录，能给出权威原因，App/未来 SPA 共同受益。落地后 App 的本地判别降级为兜底路径。

**App 侧配套**：所有请求带 `Accept-Language: zh|en`（与本机 App 语言一致）——服务于 v2 HTML 卡与审计可读性；不传语言时 relay 默认 en。

## 8. 安全设计

| 层 | 措施 |
|----|------|
| 凭证存储 | `flutter_secure_storage`：iOS Keychain（`Accessibility` 设为解锁后可用、`ThisDeviceOnly`，排除 iCloud 备份）；Android Keystore 加密存储。永不入剪贴板/日志/Analytics |
| 传输 | 默认系统 TLS 校验；**TOFU 证书锁定**：首次扫码时记录 relay 证书链 pin，后续校验——自签部署（`gen-selfsigned.sh`）的必备项；可对单机器关闭 |
| 本地 | 生物识别/密码锁（默认开），解锁后才解密使用凭证 |
| 失窃 | 任意机器/设备吊销即失效（服务端执行，与 App 无关）；30 天硬上限兜底；audit 留痕可查 |
| 凭证边界 | App 只有会话凭证，无 PSK；丢失 App 数据 ≠ 暴露隧道 |
| 日志 | App 内一切日志对 token/psk 脱敏（对齐 server 的 redact 惯例） |

明确不做（v1）：越狱/root 检测、动态完整性校验——开源 + 自建分发的场景收益低。

## 9. 对本仓的影响与不变量

- **v1 零改动**：不改 `server/`、`client/`、`plugin/`；不触碰 DRIFT-1（tunnel 单一实现）与 DRIFT-2（`/dsh-remote` 三方契约）。
- **开源共发**：`app/` 与三包同一 GitHub 仓，**Flutter 工程目录，不进 pnpm workspace、不进 npm publish 顺序链**（client → plugin 的硬约束不受影响）；产物即源码（无二进制发布，见 §6）；LICENSE 沿用 MIT；README 英文为主，本文设计案作为中文深度文档随 `docs/` 发布。
- i18n：**仅 zh/en**（2026-09-30 拍板，v1 随包；对齐 plugin 的 locale namespace 惯例）——开源后面向的不只是中文用户；不做更多语言。
- engine API 子集的类型沿用仓库惯例：**hand-copied + 双侧测试钉形状**（参照 protocol.md 的做法），不引 `@deepseek-ai/dsh-client-*`（那是 SPA 平台模块，宿主经 loader 供给，App 里不可用）。

## 10. 里程碑

> 任务级拆解、DoD 与风险登记见 **[`app-implementation-plan.md`](app-implementation-plan.md)**（2026-09-30 制定）。

| 阶段 | 内容 | 出口判据 |
|------|------|----------|
| **M0 原型验证（1–2 天）** | Flutter 空壳 + 扫码（`mobile_scanner`）+ `flutter_secure_storage` + `GET /dsh-remote/session` 真机跑通 | ① 真机过闸成功；② WS `?token=` 桥接真机跑通 + 4001 重连自愈实测；③ 自签证书锁定方案落地（Flutter 路线，见下） |
| M1 MVP | 机器管理 + 状态面板 + 会话管理 + 锁 + TOFU | 一台真机稳定管控一台真实机器 ≥1 周 |
| M2 控制台 | engine API 子集 + WS 事件流 + 前台提醒 | 对话与任务操作全流程 |

（原 M3 推送里程碑随 2026-09-30 拍板撤销——无后台推送，见 §5。）

**已由代码阅读消掉的 M0 疑点**（2026-09-30 核实，证据见 §4/§4.1）：
`url-session` / `tunnel` 远程可达性（可达）；Bearer 是否需要 landing（不需要，且
不应 landing）；v3.204 轮换对 App 的影响（HTTP 存活、WS 4001 重连自愈）。

**M0 实测结论（2026-09-30，门 0 绿灯，31/31 测试 + 0 issue）**：

1. **过闸** ✅——集成测试全链路（真 relay + 假引擎 + 迷你隧道数据面）：Bearer
   `GET /dsh-remote/session` 200、篡改/无凭证/未知会话一律 401、landing 302+cookie。
2. **4001 自愈** ✅——WS `?token=` 桥接双向通；他方着陆触发 `close(4001,
   device_replaced)`；同 Bearer 重连即恢复，且轮换后 HTTP 凭证存活（§4.1 三推论全实证）。
3. **证书锁定** ✅——`WebSocket.connect(url, customClient: pinnedClient)` 让 wss
   握手走 `badCertificateCallback`（含拒绝语义 fail-closed）；备选全局
   `HttpOverrides` 亦通。**全设计最大单点技术风险清零**。
   工程位置：`app/packages/dsh_remote_core`（纯 Dart 核心包；Flutter 壳为 M1 前置，
   见 `app/PROGRESS.md`）。

## 11. 决策记录（已全部收敛，2026-09-30）

1. ~~**技术栈**~~ **已定：Flutter**——一套源码双平台；源码即产物（2026-09-30，§6）。
2. ~~**控制台范围**~~ **已定：范围 B**——agent 对话 + host 状态 + 任务/作业列表；M2 开工前可再收窄（用户未反对推荐，按 B 记）。
3. ~~**推送优先级**~~ **已定：不做后台推送**——纯前台事件提醒（走既有 WS，零新组件）；push gateway 评估后否决、不排期不留桩（§5）。
4. ~~**分发形态**~~ **已定：源码即产物**——不打 IPA/APK、不上架、无账号服务，客户自行构建（§6）。剩余小项：仓库附不附 GitHub Actions 自建工作流作参考。
5. ~~**多语言**~~ **已定：仅 zh/en**（2026-09-30 拍板）——v1 随包，跟随系统 + 手动切换，不做更多语言（§5）。

## 12. 测试、工程化与开源物料（收尾清单）

**测试分层**（对齐 dsh 官方测试规范的分层思路与仓库 hand-copied-types 惯例）：

| 层 | 工具 | 钉什么 | 需要什么 |
|---|---|---|---|
| 单元 | dart test | 凭证组装/三因判别/续期调度/ErrorCode 映射（§7.2 全表）、Bearer 解析（含畸形 query）、签名 URL 铸造（按 protocol.md 的 HMAC 算法） | 无 |
| Widget | flutter_test | 机器卡片三态、倒计时芯片色阶、审批卡/提问卡回调、失效页文案随判别切换 | 无 |
| 契约 | dart test ↔ server 测试形状 | relay `/dsh-remote/*` 响应、error 帧 code、签名 URL 字段——双侧 hand-copy + 测试互钉（仓库惯例） | 无 |
| **Golden** | flutter_test matchesGoldenFile | **zh/en × 100%/130% 字号 × 最长文案对**：按钮不撑宽、芯片不溢出、横幅两行自适应——把 §7.1 布局健壮性变成自动化断言；golden 基线随仓 | 无 |
| **集成（App↔真 relay）** | dart test + 仓内真 relay | **全链路自动化，不需要手机**：Bearer 过闸、`url-session` 续期、WS `?token=` 桥接、4001 重连自愈、401 三因判别、429 退避 | `pnpm build` 出 server 产物 |
| 设备端 UI 流 | integration_test（+可选 patrol） | 四条关键流：粘贴链接配对→机器出现；401→失效页；审批/提问作答回传；双语+130% smoke | 模拟器/真机 |

**集成测试台（核心设计）**：relay 的 `buildServer()` 是库形态——Dart 测试进程 spawn `node server/dist/index.js`（随机端口 + 测试 PSK + `RELAY_PUBLIC_HOST=localhost:<port>`），假引擎用 Node 起 8 行静态 server 返回固定 `/dsh-remote/session` JSON。测试用已知 PSK 在 Dart 侧重现 `buildSignedUrl` 的 HMAC 铸签名 URL，从扫码入口灌进去——于是**凭证生命周期的每个分支（含 30 天上限、吊销、轮换）都能在 CI 里稳定复现**，不依赖真机器和真 dsh。运行前提仅一条：先 `pnpm build`（CI 与本地一致）。

**相机路径的取舍**：扫码自动化成本高（权限弹窗 + 取景），设计上配对已有**等价入口"粘贴链接"**——自动化全走它；相机扫码列入手动验收。patrol 作为可选增强（原生权限弹窗自动处理），v1 不引入。

**手动验收 checklist**：15 屏逐屏清单随 `app/TESTING.md`（与 README 同级开源发布）；里程碑出口判据见 §10（M1 = 一台真机稳定管控一台真实机器 ≥1 周）。

**CI**（对应 §11 遗留的 Actions 小项）：GitHub Actions 给 `app/` 单独 workflow——`flutter analyze` + 自动化五层测试（单元/Widget/契约/Golden/集成）+ `flutter build apk` 产物自检；集成层依赖 `pnpm build`（workflow 内先 build server）。设备端 integration_test 用 Linux Android emulator 跑四条关键流。fork 即用，与"源码即产物"一致。

**本地数据清单**（App 在手机上存什么、何时清除）：

| 数据 | 位置 | 清除时机 |
|---|---|---|
| 机器元数据（名称、relay URL、TOFU 指纹 pin、首次配对时间） | App 私有存储 | 删除机器时 |
| 会话凭证（Bearer） | Keychain/Keystore（§8） | 删除机器 / 失效页"删除机器" / 吊销后重配对 |
| 脱敏日志 | App 私有存储，容量上限滚动覆盖 | 随卸载；不随备份出设备 |
| 设置（语言/锁/提醒开关） | App 私有存储 | 用户手动 |

**版本与兼容**：隧道协议按帧 `v: 1` 钉死，App 不假设未协商的帧；对 relay 新能力一律**可选探测 + 降级**（§7.3 的 401 `code` 即首个实例——旧 relay 无字段则回本地判别）。App 版本随仓库 tag，"关于"页同时显示 App 版本与协议版本；无 OTA、无自更新（源码即产物，用户重构建即更新）。

**无障碍**：语义标签（状态灯带文字语义而非纯色点）、正文对比度 ≥4.5:1（深浅两主题 golden 校验）、动效可随系统减弱。

**开源物料 checklist**（M2 收尾、随仓库 GitHub 发布）：

- `app/README.md`（英文为主）：构建指引（Flutter SDK 版本、`flutter build apk` / 自备证书 iOS）、能力边界（无推送/无遥测/PRIVILEGED 不可用）
- 截图/录屏（mockup 屏级，脱敏示例数据）进 README
- CHANGELOG 随仓库统一；`docs/app-design.md` 与 `docs/app-ui-mockups.html` 作为设计文档随仓发布
- 可选：GitHub Actions 自建工作流（§11 遗留小项，fork 即用）

**设计已收敛，下一步是 M0**（§10）：Flutter 空壳 + 扫码 + 安全存储 + 真机过闸，
三件实测事：端到端 Bearer 过闸、WS 4001 重连自愈、`badCertificateCallback` 能否
覆盖 `WebSocket.connect`。
