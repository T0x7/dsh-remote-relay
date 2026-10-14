import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/machines_repository.dart';
import '../data/settings_store.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/update_checker.dart';
import 'about_info.dart';
import '../lock/biometric_gate.dart';
import '../ui/theme.dart';
import 'about_page.dart';
import 'language_page.dart';
import 'locale_store.dart';
import 'pins_page.dart';
import '../logging/diagnostics_page.dart';

/// 屏 G — settings: lock / TOFU pins / reminders / language / about.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    required this.settings,
    this.localeStore,
    this.biometricGate,
  });

  final MachinesStore store;
  final SettingsStore settings;

  /// 语言偏好。为 null 时二级页用一次性 store，**不落盘**——屏 G 由
  /// AppRoot 直接构造（见 `lib/app_root.dart`），那里还没有一个跨屏共享
  /// 的 LocaleStore；接线到 main.dart 时把它提上去即可。
  final LocaleStore? localeStore;

  /// D-056: 认证能力接缝。null = 真实平台通道；测试注入内存实现。
  final BiometricGate? biometricGate;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 屏 G 没拿到共享 store 时的一次性实例（见 [SettingsPage.localeStore]）。
  late final LocaleStore _localeStore =
      widget.localeStore ?? LocaleStore();

  /// D-056: 这台设备的认证能力，驱动锁开关的**副标题**。
  ///
  /// 之前副标题写死「placeholder gate; local_auth next batch」——功能没接线时
  /// 如实说明是对的，接线之后它就成了一句谎话。现在换成这台设备的真实能力。
  BiometricSupport? _biometrics;

  @override
  void initState() {
    super.initState();
    widget.settings.notifier.addListener(_onChanged);
    widget.store.machines.addListener(_onChanged);
    _probeBiometrics();
  }

  Future<void> _probeBiometrics() async {
    final support = await resolveBiometricSupport(
      widget.biometricGate ?? LocalAuthBiometricGate(),
    );
    if (!mounted) return;
    setState(() => _biometrics = support);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.settings.notifier.removeListener(_onChanged);
    widget.store.machines.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.settings.notifier.value;
    final machines = widget.store.machines.value;
    final l10n = L10n.of(context);
    final pinned = machines.where((m) => m.certPin != null).toList();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.tabSettings)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.l, AppTheme.s, AppTheme.l, AppTheme.xxl),
        children: [
          Card(
            child: Column(children: [
              _switchTile(
                icon: Icons.fingerprint_rounded,
                title: l10n.settingsLockTitle,
                // D-056: 如实报这台设备的能力，而不是一句「下一批接入」。
                // 探测还没回来时给一个中性说明，而不是先把「不支持」说死。
                subtitle: switch (_biometrics) {
                  null => l10n.settingsLockSubProbing,
                  final s when !s.supported => l10n.settingsLockSubUnsupported,
                  final s when s.usesDeviceCredential =>
                    l10n.settingsLockSubDeviceCredential,
                  _ => l10n.settingsLockSubBiometric,
                },
                value: snap.lockEnabled,
                onChanged: widget.settings.setLockEnabled,
              ),
              _navTile(
                icon: Icons.lock_outline_rounded,
                title: l10n.settingsPinsTitle,
                subtitle: pinned.isEmpty
                    ? l10n.settingsPinsNone
                    : l10n.settingsPinsCount('${pinned.length}'),
                onTap: () => _push(context, PinsPage(store: widget.store)),
              ),
              _switchTile(
                icon: Icons.notifications_active_outlined,
                title: l10n.settingsRemindersTitle,
                subtitle: l10n.settingsRemindersSub,
                value: snap.remindersEnabled,
                onChanged: widget.settings.setRemindersEnabled,
              ),
              _navTile(
                icon: Icons.language_rounded,
                title: l10n.settingsLanguageTitle,
                subtitle: l10n.settingsLanguageSub,
                onTap: () => _push(context, LanguagePage(store: _localeStore)),
              ),
              _navTile(
                icon: Icons.system_update_alt_rounded,
                title: l10n.settingsUpdateCheckTitle,
                subtitle: _updateSubtitle(l10n),
                onTap: _runUpdateCheck,
              ),
              _navTile(
                icon: Icons.article_outlined,
                title: l10n.settingsDiagnosticsTitle,
                subtitle: l10n.settingsDiagnosticsSub,
                onTap: () => _push(context, const DiagnosticsPage()),
              ),
              _navTile(
                icon: Icons.info_outline_rounded,
                title: l10n.settingsAboutTitle,
                subtitle: l10n.settingsAboutSub,
                onTap: () => _push(context, const AboutPage()),
              ),
            ]),
          ),
          const SizedBox(height: AppTheme.m),
          // 唯一的常驻合规声明。它之前是写死的中文，等于只对中文用户成立。
          Text(
            l10n.settingsFooter,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: AppTheme.inkDim, height: 1.7),
          ),
        ],
      ),
    );
  }

  /// D-114 更新检查的最近一次结果。**只在用户点开设置页时**才查——不后台轮询：
  /// 「零遥测」是这个 App 对外声明的卖点之一（关于页），一个静默的对外请求会
  /// 让那句话变成谎。
  UpdateCheck? _update;
  bool _checking = false;

  /// 三种结果**各自都要有话说**。第一版只有「发现新版」有反馈，其余两条回落成
  /// 默认文案——于是「已经是最新版」看起来就是**点了没反应**，而网络失败被
  /// 显示成「未检查」，比不显示更误导。
  ///
  /// 副标题与 SnackBar 共用这一个函数：同一个 switch 写两遍，迟早漂成「副标题
  /// 说失败、弹窗说成功」，而本轮消灭的正是这类不一致。
  String? _updateOutcome(L10n l10n) {
    final r = _update;
    if (r == null) return null;
    if (r.error != null) {
      final reason = switch (r.error!) {
        final UpdateError e => switch (e) {
            UpdateError.badJson => l10n.updateErrBadJson,
            UpdateError.noTag => l10n.updateErrNoTag,
          },
        final Object e => e.toString(),
      };
      return l10n.updateCheckFailed(reason);
    }
    if (!r.available) return l10n.updateCheckUpToDate(r.current ?? kAppVersion);
    final mb = r.bytes == null ? '' : ' · ${l10n.updateCheckSize(_mb(r.bytes!))}';
    return l10n.updateCheckAvailable(r.latest!) + mb;
  }

  String _updateSubtitle(L10n l10n) => _checking
      ? l10n.updateCheckChecking
      : _updateOutcome(l10n) ?? l10n.settingsUpdateCheckSub;

  static String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);

  Future<void> _runUpdateCheck() async {
    setState(() {
      _checking = true;
      _update = null;
    });
    final result = await UpdateChecker.instance().fetch()
      ..logAudit();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _update = result;
    });
    // l10n 在 await **之后**取——等待期间用户可能刚切了语言。
    final l10n = L10n.of(context);
    final opensDialog = result.available && result.url != null;
    // 三种结果都给一次明确反馈：副标题是小字，用户很容易当成「没反应」。
    // 但「有新版且有下载地址」马上要弹对话框了，那时再弹 SnackBar 是同一条
    // 信息说两遍——对话框本身就是更显眼的那次反馈。
    final banner = _updateOutcome(l10n);
    if (banner != null && !opensDialog) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(banner)));
    }
    if (opensDialog) {
      // 只提示，不自动装：Android 没有签名密钥吊销机制，而自动更新通道一旦被
      // 攻破，等于让攻击者往一台能远程操控你电脑的手机里装任意代码。
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.updateCheckAvailable(result.latest!)),
          content: SingleChildScrollView(
            child: Text(result.notes?.trim().isNotEmpty == true
                ? result.notes!.trim()
                : l10n.settingsUpdateCheckSub),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: Text(l10n.diagnosticsCancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialog).pop();
                _openUrl(result.url!);
              },
              child: Text(l10n.updateCheckOpen),
            ),
          ],
        ),
      );
    }
  }

  void _openUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _switchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      SwitchListTile(
        value: value,
        onChanged: onChanged,
        inactiveThumbColor: AppTheme.inkDim,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppTheme.m + 2),
        secondary: Icon(icon, color: AppTheme.inkDim, size: 20),
        title: Text(title,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
      );

  Widget _navTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppTheme.m + 2),
        leading: Icon(icon, color: AppTheme.inkDim, size: 20),
        title: Text(title,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
        trailing:
            const Icon(Icons.chevron_right_rounded, size: 18, color: AppTheme.inkDim),
        onTap: onTap,
      );

  /// 三个二级页共用同一种推进方式：二级页自带 AppBar，返回键由 Navigator
  /// 处理，屏 G 不重复造一套标题栏。
  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => page,
      ));
}
