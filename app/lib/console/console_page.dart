import 'dart:async';

import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/credentials/session_clock.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/net/pinned_http.dart';
import 'package:dsh_remote_core/net/relay_client.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/pin_store.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/console/workspaces/last_session_store.dart';
import 'package:dsh_remote_app/console/workspaces/session_title_cache.dart';
import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:dsh_remote_app/console/agent_preset_sheet.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

import 'chat/chat_controller.dart';
import 'host/host_pane.dart';
import 'jobs/jobs_pane.dart';
import 'models/model_picker.dart';
import '../services/live_machine_scope.dart';import 'trajectory/trajectory_pane.dart';
import 'workspace/workspace_pane.dart';
import 'chat/chat_pane.dart';
import 'workspaces/workspace_picker_page.dart';
import 'workspaces/workspace_registry_controller.dart';
import 'package:dsh_remote_core/api/workspace_registry.dart';
import 'team/team_page.dart';

/// The console tab (mockup 屏 E): machine context, the chat / tasks / host
/// segments, and the entry into the session list (屏 M).
///
/// The engine gateway is injected ([gatewayFactory]) so widget tests drive the
/// screen with a fake; production builds a real [EngineClient] per machine and
/// disposes it when the machine changes, so a switch never leaves an orphan
/// mux socket behind.
class ConsolePage extends StatefulWidget {
  const ConsolePage({
    super.key,
    required this.store,
    this.gatewayFactory,
    this.titleCache,
    this.lastSession,
    this.onShowMachines,
    this.liveScope,
  });

  final MachinesStore store;

  /// Machine → gateway. Null builds a real client over the pinned stack.
  final EngineGateway Function(MachineEntry entry)? gatewayFactory;

  /// D-062: 标题缓存。null = inMemory（测试与不需要持久化的调用方）；
  /// 真 App 在 app_root.dart 接线处传持久化版本。
  final SessionTitleCache? titleCache;

  /// D-109：「上次看的会话」记忆。null = inMemory（测试与不需要持久化的调用方）。
  final LastSessionStore? lastSession;

  /// D-110：凭证终态失效时横幅上那个**唯一主行动**的落点——跳回机器页，
  /// 那里才有重新配对的流程（design §7.2：会话失效属 L1，唯一主行动）。
  /// null = 没有出路（测试与没接 AppRoot 的调用方），此时横幅仍然不谎称重连。
  final VoidCallback? onShowMachines;

  /// D-112: claim/release 用的 scope。null = 进程级的 [LiveMachineScope.instance]
  /// （生产）。测试可以传一个私有 scope，这样「切机器后旧机器重新被轮询器看到」
  /// 能被断言，而不会去动那个进程级单例——同 [gatewayFactory] 的理由。
  final LiveMachineScope? liveScope;

  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  ChatController? _chat;
  /// D-046: this machine's workspace registry. Null until a machine binds.
  WorkspaceRegistryController? _registry;

  /// D-062: 兜底的标题缓存。App 真身从 app_root.dart 传持久化版本进来；
  /// 这里只服务「没传 titleCache 又真的跑在真机上」的路径。
  late final SessionTitleCache _titleCache = SessionTitleCache.inMemory();

  /// D-109：同上，兜底的会话记忆。
  late final LastSessionStore _lastSession = LastSessionStore.inMemory();
  MachineEntry? _machine;
  Object? _ownedResources;
  int _segment = 0;

  /// D-027: live carrier state, so the console can say "reconnecting" instead
  /// of leaving a conversation that has silently stopped updating.
  MuxState _muxState = MuxState.idle;
  StreamSubscription<MuxState>? _muxStateSub;

  /// The open session's pinned model selection. **Null means it follows the
  /// deployment default** — the projection's `next` is null and the effective
  /// selection is `ModelCatalog.default` (§6.3).
  ModelSelection? _selection;

  /// Session rows, read once per machine for the host pane's count. Kept
  /// deliberately cold: `session/list` is a cold read and the console has no
  /// reason to re-poll it behind the user's back.
  /// D-046: a [ValueNotifier] rather than a plain field because the workspace
  /// picker lives on its own route. A route does not rebuild when the console
  /// does, so a list handed over by value would stay frozen at whatever the
  /// console happened to hold — and on a real host `session/list` lands long
  /// after the picker is pushed, so the picker would open onto an empty world.
  final ValueNotifier<List<SessionSummary>> _sessions =
      ValueNotifier(const []);

