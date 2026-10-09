import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/credentials/session_clock.dart';
import 'package:test/test.dart';

/// §4/§4.1/§7.2 branch coverage with injected time — every verdict the UI
/// will ever render is pinned here.
void main() {
  // Anchors: paired 2026-09-02T10:00Z, 24h Bearer expiring 2026-10-01T12:00Z.
  final paired = DateTime.utc(2026, 9, 2, 10);
  final exp = DateTime.utc(2026, 10, 1, 12);
  final pairedMs = paired.millisecondsSinceEpoch;
  final expMs = exp.millisecondsSinceEpoch;

  SessionClock clock({int? firstPaired, int? expOverride}) => SessionClock(
        expMs: expOverride ?? expMs,
        firstPairedMs: firstPaired ?? pairedMs,
      );

  group('expiry & remaining', () {
    test('isExpired flips at exp', () {
      final c = clock();
      expect(c.isExpired(DateTime.utc(2026, 10, 1, 11, 59)), isFalse);
      expect(c.isExpired(DateTime.utc(2026, 10, 1, 12)), isTrue);
    });

    test('remaining clamps at zero', () {
      expect(clock().remaining(DateTime.utc(2026, 10, 2)).inSeconds, 0);
      expect(clock().remaining(DateTime.utc(2026, 10, 1, 6)).inHours, 6);
    });
  });

  group('chip stage colour ladder (§7.1)', () {
    test('≥6h neutral · 1–6h amber · ≤1h red', () {
      final c = clock();
      expect(c.chipStage(DateTime.utc(2026, 10, 1, 5)), ChipStage.neutral); // 7h
      expect(c.chipStage(DateTime.utc(2026, 10, 1, 6)), ChipStage.warn); // 6h
      expect(c.chipStage(DateTime.utc(2026, 10, 1, 10)), ChipStage.warn); // 2h
      expect(c.chipStage(DateTime.utc(2026, 10, 1, 11)), ChipStage.danger); // 1h
      expect(
          c.chipStage(DateTime.utc(2026, 10, 1, 12)), ChipStage.danger); // 0
    });
  });

  group('renewal scheduling (T-2h)', () {
    test('no renewal before the window, yes inside, no after expiry', () {
      final c = clock();
      expect(c.shouldRenew(DateTime.utc(2026, 10, 1, 9)), isFalse); // 3h left
      expect(c.shouldRenew(DateTime.utc(2026, 10, 1, 10)), isTrue); // 2h left
      expect(c.shouldRenew(DateTime.utc(2026, 10, 1, 12)), isFalse); // expired
    });
  });

  group('three-cause 401 disambiguation (§4.1)', () {
    test('exp passed → expired (24h window)', () {
      expect(clock().diagnose401(DateTime.utc(2026, 10, 1, 13)),
          AuthCause.expired);
    });

    test('exp valid + past 30-day cap → maxAge', () {
      // Freshly renewed bearer, but pairing is 31 days old.
      final freshExp = DateTime.utc(2026, 10, 3, 12).millisecondsSinceEpoch;
      expect(clock(expOverride: freshExp).diagnose401(DateTime.utc(2026, 10, 2, 11)),
          AuthCause.maxAge);
    });

    test('exp valid + within cap + 401 → revoked', () {
      // Pairing 5 days old, bearer still valid, but relay says no.
      expect(clock().diagnose401(DateTime.utc(2026, 9, 7, 10)),
          AuthCause.revoked);
    });

    test('unknown anchor degrades to revoked (never crashes)', () {
      final c = SessionClock(expMs: expMs, firstPairedMs: 0);
      expect(c.diagnose401(DateTime.utc(2026, 9, 7)), AuthCause.revoked);
      expect(c.maxAgeDay(DateTime.utc(2026, 9, 7)), isNull);
      expect(c.maxAgeProgress(DateTime.utc(2026, 9, 7)), 0);
    });
  });

  group('30-day cap progress', () {
    test('day N of 30 and clamped progress', () {
      final c = clock();
      expect(c.maxAgeDay(DateTime.utc(2026, 9, 2, 10)), 1);
      expect(c.maxAgeDay(DateTime.utc(2026, 10, 1, 12)), 30);
      expect(c.maxAgeDay(DateTime.utc(2026, 12, 1)), 90); // raw day count
      expect(c.maxAgeProgress(DateTime.utc(2026, 9, 17, 10)), closeTo(0.5, 0.001));
      expect(c.maxAgeProgress(DateTime.utc(2027, 1, 1)), 1.0); // clamped
    });
  });
}
