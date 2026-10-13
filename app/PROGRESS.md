# dsh-remote App · PROGRESS

> 执行日志（计划：docs/app-implementation-plan.md）。每批任务追加一行；
> 决策编号 D-xxx。任何新会话从这里无损续作。
>
> **进度与问题的可读总结：`docs/app-status.md`**（接手者先读那份；本文件是逐条流水）。

## 环境事实

- Flutter SDK **未安装**（机器无 flutter，仅 dart 3.9.4 via Homebrew）→ M0 以纯
  Dart 核心包推进（D-002）；Flutter 壳 = M1 前置项，安装建议见门 0 汇报。
- 沙箱限制：`~/.pub-cache` 改名写被拦 → 测试/构建统一带
  `PUB_CACHE=$REPO/app/.pub-cache`（.gitignore 已覆盖）。
- `pnpm build` 产物已存在（server/dist）——集成台直接可用。

## 决策日志

- **D-001**（T0.2）引入 `package:crypto`（dart.dev 官方、零传递依赖）实现
  HMAC-SHA256——纯 Dart 无内置 HMAC，手写密码学不可接受。跨语言互锁：测试向量
  由 Python stdlib 独立计算后硬编码（signed_url_test.dart `_vectorHash`）。
- **D-002**（T0.1）Flutter SDK 缺位下先行创建 `app/packages/dsh_remote_core`
  纯 Dart 核心包（凭证/网络/域逻辑），Flutter 壳就位后以 path 依赖接入——
  与设计 §6 的 `app/lib` 布局对应关系：core 的 `lib/*` 即未来 `app/lib/*` 的
  UI-free 部分，不产生返工。
- **D-003**（T0.5）**pinning 主路径定案**：`WebSocket.connect(url,
  customClient: pinnedHttpClient)` —— wss 握手走 customClient 的
  `badCertificateCallback`（实测通过，含拒绝语义 fail-closed）；备选
  `HttpOverrides.global`（读用 `.current`、写用 `.global=`，Dart 3.9 API）。
  TOFU pin 表按回调入参 host 查表，HTTP/WSS 一套逻辑。
- **D-004**（T0.3）集成测试台的隧道端为"迷你数据面客户端"（http.req 转发 +
  ws.upgrade 桥接），帧形状逐字段抄自 client/src/tunnel.ts 权威实现——它同时
  是隧道协议的第三方契约测试。

- **D-005**（2026-09-30 深夜→10-01）Flutter SDK 安装在沙箱内的完整排障路径。
  brew 装不了（沙箱 heredoc/rename 限制），改为**官方中国镜像直下 zip**：
  `storage.flutter-io.cn/.../flutter_macos_3.47.5-stable.zip`（2.1GB，3.5 分钟），
  解压进工作区 `app/.toolchain/flutter`（.gitignore 覆盖）。六层坑与解法：
  1. zip 无 git 元数据 → 本地 `git init` + 单提交（假 HEAD 会污染 engine 推导，见 3）；
  2. github.com 直连 SSL 失败（墙）、gitee 镜像无 3.47.5 tag → 放弃 git 源，走环境变量；
  3. **`FLUTTER_PREBUILT_ENGINE_VERSION`**（update_engine_version.sh 最高优先级）钉住
     `af7e796e…`（= bin/internal/engine.version 真值），否则工具按假 HEAD 推导出
     40875fd（镜像 404）→ update_dart_sdk.sh 死循环；
  4. 沙箱禁 `sysctl`，update_dart_sdk.sh 的失败兜底判成 x64 → `.toolchain/shim/sysctl`
     只应答 `-n hw.optional.arm64`=1；
  5. zip 自带 `flutter_tools.snapshot` 是 **x64 编译产物**，arm64 VM 拒绝（快照 VM
     配置不匹配）→ 故意写错 flutter_tools.stamp 触发 arm64 重编译；
  6. `~/.pub-cache` 与 zip 内 `.idea`/`.vscode` 点目录沙箱不可写 → env 里
     `PUB_CACHE` 指工作区；解压用 `-x` 排除点目录（unzip 遇不可创建路径会交互中止，
     曾一次静默丢 13570 个文件——教训：**解压后必须对账 zip 清单**）。
  所有设置固化在 `app/.toolchain/flutter-env.sh`（每个变量带来龙去脉注释），
  用法：`source app/.toolchain/flutter-env.sh`。
- **D-006**（T1.4/T1.5）网络层：TOFU pin 决策在**同步回调**里（badCertificateCallback
  是同步契约）→ PinnedHttpClient 以内存 pin 表判词、`onLearn` 回调回写持久化；
  集成台自证：假引擎会照 `Host` 头铸 url-session（端到端测续期闭环），由此揪出
  harness 的 host 钉定语义与真 client 不一致（真 client 钉 publicHost，非引擎地址），
  已修——这正是集成台该抓的回归。
- **D-007**（2026-10-01）视觉验证双轨制：当前模型会话无图像输入能力（read 工具
  [Unsupported Image]，JPEG/PNG 双试）→ 截图发 维护者 人工过目（<media> 原生
  图片消息）+ PIL 像素取证自动断言（主色/组件色/非空白）双轨；宿主支持视觉的
  会话自动恢复单轨。另：i18n 暂以中文字面量先行（intl arb 迁移列为 M1 收尾项，
  与 Golden 同批）。

## 进度

- 2026-09-30 M0 全部完成（门 0 绿灯）：
  - T0.1 core 脚手架 ✓（Flutter 壳挂起 → M1 前置）
  - T0.2 凭证模块 15 单测 ✓（含 Python HMAC 互锁）
  - T0.3 集成台 ✓：真 relay（server/dist）+ 假引擎（Node）+ 迷你隧道数据面
  - T0.4 过闸链路 7/7 ✓（Bearer 200 / 篡改 401 / 无凭证 401 / 未知会话 401 /
    landing 302+cookie / health）
  - T0.5 pinning 5/5 ✓（customClient 主路径 + 拒绝语义 + 全局备选）
  - T0.6 4001 自愈 4/4 ✓（桥接 hello / 双向帧 / 他方着陆 close(4001) /
    同 Bearer 重连自愈 + 轮换后 HTTP 存活）
  - 质量门：`dart analyze` 0 issues；`dart test` 31/31 绿、0 skip
- 待办（M1 前置）：安装 Flutter SDK（进行中——维护者 2026-09-30 23:28 起 brew 安装，
  后台监视器盯守，装好自动续作 doctor+壳）→ `flutter create app` 壳 + 接入 core；
  设备冒烟（模拟器/真机）随壳就位补跑。
