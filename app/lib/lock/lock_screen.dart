import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/lock/biometric_gate.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// 屏 H — lock gate.
///
/// **D-056：这一版真的会校验。** 之前它是占位：画着指纹图标、写「解锁」，按一下
/// 直接 `onUnlocked()` 放行，于是设置页那个开关给了用户一种「凭证受生物识别保护」
/// 的错觉，实际只挡住「离开瞬间被顺手点一下」。
///
/// 三档行为（每档对应一种真实用户，错一档就是错的人被挡在门外）：
///
/// | 设备 | 行为 |
/// |---|---|
/// | 支持且已录入 | 系统弹窗校验；失败留在本页可重试 |
/// | 支持但没录入 | 同样调 `authenticate`，由系统回落到设备 PIN/图案 |
/// | 不支持 | 退回 tap-to-unlock，**并说明这台设备没有生物识别** |
///
/// 第三档刻意不画指纹图标：设备压根不支持，继续画就是在骗用户。
class BiometricLockScreen extends StatefulWidget {
  const BiometricLockScreen({
    super.key,
    required this.onUnlocked,
    this.gate,
  });

  /// 测试注入；null = 真实平台通道。
  final BiometricGate? gate;

  final VoidCallback onUnlocked;

  @override
  State<BiometricLockScreen> createState() => _BiometricLockScreenState();
}

class _BiometricLockScreenState extends State<BiometricLockScreen> {
  BiometricGate? _gate;
  BiometricSupport _support = const BiometricSupport.unsupported();

  /// D-061: 试过一次认证、发现这台设备压根没有可用方式，于是降级到手动解锁。
  /// 与「探测阶段就没发现能力」区分开：后者是「这台设备没有生物识别」，
  /// 前者是「它自称有，试了才发现没有」——后者的话要说出来，否则用户会以为
  /// 自己哪里按错了。
  bool _degraded = false;

  bool _probing = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final gate = widget.gate ?? LocalAuthBiometricGate();
    _gate = gate;
    final support = await resolveBiometricSupport(gate);
    if (!mounted) return;
    setState(() {
      _support = support;
      _probing = false;
    });
    // 支持的设备不等用户再点一下：锁屏出现就该直接弹系统窗。真正需要手势的
    // 是失败之后的重试，那才是 [ _attempt ] 的事。
    if (support.supported) _attempt();
  }

  Future<void> _attempt() async {
    final gate = _gate;
    if (gate == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final l10n = L10n.of(context);
    final result = await gate.authenticate(reason: l10n.lockReason);
    if (!mounted) return;
    switch (result) {
      case BiometricResultSuccess():
        setState(() {
          _busy = false;
          _error = null;
        });
        widget.onUnlocked();
      case BiometricResultFailed(cancelled: final cancelled):
        setState(() {
          _busy = false;
          // 主动取消不是错误，说「失败」会让人以为系统拒绝了他。
          _error = cancelled ? l10n.lockCancelled : l10n.lockFailed;
        });
      case BiometricResultUnavailable():
        // D-061：`unavailable` 意味着这台设备**没有任何可用的认证方式**
        // （没录指纹、没设 PIN/图案/密码——硬件在，但没东西可校验）。
        //
        // 原来的写法只把它显示成一句错误 + 留着「再试一次」，于是用户被困在
        // 一个注定失败的循环里：真机上就是这样——这台小米一台凭据都没设，
        // `isDeviceSupported()` 仍然报 true（硬件支持），App 于是弹窗、失败、
        // 让用户重试，而重试一万次结果都一样。**唯一的出路是卸载 App。**
        //
        // 所以这里不是「报错后重试」，而是**当场降级**到手动解锁：图标换成锁、
        // 文案如实说明这台设备没有生物识别、按钮直接放行。设备的物理接触本身
        // 仍是一道门，但不再假装校验过什么。
        setState(() {
          _busy = false;
          _support = const BiometricSupport.unsupported();
          _error = null;
          _degraded = true;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    // 设备不支持时按钮依然存在：**设备的物理接触本身就是一道门**，而 App 里存着
    // 通往别人机器的凭证。只画图标不放行或直接锁死，两头都比这糟。
    final canAuthenticate = _support.supported;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(19),
                  color: AppTheme.accent.withValues(alpha: 0.14),
                  border: Border.all(
                      color: AppTheme.accent.withValues(alpha: 0.3)),
                ),
                child: Icon(
                  // 图标跟着真实能力走：没有生物识别就不画指纹。
                  canAuthenticate
                      ? Icons.fingerprint_rounded
                      : Icons.lock_outline_rounded,
                  size: 28,
                  color: AppTheme.accent,
                ),
              ),
              const SizedBox(height: AppTheme.l),
              Text(l10n.lockTitle,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: AppTheme.xs + 2),
              Text(
                canAuthenticate
                    ? l10n.lockSub
                    : _degraded
                        ? l10n.lockNoBiometricsTried
                        : l10n.lockNoBiometrics,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11.5, color: AppTheme.inkDim),
              ),
              const SizedBox(height: AppTheme.xl),
              if (_probing)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(
                        AppTheme.minTouch + 76, AppTheme.minTouch + 20),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(32)),
                  ),
                  onPressed: _busy
                      ? null
                      : () => canAuthenticate ? _attempt() : widget.onUnlocked(),
                  icon: Icon(
                    _busy
                        ? Icons.hourglass_empty_rounded
                        : canAuthenticate
                            ? Icons.fingerprint_rounded
                            : Icons.lock_open_rounded,
                    size: 26,
                  ),
                  label: Text(_busy ? l10n.lockVerifying : l10n.lockAction),
                ),
              if (_error != null) ...[
                const SizedBox(height: AppTheme.m),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.danger),
                ),
              ],
              const SizedBox(height: AppTheme.m),
              Text(
                canAuthenticate ? l10n.lockFootnote : l10n.lockFootnotePlain,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 10.5, color: AppTheme.inkDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
