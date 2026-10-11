# App 端实测踩坑与修复（D-067 ~ D-101）

> 这份文档记录 **Flutter App 在真机上暴露的问题、根因与修复**。每条都是先
> 实锤根因、再写红测试、最后真机复验的闭环——多数坑的共同点是「看起来是
> App 的问题，实际是 wire 契约错」或「静默失败，用户以为成功了」。
>
> 写给两类读者：① 接手 App 的人（避免重踩）；② 用本项目做二次开发的人
> （引擎契约的实证勘误，比任何文档都准）。

## 0. 五条最重要的经验

1. **别手抄 wire 契约，去打真实响应。** 本项目 80% 的 App bug 源于手抄的
   字段名/包装层写错（见 §1、§2、§3）。判据：任何「引擎提供/不提供某
   字段」的断言，都必须先 curl 一条真实响应逐字段核对。
2. **静默失败比崩溃可怕。** 乐观 UI（先改界面、后发请求）会把失败伪装成
   成功——用户以为批了权限，引擎侧还挂着（§2）。原则：**等引擎确认再改 UI**。
3. **集成测试绿 ≠ 真引擎认。** 如果 CI 用的中间件版本落后于生产，wire 契约
   类断言会假绿（§1）。
4. **fixture 的形状必须来自第一方契约**，不是「代码现在这么读」。§6.1 里两条测试
   因为 fixture 与真实契约不符而长期假绿——护栏跟着代码一起错，等于没有护栏。
5. **测试没覆盖到的分支 = 不存在的分支。** 扫错误只认一种异常类型，那个分支就
   永远没测过（§6.2）。

---

## 1. 消息「被吞」：requestId 跨进程撞车（D-077）

**现象**：App 重启后发送消息，按钮转圈、气泡永不出现；引擎日志无任何记录。

**根因**：`session/prompt` 用 client 铸的 `requestId` 做**幂等去重**。旧实现
`'app-req-${_requestSeq++}'` 的计数器随进程从 0 开始——App 每次重启都重放
`app-req-0..N`，与引擎全天已处理的 id 撞车，命中去重：接口返回 ok=true，
消息永不落 journal。

**修复**：id 掺微秒时间戳 `'app-req-<micros>-<seq>'`，跨进程天然不撞，进程内
仍单调（重试语义不变）。

**复现方式**：同 requestId curl 两连发 → 第 1 条落库、第 2 条 accepted 但消失。

## 2. 审批点「允许」但引擎没同意（D-078）——两层根因

### 2.1 信封层：应答多包了一层 `request`（根本原因）

**现象**：手机上点「允许」，卡片消失，dsh web 上审批仍挂起。

**根因**：`$events/result` 的 args 是**裸对象** `{clientId, eventId, outcome}`；
我们按手抄契约多包了一层 `request`。网关在描述符分发**之前**预解析该端点
（`api/gateway/src/index.ts`），包装层直接被判 `invalid Remote event result`。
**手机审批从未成功过一次。**

**修复**：去掉包装层。对照官方客户端源码而非文档——`remote-events.ts:218`
发的是 `{ args: result }`。

### 2.2 代际层：`$events` 重开换代，旧 clientId 失效

即使信封对了，还有第二层：网关只接受「接过该投递的那一代连接」的结果
（`deliveries.has(client)` 不符即静默丢弃）。App 的 `$events` 定期重开换代，
换代窗口内点「允许」会带着已失效的 clientId 出门。

**修复**：应答前等当前代 `ready`；失败自动重订并**恰好重试一次**（宿主会把
挂起的水瀑重放给新一代）；**只有引擎接受后才删卡**，失败保留卡片可再点。

## 3. 进会话时挂起审批不出现（D-079）

**现象**：审批早在 dsh web 触发，手机进会话却要等一分钟才出卡片。

**根因**：`open()` 会清空气泡列表重开 journal，却**从不重订 `$events`**。宿主
只在**新订阅**时重放仍挂起的水瀑——此前已抵达的审批随气泡一起被清掉且不会
回来，只能等下一次 60s 定时重订。

**修复**：`open()` 清空气泡后立刻重订 `$events`，宿主即时重放。真机复验：
ready 后 33ms 收到重放。

## 4. 插件清单/开关（D-081）

