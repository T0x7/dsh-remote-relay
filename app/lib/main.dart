import 'dart:async';
import 'dart:io';

import 'package:dsh_remote_core/api/relay.dart';
import 'package:dsh_remote_core/log_hook.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_remote_core/credentials/session_clock.dart';
import 'package:flutter/material.dart';

import 'app_root.dart';
import 'console/workspaces/session_title_cache.dart';
import 'lock/biometric_gate.dart';
import 'data/settings_store.dart';
import 'l10n/generated/app_localizations.dart';
import 'data/machine_entry.dart';
import 'data/machines_repository.dart';
import 'logging/app_log.dart';
import 'settings/locale_store.dart';
import 'machines/machine_detail_page.dart';
import 'machines/session_expired_page.dart';
import 'pairing/pairing_flow.dart';
import 'services/app_lifecycle_gate.dart';
import 'services/live_machine_scope.dart';
import 'services/machines_session_poller.dart';
import 'services/reminder_router.dart';
import 'ui/theme.dart';

void main() {
  // Logging plan（P1/P3 接线）：sink 先装、**永不 await**——目录解析前的行
  // 进内存缓冲，首帧不等文件系统；core 网络层的事件经 CoreLog 缝汇入同一份
  // 脱敏日志。测试不进 main()，sink 保持 null = 仅 debugPrint，零影响。
  AppLog.init(resolveDir: _resolveLogDir);
  CoreLog.sink = AppLog.raw;
  runApp(DshRemoteApp(
    // D-062: 打开过的会话的标题要跨进程存活——就差这一处接线。
    titleCache: SessionTitleCache(storage: SharedPreferencesAsync()),
  ));
}

/// 隐私表（design §8 后表）对脱敏日志的两条硬要求在这里兑付：
/// 「随卸载」+「不随备份出设备」。cache 目录在 Android 上不属于 Auto Backup
/// 范围、iOS 不进 iCloud——两条零配置满足。代价是系统「清除缓存」会连带清掉
/// 日志：对滚动诊断日志是可接受的折衷，换 logs 专用排除规则的复杂度不值。
Future<Directory> _resolveLogDir() async {
  final tmp = await getTemporaryDirectory();
  return Directory('${tmp.path}/logs');
}

class DshRemoteApp extends StatefulWidget {
  const DshRemoteApp({
    super.key,
    this.store,
    this.settings,
    this.lifecycle,
    this.localeStore,
    this.biometricGate,
    this.titleCache,
  });

  /// Test seam: injected stores ride AppRoot; null = secure storage.
  final MachinesStore? store;
  final SettingsStore? settings;

  /// Test seam: the foreground gate this app drives. Null = the process-wide
  /// one, which the console's controller also reads.
  final AppLifecycleGate? lifecycle;

  /// D-052: the language preference. Null = secure storage.
  final LocaleStore? localeStore;

  /// D-056: 认证能力接缝。null = 真实平台通道；测试注入内存实现。
  final BiometricGate? biometricGate;

  /// D-062: 打开过的会话的标题（持久化）。真 App 构造处建一个；
  /// 测试传 inMemory 或 null。
  final SessionTitleCache? titleCache;

  @override
  State<DshRemoteApp> createState() => _DshRemoteAppState();
}

/// Owns the one app-wide [WidgetsBindingObserver].
///
/// design §5「切后台即断 WS」needs a lifecycle answer that every surface can
/// read, so the observer is registered once at the root and folded into the
/// gate rather than sprinkled over the pages.
class _DshRemoteAppState extends State<DshRemoteApp> with WidgetsBindingObserver {
  late final AppLifecycleGate _lifecycle;

  /// D-052: one instance shared by [MaterialApp.locale] and 屏 G 的语言页.
  /// Two instances over one storage key is exactly how a picker ends up
  /// looking like it saved nothing.
  late final LocaleStore _localeStore;

