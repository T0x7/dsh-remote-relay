import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/lock/biometric_gate.dart';
import 'package:dsh_remote_app/lock/lock_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'factories.dart';

/// D-056: 屏 H 从「点一下就开」变成真的调系统生物识别。
///
/// 之前 `LockScreen` 是一个**占位**：画着指纹图标、写���「解锁」，但
/// `onPressed: onUnlocked` 直接放行，**不校验任何东西**。设置页那个开关也照样
/// 能开、能存、会在启动时拦一道——于是用户以为自己的凭证受生物识别保护，实际
/// 只挡住「离开瞬间被顺手点一下」。
///
/// 三条降级语义是这批的重点，因为它们各自对应一种真实的用户：
///
/// 1. **支持 + 已录入** → 调系统 `authenticate`，成功才解锁；
/// 2. **支持但没录入** → 仍然调 `authenticate`，靠设备 PIN/图案兜底
///    （`biometricOnly: false`）。这是刻意的：设了 `biometricOnly: true` 的用户
///    在没录指纹的机器上会被**永远锁在门外**，而这个 App 里的凭证是别人的机器。
/// 3. **设备不支持** → 退回 tap-to-unlock，但**必须如实说**这台设备没有生物识别。
///    画一个指纹图标说「解锁」是在骗用户。
class _FakeGate implements BiometricGate {
  _FakeGate({this.supported = true, this.passes = true, this.enrolled = const []});

  final bool supported;
  final bool passes;
  final List<BiometricKind> enrolled;
  final calls = <String>[];

  @override

  @override
  Future<bool> isDeviceSupported() async {
    calls.add('isDeviceSupported');
    return supported;
  }

  @override
  Future<bool> get canCheckBiometrics async {
    calls.add('canCheckBiometrics');
    return supported;
  }

  @override
  Future<List<BiometricKind>> getAvailableBiometrics() async {
    calls.add('getAvailableBiometrics');
    return enrolled;
  }

  @override
  Future<BiometricResult> authenticate({required String reason}) async {
    calls.add('authenticate');
    return passes
        ? const BiometricResultSuccess()
        : const BiometricResultFailed();
  }
}

Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