  @override
  void initState() {
    super.initState();
    widget.store.hydrate();
    widget.store.machines.addListener(_onMachines);
    final first = _defaultMachine();
    if (first != null) _bindMachine(first);
  }

  @override
  void dispose() {
    widget.store.machines.removeListener(_onMachines);
    _muxStateSub?.cancel();
    // D-112: 页面走了，它驾驶的那台机器就该回到轮询器的视野里。
    _releaseClaim();
    _chat?.dispose();
    _disposeOwned();
    super.dispose();
  }

  /// D-112: 本页当前持有的 claim（机器 id）。只有一个 claim 在飞，于是
  /// 「切机器先放旧的、再认新的」和「卸载时放掉当前的」都只能是这一份。
  String? _claimedMachineId;

  /// D-112: 认领一台机器。先放掉上一台——`LiveMachineScope` 的 claim 是**计数**
  /// 而非布尔，所以「先 claim 新的再 release 旧的」会让旧机器永远差一次释放。
  ///
  /// 同一个 id 重复绑定是空操作（不重复计数）：调用点不必自己判断，规则留在这里。
  void _claimMachine(String machineId) {
    if (_claimedMachineId == machineId) return;
    _releaseClaim();
    _claimedMachineId = machineId;
    (widget.liveScope ?? LiveMachineScope.instance).claim(machineId);
  }

  /// D-112: 放掉当前 claim。没认领过就是空操作。
  void _releaseClaim() {
    final claimed = _claimedMachineId;
    if (claimed == null) return;
    _claimedMachineId = null;
    (widget.liveScope ?? LiveMachineScope.instance).release(claimed);
  }

  void _onMachines() {
    final current = _machine;
    if (current != null && widget.store.machines.value.any((e) => e.id == current.id)) {
      return;
    }
    final next = _defaultMachine();
    setState(() {
      if (next == null) {
        _machine = null;
        // D-112: 没有下一台可驾驶 = 本页不再持有任何 claim。
        _releaseClaim();
        _chat?.dispose();
        _chat = null;
        _disposeOwned();
      } else {
        _bindMachine(next);
      }
    });
  }

  /// The first machine that still has a live credential, else the first row.
  MachineEntry? _defaultMachine() {
    final entries = widget.store.machines.value;
    if (entries.isEmpty) return null;
    final now = DateTime.now();
    for (final entry in entries) {
      final clock = SessionClock(
        expMs: entry.params.expMs,
        firstPairedMs: entry.firstPairedMs,
      );
      if (!clock.isExpired(now)) return entry;
    }
    return entries.first;
  }

  void _bindMachine(MachineEntry entry) {
    // D-051: tell the scope which machine the console is driving, so the
    // 60s poller leaves it alone (its carrier is the live source) instead of
    // asking the relay about a machine it already knows.
    //
    // D-112: claim/release 严格成对，经 [_claimMachine] / [_releaseClaim] 这一个
    // 漏斗。过去的版本只有 claim 没有 release，于是计数单调增长——切走的机器
    // 被轮询器**永久**跳过，卡片一直停在上一次读到的「在线」，而一个已经没人
    // 驾驶的机器本该回到 60 秒低频刷新里。
    _claimMachine(entry.id);
    _machine = entry;
    _disposeOwned();
    final factory = widget.gatewayFactory;
    if (factory != null) {
      // An injected gateway belongs to the caller (a test disposes its fake).
      _ownedResources = null;
      _replaceChat(factory(entry));
      return;
    }
    final params = entry.params;
    // D-025: seed the TOFU table from the machine's pairing-time pin. Empty
    // table + fail-closed steady state rejected EVERY console connection at
    // the TLS layer (yellow banner, no data). The pin learned during pairing
    // makes the verdict `ok`; a rotated cert still fails closed.
    final pinned = PinnedHttpClient.fromStore(pinStoreFor(entry));
    final mux = EngineMux(
      origin: params.relayOrigin,
      pinned: pinned,
      bearerProvider: () async => params.bearer,
    )..start();
    _muxStateSub?.cancel();
    _muxStateSub = mux.states.listen((state) {
      if (!mounted) return;
      setState(() => _muxState = state);
    });
    _ownedResources = _OwnedResources(mux: mux, pinned: pinned);
    _replaceChat(EngineClient(
      rpc: EngineRpc(
        relay: RelayClient(
          origin: params.relayOrigin,
          pinned: pinned,
          bearerProvider: () async => params.bearer,
        ),
      ),
      mux: mux,
    ));
  }