  @override
  void initState() {
    super.initState();
    _lifecycle = widget.lifecycle ?? AppLifecycleGate.instance;
    _localeStore = widget.localeStore ?? LocaleStore();
    // Hydrate before the first frame: rendering Chinese and then swapping to
    // English under the user is worse than a frame of nothing.
    _localeStore.hydrate();
    _localeStore.notifier.addListener(_onLocaleChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _onLocaleChanged() => setState(() {});

  /// The `MaterialApp.locale` the pick maps to, or null = 跟随系统.
  ///
  /// Reads [_localeStore]（含自己兜底建的那个），**不能**读
  /// `widget.localeStore`：真机跑的是 `const DshRemoteApp()`，那个字段是
  /// null，只看它等于「永远跟随系统」——语言页写进存储的选择永远不生效。
  /// null = 没选过；选了未知语言（如系统 fr）时也回 null，交给 Material 兜底。
  Locale? get _locale {
    final code = _localeStore.notifier.value;
    return code == null ? null : Locale(code.languageCode);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _lifecycle.handle(state);

  @override
  void dispose() {
    _localeStore.notifier.removeListener(_onLocaleChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'dsh remote',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.dark, // dark-first (design §7.1)
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        // D-052: this was `const Locale('zh')`, so 屏 G 的语言页写什么都不影响
        // 界面 —— 一个「零消费者」的开关，和提醒开关当初一模一样。null =
        // 跟随系统（`LocaleStore.of` 认不出的系统语言，如 fr，交给
        // Material 兜底而不是假装支持）；用户选过之后由 LocaleStore 覆盖。
        locale: _locale,
        home: AppRoot(
          store: widget.store,
          settings: widget.settings,
          localeStore: _localeStore,
          biometricGate: widget.biometricGate,
          titleCache: widget.titleCache,
        ),
      );
}

/// Machines tab (mockup 屏 A): three-state cards + empty state + pairing flow.
/// Card tap → detail (屏 D) or the expired page (屏 I) by clock verdict.
///
/// The list is also the app's **reminder presenter** (T1.12) and its low-
/// frequency status source (design §5): it holds the tunnel snapshot poller and
/// draws the 60 s warnings as SnackBars, which is why it is the one page that
/// is always mounted.
class MachinesPage extends StatefulWidget {
  const MachinesPage({
    super.key,
    this.store,
    this.reminders,
    this.live,
    this.snapshotFetch,
    this.pollInterval = const Duration(seconds: 60),
    this.timerFactory,
  });

  final MachinesStore? store;

  /// Test seam: the shared router. Null = the process-wide one.
  final ReminderRouter? reminders;

  /// Test seam: who is live. Null = the process-wide scope.
  final LiveMachineScope? live;

  /// Test seam: the `/dsh-remote/session` read. Null = the real relay client.
  final SessionSnapshotFetcher? snapshotFetch;

  /// Test seam: the sweep cadence. `Duration.zero` disables the timer.
  final Duration pollInterval;

  /// Test seam: the periodic timer itself.
  final PeriodicTimerFactory? timerFactory;

  @override
  State<MachinesPage> createState() => _MachinesPageState();
}

class _MachinesPageState extends State<MachinesPage> {
  late final MachinesStore _store;
  late final ReminderRouter _reminders;
  late final LiveMachineScope _live;
  late final MachinesSessionPoller _poller;
  StreamSubscription<Reminder>? _reminderSub;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? MachinesStore(repo: SecureMachinesRepository());
    _reminders = widget.reminders ?? ReminderRouter.instance;
    _live = widget.live ?? LiveMachineScope.instance;
    _poller = MachinesSessionPoller(
      store: _store,
      live: _live,
      fetch: widget.snapshotFetch,
      interval: widget.pollInterval,
      timerFactory: widget.timerFactory,
    );
    // A polled tunnel state is the same fact the console's carrier reports, so
    // both go through the one router and share its dedup.
    _poller.onSnapshot = (entry, snapshot) => _reminders.reportTunnel(
          machineId: entry.id,
          machineName: entry.name,
          connected: snapshot.tunnel.state == TunnelState.connected,
        );
    _store.machines.addListener(_onChanged);
    _poller.tunnelStates.addListener(_onChanged);
    _reminderSub = _reminders.reminders.listen(_present);
    _poller.start();
    _store.hydrate();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _reminderSub?.cancel();
    _store.machines.removeListener(_onChanged);
    _poller.tunnelStates.removeListener(_onChanged);
    _poller.dispose();
    if (widget.store == null) _store.dispose();
    super.dispose();
  }

  /// The single L4 surface for every reminder source (design §7.2). The
  /// messenger is the app-wide one, so a task that finishes while the user is
  /// in the console still says so.
  void _present(Reminder reminder) {
    if (!mounted) return;
    final l10n = L10n.of(context);
    final text = switch (reminder.kind) {
      ReminderKind.tunnelDown => reminder.machineName == null
          ? l10n.consoleReconnecting
          : '${l10n.consoleReconnecting} · ${reminder.machineName}',
      ReminderKind.jobFinished => reminder.detail == null
          ? (reminder.failed ? l10n.jobsStateFailed : l10n.jobsStateDone)
          : '${reminder.detail} · '
              '${reminder.failed ? l10n.jobsStateFailed : l10n.jobsStateDone}',
      ReminderKind.approvalRequested =>
        reminder.detail == null || reminder.detail == reminder.machineName
            ? l10n.chatApprovalTitle
            : '${l10n.chatApprovalTitle} · ${reminder.detail}',
    };
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  void _openPairing() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppTheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        // D-029: the inset padding MUST read the **sheet's own** context.
        // `MediaQuery.of(context)` on the page behind the modal registers the
        // dependency on that page's element, but the sheet is a separate route
        // with its own subtree — so the padding froze at whatever the keyboard
        // height was when the sheet first built. With `autofocus: true` on the
        // URL field the keyboard is already up at that moment on some devices
        // and not yet up on others; either way the sheet never tracked it, and
        // on a tall IME (MIUI Sogou ≈ 960 px) the primary button was pushed
        // clean off the bottom of the screen. Verified on-device: with the
        // keyboard open, no mint-coloured pixel existed anywhere on screen.
        builder: (sheetContext) => AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          // A tall IME can still exceed the remaining height on a short
          // screen; scrolling is cheaper than the button becoming unreachable.
          child: SingleChildScrollView(
            child: PairingFlowSheet(onPaired: _store.add),
          ),
        ),
      );

  void _openMachine(MachineEntry entry) {
    // While 屏 D is up, this machine is being read from — not polled. A claim
    // rather than a flag, so the console binding its own machine composes with
    // this one instead of overwriting it.
    _live.claim(entry.id);
    final expired = SessionClock(
      expMs: entry.params.expMs,
      firstPairedMs: entry.firstPairedMs,
    ).isExpired(MachineCard._now());
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => expired
          ? SessionExpiredPage(
              entry: entry,
              onRepair: () {
                Navigator.of(context).pop();
                _openPairing();
              },
              onDelete: () {
                _store.remove(entry.id);
                Navigator.of(context).pop();
              },
            )
          : MachineDetailPage(entry: entry),
    )).whenComplete(() => _live.release(entry.id));
  }

