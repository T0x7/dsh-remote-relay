# dsh-remote App 开发进度与问题总结

> 面向接手者与审阅者。一句话现状：**M1 全程真机验证通过；M2 控制台功能全部完成，
> 自动化全绿；2026-10-03 上午真机 E2E 打通了「配对 → 建会话 → 发 prompt → 引擎
> 真实回合 → 事件流 → 气泡渲染」全链路，并抓到 4 个真产品 Bug（TOFU pin 断链 / RPC 无超时 / 断线不重订阅 /
> 4001 自愈死代码，均已修；另修配对弹窗被输入法遮挡）；剩余：屏 P 审批往返、两端接力、隧道慢调用根因（需拍板）。**
>
> 配套文档：`app/PROGRESS.md`（逐条执行日志 + 决策 D-001~D-029）、
> `docs/app-implementation-plan.md`（任务与阶段门）、`docs/engine-contract-m2.md`
> （引擎线契约逐字段抄录）、`app/TESTING.md`（测试矩阵）。

---

## 1. 当前状态一览

| 项 | 数值 / 状态 |
|---|---|
| 核心包 `dsh_remote_core` | **222/222 测试绿**，`dart analyze` 0 issue（含 9 条**直连真引擎**的契约测试） |
| Flutter 壳 | **497/497 测试绿**，`flutter analyze` 0 error / 0 warning（含 3 张 Golden） |
| i18n | zh / en **218 键**，键集机器校验一致 |
| 设备 | Xiaomi Civi（2109119BC / Android 13），调试 APK 213 MB 已安装 |
| 真引擎 | 本机 `127.0.0.1:3080` 常驻，装有 relay 插件，隧道 `connected` → `https://<relay-host>` |
| 真机 E2E | 配对（fresh + 跨重启）/ 会话列表 / 建会话 / prompt 往返 / 事件流 / 屏 E·F·K·M·N·L 渲染 **全通过** |
| 契约抄录 | `docs/engine-contract-m2.md` 856 行，12 项逐字段 + `文件:行号` |
| 决策记录 | D-001 ~ D-024（见 `app/PROGRESS.md`） |

### 冷启动恢复上次会话（D-109，2026-10-13）

控制台冷启动后**优先恢复「你上次看的那个会话」**（跨进程持久化，按机器隔离），
不存在或已被引擎删除才回落到 D-031 的「引擎侧最近更新」。同进程内前后台切换一直
是认得的（`_resumeFromBackground` 拿内存里的 `_sessionId` 重开），此前缺的只是
「杀掉再开」这一条路径。顺带补上 D-062 标题缓存漏掉的 `load()` 接线——它此前只写
不读。详见 `docs/app-field-notes.md` §6.16。

### 诊断 / 崩溃 / 操作日志（D-107，2026-10-13）

三个独立通道、各自滚动配额（`docs/app-design.md` §7.2 的兑现）：

| 通道 | 文件 | 配额 | release | 内容 |
|---|---|---|---|---|
| 诊断 | `app.log` | 256KB | debug 行不落 | 埋点日志 + 帧聚合计数 |
| 崩溃 | `crash.log` | 64KB | **落** | 框架异常 / 未捕获异常 / async 逃逸（三个全局入口） |
| 操作 | `audit.log` | 128KB | **落** | 11 类关键动作与状态迁移，只记标识符与计数 |

诊断页按通道切换。**为什么拆**：原来逐帧探针（130–250 行/秒）能在一次连续输出
30–60 秒内把 512KB 缓冲冲干净，真机上 `first-frame deadline hit` 这类现场证据
被自己的噪声挤掉；且「全部错误入日志」这条设计承诺此前**没有兑现**——崩溃只进
logcat 红屏、从不落盘。真机复验（小米 2109119BC）当场抓到两个由此引入的回归，
均已修，见 `docs/app-field-notes.md` §6.13~6.14。

### 已交付的屏

