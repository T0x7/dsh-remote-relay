import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../ui/theme.dart';
import 'about_info.dart';

/// 屏 G → 关于页（PRD §7 信息架构：版本 / 协议 v:1 / 许可 / 源码）。
///
/// 值全部取自 [about_info.dart] 的常量，页面里不写版本号——PRD §7.3 明确
/// 「App 版本随仓库 tag」，写死第二份就等于给自己埋一个漂移源。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsAboutTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.l, AppTheme.s, AppTheme.l, AppTheme.xxl),
        children: [
          _Row(l10n.aboutAppVersion, kAppVersion),
          _Row(l10n.aboutProtocolVersion, '$kTunnelProtocolVersion'),
          _Row(l10n.aboutLicense, kLicense),
          _Row(l10n.aboutSource, kSourceRepositoryUrl),
          const SizedBox(height: AppTheme.m),
          Container(
            padding: const EdgeInsets.all(AppTheme.m),
            decoration: BoxDecoration(
              color: AppTheme.surfaceHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(l10n.aboutNoOtaNote,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.inkDim, height: 1.6)),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTheme.s + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 108,
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: AppTheme.inkDim)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
            ),
          ],
        ),
      );
}
