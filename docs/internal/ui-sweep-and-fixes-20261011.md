# UI 全量走查与自动巡检体系（D-089 ~ D-093）

状态：**已落地并提交**（2026-10-11，commit `0b50fc06` 巡检体系 + `20f392aa` D-093 修复）。
触发：一次覆盖 9 个界面 + 全部子表面的真机走查，挖出 5 个「只有人看才能发现」的问题。

---

## 0. 为什么要写这份

那次走查之前，App 侧的 56 个测试文件看着绿，但漏掉了 5 个真机可见的 bug。它们的
共同特征不是「难测」，而是**从来没被列成一条断言**：

- 任务页转圈——测试只喂过「引擎正常返回」，没喂过「流带着错误结束」；
- 轨迹横幅数字颠倒——测试断言横幅存在，没人断言它的数字对不对；
- 回底钮落空——测试用短列表，没有「一个气泡比视口还高」的场景；
- 工具名消失——测试 fixture 本身就把契约写错了（见 §5）。

所以这次不只是修 bug，而是把「怎么保证下次不漏」也一并做出来：一个清单驱动的
自动巡检体系，并把它接进 CI。

---

## 1. 巡检体系

### 1.1 核心定义：界面 ≠ Activity ≠ tab

界面 = **一屏上所有分叉的笛卡尔积**：

```
状态维度   ×  子表面维度
(空/有数据/长文本/错误)  ×  (工具行展开/思考块回看/展开全文/详情/筛选态/分页…)
```

D-089/D-090 四个 bug **全部藏在子表面**里——「页面能打开」与「页面是对的」是两
回事，只测前者等于没测。

### 1.2 三个文件（`app/test/ui_sweep/`）

| 文件 | 作用 | 规模 |
|---|---|---|
| `ui_inventory.dart` | **界面清单**——覆盖面的唯一来源 | 18 个界面状态 |
| `ui_sweep_test.dart` | 清单驱动巡检：渲染/关键文案/子表面**双向**可达 | 22 例 |
| `typography_test.dart` | 排版与可点面积规则 | 21 例 |
| `regressions_test.dart` | 本轮 5 个 bug 的行为守门 | 7 例 |

**清单是覆盖面契约**：新增界面不登记 = 从此无人巡检。「以为已经检查过」正是上轮
漏检的成因，所以清单不是便利清单，是守门契约。

### 1.3 三段式构造（逼出来的，不是设计洁癖）

```dart
prepare(kit)        // 造 fake/controller（必须在 testWidgets 体内，落在真异步区的
                    //   controller 收不到 pumpAndSettle 推进的时钟）
build(ctx, kit)     // 接上界面，拿得到 context/L10n
afterFirstPump(kit) // 订阅建立**之后**才能做的事（往 broadcast StreamController
                    //   推帧、答 RPC）
```

少了第三段，界面永远停在空态——而空态恰好是巡检最容易误判成「通过」的地方。

### 1.4 弹层与子页也在清单里

`showModalBottomSheet` 这类界面没法靠 `build()` 返回一个 widget 来「呈现」——
它需要宿主 context 并在路由里推一层。所以 [UiSurface] 单列了 `openSheet` 钩子，
在首帧之后调用。**不这么做的话，这类界面会被清单静默漏掉**：agent 预设面板
藏在顶栏 `+` 背后、team 页藏在「成员」图标背后，真机按 tab 走一遍根本碰不到，
「巡检覆盖了所有界面」那句话就是假的。

还有一个坑：弹层类断言必须**钉住语言**。巡检宿主默认 zh，面板里 broken 预设的
标记渲染成「配置损坏」——拿英文去断言会得到「找不到元素」的假失败（D-052 的老坑）。

### 1.5 排版规则的误报校准（每条都真误报过）

规则只取**客观**项；审美判断留给真机走查。但每次跑都打印字号分布——**静默通过
等于没检查**。这些豁免不是放水，是让规则可信：

| 豁免 | 原因 |
|---|---|
| 按钮 / AppBar 内部 Text | 样式来自 ButtonStyle/AppBarTheme，**不写 style 才是标准姿势** |
| 0×0 与空/零宽 RichText | 进度指示器内部也有 RichText，实测带 44pt/56pt 字号（绘制参数，非排版） |
| PUA 码位（0xE000–0xF8FF） | icon font 图标字号本就是 20/44/56，它们**是**图标不是文字 |
| 正文下限 9.5dp | 全库既有约定（等宽时间戳/元信息）；往上提到 10 是**视觉改版**，不该由巡检顺手改 |

