import 'package:flutter/material.dart';

import 'console/console_page.dart';
import 'data/machine_entry.dart';
import 'data/machines_repository.dart';
import 'data/settings_store.dart';
import 'l10n/generated/app_localizations.dart';
import 'lock/biometric_gate.dart';
import 'lock/lock_screen.dart';
import 'console/workspaces/last_session_store.dart';
import 'console/workspaces/session_title_cache.dart';
import 'main.dart';
import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'services/session_scheduler.dart';
import 'settings/locale_store.dart';
import 'settings/settings_page.dart';
import 'ui/theme.dart';

/// Three-tab root shell (mockup §7 导航): 机器 / 控制 / 设置; the lock gate
/// (屏 H) wraps everything when enabled.
class AppRoot extends StatefulWidget {
  const AppRoot({
    super.key,
    this.store,
    this.settings,
    this.gatewayFactory,
    this.localeStore,
    this.biometricGate,
    this.titleCache,
    this.lastSession,
  });

  final MachinesStore? store;
  final SettingsStore? settings;

  /// D-052: shared with 屏 G 的语言页 so a pick survives a restart. Null = the
  /// app builds one over secure storage; a test injects an in-memory one.
  final LocaleStore? localeStore;

  /// D-056: 认证能力接缝。null = 真实平台通道；测试注入内存实现。
  final BiometricGate? biometricGate;

  /// D-062: 打开过的会话的标题（持久化）。真 App 构造时传入；
  /// 测试传 inMemory 或 null。
  final SessionTitleCache? titleCache;

  /// D-109：「上次看的会话」记忆。
  final LastSessionStore? lastSession;

  /// Injected console transport; null builds a real client per machine.
  /// Widget tests pass a fake so the console renders without a relay.
  final EngineGateway Function(MachineEntry entry)? gatewayFactory;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late final MachinesStore _store;
  late final SettingsStore _settings;
  late final SessionScheduler _scheduler;

  /// D-052: normalized here rather than forwarded as-is, so 屏 G 的语言页
  /// always writes into the **same** instance `MaterialApp.locale` reads.
  /// Forwarding the nullable field would let `SettingsPage` fall back to its
  /// own `LocaleStore()`: the pick would persist to storage but the live
  /// notifier would never fire, so the language would only change after a
  /// restart — the "saved but nothing happened" failure in its purest form.
  late final LocaleStore _localeStore = widget.localeStore ?? LocaleStore();

  int _tab = 0;
  bool _locked = false;
  bool _consoleMounted = false;
  final _consoleKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? MachinesStore(repo: SecureMachinesRepository());
    _settings = widget.settings ?? SettingsStore();
    _scheduler = SessionScheduler(store: _store)..start();
    _store.hydrate();
    _settings.hydrate().then((_) {
      if (mounted && _settings.notifier.value.lockEnabled) setState(() => _locked = true);
    });
  }

  @override
  void dispose() {
    _scheduler.dispose();
    if (widget.store == null) _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The console is mounted **only once its tab is opened**. An IndexedStack
    // builds every child eagerly, which meant opening the app on the machines
    // tab still dialled the engine and held a WebSocket — battery and mobile
    // data spent on a screen the user never looked at. A placeholder keeps
    // the stack index stable while the real page stays unmounted.
    final consoleMounted = _consoleMounted;
    final pages = [
      MachinesPage(store: _store),
      consoleMounted
          ? ConsolePage(
              key: _consoleKey,
              store: _store,
              gatewayFactory: widget.gatewayFactory,
              titleCache: widget.titleCache,
              lastSession: widget.lastSession,
              // D-110：终态失效时横幅上那个「去重新配对」的落点。
              onShowMachines: () {
                if (mounted) setState(() => _tab = 0);
              },
            )
          : const _ConsoleDeferred(),
      SettingsPage(
        store: _store,
        settings: _settings,
        localeStore: _localeStore,
        biometricGate: widget.biometricGate,
      ),
    ];
    return Scaffold(
      body: _locked
          ? BiometricLockScreen(
              onUnlocked: () => setState(() => _locked = false),
              gate: widget.biometricGate,
            )
          : IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: _locked
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() {
                _tab = i;
                if (i == 1) _consoleMounted = true;
              }),
              backgroundColor: AppTheme.surfaceHigh,
              destinations: [
                NavigationDestination(
                    icon: const Icon(Icons.dns_outlined),
                    label: L10n.of(context).tabMachines),
                NavigationDestination(
                    icon: const Icon(Icons.forum_outlined),
                    label: L10n.of(context).tabConsole),
                NavigationDestination(
                    icon: const Icon(Icons.tune_rounded),
                    label: L10n.of(context).tabSettings),
              ],
            ),
    );
  }
}

/// Stand-in for the console tab before it is opened for the first time.
class _ConsoleDeferred extends StatelessWidget {
  const _ConsoleDeferred();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

