# mobile_scanner 5.2.3 → 7.4.2 升级路径与冒烟计划

状态：**已执行，随 v0.0.3 发布（2026-10-15）**。五层冒烟全过；「真实扫中一个码」
需人手持二维码，留作发版后人工抽查。执行记录见 app/PROGRESS.md 的 D-116。

## 0. 结论与触发条件

**升，单独一个批次，发 0.0.3（不重切 0.0.2）。**

触发条件（三条同时成立才动手，已全部满足）：

1. 当前 5.2.3 存在**源码级实锤**的、我们正在踩的缺陷（§1.2）；
2. 移植成本已实测为 **1 行代码 + 版本号**（§2）；
3. release 真机验收管线刚搭好并跑热（D-115 两轮验证），执行验证的边际成本处于最低点。

不再等的理由记录在 docs/app-field-notes.md §6.26：这类 release-only 缺陷的验收
窗口是「管线热」的时候，不是「想起来」的时候。

## 1. 已核实事实（执行前不再重查，执行时按行号抽查即可）

### 1.1 兼容性（对 7.4.2 tarball 实测，非推断）

| 我们的符号 | 5.2.3 | 7.4.2 | 动作 |
|---|---|---|---|
| `MobileScanner` widget | ✅ | ✅（新增 onDetectError 等，均有默认值） | 无需改 |
| `MobileScannerController()` 无参 | ✅ | ✅（全默认参，`autoStart=true`） | 无需改 |
| `BarcodeCapture`（`onDetect` 参数） | ✅ | ✅（objects/barcode_capture.dart:10） | 无需改 |
| `errorBuilder` | 3 参 `(context, error, child)` | **2 参** `(context, error)`，`MobileScannerErrorBuilder` typedef 已删 | **scan_page.dart 改 1 行** |
| `errorDetails` / `errorCode` | ✅ | ✅（mobile_scanner_exception.dart:10-16） | 无需改 |

- 7.0 两条 BREAKING（`EncryptionType.none`、`MobileScannerErrorBuilder`）本仓均未使用。
- 环境要求：7.4.2 要 Flutter ≥3.29 / Dart ≥3.7；本机 3.47.6 ✅。插件 minSdk 23，本仓 24 ✅。

### 1.2 升级收益（四条对号入座，附证据）

| 5.2.3 的缺陷 | 证据 | 7.x 修复 |
|---|---|---|
| `dispose()` 不取消 `_barcodesSubscription`（只有 `stop()`→`_disposeListeners()` 会取消），而 scan_page.dart:24 正是 dispose-without-stop；扫码页反复开合即反复泄漏 | 5.2.3 controller dispose():412-422 无 cancel；stop():328 才调 `_disposeListeners` | 7.4.2 dispose():832 调 `_disposeListeners()`；:839 起还有平台会话归属检查防跨控制器误删（changelog 7.3.0 两条） |
| ImageProxy 不释放 → **扫码永久停摆**（Android） | changelog 7.4.1 | 已修 |
| CameraX 启动失败 → **宿主 App 崩溃**（我们的 start 失败路径） | changelog 7.4.1 | 已修（降级为可捕获错误） |
| 控制器初始化黑屏无报错 | changelog 7.0.0 | 已修（同 D-115 一类） |

### 1.3 R8 风险面（升级后 keep 规则仍然必需，不能删）

- **`::defaultBarcodeScannerFactory` 在 7.4.2 依然存在**（7.4.2 MobileScanner.kt:62）——
  伴生对象可调用引用这个 R8 full mode 雷没排掉。我们 `proguard-rules.pro` 的
  `dev.steenbakker.mobile_scanner.**` 继续必需。
- 7.4.2 自带的 consumer 规则修了 mlkit 顶层（`com.google.mlkit.**`），**但 gms internal
  包仍是单星号**：`com.google.android.gms.internal.mlkit_vision_barcode.*`——
  我们的 `**` 规则仍严格更优，保留。
