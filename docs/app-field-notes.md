# App 端实测踩坑与修复（D-067 ~ D-113）

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

### 6.8 第三轮走查追加：点回底钮之后手势锁死（D-102）

同日 19:5x，全量走查第三轮。在子会话的对话页点过「回到底部」之后，
**整条列表的手势彻底失灵**：滑动无反应、再点回底也没用；切到别的 tab 再切回来
立刻恢复。App 进程 CPU 3.4%（不是忙循环）、无 ANR、logcat 无 flutter 异常、
tab 切换正常（UI 树活着，只有对话页手势死）。Stack 里也没有透明全屏 widget
吃手势。

#### 病根：自动贴底与用户手势抢同一条滚动位置

两处代码在**密集事件流**下互相打架（后台恢复重放、投影刷新正是这种形态，
每帧一次 controller notify）：

1. **贴底开关靠 ±80px 阈值判断「用户是不是想翻历史」**，而阈值判定发生在手势
   开始**之后**。手指刚落上列表还没滑出 80px 时，跟随仍是开的 → notify 里
   的 postFrame `jumpTo(maxScrollExtent)` 落在手势中途，直接把 drag 打断；
2. **回底用 `animateTo` + 递归补跳**（D-090 为治「落进空白区」加的）。动画是一条
   有状态的 activity：被 jumpTo 打断后 `whenComplete` 立刻排下一次 animate，
   动画状态机自己跟自己打转，把用户手势一起绞死。

#### 修法（三处）

- `ScrollStartNotification(dragDetails != null)` 一到就置 `_dragging=true` 并
  强制 `_followBottom=false` —— **手势期间自动贴底闭嘴**，postFrame 跳底加
  `|| _dragging` 守卫；
- `_scrollToEnd` 改**同步 `jumpTo`**（D-090 的懒加载估算问题用 postFrame 有界
  重查兜住），没有 activity 可抢；
- 贴底开关收口到 `_setFollowBottom`，回底钮是用户唯一的逃生出口。

**守门写第一版时踩了自己的坑**：一开始的用例只断言「离底距离」，结果在旧代码
上也是绿的——两条原因叠加，① 往**已有**气泡追加内容根本不会让懒加载 ListView 的
`maxScrollExtent` 增长；② `applyFrame` 的通知被 **48ms 的 stream-paint 合并定时器**
延后，测试只 `pump()` 零时长时通知压根没落地。最后钉成「手指往下拖 pixels 只许
变小、不许变大 + 必须 `pump` 推进时钟」。**回退即红验证**：两条用例在旧代码上
都真的红了。

**过程中还抓到一个自己引入的缺陷**（测试逼出来的，不是想出来的）：`_dragging`
也参与回底钮显隐判定，抬手时若 `_followBottom` 早已是 false，`_setFollowBottom`
不会再 setState，按钮就**永久停在隐藏态**——用户列表失灵时连逃生出口都没了。
ScrollEnd 分支补一次强制重画。

**复验**（20:5x，小米）：拖动 → 回底钮出现 → 点它一次到底（同步跳）→ **立刻**
再滑，列表正常响应、回底钮重新出现；连做三轮「点回底 + 上下滑」仍无锁死，
logcat 无 flutter 异常。

### 6.9 顺带挖出：空会话残留回底钮（D-103）

验 D-102 时顺手发现的：长会话里翻离底 → 新建一个 0 轮空会话 → 右下角那颗
「回到底部」**还亮着**，而列表里连一个气泡都没有，根本没有「底」可回。

第一版诊断是错的（我猜「切换时 ScrollPosition metrics 陈旧」），**探针实锤**的
真因是：**ConsolePage 新建会话时复用同一个 `ChatController`**（只是调
`open()` 换 sessionId），`ChatPane` 的 widget 和 controller 都没换，于是
`didUpdateWidget` 里那条「换 controller 就复位贴底开关」**根本没执行**——
`_followBottom=false` 从上一段会话一路带进新会话；空列表又不会产生任何滚动
事件去纠正它，按钮就一直挂在那儿。

**修法两处**：① `ChatPane` 在 build 里按 `sessionId` 变化复位（那才是真正能
观察到「换会话」的地方）；② 按钮显隐加「列表里有气泡」兜底。

**守门写不出来的那一段，值得记**：这条路径（同 controller 二次 `open`）在
`testWidgets` 里直接 `await controller.open(...)` 会**把测试吊死**（`open` 首行
`await _closeJournal()` 等旧流关闭），必须包进 `tester.runAsync`；而且推帧也要
一起放进 `runAsync` 内——否则 broadcast stream 不缓存，帧在订阅循环起来前就
丢了，`_loading` 永远停在 true，页面渲染的是 spinner 分支，断言会**假绿**。

**复验**：真机走同一条路径，空会话干净。

### 6.10 vivo（Android 16）复验带出两条：契约已有、实现没有（D-104）

同日 10:0x，把当天全部修复装到 **vivo V2502A / Android 16（SDK 36）** 复验。
vivo 上装的是前一天凌晨的老包，一轮修复都没进去。跨平台结论：D-102（流式中
滚动）在 Android 16 上同样成立，工作区/轨迹/团队页都正常。

