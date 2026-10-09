import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../ui/theme.dart';
import 'locale_store.dart';

/// 屏 G → 语言页（PRD §7 信息架构：中文 / English 二选一）。
///
/// 选中的值 = 已持久化的偏好；没有偏好时 = 当前真实生效的 locale，所以进
/// 来看到的永远是"现在到底是什么语言"，不是一份和界面可能对不上的设置。
///
/// **D-052 已接线**：`MaterialApp.locale` 读 `LocaleStore.notifier.value`
/// （`lib/main.dart`），`AppRoot` 往下传的就是这一个实例。所以在这儿勾一下，
/// 整个 App 立刻换语言，不用重启。接线之前 `main.dart` 写死 `Locale('zh')`，
/// 本页就只剩「选择并持久化」而没有任何消费者——一个看起来能用的开关。
class LanguagePage extends StatefulWidget {
  const LanguagePage({super.key, required this.store});

  final LocaleStore store;

  @override
  State<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<LanguagePage> {
  @override
  void initState() {
    super.initState();
    widget.store.notifier.addListener(_onChanged);
    widget.store.hydrate();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.notifier.removeListener(_onChanged);
    super.dispose();
  }

  /// 语言名用**自称**（endonym），中英界面都显示同一个词：挑语言的人是在
  /// 找自己认识的那个词，"English" 配 "英文" 只会让人多读一眼。
  String _endonym(L10n l10n, L10nCode code) => switch (code) {
        L10nCode.zh => l10n.languageOptionZh,
        L10nCode.en => l10n.languageOptionEn,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final picked = widget.store.notifier.value;
    // 真实生效的 locale：反映屏幕上正在显示的语言。
    final effective = L10nCode.of(Localizations.localeOf(context)) ?? picked;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsLanguageTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.l, AppTheme.s, AppTheme.l, AppTheme.xxl),
        children: [
          // RadioGroup 统一管选中态：两个 tile 的勾选状态必须同源，分开写
          // 迟早会只改一个。
          RadioGroup<L10nCode>(
            // 还没选过时，用当前生效的语言打勾——选项状态必须和屏幕一致。
            groupValue: picked ?? effective,
            onChanged: (v) {
              if (v != null) widget.store.setLanguage(v);
            },
            child: Column(
              children: [
                for (final code in L10nCode.values)
                  RadioListTile<L10nCode>(
                    value: code,
                    title: Text(_endonym(l10n, code),
                        style: const TextStyle(fontSize: 14)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.m),
          Container(
            padding: const EdgeInsets.all(AppTheme.m),
            decoration: BoxDecoration(
              color: AppTheme.surfaceHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  effective == null
                      ? l10n.languageEffectiveUnknown
                      : l10n.languageEffective(_endonym(l10n, effective)),
                  style: const TextStyle(fontSize: 11.5, height: 1.6),
                ),
                const SizedBox(height: AppTheme.xs),
                Text(l10n.languageStartupNote,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.inkDim, height: 1.6)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
