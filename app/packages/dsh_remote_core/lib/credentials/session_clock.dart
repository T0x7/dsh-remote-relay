/// Session clock — the pure decision core of the credential lifecycle
/// (design §4/§4.1, §7.2). Time is ALWAYS injected (`now`), so every branch
/// is unit-testable and the UI/widget layer just renders verdicts.
///
/// Responsibilities:
/// 1. **Three-cause 401 disambiguation** — the relay's 401 body is generic by
///    contract (§7.3), the app decides locally: exp passed = 24h window
///    expired; exp still valid but 401 = revoked OR 30-day cap (first-paired
///    anchor decides which is "likely").
/// 2. **Chip stage** — countdown colour (≥6h neutral / 1–6h amber / <1h red).
/// 3. **Renewal scheduling** — attempt `url-session` re-mint at T-2h.
/// 4. **30-day cap progress** — "day N of 30" reading for the detail page.
library;

import '../api/error_code.dart';

/// Countdown chip colour stage (design §7.1 CountdownChip).
enum ChipStage { neutral, warn, danger }

/// Constants pinned to relay config defaults (server README):
/// `RELAY_SESSION_GRACE_SEC` irrelevant client-side; cap = 30 days.
const sessionMaxAge = Duration(days: 30);
const renewalLead = Duration(hours: 2);
const chipWarnThreshold = Duration(hours: 6);
const chipDangerThreshold = Duration(hours: 1);

class SessionClock {
  const SessionClock({
    required this.expMs,
    required this.firstPairedMs,
  });

  /// Current Bearer's expiry (from the signed URL's `exp`).
  final int expMs;

  /// First-pairing anchor: the session row's `createdAt` (RemoteSessionInfo),
  /// or the original QR's `t` as a bootleg when unknown. 0 = unknown.
  final int firstPairedMs;

  bool isExpired(DateTime now) => now.millisecondsSinceEpoch >= expMs;

  Duration remaining(DateTime now) => Duration(
      milliseconds: (expMs - now.millisecondsSinceEpoch).clamp(0, 1 << 40));

  /// §4.1(2)/§7.2: colour the countdown chip by time-to-live.
  ChipStage chipStage(DateTime now) {
    final left = remaining(now);
    if (left <= chipDangerThreshold) return ChipStage.danger;
    if (left <= chipWarnThreshold) return ChipStage.warn;
    return ChipStage.neutral;
  }

  /// §5: renewal attempt window opens at T-2h.
  bool shouldRenew(DateTime now) {
    final left = remaining(now);
    return !isExpired(now) && left <= renewalLead;
  }

  /// Three-cause verdict for a 401 (design §4.1 + §7.2 `auth.*`).
  AuthCause diagnose401(DateTime now) {
    if (isExpired(now)) return AuthCause.expired;
    // exp still valid but the relay said no: the session row is gone server
    // side — revoked by the user, or past the 30-day absolute cap.
    if (firstPairedMs > 0 &&
        now.millisecondsSinceEpoch - firstPairedMs >=
            sessionMaxAge.inMilliseconds) {
      return AuthCause.maxAge;
    }
    return AuthCause.revoked;
  }

  /// Day N of the 30-day absolute cap ("第 N / 30 天"); null when the anchor
  /// is unknown.
  int? maxAgeDay(DateTime now) {
    if (firstPairedMs <= 0) return null;
    final elapsed = now.millisecondsSinceEpoch - firstPairedMs;
    if (elapsed < 0) return 1;
    return elapsed ~/ const Duration(days: 1).inMilliseconds + 1;
  }

  /// 0..1 progress through the absolute cap (for the detail-page second bar).
  double maxAgeProgress(DateTime now) {
    if (firstPairedMs <= 0) return 0;
    final p = (now.millisecondsSinceEpoch - firstPairedMs) /
        sessionMaxAge.inMilliseconds;
    return p.clamp(0.0, 1.0);
  }
}