真正的收获在**断网冷启动**那一步——顺手按出来的缺陷 D-104：

1. **文案说谎**：首帧 45 秒看门狗超时后落一张错误卡，文案是「引擎处理超时，
   **正在重试**」，而 `_onFirstFrameDeadlinePassed` 设完 `_error` 就结束了，
   **代码里根本没有重试**。真机表现：网络恢复、mux 重连成功（logcat 有
   `$events clientId=...`），那张卡**永不消失**；点它无反应、切 tab 往返也
   无效，只有从会话列表重新进入才活。
2. **注释也说过头**：`chat_controller.dart` 里写着「The bubble is also the
   retry affordance」，可 `ErrorNotice` 气泡只印文案、不可点。

**根因不是缺功能，是契约已有、实现没有**：`error_code.dart` 里早就写着
`ErrorCode.engineTimeout => RetryPolicy.autoBackoff`，只是聊天页没兑现它。

修法：超时后按 `RetryPolicy.autoBackoff` 自动重开一次（3s 退避），错误卡加可点
的「重试」（重开 journal）。自动重开走**同步**路径而不是 `open()`——`open` 首行
`await _closeJournal()`，在 widget 测试的 FakeAsync 区里这个 await 永远不完成
（同 D-103）；顺带给 journal 加了 `_journalGeneration`，关旧流的 `cancel()` 是
异步的，新流绑定后旧流可能还递上来几帧，按代号不符一律丢弃。

#### 真机当场抓到的第二个 bug：自动重开变成死循环

装包复验时 logcat 直接把循环抖出来了：

```
10:48:06 first-frame deadline hit → auto-reopening → open journal gen=2
10:48:54 first-frame deadline hit → auto-reopening → open journal gen=3
10:49:42 first-frame deadline hit → auto-reopening → open journal gen=4 …
```

每 48 秒一次，无穷无尽，用户永远只看到一个转圈。起因是我把「手动重试」和
「自动重开」都接到同一个 `retry()`，而 `retry()` 为了「用户主动点了就给一次
自动兜底」会重置预算——于是每次自动重开都把预算花光再重置。

**为什么第一版守门没抓住**：那条用例只推进了 4 秒，够验一次自动重开，不够验
第二次。补了一条「第二次超时不得再自动重开」才咬住（回退验证：follow 次数
2 → 3，守门红）。教训和 D-102 那条同源——**断言必须覆盖「第二次」**。

### 6.11 上下文栏挤爆，截断的偏偏是最该保住的那一项（D-105）

用户截图指出：对话页底部状态栏太挤——`上下文 11%🧊st… 51.3 tok/s 缓存 88% 1 轮`。

根因是**截断优先级反了**：`ContextBar` 整行 `Row` 里只有 agent 名套了
`Flexible`，百分比和两个胶囊全是固定宽度。屏幕一窄，唯一能被压缩的就是
agent 名，于是 `stock-trader` 被截成 `stock…`，而 tok/s、缓存这些装饰性
数字占着位置不让位。附带两处小毛病：`上下文` 三字与 🧊 只隔 3px；
`55.4 tok/s` 在 360~393dp 屏上吃掉三分之一宽度。

修法（用户定稿：**拆成上下两行**）：第一行只放圆环 + 上下文占用 + agent 名
（独占整行宽度，常见 agent 名都能完整显示，真长到放不下才截）；第二行放
tok/s、缓存两个胶囊，右边留轮数与详情入口。

**守门怎么写才咬得住**：断言「窄屏下 agent 名**未被截断**」不能靠肉眼，要量
`RenderParagraph.didExceedMaxLines`——把 surface 设成 393×873（小米真实
宽度）再配一份「什么都报了」的 projections（占用+速率+缓存+轮数齐活，正
是真机上挤爆的那种组合），并断言 `ContextBar` 里恰好两个 `Row`。回退验证：
把指标塞回第一行 → `didExceedMaxLines=true` 立刻红。

**复验**：vivo（360dp）上 agent 名 `standard` 完整显示，tok/s 与缓存落到第二行。

### 6.12 折叠预览里 markdown 表格露竖线（D-106）

用户截图里那段表格原样显示成 `| 位置 | 含义 |` / `|----|----|` / `| 20.00 | 9 月…`。

**第一步诊断就走错了**：先用 widget 测试喂完整表格、截断表格、缺空行表格
三种输入，发现 `Table` 都渲染出来了（gpt_markdown 1.3.4 有 `TableMd` 组件，
本来就没问题）。真机现象在测试里根本复现不了。

真因在**折叠态**：`_MessageBody` 只在展开/非折叠时才走 `GptMarkdown`，折叠
预览走的是 `_previewOf` 那套「去符号净化」（D-070.1），而它只认 `#`、`**`、
反引号、列表符号——**完全没有表格这一项**。真机那段回答 880 字 > 600 字折叠
线，于是走折叠路径，竖线原样外露。

修法：`_previewOf` 拆出单行版 `_previewLine`，补表格处理——分隔行整行丢掉，
数据行去掉首尾竖线、单元格用 ` · ` 分隔。内容一个字不少，只是符号不见了。