- 2026-09-30（深夜批）M1 数据层三项完成，Flutter 独立：
  - T1.3 错误模型 ✓ `lib/api/error_code.dart`：ErrorCode 全表（16 code）→ 呈现层
    （L1–L4）→ 重试策略三向映射 + HTTP/401 三因/relay 帧/传输层四个映射函数 +
    zh/en l10n 键约定；表驱动测试逐行对 §7.2（10 测试）
  - T1.6 relay 契约 ✓ `lib/api/relay.dart`：/dsh-remote/* 五路由形状
    （RemoteSessionSnapshot/TunnelState 五字面量/RemoteSessionInfo/
    RemoteDeviceInfo/RevokeAllResult/UrlSessionMint），字段逐个抄 client/src
    tunnel.ts；防御性 cast；devices=null 降级语义钉死（5 测试）
  - T1.2 会话时钟 ✓ `lib/credentials/session_clock.dart`：三因 401 判别
    （exp 已过→expired；锚点超 30 天→maxAge；否则 revoked；无锚点降级 revoked）、
    芯片色阶（≥6h/1–6h/<1h）、T-2h 续期窗口、30 天第 N 天与进度——时间全注入
    （9 测试）
- 2026-10-01 M1 网络层 + Flutter 壳：
  - T1.4/T1.5 网络层 ✓ `lib/net/`：tofu_pins（pin 表/指纹/三态判定）、
    pinned_http（同步回调上做 TOFU 决策、稳态拒绝自动学习、onLearn 回写）、
    relay_client（Bearer+Accept-Language、429 退避、类型化五路由）、
    events_socket（4001 → healing 立即重连、其余指数退避、状态流）
  - **端到端实证**（真 relay + 假引擎）：续期闭环（mint→新 Bearer→闸门 200）、
    4001 自愈（landing→顶替→healing→重连 hello）；假引擎按 Host 头铸 URL
    的行为揪出 harness host 钉定语义 bug（真 client 钉 publicHost）——已修（D-006）
  - T0.1 壳 ✓：flutter create（android+ios）→ 接入 core（path 依赖）→
    `lib/ui/theme.dart`（设计 token：4px 网格/调色板/最小触达/StatusDot/
    CountdownChip）→ 空态机器页（屏 A/B）→ 2 widget 测试
  - 质量门：`flutter analyze` 0 issue、`flutter test` 2/2；core 61/61、0 issue
  - 待办：T1.1 存储（secure_storage）；M1 UI 屏（B–J）；设备冒烟（模拟器/真机）
- 2026-10-01 **APK 构建链打通**（`flutter build apk --debug` → app-debug.apk 144M）：
  又踩两坑并固化——① gradle dist 默认从 services.gradle.org（改腾讯镜像，
  `gradle-wrapper.properties` 带注释可切回）；② AGP 在系统 TMPDIR(/var/folders)
  写临时文件被沙箱拒（compressDebugAssets 失败）→ `TMPDIR` 与
  `-Djava.io.tmpdir` 指工作区、`GRADLE_USER_HOME` 工作区化。全部在
  `.toolchain/flutter-env.sh`（客户环境不需要这些，属沙箱适配）。
  至此门 1 的"内建质量标准"全部达成；下一步：T1.1 存储 + M1 UI 屏 B–J。
- 2026-10-01（晨批）设备接入 + T1.1 + 配对流 UI：
  - 真机接入：Xiaomi Civi（a0228a1c）经 MTP 切换 + USB 调试授权上线；APK 安装/
    截图/输入全自动。**设备冒烟通过**（像素取证：主色 #0E1316 占 95%、翡翠按钮
    在场、无崩溃）——截图已发 维护者 人工视觉验收（模型会话无视觉输入，以
    维护者 过目 + 像素取证双轨，D-007）。
  - T1.1 存储 ✓ `lib/data/`：MachineEntry（JSON 编解码）+ SecureMachinesRepository
    （flutter_secure_storage，Android 加密 prefs / iOS 默认链）+ MachinesStore
    （ValueNotifier，测试可注入内存实现）
  - 配对流 UI ✓ `lib/pairing/pairing_flow.dart`：粘贴 → 解析（错误文案分级）→
    确认卡（屏 C）→ **先验证后入库**（验证器可注入：valid/invalid/unreachable
    三态；失效=屏 J 文案、不可达=中继不可达文案）→ 落库出机器卡
  - 机器卡三态 ✓ `lib/main.dart`：倒计时芯片（SessionClock 色阶）+ 30 天第 N 天
    + 删除；FAB 添加；空态保留
  - 测试：壳 8/8 绿 + analyze 0（含"死凭证不落库"断言）；core 61/61 保持
  - 设备 E2E 床 ✓ `packages/dsh_remote_core/bin/pairing_bed.dart`（真 relay +
    假引擎 + 隧道注册 + 铸 URL 长驻）+ `adb reverse` 打通手机↔Mac；E2E 脚本
    `.toolchain/e2e_paste.sh` 备好——**等待手机解锁触发**（有安全锁，adb 不能
    绕过，维护者 解锁即自动跑）
  - 两次手数 mid 长度的翻车教训（63/66 位）→ fixtures 已改程序化构造
  - 设备 E2E 状态：**挂起等物理操作**——手机有安全锁（adb 不能绕）+ USB 接触
    不稳（两次掉线弄崩过 adb daemon）+ MIUI 重插会回"仅充电"。维护者 需：
    插稳线（建议换口）→ 通知栏切 MTP →（若弹）允许调试 → 保持解锁。
    之后 `bash .toolchain/e2e_oneshot.sh` 一键完成（内置等待/重挂 reverse/
    启动/输入/双截图）。若 bed 已死（PAIRING_URL 过期或进程不在），先：
    `source .toolchain/flutter-env.sh && dart run packages/dsh_remote_core/bin/pairing_bed.dart > /tmp/bed.log 2>&1 &`
    （URL 有效期 24h；bed 死了重启即可重铸）。设备 E2E 坐标已标定：
    空态主按钮 y≈1420、sheet 主按钮 y≈2300（mint 色行扫描法，1080x2400）。
- 2026-10-01（晨批二）M1 剩余屏 D/G/H + 根壳：
  - 根壳 `lib/app_root.dart`：三 Tab IndexedStack（机器/控制占位/设置）+
    锁屏门（settings.lockEnabled 时启动即锁，屏 H）
  - 屏 D `lib/machines/machine_detail_page.dart`：真快照拉取（RelayClient+
    entry certPin 注入 pin 表）、双时钟（24h 续期 + 30 天 cap 双进度条）、
    设备在场列表、操作区（**逃生舱 v1=复制 24h 链接**（url_launcher 不在
    白名单，剪贴板先行）/断开/重连/吊销（二次确认 AlertDialog））
  - 屏 I `lib/machines/session_expired_page.dart`：三因判别文案
    （AuthCause 注入或本地 exp 推导）+ 重新扫码/删除
  - 屏 G `lib/settings/settings_page.dart` + `data/settings_store.dart`：
    锁/前台提醒开关（secure storage 持久化 JSON）、TOFU 计数、语言、关于
  - 屏 H `lib/lock/lock_screen.dart`：占位解锁门（local_auth 下一批）
  - hydrate 双守卫（测试环境无 channel / 存储损坏 → 空态优雅降级）
  - 壳测试 8 → **16 全绿**，analyze 0。三个真 bug 记录（都成了模式）：
    ① widget 测试里详情页**真 socket 在 fake-async 永不结算**（+loading 无限
    动画让 pumpAndSettle 挂死）→ 注入 seam（`MachineDetailPage.fetchOverride`，
    与配对 verifierOverride 同款）；② 测试环境无 secure-storage channel →
    `MemStorage` 假实现（override 签名须逐字匹配父类）；③ 视口 800×600 太矮，
    屏外按钮 tap 空转 → `scrollUntilVisible`。
- 2026-10-01（晨批三）**门 1 收尾**：
  - i18n 迁移完成（D-007 的临时方案转正）：`l10n.yaml` + `lib/l10n/app_{zh,en}.arb`
    （**111 键 ×2 语言，键集机器校验一致**）+ flutter gen-l10n 生成
    `lib/l10n/generated/`；7 个 UI 文件全部去硬编码（main/app_root/pairing/
    detail/expired/settings/lock）。ErrorCode 16 条文案也进资源表
    （`err_*`，与 core 的 l10nKey 约定对齐）
  - 迁移坑（已成模式）：① `initState` 里禁调 `L10n.of(context)`（inherited 未就绪）
    → 状态存语义、build 时翻译；② ARB 占位符生成的是**位置参数**（`cardSessionLine(a, b)`）；
    ③ NavigationDestination 列表去 const；④ 测试宿主 MaterialApp 必须自己挂
    delegates+locale
  - 当前默认 locale 固定 zh（中文优先），语言选择器（G 屏）落地后切"跟随系统"
  - Golden 基线 ×3（空态 / 机器列表 live+expired / 设置）——设计变更走 diff 评审
  - `app/TESTING.md` v1：自动化矩阵 + 设备冒烟 + E2E 脚本 + 15 屏人工清单（含
    占位标注：相机/url_launcher/local_auth/语言选择器/续期调度）
  - **门 1 自动化侧全绿：壳 19/19（含 3 golden）+ core 61/61，analyze 0**
- 2026-10-02 **门 1 设备 E2E 完成（真环境）**：
  - <relay-host> 部署核验全绿：/health ok、真 Let's Encrypt 证书
    （CN=<relay-host>，效期至 2026-11-29）、无凭证 401 fail-closed、HTTP→HTTPS 301
  - 本机侧曾因 patch.yml 的 `psk:` 为空导致隧道不上线（根因定位）→ 维护者
    补齐后隧道 3 条 ESTABLISHED 在线
  - **配对硬证据**：`/__devices` 显示 `sess_8e9ba811… paired=True ip=<vps-ip>`
    ——手机经 VPS relay 完成 landing，链路 = App → LE TLS → 真 relay 闸门 →
    PSK 隧道 → 本机 dsh 引擎(3080) 全通
  - 结论：**控制台当前是占位页**（M2 未开工）；点机器卡进的是详情页（屏 D）。
    控制台按设计为 Flutter 原生（不用 WebView），WebView/浏览器仅作逃生舱兜
    长尾插件页面（§5 范围 B）
  - 未做：M2 全量（见下）；iOS 完整 Xcode（维护者 机器）
- 2026-10-01（晨批四）**M1 末三小项收口**（门 1 代码侧全部完成）：
  - **相机扫码** `lib/pairing/scan_page.dart`（mobile_scanner 5.2.3，白名单计划
    T1.8）：取景 + 取景框 + 权限/相机错误内联页（回退粘贴入口）；扫码结果走
    与粘贴**同一条**解析/验证路径（一个契约一次验证）
  - **T-2h 续期调度** `lib/services/session_scheduler.dart`：60s tick 遍历机器
    列表，窗口内调 url-session 重铸并原地换凭证（**保留 firstPairedMs 锚点**——
    30 天读数不因续期漂移）；失败保留旧凭证（有效到自身 exp）+ failures
    状态（L3 芯片态，不弹窗）；时间与 mint 均注入 → 4 个单测（窗口内/窗口外/
    失败/已过期不续）
  - **浏览器逃生舱** 升级为真实跳转（url_launcher 6.2.5，Flutter 官方第一方），
    唤不起浏览器自动降级复制（D-008，维护者 可否决；文案入 ARB）
  - i18n 扩到 **121 键**（扫码/相机错误/续期失败等新文案中英同批）
  - **壳 23/23 绿，analyze 0**——M1 代码侧全部完成。门 1 仅剩真机 E2E
    （物理层：USB 接触 + MIUI MTP + 安全锁），脚本 `.toolchain/e2e_oneshot.sh`
    一键待命。

## M2 控制台（2026-10-02 起）

- **D-009（关键纠偏）引擎控制面不是「一方法一路由」的 REST**。dsh 的 `/api` 是
  **保留共享通道**（`client/connection/src/rpc-host.ts:313` 的 `assertChannel`
  显式拒绝在 `/api` 上注册独立通道；`client/connection/src/index.ts:141-155`
  只挂一条 `prefix` 路由交给共享 fetch handler）。真实线格式是 **JSON-RPC 信封
  POST 到 `/api`**，方法名放在 `method` 字段：
  `→ {"type":"client-request","rpcId","method":"session.list","payload":{"args":{}}}`
  `← {"type":"server-response","rpcId","result":{"ok":true,"value":…}}`
  出处：`client/connection/src/rpc-schema.ts:35/43/10`。
  **踩坑记录**：早期按「`/api/session.list` 一方法一路由」设计，实测本机引擎
  对 `/api/session.list`、`/api/session`、`/api` 全部 404 才揪出真相。教训同
  M1 三条：**wire 真值在 zod schema 与路由注册处，不在方法调用处的字面量**。
- **D-010 流走单条 WebSocket 多路复用**。所有服务端流（`session.follow`、
  `session.control`、`$events`）不各占一条连接，而是复用
  `/api/remote.mux`（`gateway/src/stream-protocol.ts:7`），按 `streamId` 分流。
  上行四帧 `open/item/end/cancel`、下行三帧 `item/error/end`，host 用
  `exactKeys` 逐帧校验（line 340）——**多一个字段即整帧拒收**。故把帧构造
  提成 `MuxFrame` 具名构造器，让「精确键集」成为可测产物而非内联字面量。
- **D-011 引擎源码就在本机**。`/opt/homebrew/lib/node_modules/@deepseek-ai/dsh-root/`
  （0.1.7-rc.2，完整 monorepo：packages/api、session、interaction、llm、context、
  subagent、typert…）。契约抄录直接对源码逐行 hand-copy + 记 `文件:行号`，
  不必猜、不必联网。
- 2026-10-02 **T2.1 传输底座完成**（core 93/93 绿，analyze 0）：
  - `lib/api/engine_rpc.dart`：单播 RPC（`/api` JSON-RPC 信封）+ `EngineRemoteError`
    （`{code,message,details}`）+ `SessionEndpoints` 17 个端点名（逐个抄自
    `session-controller/src/index.ts` 的 `@Remote` 装饰器，namespace `session`
    见 line 136）+ `EventEndpoints`（`$events` / `$events/result`）
  - `lib/api/engine_mux.dart`：`/api/remote.mux` 多路复用客户端，
    `MuxFrame` 帧构造器 + `MuxStream` 逻辑流（items/errors/done 三出口）+
    4001 立即自愈（同 §4.1(3) 契约）
  - 测试 `test/api/engine_{rpc,mux}_contract_test.dart` 共 32 例：信封键集、
    `payload.args` 包装、错误三键、6 类畸形响应 fail-closed、17 个端点名不变量
- **待办**：`engine.dart` 域模型（会话/消息/审批/提问/模型目录/上下文）依赖
  契约抄录文档落地；`toAppError()` 暂一律落 `engine.unknown`——真实
  `RemoteErrorCode` 域拿到前不猜映射（D-009 教训）。
- **D-012 重大去风险：mux 链路在现有 relay 上零改动可用**（核查 `server/src`）：
  - `server/src/index.ts:1057` 的 upgrade 分派**已显式放行** `/api/remote.mux`
    （注释记明 dsh 0.1.2 把事件流从 `/api/events.*` 迁到 mux），并与
    `/api/events.*` 并存兼容——**不需要动 `RELAY_WS_BRIDGE_PATHS`**（该 CSV 是
    给第三方插件自有 WS 用的，默认空是对的）
  - `handleEventsBridgeUpgrade`（index.ts:1366）**优先读 `?token=` 的
    url-session Bearer**，cookie 路线兜底；无效则 401 后 destroy
  - `EngineMux` 的 `?token=<bearer>` 连接方式与之逐字吻合
  - 结论：M2 全套控制台流量（单播 `/api` + mux 流）**都在 v1 零改动承诺内**，
    不构成打断协议第 2 类情形
- **本机引擎探测记录**：`127.0.0.1:3080` 上有两个 node 进程——PID 39135 是
  dsh-host-app 内置引擎（`Contents/Resources/engine`），PID 52819 是本仓
  tunnel 进程。两者对 `/api/*` 一律 404，**因此 D-009 的纠偏靠源码而非实测**；
  真机 E2E 需走 VPS relay（门 2 的人工验收项）。
- **D-013 修掉 M1 遗留的"定时炸弹"测试**（M2 开工回归时发现，与 M2 无关但必须修）：
  - 症状：`flutter test` 两个用例从 2026-10-02 起必红，**无任何代码改动**。
    `pairing_flow_test` 的「机器卡出现」找不到 `/30 天`；`machines_list` golden 失配。
  - 根因两层：
    ① `test/factories.dart` 的 `mintTestUrl` 默认铸于**写死的绝对时间**
       `DateTime.utc(2026, 10, 1, 8)`。签名 URL 带 24h 窗口，基线写完第二天
       所有"live"夹具自动变成"已过期"；
    ② 机器卡把**墙上时钟**直接渲染进文案（倒计时 `23h 4m` + 30 天第 N 天），
       golden 就算夹具修好也会随分钟漂移。
  - 修法（遵循 M1 已定的 `fetchOverride`/`verifierOverride` 注入缝惯例）：
    `MachineCard.nowOverride` 静态缝 + `mintTestUrl` 默认改为相对当前时间；
    golden 套件 `setUp` 冻结时钟到 `2026-10-01 09:30Z`。
  - **未重铸基线**：冻结后原 `machines_list.png` 直接通过——证明复现的正是
    原设计意图，比 `--update-goldens` 盲刷有力。
  - 教训已成模式（与 D-006/D-009 同族）：**测试夹具里禁止出现写死的绝对时间
    戳**；要渲染时间的 UI 必须留时钟注入缝，否则 Golden 基线毫无价值。
- **当前质量门**：core 93/93 + analyze 0；壳 23/23（含 3 golden）+ analyze 0。
- **D-014 端点分隔符是斜杠，不是点**（契约抄录推翻了我 T2.1a 的实现）：
  - 我先前把 17 个端点写成 `session.list` / `session.prompt` 之类**点号**形态，
    并用测试把它钉死了。契约抄录回来后自查源码 `api/gateway/src/index.ts:1370-1372`
    ——`endpointOf()` 返回 `` `${namespace}/${method}` ``，**斜杠**。点号形态在
    0.1.7-rc.2 的 wire 上根本不存在。
  - 连带修正：`open` 帧的 `payload` 必须是 `{args}` 包装而非裸参数
    （`client/index.ts:229`），已把包装收进 `EngineMux.open(args:)`，调用点
    无法再写错。`$events/result` 是斜杠（本就对）。
  - `session.export` **本版本无此路由**（全仓无 `@Remote('export')`）；旧笔记里
    的 `/api/session.list`、`/api/sessions.list` 同样不存在——`sessions` 只是
    **客户端本地服务名**（`client/sessions/service.ts`），不是 Remote namespace。
  - **教训（D-009 的续集）**：我先前那句「wire 真值在 zod schema 与路由注册处」
    只对了一半——**真正的路由名在 endpoint 构造函数里，不在装饰器上**。
    `@Remote('prompt')` 只给方法名，namespace 和分隔符都得另找。
    更要紧的教训：**测试把错误契约钉死，等于给错误上锁**。这次那 17 条端点名
    断言原本是防杜撰的好实践，结果成了错误假设的放大器；幸好它是**表驱动 +
    单一常量源**，改一处即全绿——**常量集中在 `SessionEndpoints` 一处，是这次
    能低成本翻盘的原因**。以后断言结构不变式（斜杠/两段/字符集），而非逐个
    硬编码字面量。
- **契约文档落地** `docs/engine-contract-m2.md`（856 行，12 项逐字段 + 传输底座，
  每条带 `文件:行号`）。抄录另揪出三处与设计案假设相反的事实，直接影响 UI 决策：
  ① `contextPressure` / `contextBreakdown` / `tokenUsage` / `subagentCatalog`
     **全是投影不是事件**（61 个 SessionEvent 里没有它们），tok/s 需用
     `sessionStats.decodeTokens / decodeMs` 自算 → 屏 L 改投影驱动；
  ② 审批/提问的应答体是**裸值**（`"allowed-once"` 字符串或 `{answers:[...]}`），
     无外层包装 → 屏 E/P 的回传代码不按通用信封写；
  ③ `ask_user_question` **协议层无 skip 字段**（skip 是 App 自己的 UI 语义）、
     `selectModel` **无「跟随默认」标志**（语义 = `modelSelection.next === null`
     加 `ModelCatalog.default`）→ 屏 K/P 实现前须回看文档再定交互。
- **当前质量门（更新）**：core 165/165 + analyze 0；壳 23/23（含 3 golden）+ analyze 0。
- **T2.1c 域模型完成**（`lib/api/engine_models.dart` + `lib/api/engine.dart`）：
  - `engine_models.dart`：会话（Address/Header/Summary/Hints）、follow 三帧
    （snapshot/event/assistant-stream）、投影集（`Projections` + contextPressure
    / contextBreakdown / tokenUsage / sessionStats / modelSelection /
    subagentCatalog）、`ModelCatalog` 全树、审批、提问（含 `PlanReview` 六条件
    收窄）、`PromptContentPart`、`JobView`。
  - `engine.dart`：`EngineClient` 门面，把域模型绑到 `EngineRpc`（单播）/
    `EngineMux`（`session/follow`、`session/control`、`job/*`、`$events`）。
    失败策略分层：传输故障抛 `AppError`，业务失败**返回** `EngineRemoteError`
    供 UI 内联渲染（L2），只有 `callOrThrow` 抛。
  - 测试 49（域模型语义）+ 19（门面请求形状）例。
- **D-015 投影缺席 ≠ 零值**（契约最重要的一条语义，已写成不变式 + 测试）：
  - `values` 里缺某个 key = 该会话在此 cut 上**不具备该能力**，不是零
    （`api/session-controller/src/types.ts:75-77`）。故 `Projections.has(key)`
    是有意义的 API，**禁止**把缺席折叠成默认值。
  - 同族三坑，都已用测试钉死：`contextPressure` 三个字段**全部可选**（provider
  报 usage 前一律缺席 → 占用环必须能显示"未知"而不是 0%）；`fillRatio` 除零与
  >1 都要夹住；`contextBreakdown` 三段是固定密度估算，**刻意不等于**
  `projectedTokens`，只能当"构成分解"展示。
- **D-016 子代理只读没有 `readOnly` 字段**（协议层完全靠推导）：
  判据是 `mode`——`one-shot` 终态即只读，`continuable` 才可写（Host 侧
  `subagents/prompt` 强制字面量 `'continuable'`，否则 `subagent/not-resumable`）；
  父不在线则 `subagent/parent-unavailable`。已落成 `SubagentMode.acceptsInput`
  与 `SubagentCatalogEntry.acceptsInput`，屏 N 的 composer 可见性直接读它。
- **D-017 plan-review 靠 `intent.approve` **按名**匹配，不按位置**：
  官方客户端六个条件缺一即退回通用问题流（应答编码完全相同，故回退安全）。
  `PlanReview.of()` 已按六条件实现并逐条测（含"approve 名字对不上"→ 回退）。
  同理 `ask_user_question` **协议层无 skip 字段**——跳过 = 把该 id 从
  `answers` 里省略，是 App 自己的 UI 语义，已落成
  `AskUserQuestionAnswerItem.skipped`。
- **一处自纠**：门面的 `value as Map<String, dynamic>` 在 const map 上直接抛
  `type '_ConstMap' is not a subtype`，被"list tolerates a missing items array"
  这条测试当场抓住。已把取值器提成公共 `asObject/asList` 并全线替换——**一个畸形
  信封绝不该掀翻会话屏**，与 engine_models 的降级策略一致。
- **T2.1d 错误映射完成**（`toAppError` 不再一律 unknown）：
  - 新增 8 个控制台域 `ErrorCode`：`engineSessionGone` / `sessionWriterHeld` /
    `sessionAgentBusy` / `subagentReadOnly` / `modelUnavailable` /
    `engineUnsupported` / `engineUnavailable` / `engineCancelled`。
  - 映射表逐条抄自契约 §11.2 的真实 code 域（3 基座 + 19 gateway + 17 session
    + 8 subagent），**只教有独立用户动作的码**；其余一律 `engineUnknown` 且
    `rawMessage` 原样带出——**不为没教过的码编文案，也绝不静默吞掉**。两条
    测试钉死：`a mapped code never leaks as engineUnknown`（加了表行忘了加
    switch 分支就红）+ `unrecognised codes fall back but are never swallowed`
    （24 个未映射码逐个断言仍原样上报）。
  - `session/writer-held` 单独成码是**两端接力**的正常态（web 端正在编辑），
    L2 内联卡 + 自动退避，不是故障。
  - `gateway/cancelled` 给独立码是为了让 UI **抑制**它（`isSilentError`）——
    重连/用户退出时的取消不是失败，渲染出来是噪音。
  - HTTP 状态并入同表：404→gone、413→payloadTooLarge、5xx→internal；
    **401/403 刻意不映射**（三因判别在上游 SessionClock，门面不替它下结论）。
  - 文案 121 → **130 键**（zh/en 同批），新增 `lib/ui/error_copy.dart`
    （`errorCopy` / `errorDetailLine` / `isSilentError`）——错误层只出码，
    **码变文案只在这一个地方**。
  - 新增 `test/error_copy_linkage_test.dart`（9 例）：穷尽性、双语非同一份、
    不泄漏裸 wire 码（匹配命名空间形态而非裸斜杠——中文「二维码/链接」本就该
    有斜杠，我第一版断言写太粗被它当场抓到）、文案长度上限。
  - 新增 `.toolchain/check_arb_keys.py`：zh/en 键集机器校验——缺一个键是
    **静默的单语言运行时故障**，不是编译错误。
- **待办**：无（T2.1a–e 全部完成）。
- **T2.1e 集成床完成**（假引擎实现 M2 最小集 + 24 条端到端契约测试）：
  - `tool/fake_engine.mjs` 扩到 M2：共享通道 `POST /api/<endpoint>`（JSON-RPC
    信封）+ `WS /api/remote.mux`（多路复用逻辑流）。**关键是它按真引擎的严格度
    实现**——信封 `exactKeys`、`payload` 恰好 `{args}`、`args` 键必须逐字匹配
    端点声明（多一个 → `gateway/arguments-invalid`）、流端点当单播调 →
    `gateway/signature-invalid`、单播端点当流开 → 同码、路径与信封 `method`
    不一致 → `gateway/bad-request`。**宽松的假引擎只会让真引擎挂的测试通过**，
    那它就不是契约测试而是橡皮章。
  - `test/integration/engine_control_plane_test.dart` 24 例，穿过**真 relay**
    （闸门 + PSK 隧道）打到假引擎：会话 CRUD、prompt→follow 事件落流、
    投影在场语义、模型目录、selectModel 归一化、多路复用同 socket、
    审批/提问 waterfall 全程往返、任务三态、子代理只读拒绝、闸门对 M2 面
    同样生效（无凭证 401）。
- **D-018 集成床一次揪出三个单元测试永远抓不到的 bug**（这是 T2.1e 的真正价值）：
  ① **路径错了**：我以为共享通道就是 `POST /api`，实际 client 拼的是
     `` `${channel}/${endpoint}`.slice(1) ``（`client/connection/src/client/rpc.ts:48`）
     → `/api/session/prompt`；relay 的 `/api/*` 通配**不匹配无尾斜杠的 `/api`**，
     打过去直接 404。**单元测试全绿是因为假 relay 不校验路径**。
  ② **schema 转换错了**：`EngineMux` 直接拿 `http://` origin 喂
     `WebSocket.connect`（后者只认 ws/wss），静默陷入 connect→reconnect 死循环。
     改 `endpoint` getter 做 http→ws / **https→wss** 映射（生产 origin 是
     https，不转则线上必连不上），三条测试钉死。
  ③ **集成台丢 body**：harness 的 `_fulfilHttpReq` 没转发 `http.req` 的 `body`
     （权威实现 `client/src/tunnel.ts:673/775` 有）。M1 只发 GET 所以一直没
     暴露，M2 第一个 POST 就 400。已补转发。
  **教训已成模式**：**假实现必须和真实现一样严**，否则集成床测的是假象；
  而「单元全绿 + 集成全红」几乎总是说明**测试替身太宽松**，不是被测代码有鬼。
- **D-019 mux 的两处静默失败模式已堵死**：
  - 连接未建立时 `open()` 的帧原先被 `_sendFrame` **直接丢弃**——对
    fire-and-forget 的 API 来说这是最坏的失败方式（调用方干等一个永不到来的
    首帧）。改为**入队 + 首次 `open()` 惰性启动**，断链时清空队列（不重放过期帧）。
  - `MuxStream.items` 吐裸 JSON，缺一层类型化解码与协议校验。新增
    `SessionEventStream`（`engine.dart`）：解成 `SessionFollowFrame`，并把两条
    硬约束落成代码——**snapshot 恰好一次**、**assistant-stream `revision` 必须
    严格 +1**（跳号即判定流已失同步，直接停流让调用方按已知游标重开，
    `client/transport.ts:206-215` 同样的处置）。
- **一处测试自纠**：广播流不重放——先 `.items.first` 吃掉 `ready` 帧再订阅，
  后续 waterfall 帧会**静默丢失**，症状是 flaky 而非真失败。改成单次订阅
  收集全部帧（`_EventSink`）。这类「测试自己制造假阴性」的模式要警惕。
- **当前质量门（更新）**：core 203/203 + analyze 0；壳 32/32（含 3 golden）
  + analyze 0；ARB 130 键双语一致。**T2.1 整批关闭。**
- **T2.2/T2.3 会话域 + 对话 UI 完成**（控制台从占位页变成真页面）：
  - core：`engine_gateway.dart` 抽 `EngineGateway` 接口（UI 只依赖接口，
    测试用假实现；`EngineClient implements`），`SessionEventStream` 拆
    `fromSource`（已解码帧）/ `fromWire`（裸 JSON）——**JSON 边界收敛到一处**。
  - 壳：`console/console_page.dart`（机器芯片 + 对话/任务/主机分段 + 会话入口）、
    `console/sessions/sessions_page.dart`（**屏 M**：子代理缩进挂父、孤儿提升不
    丢、空态说明两端接力）、`console/chat/chat_controller.dart`（journal +
    投影 + waterfall 生命周期）、`console/chat/chat_pane.dart`（**屏 E**：气泡流
    / 工具节点 / 审批卡 / 计划审批卡 / ctxbar / composer）、`console/
    inline_error_card.dart`（L2 错误卡三段式，屏 E/M 共用）。
  - 文案 130 → **164 键**（zh/en 同批），ARB 键集机器校验通过。
  - 测试：`test/fakes/fake_engine_gateway.dart`（内存网关，记录所有出站调用）+
    `test/console_screens_test.dart` **29 例**，含 T2.3 DoD 的回传断言——审批
    允许/拒绝送**裸字符串**、计划批准/拒绝送**裸 `{answers:[…]}`**、clientId
    回显、只读子代理**没有 composer**、发送失败落 L2 内联卡。
- **D-020 控制台改为惰性挂载**（顺手修掉一个真实的移动端缺陷）：
  `IndexedStack` 会**预先构建**所有子页，于是用户停在「机器」页时控制台已经
  拨号并持有 WebSocket——为一个没打开的屏耗电耗流量。改为首次切到该 Tab 才挂载
  （`_consoleMounted` + GlobalKey 保住挂载后不重建）。M1 的四个壳测试当场变红
  正是这个 bug 的副作用（测试环境无 channel → `WebSocket.connect` 抛
  "Mocked response"）——**又一次「旧测试变红 = 真缺陷」**。
- **D-021 投影基线只有一个来源：snapshot**（`chat_controller.open`）：
  原先 open() 里额外调 `session/projections` 与实时到达的 snapshot **竞态**，
  上下文环在两个 cut 之间跳。契约上 snapshot 自带 `projections` 基线（带
  `asOfSeq`），故删掉这次冷读——**基线缺席就渲染「上下文 未知」，绝不用 0% 顶替**。
- **一条 widget 测试纪律（与 M1 同族，值得固化）**：
  controller 若在 `setUp`（真 async 区）构造、事件在 `testWidgets`（fake-async
  区）推送，回调落在 `pumpAndSettle` 不会推进的时钟上——症状是**屏幕静默空白**
  而不是失败，极易误判成 UI bug。现在所有控制台测试都在**测试体内**建
  controller、开流、推帧、清尾。
- **当前质量门（更新）**：core **203/203** + analyze 0；壳 **61/61**（含 3 golden
  + 29 控制台例）+ analyze 0；ARB 164 键双语一致。
- **D-022【本项目最重要的一条】契约抄录必须有真引擎兜底**（维护者 问「开发完成
  有没有真机测试」时发现）：
  - **M2 至此零真机、零真引擎验证。** 全部证据是：203 core 单测/契约 + 61 widget
    + 24 条「真 relay + 假引擎」集成。假引擎是**我写的**——两侧同源于同一次误读。
  - 本机 `127.0.0.1:3080` 上一直跑着**真 dsh 引擎**（我此前只探过点号路径，全
    404 就以为引擎不可用，**从未用正确斜杠路径试过**——又一次「没试就下结论」）。
    用正确路径一打，真引擎立刻回我一个 D-014 修正后仍全错的答案。
  - **实测抓到的头号 bug：wire `args` 按「端点声明的参数名」嵌套**，不是扁平
    业务字段。`session/cancel` 发 `{sessionId}` → `gateway/arguments-invalid`
    ("missing \"request\"")；发 `{request: {sessionId}}` → 进到领域层返回
    `session/not-found`。`session/list` 的被忽略参数**保留下划线**：
    `{_request: {}}`。无参端点（`modelCatalog`、`control`、`$events`）收裸 `{}`。
    **除 `modelCatalog` 外，我此前的每一个调用形状都是错的。**
  - 288 条绿灯一条没抓到——因为假引擎被我拍平成了同一个错误形状。**D-018 说
    「假引擎必须和真引擎一样严，否则是橡皮章」，这次的兑现方式是：橡皮章连形
    状一起盖住了错误。**
  - 修法：facade 13 处调用点按括号配对重包 → 假引擎改为同一套 `unwrapArgs`
    规则（并镜像真引擎的**校验顺序**：先 `arguments-invalid` 后
    `signature-invalid`）→ 新增 `test/integration/real_engine_contract_test.dart`
    **9 条常驻真引擎契约测试**（`http://127.0.0.1:3080`，无引擎则 SKIP 打印原因，
    绝不静默通过；全部只读或打不存在的会话，失败在领域层而非启动真实作业）。
  - 顺带修正我自己集成测试里的两处**假断言**：`session/follow` 当单播调、args
    为空时，真引擎先报 `gateway/arguments-invalid`（缺 `request`），不是
    `gateway/signature-invalid`；`session/follow` 对不存在会话回
    `session/not-found` 而非凭空造一个。假引擎已同步这两条真实行为。
  - **教训**：`grep 源码 → 手抄 → 双侧断言` 这条链**只能证明 Dart 与我的抄读
    一致**，证明不了抄读对。**凡是有真引擎可打，就必须有一条常驻真引擎测试**，
    且它必须**独立于**我写的假实现存在。
- **当前质量门（更新）**：core **213/213**（含 9 条真引擎契约）+ analyze 0；
  壳 **61/61** + analyze 0；ARB 164 键双语一致。
- **T2.4 屏 P 通用提问流完成**（`question_answer_state.dart` + `question_batch_card.dart`）：
  - 纯状态机 `QuestionAnswerState`（ChangeNotifier，单选互斥/多选累加/自由文本/
    跳过），**把「跳过=从 answers 省略」与「custom 与 selected 并存」两条协议
    语义固化成代码 + 单测**，而非留给 UI 临场决定。
  - `QuestionBatchCard`：整批渲染，进度「已答 n/m」，全部答完才可提交（协议要求
    一次答完所有 id），「放弃」走 `rejectEvent(ASK_CANCELLED)`（plan-mode 识别该码）。
  - 多选题**额外带 custom 输入框**（契约 §5.2：多选可 custom+已选并存）——这是本轮
    测试逼出来的一个真缺口，最初只在纯自由文本题给了输入框。
  - `answerQuestionWire` 让 UI 直接交 wire map，controller 只负责发——裸值规则
    只在一处落地。
  - 测试 `test/question_card_test.dart` 16 例（状态机 8 + 屏 8）。
- **当前质量门（更新）**：core **213/213** + analyze 0；壳 **80/80**（含 16 屏 P
  例）+ analyze 0（余 3 个 dart3.9 语法 info，非阻塞）；ARB 170 键双语一致。
- **待办**：T2.5/T2.6（屏 K 模型档位 + 屏 L 上下文）→ T2.7（屏 N 团队）→ T2.8
  （屏 F 任务/主机）→ T2.9（开源物料）→ **真机 E2E（维护者 拍板：做完统一验）**。
- **T2.5/T2.6 屏 K + 屏 L 完成**（`console/models/model_picker.dart` +
  `console/context/context_sheet.dart`，顶栏芯片槽位已接上）：
  - **屏 K**：`session/modelCatalog` 全量下发，**App 零硬编码模型清单**；provider
    分组、模型描述、思考档位 chips 全部来自目录，**非推理模型无 reasoning 块 → 不
    渲染任何档位 chip**（而非写死 Off/Low/High/Max）。provider 加载失败隔离在
    failures 区，不影响其余。
  - **「跟随默认」按契约实现**（D-023）：无 `followDefault` 标志位——`next == null`
    即跟随部署默认，UI 显示 `ModelCatalog.default`；用户显式点「使用」才发
    selectModel，且 `reasoningEffort` **省略**即用该模型自身默认档。顶栏芯片
    显示引擎**归一化后**返回的选择，不是本地请求值。
  - **屏 L**：占用环 + system/tools/对话三段 + 用量统计。三条硬规则：投影缺席 →
    显示「未知」**绝不画 0% 环**；三段是固定密度估算，**明示不与总量对齐**；
    tok/s 由 `decodeTokens/decodeMs` 自算（协议无此字段）。
  - 测试 `test/model_context_sheets_test.dart` 16 例，钉住「跟随默认」标签、
    档位来自 adapter、缺席≠零值、三段 caveat、tok/s 仅在 decode 窗口存在时出现。
- **D-023「跟随默认」是语义不是标志**（易错点，已成模式）：协议无
  `followDefault` 字段。`modelSelection.next === null` 即「本会话从未选择」=
  跟随部署默认。实现要点：`current == null` 时芯片显示 muted「跟随默认」，
  picker 头部说明当前跟随部署默认；用户点任一模型才固定。
- **当前质量门（更新）**：core **216/216**（含 9 条真引擎）+ analyze 0；
  壳 **96/96**（含 16 屏 K/L 例）+ analyze 0（0 error / 0 warning）；ARB 195 键
  双语一致。
- **T2.7 屏 N 子代理团队完成**（`console/team/team_page.dart`，顶栏徽标显示目录
  条数）：先打真引擎问「目录里到底有什么」，三条实测结论直接改写设计：
  - **目录条目没有 `activity` 字段**（实测 `entry keys: mode, label, id,
    createdAt`，`has activity field: false`）→ **屏 N 不能画每子代理的运行点**，
    契约 §9.1 早写明运行态不上 wire。已改成画 `mode` 派生色点，不编造实时状态。
  - **`label` 是长描述不是名字**（实测中位 27 字符、最长 64，如「盘中盯盘团队·
    实时热点新闻腿：news_scan 未判读快速（≤90min 窗）」）→ 单行截断会吃掉区分
    两个子代理的关键信息，故整段换行渲染。
  - 只读仍由 `mode` 推导（`one-shot`/`unknown` ⇒ 只读），与屏 E 的 composer 同源。
  - 测试 8 例，含「`unknown` 不得当可写」（契约：读历史后才能定，不能替用户猜）。
- **T2.8 屏 F 任务 + 主机完成**（`console/jobs/jobs_pane.dart` +
  `console/host/host_pane.dart`，填补对话页两个占位分段）：
  - 任务页：五态生命周期（`running`→`stopping`→`completed`/`killed`/`failed`）
    收敛成三态卡；`rows` 帧**整体替换**不是追加（测试钉住 job 消失会真消失）；
    `job/kill` 的 `already-finished` 当正常答复而非失败。
  - **主机页是对设计案的一处纠偏**（D-024）：设计案写「host 状态（`/api/events.host`
    ）」，**该事件/路由在 0.1.7-rc.2 不存在**——`packages/host/` 只有目录选择器/
    静态站/插件清单/遥测传输，繁忙会话的投影集里也没有任何 host key（实测 19 个
    投影 key 全查）。**故不编造 CPU/内存/温度**，改用真有的面：
    `pluginInventory/list`（`host/plugin-inventory/src/index.ts:55/70` 的
    `@Remote('list')`）+ 会话数 + 当前模型，并在页脚**明说主机指标不可用**。
- **D-024 主机指标在 0.1.7-rc.2 不存在**（第二次「设计案 vs 真实引擎」纠偏）：
  设计案 §5 提到的 `events.host` 与 `/api/events.host` 在本版本无实现。处理原则与
  D-015 投影缺席同源——**没有就是没有，页面上写明，不用近似值冒充**。
- **当前质量门（更新）**：core **216/216** + analyze 0；壳 **119/119**（含 8 屏 N
  + 15 屏 F 例）+ analyze 0（0 error / 0 warning）；ARB **217 键**双语一致。
- **待办**：T2.9 开源物料 → **真机 E2E（维护者 拍板：做完统一验）**。
- **2026-10-03 06:00 门 2 真机 E2E 第一次尝试 —— 卡在 UI 坐标，非链路问题**：
  - 前置全部就绪：设备在线（`a0228a1c`，Xiaomi Civi / Android 13）；重编 APK
    213 MB 并安装成功；本机真引擎 `127.0.0.1:3080` 隧道 `connected`
    （→ `https://<relay-host>`），活跃 URL 有效到 10-03 17:25；**手机网络正常**
    （`ping <relay-host>` 35ms）；App 在前台无崩溃（logcat 无 FATAL）。
  - 阻塞点：M1 标定的「粘贴流主按钮 y≈2300」失效。约 250 字符的 URL **撑高
    输入框**使按钮下移；`KEYCODE_ESCAPE`(111) 会**关掉整个 sheet**（Flutter modal
    响应 Escape），改 `KEYCODE_BACK`(4) 后位置又与标定不符 → `解析链接` 从未执行，
    引擎侧 `lastSeen` 全程不更新（可观测判据 = 配对校验必须打到 relay）。
  - 副产物：`app/.toolchain/e2e_console.sh`（五步流程 + 每步截图）、
    `e2e_console_forensics.py`（像素取证，本会话无视觉能力的替代）、
    **`e2e_adaptive.py`（按颜色定位按钮：FilledButton 用翡翠 `#34d399`，脚本找最大
    翡翠连通块点击其中心，放弃写死坐标）**——已能定位并点击入口
    （box=(696,1938)-(1035,2091)），sheet 内按钮待调。
  - 结论记录：**这是测试驱动问题，不是产品缺陷**。M2 数据链路由 core 的 9 条真引擎
    契约测试 + 24 条集成测试证明；真机这轮验的是触屏与真实网络。
  - 三个继续方案（详见 `docs/app-status.md` §3.1）：① 调 `e2e_adaptive.py` 时序；
    ② 维护者 看一眼截图给按钮坐标（最快）；③ 给 App 加**仅 debug 构建**的
    `dshremote://pair?url=…` 深链，让配对可被 `adb am start` 直接驱动
    （一劳永逸，但要改 App 代码——**已向 维护者 提议，待拍板**）。
- **当前质量门（更新）**：core **216/216** + analyze 0；壳 **119/119** + analyze 0
  （0 error / 0 warning）；ARB **217 键**双语一致。详见 `docs/app-status.md`。
- **2026-10-03 07:20–08:40 门 2 真机 E2E —— 打通全链路，抓到 1 个真产品 Bug（D-025）**：
  - **D-025（最重要）：TOFU 证书 pin 从未接线，控制台所有连接被自己的 TLS 闸掐死**。
    `MachineEntry.certPin` 字段**有读无写**（4 处读、0 处写）：配对时
    `PinnedHttpClient(learnOnFirstConnect: true)` 学到的指纹存进一次性
    `MemoryPinStore` 后即丢弃；控制台/详情/续期三处都建**空 pin 表**再以
    `learnOnFirstConnect: false` 建 client（`fromStore` 默认值），
    `pinned_http.dart:65-67` 对「无 pin 且不许学」一律 **fail closed 拒绝** →
    控制台的每一条 HTTPS/WSS 都在 TLS 层被拒（真机症状：顶栏黄色告警、
    会话列表/团队/模型全部空、引擎侧看不到设备）。**M1 门 1 之所以绿**：
    配对流自己学 pin 所以配对成功，而详情页/续期的活路径从未被真机验过。
    修法（只动 app，v1 零改动不受影响）：配对 `_verify` 的 `onLearn` 捕获指纹
    → `buildPairedEntry(params, pin)` 写进 `MachineEntry.certPin`（随机器进
    SecureMachinesRepository，零新增存储）；控制台 `pinStoreFor(entry)` 按
    `entry.certPin` 播种（与详情页/续期同一形状）。严格模式全保留：无 pin 仍
    fail closed（重配=刻意的用户动作），cert 变更仍拒绝（`tls.cert_changed`）。
    壳测试 +5（`test/tofu_pin_wiring_test.dart`）。
  - **E2E 驱动问题的真正根因（三个叠加，都不是产品缺陷）**：
    ① **MIUI 搜狗输入法**（浅色主题近 1000px 高）盖住 sheet，颜色定位命中的
       是搜狗的**绿色回车键**而非 App 按钮——「入口按钮 box=(696,1938)-(1035,2091)」
       其实是回车键。解法：切 **ADBKeyBoard**（设备已装
       `com.android.adbkeyboard/.AdbIME`）+ `ADB_INPUT_TEXT` 广播注入，
       从此无键盘遮挡、无转义地狱。
    ② **`adb shell` 吃 `&`**：`am broadcast --es msg <url>` 的参数被拼到手机
       `/bin/sh`，URL 里的 `&` 变成命令分隔符 → 字段只收到第一个参数
       （`?sessionId=…`），本地解析必然失败（红字 `链接格式不对：t/exp…`）。
       修法：参数带设备端单引号 `'…'`。**教训同 D-022：断言要打在真正的对手方**。
    ③ **App 的 FilledButton 是浅薄荷 `#8ED5B2`**（不是 M1 标定的 `#34d399`），
       旧阈值永远匹配不到 sheet 内按钮。
  - **真机 E2E 实测通过项（Xiaomi Civi / Android 13，debug APK）**：
    全新安装 → 粘贴配对链接（v6 驱动，带引号注入 + 像素护栏）→ 解析 → 确认
    → **`onlineWs=1`**（mux WS 经 relay 桥接成功）→ 控制台 Tab →
    `session/list ok=true`（屏 M 会话行渲染）→ FAB 新建会话（引擎
    `session-3c0bf849…` 出现）→ composer 注入中文 → 发送 → 引擎
    **`turns: 1`**（真实 agent 回合启动）→ 事件流 `FollowSnapshot` /
    `FollowEvent` / `FollowAssistantStream` 持续到达 → **屏 E 用户气泡 +
    助手气泡渲染**（用户侧右对齐、助手侧全宽）→ 屏 K 模型选择器（浮层，
    mint 芯片可见）打开并渲染目录 → 屏 N 团队页内容饱满 → 屏 F 任务页/主机页
    渲染（无会话/无任务时是诚实空态）。配对跨重启复验：`install -r` 保留凭证
    后重开 App 直连成功（pin 持久化生效）。
  - **D-026：一元 RPC 无客户端超时 → 无限转圈**。真机实测：经 relay 隧道的一元
    RPC 在 mux WS 桥接时会从引擎直连的 ~0.5s 劣化到 20~30s（引擎直连复现不出，
    relay 侧也非每发必坏；真凶待查，可能在隧道 WS 的帧/请求调度）。此前 App
    没有客户端上限（`PinnedHttpClient.connectionTimeout` 只管建连不管等响应），
    stall 时 UI 永远转圈、没有错误卡也没有重试入口。修法：`EngineRpc` 注入式
    `callTimeout`（默认 35s，**高于 relay 自身 30s `WSS_PROXY_TIMEOUT_MS`**，
    让健康慢请求走 relay 自己的 504、真 stall 才落这里）→ `client/timeout`
    → `ErrorCode.engineUnavailable`（可重试文案）。core 测试 +2。
  - **D-027：载波（mux WS）一断，所有逻辑流被 terminate 且永不重订阅 → 控制台永久失明**。
    断线时 `EngineMux._onDone` 调 `_terminateAllStreams()` 把每个 journal 杀掉，
    壳层没有任何东西去重订阅；表现是**「看起来活着其实是瞎的」**——prompt 仍
    走一元 HTTP 成功（引擎 turns 变 1），但气泡流再也没有帧，UI 空转到天荒地老。
    真机抓包现场：08:34 审批探针 prompt ok=true，引擎 turns=2 落账，手机 0 帧，
    `onlineWs` 已掉 0。修法：载波丢失时**不终止流**——给 `MuxStream` 存下 open
    参数、标记 `detached`，重连成功后 core 侧自动重放 `open` 帧（宿主回一份
    新 snapshot = 已知游标，不是「未知游标静默续跑」）。新增 `MuxCarrier` 抽象
    作为测试缝（生产是 `_WebSocketCarrier`，测试用假 carrier 钉住
    drop→reconnect→re-open 契约）。**真机验证**：关网络 20s → 控制台顶部出现
    琥珀色「连接已断开，正在重连…」横幅（新增 `consoleReconnecting` ARB 键）→
    开网络 → 横幅消失、journal 自动复活（`onlineWs` 计数回升）。core 测试 +3。
  - **D-028（顺手钉住）：4001 立即自愈路径其实是死代码**——`_lastCloseCode` 只在
    `_connect()` 里被置 `null`，`_onDone()` 从不读真实 close code，所以 v3.204
    「设备被顶替」的 heal 分支永远走不到，一律退化成指数退避。D-027 的抽象顺带
    修掉：`MuxCarrier.closeCode` 暴露真实码，`_onDone` 读它，测试用假 carrier
    投 4001 验证零退避立即重拨。core 测试 +1。
  - 副产物（`.toolchain/`）：`e2e_pair_v2..v6.py`（v6 为定版：带引号注入 +
    字段满两行护栏 + 薄荷按钮定位）、`e2e_screen_classify.py`、
    `e2e_dim_scan.py`（低阈值全屏内容图）、`e2e_row_profile.py`、
    `e2e_find_small_green.py`、`e2e_find_cta.py`、`e2e_img_diff.py`、
    `e2e_band_scan.py`、`e2e_dark_on_light.py`、`e2e_color_sample.py`、
    `relay_ws_probe.mjs` / `relay_ws_holder.mjs` / `relay_mixed_probe.mjs` /
    `engine_mixed_probe.mjs` / `engine_busy_mux_probe.mjs`（Mac 侧真链路复现）、
    `ocr.swift`（Vision OCR——**本会话沙箱拦截，暂不可用**）。
  - **D-029（维护者 报障）：添加机器弹窗被输入法遮挡，「解析链接」按钮消失**。
    真机复现（MIUI 搜狗输入法，`mInputShown=true`，键盘占 y1440–2400 共 960px）：
    **全图找不到任何薄荷色像素**——主按钮被顶出屏幕底部，用户根本无法提交。
    根因在 `main.dart` 的 `showModalBottomSheet`：`MediaQuery.of(context)`
    取的是**弹窗外部页面**的 context，那个依赖注册在外层 State element 上，
    而 modal route 是独立子树、其内容不会因外层重建而刷新——**padding 的值在
    sheet 首次构建时就冻结了**，键盘后来弹出多高都不会跟随。加上 `autofocus: true`
    时机不定（有设备开 sheet 时键盘已起，有的还没起），所以表现时有时无。
    修法三条：① 改用 builder 自己的 `sheetContext` 读 `viewInsets`（依赖落在
    route 子树内，随键盘实时更新）；② `AnimatedPadding` 让位移平滑而不是瞬跳；
    ③ 包 `SingleChildScrollView` 兜底——矮屏 + 高键盘时按钮仍可滚动够到。
    **回归测试是真会红的**：把修复回退后 `flutter test` 报
    `Expected: a value less than <1440> / Actual: <2362.0>`，正是真机现象；
    测试用 `tester.view.viewInsets` 模拟 960px 键盘，并断言按钮既在键盘之上
    **又确实可点**（点完出现「确认机器」才算数——按钮存在≠能按到）。
    真机复验：修复后键盘开着时按钮位于 y1284–1392（键盘顶边 1440 之上），
    输入长 URL 后自动上移到 y2118–2226 仍可点击，解析成功无红字。
    教训与 D-022 同源：**「测试全绿」必须验证测试本身能抓住 bug**。
  - **D-030（接 D-027）：`$events` 通道在重连竞态下永久失聪**。D-027 的重放集
    是「open 已落地的流」；但 `$events` 的 open 若在载波断开瞬间还在 `_pending`
    里，会随 `_pending.clear()` 一起蒸发——它从未到达宿主，自然不在任何恢复集
    里，**永远不会重发**。真机表现：journal 复活了（快照到），但审批/提问的
    waterfall 一帧都收不到。修法：`EngineMux` 记录**意图集 `_desired`**（open()
    即登记，宿主 end / 调用方 cancel 时移除），重连后重放意图集而非「曾活集」。
    core 测试沿用 D-027 的假 carrier 三例 + 新增竞态覆盖。真机：重启 App 后
    `$events` ready + waterfall 重放帧到达（此前零帧）。
  - **D-031（维护者 报障）：控制台打开时全是新会话，看不到电脑上正在进行的
    工作**。根因是产品行为：控制台打开时不绑定任何会话（空态 + 只有"新建"FAB）。
    修法：`_loadSessions` 拿到列表后，若当前无打开会话，自动打开最近更新的
    一个（列表按 updatedAt 排序取首）——打开 App 即"继续电脑上最近的工作"，
    屏 M 仍可切换。
  - **D-032（遗留，疑似 relay 侧）：App 的 mux 下行长连接静默**。实证：Mac 探针
    （独立订阅）收到了引擎广播的新 waterfall，**同一时刻手机 App 零帧**，且 App
    侧 socket 被认为健康（onlineWs=1、无重连横幅）。App 侧 D-027/D-030 的重连
    与重放均正常工作（重启后订阅成功并收到 pending 重放），故嫌疑在 relay→App
    的 mux 桥接下行（长连接下帧不再转发）。**需 server/ 侧排查，超出 v1 零改动
    承诺，待拍板**。App 侧可做的兜底（未实施）：周期性重订阅 `$events`——重订阅
    会触发引擎的 pending 重放，即使实时帧丢失也能在下一周期拿到。
  - **屏 P 引擎侧语义实证**（本轮最有价值）：模型真调 `ask_user_question` →
    turn 合法挂起（running=True、turns 不增、updatedAt 冻结）→ `session/cancel`
    作为答案送达后 turns=1、running=False——**「agent 卡住等人类」是引擎的设计
    行为**，手机渲染卡片后作答即可解锁。
  - **屏 P 协议闭环实证（2026-10-03 12:58）**：模型调 `ask_user_question` →
    pending waterfall 广播 → **App 收到并渲染**（waterfall 帧数=2 实证，屏上
    对话+卡片内容实时更新）→ **Mac 模拟作答（正确 schema
    `{answers:[{id,selected:[…]}]}`）被引擎接受 → 模型从挂起中唤醒继续跑**
    （running=True 实时渲染输出）。**屏 P 三要素（收卡/渲染/作答）的协议闭环
    全部打通**。剩：手机上真实手指点击选项（widget 测试已覆盖点击逻辑，真机
    点击等模型配合窗口）；11:50 的实时 waterfall 未到达 App 一帧的问题归入
    D-032 周期重订阅兜底（60s 内可达）。
  - **当前质量门（最终）**：core **222/222** + analyze 0；壳 **127/127**
    + analyze **0 issue**（3 条 info 已清）；ARB **218 键**一致。
  - **屏 P 状态小结**：引擎工具挂载 ✓、模型调用 ✓、waterfall 广播 ✓（Mac 实证）、
    App 订阅+重放接收 ✓（12:03 实证）、App 实时下行接收 ✗（D-032，relay 嫌疑）、
    作答 wire 形状 ✓（App 与引擎 schema 一致；先前 Mac 探针被拒是探针自身形状错）。
  - **D-029 同类问题普查（收尾）**：
    - **屏 E composer 键盘遮挡**：Scaffold 默认 `resizeToAvoidBottomInset` 已
      正确处理——真机搜狗键盘实测发送按钮 y1365-1398，在键盘顶边 1440 之上，
      无需修改。
    - **详情页活数据**：D-025 修复前详情页与续期同样是"假绿"路径（certPin 空 →
      fail closed）。修复后真机实测：点机器卡进详情页，快照数据正常渲染，
      无错误卡；`lastSeen` 打点确认 HTTP 真通（30s 内）。
    - **续期路径**：`session_scheduler` 用 `entry.certPin` 播种（D-025 后已
      填充）；其真实网络环节 `GET /dsh-remote/url-session` 经 relay 实测
      0.11s 返回 200 并铸出完整签名 URL。真机 T-2h 触发时机未验（需等窗口）
      ——已在 app-status.md 如实声明。
    - **三处播种逻辑收敛**（D-025 自身的教训：同一段"三行代码"写了三份才漏）：
      console / 详情页 / 续期统一改用 `data/pin_store.dart` 的
      `pinStoreFor()`，并加**源码级断言**（`no other module rebuilds the pin
      table by hand`）——裸 `MemoryPinStore()` 只允许出现在 pin_store.dart
      （播种实现）和 pairing_flow.dart（配对学习表，语义相反的合法例外）。
      该断言首跑就抓到 pairing_flow 的例外没被排除，写明理由后才收绿。
  - **门 2 剩余**：屏 P 审批/提问**真机往返**（Mac 侧探针已证实引擎会产生审批
    态——`bash` 写文件探针真被执行并落盘 `/tmp/mac_probe.txt`，但当时手机
    恰逢 D-027 断线失明，审批卡没在手机渲染；D-027 修复后需重跑一次手机侧
    审批往返）、**两端接力**（第二台设备/浏览器与手机同引擎互斥验证）。隧道
    一元 RPC 延迟的根因（疑似 relay↔引擎隧道帧调度）需要改 `server/` 或引擎
    侧——**属 v1 零改动承诺范围，待 维护者 拍板**。

## 2026-10-07 · 日志系统（D-077）

- **D-077** 落地 App 日志系统（此前仅 13 处散装 debugPrint，release 包出问题
  无任何现场）：
  - **基座** `lib/logging/app_log.dart`：AppLog 门面（d/i/w/e + CoreLog 缝适配
    `raw`）/ FileLogSink（`app.log` + `.old` 双代滚动，256KB/代，RandomAccessFile
    同步写）/ Redactor 单点脱敏（写入前统一过，调用点免记）/ MemoryLogSink
    测试缝。兑现设计 §7.2「全部错误入本地脱敏日志」+ 隐私表「容量上限滚动
    覆盖；随卸载；不随备份出设备」。
  - **依赖（白名单外新增两条，执行纪律 4 记录）**：`path_provider 2.1.6`
    （原已是传递依赖，转正为直接依赖——cache 目录唯一正规来源，shared_preferences
    给不了文件系统路径）；`share_plus 12.0.2`（OS 分享面板，维护者 指定本轮
    做掉；官方插件，避免自写分享 platform channel）。两者皆 Flutter 官方第一方。
  - **目录选型**：`cacheDir/logs`——Android Auto Backup 默认不含 cache、iOS 不进
    iCloud，「不随备份出设备」零配置满足；代价是系统「清除缓存」会连带清日志，
    对滚动诊断日志接受（换备份排除规则的复杂度不值）。
  - **core 缝**：`packages/dsh_remote_core/lib/log_hook.dart`（CoreLog 静态缝，
    默认 no-op，core 保持零依赖）；relay_client（429 退避重试 / Socket·Handshake
    异常）、pinned_http（TOFU learn/fail-closed/mismatch 三判各一条）、
    events_socket（connected / 4001 healing / 退避重连 / 连接失败）埋点。纪律
    对齐 `server/src/logger.ts`：只打标识符（host/path/attempt），带 token 的
    URL 永不进日志。
  - **接线**：13 处 debugPrint 全迁 AppLog——`[e2e]` 探针为 debug 级，debug 构建
    仍镜像 debugPrint，logcat 工作流（journal 帧计数等）不变；catch 吞错处
    （title-cache/locale/lock）升 warn；ErrorCode 产出点（prompt 失败 / journal
    错误 / 首帧超时 / 模型目录与选用 / workspace 列表与文件打开）补 warn。
  - **UI**：屏 G 新增「诊断日志」页（`lib/logging/diagnostics_page.dart`）——
    等宽逐行查看 + 元信息（字节/行数）+ 复制全部 + 系统分享（带 `.old` 一代）+
    清空（二次确认）；arb 新增 13 键 ×zh/en；settings golden 基线随新入口更新
    （设计变更，diff 已过目）。
  - **测试逮到三个真 bug**（均为首发即坏级别，全在 FileLogSink）：① 首启动
    `length()` 对不存在的文件抛异常 → catch 后 sink 永久 `_failed` 静默——
    整个系统在全新安装上直接哑掉；② 本 SDK `IOSink.flush()` 实现会 close 内部
    流控制器，第二条日志并发 add 即抛 StateError——IOSink 整体弃用，改
    `RandomAccessFile` + `writeFromSync`（顺带更好的崩溃取证：write 返回即落盘）；
    ③ `write()` 把「rotation 进行中 raf=null」误判为「从未打开」，二次
    `_ensureOpen` 双句柄赛跑，rename 输家的行确定性蒸发——`_rotating` 判断必须
    先于 `_raf == null`。判据工程化：`flush()` 进 LogSink 接口（诊断页复制/
    分享/读取前同样需要）。
  - **Redactor 规则**（表驱动测试钉死）：`Authorization: Bearer x` 整段 →
    `Authorization: [REDACTED]`（须先于 kv 规则，否则 Bearer 字样被当值吃掉）；
    裸 JWT 三段式；kv 形态 psk/pairingToken/sessionSecret/token/secret/password/
    authorization/cookie（引号可选，值 ≥4 字符，负向前瞻防止吃自己产出的
    censor）；URL 一律剥 query/fragment。**sessionId/host 刻意不脱敏**——
    server 纪律：日志就是为标识符服务的。
  - **质量门**：analyze 0（app）+ 0（core）；app 全量 361/361；core api 178
    一次跑全绿；core 集成逐文件（沿 D-032 惯例）；新增 core `log_hook_test`
    4/4（纯 Dart 包，用 `package:test` 不用 flutter_test）+ app
    `test/logging/` 12 测（redaction 表驱动 / 滚动 / 缓冲 / 清空 / 页面
    widget）。
  - **Android 构建验证 + Gradle 镜像 shim**：share_plus 12 的 legacy
    buildscript 钉 `kotlin-gradle-plugin:2.2.0`/AGP 8.12.1，gradle-home 缓存
    缺这几件，而沙箱代理对 repo.maven.apache.org 回 403 → assembleDebug 首跑
    即挂。解法：`.toolchain/gradle-home/init.d/sandbox-mirrors.gradle`
    （Gradle 自动执行，gitignore 内，零项目文件改动）追加 aliyun/tencent/
    dl.google.com 镜像。两个坑已写进脚本注释：①只能注 **buildscript**
    仓库——settings.gradle.kts 是 PREFER_SETTINGS 模式，注项目级仓库会让
    flutter-plugin-loader 直接死；②debug APK 构建通过
    （`✓ Built build/app/outputs/flutter-apk/app-debug.apk`），插件注册链
    （path_provider + share_plus）完整走通。
  - **net_stack 集成挂死归因**：本轮两次 300s 超时强杀（签名与记忆条目一致：
    `Cannot add event while adding stream`、flutter_tester 0% CPU），但两次
    都发生在**并行 Gradle 构建抢资源**的窗口；排除负载后，含本改动连跑 3 次
    全过（每次 ~1s），干净 HEAD 无负载也过。结论：是既有随机挂被资源竞争
    放大，非本改动回归。tls_pinning 的「global HttpOverrides 回退」一例仍红
    （此前已立案的已知红，Dart 运行时行为，与本改动无关）。

- **D-078 引擎 RPC 信封一律去壳**（今天最贵的教训，代价是一整天排查）：写
  引擎调用前**必须打一条真实响应 dump 逐字段核对**，或用「传空 args 的零副作用
  探针」读 descriptor 报错。`$events/result` 的 args 是裸对象，多包一层
  `request` 会被网关在描述符分发前拒掉 → 手机审批自始至终没生效过。
  勘误表见 `docs/engine-rpc-errata.md`。
- **D-079 乐观 UI 吞失败**：审批/开关这类「改他人状态」的操作，UI 只能在
  引擎确认后才更新；失败保留原状 + 内联错误。跨进程/跨连接的身份（如
  clientId）失效时，报错通常被静默丢弃——所以失败路径必须自证。
- **D-080 真机 integration_test 会清空 App 数据**：`flutter test
  integration_test -d <serial>` 的安装流程含卸载重装，配对与语言偏好全没，
  不可恢复。只跑专用测试机/模拟器。
- **D-081 清单要按「用户装的包」组织**：引擎的 loader entry 视角有 199 行，
  而 bundle 视角只有 16 行——面向用户的 UI 用后者，entry 收进展开里。

## 2026-10-08 · 真机 L3 验收（三个缺陷 + 一条方法论）

发布前最后一轮真机实跑。计划巡检 15 项，实际在拿不到 UI 的那批里先挖出两个
缺陷——**没有 UI 的证据反而更硬**：崩溃扫描、落库对账、logcat 时间线都不需要
看屏幕，也就不会被锁屏打断。

- **D-083（P1）resume 的首个 `open` 写死了载具**：`stop()` 只关载具不摘 `_ws`，
  于是回前台后第一个 `open` 走「载具已就绪」分支，往刚被关闭的 socket 写帧，
  dart:io **同步**抛 `StateError` 穿出 `open()`；而 `open()` 里首帧看门狗已经
  布防，45s 后弹一个与病因毫无关系的错误卡。真机 20:48 的「会话打不开」就是
  它，那条消息引擎侧从未收到（session 最后记录停在 18:32）。
  触发条件是**「resume 前连上过」**而非「后台够久」——22:54 我解锁后一切通畅，
  正因为那台 App 从未连上过、`_ws` 为 null、帧进了 `_pending`。
- **D-084（P2）TOFU pin 对受信任证书永不学习**：learn 挂在
  `badCertificateCallback` 上，而 dart:io 只在校验**失败**时调它。relay 用
  Let's Encrypt 就走正常校验，回调永不触发，pin 表恒空。
  **语义要写准**：pin 空的后果不是「连接被拒」——受信任证书照样连得通——而是
  **失去对证书变更的额外检测**（私钥泄露后重新签发，App 不会察觉）。
  `data/pin_store.dart` 里「the table is then empty and the steady-state client
  fails closed by design」这句自 D-025 起就在，实际从未 fail closed 过。
- **D-085（P3）英文段栏把 Workspace 折成两行**：整条 tab 栏被撑高一行，
  正在点的 tab 在指尖落下时往下挪半格。中文「工作区」碰不到这个边界，
  所以中文下怎么测都测不出来。

### 方法论

- **假载具抹平真实契约 = 结构性假绿**。D-083 逃过了所有 mux 测试，因为假载具
  的 `addText` 是静默成功的，而真实的 dart:io 在写已关闭 socket 时**同步抛**。
  这和「mock sink 全绿」是同一类错误：fake 必须按真实运行时建模，包括它会
  抛异常的路径。D-083 的两条新用例里有一条专门模拟「未送达 onDone 就死亡」
  （静默死亡），另一条把假载具改成会抛。
- **红测试必须先证明能抓住**。D-085 的测试写完是绿的，我用 `git checkout` 把
  修复退回去跑了一遍，确认它红在 `"Workspace" must stay on one line`，再把
  修复放回来。否则「测试通过」和「测试有用」是两件事。
- **golden 漂移可以用数值指纹当非回归判据**。`machines_list` 又是 0.18%/7764px
  ——与 10-07 记档的数字**逐位一致**，且本次改动未触及 machines 页，于是它不是
  回归。判据要同时成立：数值指纹 + 影响面未触及，缺一条都不算。
- **日志系统会反哺定位**。D-083 是在诊断日志里那条孤零零的
  `first-frame deadline hit (45s)` 上开始的——没有 app.log，这个 bug 只会停在
  「用户说会话打不开」这种无法收敛的描述上。D-077 当天入库是对的。

## 2026-10-10（晚）D-087：流式思考默认收起——移动端惯例改版

- **决策**：D-069 的「思考先于答案实时展开」对齐的是桌面端（Cherry Studio）；
  本 App 是手机，对齐 Claude / ChatGPT 移动端惯例——思考中默认只显示
  pill「💭 思考中 · N 字」（字数实时增长证明活着），点开看实时流、再点收起，
  正文到达照旧收成「已思考 · N 字」。由用户提出并拍板。
- **顺带修掉一个现存小疣**：`showBody = active || open` 让思考流期间用户
  钉住的「收起」失效（被 active 强制展开）。改为 `open`，钉住真正全权。
- **测试**：新增 `chat_thinking_test.dart` 四条（默认收起 / 点开看实时流 /
  自动收成已思考 / 钉住保持展开）；`chat_meta_and_thinking_test` 与
  `chat_typing_indicator_test` 两条旧行为断言改写为新预期。
- **测试基建经验**：流式 token 的重绘按 `_streamPaintInterval`（48ms）合并
  （D-034），widget 测试里推 delta 后必须 `pump(60ms)` 越过窗口，否则 UI
  永远不重建（controller 状态是对的，屏幕是旧的——用「打印 controller 状态
  vs 打印屏幕 Text」两层对比定位）。
- **golden**：`machines_list` 又是 0.18%/7764px，与 10-07/10-10 早记录逐位
  一致、本改动未触及 machines 页——已知漂移，非回归。

## 2026-10-11 D-088：durable 思考回看——「引擎不落盘 reasoning」结论被数据推翻

- **更正 D-069 的平台事实**：解包 4 个现役会话 journal（zstd），reasoning 以
  `assistant/message.content[]` 的独立块落库（223~1300 字，与 tool-call/text
  混排），四种来源全部命中。旧结论「journal 全是纯 text 块」是 0.1.7-rc.2
  代际的实测，对 0.2.0-rc.2（reasoningEffort=max）已不成立。**教训：平台事实
  也要定期对数据复检——落库格式跟着引擎版本走。**
- **App 侧两处接住**：①durable 路径 `_reasoningOf()` 解析 reasoning 块 →
  气泡带「💭 已思考 · N 字」折叠 chip（历史思考可回看）；顺带修掉 pane 里
  `thinking = streaming ? reasoningText : null` 把 durable 行硬性排除的旧假设。
  ②轨迹 message 记录新增 `reasoningChars`（正文块字符数，与 usage 的
  reasoningTokens 计费口径是两个数），详情 KV 显示 `thought`。
- **边界**：reasoning+tool-call 且无 text 的消息仍不产气泡（tool 节点承载），
  不为凑 chip 造空卡；旧 journal 无 reasoning 块 → null → 无 chip（兼容）。
- **i18n 守卫立功**：轨迹 KV 值里的「字」字面量被零硬编码文案守卫逮到——
  lib/ 禁 CJK 字面量的规矩（静态类拿不到 l10n）再次自证。
- **测试**：chat_thinking 新增 durable 回看一条；trajectory_projection 两条
  （有块计数 / 旧消息 null）；全量 382/383（golden 已知漂移 + i18n 守卫当
  场逮到并修正）。

## 2026-10-13 D-107：诊断日志三通道 + 全局崩溃捕获 + 操作日志

**起因**：真机（小米 10-12）那份诊断日志，打开后是一屏
`[e2e] frame FollowAssistantStream`。不是引擎重发，是探针本身**每帧打一行**。

- **病根一 · 噪声源**：`chat_controller` 对 journal 的每一帧打一行 debug 日志，
  引擎流式输出时实测 130–250 帧/秒。512KB 滚动缓冲（≈7800 行）在**一次连续
  输出 30–60 秒内**被冲干净，`W/[chat] first-frame deadline hit` 这类现场证据
  反被挤掉——唯一的幸存者只是因为那时流已经停了。
  修法（`FrameSampler`）：前 3 帧逐帧打（保留「帧确实在来」的证据，D-094~D-104
  靠的就是它），其后按帧类型计数、每 2 秒汇总一行。30 秒满速输出 6000 行 → 18 行。
  刻意**不用 Timer 驱动窗口收尾**——pending Timer 会吊死 widget 测试；尾部残余
  由关流时显式 `flush()`。
- **病根二 · 崩溃从来没进过日志**：design §7.2 早就写着「全部错误入本地脱敏
  日志」，但全仓零个全局异常钩子。框架异常只在 logcat 红屏里、未捕获异常直接
  崩进程——App 真崩了打开诊断页是空的。修法（`CrashCapture`）：`FlutterError
  .onError` + `PlatformDispatcher.onError` + `runZonedGuarded` 三个入口，且
  **保留既有 handler**（debug 红屏不能因为接了捕获就没了）。
- **修法 · 三通道各自配额**：`app.log`(256KB, debug 行只在 debug 落) /
  `crash.log`(64KB, release 也落) / `audit.log`(128KB, release 也落)。通道隔离
  就是防噪声：debug 探针再吵也挤不掉崩溃记录。诊断页加通道切换，筛到空通道时说
  「该通道暂无日志」而不是「暂无日志」——两句话对排障的指向完全不同。
- **批量写**：逐行 `writeFromSync`（`IOSink.flush()` 会关 controller，见原注释）
  在流式输出时等于每帧一次同步 I/O。改成攒批（4KB / 250ms）。
  ⚠️ 滚动判定必须**按行铺**而不是整批灌：整批灌的话一个空文件会把整批接下去，
  256KB 上限当场失效。第一版就踩了这个（rotation 守门用例直接变红）。
- **操作日志**（用户选定「关键动作与状态迁移」粒度）：会话打开 / journal 重开
  （含 reason）/ 发送 prompt（只记 chars 不记内容）/ 审批回答 / 问答回答与拒绝 /
  首帧超时 / 自动重开 / 配对 TOFU / 解锁 / 语言变更 / 选模型，共 11 个动作。
- **两次断言基准选错，回退验证当场逮到**（今天第 3、第 4 次同族）：
  ①「栈单独成行」拿**记录条数**当基准——栈是同一条记录里的换行，应断言渲染文本
  的拆行数；②通道隔离拿 `MemoryLogSink.lines` 当基准——`lines` 不按通道过滤，
  崩溃误投 app 通道也照样看得见，**回退后仍然全绿**。改用 `readChannel` 才立住。
- **golden 基线**：`golden · machines list (live + expired)` 红是**既有漂移**——
  `git stash` 回 HEAD 单独复跑同样红，差异图只有两个小色块，不在本轮改动路径上。
- **测试**：新增 `frame_sampler_test`（6）+ `crash_capture_test`（8）+ 通道组（8）
  + 诊断页通道切换（2）；logging 全绿 36；app 全量 482/483（唯一红的就是上述
  既有 golden 漂移）。

### D-107 真机复验（小米 2109119BC，Android 13，12:12–12:19）

真机当场逮到**两个我自己引入的 bug**，都是 37 条单元测试一条没抓到的：

- **`Zone mismatch`（crash_capture 引入）**：`ensureInitialized()` 在根 zone、
  `runApp` 在 `runZonedGuarded` 里。第一个真机启动 `crash.log` 自己长出 1761 字节
  记的就是它——**崩溃捕获第一次上线就抓到了自己**。修法：`ensureInitialized`
  移进 `runGuarded` 内部。修完干净启动 `crash.log` **根本不存在**（无崩溃不落盘）。
  ⚠️ 凡是拆 `ensureInitialized` / `runApp` / zone 的改动，单测覆盖率是 0（测试不进 main）。
- **诊断页打开 7~8 秒（我改 flush 时引入）**：收敛条件多写了 `_raf == null`，
  「从没写过」的通道被当成「还在忙」，每个空通道空转 200×5ms。纯回归——旧代码
  立刻返回。诊断页 widget 守门抓不到（那页用 `MemoryLogSink`，flush 是空实现）。
  修完 1 秒内出内容。

**设备上已实证通过**：①`audit.log` 启动即写 `action=app.start mode=debug`；
②三通道文件按需创建、互不混写；③诊断页通道切换可用，空通道文案是「该通道暂无日志。」
（不是「暂无日志。」）；④崩溃捕获真的能抓（它抓到了自己那条 Zone mismatch）；
⑤修完 12:19 重启，无崩溃 = 无 crash.log。

已补测试后 app 全量 **485/485 全绿**（§D-108 修掉了那条 golden）。

**仍待验（需先重新配对）**：真实流式会话下的 `FrameSampler` 汇总行。本机引擎活着
（`127.0.0.1:3080`，trusted-host `relay.example.com`），但手机上那台机器「已过期」，
插件的 `/agent-stock/remote` 路由在引擎侧 404，拿不到新的配对链接。该项由单元
测试按真机速率覆盖（6000 帧 → <30 行）且两次回退即红，但**没有在真机流式输出下
亲眼见过那一行**，不冒充已验。

### D-108 Golden 基线钉住的是「只有那一天存在过」的状态

之前只证伪过「golden 漂移不是我改坏的」（stash 回 HEAD 复跑同样红），这次把
它自己的根因挖了：像素级测量（diff bbox / 逐列墨迹段 / 字形框计数）显示变的不是
文字行而是**过期机器那行的第一个 chip**（96→128px）。`test/factories.dart` 的
`expiredMachine()` 用**真实墙钟**铸造，而 golden 套件把渲染时钟冻结在
`2026-10-01`，于是 `isExpired(frozen)` 取决于跑测试当天是几号。反推出拍摄时刻在
**2026-10-03 傍晚**，那张基线编码的是一个只存在过几个小时的状态。

修法：`expiredMachine({DateTime? now})`（默认仍是真实墙钟，pairing /
screens_dghi 不受影响）+ golden 传冻结时间 + 重拍基线。修完卡片进入真正该有的
过期态（红点 + danger chip +「已过期」），golden 连跑两次 testImage md5 一致。

教训两条：①**夹具的时间源必须与渲染时钟同源**——冻结时钟配墙钟夹具，基线就是
一次性的；②`liveMintTime` 上方那段注释早就把同一个坑写下来了，在线夹具修过，
**过期夹具漏改**，它是那个时间炸弹的镜像版本（在线夹具怕绝对日期过期，过期夹具
怕相对日期「过期得不够久」）。同类仓库排查时先 grep 夹具里的 `DateTime.now()`。

### D-109 冷启动恢复「上次看的会话」+ 补 D-062 标题缓存的 load() 漏接线

起因是用户一句「重新开 app 进控制台是不是不会自动进入上一次的会话」。查证结果
和预期相反但方向有利：控制台**会**自动打开会话（D-031，取列表第一个 = 引擎侧最近
更新的），而「上次那个」压根没人记——`grep lastSession|restoreSession|currentSession
lib/` 零命中。所以落差真实存在，只是原因不是「没自动打开」，而是「自动打开的判据
不是用户上次看的那个」。

- 新增 `LastSessionStore`（按机器存 `machineId␟sessionId`）。
- **写**侧只挂 `ChatController.open()`——「此刻在看哪个会话」的唯一漏斗；
  `open(null)` 视为「用户关掉了」= 忘掉。
- **读**侧在 `ConsolePage._loadSessions`：先 `await ready`（不等就会静默回落，
  正是要修的行为），再优先记忆里的会话，**且必须验活**（id 可能已被引擎删了，硬
  开会得到永远转圈的空白页且不报错）。
- `main.dart` 补上 `SessionTitleCache.load()`——它此前**只在测试里被调用**，
  D-062 的「标题跨进程存活」只写不读，冷启动后照旧退回 session-xxxx。

**守门**：`last_session_store_test` 7 条（复用 `workspace_titles_test.dart` 的
`InMemorySharedPreferencesAsync` 平台替身，不手写 implements）+ `console_
resume_last_session_test` 5 条（断言落在「实际 follow 了哪个 session id」，而不是
UI 文案）。**回退即红**：把 `_resumeTarget` 退回 `_latestResumable` →
`Expected: session-a / Actual: session-b`。

**真机（小米 2109119BC）**：启动无 crash.log，控制台挂载正常、`await ready` 不卡
不抛，`session/list` 的 401 被如实记录。**但那台机器的会话仍被拒、列表为空，所以
「恢复到上次那个会话」没有在真机上亲眼验过**——缺一次可用配对，不冒充已验。
app 全量 497/497。

### D-110 凭证终态失效：控制台不再谎称「正在重连」

用户追问「凭证过期了不能更换凭证吗，不能更换的话也要提示用户呀」。三个答案：
①**之前更新过**——T-2h 续期调度在 M1 就做了，还有个单测就叫「已过期不续」；
②**过期后换不了**——`_realMint` 用旧 bearer 调 `GET /dsh-remote/url-session`，
换钥匙的门要旧钥匙开，且 `shouldRenew` 的 `!isExpired` 让过期条目被直接跳过；
③**提示只做了一半**——机器列表页有（已过期·点击重新配对→屏 I），但控制台的横幅
条件只有 `_muxState != connected`，凭证过期时 mux 永远到不了 connected，于是
「正在重连…」永远显示。这违反 design §7.2（会话失效属 L1 全屏页，L3 是自动消失
的层级），也是 D-104「文案承诺的行为必须兑现」的第四例。

修法：横幅分「可自愈断连 / 凭证终态失效」两种；后者红 + 断链图标（不转圈）+「凭证
已失效，不会自动恢复」+ 三因判别人话（expired/revoked/maxAge/unknown）+ 唯一主
行动「去重新配对」跳机器页。终态首次判定记一行 audit
（`action=machine.credential.dead cause=…`），顺带补上「续期从不写日志」这个回溯
洞的一角。判据用本地时钟，不等一次失败往返。

**真机复验**：这台机器天然就是终态对照组——横幅变红、文案正确、按钮真跳到机器页
那张「已过期 · 点击重新配对」的卡，audit 落 `cause=expired`。
**守门**：4 条，核心断言是那句谎话 `findsNothing`；回退即红（摘掉判定立刻抓到
`Found 1 widget with text "连接已断开，正在重连…"`）。app 全量 501/501。
