import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/error_copy.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// L2 inline error card (design §7.2): human copy first, with the raw engine
/// code on the mono line beneath so a bug report carries the real identifier.
///
/// Shared by every screen that renders an engine failure in context — the
/// conversation, the session list, and later the team and jobs pages — so the
/// three-段式 contract (copy → detail → no code leak) has exactly one
/// implementation.
class InlineErrorCard extends StatelessWidget {
  const InlineErrorCard({super.key, required this.error, required this.l10n});

  final AppError error;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final detail = errorDetailLine(error);
    return Container(
      padding: const EdgeInsets.all(AppTheme.m),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.06),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(AppTheme.m),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(errorCopy(error, l10n),
              style: const TextStyle(fontSize: 12.5, color: AppTheme.ink)),
          if (detail != null) ...[
            const SizedBox(height: AppTheme.xs),
            Text(detail,
                style: const TextStyle(
                    fontSize: 10, fontFamily: 'monospace', color: AppTheme.inkDim)),
          ],
        ],
      ),
    );
  }
}