- 依赖版本变化（R8 面积变化，冒烟 §3.4 就是为它设的）：
  CameraX 1.3.3 → **1.6.1**；mlkit barcode-scanning 17.2.0 → 17.3.0；
  play-services-mlkit 18.3.0 → 18.3.1。插件改用 `android/build.gradle.kts`。

## 2. 升级路径（精确到文件）

```
1. app/pubspec.yaml
     mobile_scanner: ^5.2.3  →  ^7.4.2
2. flutter pub get（lock 会更新 mobile_scanner 及其传递依赖）
3. app/lib/pairing/scan_page.dart  —— 唯一的代码改动：
     errorBuilder: (context, error, child) => _ScanError(...)   // 5.x 三参
     errorBuilder: (context, error) => _ScanError(...)          // 7.x 两参
   同时保留（守门 grep 依赖这两处，android_hardening_test.dart 会查）：
     - error.errorCode.name
     - error.errorDetails
4. scan_page 其余不动：`_controller.dispose()` 无需补 stop()——
   7.4.2 widget 层在 dispose 时对 autoStart 控制器自行 stop（mobile_scanner.dart:221-223），
   controller.dispose() 自身也已修为会取消订阅（:832）。给 5.2.3 补 stop 的历史教训
   写在 D-115 注释里即可，不扩大 diff。
5. proguard-rules.pro 不动（§1.3：两条 keep 均仍必需）。
6. 跑 §3 全部五层。
```

预期冲突点（若出现，属于计划内而非意外）：
- `flutter pub get` 可能连带升级 collection/meta 等传递依赖 → 看 lock diff 再继续；
- 若 analyzer 报其它 mobile_scanner 相关错误，停下重估——说明本文件 §1.1 有漏。

## 3. 冒烟计划（五层，逐层过，任何一层红即停）

判据总原则（field-notes §6.26）：**debug 绿不算数，UI 文案不算数，系统服务侧事件才算数。**

### 3.1 静态层（本地，~1 分钟）

```bash
cd app
flutter pub get && flutter analyze            # 期望：No issues
flutter test                                   # 期望：556+ 全绿（守门 10 条含 D-115）
python3 ../scripts/check-arb-keys.py           # 期望：key sets match
bash ../scripts/scan-secrets.sh                # 期望：clean
```

红 → 停，先回退 pubspec 再排查（见 §4）。

### 3.2 产物层：R8 是否又剥了东西（构建后、装机前，~2 分钟）

```bash
# 用发布脚本构建（含 mtime 过滤，跳过陈旧产物）
source ~/.config/dsh-remote/signing/env.sh
bash scripts/build-release.sh                  # 默认不发布，只产 dist/release/

# 判据一：mapping 里插件与 ML Kit 仍是全名（keep 生效）
grep -c "^dev.steenbakker.mobile_scanner\..* -> dev.steenbakker" \
  app/build/app/outputs/mapping/release/mapping.txt        # > 0
grep "^com.google.mlkit.vision.barcode.internal.BarcodeRegistrar -> com.google" \
  app/build/app/outputs/mapping/release/mapping.txt        # 有输出
# 判据二：R8 读到了我们的规则文件
grep -c "proguard-rules.pro" app/build/app/outputs/mapping/release/configuration.txt  # ≥ 1
```

### 3.3 装机冒烟：debug 级功能面（模拟器或真机皆可，~3 分钟）

```bash
adb install -r app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb shell dumpsys package dev.dshremote.dsh_remote_app | grep versionCode   # 期望 2003
```

手测（或按屏 G 诊断页核对）：
- [ ] 配对页 →「扫码」→ 相机预览出现、取景框渲染
- [ ] 对任意二维码，1 秒内回填链接（扫码主路径通）
- [ ] 关闭扫码页 → 重开 → 再关 ×3（dispose 路径；5.2.3 的泄漏场景）
- [ ] 退出 App 重进：锁屏（屏 H）正常