**守门写法**：必须先构造出**折叠态**（>600 字），否则测的是富文本路径、bug
不现形——我第一版 filler 只写了 420 字，前置条件「展开全文」按钮根本没出现，
守门是绿的。这也是 D-105 那条的同一课：**fixture 必须落在出问题的分支上**。

**复验**：vivo 真机折叠预览里 `| 帖 | 档位 | 内容 | 方向 |` 变成
`帖 · 档位 · 内容 · 方向`，分隔行消失，数据行压平。

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
| 引擎直连好 ≠ 手机端好 | curl `127.0.0.1:3080/api/…` 与 WS mux 秒回，手机同一端点却无响应 | 手机走的是你自己的中继 VPS → 插件隧道 → 引擎；先确认 `GET /dsh-remote/session` 里的 `tunnel.relayUrl`，别在引擎侧空查 |
| `applyFrame` 的通知被 48ms 合并定时器延后 | widget 测试里 `pump()` 零时长后断言「UI 应该更新了」——其实通知还没发出，守门一片假绿 | 推时钟：`pump(100ms)`；`ChatController._scheduleStreamPaint` |
| 懒加载 ListView 的 `maxScrollExtent` 对「往已有气泡追加内容」不增长 | 拿 `pixels` 与 `maxScrollExtent` 的差值当断言基准会踩到边界/空断言 | 用**不变量**断言（手势往下拖 pixels 只许变小）；要真让列表变高得推**新 durable 记录**（新 item）|
| `testWidgets` 里对同一 controller 二次 `open()` | 直接 `await` 会把测试吊死（`open` 首行 `await _closeJournal()`）；改用 `runAsync` 后又可能**假绿**——帧在订阅循环起来前就被丢掉，`loading` 停在 true，页面渲染 spinner 分支 | `open` + `pushFrame` **都放进同一个 `tester.runAsync` 内部**；跑前先断言 `loading=false && list=1`，别让它用 spinner 分支蒙过去 |
| 「换会话」的信号可能根本不走 `didUpdateWidget` | ConsolePage 新建/切换会话复用同一个 controller，只调 `open()`——widget 层的「换 controller 就复位」形同虚设 | 需要按会话复位的 UI 状态一律以 `controller.sessionId` 为准，在 build 里比对 |
| 中继 URL 会话凭据不可外借 | 拿插件 `active` 那条会话的 qrUrl/hash 去 `wss://` 握手，一律 401 | 设备侧 bearer 是 `<sid>.<expMs>.<mid>.<t>.<hash>`，且必须已被**那台 VPS 中继**认识；换会话号就换一套凭据 |

## 8. 已知引擎侧问题（不在本仓，需引擎修）

- **profile 写锁泄漏**：引擎进程长期持有 `package.json.lock` 的读 fd，导致
  一切 profile 写操作（插件启停）必超时。重启引擎解除。curl 直连可复现，
  与客户端无关。
### 6.13 诊断日志被自己的探针冲爆，同一次里还发现崩溃从来没被记过（D-107）

**症状**：真机（小米 10-12）打开「诊断日志」，整屏都是
`D/[e2e] [e2e] frame FollowAssistantStream`，时间戳密集到肉眼分不出行。翻完整份
文件，真正有用的一行只有一条 `W/[chat] first-frame deadline hit`——而它能活下来
纯属侥幸：**流已经停了**，没有新噪声把它冲走。

**根因一 · 探针按帧打**：`chat_controller` 对 journal 每一帧打一行 debug 日志。
引擎流式输出实测 130–250 帧/秒，一行 67 字节，而 `FileLogSink` 上限 256KB ×
两代 ≈ 7800 行 ⇒ **一次连续输出 30–60 秒就能把两代缓冲全部冲干净**。
附带两个同源问题：debug 包把同一份噪声同时写 logcat 和文件；逐行
`writeFromSync` 同步写盘 = 流式输出时每帧一次同步 I/O。

**根因二 · 崩溃从未落盘**：`docs/app-design.md` §7.2 早写着「全部错误入本地
脱敏日志」，但全仓 `FlutterError.onError` / `runZonedGuarded` /
`PlatformDispatcher.onError` **零命中**。框架异常只在 logcat 红屏里，未捕获异常
直接崩进程——**App 真崩了，诊断页是空的**，恰恰是最需要日志的那次。

**修法**：①帧日志改「前 3 帧逐帧 + 每 2 秒按类型汇总」（`FrameSampler`），30 秒
满速输出 6000 行 → 18 行；②`CrashCapture` 装三个全局入口，且**保留既有
handler**——捕获 ≠ 吞掉，debug 红屏还得在；③日志拆三通道各自配额
（`app.log` / `crash.log` / `audit.log`），debug 探针挤不掉崩溃记录；④攒批写，
满 4KB 或 250ms 落一次盘。

**方法论（今天第三次同族）**：两处断言基准选错，都是回退验证当场逮到的——
「栈单独成行」拿**记录条数**断言（栈其实是同一条记录里的换行）；「崩溃落 crash
通道」拿 `MemoryLogSink.lines` 断言（`lines` 不按通道过滤，误投 app 通道照样
看得见 ⇒ **回退后仍然全绿**）。通道类断言一律走 `readChannel`。

