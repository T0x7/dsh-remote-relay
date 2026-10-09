import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_options.dart';

/// App settings (屏 G toggles) persisted in the secure store as one JSON.
class SettingsStore {
  SettingsStore({FlutterSecureStorage? storage})
      // D-054: 同 locale_store —— 必须与 machines 用同一套加密选项。
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: kSecureAndroidOptions,
              iOptions: kSecureIOSOptions,
            );

  static const _key = 'dsh_remote.settings.v1';

  /// T1.12: the 提醒 switch has more than one reader — the 屏 G page writes it,
  /// the reminder router reads it — and the two hold **different** instances
  /// over the same key. A per-instance [notifier] cannot cross that gap (the
  /// write would land on a page's store and never reach the reader), so every
  /// write publishes the whole snapshot here and any interested instance folds
  /// it in. Without this the toggle is a switch that only the settings page can
  /// see, which is exactly what it was before the router existed.
  static final _changes = StreamController<SettingsSnapshot>.broadcast();

  /// Every settings write, whichever instance made it.
  static Stream<SettingsSnapshot> get changes => _changes.stream;

  final FlutterSecureStorage _storage;
  final notifier = ValueNotifier<SettingsSnapshot>(const SettingsSnapshot());

  Future<void> hydrate() async {
    String? raw;
    try {
      raw = await _storage.read(key: _key);
    } on Object {
      return; // tests / missing channel → defaults
    }
    if (raw != null && raw.isNotEmpty) {
      try {
        notifier.value = SettingsSnapshot.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
        _publish();
      } catch (_) {/* corrupted → defaults */}
    }
  }

  Future<void> _persist() =>
      _storage.write(key: _key, value: jsonEncode(notifier.value.toJson()));

  /// Publish a snapshot to every instance, including one that only ever read
  /// the key (a cold `hydrate` in a second store).
  void _publish() {
    if (!_changes.isClosed) _changes.add(notifier.value);
  }

  Future<void> setLockEnabled(bool v) async {
    notifier.value = notifier.value.copyWith(lockEnabled: v);
    _publish();
    await _persist();
  }

  Future<void> setRemindersEnabled(bool v) async {
    notifier.value = notifier.value.copyWith(remindersEnabled: v);
    _publish();
    await _persist();
  }
}

class SettingsSnapshot {
  const SettingsSnapshot({this.lockEnabled = false, this.remindersEnabled = true});

  /// 生物识别锁（屏 H 门）。local_auth 接线在下一批；开关先持久化。
  final bool lockEnabled;

  /// 前台提醒（无后台推送，2026-09-30 拍板）。
  final bool remindersEnabled;

  SettingsSnapshot copyWith({bool? lockEnabled, bool? remindersEnabled}) =>
      SettingsSnapshot(
        lockEnabled: lockEnabled ?? this.lockEnabled,
        remindersEnabled: remindersEnabled ?? this.remindersEnabled,
      );

  Map<String, dynamic> toJson() =>
      {'lockEnabled': lockEnabled, 'remindersEnabled': remindersEnabled};

  factory SettingsSnapshot.fromJson(Map<String, dynamic> j) =>
      SettingsSnapshot(
        lockEnabled: (j['lockEnabled'] as bool?) ?? false,
        remindersEnabled: (j['remindersEnabled'] as bool?) ?? true,
      );
}