| 阶段 | 屏 | 状态 |
|---|---|---|
| M1 | A 机器列表 · B 扫码 · C 确认 · D 详情 · G 设置 · H 锁 · I 失效 · J 配对失败 | ✅ **真机 E2E 通过**（2026-10-02，VPS relay + LE 证书 + 真引擎配对） |
| M2 | **E 对话**（气泡流 / 审批卡 / 计划审批 / composer / 上下文环） | ✅ 完成 |
| M2 | **M 会话列表**（子代理缩进挂父、孤儿提升、两端接力脚注） | ✅ 完成 |
| M2 | **P 提问**（多问题批量 / 单选 / 多选 / 自由文本 / 跳过 / 放弃） | ✅ 完成 |
| M2 | **K 模型与档位**（顶栏芯片 + provider 分组 + 档位 chips + 跟随默认） | ✅ 完成 |
| M2 | **L 上下文分解**（占用环 + 三段构成 + 用量统计） | ✅ 完成 |
| M2 | **N 子代理团队**（目录 + 模式 + 只读输出入口） | ✅ 完成 |
| M2 | **F 任务 / 主机**（五态任务卡 + kill + 插件清单） | ✅ 完成 |

### 任务表

| 任务 | 状态 |
|---|---|
| T2.1a 传输底座（单播 JSON-RPC + `/api/remote.mux` 多路复用） | ✅ |
| T2.1b 契约抄录（12 项逐字段） | ✅ |
| T2.1c 域模型（会话 / 事件帧 / 投影 / 模型目录 / 审批 / 提问） | ✅ |
| T2.1d 错误映射（8 个控制台域 ErrorCode + 全表 + 双语文案） | ✅ |
| T2.1e 集成床（假引擎实现 M2 最小集 + 24 条端到端） | ✅ |
| T2.2 / T2.3 会话域 + 对话 UI | ✅ |
| T2.4 提问 / 计划审批 | ✅ |
| T2.5 / T2.6 模型档位 + 上下文 | ✅ |
| T2.7 / T2.8 团队页 + 任务/主机页 | ✅ |
| **T2.9 开源物料**（README / CHANGELOG / CI / 截图终审） | ⬜ 未做 |
| **门 2 真机 E2E**（对话 + 审批 + 提问 + 模型切换 + 上下文环 + 两端接力） | ⛔ 卡住（见 §3.1） |

---

## 2. 架构落点（为什么是现在这个形状）

```
app/
├─ packages/dsh_remote_core/        纯 Dart，无 Flutter 依赖
│   └─ lib/
│       ├─ credentials/            签名 URL、Bearer 装配、会话时钟（24h/30 天）
│       ├─ net/                    pinned HTTP（TOFU）、RelayClient、EventsSocket
│       └─ api/                    引擎控制面
│           ├─ engine_rpc.dart       单播：POST /api/<ns>/<method>，JSON-RPC 信封
│           ├─ engine_mux.dart       多路复用：/api/remote.mux 逻辑流
│           ├─ engine_gateway.dart   UI 依赖的接口（测试注入假网关）
│           ├─ engine_models.dart    域模型（会话 / 帧 / 投影 / 目录 / 审批 / 提问 / 任务）
│           ├─ engine.dart           门面：把模型绑到两种传输上
│           └─ error_code.dart       全局错误模型 + 呈现层 + 重试策略
├─ lib/
│   ├─ main.dart / app_root.dart    机器 · 控制 · 设置 三 Tab
│   ├─ console/                     控制台：console_page / chat / sessions / questions / models / context / team / jobs / host
│   ├─ data/                        机器条目 + 安全存储 + 设置
│   ├─ services/session_scheduler   T-2h 续期调度
│   └─ l10n/                        zh / en（217 键）
└─ test/
    ├─ api/                         契约测试（信封、帧键集、域语义、错误映射）
    ├─ integration/                 集成床（真 relay + 假引擎）+ **真引擎契约测试**
    └─ *.dart                       widget / Golden / 端到端回调断言
```

**控制面与配对面彻底分离**：`/dsh-remote/*`（本仓插件）+ `/api/*`（引擎）是两条
不同的路，控制台只走后一条。

---

## 3. 遇到的问题（按严重度排序）

### 3.1 ✅ 已解决：真机 E2E 配对粘贴流卡点（2026-10-03 上午）

**当时的卡点**：M1 的坐标标定（粘贴流主按钮 y≈2300）失效——250 字符 URL 撑高
输入框使按钮下移，收键盘的按键又会把整个 sheet 关掉，`解析链接` 从未执行。

**真因（三个叠加，全是测试驱动层，产品无缺陷）**：