**复验**：`FrameSampler` 回退成逐帧 → `Expected: a value less than <30>,
Actual: <6000>`；`AppLog.crash` 回退成写 app 通道 → 两条通道守门同时变红。
app 全量 482/483，唯一红的是既有 golden 漂移（`git stash` 回 HEAD 复跑同样红）。

### 6.14 装上崩溃捕获后的第一个真机启动就报了 Zone mismatch（D-107 续）

**症状**：`CrashCapture` 装好后第一次真机启动，`crash.log` 自己长出来了 1761 字节，
内容是一条框架错误：

```
E/[flutter] Zone mismatch.
The Flutter bindings were initialized in a different zone than is now being used.
...
context=while during runApp library=Flutter framework
#4 main.<anonymous closure> (package:dsh_remote_app/main.dart:53:33)
#8 runZonedGuarded (dart:async/zone_api.dart:151:12)
#9 CrashCapture.runGuarded (package:dsh_remote_app/logging/crash_capture.dart:58:5)
```

**根因**：`WidgetsFlutterBinding.ensureInitialized()` 写在 `main()` 里（根 zone），
而 `runApp` 在 `runZonedGuarded` 里面（子 zone）。Flutter 对此的措辞是「会导致
困惑和 bug：任何 zone 相关配置会按难以预测的因素在不同 zone 的配置之间摇摆」。

**为什么 24 条单元测试一条都没抓到**：它们全部**不进 `main()`**。这是本轮第三次
「测试抓不到、真机一下抓到」——前两次是 D-104 的重试死循环与 D-101 的轨迹不监听。
**凡是把 `ensureInitialized` / `runApp` / zone 拆开的改动，单元测试的覆盖率是 0。**

**修法**：`ensureInitialized()` 移进 `runGuarded(() { …; runApp(…); })` 内部，
与 `runApp` 同 zone。修完重启，`crash.log` **根本不存在**（文件按需创建，无崩溃
就不落盘）——这才是干净启动该有的样子。

**附带发现 · 诊断页打开要 7 秒**：`flush()` 的收敛条件里多写了 `_raf == null`，
于是「**从没写过**的通道」也被当成「还在忙」，每个空通道空转 200×5ms，三个通道
= 3 秒起步（小米实测 7 秒多才出内容，旧代码是立刻返回的，纯回归）。而诊断页的
widget 守门抓不到它——那一页用的是 `MemoryLogSink`，`flush()` 是空实现。
**守门要覆盖「文件 sink 的真实契约」，不能只测替身。**

**复验**：修完重启 → `crash.log` 不存在、`audit.log` 有 `action=app.start`；
诊断页 **1 秒内**出内容（原来 7~8 秒）；切到「崩溃」通道显示「该通道暂无日志。」
而不是含糊的「暂无日志」。app 全量 485/485 全绿（golden 基线的时间炸弹见 §6.15）。

### 6.15 Golden 基线钉住的是「只有那一天存在过」的状态（D-108）

**症状**：全量套件唯一一条红是 `golden · machines list (live + expired)`，0.18%、
7764px。之前只证伪过「不是我改坏的」（`git stash` 回 HEAD 复跑同样红），没查
它自己为什么红。

**分诊手法**：别看 `isolatedDiff` 的红块位置就下结论——先跑两次比对 testImage 的
md5（一致 ⇒ 测试是稳定的，差异来自基线而非抖动），再用 PIL 把 diff bbox、逐行
逐列的墨迹段、字号框数量全量出来。我最初肉眼把差异读成「文字行多了一个字」，
**错的**：像素测量显示文字段 (146,501) 两边完全一致，真正变的是过期机器那行的
第一个 chip（1913→1881，宽 96→128px）。

**根因**：`test/factories.dart` 的 `expiredMachine()` 用**真实墙钟**铸造：

```dart
MachineEntry expiredMachine() => machineFrom(mintTestUrl(
      now: DateTime.now().subtract(const Duration(days: 3)),
    ));
```

而 golden 套件把渲染时钟**冻结**在 `2026-10-01 09:30 UTC`
（`MachineCard.nowOverride`）。于是 `isExpired(frozen)` 取决于**你哪天跑测试**：
铸造时刻 = `realNow − 3d`，签名 URL 窗口 24h ⇒ `expMs = realNow − 2d`。

反推基线：chip 是中性灰、点是绿的 ⇒ 当时**不是过期态**，而是「还剩 0~60 分钟」
（标签 `"NNm"` 恰好 3 个字形）。解出 `expMs − frozen ∈ [0, 1h)` ⇒ 拍摄时刻在
**2026-10-03 傍晚**。也就是说这张基线编码的是一个**只在那几个小时存在过的状态**，
之后任何人都复现不出来——它不是"漂移"，是一次性的。

**讽刺点**：`factories.dart` 里 `liveMintTime` 上方那段注释已经把同一个坑写下来了
（"a time bomb that made the pairing and golden suites fail on 2026-10-02 with no
code change"），在线夹具修过，**过期夹具漏改了**——它是那个时间炸弹的**镜像
版本**：在线夹具怕绝对日期过期，过期夹具怕相对日期「过期得不够久」。

