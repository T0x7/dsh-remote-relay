# 真机测试方案（Android）

> 本项目 App 的真机验证分**三层**，各有分工。全文记录的都是 2026-10-08
> 真机实战中验证过的命令与踩过的坑——包括把黑屏误判成渲染 bug、把息屏
> 当成 App 崩溃这类**看起来像代码问题、其实是环境问题**的假信号。
>
> 读者：① 跑回归的人（照 §2 走）；② 接手 App 的人（先读 §6 陷阱速查）。

## 1. 三层测试体系

| 层 | 手段 | 覆盖 | 何时跑 |
|---|---|---|---|
| **L1 宿主机** | `cd app && flutter test`（约 360 用例）+ core 包测试 | 逻辑、渲染、wire 形状、i18n、golden | 每次提交 |
| **L2 真机结构冒烟** | `flutter test integration_test -d <serial>`（3 用例） | 冷启动、三 Tab、诊断页、控制台输入框**在真机上真的存在** | 改壳层/依赖后；**只在专用机**（见 §4 禁令）|
| **L3 真机人工验收** | 手动 + adb 辅助（本文档） | 真实网络、真实配对、真实引擎交互、视觉观感 | 里程碑、发布前 |

L1 绿 ≠ 能发布：L1 的 widget 测试跑在宿主机渲染器里，**真机渲染、网络栈、
系统对话框（生物识别）、安装门**全都不覆盖。今天三个真机 bug（息屏黑屏、
meta 本地化崩溃、MIUI 拒装）L1 全绿。

## 2. adb 控制真机操作手册

### 2.1 连接与健康检查

```bash
export PATH="$PATH:$HOME/Library/Android/sdk/platform-tools"
adb devices                 # 出现 serial + "device" 才算在线
adb -s <serial> shell echo alive
```

**掉线是常态**（线松、息屏、MIUI 打断）。所有多步操作前先探一次；
跑批时优先"单条命令完成一件事"，断线只需重跑那一条。

### 2.2 装机（三条路径，风险递增）

```bash
# A. 常规覆盖安装（保留数据，App 配对不掉）
adb -s <serial> install -r app/build/app/outputs/flutter-apk/app-debug.apk

# B. MIUI 拒装时：让机主点弹窗，或开发者选项开「USB 安装」
#    INSTALL_FAILED_USER_RESTRICTED = Install canceled by user

# C. Root 设备（Magisk 已授权 shell su 时）——绕开 MIUI 安装门
adb push <apk> /data/local/tmp/x.apk
adb shell "su -c 'pm install -r /data/local/tmp/x.apk'"
adb shell "su -c 'rm /data/local/tmp/x.apk'"
```

⚠️ `flutter test integration_test` 内部是**卸载重装**（会清空 App 数据），
且每次跑测都触发 MIUI 安装门——**别在主力机上用它**。

### 2.3 唤醒、解锁、截屏（最常踩的三个坑）

```bash
adb shell input keyevent 224        # KEYCODE_WAKEUP 唤醒
adb shell am force-stop <pkg>       # 冷启动复现
adb shell monkey -p <pkg> -c android.intent.category.LAUNCHER 1
adb exec-out screencap -p > shot.png
```

- **息屏 vs 渲染失败**：息屏时截屏是 100% 黑（连状态栏都没有）；App 渲染失败
  时**状态栏仍在**。先用 `dumpsys power | grep mWakefulness` 确认 Awake。
  今天 17:15 的"黑屏 bug"实为息屏——**先唤醒再判定**。
- **FLAG_SECURE**：App 处于生物识别锁屏门/系统指纹弹窗时，截屏返回 **0 字节**，
  且 UI 驱动全失效——必须请机主按指纹解锁。
- **看图技巧**：手机 1080×2400 截图直接看太占上下文，`sips -Z 900` 缩到
  405 宽再看；换算坐标时**乘 2.667**（1080/405），横竖屏每变一次重算。

### 2.4 点击与语义定位

```bash
# 按小图标坐标换算后点击（竖屏 1080 宽）
adb shell input tap <x> <y>

# 拿 Flutter 语义节点真实 bounds，避免坐标猜错
adb shell uiautomator dump /sdcard/ui.xml
adb shell cat /sdcard/ui.xml | grep -o 'class="[^"]*Switch"[^>]*bounds="[^"]*"'
```

（Switch 的语义节点常常是**整行** bounds，不是那个小开关本身。）

### 2.5 logcat

```bash
PID=$(adb shell pidof <pkg> | tr -d '\r')
adb logcat -c                                  # 清空
adb logcat -d --pid=$PID -v time               # 只看本进程
adb logcat -d --pid=$PID | grep -E "e2e|flutter" # App 自己的帧日志
adb logcat -d -b crash | grep <pkg>            # 崩溃缓冲
```