1. **MIUI 搜狗输入法盖住了 sheet**（浅色主题、近 1000px 高、带工具栏）——按颜色
   定位按钮时命中的是搜狗的**绿色回车键**（box=(696,1938)-(1035,2091) 就是它）。
   → 切 **ADBKeyBoard**（设备已装 `com.android.adbkeyboard`）用
   `ADB_INPUT_TEXT` 广播注入文本，键盘从此不参与。
2. **`adb shell` 吃掉了 URL 里的 `&`**：`am broadcast --es msg <url>` 的参数被拼到
   手机 `/bin/sh` 执行，`&` 变成命令分隔符，字段只收到 `?sessionId=…` 这一段 →
   App 本地解析必然失败（红字「链接格式不对：t/exp must be epoch-ms digits」）。
   → 参数带**设备端单引号** `'…'`。教训同 D-022：断言必须打在真正的对手方。
3. **App 的 `FilledButton` 是浅薄荷 `#8ED5B2`**，而旧脚本按 M1 标定的翡翠
   `#34d399` 找——sheet 内按钮永远匹配不到。

**结果**：全新安装 → 粘贴 → 解析 → 确认 → `onlineWs=1`（mux WS 经 relay 桥接
成功）→ 控制台全屏可用。定版驱动 = `app/.toolchain/e2e_pair_v6.py`。

### 3.1b ⛔ 门 2 真机 E2E 抓到的真产品 Bug：TOFU pin 从未接线（D-025）

**这是 M2 迄今最重要的发现，自动化测试一条没抓到。**

`MachineEntry.certPin` 字段**有读无写**（4 处读、0 处写）：

- 配对时 `PinnedHttpClient(learnOnFirstConnect: true)` 学到了证书指纹，但存进
  一次性 `MemoryPinStore` 后**立即丢弃**（`pairing_flow.dart` 的 `onLearn: (_, _) {}`）；
- 控制台 `console_page.dart:121` 原来是 `PinnedHttpClient.fromStore(MemoryPinStore())`
  —— **空表 + `learnOnFirstConnect: false`（fromStore 默认）** →
  `pinned_http.dart:65-67` 对「无 pin 且不许学」一律 **fail closed 拒绝** →
  **控制台的每一条 HTTPS/WSS 都在 TLS 层被自己的闸掐死**（真机症状：顶栏黄色
  告警、会话列表/团队/模型全空、引擎侧看不到设备）。机器详情页与续期调度器同样
  受害（`session_scheduler.dart:86`）。

**M1 门 1 之所以绿**：配对流自己学 pin（所以配对能过），而详情页/续期/控制台的
**活路径从未在真机上跑过**——门 1 验的是「能配对、页面能渲染」。

**修法**（只动 app，v1 零改动承诺不受影响）：配对 `_verify` 的 `onLearn` 捕获
指纹 → `buildPairedEntry(params, pin)` 写进 `MachineEntry.certPin`（随机器进
SecureMachinesRepository，零新增存储）→ 控制台 `pinStoreFor(entry)` 播种（与
详情页/续期同形状）。严格模式全保留：无 pin 仍 fail closed（重新配对 = 刻意的
用户动作），证书变更仍拒绝（`tls.cert_changed`）。壳测试 +5。

**教训**：「字段存在」不等于「字段被写」；安全设计里 fail-closed 的默认值 +
未接线的持久化 = 一整片功能静默死亡，而单元测试（都注入假网关）永远绿。

### 3.1c ✅ 已修：配对弹窗被输入法遮挡，主按钮消失（D-029，维护者 报障）

**现象**：点「添加机器」后 IME 自动弹出（URL 字段 `autofocus: true`），
MIUI 搜狗键盘占 960px，**「解析链接」按钮被顶出屏幕底部**——真机取证：键盘
打开时全图**找不到任何薄荷色像素**，用户根本没法提交。

**根因**：`showModalBottomSheet` 里用了 `MediaQuery.of(context)`，而 `context`
是**弹窗外部页面**的。该依赖注册在外层 State element 上，但 modal route 是
独立子树，其内容不会因为外层重建而刷新——**padding 在 sheet 首次构建时就冻结
了**，键盘之后弹多高都不跟随。叠加 `autofocus` 时机不定（有设备开 sheet 时
键盘已起，有的还没起），所以这个 bug 时隐时现。

