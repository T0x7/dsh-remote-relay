# 本仓自定义的 R8/ProGuard 规则。
#
# Flutter Gradle 插件会自动把本文件**追加**到 release 构建的规则列表
# （见 flutter_tools/gradle/.../FlutterPlugin.kt：`File("${project.projectDir}/
# proguard-rules.pro")` 存在即 `proguardFiles.add(...)`，是 add 不是 set，
# 不会顶掉插件自带的 flutter_proguard_rules.pro 与 proguard-android-optimize.txt）。
# 所以改这个文件就够了，不需要在 build.gradle.kts 里再声明一次。

# ── D-115：保住 mobile_scanner 的 Kotlin 伴生对象 ────────────────────────────
#
# 症状：release 包里扫码配对（屏 B）永远「相机不可用 / 错误：genericError」，
# 相机一次都没被打开过（camera service 无 CONNECT 记录），但权限 granted=true、
# 硬件齐全、GMS 正常。debug 包一切正常，所以本地怎么测都是好的。
#
# 成因链（用 mapping.txt + jadx 逐帧还原，非推测）：
#   1. mobile_scanner 5.2.3 的 MobileScanner.kt:46 把扫码器工厂写成对**伴生对象
#      函数**的可调用引用 `::defaultBarcodeScannerFactory`。
#   2. 可调用引用编译成持有 `MobileScanner.Companion.INSTANCE`（一个**静态字段**，
#      不是编译期常量）的 lambda 类。
#   3. AGP 9.x 默认 R8 full mode。它把 `defaultBarcodeScannerFactory` 的方法体
#      整体内联进调用点后，判定 `MobileScanner$Companion`「无人使用」，于是把
#      **整个类连同 `<clinit>` 一起剥掉**——release APK 里 jadx 反编译出来就是个
#      空类 `public final class ok0 {}`。
#   4. 那个 lambda 仍照读不误 → 拿到 null → `BarcodeScanning.getClient()` 第一行
#      就 NPE（ART 文案：Attempt to invoke virtual method 'getClass()' on a null
#      object reference）。
#   5. 失败发生在 CameraX 绑定之前，所以相机压根没开；插件把异常统一编码成
#      PlatformException，Dart 侧一律映射成 genericError，屏上什么真因都看不到。
#
# 为什么规则要 keep **类**而不是 keep CallableReference：被剥掉的是伴生对象上的
# 静态 INSTANCE 字段，只 keep CallableReference 本身，那个读操作照样拿到 null。
# 必须让伴生对象类（含其 `<clinit>`）活下来。
#
# 插件自带的 proguard-rules.pro 只 keep 了 `com.google.mlkit.*` / barhopper /
# photos，**一条都没覆盖 mobile_scanner 自己的类**，所以这个洞没人挡。
-keep class dev.steenbakker.mobile_scanner.** { *; }

# ── D-115 第二层：ML Kit 的组件注册靠反射，R8 会把构造器剥掉 ──────────────────
#
# 补上上面那条之后，伴生对象不再是 null 了，NPE 挪到了**下一行**，仍报同一个
# `getClass() on a null object reference`，位置是 defaultBarcodeScannerFactory:15
# ——那里是 `MlKitContext.getInstance().get(BarcodeRegistrar.class)` 拿回 null。
#
# 真因在启动日志里，早 8 秒：
#   W ComponentDiscovery: Could not instantiate com.google.mlkit.common.internal.CommonComponentRegistrar
#     Caused by: java.lang.NoSuchMethodException: ...CommonComponentRegistrar.<init> []
#   W ComponentDiscovery: Could not instantiate com.google.mlkit.vision.barcode.internal.BarcodeRegistrar
#   W ComponentDiscovery: Could not instantiate com.google.mlkit.vision.common.internal.VisionCommonRegistrar
#
# ML Kit 的 `MlKitInitProvider` 用 `Class.getConstructor()` **反射**造这几个
# Registrar；R8 full mode 看不到静态引用，就把无参构造器当死代码剥了 → 注册表里
# 没有实现 → 上面那次查表返回 null → 相机仍然一次都不开。
#
# 为什么插件自带的规则挡不住：它写的是 `-keep class com.google.mlkit.* { *; }`，
# 而 ProGuard 的 `*` **不匹配包分隔符**——`com.google.mlkit.*` 只覆盖顶层包，
# `com.google.mlkit.common.internal.*` / `com.google.mlkit.vision.barcode.internal.*`
# 一个都没盖到。必须用 `**`。
#
# 这两条是 ML Kit 官方文档给出的 R8 规则；`mlkit_vision_barcode` 是随
# play-services 条码模块一起进来的那部分（本仓用它，见依赖树里
# com.google.mlkit:barcode-scanning:17.2.0 → play-services-mlkit-barcode-scanning:18.3.0）。
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }

# 兜底：同类风险不限于 mobile_scanner 5.2.3。若日后升级/新增插件后扫码或其他
# 插件出现同样的「只在 release 报错」，先来这里加规则，而不是去调插件版本。
# （本仓只装 mobile_scanner 一个带 Kotlin 伴生对象工厂的插件，故未开全局 keep，
#  以免白白放弃 R8 的体积与混淆收益。）
