import 'dart:io';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_core/net/tofu_pins.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/pin_store.dart';
import 'package:dsh_remote_app/main.dart';
import 'package:dsh_remote_app/pairing/pairing_flow.dart';

import 'factories.dart';

/// D-025 — the TOFU pin learned during the pairing verify request must land
/// in `MachineEntry.certPin` (persisted with the machine), and the console
/// must seed its pin table from it. Before this wiring every steady-state
/// client (console / detail / renewal) built an EMPTY pin table and failed
/// closed at the TLS layer — real-device symptom: yellow banner, no data,
/// engine side never sees the device.
void main() {
  // The D-084 group below drives the real pairing sheet and asserts on Chinese
  // copy, and the App follows the system language (D-052) — without pinning the
  // locale those taps silently find nothing on the en_US test platform.
  setUp(pinChineseSystemLocale);
  tearDown(unpinSystemLocale);

  group('buildPairedEntry (pairing → certPin)', () {
    test('captures the learned fingerprint into certPin', () {
      final url = mintTestUrl();
      final params = parseSignedUrl(url);
      final entry = buildPairedEntry(params, 'a' * 64);
      expect(entry.id, params.sessionId);
      expect(entry.name, params.name);
      expect(entry.firstPairedMs, params.tMs);
      expect(entry.certPin, 'a' * 64);
    });

    test('null pin (plain-http relay / overridden verifier) stays null', () {
      final params = parseSignedUrl(mintTestUrl());
      expect(buildPairedEntry(params, null).certPin, isNull);
    });

    test('certPin survives the secure-store round trip', () {
      final params = parseSignedUrl(mintTestUrl());
      final entry = buildPairedEntry(params, 'b' * 64);
      final restored =
          MachineEntry.decodeList(MachineEntry.encodeList([entry])).single;
      expect(restored.certPin, 'b' * 64);
    });
  });

  group('pinStoreFor (console pin-table seeding)', () {
    test('seeds the relay host with the machine pin', () {
      final url = mintTestUrl(relay: 'https://relay.example.com');
      final params = parseSignedUrl(url);
      final entry = MachineEntry(
        id: params.sessionId,
        name: 'relay-machine',
        params: params,
        firstPairedMs: params.tMs,
        certPin: 'c' * 64,
      );
      final store = pinStoreFor(entry);
      expect(store.pins, {'relay.example.com': 'c' * 64});
    });

    test('entry without a pin yields an empty table (fail closed)', () {
      final entry = machineFrom(mintTestUrl(relay: 'https://relay.example.com'));
      expect(entry.certPin, isNull); // factories build pre-D-025 entries
      expect(pinStoreFor(entry).pins, isEmpty);
    });

    // D-025 follow-up: the bug was one client building its pin table by hand
    // and forgetting the pin. The seeding existed in three copies (console,
    // machine detail, renewal scheduler), so a fourth was one copy-paste away.
    // A source-level pin keeps the count honest without a behavioural test that
    // would pass even if someone re-inlined the logic elsewhere.
    //
    // Exactly two files may construct MemoryPinStore directly:
    // - data/pin_store.dart  — the shared per-machine seeding itself
    // - pairing_flow.dart    — the pairing-time LEARN table (fresh, disposable,
    //   learnOnFirstConnect: true); semantically the opposite of seeding.
    test('no other module rebuilds the pin table by hand', () {
      final lib = Directory('lib');
      const allowed = {'lib/data/pin_store.dart', 'lib/pairing/pairing_flow.dart'};
      final offenders = <String>[];
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (allowed.contains(entity.path)) continue;
        if (entity.path.contains('generated')) continue;
        final source = entity.readAsStringSync();
        if (source.contains('MemoryPinStore()')) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'steady-state clients must build the TOFU table via '
              'pinStoreFor() — a raw MemoryPinStore is how D-025 happened; '
              'pairing_flow.dart is the one legitimate learn-table exception');
    });
  });

  // D-084 — the group above proves a pin, once learned, travels correctly.
  // It says nothing about whether it is ever learned, and on a real device it
  // never is: `learnOnFirstConnect` fires from `badCertificateCallback`, which
  // dart:io only calls when certificate validation FAILS. A relay with a
  // Let's Encrypt cert validates normally, the callback never runs, and the
  // machine is stored with `certPin: null` — so every steady-state client
  // fails closed with an empty pin table while the app appears to work, and
  // Settings cheerfully says "No https relay yet" about a relay that is
  // right there on screen. 真机实证：配对的是 https relay，pin 表却恒空。
  group('D-084：https relay 的 pin 必须真的学到', () {
    test('plain-http relay has no certificate to pin', () async {
      expect(await probePeerFingerprint(Uri.parse('http://127.0.0.1:9/')),
          isNull,
          reason: '明文传输没有对端证书，probe 应直接放弃而不是空跑一次 TLS');
    });

    testWidgets('配对成功时抓到的指纹要写进 certPin', (tester) async {
      PairingFlowSheet.verifierOverride = (_) async => PairingVerifyResult.valid;
      PairingFlowSheet.pinProbeOverride = (origin) async {
        expect(origin.scheme, 'https');
        return 'd' * 64;
      };
      addTearDown(() {
        PairingFlowSheet.verifierOverride = null;
        PairingFlowSheet.pinProbeOverride = null;
      });

      final repo = InMemoryMachinesRepository();
      final store = MachinesStore(repo: repo);
      await tester.pumpWidget(DshRemoteApp(store: store));

      await tester.tap(find.text('扫码 / 粘贴链接'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField),
          mintTestUrl(relay: 'https://relay.example.com').toString());
      await tester.tap(find.text('解析链接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('锁定并连接'));
      await tester.pumpAndSettle();

      expect(store.machines.value.single.certPin, 'd' * 64,
          reason: '配对是唯一一次「见到对端证书并固定它」的机会，错过就没有第二次');
    });

    testWidgets('http relay 不做 probe，pin 保持 null', (tester) async {
      PairingFlowSheet.verifierOverride = (_) async => PairingVerifyResult.valid;
      var probed = false;
      PairingFlowSheet.pinProbeOverride = (_) async {
        probed = true;
        return null;
      };
      addTearDown(() {
        PairingFlowSheet.verifierOverride = null;
        PairingFlowSheet.pinProbeOverride = null;
      });

      final repo = InMemoryMachinesRepository();
      final store = MachinesStore(repo: repo);
      await tester.pumpWidget(DshRemoteApp(store: store));

      await tester.tap(find.text('扫码 / 粘贴链接'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), mintTestUrl().toString());
      await tester.tap(find.text('解析链接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('锁定并连接'));
      await tester.pumpAndSettle();

      expect(probed, isFalse, reason: '明文 relay 无证书可固定，不该白跑一次 probe');
      expect(store.machines.value.single.certPin, isNull);
    });

    testWidgets('probe 失败不阻断配对，但 pin 留空（fail closed 由稳态接管）',
        (tester) async {
      PairingFlowSheet.verifierOverride = (_) async => PairingVerifyResult.valid;
      PairingFlowSheet.pinProbeOverride = (_) async => null; // 抓不到
      addTearDown(() {
        PairingFlowSheet.verifierOverride = null;
        PairingFlowSheet.pinProbeOverride = null;
      });

      final repo = InMemoryMachinesRepository();
      final store = MachinesStore(repo: repo);
      await tester.pumpWidget(DshRemoteApp(store: store));

      await tester.tap(find.text('扫码 / 粘贴链接'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField),
          mintTestUrl(relay: 'https://relay.example.com').toString());
      await tester.tap(find.text('解析链接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('锁定并连接'));
      await tester.pumpAndSettle();

      expect(store.machines.value, hasLength(1),
          reason: '抓证书失败不该把用户挡在门外——配对本身已经验证过 Bearer');
      expect(store.machines.value.single.certPin, isNull);
    });
  });
}