**修法**：①`expiredMachine({DateTime? now})`，默认仍是真实墙钟（pairing /
screens_dghi 那两套用真实时钟渲染的用例不受影响），golden 传冻结时间；
②重拍基线——旧基线钉的状态已经不存在，且它本来就不是「过期态」。

**复验**：修完卡片进入真正该有的过期态（红点 + danger chip +「已过期」），
`flutter test` 全绿；golden 连跑两次 testImage md5 一致，说明可复现。

### 6.16 冷启动不记得「上次看的会话」，而且标题缓存只写不读（D-109）

**症状**：手机上聊着 A，电脑另一个终端跑了 B，杀进程重开 App，进控制台落到的是 B。

**根因**：跨冷启动**压根没有任何地方存过 sessionId**——`grep -rn "lastSession|
currentSession|restoreSession" lib/` 零命中，唯一的持久化写入是机器列表、语言设置、
会话标题缓存。控制台那点「自动打开」取的是 `_latestResumable(rows)` = 列表第一个 =
**引擎侧最近更新**的会话，跟「用户上次在看哪个」无关。同进程内前后台切换是认得的
（`_resumeFromBackground` 拿内存里的 `_sessionId` 重开 journal），所以问题只在
「杀掉再开」这一种路径上。

**顺带挖出的第二个 bug**：`SessionTitleCache.load()` **只在 `test/
workspace_titles_test.dart` 里被调用过**，生产代码从来没调。于是 D-062「标题跨进程
存活」只写不读——冷启动后工作区与会话列表照旧退回 `session-xxxx`。**写盘成功 ≠
读得回来**，而这类漏接线单测抓不到：测试自己调了 `load()`，看起来就通了。

**修法**：
- 新增 `LastSessionStore`（按机器存 `machineId␟sessionId`，沿用 `SessionTitleCache`
  的 `␟` 格式），`load()` / `ready` / `remember` / `lastFor`；
- **写**在 `ChatController.open()`——「用户此刻在看哪个会话」的唯一漏斗（自动打开、
  列表点选、新建、团队页点子代理都走它）；`open(null)` 走 null 分支 = 忘掉，用户
  显式关掉的就别在下次又被请回来；
- **读**在 `ConsolePage._loadSessions`：先 `await ready`（不等就会读到空内存态、
  **静默**回落到 latest，正是这个特性要修的行为，而且一声不吭），再
  `_resumeTarget()` 优先记忆里的会话；
- **必须验活**：记忆里的 id 可能已被引擎删了，硬开会得到一个永远转圈的空白页
  （D-100 修过的那类症状）且不报错——列表里没有就回落到最近更新的；
- `main.dart` 里把两个 store 的 `load()` 真正调上（补 D-062 的漏接线）。

**真机复验（小米 2109119BC）**：App 启动无 `crash.log`，控制台挂载正常、
`await ready` 不卡不抛，`session/list` 的失败被如实记录
（`EngineRemoteError(auth/refused: … HTTP 401)`）——那台机器的会话仍被拒，会话列表
为空，所以**没有会话可自动打开**。也就是说：改动路径在真机上跑通了，
但「恢复到上次那个会话」这一段**没有在真机上亲眼验过**（缺一次可用配对），不冒充
已验。守门：`last_session_store_test` 7 条 + `console_resume_last_session_test`
5 条；回退验证把 `_resumeTarget` 退回 `_latestResumable` → `Expected: session-a /
Actual: session-b` 变红。app 全量 497/497 全绿。

### 6.17 凭证终态失效，控制台却一直说「正在重连」（D-110）

**症状**：用户一句「为啥一直连接不上」。设备上控制台挂着「连接已断开，正在重连…」，
转圈永不停。

**诊断链**（逐段验，别从一个 401 就下结论）：

| 环节 | 结论 | 证据 |
|---|---|---|
| 手机 → relay | 通 | App 拿到的是 HTTP 层错误，不是超时 |
| relay → 引擎 | 通 | 401 是**引擎 RPC 层**回的，不是 relay |
| 引擎进程 | 活着 | 14:45 还在写新会话 |
| 凭据 | 被拒 | `engine RPC session/list returned HTTP 401` |

过期的是 **URL 会话本身**，三处独立印证：引擎插件注释「凭证（**URL 会话 24h exp** /
pairing cookie）」、App 自己的报错文案「有效期 1 分钟–24 小时」、卡片判「已过期」。

**为什么换不了**：`_realMint`（`session_scheduler.dart:81`）用
`bearerProvider: () async => entry.params.bearer` 调
`GET /dsh-remote/url-session` 铸新链接——**换钥匙这道门要用旧钥匙开**。而
`shouldRenew` 里 `!isExpired(now) &&` 那一项意味着过期条目被扫描直接跳过。所以
**错过过期前 2 小时就是终局**，重试一万次也不会成功。这是当时明确决定且有单测
（「已过期不续」）的行为，不是漏做。

**真 bug 在文案**：横幅条件只有 `_muxState != connected`，而凭证过期时 mux 永远
到不了 connected ⇒「正在重连…」**永远**显示。它承诺了「正在重连」，而真实情况是
永远重连不成——D-104「文案写着正在重试，那就让它真的重试」的**第四例**。分层也错：
design §7.2 写明**会话失效属 L1 全屏页（红，唯一主行动）**，L3 横幅是「自动消失」
的层级，给终态挂自愈横幅＝用户等多久都等不到。

