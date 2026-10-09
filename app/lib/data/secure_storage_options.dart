import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// D-054：App 里**所有** secure storage 必须用同一套 Android options。
///
/// ## 这条注释是一次真机事故的记录
///
/// 症状：语言偏好选了「中文」，冷启动后又回到跟随系统。查下来存储文件里
/// `dsh_remote.locale.v1` 那一条**单独消失了**，而机器条目完好。
///
/// 根因：`AndroidOptions.encryptedSharedPreferences` 的**默认值是 `false`**
/// （`flutter_secure_storage-9.2.4` `android_options.dart:15`）。当时三个 store
/// 里有两种写法：
///
/// ```dart
/// // machines_repository.dart —— 显式加密
/// const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true))
/// // locale_store.dart / settings_store.dart —— 裸的，等于非加密
/// const FlutterSecureStorage()
/// ```
///
/// 两种模式**共用同一个 `FlutterSecureStorage.xml`**（`SHARED_PREFERENCES_NAME`
/// 在插件里硬编码），但用**两套完全不同的密钥**：加密模式走 AndroidX
/// `EncryptedSharedPreferences` + 硬件 keystore，非加密模式走 RSA-ECB keystore。
///
/// 而每次 machines 初始化都会执行迁移（`FlutterSecureStorage.java:170`）：
///
/// ```java
/// preferences = initializeEncryptedSharedPreferencesManager(context);
/// checkAndMigrateToEncrypted(nonEncryptedPreferences, preferences);
/// ```
///
/// 迁移会**重写并清理非加密条目**。于是 locale / settings 的值在进程几次启动
/// 之间被迁移逻辑吃掉了——机器条目没事是因为它本来就写在加密区。
///
/// ## 为什么不能各写各的
///
/// 这个 bug 的本质是「同一个文件、两种加密方式、两套密钥」，而它在代码里长得
/// 和「一个正常的构造」一模一样，`flutter analyze` 不会报，测试也不会红。
/// 所以规则写成一条共享常量 + 一条守卫测试（`test/secure_storage_guard_test.dart`），
/// 而不是靠 review 时记得住三处写法一致。
///
/// 顺带一提：加密模式本身也更安全（值由硬件 keystore 背书），所以统一到它
/// 没有代价——除了升级后旧值读不到一次，届时用户回落到默认偏好即可。
const kSecureAndroidOptions =
    AndroidOptions(encryptedSharedPreferences: true);

/// 与 [kSecureAndroidOptions] 配套的 iOS 选项。
///
/// 留空：插件的 iOS 默认是 `kSecAttrAccessibleAfterFirstUnlock`，与 design
/// §7.3 的要求一致。`ThisDeviceOnly` 收紧是 v1.1 的事（见
/// `machines_repository.dart` 的同名注释），等插件枚举名核实后再动。
const kSecureIOSOptions = IOSOptions();