App 的 `[e2e]` 行（kDebugMode）是最有用的实时流水：开了哪些 `$events` 代、
journal 帧、错误分类都在里面。

## 3. 迭代闭环（今天实际用的节奏）

```
1. 宿主复现：写红测试（引擎契约用 fake relay 断 wire 形状）
2. 修 + analyze + L1 全绿
3. 装机（路径 A，保数据）
4. 真机实弹：唤醒→冷启→截图→驱动→再截图
5. 权威证据：引擎侧 curl / journal 落库佐证 UI 不是自说自话
6. 提交（把 APK 哈希、journal 记录、logcat 行写进 commit message）
```

**证据留存**：截图落在 `app/.e2e/`（已 gitignore），命名前缀
`u##`=迭代 / `s##`=冒烟 / `b##`=缺陷 / `d0##`=功能，本文档引用的都是
这类文件。commit message 里写证据路径，接手者能复原全过程。

## 4. 禁令：integration_test 只跑专用机

`flutter test integration_test -d <serial>` 的安装流程含**卸载重装**，会清空
目标设备 App 数据（配对、语言偏好，不可恢复）。2026-10-08 在机主主力机上
误跑两次，擦了配对两次。

**规则**：L2 只跑模拟器或备用真机；主力机要用自动化，先备份配对
（或准备重新扫码的一次性成本）。

## 5. 真机验收清单（L3，发布前走一遍）

1. **冷启动**：断网态冷启（看错误卡形态），联网态冷启（看会话恢复）
2. **三 Tab**：机器/控制/设置 互切，控制台进出会话保持
3. **配对**：新配对 → 机器绿点 → 断网 → 恢复（看重连日志与 UI）
4. **审批流**：让 agent 触发一次需审批的工具调用 → 手机批 → **在 dsh web 上
   确认同一审批同步消失**（这条是跨端一致性断言，L1 永远测不到）
5. **发送消息**：连发两条 → 都落库（requestId 幂等回归点）
6. **插件页**：Host 页开关渲染，**点一次并确认引擎侧状态真变化**（引擎写锁
   泄漏时会失败——见 §6）
7. **诊断日志**：故障后有行、脱敏（无 Bearer/密码）、分享面板带 app.log、
   清空要二次确认
8. **系统弹窗**：生物识别锁开/关两态（开时确认进控制台会拦）
9. **崩溃扫描**：`adb logcat -d -b crash | grep <pkg>` 空

## 6. 环境陷阱速查（全部实战命中）

| 现象 | 真因 | 处置 |
|---|---|---|
| 截屏全黑（0% 非黑像素） | **手机息屏**，非 App 问题 | `input keyevent 224` 先唤醒 |
| 截屏 0 字节、控制台初始化不了 | FLAG_SECURE 锁屏门 | 请机主按指纹解锁 |
| `INSTALL_FAILED_USER_RESTRICTED` | MIUI 安装确认未点/息屏取消 | 亮屏点允许；或开「USB 安装」；或 root `pm install -r` |
| `flutter test integration_test` 跑完手机 App 变"测试壳" | 测试变体覆盖安装 | 跑完重装正常包（root 装保留数据） |
| 配对/语言全丢 | integration_test 卸载重装 | 同上；重配对；只跑专用机 |
| 点 Switch 报 `atomic-wrote … lock` 超时 | **引擎侧 bug**：profile 写锁泄漏（引擎进程长期持读 fd） | 重启引擎；非客户端问题 |
| 日志里 `meta is not a subtype of String?` 崩溃 | 引擎元数据是 locale map 不是字符串 | 解析侧按 locale map 兼容 |
| 集成套件多文件同跑挂死 | flutter_tools 通道 bug（单跑全绿） | 逐文件跑 |
| `adb devices` 反复掉线 | 线/口接触不良 | 换线换口；或无线调试 |

## 7. 无线调试（备选链路，线坏时用）

线一直掉、或想彻底摆脱线时：手机 开发者选项 → 无线调试 → 配对；
`adb pair <ip:port>`（输手机上的 6 位码）→ `adb connect <ip:port>`，
之后所有命令把 `-s <serial>` 换成 `-s <ip:port>` 即可。

## 8. 相关文件

- `app/integration_test/device_smoke_test.dart` — L2 三用例（注意 §4 禁令）
- `app/TESTING.md` — 宿主测试现状表 + 人工验收清单（日志系统一节可作 L3 范式）
- `docs/app-field-notes.md` — 真机 bug 纪实（每个坑的现象→根因→修复）
- `docs/engine-rpc-errata.md` — 引擎 RPC 勘误（写客户端前必读）
- `app/.e2e/` — 证据截图（未入库）