### 3.4 真机系统层：相机真的被打开、无异常（小米 Civi，~3 分钟）

```bash
adb logcat -c
adb shell am force-stop dev.dshremote.dsh_remote_app
adb shell am start -n dev.dshremote.dsh_remote_app/.MainActivity && sleep 7
adb shell input tap 540 1448 && sleep 3 && adb shell input tap 925 960 && sleep 9
# 判据一：camera service 有本次 CONNECT + ACTIVE（State: 2）
adb shell dumpsys media.camera | sed -n '/Camera service events log/,/dynamic/p' | head -4
adb shell dumpsys media.camera | sed -n '/Active Camera Clients/,/Allowed user/p'
# 判据二：零插件/ML Kit 异常
adb logcat -d | grep -icE "Failed to handle method call|Could not instantiate"   # 期望 0
# 判据三：UI 无「相机不可用」（FLAG_SECURE 下 screencap 不可用，走无障碍树）
adb shell uiautomator dump /sdcard/ud.xml >/dev/null && adb pull /sdcard/ud.xml /tmp/ud.xml
grep -c "相机不可用" /tmp/ud.xml                                                # 期望 0
adb shell input tap 77 172   # 关掉相机
```

### 3.5 发布层：0.0.3 走完整发版链路（~10 分钟）

1. 版本四处同步升 0.0.3（pubspec `0.0.3+3` / about_info / ARB×2 / CHANGELOG 封段），
   `version_single_source_test` 6 条全绿；
2. `update_checker_test` 重点看「推导」夹具——0.0.3 上线当天它必须仍绿（D-115 教训：
   这类夹具要一次改全，升级批次最容易漏）；
3. `DSH_RELEASE_PUBLISH=1 bash scripts/build-release.sh`（脚本已带 `--prerelease`，
   说明取 CHANGELOG `## [0.0.3]` 段）；
4. **线上包回装验收**：`gh release download` arm64 → SHA-256 与本地比对 → 装机重复 §3.4；
5. 用 App 逻辑复验更新通道：装 0.0.2 的用户对 0.0.3 `available=True`。

## 4. 回退方案

任一层失败且 30 分钟内定位不到：

```bash
git checkout HEAD -- app/pubspec.yaml app/pubspec.lock app/lib/pairing/scan_page.dart
flutter pub get && flutter test test/android_hardening_test.dart   # 回到 5.2.3 基线
adb install -r /tmp/app-arm64-v8a-release-BEFORE-D115.apk          # 或重出 5.2.3 包
```

回退即绿的判据（§3.4 三条判据全过）才算回退成功；只回代码不回验等于没回。
升级分支上已有的任何改动不携带着回 master。

## 5. 发布决策

- 冒烟全绿 → 发 **0.0.3 prerelease**（beta，与 0.0.1/0.0.2 同档）。
- 3.1–3.4 绿但 §3.5 发现更新通道异常 → 发版挂起，先修通道（那是 D-114 的锅，不归升级）。
- CHANGELOG 的 0.0.3 段必须写两类内容：升级收益（尤其 dispose 泄漏，附本文件 §1.2 证据）
  与「R8 keep 规则在 7.4.2 下仍必需」的事实（防后人误删）。

## 6. 执行时再确认清单（本文件未覆盖、留待执行现场）

- [ ] `flutter pub get` 后 lock 的传递依赖 diff 是否夹带无关升级
- [ ] analyzer 若报本文件未列出的 mobile_scanner 错误 → 停下重估 §1.1
- [ ] CameraX 1.6.1 在 AGP 9.1.0 / R8 full mode 下的组合行为（只能靠 §3.2/§3.4 实测）
- [ ] 7.x `onDetectError` 新回调是否值得接（默认 `_onDetectErrorHandler`，先不动）
