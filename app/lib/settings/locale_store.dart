import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/secure_storage_options.dart';

/// 屏 G 提供的两种语言。刻意只认这两种：arb 只有 zh/en，多认会让界面落回
/// Material 的默认英文，而那不是我们的译文。
enum L10nCode {
  zh('zh'),
  en('en');

  const L10nCode(this.languageCode);

  final String languageCode;

  static bool isSupported(String code) =>
      L10nCode.values.any((e) => e.languageCode == code);

  static L10nCode? of(Locale? locale) {
    if (locale == null) return null;
    for (final code in L10nCode.values) {
      if (code.languageCode == locale.languageCode) return code;
    }
    return null; // 例如系统是 fr：没有对应译文，不假装支持
  }
}

/// 语言偏好（屏 G 的语言页）。
///
/// 为什么单独一个 store 而不是加进 `SettingsSnapshot`：`SettingsSnapshot`
/// 在 `lib/data/settings_store.dart`，那个文件本任务不拥有（另一条线在并行
/// 改）。为了不制造写冲突，这里用同一条 secure storage 通道自己存一份
/// locale，与 `SettingsStore` 的做法保持一致（零新增依赖）。
///
/// 这里不做「跟随系统」选项——PRD §7.1 的信息架构里语言页就是二选一，
/// 系统语言由 `MaterialApp` 的 `locale` 兜底。
class LocaleStore {
  LocaleStore({FlutterSecureStorage? storage})
      // D-054: 裸的 `const FlutterSecureStorage()` 走非加密路径，与 machines
      // 共用同一个文件却是两套密钥，会被加密模式的迁移逻辑吃掉。
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: kSecureAndroidOptions,
              iOptions: kSecureIOSOptions,
            );

  static const _key = 'dsh_remote.locale.v1';

  final FlutterSecureStorage _storage;

  /// null = 尚未选择过（此时界面语言由 App 启动时决定）。
  final notifier = ValueNotifier<L10nCode?>(null);

  Future<void> hydrate() async {
    String? raw;
    try {
      raw = await _storage.read(key: _key);
    } on Object catch (e) {
      // 这里原来是一个静默的 `on Object { return; }`：真机上冷启动读偏好失败时，
      // 界面会安静地落回系统语言，日志里一个字都没有，于是「重启后语言丢了」
      // 看上去像玄学。失败必须出声，否则下一次只会更查不下去。
      AppLog.w('locale', 'hydrate failed: $e');
      return; // tests / 缺平台通道 → 未选择
    }
    if (raw != null && L10nCode.isSupported(raw)) {
      notifier.value = L10nCode.values.firstWhere((e) => e.languageCode == raw);
    }
  }

  Future<void> setLanguage(L10nCode code) async {
    notifier.value = code;
    await _storage.write(key: _key, value: code.languageCode);
    // 设置变更进操作日志：「重启后语言丢了」这类问题的第一问就是
    // 「上次有没有人改过语言、改成了什么」。
    AppLog.audit('settings.locale.set', attrs: {'lang': code.languageCode});
  }
}