  void _replaceChat(EngineGateway gateway) {
    // D-051: the machine id lets the reminder router name the machine that
    // lost its tunnel, and — more importantly — lets the console's carrier
    // share the poller's dedup key instead of carrying a `tunnel:console`
    // key of its own, which would have reported the same outage twice.
    final chat = ChatController(
      gateway: gateway,
      machineId: _machine?.id,
      lastSession: widget.lastSession ?? _lastSession,
    )..startEvents();
    _chat?.dispose();
    _chat = chat;
    // D-046: the registry is machine-scoped, exactly like the chat: it dies
    // with the machine binding and is rebuilt for the next one, but switching
    // *sessions* must not disturb it.
    _registry?.dispose();
    // D-062: 这里是唯一用持久化标题缓存的地方——App 真身。其他调用方
    // （测试、不知道该特性的）拿到 inMemory 默认，不会在缺平台通道的环境里炸。
    _registry = WorkspaceRegistryController(
      gateway,
      titles: widget.titleCache ?? _titleCache,
    );
    _loadSessions(gateway);
    setState(() {});
  }

  /// One cold read per machine, feeding the host pane's session count — and,
  /// on first load, auto-opening the most recently updated session (D-031).
  ///
  /// E2E feedback: the console used to land on an empty conversation
  /// with only a "new session" FAB, so opening the app read as "the phone
  /// never sees the machine's sessions — everything becomes a new one". The
  /// machine's sessions were always there (the list view reads them); what was
  /// missing was *continuing* the latest one without a manual detour.
  ///
  /// D-067: `[autoOpen]` 为 false 的调用来自工作区页的后台刷新——只更新
  /// `_sessions`，绝不顺带打开最新会话：用户此刻正在挑会话，替他做决定
  /// 等于把他正在看的页面抽走。
  Future<void> _loadSessions(EngineGateway gateway, {bool autoOpen = true}) async {
    final result = await gateway.listSessions();
    AppLog.d(
        'e2e', '[e2e] console session/list ok=${result.isOk} err=${result.error}');
    if (!mounted) return;
    final rows = result.isOk
        ? (result.value! as Map<String, dynamic>)['items']! as List<SessionSummary>
        : const <SessionSummary>[];
    setState(() => _sessions.value = rows);

    final chat = _chat;
    if (!autoOpen || chat == null || chat.sessionId != null) return;
    // D-109：**必须先 await 读盘**，否则拿到空内存态、静默回落到 latest——
    // 那正是这个特性要修的行为，而且一声不吭。
    await (widget.lastSession ?? _lastSession).ready;
    final target = _resumeTarget(rows);
    if (target != null) {
      await chat.open(target.sessionId);
      await chat.refreshProjections();
      if (mounted) setState(() {});
    }
  }

  /// D-110：这台机器的凭证是不是**终态**失效（重连无望）。
  ///
  /// 判据是本地的时钟，不是等一次失败往返：`_realMint` 用**旧 bearer** 调
  /// `GET /dsh-remote/url-session` 铸新链接（`session_scheduler.dart:81`），
  /// 所以过期之后连「换一把钥匙」的门都锁着——等下去不会好，只会一直挂着
  /// 「正在重连…」。
  ///
  /// 只在绑定机器之后才判；`null` = 凭证还活着（或者压根没绑定），横幅照旧按
  /// carrier 状态显示「自愈中」。
  AuthCause? _terminalAuthCause() {
    final machine = _machine;
    if (machine == null) return null;
    final clock = SessionClock(
      expMs: machine.params.expMs,
      firstPairedMs: machine.firstPairedMs,
    );
    final now = DateTime.now();
    if (!clock.isExpired(now)) return null;
    final cause = clock.diagnose401(now);
    if (cause == AuthCause.unknown) return null;
    // 只在**首次**判定时记一行：每次 build 都记会把 audit 通道刷爆，而
    // 「为什么一直连不上」恰恰需要这行。
    if (cause != _loggedTerminalCause) {
      _loggedTerminalCause = cause;
      AppLog.audit('machine.credential.dead', attrs: {
        'machine': machine.id,
        'cause': cause.name,
      });
    }
    return cause;
  }