**App 起初只有 `pluginInventory/list` 的只读清单**，与 dsh web 的插件管理器
（可启停/装卸）差距明显。补齐时踩了三层坑：

| 坑 | 实锤方式 |
|---|---|
| 写路由信封必须裸 `{id,enabled}` / `{name,enabled}` | 传空 args 的零副作用探针读 descriptor 报错 |
| `meta.title` 可能是**本地化 Map** `{en,zh}` 不是字符串（193 行中 4 行如此） | 真机点开关白屏 → logcat Dart 异常 → curl 统计字段类型 |
| 199 行 loader entry 平铺给用户是**信息架构错误** | 改包（bundle）视角：`listBundles` 只有 16 行，每包一行开关，展开才见内部模块 |

开关语义：**引擎确认后才翻转 UI**；`readOnlyReason` 的核心模块不显示开关；
`restart-required` 时保持原状并标注。

## 5. 真机 E2E 底座（D-080）与其代价

`integration_test/device_smoke_test.dart` 是本仓唯一的真机自动化。**警告：**
`flutter test integration_test` 的安装流程含**卸载重装**，会清空目标设备的
App 数据（配对、语言偏好全没，不可恢复）。**只许跑在专用测试机/模拟器**，
或在机主明确同意时跑。

## 6. 静默不显示的五个坑（D-089 ~ D-093）

一次覆盖全部界面与子表面的真机走查挖出的问题。共同点：**都不崩、不报错、测试全
绿**，只是界面上「少了一样东西」。完整报告见
[`internal/ui-sweep-and-fixes-20261011.md`](internal/ui-sweep-and-fixes-20261011.md)。

### 6.1 工具调用不显示工具名（D-093）

**现象**：对话页每条工具调用只有「工具调用 + 参数摘要」，工具名消失；**轨迹页却照
常显示**工具名——同一份数据，两屏不一致。

**根因**：`tool/result` 的 callId 在 `message.toolCallId`（引擎契约），代码从顶层
`dataObject['callId']` 读 → 永远 null → 工具名的前向配对失效 → 落到默认 `'tool'` →
UI 又把 `'tool'` 过滤掉。**修**：改读 `message.toolCallId`。

> 这条同时暴露了一个更隐蔽的问题：仓库里两条相关测试的 fixture 也把 callId 写在
> 顶层，于是**测试把 bug 一起编码进去了**，长期是绿的。**fixture 的形状必须来自
> 第一方契约，不能是「代码现在这么读」。**

### 6.2 任务页把流错误吞成永久转圈（D-089）

**现象**：任务页无限转圈。引擎直连探针实证 `job/list` 开流即回 `rows: []`——引擎
正常，是 App 把帧/错误丢了。

**根因**：错误过滤只认 `EngineRemoteError`，而唯一会让 `job/list` 停摆的
`MuxStreamError` 被静默丢弃；且无超时。**修**：任何流错误都落到错误卡片 + 12s 首
帧闸。

> **扫错误只认一种异常类型 = 该分支永远没测过**。这正是测试替身缺 errors 通道造
> 成的盲区。

### 6.3 回底钮落进空白区（D-090）

**现象**：列表含超视口高的展开气泡时，点「回到底部」一次落进**空白区**、一次停在
半屏处。

**根因**：`animateTo(maxScrollExtent)` 单次跳转，但懒加载 ListView 的
`maxScrollExtent` 是**估算值**。**修**：动画后重查真实落点，未到底则**有界补跳**。

### 6.4 轨迹窗口：横幅数字颠倒 + 保留方向相反（D-090）

**现象**：横幅「保留最近 11 条（丢弃 80 条）」，且列表顶部是会话**最早**的记录。

**根因**：① 实参按 `(kept, dropped)` 传给 `(dropped, kept)` 的生成签名，两个 int
安静交换；② 预算从最老轮次消耗，实际丢掉**最新**一段。**修**：按签名传参 + 先摊平
再保留最新 N 条。

### 6.5 重连后对话静默停更（D-092）

**现象**：mux 重连后 `session/follow` 重开收到 snapshot 即被「second snapshot」
守卫误杀，`logcat` 打 `gateway/protocol`，界面却看着正常。**修**：重开路径允许
re-baseline。

### 6.6 「智能体团队」这条链路的五个洞（D-094 ~ D-098）

