import 'package:dsh_remote_core/credentials/session_clock.dart';
import 'package:flutter/material.dart';

/// Design tokens — mirrors docs/app-ui-mockups.html §01 (spacing/size table +
/// palette). Dark-first Material 3; light theme derives from the same seed.
class AppTheme {
  AppTheme._();

  // Palette (mockup §01 swatches)
  static const Color bg = Color(0xFF0E1316);
  static const Color surface = Color(0xFF151C20);
  static const Color surfaceHigh = Color(0xFF1C2529);
  static const Color ink = Color(0xFFE8EDEF);
  static const Color inkDim = Color(0xFF93A7AE);
  static const Color accent = Color(0xFF34D399); // emerald — actions only
  static const Color warn = Color(0xFFF5B74F); // reconnecting / expiring
  static const Color danger = Color(0xFFF87171); // dead credential / revoke

  /// Hairline border and dividers (mockup §01). Sits just above `surface` so
  /// separation reads without a hard line.
  static const Color line = Color(0xFF223038);

  // 4px spacing grid (mockup §01 token table)
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 20;
  static const double xxl = 24;

  /// Touch target floor: visual size may be small (9px status dot), the
  /// touch area never is.
  static const double minTouch = 44;

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      surface: bg,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceHigh,
      error: danger,
    );
    return _base(scheme);
  }

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2F6F5E),
      brightness: Brightness.light,
    ).copyWith(error: const Color(0xFFB34A4A));
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) => ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: scheme.surface,
        cardTheme: CardThemeData(
          color: scheme.surfaceContainer,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
          ),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: surfaceHigh,
          contentTextStyle: const TextStyle(color: ink, fontSize: 12),
        ),
      );
}

/// Status-dot + label pair — status is never color-only (§12 a11y).
class StatusDot extends StatelessWidget {
  const StatusDot(this.stage, {super.key, this.size = 9});

  final ChipStage stage;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: switch (stage) {
            ChipStage.neutral => AppTheme.accent,
            ChipStage.warn => AppTheme.warn,
            ChipStage.danger => AppTheme.danger,
          },
          boxShadow: [
            if (stage == ChipStage.neutral)
              BoxShadow(
                  color: AppTheme.accent.withValues(alpha: 0.5),
                  blurRadius: 8),
          ],
        ),
      );
}

/// Countdown chip — colour ladder from the session clock verdict.
class CountdownChip extends StatelessWidget {
  const CountdownChip(this.label, this.stage, {super.key});

  final String label;
  final ChipStage stage;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: switch (stage) {
            ChipStage.neutral => AppTheme.surfaceHigh,
            ChipStage.warn => AppTheme.warn.withValues(alpha: 0.12),
            ChipStage.danger => AppTheme.danger.withValues(alpha: 0.12),
          },
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 10.5,
            color: switch (stage) {
              ChipStage.neutral => AppTheme.inkDim,
              ChipStage.warn => AppTheme.warn,
              ChipStage.danger => AppTheme.danger,
            },
          ),
        ),
      );
}
