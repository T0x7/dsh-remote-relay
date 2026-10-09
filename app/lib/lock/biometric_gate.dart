import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// D-056: 屏 H 的认证能力接缝。
///
/// 屏 H 之前是**占位**：画着指纹图标、写「解锁」，按一下直接放行。设置页的开关
/// 能开能存、启动时会拦一道，于是用户以为凭证受生物识别保护，实际只挡住「离开
/// 瞬间被顺手点一下」。
///
/// 这里把平台通道封在一个接口后面，有两个理由：
/// - widget 测试没法真的按下用户的指纹，而这三条降级路径（支持 / 没录入 /
///   不支持）恰恰是最容易写错的地方，必须能被测；
/// - 「这台设备有没有生物识别」是**运行时**的事实，不该在编译期定死。

/// 设备上可用/已录入的生物识别种类。
///
/// 与平台的 `BiometricType` 分开，是为了不让「界面文案」直接依赖插件的枚举——
/// 插件换枚举值时，改动收敛在这一个文件里。
enum BiometricKind { fingerprint, face, iris, other }

/// 一次认证的结果。
///
/// 只区分「过 / 不过」是不够的：用户主动取消和系统报错在 UI 上要说的不是同一句
/// 话（一个可以再试，一个该提示去系统设置里开）。
sealed class BiometricResult {
  const BiometricResult();
}

class BiometricResultSuccess extends BiometricResult {
  const BiometricResultSuccess();
}

/// 用户没通过。`cancelled` 为 true 表示是用户自己取消/点错，而不是被系统拒了。
class BiometricResultFailed extends BiometricResult {
  const BiometricResultFailed({this.cancelled = false});
  final bool cancelled;
}

/// 设备侧出问题了（没录生物识别、硬件被锁、生物识别被禁用等）。
class BiometricResultUnavailable extends BiometricResult {
  const BiometricResultUnavailable({this.reason});
  final String? reason;
}

/// 认证能力接缝。生产用 [LocalAuthBiometricGate]，测试用内存实现。
abstract interface class BiometricGate {
  /// 这台设备**能**做本地认证吗（含设备 PIN/图案，不只生物识别）。
  Future<bool> isDeviceSupported();

  /// 硬件层面能不能读生物特征。
  Future<bool> get canCheckBiometrics;

  /// 用户**已经录入**了哪些。没录入 ≠ 不支持，见 [BiometricSupport]。
  Future<List<BiometricKind>> getAvailableBiometrics();

  /// 发起一次认证。[reason] 会被系统弹窗原样显示，所以是用户可见文案。
  Future<BiometricResult> authenticate({required String reason});
}

/// 探测结果。[usesDeviceCredential] 是这批最重要的一格。
class BiometricSupport {
  const BiometricSupport({
    required this.supported,
    required this.enrolled,
  });

  const BiometricSupport.unsupported()
      : supported = false,
        enrolled = const [];

  /// 设备能认证（含 PIN/图案）。
  final bool supported;

  /// 已录入的生物识别。
  final List<BiometricKind> enrolled;

  /// 能真正校验生物特征。
  bool get supportsStrongAuth => supported && enrolled.isNotEmpty;

  /// 只能靠设备 PIN/图案这类凭证。
  ///
  /// **这一格是「没录指纹的用户」的命脉。** `local_auth` 的
  /// `biometricOnly: false`（默认）会让系统弹窗在生物识别失败后回落到设备
  /// 凭证；设成 `true` 则直接拒。于是没录指纹的用户在 `biometricOnly: true`
  /// 下会被**永远锁在门外**——而这个 App 里的凭证通往的是别人的机器。
  bool get usesDeviceCredential => supported && enrolled.isEmpty;
}