---

## 2. D-089 · 任务页把流错误吞成永久转圈

**真机症状**：任务页无限转圈（9:18 与 9:39 两轮）。引擎直连探针实证
`job/list` 开流即回 `{"type":"rows","jobs":[]}`——引擎正常，是 App 把帧丢了。

**根因（两层叠加）**：

1. `jobs_pane.dart` 的错误过滤只认 `EngineRemoteError`：
   ```dart
   if (!mounted || e is! EngineRemoteError) return;   // MuxStreamError 被静默丢弃
   ```
   而**唯一会让 job/list 停摆的那种错误**恰恰是 `MuxStreamError`（引擎拒开流、
   帧带错误结束）。
2. 无超时。流不报错也不来帧时，`_loading` 永远是 true。

**修复**：任何流错误都落到错误卡片（`MuxStreamError` 自带 `toAppError()`，走全局
同一张错误码表）；加 12s 首帧闸——引擎的 job/list 开流即 yield rows，「一直没
第一帧」只可能是链路断了。

**真机复验**：显示「该会话没有任务」空态，与引擎直连 `rows: []` 一致；logcat 无
follow-contract 违规。

**方法论沉淀**：**扫错误只认一种异常类型 = 该分支永远没测过**。`MuxStream.forTesting`
原本没有 errors 缝 → 这个分支一行都测不了。修 seam 时优先给 `forTesting` 加
errors/item 两个通道。

---

## 3. D-090 · 回底钮 + 轨迹窗口（一个提交两个 bug）

### 3.1 回底钮落进空白区

**真机症状**：列表里有超视口高的展开气泡（「展开全文」点开的长文）时，点「回到底
部」——一次落进**纯空白区**（视口什么都没有），一次**停在距底一屏处**而 ↓ 钮还亮着。

**根因**：`chat_pane.dart` 的 `_scrollToEnd()` 只做一次
`animateTo(_scroll.position.maxScrollExtent)`。**懒加载 ListView 的
`maxScrollExtent` 是估算值**，一个超视口高的展开气泡就让估算与真实布局差出好一屏。

**修复**：动画结束后重查真实落点，没到底就再跳一次；补跳次数有界（避免布局真不对时
无限抽搐）。

**真机复验**：一次点到真底，最后一条完整可见、↓ 钮消失、无空白区。

### 3.2 轨迹窗口：横幅三重失真

**真机症状**：横幅「窗口只保留最近 **11** 条记录（更早的 **80** 条已丢弃，可向上
加载）」，且列表顶部是 `system/message` / `user/message`（会话**最早**的记录）。

**根因（三个独立错误叠加）**：

1. **数字颠倒**：实参 `(maxRenderedRows=80, truncated=11)` 按位置传给生成的签名
   `(dropped, kept)` → 两个 int 安静交换。
2. **方向相反**：预算从**最老**的轮次开始消耗 → 实际保住最老 80 条、丢掉最新 11 条，
   与「只保留最近」文案相反。真机上会话末尾的记录在轨迹页根本看不到。
3. **空头支票**：「可向上加载」按钮只在 `hasEarlierHistory` 时渲染；且 `loadEarlier`
   只 prepend 更早页，永远救不回被截掉的**新**尾部。

**修复**：横幅实参按签名 `(dropped, kept)` 传；记录表先摊平再**保留最新**
`maxRenderedRows` 条。

**真机复验**：横幅变「保留最近 80 条（更早的 11 条已丢弃）」，列表顶部是第 15 号
记录（最早的**保留**项），裁剪方向正确。

---

## 4. D-092 · 重连后对话静默停更

logcat 实证：`[chat] journal error: EngineRemoteError(gateway/protocol: session
stream violated the follow contract)`。mux 重连后重开 follow 收到的首个 snapshot
被「second snapshot」守卫误杀（`_raw` 已指向新流、非 detached，re-baseline 例外不
生效）。

**真机复验**：重启 App → 隧道自愈 → 会话恢复 → 内容与思考 chip 正常渲染，全程
logcat 干净。

**（附带发现，未修）**：重启 App 后控制台**不恢复上次会话**，要手动从选择器挑一个。
会话恢复不在本轮改动范围，记为体验缺口待立项。