**修法**：改用 builder 自己的 `sheetContext`（依赖落在 route 子树内，实时
更新）+ `AnimatedPadding`（位移平滑）+ `SingleChildScrollView`（矮屏高键盘
时仍可滚动够到）。**回归测试验证过它真会红**：回退修复后测试报
`Expected: a value less than <1440> / Actual: <2362.0>`，与真机现象一致。

**教训**：与 D-022 同源——**「测试全绿」必须先证明测试能抓住这个 bug**。

> 立场：这是**测试驱动问题**，不是产品缺陷。M2 的数据链路已由 core 的
> 9 条真引擎契约测试 + 24 条集成测试证明；真机这轮验的是触屏与真实网络。

### 3.2 🔴 契约抄录错了整批（288 条绿灯一条没抓到）

**这是本项目最贵的一个教训。** 我把 wire `args` 写成了扁平业务字段
（`{sessionId}`），而真实引擎要求**按端点声明的参数名嵌套**
（`{request: {sessionId}}`；`session/list` 保留 `_request` 下划线；无参端点收裸 `{}`）。
**除 `modelCatalog` 外全部调用形状都是错的。**

- 为什么 288 条测试全绿？因为**假引擎是我写的**，两侧同源于同一次误读——
  橡皮章连形状一起盖住了错误。
- 怎么发现的：用户问「有没有真机测试」，我回头打真引擎（此前只用点号路径探过，
  全 404 就断定引擎不可用，**从未用正确斜杠路径试过**）。
- 修复：13 处调用点重包 + 假引擎改用同一套 `unwrapArgs`（并镜像真引擎的
  **校验顺序**：先 `arguments-invalid` 后 `signature-invalid`）+ 新增
  **9 条常驻真引擎契约测试**（无引擎则 SKIP 并打印原因，绝不静默通过）。

**固化教训**：`grep 源码 → 手抄 → 双侧断言` 这条链**只能证明 Dart 与我的抄读一致**，
证明不了抄读对。**凡有真引擎可打，就必须有一条独立于我写的假实现的存在。**

### 3.3 🟠 真数据三次改写设计

| 位置 | 设计案设想 | 真引擎实测 | 处置 |
|---|---|---|---|
| 路由分隔符 | `session.list` | `session/list`（`endpointOf()` 返回斜杠） | 全面改正 + 测试钉死结构不变式 |
| 子代理目录 | 每子代理有「运行中」点 | 条目只有 `mode/label/id/createdAt`，**无 `activity`** | 改画 `mode` 派生点，不编造实时状态 |
| 子代理 label | 短名字 | 中位 27 字符、最长 64 的**长描述** | 整段换行，不单行截断 |
| 主机指标 | `/api/events.host` | **本版本不存在**（`packages/host/` 无该面，投影集 19 个 key 也无） | 改用真有的 `pluginInventory/list`，页脚**明说指标不可用** |
| 快照体积 | 未考虑 | 真实 17 轮会话 = **2.2 MB / 299 事件**（隧道请求体上限 4 MiB） | follow 默认 `maxMessages=50`，历史按需分页 |

### 3.4 🟠 集成床逼出三个单元测试永远抓不到的 bug

1. **路径错**：`POST /api` 全 404——relay 的 `/api/*` 通配不匹配无尾斜杠路径；
2. **scheme 未映射**：`http://` origin 直接喂 `WebSocket.connect` 静默死循环
   （生产是 `https://` → 必转 `wss://`）；
3. **集成台丢 body**：`http.req` 的 `body` 未转发（M1 只发 GET 所以一直没暴露）。

固化教训：**假实现必须和真实现一样严**，否则集成床测的是假象。

### 3.5 🟡 Flutter 测试的三类经典陷阱（各踩过多次）

| 陷阱 | 症状 | 处置 |
|---|---|---|
| 写死的绝对时间戳夹具 | 第二天起必红，与代码无关 | 夹具改相对时间；Golden 冻结时钟 |
| controller 建在 `setUp`（真 async 区） | 屏幕静默空白（回调落在 fake-async 不会推进的时钟上） | 一切在 `testWidgets` 体内创建 |
| 广播流不重放 | 先 `.first` 吃首帧再订阅 → 后续帧静默丢失 | 单次订阅收集全部帧 |