  AuthCause? _loggedTerminalCause;

  /// D-109：冷启动该开哪个。
  ///
  /// 优先「上次看的那个」——但**必须验活**：它可能已经被引擎删了，拿一个不存在的
  /// id 去 `session/follow`，用户看到的是一个永远转圈的空白页（正是 D-100 修过的
  /// 那类症状），而且不会有任何报错。列表里没有就回落到最近更新的那个。
  SessionSummary? _resumeTarget(List<SessionSummary> rows) {
    if (rows.isEmpty) return null;
    final remembered = (widget.lastSession ?? _lastSession).lastFor(_machine?.id);
    if (remembered != null) {
      for (final row in rows) {
        if (row.sessionId == remembered) return row;
      }
    }
    return _latestResumable(rows);
  }

  /// The most recently updated session row (the list arrives sorted that way),
  /// or null when there is nothing to continue.
  SessionSummary? _latestResumable(List<SessionSummary> rows) =>
      rows.isEmpty ? null : rows.first;

  void _disposeOwned() {
    final resources = _ownedResources;
    if (resources is _OwnedResources) {
      resources.dispose();
      _ownedResources = null;
    }
  }

  Future<void> _openSessions() async {
    final machine = _machine;
    final chat = _chat;
    final registry = _registry;
    if (machine == null || chat == null || registry == null) return;
    // D-047: the picker needs nothing from `session/list`. The registry
    // carries each workspace's own `sessionIds`, so the entry point is now
    // milliseconds instead of whatever that call costs (130s+ today and
    // rising). `_sessions` is passed only so the **ungrouped** row can be
    // counted — the baseline has no total, and saying "—" beats saying "0".
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WorkspacePickerPage(
        registry: registry,
        gateway: chat.gateway,
        sessions: _sessions,
        machineName: machine.name,
        onOpenSession: (sessionId) => openSessionById(sessionId),
        // D-067: 每次进工作区页后台刷一次 session/list，给「已失效」判定
        // 提供正据。只读不打开——这里绝不能有自动打开最新会话的副作用。
        refreshSessions: () => _loadSessions(chat.gateway, autoOpen: false),
      ),
    ));
  }

  Future<void> openSessionById(String sessionId) async {
    final chat = _chat;
    if (chat == null) return;
    // D-041: two things sat between the tap and the conversation, and both
    // read to the user as "nothing happened".
    //
    // 1. The segment selection outlives the push/pop of these pages, so a
    //    user reading the workspace was dropped straight back into it.
    // 2. `open()` tears the old journal down before it follows the new
    //    session, and the pop was sequenced behind that await. A tap that
    //    waits on stream teardown is a tap that looks broken, so the routes
    //    close first and the conversation swaps underneath.
    if (mounted) {
      setState(() {
        // A session that never chose a model follows the default: reset the
        // chip so it does not carry the previous session's pin.
        _selection = null;
        _segment = 0;
      });
      final navigator = Navigator.of(context);
      // Two routes can be open: the workspace's session list and the picker.
      // Popping exactly twice lands on the conversation instead of stranding
      // the user on the list they just came from.
      if (navigator.canPop()) navigator.pop();
      if (navigator.canPop()) navigator.pop();
    }
    // Re-read the controller: closing the route can hand the console to a
    // different machine, and `chat` was captured when the picker was built.
    await _chat?.open(sessionId);
  }

  Future<void> _newSession() async {
    final chat = _chat;
    if (chat == null) return;
    // D-073: 第一跳选 agent 预设（null = 关闭面板放弃；'' = 直接新建走
    // 引擎默认）。快路径「直接新建」保持在面板第一颗，默认建会话只多一击。
    //
    // 工作区选择（combined 方案）：registry 当前快照一并交给面板；选择
    // 「引擎默认」时 workspaceId 为 null，wire 上与功能上线前完全一致。
    // registry 尚未就绪（error/未 loaded）时传空列表，面板退化为纯预设
    // 选择——新建会话永远可用，不因分组数据缺席而不可用。
    final registry = _registry;
    final workspaces =
        (registry != null && registry.loaded && registry.error == null)
            ? registry.workspaces
            : const <WorkspaceView>[];
    final choice = await showAgentPresetSheet(
      context,
      chat.gateway,
      workspaces: workspaces,
    );
    if (choice == null || !mounted) return;
    final result = await chat.gateway.createSession(
      agentPreset: choice.preset.isEmpty ? null : choice.preset,
      workspaceId: choice.workspaceId,
    );
    if (!result.isOk || !mounted) return;
    final sessionId = (result.value! as Map<String, dynamic>)['sessionId'] as String?;
    if (sessionId != null) {
      await chat.open(sessionId);
      if (mounted) setState(() => _selection = null);
    }
  }

  /// Open the engine's model catalog and apply the user's pick (屏 K).
  ///
  /// The chip reflects the session's own `modelSelection.next`, and **null
  /// means "follows the deployment default"** — there is no flag on the wire
  /// (§6.3). Choosing posts the triple; `reasoningEffort` is omitted when the
  /// user left the effort chips alone, which is how "use this model's own
  /// default" is expressed.
  Future<void> _pickModel() async {
    final chat = _chat;
    final sessionId = chat?.sessionId;
    final l10n = L10n.of(context);
    if (chat == null || sessionId == null) return;

    final result = await chat.gateway.modelCatalog();
    if (!mounted) return;
    if (!result.isOk) {
      AppLog.w('console',
          'model catalog failed: code=${result.error!.code} ${result.error!.message}');
      _showInline(l10n.modelSheetFailed, result.error!.toAppError());
      return;
    }
    final catalog = result.value! as ModelCatalog;
    final choice = await ModelPickerSheet.show(
      context,
      catalog: catalog,
      current: _selection ?? catalog.defaultSelection,
      l10n: l10n,
      onSelect: (_, _, _) {},
    );
    if (choice == null || !mounted) return;

    final applied = await chat.gateway.selectModel(
      sessionId: sessionId,
      provider: choice.provider,
      model: choice.model,
      reasoningEffort: choice.effort,
    );
    if (!mounted) return;
    if (!applied.isOk) {
      AppLog.w('console',
          'model apply failed: code=${applied.error!.code} ${applied.error!.message}');
      _showInline(l10n.modelSheetFailed, applied.error!.toAppError());
      return;
    }
    // The engine normalizes the selection; the chip shows what it returned,
    // not what we asked for.
    setState(() => _selection = applied.value! as ModelSelection);
    // 模型选择进操作日志：「换了模型就不对了」这类回溯里，选了什么、选成功没，
    // 是最先要确认的两件事。
    AppLog.audit('console.model.apply', attrs: {
      'session': sessionId,
      'provider': choice.provider,
      'model': choice.model,
    });
    await chat.refreshProjections();
  }

  /// Open the subagent team for the current session (屏 N).
  ///
  /// Tapping a child opens it as a **read-only** conversation: a one-shot
  /// child is terminal, and the protocol has no `readOnly` flag — the mode
  /// is the rule (§9.2), so the composer simply never appears.
  Future<void> _openTeam() async {
    final chat = _chat;
    final sessionId = chat?.sessionId;
    final l10n = L10n.of(context);
    if (chat == null || sessionId == null) return;

    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TeamPage(
        parentSessionId: sessionId,
        projections: chat.projections,
        l10n: l10n,
        onOpenChild: (child) {
          Navigator.of(context).pop();
          chat.open(
            child.id,
            parentSessionId: sessionId,
            subagentLabel: child.label ?? child.id,
            mode: child.mode,
          );
        },
      ),
    ));
    // The team page reads the baseline it was handed; refresh so a newly
    // opened conversation's snapshot can change it.
    await chat.refreshProjections();
  }

  void _showInline(String fallback, AppError error) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(fallback)));
    if (error.code == ErrorCode.engineCancelled) return;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final chat = _chat;
    if (chat == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.tabConsole), backgroundColor: AppTheme.bg),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.dns_outlined, size: 44, color: AppTheme.inkDim),
                const SizedBox(height: AppTheme.m),
                Text(l10n.consoleNoMachine,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: AppTheme.xs),
                Text(l10n.consoleNoMachineBody,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        titleSpacing: AppTheme.m,
        title: Row(
          children: [
            // D-038: both chips are shrinkable, and both are wrapped so the
            // bar's own row can hand out width instead of overflowing when
            // the two labels are long at once.
            Flexible(
              child: _MachineChip(
                  name: _machine?.name ?? '', onTap: _openSessions),
            ),
            const SizedBox(width: AppTheme.s),
            Flexible(
              // Model · effort chip (屏 K). Tapping it opens the engine's own
              // catalog — the App ships no model list.
              child: ModelChip(
                selection: _selection,
                followsDefault: _selection == null,
                l10n: l10n,
                onTap: _pickModel,
              ),
            ),
          ],
        ),
        actions: [
          // Team badge: the count is the number of children in the parent
          // session's catalog, which is a real projection value — not a
          // running tally, because the wire carries no per-child activity.
          //
          // D-096: this used to be a bare `Builder`, so the badge was computed
          // once per `ConsolePage.setState` — and the page does not listen to
          // the chat controller (only `ChatPane` does, for the bubble list).
          // The catalog arrives with the follow snapshot, long after the AppBar
          // built, so `count` was stuck at the pre-snapshot 0 and the one
          // affordance that says "this session has subagents" never lit up
          // (真机 2026-10-11: 徽标无数字，点进去却有 4 个子代理). Listening to
          // the controller is the fix; the `Builder` is kept so `L10n` still
          // resolves against the AppBar's context.
          Builder(
            builder: (context) {
              final chat = _chat;
              Widget badge(int count) => IconButton(
                    tooltip: l10n.teamBadgeTooltip,
                    onPressed: _openTeam,
                    icon: Badge(
                      isLabelVisible: count > 0,
                      label: Text('$count'),
                      child: const Icon(Icons.groups_outlined, size: 20),
                    ),
                  );
              if (chat == null) return badge(0);
              return ListenableBuilder(
                listenable: chat,
                builder: (context, _) => badge(
                  chat.projections?.values.subagentCatalog?.length ?? 0,
                ),
              );
            },
          ),
          // D-060: 原先是右下角 FAB，压住了 composer 的发送按钮。挪到顶栏。
          // `IconButton` 而不是 FAB：不需要强调色大块——它是第三个入口，
          // 和旁边的「成员」「会话列表」同级。
          IconButton(
            tooltip: l10n.sessionsNew,
            onPressed: _newSession,
            icon: const Icon(Icons.add_comment_outlined, size: 20),
          ),
          IconButton(
            tooltip: l10n.sessionsTitleShort,
            onPressed: _openSessions,
            icon: const Icon(Icons.list_alt, size: 20),
          ),
        ],
      ),
      body: Column(
        children: [
          // D-027: a dropped carrier used to be invisible — the bubble list
          // just stopped updating while prompts kept succeeding over unary
          // HTTP, so the console looked alive but was blind.
          if (_muxState != MuxState.connected && _machine != null)
            _ReconnectBanner(
              state: _muxState,
              l10n: l10n,
              deadCause: _terminalAuthCause(),
              onGoRepair: widget.onShowMachines,
            ),
          _SegmentBar(
            index: _segment,
            labels: [
              l10n.segmentChat,
              l10n.segmentTasks,
              l10n.segmentHost,
              l10n.segmentWorkspace,
              // D-042: 轨迹。放在最后而不是插在对话旁边——它是「检查
              // 同一段会话」的视角，不是主工作面，用户想看时才切过去。
              l10n.segmentTrajectory,
            ],
            onChanged: (i) => setState(() => _segment = i),
          ),
          Expanded(
            child: switch (_segment) {
              0 => ChatPane(controller: chat),
              1 when chat.sessionId != null => JobsPane(
                  gateway: chat.gateway,
                  sessionId: chat.sessionId!,
                  l10n: l10n,
                ),
              1 => _SegmentPlaceholder(l10n: l10n, label: l10n.jobsEmpty),
              2 when chat.sessionId != null => HostPane(
                  gateway: chat.gateway,
                  machineName: _machine?.name ?? '',
                  sessions: _sessions.value,
                  selection: _selection,
                  l10n: l10n,
                ),
              2 => _SegmentPlaceholder(l10n: l10n, label: l10n.consoleNoSessionBody),
              // D-036: the file tree is the *session's* workspace — the Host
              // scopes it to the session header, so it is meaningless without
              // one and says so instead of showing an empty tree.
              3 when chat.sessionId != null => WorkspacePane(
                  gateway: chat.gateway,
                  sessionId: chat.sessionId!,
                  l10n: l10n,
                ),
              3 => _SegmentPlaceholder(l10n: l10n, label: l10n.consoleNoSessionBody),
              // D-042: 轨迹读的是 controller 手里那本账本，和对话同一条
              // 事件流，所以这里不额外开流——见 `ChatController.ledger`。
              //
              // D-101: the pane itself is passive — it renders whatever the
              // ledger projects **at build time** — and this page does not
              // listen to the chat controller (only `ChatPane` does). So after
              // a background/resume the ledger was rebuilt from the fresh
              // snapshot, but a user **parked on this tab** kept seeing the
              // empty state until they switched away and back (真机 15:20:
              // resume 后轨迹空，切走再切回才恢复). Same shape as D-096; the
              // rebuild trigger is the controller's notify, which carries the
              // rebuilt projection with it.
              _ => ListenableBuilder(
                  listenable: chat,
                  builder: (context, _) => TrajectoryPane(
                    ledger: chat.ledger,
                    gateway: chat.gateway,
                    sessionId: chat.sessionId,
                    subagentLabel: chat.subagentLabel,
                    // D-112: 子代理补页要成对寻址，父半边只能来自 controller 的
                    // 记忆。漏传 = 轨迹页自己拿 child 的 id 顶替 parent。
                    parentSessionId: chat.parentSessionId,
                  ),
                ),
            },
          ),
        ],
      ),
      // D-060: 「新会话」曾经是右下角的 FAB，位置与 composer 的发送按钮
      // `IconButton(Icons.send)` **完全重合**（Scaffold 的 FAB 就在右下角）。
      // FAB 在上层，于是用户看得见输入框、看得见「新会话」、唯独发不出去——
      // 主操作不可达，而 D-048 刚把这个按钮放回来，谁都没看它落在哪儿。
      //
      // 修法不是把 FAB 挪开一点：右下角在对话页本来就该属于发送。入口移到顶栏
      // （会话列表按钮左侧），那里是「会话级操作」该在的地方，也符合 mockup 的
      // 顶栏布局。
    );
  }
}