**还有一个隐形洞**：续期成功与失败**都不写日志**（`_fail()` 只塞 UI 芯片），所以
「续期为什么没救回来」在磁盘上完全查不到——那正是用户追问的核心。

**修法**：①横幅分两种，终态用红 + 断链图标（不转圈）+「凭证已失效，不会自动恢复」
+ 三因判别人话 + 唯一主行动「去重新配对」（跳机器页，那里才有配对流程）；
②终态首次判定记一行 audit：`action=machine.credential.dead cause=expired`；
③判据是本地时钟，不等一次失败往返。

**真机复验（小米 2109119BC，天然对照组——这台机器正好处于终态）**：横幅变红、
断链图标、文案「凭证已失效，不会自动恢复 / 会话已过期 · 需要重新配对才能继续」、
点「去重新配对」真跳到机器页那张写着「已过期 · 点击重新配对」的卡；audit 落
`cause=expired`（顺带暴露了真实 session id `sess_f345b782ac3a558c`）。

**守门**：`console_terminal_credential_test` 4 条（核心那条断言
`find.text('连接已断开，正在重连…')` **findsNothing**）。**回退即红**：摘掉终态判定 →
立刻 `Found 1 widget with text "连接已断开，正在重连…"`。app 全量 501/501。

### 6.18 「不会错过的续期流程」：把死结从协议里拆开（D-111）

**起因**：用户一句「为啥会错过呢，我们是不是要设计一个不会错过的流程」。

**先说实验结论——而且不用跑实验，答案就写在代码里。** 原计划是「拿一把过期
bearer 去打 url-session 看服务器给不给」，但 relay 的闸门实现直接给出了答案
（`server/src/index.ts` `verifyUrlSessionToken`）：

```ts
if (now > Number(exp)) return null                          // 过期直接拒
if (now - tMs > SHARE_LINK_MAX_AGE_MS) return null          // mint 老过 30 天也拒
if (!sessionManager.getSession(sid)) return null            // 吊销/不存在也拒
```

而 App 的 `_realMint` 用**旧 bearer** 调这个端点铸新链接——**换钥匙的门要用旧
钥匙开**。于是「错过窗口 = 终局」不是 App 偷懒，是协议本身无解。

**结构性缺陷**：当前设计等于把「连接保持」外包给「**用户每 22 小时打开一次
App**」（TTL 24h，窗口在剩 2h）。对一个远程控制 App 来说，这要求本身就荒谬——
你越是把它当远程工具用（不开它），它越容易死。

**拆死结的办法（只放宽一条，其余全部照旧）**：relay 为 **只有**
`/dsh-remote/url-session` 这一个路径开口子，让「已过期但签名正确、session 未被
吊销、mint 未老过 30 天 cap」的凭证能过去**铸出下一把钥匙**。

安全边界（务必保持，`server/tests/relay.spec.ts` 里逐条钉住）：
- 精确路径匹配，`/dsh-remote/url-sessionX` 不跟着放宽；
- HMAC 签名比对一字不改；
- 吊销 / session 不存在 → 照旧 401（这个口子救「过期」，救不了「被吊销」）；
- 30 天 cap 照旧 → 它是「续命」不是「复活」；
- 铸出的新 bearer 照旧 24h，仍走完整闸门；
- **数据面完全没动**：过期凭证访问 `/api/*` 照旧 401。

App 侧配套：
- `sweep()` 不再把过期条目直接跳过（过去 `shouldRenew` 里的 `!isExpired` 就是
  「连问都不再问一次」），改成带退避再问：5min → 30min → 2h 封顶——别把没救的
  条目变成每 60 秒敲一次门的东西；
- **续期成功与失败都记 audit**（`action=machine.renew ok=… wasExpired=…`）。过去
  两者都不写日志，于是「这台手机为什么错过了窗口」在磁盘上查无实据，而那恰恰是
  排障时唯一能回答的问题；
- 既有单测 `expired machine is not renewed` 被**显式改写**（不是悄悄变红），
  注释里写清「当时是对的、现在为什么变了」。

**守门**：relay 5 条 + App 4 条，两端都做了回退即红（relay 摘口子 → 数据面那条变
红；App 退回跳过 → 三条同时变红）。server 97/97，app 504/504。

**生产部署与实测**（16:38）：relay 是 rsync 部署在 VPS 的生产容器
（`a-production-container`，Up 8 天 healthy，`a-private-deploy-dir`，端口
18080 / `network_mode: host`）。部署时**没有整体替换**——部署版源码是 9 月 30 日的，
与本地差 105 行，整体替换等于把两个月无关变更一起推进生产。只把 D-111 这三处改动
打成补丁贴上去，本地拉下部署版整套 src 用同款 tsc 验过再上传；旧文件备份在
`src/index.ts.bak-d111`。

⚠️ 一次**假绿**值得记：VPS 上 `npx` 不存在，而我用 `EXIT=$?` 取的是 `head` 的
退出码，于是打印出「编译通过」——其实根本没编译。**部署类动作不能用这种间接判断
充数**，改成把源码拉到本地用同款编译器编。