2026-10-11 小米真机。目标会话 `job-weekly-20261011-030055`（4 个子代理）。
**team 页本身展示全对**：标题、`4 个子代理`、标签完整换行不截断（引擎实测
label 最长 50 字符）、绿点、`可继续对话`、无只读标记——但**点进去是空白**，
而且**顶栏徽标不亮**。逐条如下。

#### D-094 子代理会话打不开（`parentSessionId` 被填成 child 自己）

**现象**：点任一子代理 → 内容区全空，只有一个几乎看不见的转圈残影；顶部
上下文胶囊还冻在**父会话**的数值（17% / 282.1 tok/s / 缓存 94%）。

**根因**：`ChatController.open` 构造 `SubagentSessionAddress` 时，parent 和
child 两半都填了同一个 `sessionId`：

```dart
SubagentSessionAddress(parentSessionId: sessionId, childSessionId: sessionId, …)
```

而 team 页传进来的 `sessionId` 就是 **child 自己的 id**（`console_page` 只把
`child.id` 递下去，`TeamPage.parentSessionId` 从未参与）。引擎回的帧是：

```
{"type":"error","code":"subagent/unauthorized",
 "message":"subagent does not belong to the supplied parent"}
```

**根子**：子代理在 wire 上**成对寻址**，光有 child id 不可寻址——这正是协议
单独定义 `SubagentSessionAddress` 的原因。**修**：`open()` 增加显式
`parentSessionId` 形参，`console_page` 把当前父会话 id 传下去。

#### D-095 对话流错误被吞（D-089 的另一半）

`chat_controller` 的 journal 错误订阅写的是 `if (e is EngineRemoteError)`，
而**流**的错误一律是 `MuxStreamError`——于是 `unauthorized` 只进了
`AppLog.w`，界面保持空白。**同一个洞在 jobs_pane 上已经修过一次（D-089）**，
对话侧漏了。**修**：两种异常都走 `toAppError()`，未知类型才置 null。

> 教训可复用：**扫错误只认一种异常类型 = 该分支永远没测过**。修一处要按类型
> 把全仓的流消费端扫一遍。

#### D-096 子代理徽标永远不亮

徽标数字来自 `_chat?.projections?.values.subagentCatalog?.length`，但
`ConsolePage` **不订阅** `ChatController`（只有 `ChatPane` 订阅，那是给气泡
列表用的）。目录随 follow 快照晚到，而 AppBar 只在 `ConsolePage.setState` 时
重建——所以 count 永远停在快照前的 0。真机表现：**徽标无数字，点进去却有 4 个
子代理**。「这个会话有子代理」的唯一入口因此是哑的。**修**：徽标包一层
`ListenableBuilder(listenable: chat)`。

#### D-097 页脚把可写说成只读

页脚原文「点按子代理查看**只读输出**」，但 `continuable` 子代理会拿到输入框
——协议上 `mode` 才是只读判据，`one-shot` 才是终态。而且引擎 504 个会话、
170 条 catalog 条目**实测全是 `continuable`，没有一条 `one-shot`**，
所以真机上 100% 会看到矛盾文案。**修**：文案改成「点按子代理打开它的会话；
能否继续对话看卡片上的模式」。

> 附带结论：`one-shot` / 只读分支**无法用真机数据验证**，只由
> `team_page_test.dart` 的 widget 测试守着。别把它当成「验过了」。

#### D-098 工作区注册表失败屏是死胡同

`WorkspacePickerPage._body` 在 `registry.error != null` 时直接
`return _Centered(...)` —— **没有 Scaffold**，于是这一屏没有 AppBar、没有
标题、没有返回键、没有重试按钮。流此时已经结束，重进页面也只会拿到同一个
死掉的 controller。**修**：失败屏与加载屏都补 Scaffold + 同名标题，失败屏
再加一个重试；`WorkspaceRegistryController.retry()` 真正**重开订阅**
（不是只清错误）。

### 6.7 完整走查追加：后台恢复三连（D-099 ~ D-101）

同日 15:0x，完整走查第二轮。**进后台 55s 再回前台**（复现 15:01 的现场）
暴露了恢复路径上的三个洞，全在小米真机实锤：

#### D-099 恢复路径把子代理地址的 parent 又丢了