/// Transport resources this page created and must therefore close when the
/// machine changes — an orphan mux socket would keep writing into a view that
/// no longer exists.
class _OwnedResources {
  _OwnedResources({required this.mux, required this.pinned});

  final EngineMux mux;
  final PinnedHttpClient pinned;

  void dispose() {
    mux.dispose();
    pinned.close();
  }
}

/// Pin table seeded from the machine's pairing-time TOFU pin lives in
/// `data/pin_store.dart` — one implementation shared by the console, the
/// machine detail page and the renewal scheduler (D-025 follow-up).

class _MachineChip extends StatelessWidget {
  const _MachineChip({required this.name, required this.onTap});
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.m, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.surfaceHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: AppTheme.accent),
              ),
              const SizedBox(width: AppTheme.s),
              // D-038: the machine name comes from the host, so it can be as
              // long as a hostname plus a suffix. Shrinkable, or it and the
              // model chip together overflow the bar.
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 16, color: AppTheme.inkDim),
            ],
          ),
        ),
      );
}

/// D-027 — says the carrier is down instead of letting the conversation look
/// alive-but-frozen. `warn` while backing off, `accent` for the 4001 heal,
/// which the relay uses when another device took the pairing.
/// D-110：横幅分两种，**「能自愈」和「已经没救了」必须说不一样的话**。
///
/// 原来的条件只有 `_muxState != connected`，于是凭证终态失效（`_realMint` 用
/// 旧 bearer 铸新链接 ⇒ 过期后连换凭证的门都锁着，见 `session_scheduler.dart:81`）
/// 也会永远挂上「连接已断开，正在重连…」。这句话承诺了「正在重连」，而真实情况
/// 是**永远重连不成**——D-104「文案写着正在重试，那就让它真的重试」的第四例。
///
/// 而且分层也错了：design §7.2 写明**会话失效属 L1 全屏页（红，唯一主行动）**，
/// L3 横幅是「自动消失」的层级。给终态挂一个自愈横幅，用户等多久都等不到。
class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({
    required this.state,
    required this.l10n,
    this.deadCause,
    this.onGoRepair,
  });

  final MuxState state;
  final L10n l10n;

  /// 非 null = 这台机器的凭证已经终态失效（重连无望），值是三因判别的结果。
  final AuthCause? deadCause;

  /// 终态时给用户的那**唯一**主行动（跳回机器页去重新配对）。
  final VoidCallback? onGoRepair;

  @override
  Widget build(BuildContext context) {
    final dead = deadCause != null;
    final healing = state == MuxState.healing;
    final color = dead
        ? AppTheme.danger
        : healing
            ? AppTheme.accent
            : AppTheme.warn;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.l, vertical: AppTheme.xs + 2),
      color: color.withValues(alpha: 0.12),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            // 终态没有「正在自愈」这回事——转圈就是在骗人。
            child: dead
                ? Icon(Icons.link_off_rounded, size: 12, color: color)
                : CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
          const SizedBox(width: AppTheme.s),
          Expanded(
            child: dead
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.consoleCredentialDead,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: color)),
                      Text(
                          l10n.consoleCredentialDeadWhy(_causeText(deadCause!)),
                          style: TextStyle(
                              fontSize: 10.5, color: color.withValues(alpha: .8))),
                    ],
                  )
                : Text(
                    healing ? l10n.err_ws_device_replaced : l10n.consoleReconnecting,
                    style: TextStyle(fontSize: 11.5, color: color),
                  ),
          ),
          if (dead && onGoRepair != null) ...[
            const SizedBox(width: AppTheme.s),
            TextButton(
              onPressed: onGoRepair,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.s),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l10n.consoleGoRepair,
                  style: const TextStyle(fontSize: 11.5)),
            ),
          ],
        ],
      ),
    );
  }

  /// 三因判别（design §7.2：401→`auth.expired`/`.revoked`/`.max_age`）。这里说
  /// 人话，不把 code 甩给用户——但 code 进日志，方便回溯。
  String _causeText(AuthCause cause) => switch (cause) {
        AuthCause.expired => l10n.authCauseExpired,
        AuthCause.revoked => l10n.authCauseRevoked,
        AuthCause.maxAge => l10n.authCauseMaxAge,
        AuthCause.unknown => l10n.authCauseUnknown,
      };
}

