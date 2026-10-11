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
  });

  final MachinesStore store;

  /// Machine → gateway. Null builds a real client over the pinned stack.
  final EngineGateway Function(MachineEntry entry)? gatewayFactory;

  /// D-062: 标题缓存。null = inMemory（测试与不需要持久化的调用方）；
  /// 真 App 在 app_root.dart 接线处传持久化版本。
  final SessionTitleCache? titleCache;

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
    _chat?.dispose();
    _disposeOwned();
    super.dispose();
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
    LiveMachineScope.instance.claim(entry.id);
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
    final latest = rows.isEmpty ? null : _latestResumable(rows);
    if (latest != null) {
      await chat.open(latest.sessionId);
      await chat.refreshProjections();
      if (mounted) setState(() {});
    }
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
    final preset = await showAgentPresetSheet(context, chat.gateway);
    if (preset == null || !mounted) return;
    final result = await chat.gateway
        .createSession(agentPreset: preset.isEmpty ? null : preset);
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
            _ReconnectBanner(state: _muxState, l10n: l10n),
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
class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({required this.state, required this.l10n});

  final MuxState state;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final healing = state == MuxState.healing;
    final color = healing ? AppTheme.accent : AppTheme.warn;
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
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
          const SizedBox(width: AppTheme.s),
          Expanded(
            child: Text(
              healing ? l10n.err_ws_device_replaced : l10n.consoleReconnecting,
              style: TextStyle(fontSize: 11.5, color: color),
            ),
          ),
        ],
      ),
    );
  }
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