生产实测（在真 relay 上注册一条临时 session，铸一把**过期但签名正确**的 token）：

| 断言 | 结果 |
|---|---|
| `GET /dsh-remote/url-session` + 过期 token | **200**，引擎真的铸出新的 24h url |
| `GET /api/version` + 同一把过期 token | **401**（数据面仍锁） |

**手机那台：现在完全连上了**——`console session/list ok=true`，journal 打开、会话
正文渲染、上下文环 7% / 40.7 tok/s 都正常。

**但要说清一件事：手机的恢复不是 D-111 这条路干的。** 设备 audit 里**没有**
`machine.renew`，relay 侧也**没有** `url_session_rearm` 记录；而手机上凭证在我到场
之前就已经是新的（卡片显示「第 1/30 天 · 剩 23h 50m」，`firstPairedMs` 是近期的）。
最合理的解释是那台机器在期间**被重新配对过**（day 1/30 就是证据）。所以
「App 侧过期重铸」这条路径在真机上**仍未亲眼见到**——不冒充已验；它由 4 条单例
守住，新版日志也已经就位，下次真发生就能直接查到。

### 6.19 D-111 端到端：App 真代码 × 生产 relay × 真过期 token（16:59–18:02）

设备时钟这条路走不通——MIUI 禁止 `date` 改系统时间（`Operation not permitted`），
改用**直接让 App 的真代码打生产 relay**。

做法：VPS 上起一个 `engine_holder.mjs` 以**引擎身份**常驻（注册一条 session，并对
relay 代理过来的 `http.req` 回一个真签名的 24h url），Dart 侧拿 `package:dsh_remote_app`
里**真正的 `SessionScheduler` + `RelayClient`**，配一把「24h 前铸、23h 前就过期、
HMAC 正确」的 token 跑 `sweep()`。

**两次失败都是好线索**：

1. 第一版 session 没在 relay 注册 → mint 返回空 → `ok=false error=mint returned
   nothing`。这恰好验到了安全边界：**伪造 token 打不存在的 session 会被
   `!sessionManager.getSession(sid)` 挡下**，口子没有变成万能钥匙。
2. 第二版 relay 放行了（200）但 App 报 `SignedUrlFormatException: path must be /
   (root landing)` —— holder 铸的 url 路径写成 `/dsh-remote/?…`，而 App 要求根路径
   着陆。是探针的错，不是产品的错。

顺带一提：**这个错误正是因为 D-111 给失败加了日志才看得见**——过去它在
`_fail()` 里只变成一个自动消失的芯片。

**最终结果**（两端 + App 侧留痕，三处同时成立）：

```
PROBE     mintCalls=1 stillExpired=false
PROBE_LOG A/[audit] action=machine.renew machine=sess_prodcheck_002 ok=true wasExpired=true
relay     {"msg":"url_session_rearm_expired_token_allowed","sid":"sess_prodcheck_002"}
```

即：过期条目**确实被再问了一次**（`mintCalls=1`、`wasExpired=true`）→ 生产 relay
**用过期凭证放行了重铸**（`url_session_rearm_expired_token_allowed`）→ 新凭证被解析
并原地替换（`stillExpired=false`，30 天锚点不动）→ **audit 落了一行**。

一次性测试文件用完即删（依赖 `RELAY_PSK`/`RELAY_ORIGIN` 环境变量、打生产，
留在 test/ 里是个陷阱）；配方记在 PROGRESS，需要时可照着重建。

**手机那台仍未由这条路径恢复**：它的凭证在我到场前已是新的（卡片「第 1/30 天」），
设备与 relay 两侧都没有 renew / rearm 记录，最合理解释是期间被重新配对过。

### 6.20 PSK 缺失不该是「拒启让人干瞪眼」（D-112，运维拍板）

**决定**（运维口述，两条硬规则）：**relay 侧 PSK 没配置就自动重新生成一把，长度
32 位起步；dsh 客户端插件必须配置才可以使用。**

**为什么自动生成而不是继续拒启。** 之前缺 PSK 的表现是
`refusing to start — unsafe relay configuration: RELAY_PSK is unset…`。对一个
第一次自部署的人来说那是：装完了、起不来了、错误信息告诉他去设一个变量——但
**没人告诉他该设成什么值**。生成 + 落盘 + 打印路径，把「不知道填什么」变成
「`cat` 这个文件复制过去」。

**实现要点**：

- `generatePsk()` 用 `crypto.randomBytes(32)` → 64 个 hex 字符（`Math.random`
  在根秘密的种子源上不可接受）；`MIN_PSK_LENGTH = 32` 是下限。
- **不回写 `.env`**：部署形态是 `env_file: .env`，docker compose 在**宿主机**上
  读它，容器里根本没有这个文件，写了也会在容器重建时蒸发。落盘位置是**数据卷**
  `<dataDir>/generated-psk`（`/app/data`，真正跨容器重建存活）。
- 重启**复用**同一把（否则自己的重启就会打断隧道）；落盘值短于下限 → 当作没有、
  重新生成（宁可换掉也别留一把弱钥匙）。