`_resumeFromBackground` 调 `open(sessionId, subagentLabel:, mode:)` ——
**没传 parentSessionId**，`parent ?? sessionId` 兜底成 child 自己。修复前的
现场：回前台 → 45s 无首帧 → 看门狗 → 空白。**修**：`ChatController` 记住
`_parentSessionId`，resume 时带回。

**复验**（15:15）：修复前 resume 后 45s 零帧；修复后 **0.9s FollowSnapshot
落地**，子会话内容原样恢复。

#### D-100 首帧看门狗超时同样没有 UI 出口（D-095 第三处）

看门狗只赋 `_error`；`_error` 无消费者——用户对着空白页，logcat 里却明明打了
`first-frame deadline hit`。**修**：超时也落 `ErrorNotice` 气泡（错误卡自带
重试入口）。测试侧顺带钉了一条：**推时钟触发定时器（`pump(46s)`），别用
`onFirstFrameDeadlinePassedForTest`**——它不清真实 Timer，testWidgets 会报
"A Timer is still pending"。

#### D-101 停留在轨迹页时，账本重建不上屏

`TrajectoryPane` 是纯被动的（渲染构建时刻的 projection），ConsolePage 又不听
ChatController（与 D-096 同族）。resume 重建 ledger 后，**恰好停在轨迹 tab 的
用户**看到空态「这个会话还没有轨迹记录」，切走再切回才恢复。**修**：轨迹分支
包 `ListenableBuilder(listenable: chat)`。**复验**（15:28）：resume 后 0.7s
快照到达，轨迹页无需任何操作直接显示完整记录。

**这轮的方法论教训**：三处全是**「先修了 A 面板的同族问题，B/C 面板还有同族」**
——D-096（徽标不监听）→ D-101（轨迹不监听）；D-095（journal 错误无出口）→
D-100（看门狗无出口）；D-094（open 丢 parent）→ D-099（resume 丢 parent）。
**修任何「监听缺失 / 错误出口缺失 / 寻址参数缺失」时，必须 grep 全仓同类消费
端一次做完**，否则每一处都要等下一次真机走查来暴露。

---

## 7. 环境陷阱速查

| 陷阱 | 症状 | 处置 |
|---|---|---|
| 手机息屏 | 截屏全黑（连状态栏都没有） | 先 `input keyevent 224` 唤醒；别误判为渲染 bug |
| FLAG_SECURE 锁屏门 | 截屏 0 字节、UI 驱动失效 | 请用户解锁 |
| MIUI 安装门 | `INSTALL_FAILED_USER_RESTRICTED` | 开发者选项开「USB 安装」，或 root `pm install -r` |
| 中继 mux 长连变聋 | socket 活着但帧不转发 | 周期重开 `$events` 自愈（App 已内置 60s）|
| 集成套件多文件同跑 | flutter_tools 通道挂死（单跑全绿）| 逐文件跑 |
| `adb input swipe` 太快 | 150ms 快甩被系统当误触丢弃、页面纹丝不动 | 用 ≥350ms；否则会误判成「列表卡住」 |
| VM service 的 `debugPaintBaselinesEnabled` | 截图里**每段文字下都有两条亮黄线**，看起来像样式炸了 | 文字本身的颜色/字号是对的，黄线是 baseline 调试层；重启 App 进程即消失 |
| 引擎直连好 ≠ 手机端好 | curl `127.0.0.1:3080/api/…` 与 WS mux 秒回，手机同一端点却无响应 | 手机走的是 `https://relay.example.com`（VPS）→ 插件隧道 → 引擎；先确认 `GET /dsh-remote/session` 里的 `tunnel.relayUrl`，别在引擎侧空查 |
| 中继 URL 会话凭据不可外借 | 拿插件 `active` 那条会话的 qrUrl/hash 去 `wss://` 握手，一律 401 | 设备侧 bearer 是 `<sid>.<expMs>.<mid>.<t>.<hash>`，且必须已被**那台 VPS 中继**认识；换会话号就换一套凭据 |

## 8. 已知引擎侧问题（不在本仓，需引擎修）

- **profile 写锁泄漏**：引擎进程长期持有 `package.json.lock` 的读 fd，导致
  一切 profile 写操作（插件启停）必超时。重启引擎解除。curl 直连可复现，
  与客户端无关。