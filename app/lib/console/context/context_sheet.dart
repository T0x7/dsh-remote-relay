import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// Context occupancy and its composition (mockup 屏 L).
///
/// Two contract rules are load-bearing here, and both are easy to get wrong:
///
/// - **Absence is not zero.** A missing `contextPressure` means the engine has
///   not reported usage yet, so the screen says so — it does not draw an empty
///   ring that reads as "0% used" (§7.2).
/// - **The three segments are a composition, not a total.** They are
///   fixed-density estimates and deliberately do NOT sum to
///   `projectedTokens`, so the breakdown never claims to reconcile with the
///   headline figure (§7.3).
class ContextSheet extends StatelessWidget {
  const ContextSheet({
    super.key,
    required this.projections,
    required this.l10n,
  });

  final SessionProjectionBaseline? projections;
  final L10n l10n;

  static Future<void> show(
    BuildContext context, {
    required SessionProjectionBaseline? projections,
    required L10n l10n,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppTheme.surface,
        isScrollControlled: true,
        builder: (_) => ContextSheet(projections: projections, l10n: l10n),
      );

  @override
  Widget build(BuildContext context) {
    final values = projections?.values;
    final pressure = values?.contextPressure;
    final breakdown = values?.contextBreakdown;
    final usage = values?.tokenUsage;
    final stats = values?.sessionStats;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppTheme.l, AppTheme.m, AppTheme.l, AppTheme.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.contextTitle,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: AppTheme.l),
              if (pressure == null)
                _Unavailable(l10n: l10n)
              else
                _Occupancy(pressure: pressure, l10n: l10n),
              if (breakdown != null) ...[
                const SizedBox(height: AppTheme.l),
                _Breakdown(breakdown: breakdown, l10n: l10n),
              ],
              if (usage != null || stats != null) ...[
                const SizedBox(height: AppTheme.l),
                _Usage(usage: usage, stats: stats, l10n: l10n),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.l10n});
  final L10n l10n;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppTheme.l),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(AppTheme.m),
        ),
        child: Text(l10n.contextNotReported,
            style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
      );
}

class _Occupancy extends StatelessWidget {
  const _Occupancy({required this.pressure, required this.l10n});

  final ContextPressure pressure;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final ratio = pressure.fillRatio;
    return Row(
      children: [
        SizedBox(
          width: 64,
          height: 64,
          child: ratio == null
              ? const Icon(Icons.radio_button_unchecked,
                  size: 56, color: AppTheme.inkDim)
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 56,
                      height: 56,
                      child: CircularProgressIndicator(
                        value: ratio,
                        strokeWidth: 5,
                        backgroundColor: AppTheme.ink.withValues(alpha: 0.1),
                        valueColor:
                            const AlwaysStoppedAnimation(AppTheme.accent),
                      ),
                    ),
                    Text('${(ratio * 100).round()}%',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ],
                ),
        ),
        const SizedBox(width: AppTheme.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Line(l10n.contextProjected, _tokens(pressure.projectedTokens)),
              _Line(l10n.contextPressure, _tokens(pressure.pressureTokens)),
              _Line(l10n.contextWindow, _tokens(pressure.contextWindow)),
            ],
          ),
        ),
      ],
    );
  }

  static String _tokens(int? value) => value == null ? '—' : '$value';
}

class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.breakdown, required this.l10n});

  final ContextBreakdown breakdown;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final total = breakdown.total;
    final segments = [
      (l10n.contextSegmentSystem, breakdown.systemTokens, AppTheme.warn),
      (l10n.contextSegmentTools, breakdown.toolsTokens, AppTheme.accent),
      (l10n.contextSegmentMessages, breakdown.messageTokens, AppTheme.inkDim),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(l10n.contextBreakdownTitle,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: AppTheme.s),
            // The segments are density estimates, so they never reconcile
            // with `projectedTokens`; saying so prevents a false cross-check.
            Flexible(
              child: Text(l10n.contextBreakdownCaveat,
                  style: const TextStyle(fontSize: 10.5, color: AppTheme.inkDim)),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.s),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 10,
            child: Row(
              children: [
                for (final segment in segments)
                  if (total > 0 && segment.$2 > 0)
                    Expanded(
                      flex: segment.$2,
                      child: ColoredBox(color: segment.$3),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppTheme.s),
        for (final segment in segments)
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: AppTheme.xs),
                decoration:
                    BoxDecoration(color: segment.$3, shape: BoxShape.circle),
              ),
              Expanded(
                  child: Text(segment.$1,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppTheme.inkDim))),
              Text('${segment.$2}',
                  style: const TextStyle(
                      fontSize: 11.5, fontFamily: 'monospace')),
            ],
          ),
      ],
    );
  }
}

class _Usage extends StatelessWidget {
  const _Usage({required this.usage, required this.stats, required this.l10n});

  final TokenUsageProjection? usage;
  final SessionStatsProjection? stats;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final tokensPerSecond = stats?.tokensPerSecond;
    final cacheHit = _cacheHitRate(usage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.contextUsageTitle,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: AppTheme.xs),
        if (usage != null) ...[
          _Line(l10n.contextUsageUncached, '${usage!.uncachedInputTokens}'),
          _Line(l10n.contextUsageCacheRead, '${usage!.cacheReadTokens}'),
          _Line(l10n.contextUsageCacheWrite, '${usage!.cacheWriteTokens}'),
          _Line(l10n.contextUsageOutput, '${usage!.outputTokens}'),
        ],
        if (tokensPerSecond != null)
          _Line(l10n.chatTokensPerSecond(tokensPerSecond.toStringAsFixed(1)),
              ''),
        if (cacheHit != null)
          _Line(l10n.chatCachePercent((cacheHit * 100).round()), ''),
        if (stats != null) _Line(l10n.contextTurns, '${stats!.turns}'),
      ],
    );
  }

  /// Cache hits over total input; null when nothing has been counted yet, so a
  /// fresh session shows "—" rather than a confident 0%.
  static double? _cacheHitRate(TokenUsageProjection? usage) {
    if (usage == null) return null;
    final total = usage.uncachedInputTokens + usage.cacheReadTokens;
    if (total <= 0) return null;
    return usage.cacheReadTokens / total;
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.inkDim))),
            if (value.isNotEmpty)
              Text(value,
                  style: const TextStyle(
                      fontSize: 11.5, fontFamily: 'monospace')),
          ],
        ),
      );
}