class _SegmentBar extends StatelessWidget {
  const _SegmentBar({
    required this.index,
    required this.labels,
    required this.onChanged,
  });

  final int index;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(AppTheme.l, 0, AppTheme.l, AppTheme.s),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.m),
        ),
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: i == index ? AppTheme.surfaceHigh : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppTheme.s),
                    ),
                    child: FittedBox(
                      // D-085: five tabs do not fit one narrow phone row in
                      // English — "Workspace" wrapped onto a second line and
                      // pushed the whole bar taller, so the tab you were on
                      // moved under your thumb while you were tapping it.
                      // Chinese is short enough to be unaffected. Scaling down
                      // keeps the label whole and readable; ellipsis would
                      // have turned it into "Workspa…".
                      fit: BoxFit.scaleDown,
                      child: Text(labels[i],
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight:
                                i == index ? FontWeight.w600 : FontWeight.w400,
                            color: i == index ? AppTheme.ink : AppTheme.inkDim,
                          )),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

class _SegmentPlaceholder extends StatelessWidget {
  const _SegmentPlaceholder({required this.l10n, required this.label});
  final L10n l10n;
  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          // Without this the line runs edge to edge on a phone and reads as
          // broken layout rather than as a message. The cap keeps a short
          // sentence from stretching across a tablet.
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.hourglass_empty,
                    size: 28, color: AppTheme.inkDim),
                const SizedBox(height: AppTheme.m),
                Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.inkDim,
                        height: 1.5)),
              ],
            ),
          ),
        ),
      );
}