  @override
  Widget build(BuildContext context) {
    final machines = _store.machines.value;
    return Scaffold(
      appBar: AppBar(title: Text(L10n.of(context).tabMachines)),
      body: machines.isEmpty
          ? _EmptyState(onAdd: _openPairing)
          : RefreshIndicator(
              // design §5: 下拉手动 — the same pass the 60 s timer runs.
              onRefresh: _poller.sweep,
              child: ListView.separated(
                // A one- or two-machine list is not scrollable, and
                // `onEdge` pull-to-refresh only arms on an overscroll at the top
                // — so without this the 下拉手动 affordance would be dead on
                // exactly the installs that have not paired a second machine.
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                    AppTheme.l, AppTheme.s, AppTheme.l, AppTheme.xxl),
                itemCount: machines.length,
                separatorBuilder: (_, _) => const SizedBox(height: AppTheme.m),
                itemBuilder: (_, i) => MachineCard(
                  entry: machines[i],
                  tunnel: _poller.stateOf(machines[i].id),
                  engineHealth: _poller.engineHealthOf(machines[i].id),
                  onTap: () => _openMachine(machines[i]),
                  onRemove: () => _store.remove(machines[i].id),
                ),
              ),
            ),
      floatingActionButton: machines.isEmpty
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppTheme.accent,
              foregroundColor: const Color(0xFF052E1F),
              onPressed: _openPairing,
              icon: const Icon(Icons.add),
              label: Text(L10n.of(context).machinesAddFab),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_scanner_rounded,
                  size: 64, color: AppTheme.inkDim),
              const SizedBox(height: AppTheme.l),
              Text(L10n.of(context).machinesEmptyTitle,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: AppTheme.s),
              // D-053: 这句曾是 `const Text('在电脑上运行…')`，于是在英文界面
              // 下屏 A 的空状态一半英文一半中文——翻译早就在 arb 里躺着
              // （machinesEmptyBody），只是没人取。
              Text(
                L10n.of(context).machinesEmptyBody,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim),
              ),
              const SizedBox(height: AppTheme.xl),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                label: Text(L10n.of(context).machinesScanOrPaste),
              ),
            ],
          ),
        ),
      );
}

/// One machine card — the live tunnel state for the dot (mockup 屏 A 三态) and
/// the credential clock for the countdown chip.
class MachineCard extends StatelessWidget {
  const MachineCard({
    super.key,
    required this.entry,
    this.tunnel,
    this.engineHealth,
    this.onTap,
    this.onRemove,
  });

  /// Clock seam for tests, matching the `fetchOverride` / `verifierOverride`
  /// pattern already used across the app.
  ///
  /// The card renders a live countdown ("23h 4m") and a 30-day day counter, so
  /// without this every Golden baseline went red the moment the wall clock
  /// moved past the instant it was captured — a test that can only be green
  /// for the minute it was written. Freezing the clock makes the baseline a
  /// design artifact again.
  static DateTime Function() nowOverride = DateTime.now;

