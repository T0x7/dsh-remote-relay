import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/credentials/session_clock.dart';
import 'package:flutter/material.dart';

import '../data/machine_entry.dart';
import '../l10n/generated/app_localizations.dart';
import '../ui/theme.dart';

/// 屏 I — 会话失效页（三因判别，本地推导）。Entry point: tapping an
/// expired/failed machine card. 重新扫码 reuses the pairing sheet (handled
/// by the caller); 删除机器 removes the entry.
class SessionExpiredPage extends StatelessWidget {
  const SessionExpiredPage({
    super.key,
    required this.entry,
    required this.onRepair,
    required this.onDelete,
    this.lastAuthCause,
  });

  final MachineEntry entry;

  /// Open the pairing flow (caller wires the sheet).
  final VoidCallback onRepair;

  final VoidCallback onDelete;

  /// The relay's 401 verdict when known (drives the cause copy); null →
  /// local inference (exp passed = 24h window).
  final AuthCause? lastAuthCause;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final clock = SessionClock(
        expMs: entry.params.expMs, firstPairedMs: entry.firstPairedMs);
    final cause = lastAuthCause ??
        (clock.isExpired(now) ? AuthCause.expired : AuthCause.revoked);
    final l10n = L10n.of(context);
    final (chip, causeText) = switch (cause) {
      AuthCause.expired => (l10n.expiredChipWindow, l10n.expiredCauseWindow),
      AuthCause.maxAge => (
          l10n.expiredChipMaxAge,
          l10n.expiredCauseMaxAge(clock.maxAgeDay(now) ?? '–')),
      AuthCause.revoked => (l10n.expiredChipRevoked, l10n.expiredCauseRevoked),
      AuthCause.unknown => (l10n.expiredChipUnknown, l10n.expiredCauseUnknown),
    };

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              child: Text(entry.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: AppTheme.s),
          const StatusDot(ChipStage.danger),
        ]),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.danger.withValues(alpha: 0.10),
                  border: Border.all(color: AppTheme.danger.withValues(alpha: 0.28))),
                child: const Icon(Icons.schedule_outlined,
                    size: 26, color: AppTheme.danger),
              ),
              const SizedBox(height: AppTheme.m),
              Text(l10n.expiredTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: AppTheme.s),
              Center(
                child: CountdownChip(chip, ChipStage.danger),
              ),
              const SizedBox(height: AppTheme.m),
              Text(causeText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
              const SizedBox(height: AppTheme.xs + 2),
              Text(l10n.expiredScopeHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: AppTheme.inkDim)),
              const SizedBox(height: AppTheme.m),
              Text(l10n.expiredRepairHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppTheme.inkDim)),
              const SizedBox(height: AppTheme.xl),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(AppTheme.minTouch + 2)),
                onPressed: onRepair,
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                label: Text(l10n.actionRescan),
              ),
              const SizedBox(height: AppTheme.s),
              TextButton(
                style: TextButton.styleFrom(
                    foregroundColor: AppTheme.danger,
                    minimumSize: const Size.fromHeight(AppTheme.minTouch - 6)),
                onPressed: onDelete,
                child: Text(l10n.actionDeleteMachine),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