### 3.6 🟡 其它

- **ARB 位置参数**：`{model} · {effort}` 生成的是 `(effort, model)`——按出现顺序；
- **Eager socket**：`IndexedStack` 预先构建所有子页 → 用户没打开控制台也在拨号，
  白耗电耗流量。改为**首次切 Tab 才挂载**（M1 的四个测试当场变红暴露了它）；
- **投影竞态**：`open()` 里额外调 `session/projections` 与实时 snapshot 竞态，
  上下文环在两个 cut 间跳。改为**只认 snapshot 基线**（带 `asOfSeq`），
  缺席就显示「未知」而不是 0%；
- **协议「没有的东西」要写明**：跳过（skip）无 flag、`followDefault` 无字段、
  `readOnly` 无字段——三处都靠推导 + 注释 + 测试固化，不在 UI 临场编造。

---

## 4. 已知限制（如实声明）

- **门 2 未关闭，剩三项**（2026-10-03 真机 E2E 后）：
  1. **屏 P 审批 / 提问的真机往返**——协议形状已由集成床 + 假引擎双向互钉；
     Mac 侧探针证实引擎确实会产生审批态（bash 写文件探针真被执行落盘），
     但**这台引擎当前没有配置 ask/审批类工具**（`bash` 直接执行、无
     waterfall），所以手机侧没能等到一张真审批卡。需要一台配了审批门或
     会主动 `ask` 的引擎才能验完这条链。
  2. **两端接力**——App 恢复引擎侧会话（与 web 同一份）已实现并测，但没在
     真机上与浏览器端同时开着验证过互斥（`4001` / writer-held 路径）。
  3. **屏 E 逐 token 渲染**（Open question）——帧已解、`revision` 硬约束已落
     代码并在真机看到 `FollowAssistantStream` 帧持续到达，但 UI 仍是整条
     消息落定后渲染。
- **隧道一元 RPC 延迟（未定位根因）**：经 relay 的一元 RPC 在 mux WS 桥接时
  从直连的 ~0.5s 劣化到 20~30s；引擎直连复现不出，relay 侧也不是每发必坏。
  疑似 relay↔引擎隧道的帧/请求调度。**修它要动 `server/` 或引擎侧——超出
  v1 零改动承诺范围，待拍板**。App 侧已用 D-026 的 35s 客户端超时兜底，
  最坏情况是显示可重试的错误卡而不是无限转圈。
- **上传 / 附件未做**（`PromptContentPart` 的 image/file 变体已建模，无 UI）。
- **无后台推送**（设计如此：纯前台提醒）。
- **重连横幅未做 widget 测试**：D-027 的断线→复活契约由 3 条 core 测试用假
  carrier 钉住（这是行为真身），横幅本身是薄渲染层，只有真机像素取证。

---

## 5. 下一步（建议顺序）

1. **屏 P 真机往返**：需要一台配了审批门 / 会主动 `ask` 的引擎（或在现有引擎
   上开一个），维护者 定用哪种真实环境。
2. **两端接力**：浏览器 + 手机同开一台引擎，验互斥。
3. **T2.9 开源物料**：`app/README.md`（构建指引 + 能力边界）、`CHANGELOG.md`、
   CI workflow、截图终审；随后换公网 `repository.url`（4 处，见 `docs/internal/HANDOFF.md`）
4. **拍板隧道 RPC 延迟**：是否允许为定位根因临时改 `server/`（v1 零改动承诺
   的例外）。
5. **补 `assistant-stream` 逐 token 渲染**（体验项，非阻塞）

---

## 6. 给接手者的三句话

1. **先跑质量门**：`dart analyze` + `dart test`（core）+ `flutter analyze` +
   `flutter test`，四个都必须绿；有真引擎时那 9 条真引擎测试会自动跑。
2. **改任何 wire 形状前先打真引擎**：`127.0.0.1:3080` 上有常驻实例，
   `.toolchain/real_*_probe.mjs` 里有现成的只读探针（会话列表、事件流、
   子代理目录、任务、插件清单）。**别信手抄，信探针。**
3. **别在测试夹具里写死绝对时间**；**别在 UI 里编造协议没有的字段**——
   两者都有测试在盯着，改了会红。