---

## 5. D-093 · 工具调用不显示工具名（本轮最隐蔽的一个）

**真机症状**：对话页每条工具调用只剩「工具调用 + 参数摘要」，工具名消失；而**轨
迹页照常显示** `mcp__demo__lookup` / `todo_write`——同一份数据，两屏
不一致。

**根因（引擎契约 vs 代码）**：deepseek-harness 的 `SessionEventMap` 定义

```
'tool/result': { turn, step, message: ToolResultMessage, error?, meta? }
ToolResultMessage.toolCallId   ← callId 在这里，顶层没有
```

`chat_controller.dart` 从顶层 `dataObject['callId']` 读 → 永远 null → 前向记录
`toolCalls[callId]` 匹配不上 → name 落到默认 `'tool'` → UI 又把 `'tool'` 这个占位值
过滤掉。两处静默叠加，症状就是「名字不见了」。轨迹页读 `data.name` 所以不受影响。

**更深一层：假绿测试把 bug 一起编码进去了**。`console_screens_test.dart` 里两条
用例的 fixture 恰恰把 callId 写在顶层——代码读顶层键时它们是绿的，真机上却是空
的。已按契约改正。

**修复**：改读 `message.toolCallId`。新增守门用例**只按契约构造** tool/result（不带
顶层 callId），任何人改回旧读法立刻红。做了「回退即红」验证：回退修复→红，恢复→
绿。

**真机复验**：工具名恢复，与参数摘要组成「全名 · 摘要」两段式显示。

---

## 6. 测试可达性缝（随巡检一起补的基建）

- `MuxStream.forTesting` 增加 `errors:` 缝（此前 job/list 流错误通道**完全不可达**）。
- `FakeEngineGateway` 增加 job rows 注入、流错误注入、合规 job 行 fixture
  （引擎 zod 是 strict，fixture 缺字段不是「更瘦的卡片」而是「引擎会拒的帧」）。
- golden 打 `@Tags(['golden'])` + `dart_test.yaml` 描述，CI 排除。macOS 录的基线在
  Linux 必红，长期红的检查等于没有检查；本地全量仍跑，保留漂移检测。

---

## 7. CI 接入

此前 CI 只有 `server-client / plugin / secrets`——**App 的 400+ 测试从未进过 CI**。
新增 `app` job：

```
flutter analyze → core API 契约 → UI 巡检（单独点名，日志里能一眼看到覆盖面）
                → widget 测试（--exclude-tags golden）
```

Flutter 版本钉到与开发机一致（3.47.6）：同一个版本的生成件与渲染行为才可比，否则
CI 的失败原因会变成「版本不对」而不是真正的回归。

---

## 8. 验证总账

| 项 | 结果 |
|---|---|
| 巡检套件 `test/ui_sweep/` | **50/50**（含 5 个 bug 的守门） |
| app 全量 `--exclude-tags golden` | **431 全绿** |
| 唯一红（本地全量） | `machines_list` golden 环境性漂移（本轮未碰该代码） |
| core API 契约 | **184/184** |
| `flutter analyze` | 全清 |
| `scan-secrets.sh` | 328 文件 clean |
| 真机（Xiaomi） | D-089/090/091/092/093 **逐项复验通过**，logcat 干净 |

---

## 9. 给下一位的三条纪律

1. **新界面必须进 `buildUiInventory()`**。忘了登记 = 这个界面从此无人巡检。
2. **fixture 的键位形状必须来自第一方契约**，不是「代码现在这么读」。D-093 里两条
   测试因为 fixture 写错而长期假绿——护栏跟着代码一起错，等于没有护栏。
3. **修完必做「回退即红」验证**。只跑「现在是绿的」证明不了守门有效。

---

## 10. 追加：第二轮走查（同日下午，D-094 ~ D-098）

目标：验证「智能体团队」页（用户点名）。目标会话 `job-weekly-20261011-030055`
（4 个子代理）。**team 页本身零缺陷**（布局、换行、mode 点、只读标记），但链路上
挖出五个洞，全部修复并有守门（`test/ui_sweep/team_regressions_test.dart`，7 例）：