void main() {
  setUp(pinChineseSystemLocale);
  tearDown(unpinSystemLocale);

  group('能力探测', () {
    test('支持且已录入 → 可以走强校验', () async {
      final gate = _FakeGate(enrolled: [BiometricKind.fingerprint]);
      final state = await resolveBiometricSupport(gate);
      expect(state.supportsStrongAuth, isTrue);
      expect(state.enrolled, [BiometricKind.fingerprint]);
    });

    test('支持但没录入 → 走设备凭证兜底，仍算可用', () async {
      // 没录指纹的用户不是「不支持」，他有设备 PIN 可用。把它归到 unsupported
      // 会让 tap-to-unlock 的文案去说「这台设备没有生物识别」，而事实是有的。
      final state = await resolveBiometricSupport(_FakeGate(enrolled: []));
      expect(state.supported, isTrue);
      expect(state.enrolled, isEmpty);
      expect(state.usesDeviceCredential, isTrue);
    });

    test('设备不支持 → 明确 unsupported，不假装', () async {
      final state = await resolveBiometricSupport(_FakeGate(supported: false));
      expect(state.supported, isFalse);
      expect(state.supportsStrongAuth, isFalse);
    });

    test('探测本身抛异常时按不支持处理，不让启动路径崩掉', () async {
      final state = await resolveBiometricSupport(_ThrowingGate());
      expect(state.supported, isFalse,
          reason: '锁屏在启动路径上，探测失败不能变成白屏或崩溃');
    });
  });

  group('锁屏', () {
    testWidgets('支持的设备：锁屏一出现就自动弹系统窗，通过即解锁', (tester) async {
      final gate = _FakeGate(enrolled: [BiometricKind.fingerprint]);
      var unlocked = false;

      await tester.pumpWidget(_host(BiometricLockScreen(
        gate: gate,
        onUnlocked: () => unlocked = true,
      )));
      await tester.pumpAndSettle();

      // 不需要用户多点一下：锁屏出现时直接弹系统窗。真正需要手势的是
      // **失败之后的重试**——那才是按钮存在的理由。
      expect(gate.calls, contains('authenticate'));
      expect(unlocked, isTrue);
    });

    testWidgets('强校验失败就不解锁，且给出可重试的界面', (tester) async {
      final gate = _FakeGate(
        enrolled: [BiometricKind.fingerprint],
        passes: false,
      );
      var unlocked = false;

      await tester.pumpWidget(_host(BiometricLockScreen(
        gate: gate,
        onUnlocked: () => unlocked = true,
      )));
      // 探测 → 自动弹窗 → 失败 → setState 是四段异步；pumpAndSettle 收尾后
      // 再补一拍，确保错误文案已经上屏（否则这条测试在断言一个还没发生的帧）。
      await tester.pumpAndSettle();
      await tester.pump();

      expect(unlocked, isFalse,
          reason: '校验没过就放行 = 这个锁等于没有');
      // 失败后必须还能再试，而不是把用户关在一块死界面上。
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.text('验证未通过，再试一次'), findsOneWidget);

      // 重试这一次真的调了 authenticate——按钮不是摆设。
      final before = gate.calls.where((c) => c == 'authenticate').length;
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(
        gate.calls.where((c) => c == 'authenticate').length,
        before + 1,
      );
    });

    testWidgets('不支持的设备：保留 tap-to-unlock，但如实说明', (tester) async {
      final gate = _FakeGate(supported: false);
      var unlocked = false;

      await tester.pumpWidget(_host(BiometricLockScreen(
        gate: gate,
        onUnlocked: () => unlocked = true,
      )));
      await tester.pumpAndSettle();

      // 文案必须说清楚这台设备没有生物识别——继续画一个指纹图标说「解锁」
      // 是让用户以为校验过什么。
      expect(find.textContaining('没有可用的生物识别'), findsOneWidget);
      expect(
        find.byIcon(Icons.fingerprint_rounded),
        findsNothing,
        reason: '这台设备压根不支持，画指纹图标是在骗人',
      );

      // 但仍可解锁：设备的物理接触本身就是一道门。
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(unlocked, isTrue);
    });

    testWidgets('支持但没录入：仍然走 authenticate，交给设备 PIN 兜底',
        (tester) async {
      final gate = _FakeGate(enrolled: []);
      var unlocked = false;

      await tester.pumpWidget(_host(BiometricLockScreen(
        gate: gate,
        onUnlocked: () => unlocked = true,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(gate.calls, contains('authenticate'),
          reason: '没录指纹不等于没有认证能力，设备 PIN 也在 authenticate 里');
      expect(unlocked, isTrue);
    });
  });

  // D-061：设备**没有任何可用认证方式**时，不能把用户困在注定失败的循环里。
  //
  // 真机（小米 2109119BC）：一台 PIN / 图案 / 密码都没设的机器
  // （`settings get secure lockscreen.password_type` = null，
  // `dumpsys trust` → `deviceLocked=0`），`isDeviceSupported()` 却返回 **true**
  // ——硬件在，所以「支持」；但没录指纹、没设密码，所以**没有任何东西可校验**。
  //
  // 原实现把 `BiometricResultUnavailable` 显示成一句错误 + 留着「再试一次」，
  // 于是用户被困住：弹窗 → 失败 → 重试 → 失败 → …… 唯一的出路是卸载 App。
  // 修法不是把错误文案改好看，是**当场降级**到手动解锁。
  group('D-061 设备没有任何可用认证方式时不能困住用户', () {
    test('重试也解决不了的错误码 → Unavailable（不是 Failed）', () {
      // 这是真机踩到的那个码。D-061 的第一版修法只处理了「锁屏收到
      // Unavailable 之后怎么办」，却在**映射**这一层漏了 uiUnavailable：
      // 它落进 `_ => Failed`，于是锁屏显示「再试一次」，而重试一万次还是
      // 同一个码——用户被困住，唯一的出路是卸载。
      //
      // 真机实测（小米 2109119BC，一台没设任何凭据的机器）：
      //   isDeviceSupported=true  canCheck=true  enrolled=[weak, strong]
      //   LocalAuthException code=LocalAuthExceptionCode.uiUnavailable
      // MIUI 把「屏幕锁」算进了 weak/strong，所以探测阶段完全看不出异常。
      expect(
        LocalAuthBiometricGate.whichResultFor(
          LocalAuthExceptionCode.uiUnavailable,
        ),
        isA<BiometricResultUnavailable>(),
        reason: 'uiUnavailable ＝ 系统弹不出窗，不是「你没通过验证」',
      );
      // 「试太多次了等一会」是另一回事：重试有意义，必须留在 Failed。
      expect(
        LocalAuthBiometricGate.whichResultFor(
          LocalAuthExceptionCode.temporaryLockout,
        ),
        isA<BiometricResultFailed>(),
      );
      expect(
        LocalAuthBiometricGate.whichResultFor(
          LocalAuthExceptionCode.userCanceled,
        ),
        isInstanceOf<BiometricResultFailed>(),
      );
    });

    testWidgets('认证报 unavailable → 当场降级到手动解锁，而不是让用户重试',
        (tester) async {
      // 探测说「支持」（硬件在），认证却答 unavailable（没录指纹、没设密码）。
      final gate = _UnusableGate();
      var unlocked = false;

      await tester.pumpWidget(_host(BiometricLockScreen(
        gate: gate,
        onUnlocked: () => unlocked = true,
      )));
      await tester.pumpAndSettle();

      // 探测阶段先弹了一次 → unavailable → 已经降级。
      expect(find.textContaining('已试过系统验证'), findsOneWidget,
          reason: '要告诉用户「它自称有，试了才发现没有」，否则他以为自己按错了');
      // 降级后不再画指纹：没校验过任何东西，画指纹是在骗人。
      expect(find.byIcon(Icons.fingerprint_rounded), findsNothing);

      // 关键：点解锁**直接放行**，不再弹一个注定失败的系统窗。
      final before = gate.authCalls;
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(unlocked, isTrue,
          reason: '没有可用的认证方式时，锁屏不能变成无法离开的死路');
      expect(gate.authCalls, before,
          reason: '已经降级了就不该再弹系统窗——那正是把用户困住的循环');
    });
  });
}

/// 探测说支持、认证却 unavailable：硬件在但没录指纹也没设密码。
class _UnusableGate extends _FakeGate {
  _UnusableGate() : super(supported: true);

  int authCalls = 0;

  @override
  Future<BiometricResult> authenticate({required String reason}) async {
    authCalls++;
    calls.add('authenticate');
    return const BiometricResultUnavailable();
  }
}

class _ThrowingGate implements BiometricGate {
  @override
  Future<bool> isDeviceSupported() async => throw StateError('no plugin');

  @override
  Future<bool> get canCheckBiometrics async => throw StateError('no plugin');

  @override
  Future<List<BiometricKind>> getAvailableBiometrics() async =>
      throw StateError('no plugin');

  @override
  Future<BiometricResult> authenticate({required String reason}) async =>
      throw StateError('no plugin');

}