/// 一次性问清设备能力。
///
/// 任何一步抛异常都按「不支持」收敛：这段跑在**启动路径**上（AppRoot 读
/// `lockEnabled` 后就可能把锁屏推到最前），探测失败不该变成白屏或崩溃，退回
/// tap-to-unlock 才是安全的一侧。
Future<BiometricSupport> resolveBiometricSupport(BiometricGate gate) async {
  try {
    if (!await gate.isDeviceSupported()) {
      return const BiometricSupport.unsupported();
    }
    final enrolled = await gate.getAvailableBiometrics();
    return BiometricSupport(supported: true, enrolled: enrolled);
  } on Object {
    return const BiometricSupport.unsupported();
  }
}

/// 平台实现。
class LocalAuthBiometricGate implements BiometricGate {
  LocalAuthBiometricGate([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isDeviceSupported() => _auth.isDeviceSupported();

  @override
  Future<bool> get canCheckBiometrics => _auth.canCheckBiometrics;

  @override
  Future<List<BiometricKind>> getAvailableBiometrics() async {
    final raw = await _auth.getAvailableBiometrics();
    return [
      for (final type in raw)
        switch (type) {
          BiometricType.fingerprint => BiometricKind.fingerprint,
          BiometricType.face => BiometricKind.face,
          BiometricType.iris => BiometricKind.iris,
          _ => BiometricKind.other,
        },
    ];
  }

  @override
  Future<BiometricResult> authenticate({required String reason}) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        // `biometricOnly: false` 是刻意的：没录指纹的设备靠 PIN/图案解锁，
        // 理由见 [BiometricSupport.usesDeviceCredential]。
        biometricOnly: false,
        // 切后台再回来时由插件自动重试，而不是甩一个错误给用户。
        persistAcrossBackgrounding: true,
      );
      return ok
          ? const BiometricResultSuccess()
          : const BiometricResultFailed();
    } on LocalAuthException catch (e) {
      AppLog.w('lock', 'local_auth: ${e.code} — ${e.description}');
      return whichResultFor(e.code, description: e.description);
    } on Object catch (e) {
      AppLog.w('lock', 'local_auth: unexpected $e');
      return const BiometricResultUnavailable();
    }
  }

  /// D-061: 把一个异常码映射成结果。**独立成方法**是为了能直接测试它——
  /// 上一版它是 `authenticate` 里一个内联 switch，漏掉 `uiUnavailable` 时
  /// 没有任何测试会红，而真机上的后果是用户被锁在 App 外面出不来。
  @visibleForTesting
  static BiometricResult whichResultFor(
    LocalAuthExceptionCode code, {
    String? description,
  }) {
    return switch (code) {
      // 用户自己取消：这不是「验证失败」，界面上要说的话不一样。
      LocalAuthExceptionCode.userCanceled =>
        const BiometricResultFailed(cancelled: true),
      // 这几个码的含义是「**环境**不支持/不允许弹窗」，不是「用户没通过验证」。
      // 混进 Failed 会让锁屏显示「再试一次」，把用户困在无限重试里——
      // D-061 在真机上就是这么发生的：这台机器一台凭据都没设，
      // `getAvailableBiometrics()` 却回报 weak/strong（MIUI 把屏幕锁也算成
      // 生物识别），于是 App 弹窗 → `uiUnavailable` → 「再试一次」→ 再试
      // 还是 `uiUnavailable` → 唯一的出路是卸载 App。
      //
      // 所以凡是**重试也解决不了**的，一律归 Unavailable，交给锁屏当场降级
      // 到手动解锁。`temporaryLockout` / `biometricLockout` 不在此列：那两个
      // 真的是「试太多次了等一会」，重试有意义，留在 Failed。
      LocalAuthExceptionCode.uiUnavailable ||
      LocalAuthExceptionCode.authInProgress ||
      LocalAuthExceptionCode.noBiometricsEnrolled ||
      LocalAuthExceptionCode.noBiometricHardware ||
      LocalAuthExceptionCode.noCredentialsSet ||
      LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
        BiometricResultUnavailable(reason: description),
      _ => const BiometricResultFailed(),
    };
  }
}