- env 里**显式设成那个公开默认值**按「没设」处理——它本来就等于公开。
- 启动提示**只打印路径不打印值**：密钥不进日志（仓库有 `scripts/scan-secrets.sh`），
  操作者照着路径 `cat`。
- `assertProductionConfig` 的拒绝逻辑**保留为最后一道防线**，并新增长度校验——
  防的是有人绕过 `resolvePsk` 直接构造 config 调过来（buildServer 直调、脚本）。
  因此既有守卫用例的夹具从 21 字符的 `TEST_PSK` 换成 64 字符，否则新校验会误伤。

**守门**：6 条（env 优先且不生成 / 缺失则生成并落盘 / 公开默认按没设 / 重启复用 /
弱值重生成 / 真生成器 64 hex 且两次不同）+ 长度守卫 1 条。回退即红：4 条同时变红。
server 103/103。

**插件侧待做**（agent-stock 仓）：`psk` 缺失或等于
`agent-stock-default-insecure-psk` → 拒绝启用。relay 侧本来就有这道守卫
（`config.ts:101-110`），**两边不对称**：本轮讨论中先被误判成「relay 的洞」，
其实是引擎插件缺了同一道防线。

### 6.21 收尾：备份/截屏硬保证、PSK 去重、D-112 上生产（D-113）

**① 隐私表的承诺补成硬保证（D-113）**

顺着「要不要给 APK 加固」那轮查出来两处**文档写了、代码没做**：

- **备份**：design §8 写着凭证「不随备份出设备」，而 main manifest 里**根本没有**
  `android:allowBackup` 那一行——靠「日志落在 cache 目录，cache 不进备份」这个
  间接事实。而凭证本身（flutter_secure_storage 的 AndroidX security-crypto 偏好）
  默认**是**会被云备份带走的；Android 12+ 还得看 `dataExtractionRules`，光写
  allowBackup 拦不住设备换机迁移。→ allowBackup=false + fullBackupContent=false +
  逐项排除的 data_extraction_rules（cloud-backup 与 device-transfer **两个通道**）。
- **截屏**：屏 E 是真实业务内容（正文、工具调用、文件路径、用量），系统截屏/录屏/
  最近任务缩略图都能带走而 App 无感。→ MainActivity.onCreate 设 FLAG_SECURE。
  知情代价：用户不能再截图反馈；真机排障走 `adb screencap`（ADB 通道不受影响）
  与 App 内诊断日志（屏 G），本项目一直靠这两条。

  守门是**读文件本身**——原生改动 widget 测试进不去，而这类漏洞正是靠文档才漏
  的。删掉 `allowBackup` 那一行，守门立刻变红（已验）。

**② `cordis.patch.yml` 里两份 PSK 的真相**

两份都是 `enabled/relay_url/psk`，但**插件 id 不同**：`agent-stock-remote`（第 31 行）
与 `dsh-remote`（第 161 行）。而 **harness 里根本没有名为 `dsh-remote` 的插件**（只有
`@deepseek-ai/dsh-remote-mock` 这个测试替身）——所以第 161 行是**死配置**。

为什么确定活的那个是 `agent-stock-remote`：D-111 的生产实测里，打 `/dsh-remote/url-session`
时 relay 转发到了引擎，**回的是一把真签名的 24h url**——那正是 `agent-stock-remote`
的代码路径（`plugin/src/index.ts` 的 `url-session` 分支）。

死配置的风险不是安全，是**误导**：改 PSK 时改到死的那份会疑惑"怎么没生效"；
轮换要改两处其中一处没用；哪天有人把插件改回这个名字，它会带着旧 PSK 悄悄复活。
已删除，备份 `cordis.patch.yml.bak-dedup-*`，现在 PSK 只剩一处。

**③ D-112 上生产（VPS）**

沿用 D-111 的纪律：**不打整体替换**（部署版是 9-30 的，与本地差 105 行），只把
D-112 的三处贴上去，本地拉下 VPS 整套 src 用同款 tsc 验过（TSC_EXIT=0）才上传；
备份 `index.ts.bak-d112` / `config.ts.bak-d112`。

生产实测（真镜像、一次性容器、独立卷）：

| 断言 | 结果 |
|---|---|
| VPS 有 `.env` PSK 时**不**生成 | 0 次横幅、**无** `generated-psk` 文件 ✓ |
| 空 PSK 启动 → 生成并落盘 | 横幅打印路径，文件 **64 字符** ✓ |
| 第二次启动复用上次那把 | 横幅措辞是「上次生成的」，未重造 ✓ |

第二条顺手把「重启复用」这条性质在生产里也验了——上一轮被中断的容器已经生成过，
这一轮直接复用。

**④ 插件侧 D-112 未部署（诚实记一笔）**

插件源码改了、测试 33 过，但**跑着的引擎用的是 `.app` bundle 里的编译产物**。
要生效得跑 `scripts/build-dist.sh` 重打整个 App——而 vendor 树里还有**别人 25 处
未提交改动**（`agent-stock-sys-schedule`），重打会把它们一起烤进正在跑的引擎。
没做，也不建议现在做；要么等那批改动落地，要么就手工改 bundle 里的编译产物
（会与源码漂移，下次真构建自动纠正）。当前配置本身是对的，守卫是纵深防御。
