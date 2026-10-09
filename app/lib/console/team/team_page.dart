import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// The subagent team view (mockup 屏 N).
///
/// Three facts measured against the live engine on 2026-10-02 shape this
/// screen, and each one contradicts a shortcut the mockup invites:
///
/// 1. **There is no `activity` field.** A catalog entry carries exactly
///    `mode`, `label`, `id`, `createdAt` (verified: `entry keys: mode, label,
///    id, createdAt`). The Host's richer `activity` column never reaches the
///    wire, so this screen must **not** draw a live running dot per child.
///    What it can show is the child's `mode` — which is also the read-only
///    rule (§9.2).
/// 2. **`label` is a long description, not a name.** Real labels run to a
///    median of 27 and a maximum of 64 characters ("盘中盯盘团队·实时热点新闻腿：
///    news_scan 未判读快讯…"). Truncating to one line would hide the part that
///    distinguishes two children, so the label wraps fully.
/// 3. **The parent link is implicit.** A catalog entry has no
///    `parentSessionId`; the parent is whichever session's projection was read.
///    So the screen takes the parent as an argument and never claims otherwise.
class TeamPage extends StatelessWidget {
  const TeamPage({
    super.key,
    required this.parentSessionId,
    required this.projections,
    required this.l10n,
    required this.onOpenChild,
  });

  final String parentSessionId;
  final SessionProjectionBaseline? projections;
  final L10n l10n;

  /// Open one child as a read-only conversation.
  final void Function(SubagentCatalogEntry child) onOpenChild;

  @override
  Widget build(BuildContext context) {
    final catalog = projections?.values.subagentCatalog;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.teamTitle,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        backgroundColor: AppTheme.bg,
      ),
      body: catalog == null
          ? _TeamNotice(text: l10n.teamCatalogUnavailable, icon: Icons.help_outline)
          : catalog.isEmpty
              ? _TeamNotice(text: l10n.teamEmpty, icon: Icons.group_outlined)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(
                      AppTheme.m, AppTheme.m, AppTheme.m, AppTheme.xl),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                          left: AppTheme.s, bottom: AppTheme.s),
                      child: Text(l10n.teamCount(catalog.length),
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.inkDim)),
                    ),
                    for (final child in catalog)
                      _ChildCard(
                        entry: child,
                        l10n: l10n,
                        onTap: () => onOpenChild(child),
                      ),
                    const SizedBox(height: AppTheme.m),
                    Text(l10n.teamFooter,
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.inkDim)),
                  ],
                ),
    );
  }
}

class _TeamNotice extends StatelessWidget {
  const _TeamNotice({required this.text, required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: AppTheme.inkDim),
              const SizedBox(height: AppTheme.m),
              Text(text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
            ],
          ),
        ),
      );
}

class _ChildCard extends StatelessWidget {
  const _ChildCard({
    required this.entry,
    required this.l10n,
    required this.onTap,
  });

  final SubagentCatalogEntry entry;
  final L10n l10n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Read-only is derived from `mode` — the protocol has no `readOnly` flag,
    // and a one-shot child is terminal (§9.2).
    final readOnly = !entry.acceptsInput;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.m),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppTheme.s),
        padding: const EdgeInsets.all(AppTheme.m),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.m),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // A mode dot, NOT an activity dot: the wire carries no
                // running state, so a pulsing "running" indicator here would
                // be fiction.
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: readOnly ? AppTheme.inkDim : AppTheme.accent,
                  ),
                ),
                const SizedBox(width: AppTheme.s),
                Expanded(
                  child: Text(
                    // Labels are long descriptions in practice; keep them
                    // short when they are genuinely an id.
                    entry.label == null || entry.label!.isEmpty
                        ? entry.id
                        : entry.label!,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.ink),
                  ),
                ),
                if (readOnly)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.s, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceHigh,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(l10n.teamReadOnly,
                        style: const TextStyle(
                            fontSize: 9.5, color: AppTheme.inkDim)),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.xs),
            Text(
              readOnly ? l10n.teamModeTerminal : l10n.teamModeContinuable,
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                color: readOnly ? AppTheme.inkDim : AppTheme.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