| ID | 一句话 | 修在哪 |
|---|---|---|
| D-094 | 子代理会话地址 `(parent, child)` 的 parent 被填成 child 自己 ⇒ 引擎回 `subagent/unauthorized`，点子代理必失败 | `chat_controller.dart` `open(parentSessionId:)` |
| D-095 | journal 错误只认 `EngineRemoteError`；且 `_error` 无消费者——错误必须落 `ErrorNotice` 气泡才可见 | `chat_controller.dart` journal 错误订阅 |
| D-096 | 子代理徽标不在 `ChatController` 的监听者里，count 永远停在快照前的 0 | `console_page.dart` 徽标包 `ListenableBuilder` |
| D-097 | 页脚说「只读输出」，而引擎 170 条 catalog 实测全是 continuable（可写） | arb + 生成件改文案 |
| D-098 | 工作区注册表失败屏没有 Scaffold：无标题、无返回、无重试，且流死了重进也没用 | `workspace_picker_page.dart` + `WorkspaceRegistryController.retry()` |

**两条方法论级别的收获**（比五个 bug 本身更值钱）：

1. **「扫错误只认一种异常类型」这个坑本轮第二次出现**（D-089 jobs_pane、D-095
   chat journal）。修一处必须按类型把全仓流消费端扫一遍，否则永远还有下一个。
2. **临时探针日志定位链路**：`engine_mux.dart` 加 4 处 `print`（入帧/出帧/排队/
   非字符串帧）+ 真机 logcat，5 分钟钉死引擎回了 `subagent/unauthorized`——
   事后 `git checkout --` 一键回滚。比反复猜测快一个量级。

测试侧新坑（下次直接绕开）：`testWidgets` 的 FakeAsync 区里
**`await Future.delayed(Duration.zero)` 会把测试吊死**（真实定时器永不触发）；
纯 `test()` 里同句没问题。等流事件用 `tester.pump` 有界推进。
## 11. 追加：第三轮走查（同日晚，D-102）

**现象**：子会话对话页点过「回到底部」之后整条列表手势锁死（滑动无反应、再点回底
也没用，切 tab 回来即恢复）。CPU 3.4%、无 ANR、logcat 无 flutter 异常——第一次
遇到「无异常、无日志、纯手感死」的缺陷。

**病根**（`chat_pane.dart`）：自动贴底与用户手势抢同一条滚动位置。

| 环节 | 旧写法 | 后果 |
|---|---|---|
| 贴底开关 | 靠 ±80px 阈值**事后**判断 | 手指刚落上列表（滑出不足 80px）时跟随仍开着 |
| 自动贴底 | 每次 notify postFrame `jumpTo(max)` | 密集事件流下落在手势中途，打断 drag |
| 回底 | `animateTo` + 递归补跳 | 被 jumpTo 打断 → `whenComplete` 立刻重排 → 状态机自转 |

**修法**：手势开始即 `_dragging`（`ScrollStartNotification(dragDetails != null)`）
并强制退出跟随、postFrame 跳底加 `_dragging` 守卫、回底改同步 `jumpTo`
（D-090 的懒加载估算问题由 postFrame 有界重查兜住）、回底钮在手势中不显示。

守门：`app/test/chat_autoscroll_test.dart` 2 例（app 全量 447 → 449）。

### 这一轮最值钱的收获：假绿的两种形状

第一版守门在旧代码上也是绿的。两条原因都是「fixture 与真实机制不符」：

1. **往已有气泡追加内容不会让懒加载 ListView 的 `maxScrollExtent` 增长** → 拿
   「离底距离」当断言基准是空断言。改成**不变量**断言：手指往下拖 pixels 只许
   变小（自动贴底只会把它往上拽）。要真让列表变高，得推**新 durable 记录**
   （= 新 item）。
2. **`ChatController._scheduleStreamPaint` 把 notify 延后 48ms** → 测试只
   `pump()` 零时长时通知根本没发出，「UI 应该更新了」的断言全是摆设。
   **凡是等异步通知的断言，一律 `pump(100ms)` 推进时钟。**

补一句：`_dragging` 一旦也参与按钮显隐，抬手时就必须强制重画——否则
`_followBottom` 已是 false 时 `_setFollowBottom` 不会 setState，回底钮永久停在
「手势中」的隐藏态，**用户在列表失灵时连逃生出口都没了**。这个缺陷是测试逼出来
的，不是读代码想出来的。

纪律复述：**修完必做「回退即红」**——把修复改回旧写法跑一遍，守门必须红；
本轮第一次回退验证就暴露了「守门根本没咬住」。
