import 'package:flutter/material.dart';

import '../data/machines_repository.dart';
import '../data/machine_entry.dart';
import '../l10n/generated/app_localizations.dart';
import '../ui/theme.dart';

/// 屏 G → 证书锁定（TOFU）管理页（PRD §7 信息架构）。
///
/// **只读**。删 pin 是安全敏感操作：pin 是配对时 TOFU 学到的指纹，删掉它
/// 等于把这条链路降级回「首次连接即信任」，而用户真正想要的恢复路径是在
/// 电脑上重新配对（那样会学到新指纹）。所以这里一个删除入口都不给，也不
/// 留一个按下去没反应的死按钮。
class PinsPage extends StatefulWidget {
  const PinsPage({super.key, required this.store});

  final MachinesStore store;

  @override
  State<PinsPage> createState() => _PinsPageState();
}

class _PinsPageState extends State<PinsPage> {
  @override
  void initState() {
    super.initState();
    widget.store.machines.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.machines.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final machines = widget.store.machines.value;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsPinsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.l, AppTheme.s, AppTheme.l, AppTheme.xxl),
        children: [
          _Note(l10n.pinsHowTofu),
          const SizedBox(height: AppTheme.m),
          if (machines.isEmpty)
            _Note(l10n.pinsEmptyTitle, dim: true)
          else
            ...machines.map((m) => _PinRow(entry: m)),
          const SizedBox(height: AppTheme.m),
          _Note(l10n.pinsReadOnlyNote, dim: true),
        ],
      ),
    );
  }
}

/// 一台机器的 pin 状态。http 链路没有 TLS，也就无从学指纹——这不是「没配
/// 好」，是正确的最终状态，所以照实写出来而不是显示成缺失。
class _PinRow extends StatelessWidget {
  const _PinRow({required this.entry});

  final MachineEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final pin = entry.certPin;
    final host = entry.params.relayOrigin.host;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTheme.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
              pin == null ? Icons.lock_open_rounded : Icons.lock_rounded,
              size: 16,
              color: pin == null ? AppTheme.inkDim : AppTheme.accent,
            ),
            const SizedBox(width: AppTheme.s),
            Expanded(
              child: Text(host,
                  style: const TextStyle(
                      fontSize: 13, fontFamily: 'monospace')),
            ),
          ]),
          const SizedBox(height: AppTheme.xs),
          if (pin == null)
            Text(l10n.pinsNoPinNeeded,
                style: const TextStyle(fontSize: 11, color: AppTheme.inkDim))
          else ...[
            Text(l10n.pinsFingerprint,
                style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
            const SizedBox(height: AppTheme.xs),
            // 完整指纹原样显示：截断过的指纹没法用来核对，也没法复制去比对。
            SelectableText(pin,
                style: const TextStyle(
                    fontSize: 10.5, fontFamily: 'monospace', height: 1.4)),
          ],
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.dim = false});

  final String text;
  final bool dim;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppTheme.m),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: dim ? AppTheme.inkDim : AppTheme.ink)),
      );
}
