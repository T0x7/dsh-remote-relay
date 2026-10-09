# dsh remote · 测试与验收（TESTING）

> 自动化分层见 `docs/app-implementation-plan.md` §12；本文件是**人工验收清单**
> 与设备冒烟步骤。设计对照物：`docs/app-ui-mockups.html`（15 屏）。
>
> 真机测试的完整方案（三层体系 · adb 操作手册 · 环境陷阱速查）见
> [`docs/device-testing.md`](../docs/device-testing.md)——跑真机回归前先读它，
> 本文 §2 只是其中最短的一条路径。

## 1. 自动化测试

| 层 | 命令 | 现状（2026-10-08） |
|---|---|---|
| core api（纯 Dart） | `cd packages/dsh_remote_core && flutter test test/api` | 181/181 绿 · 一次跑 |
| core 集成 | 同上，`test/integration/*.dart` **逐文件**跑 | 全绿（合跑会挂，见 PROGRESS D-032） |
| core log 缝 | `flutter test test/log_hook_test.dart` | 4/4 绿（`package:test`） |
| 壳 widget（含 i18n） | `cd app && flutter test` | 364/365 绿（golden 机器列表有已入档的环境漂移） |
| 真机冒烟 | `cd app && flutter test integration_test -d <serial>` | 3 例结构冒烟；**会清空目标机 App 数据，只跑专用机** |
| Golden 基线 | `flutter test --update-goldens`（刷新） | 3 张（空态 / 机器列表 / 设置） |
| analyze | `flutter analyze` | 0 issues（app + core） |
| ARB 键一致性 | `python3 scripts/check-arb-keys.py` | zh/en 键集必须相同 |

Golden 变更请当作**设计评审**看 diff，而非顺手 `--update-goldens`。
i18n：文案全走 ARB（`app/lib/l10n/*.arb`），UI 零硬编码中文；改文案走 ARB。

## 1a. 日志系统（D-077）人工验收

1. **查看**：设置 →「诊断日志」→ 出现日志行与元信息（字节 · 行数）；空安装显示「暂无日志。」。
2. **脱敏**：制造一条带凭证的日志后「复制全部」，粘贴检查——`Bearer`/token/psk/
   配对链接的 query 必须已是 `[REDACTED]` 或被剥除；host 与 sessionId 应保留
   （那是日志的价值所在）。
3. **分享**：点分享 → 系统分享面板带出 `app.log`（若有滚动一代则含 `.old`）；
   接收侧打开内容与 App 内查看一致（同一份脱敏字节）。
4. **清空**：需二次确认；确认后立即回空态，之后新日志照常落盘。
5. **core 事件进日志**：断开电脑网络 / 杀引擎 → 日志应出现
   `W/[relay]`（传输失败）、`I/[events]`（重连退避）、`W/[events]`（4001 healing）、
   `E/[tofu]`（指纹不匹配）等级别的行。
6. **release 包**：`flutter build apk --release` 装机复现一个错误 → 诊断日志页
   必须有内容（debug 探针除外，release 只收 info+）。

## 2. 设备冒烟（Android 真机，3 分钟）

```bash
cd app && flutter build apk --debug     # 需要 PATH 里有 flutter
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell monkey -p dev.dshremote.dsh_remote_app -c android.intent.category.LAUNCHER 1
```

验收点：深色主题、底部三 Tab、空态文案与主按钮、可滑动无异常、logcat 无本包崩溃。

## 3. 配对端到端（自动脚本）

### 3a. 相机扫码验证（零 USB，推荐先走这条）

```bash
dart run app/packages/dsh_remote_core/bin/pairing_bed.dart > /tmp/bed.log 2>&1 &
sleep 7
node app/packages/dsh_remote_core/tool/print_qr.mjs "$(grep PAIRING_URL /tmp/bed.log | cut -d= -f2-)"
# 手机（已装新 APK、解锁）→ App →「扫码 / 粘贴链接」→ 右上「扫码」→ 对终端扫
# → 确认页 → 锁定并连接 → 机器卡出现
```

不依赖 adb/USB：终端出码（`print_qr.mjs` 复用 client `cli.ts` 的 proven 渲染），
手机扫。相机权限/硬件问题在此路径才会暴露——widget 测试覆盖不到。

### 3b. 粘贴路径（自动，需 USB）

```bash
# 手机插线 + MTP + USB 调试授权后
adb reverse tcp:<relay_port> tcp:<relay_port>   # 脚本自动从 bed.log 读端口
```

期望：确认页（屏 C）→ 「锁定并连接」→ 机器卡出现（屏 A），`build/…/e2e_confirm.png`
与 `e2e_done.png` 可查。**死链接必须停在屏 J 且不入库**（widget 测试已钉）。

## 4. 15 屏人工清单

| 屏 | 验收点 | 状态 |
|---|---|---|
| A 机器列表 | 三态卡（绿/琥珀/红）、倒计时芯片色阶、30 天读数、空态 | ✅ |
| B 配对·扫码 | 相机取景、真机扫终端 QR 成功 | ✅ 代码（真机待验，§3a） |
| B′ 配对·粘贴 | 解析/错误分级文案 | ✅ |
| C 确认 | relay/机器名/会话/TOFU 提示、锁定并连接 | ✅ |
| D 详情 | 双进度条、设备在线、复制链接/断开/重连/吊销（二次确认） | ✅（复制链接；浏览器跳转待 url_launcher 白名单） |
| E 对话 | 控制台占位 | ⏳ M2 |
| F 任务 / G 主机 | — | ⏳ M2 |
| G 设置 | 锁/TOFU/提醒/语言/关于 | ✅（语言行占位，接 picker 后生效） |
| H 锁屏 | 启动上锁、解锁回归 | ✅（占位解锁；local_auth 下一批） |
| I 失效 | 三因文案、重扫/删除 | ✅ |
| J 配对失败 | 失效/不可达/格式三态 | ✅ |
| K 模型/档位 · L 上下文 · M 会话 · N 团队 · P 提问 | — | ⏳ M2 |

## 5. 已知占位（M1 末/M2 接）

- 浏览器直开已接 url_launcher（唤不起自动降级复制）、相机已接 mobile_scanner；
  仍占位：生物识别（local_auth）、语言选择器（当前固定 zh 优先）
- 列表页的续期失败 chip 呈现（调度器已在跑并记录 failures，UI 呈现放 M2）