  static DateTime _now() => nowOverride();

  /// What the status dot paints, as a pure function of the two inputs.
  ///
  /// The dot used to be the credential clock alone, which is why a machine
  /// whose tunnel had dropped still showed a green light on 屏 A: a 24 h
  /// credential says nothing about whether the machine is reachable **now**.
  /// A polled tunnel state outranks the clock, and the clock is what remains
  /// when no snapshot has landed yet (offline, first paint, 401) — an unknown
  /// state is not a fault and must not be painted as one.
  ///
  /// v3.177: tunnel `connected` no longer paints green unconditionally. The
  /// machine-side client's engine verdict outranks it: a tunnel can be up
  /// while the engine behind it refuses every request (2026-10-10: engine
  /// restart rotated its token, stale cookies 401'd every /api call, the card
  /// stayed green the whole time). No verdict yet (unknown / old client) keeps
  /// the old green — absence of evidence is not a fault.
  static ChipStage dotStageOf({
    TunnelState? tunnel,
    EngineHealth? engine,
    required ChipStage clock,
  }) =>
      switch (tunnel) {
        null => clock,
        TunnelState.connected when engine == EngineHealth.unreachable => ChipStage.warn,
        TunnelState.connected => ChipStage.neutral,
        TunnelState.connecting ||
        TunnelState.reconnecting ||
        TunnelState.unknown =>
          ChipStage.warn,
        TunnelState.disabled || TunnelState.manualOff => ChipStage.danger,
      };

  final MachineEntry entry;

  /// The relay's last reported tunnel state, or null when unknown.
  final TunnelState? tunnel;

  /// The client's engine verdict from the same snapshot, or null when unknown.
  final EngineHealth? engineHealth;

  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  /// The credential clock's verdict — still what the countdown chip shows.
  @visibleForTesting
  ChipStage get clockStage {
    final now = _now();
    return SessionClock(
      expMs: entry.params.expMs,
      firstPairedMs: entry.firstPairedMs,
    ).chipStage(now);
  }

  /// The stage the dot actually paints. Read by the list test instead of
  /// pixel-diffing a circle.
  @visibleForTesting
  ChipStage get dotStage =>
      dotStageOf(tunnel: tunnel, engine: engineHealth, clock: clockStage);

  @override
  Widget build(BuildContext context) {
    final now = _now();
    final clock = SessionClock(
      expMs: entry.params.expMs,
      firstPairedMs: entry.firstPairedMs,
    );
    final expired = clock.isExpired(now);
    final left = clock.remaining(now);
    final l10n = L10n.of(context);
    final label = expired
        ? l10n.chipExpired
        : left.inHours >= 1
            ? '${left.inHours}h ${left.inMinutes % 60}m'
            : '${left.inMinutes}m';
    final stage = expired ? ChipStage.danger : clock.chipStage(now);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.m + 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StatusDot(dotStage),
                  const SizedBox(width: AppTheme.s + 2),
                  Expanded(
                    child: Text(entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                  ),
                  CountdownChip(label, stage),
                  if (onRemove != null) ...[
                    const SizedBox(width: AppTheme.xs),
                    SizedBox(
                      width: AppTheme.minTouch,
                      height: AppTheme.minTouch,
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: onRemove,
                        icon: const Icon(Icons.delete_outline_rounded,
                            size: 18, color: AppTheme.inkDim),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppTheme.xs + 2),
              Padding(
                padding: const EdgeInsets.only(left: AppTheme.minTouch - 26),
                child: Text(entry.params.relayOrigin.toString(),
                    style: const TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        color: AppTheme.inkDim)),
              ),
              const SizedBox(height: AppTheme.xs),
              Padding(
                padding: const EdgeInsets.only(left: AppTheme.minTouch - 26),
                child: Text(
                  expired
                      ? l10n.cardExpiredHint
                      : l10n.cardSessionLine(
                          label, clock.maxAgeDay(now) ?? '–'),
                  style:
                      const TextStyle(fontSize: 11.5, color: AppTheme.inkDim),
                ),
              ),
              // v3.177 黄态提示：隧道在线但引擎不应答。只在有证据时出现
              // （unreachable），unknown/旧客户端快照不渲染任何新东西——
              // 健康态的卡片布局保持逐像素不变。
              if (!expired &&
                  tunnel == TunnelState.connected &&
                  engineHealth == EngineHealth.unreachable) ...[
                const SizedBox(height: AppTheme.xs),
                Padding(
                  padding: const EdgeInsets.only(left: AppTheme.minTouch - 26),
                  child: Text(l10n.machinesEngineUnreachable,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppTheme.warn)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
