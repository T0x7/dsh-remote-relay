import 'dart:async';

import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/workspace_registry.dart';
import 'package:dsh_remote_app/console/workspaces/session_title_cache.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_registry_controller.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// D-047 + T2.2：pick a workspace, then a session inside it — **without ever
/// calling `session/list` on the critical path**.
///
/// The registry alone carries everything needed to draw the page: title, path,
/// and the full `sessionIds` of every workspace. `session/list` currently
/// takes 130+ seconds on a real host and is getting worse (see
/// `docs/internal/engine-session-list-degradation-report-20261004.md`), so putting it
/// here would make the entry point unusable again.
///
/// What that costs, stated plainly: rows show a session id, not a turn count or
/// a running badge. `parentSessionId` — and therefore the subagent nesting that
/// T2.2's DoD asks for — lives only on `SessionSummary`, so it arrives with the
/// **background** list. Until that lands the rows are flat; that is the honest
/// rendering rather than an invented hierarchy.
class WorkspacePickerPage extends StatefulWidget {
  const WorkspacePickerPage({
    super.key,
    required this.registry,
    required this.gateway,
    required this.machineName,
    required this.onOpenSession,
    required this.sessions,
    this.refreshSessions,
  });

  final WorkspaceRegistryController registry;

  /// Kept only so a conversation can be opened; the page never queries with it.
  final EngineGateway gateway;

  final String machineName;
  final void Function(String sessionId) onOpenSession;

  /// The console's background `session/list`. Used for two things, both
  /// non-blocking: sizing the **ungrouped** row (the baseline has no total) and
  /// reading `parentSessionId` to fold subagents under their parent.
  final ValueListenable<List<SessionSummary>> sessions;

  /// D-067: 死行（注册表里有、引擎列表里没有的 id）的判定前提是「手上有一份
  /// 足够新的 `session/list`」。本页不自己拉全量（D-047 的铁律），由宿主在
  /// 页面打开时后台刷一次；成功返回之前一律不判死——把还没核实过的 id 标成
  /// 「已失效」，和把点不开的行画成正常行，是同一种撒谎。刷新失败（引擎
  /// 降级/超时）同样维持不判死，功能整体退回旧行为。
  ///
  /// null = 宿主没有提供刷新能力，死行功能整体关闭（所有行保持可点）。
  final Future<void> Function()? refreshSessions;

  @override
  State<WorkspacePickerPage> createState() => _WorkspacePickerPageState();
}

  /// D-063: 会话行的显示名，三级来源按优先级：
///
/// 1. durable title（用户改过名 / 打开时记下的，D-062 持久化）；
/// 2. `projections.values.title`（引擎投影标题，`session/list` 就带着，
///    无需打开会话——但 `titleLike` 会过滤掉「日期行」和「子代理提示词」
///    这两类假标题）；
/// 3. id（兜底，如实）。
String _titleFor(
  List<SessionSummary> known,
  String id,
  SessionTitleCache titles,
) {
  final cached = titles.titles[id];
  if (cached != null && cached.isNotEmpty) return cached;
  final p = known.where((s) => s.sessionId == id).firstOrNull;
  if (p != null) return readableSessionName(p);
  return id;
}


class _WorkspacePickerPageState extends State<WorkspacePickerPage> {
  /// T2.2's other DoD: search. Client-side, because the only engine route that
  /// searches (`session/search`) takes free text, returns at most 20 unranked
  /// snippets, and would put a round trip back on the entry path.
  String _query = '';

  /// D-067: 最近一次后台 `session/list` 刷新是否成功落袋。只有它为真时，
  /// `sessions` 里的 id 集合才有资格当「引擎没有这个会话」的正据。
  bool _sessionsFresh = false;

  @override
  void initState() {
    super.initState();
    final refresh = widget.refreshSessions;
    if (refresh == null) return;
    // 后台刷，不挡首帧；每次进本页都会走到这里（宿主每次 push 新实例），
    // 所以离开再回来时正据会重新核实一遍。
    unawaited(refresh().then((_) {
      if (mounted) setState(() => _sessionsFresh = true);
    }).catchError((Object _) {
      // 刷新失败：保持不判死。这里故意不提示——工作区页的主功能（分组、
      // 打开、归档）不依赖这份列表，为一个辅助判定报错是本末倒置。
    }));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return ListenableBuilder(
      // titles 也要进 listenable：对话页记下一个标题后回到列表，那一行
      // 应当立刻从 id 变成名字，而不是要用户手动刷新。
      listenable: Listenable.merge(
          [widget.registry, widget.sessions, widget.registry.titles]),
      builder: (context, _) => _body(l10n, widget.sessions.value),
    );
  }

  /// The engine's three-way archive filter, offered as a popup because the
  /// phone has no room for a segmented control next to the search field, and
  /// because "only archived" is a mode rather than a toggle.
  Future<void> _pickArchiveView(L10n l10n) async {
    final picked = await showModalBottomSheet<ArchiveView>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.l, AppTheme.l, AppTheme.l, AppTheme.s),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.workspacesFilter,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            // One RadioGroup owns the selection, so the three tiles cannot end
            // up disagreeing about which one is checked.
            RadioGroup<ArchiveView>(
              groupValue: widget.registry.archiveView,
              onChanged: (v) => Navigator.of(sheetContext).pop(v),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final view in ArchiveView.values)
                    RadioListTile<ArchiveView>(
                      value: view,
                      title: Text(switch (view) {
                        ArchiveView.hide => l10n.workspacesFilterHide,
                        ArchiveView.show => l10n.workspacesFilterShow,
                        ArchiveView.only => l10n.workspacesFilterOnly,
                      }),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppTheme.s),
          ],
        ),
      ),
    );
    if (picked != null && mounted) widget.registry.archiveView = picked;
  }

  /// Archive, or explain why it cannot, then archive anyway.
  ///
  /// The two-step is not friction for its own sake: the plain call can be
  /// **refused** with `workspace/session-active`, and the only way through is
  /// `stopActivity: true`, which cancels a running desktop turn, its subagents,
  /// its background jobs and its schedules. A phone screen that offers one
  /// button reading "归档" would be asking a thumb to stop the computer's work
  /// with no warning, so the stop is its own named action with the activity
  /// spelled out above it.
  Future<void> _archive(L10n l10n, String sessionId) async {
    final registry = widget.registry;
    final first = await registry.archive(sessionId);
    if (!mounted) return;
    if (first.isOk) {
      _toast(l10n.workspacesArchiveDone);
      return;
    }
    if (first.error?.code != 'workspace/session-active') {
      _toast(l10n.workspacesArchiveFailed);
      return;
    }

    final activity = SessionActivityList.decode(first.error!.details);
    final force = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surfaceHigh,
        title: Text(l10n.workspacesArchiveBusyTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.workspacesArchiveBusyBody,
                style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: AppTheme.s),
            for (final line in _activityLines(l10n, activity))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· $line',
                    style: const TextStyle(fontSize: 12, color: AppTheme.ink)),
              ),
            if (activity.isEmpty)
              Text(l10n.workspacesArchivedHint,
                  style: const TextStyle(fontSize: 12, color: AppTheme.inkDim)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.workspacesArchiveBusyCancel),
          ),
          // Deliberately worded as its own consequence, not a confirmation of
          // "archive": it stops work on another machine.
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.workspacesArchiveBusyStopAndArchive,
                style: const TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (force != true || !mounted) return;

    final second = await registry.stopAndArchive(sessionId);
    if (!mounted) return;
    _toast(second.isOk
        ? l10n.workspacesArchiveDone
        : l10n.workspacesArchiveFailed);
  }

  /// One line per activity family, with its item labels.
  ///
  /// An unknown family is **not** dropped — it falls through to a generic line
  /// so the dialog never under-reports what stopping this session would cost.
  List<String> _activityLines(L10n l10n, SessionActivityList activity) {
    final out = <String>[];
    for (final entry in activity.byKind.entries) {
      final label = switch (entry.key) {
        'turn' => l10n.workspacesArchiveActivityTurn,
        'job' => l10n.workspacesArchiveActivityJob,
        'subagent' => l10n.workspacesArchiveActivitySubagent,
        'schedule' => l10n.workspacesArchiveActivitySchedule,
        final other => l10n.workspacesArchiveActivityOther(other),
      };
      final names = entry.value.map((i) => i.display).join(
            // The separator and the "label: names" shape are copy, so they live
            // in the arb — English wants ", " and ": " where Chinese wants
            // "、" and "：", and a hardcoded one would quietly pick the wrong
            // punctuation for half the users.
            l10n.workspacesArchiveActivityJoin,
          );
      out.add(names.isEmpty
          ? label
          : l10n.workspacesArchiveActivityWith(label, names));
    }
    return out;
  }

  Future<void> _unarchive(L10n l10n, String sessionId) async {
    final result = await widget.registry.unarchive(sessionId);
    if (!mounted) return;
    if (!result.isOk) _toast(l10n.workspacesUnarchiveFailed);
  }

  Future<void> _togglePin(L10n l10n, String sessionId) async {
    final registry = widget.registry;
    final result = registry.isPinned(sessionId)
        ? await registry.unpin(sessionId)
        : await registry.pin(sessionId);
    if (!mounted) return;
    if (!result.isOk) {
      _toast(result.error?.code == 'gateway/arguments-invalid'
          ? l10n.workspacesPinFailed
          : l10n.workspacesPinFailed);
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _body(L10n l10n, List<SessionSummary> known) {
    final registry = widget.registry;
    final error = registry.error;
    if (error != null) {
      return _Centered(text: l10n.workspacesUnavailable);
    }
    if (!registry.loaded) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final groups = _groups(l10n, registry, known, _query, _sessionsFresh);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.workspacesTitle(widget.machineName),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        backgroundColor: AppTheme.bg,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.m, AppTheme.s, AppTheme.m, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: l10n.workspacesSearchHint,
                      hintStyle:
                          const TextStyle(fontSize: 12, color: AppTheme.inkDim),
                      prefixIcon: const Icon(Icons.search,
                          size: 18, color: AppTheme.inkDim),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      filled: true,
                      fillColor: AppTheme.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppTheme.m),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.s),
                // The filter is only worth showing as an affordance when it is
                // off-default: in `hide` there is nothing to reveal.
                _ArchiveFilterButton(
                  view: registry.archiveView,
                  onPressed: () => _pickArchiveView(l10n),
                ),
              ],
            ),
          ),
          if (registry.isSettling)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.m, AppTheme.s, AppTheme.m, 0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                  const SizedBox(width: AppTheme.s),
                  Expanded(
                    child: Text(
                      l10n.workspacesSyncing,
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.inkDim),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.m, AppTheme.s, AppTheme.m, AppTheme.xl),
              children: [
                for (final group in groups)
                  _WorkspaceRow(
                    title: group.title,
                    path: group.path,
                    rows: group.rows,
                    countKnown: group.countKnown,
                    settling: registry.isSettling,
                    isUngrouped: group.isUngrouped,
                    machineName: widget.machineName,
                    l10n: l10n,
                    gateway: widget.gateway,
                    onOpenSession: widget.onOpenSession,
                    registry: registry,
                    onUnarchive: (id) => _unarchive(l10n, id),
                    onTogglePin: (id) => _togglePin(l10n, id),
                    onArchive: (id) => _archive(l10n, id),
                    known: known,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Registered workspaces in the engine's own order, then **未分组** last.
  ///
  /// A row is `({String id, bool nested, bool dead})` — `nested` marks a
  /// subagent so the row can be indented under its parent (T2.2's shape), and
  /// `dead` marks an id the engine no longer has (D-067).
  List<({
    String title,
    String? path,
    List<({String id, bool nested, bool dead})> rows,
    bool isUngrouped,
    bool countKnown,
    bool matchedByName,
  })> _groups(
    L10n l10n,
    WorkspaceRegistryController registry,
    List<SessionSummary> known,
    String query,
    bool deadKnown,
  ) {
    final needle = query.trim().toLowerCase();
    final byId = {for (final s in known) s.sessionId: s};
    // Parent links only exist on `SessionSummary`, so they arrive with the
    // background list; before that the rows stay flat and say nothing false.
    final parentOf = {for (final s in known) s.sessionId: s.parentSessionId};
    // D-067: 判死只在拿到成功刷新过的列表之后。死行没有 parent 信息
    //（引擎 summary 里才带），必然是根行，折叠逻辑不受影响。
    final liveIds = {for (final s in known) s.sessionId};
    bool dead(String id) => deadKnown && !liveIds.contains(id);

    List<({String id, bool nested, bool dead})> shape(List<String> ordered) {
      final keep = ordered.toSet();
      final children = <String, List<String>>{};
      final roots = <String>[];
      for (final id in ordered) {
        final parent = parentOf[id];
        if (parent != null && keep.contains(parent)) {
          (children[parent] ??= <String>[]).add(id);
        } else {
          roots.add(id);
        }
      }
      final out = <({String id, bool nested, bool dead})>[];
      final emitted = <String>{};
      void walk(String id, {required bool nested}) {
        if (!emitted.add(id)) return;
        out.add((id: id, nested: nested, dead: dead(id)));
        for (final child in children[id] ?? const <String>[]) {
          walk(child, nested: true);
        }
      }

      for (final id in roots) {
        walk(id, nested: false);
      }
      // A parent/child cycle would leave some ids unreachable from a root;
      // emit them flat rather than lose a live session to a layout rule.
      for (final id in ordered) {
        walk(id, nested: false);
      }
      return out;
    }

    // D-059: 搜索命中三种东西——id、cwd、以及**已经知道的标题**。
    // 标题这一格是新增的：用户记得住「nightly-backtest 复盘」，记不住
    // `31a580dc-bd6a-48bc-8cc0-f2d290d25898`。
    bool matchesRow(String id) {
      if (needle.isEmpty) return true;
      if (id.toLowerCase().contains(needle)) return true;
      final cwd = byId[id]?.cwd;
      if (cwd != null && cwd.toLowerCase().contains(needle)) return true;
      final title = _titleFor(known, id, registry.titles);
      // title==id 时（无任何已知名字）再比一次 id 是无害的冗余。
      return title.toLowerCase().contains(needle);
    }

    final out =
        <({String title, String? path, List<({String id, bool nested, bool dead})> rows, bool isUngrouped, bool countKnown, bool matchedByName})>[];

    // D-055: the archive filter is applied to the *rows*, never to the groups.
    // A workspace that owns both archived and live sessions keeps its card in
    // every view; hiding the whole card would make `only` look like data loss.
    final view = registry.archiveView;
    for (final workspace in registry.workspaces) {
      final titleHit = needle.isNotEmpty &&
          (workspace.title.toLowerCase().contains(needle) ||
              workspace.path.toLowerCase().contains(needle));
      // A workspace-name match keeps the group but drops the rows: the user
      // asked for this workspace, not for the first three of its sessions.
      //
      // D-067: 活行在前、死行垫底（各自保持注册表原序，不用 sort——Dart 的
      // sort 不保稳定，会让行序在重建间跳动）。卡片只预览 3 行，别让一行
      // 引擎里早就没有的记录占掉有用名额。
      final rows = titleHit
          ? const <({String id, bool nested, bool dead})>[]
          : shape([
              for (final id in workspace.sessionIds)
                if (matchesRow(id) &&
                    registry.isVisible(id) &&
                    !dead(id)) id,
              for (final id in workspace.sessionIds)
                if (matchesRow(id) && registry.isVisible(id) && dead(id)) id,
            ]);
      out.add((
        title: workspace.title,
        path: workspace.path,
        rows: rows,
        isUngrouped: false,
        countKnown: true,
        matchedByName: titleHit,
      ));
    }

    // The ungrouped row is always present — a host with sessions but no
    // registered workspaces is a real state, not a reason to show nothing.
    out.add((
      title: l10n.workspacesUngrouped,
      path: null,
      rows: shape([
        for (final id in registry.ungroupedSessionIds(
          known.map((s) => s.sessionId),
        ))
          if (registry.isVisible(id) && matchesRow(id)) id,
      ]),
      isUngrouped: true,
      countKnown: known.isNotEmpty,
      matchedByName: false,
    ));

    // `only` gets a dedicated group, because "3 archived sessions" is the fact
    // that view exists to deliver and it is not answerable by counting rows
    // scattered across other cards.
    if (view == ArchiveView.only) {
      final archived = registry.archivedSessionIds;
      out.insert(
        0,
        (
          title: l10n.workspacesFilterOnly,
          path: null,
          rows: shape([
            for (final id in archived)
              if (matchesRow(id)) id,
          ]),
          isUngrouped: false,
          countKnown: true,
          matchedByName: archived.isNotEmpty,
        ),
      );
    }

    return [
      for (final g in out)
        // A name match keeps the group with no rows: the user asked for this
        // workspace, and an empty screen would read as "nothing matched".
        //
        // The ungrouped row is the exception in `only` view: archived sessions
        // are excluded from that computation by definition, so it would always
        // render an empty card with a "—" that reads as a broken count rather
        // than as "there is nothing here".
        if (g.rows.isNotEmpty ||
            (g.isUngrouped && view != ArchiveView.only) ||
            g.matchedByName)
          g,
    ];
  }
}

class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow({
    required this.title,
    required this.path,
    required this.rows,
    required this.countKnown,
    required this.settling,
    required this.isUngrouped,
    required this.machineName,
    required this.l10n,
    required this.gateway,
    required this.onOpenSession,
    required this.registry,
    required this.onUnarchive,
    required this.onTogglePin,
    required this.onArchive,
    required this.known,
  });

  final String title;
  final String? path;
  final List<({String id, bool nested, bool dead})> rows;

  /// False only for the ungrouped row before the background list lands.
  final bool countKnown;

  /// D-057: 引擎正在重算这个工作区的成员资格，此刻的行数不是事实。
  final bool settling;
  final bool isUngrouped;
  final String machineName;
  final L10n l10n;
  final EngineGateway gateway;
  final void Function(String sessionId) onOpenSession;

  final WorkspaceRegistryController registry;
  final void Function(String sessionId) onUnarchive;
  final void Function(String sessionId) onTogglePin;
  final void Function(String sessionId) onArchive;

  /// D-063: 后台 `session/list`。标题的第二来源（投影 title）从这里查。
  final List<SessionSummary> known;

  /// How many sessions a row previews. Grouping exists for legibility; a
  /// 600-row list is the thing being fixed.
  static const _previewRows = 3;

  @override
  Widget build(BuildContext context) {
    final preview = rows.take(_previewRows).toList();
    final rest = rows.length - preview.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.m),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => _WorkspaceSessionsPage(
                  title: title,
                  rows: rows,
                  l10n: l10n,
                  onOpenSession: onOpenSession,
                  registry: registry,
                  onUnarchive: onUnarchive,
                  onTogglePin: onTogglePin,
                  onArchive: onArchive,
                  known: known,
                ),
              )),
              borderRadius: BorderRadius.circular(AppTheme.m),
              child: Padding(
                padding: const EdgeInsets.all(AppTheme.m),
                child: Row(
                  children: [
                    Icon(
                      isUngrouped
                          ? Icons.inbox_outlined
                          : Icons.folder_outlined,
                      size: 18,
                      color: isUngrouped ? AppTheme.inkDim : AppTheme.accent,
                    ),
                    const SizedBox(width: AppTheme.s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: const TextStyle(
                                  fontSize: 13.5, fontWeight: FontWeight.w600)),
                          if (path != null)
                            Text(
                              path!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 10.5, color: AppTheme.inkDim),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      // D-057: 三个「不知道」都要说不知道，不能拿一个每 4 秒
                      // 变一次、跨度 35~94 的数字充数：
                      //  - 未分组且后台列表没到 → 引擎的全量我们不知道；
                      //  - 引擎正在重算成员资格 → 这一刻的数不是事实；
                      //  - 否则才是真值。
                      countKnown && !settling ? '${rows.length}' : '—',
                      style: const TextStyle(fontSize: 12, color: AppTheme.inkDim),
                    ),
                    const Icon(Icons.chevron_right,
                        size: 18, color: AppTheme.inkDim),
                  ],
                ),
              ),
            ),
            if (preview.isNotEmpty) ...[
              const Divider(height: 1, color: AppTheme.line),
              for (final row in preview)
                _SessionLine(
                  sessionId: row.id,
                  title: _titleFor(known, row.id, registry.titles),
                  nested: row.nested,
                  dead: row.dead,
                  onTap: () => onOpenSession(row.id),
                  archived: registry.isArchived(row.id),
                  pinned: registry.isPinned(row.id),
                  onUnarchive: () => onUnarchive(row.id),
                  onTogglePin: () => onTogglePin(row.id),
                  onArchive: () => onArchive(row.id),
                ),
              Padding(
                // Same left edge as the rows above it, so the card has one
                // vertical line instead of three ragged ones.
                padding: const EdgeInsets.fromLTRB(
                    AppTheme.l + AppTheme.s, AppTheme.xs, AppTheme.m, AppTheme.m),
                child: Text(
                  rest > 0
                      ? l10n.workspacesMore(rest)
                      : l10n.workspacesSessionCount(rows.length),
                  style:
                      const TextStyle(fontSize: 10.5, color: AppTheme.inkDim),
                ),
              ),
            ] else if (!isUngrouped) ...[
              const Divider(height: 1, color: AppTheme.line),
              Padding(
                padding: const EdgeInsets.all(AppTheme.m),
                child: Text(l10n.workspacesEmptyGroup,
                    style: const TextStyle(
                        fontSize: 11.5, color: AppTheme.inkDim)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One workspace's sessions, from the registry's own `sessionIds`.
///
/// Takes no gateway: there is no scoped-list route to call, and calling the
/// unscoped one to answer a scoped question is the 130-second mistake this
/// whole change exists to remove.
class _WorkspaceSessionsPage extends StatelessWidget {
  const _WorkspaceSessionsPage({
    required this.title,
    required this.rows,
    required this.l10n,
    required this.onOpenSession,
    required this.registry,
    required this.onUnarchive,
    required this.onTogglePin,
    required this.onArchive,
    required this.known,
  });

  final String title;
  final List<({String id, bool nested, bool dead})> rows;
  final L10n l10n;
  final void Function(String sessionId) onOpenSession;
  final WorkspaceRegistryController registry;
  final void Function(String sessionId) onUnarchive;
  final void Function(String sessionId) onTogglePin;
  final void Function(String sessionId) onArchive;

  /// D-063: 后台 `session/list`。标题的第二来源（投影 title）从这里查。
  final List<SessionSummary> known;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          backgroundColor: AppTheme.bg,
        ),
        body: ListenableBuilder(
          // The list repaints on every registry change, because a row's
          // archived/pinned state and its action buttons all read from it —
          // a static list would show a stale "unarchive" button after the
          // session was already restored.
          listenable: Listenable.merge([registry, registry.titles]),
          builder: (context, _) => ListView.separated(
            padding: const EdgeInsets.all(AppTheme.m),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppTheme.xs),
            itemBuilder: (context, i) => _SessionLine(
              sessionId: rows[i].id,
              title: _titleFor(known, rows[i].id, registry.titles),
              nested: rows[i].nested,
              dead: rows[i].dead,
              onTap: () => onOpenSession(rows[i].id),
              archived: registry.isArchived(rows[i].id),
              pinned: registry.isPinned(rows[i].id),
              onUnarchive: () => onUnarchive(rows[i].id),
              onTogglePin: () => onTogglePin(rows[i].id),
              onArchive: () => onArchive(rows[i].id),
            ),
          ),
        ),
      );
}

class _SessionLine extends StatelessWidget {
  const _SessionLine({
    required this.sessionId,
    required this.onTap,
    this.title,
    this.nested = false,
    this.archived = false,
    this.pinned = false,
    this.dead = false,
    this.onUnarchive,
    this.onTogglePin,
    this.onArchive,
  });

  final String sessionId;
  final VoidCallback onTap;

  /// D-059: 打开过这个会话时记下的标题；null = 未知，如实显示 id。
  final String? title;

  /// A subagent hangs under its parent (T2.2's DoD). A top-level row keeps the
  /// card's own left margin; a nested one steps in one more level.
  final bool nested;

  /// Archived rows are greyed and **cannot be opened** — the engine's own rule
  /// ("cannot open until restored", web-client.md:52). They carry a restore
  /// action instead, so hiding the row is never the only way out.
  final bool archived;

  final bool pinned;

  /// D-067: 引擎的 `session/list` 里已经没有这个 id——多为宿主侧任务绕过
  /// 引擎直写的记录，或 journal 被清理后的注册表残留。行仍然画出来（归档
  /// 清理需要一个入口），但绝不能假装它点得开。
  final bool dead;

  final VoidCallback? onUnarchive;
  final VoidCallback? onTogglePin;
  final VoidCallback? onArchive;

  @override
  Widget build(BuildContext context) {
    final dim = archived || dead || nested;
    // An archived row is inert: tapping it must not open a session that the
    // engine has already gated out of model steps. A dead one would fail with
    // session/not-found — the exact complaint D-067 fixes — so it is just as
    // inert, but it keeps its archive action as the cleanup path.
    final canOpen = !archived && !dead;
    return InkWell(
      onTap: canOpen ? onTap : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppTheme.m + (nested ? AppTheme.l : 0),
          AppTheme.xs,
          AppTheme.xs,
          AppTheme.xs,
        ),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: AppTheme.s),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: archived
                    ? AppTheme.inkDim
                    : dead
                        ? AppTheme.line
                        : nested
                            ? AppTheme.line
                            : AppTheme.accent,
              ),
            ),
            Expanded(
              child: Text(
                title ?? sessionId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  // 标题是给人读的，给它一点字重；id 是退路，保持和原来一样轻。
                  fontWeight: title == null ? null : FontWeight.w500,
                  fontSize: 11.5,
                  color: dim ? AppTheme.inkDim : AppTheme.ink,
                  // 归档是「用户亲手收起来的」，划线表达收起；失效是「引擎
                  // 已经没有了」，不划线——两件事长一个样，用户就分不清
                  // 该按恢复还是该按归档。
                  decoration: archived ? TextDecoration.lineThrough : null,
                  decorationColor: AppTheme.inkDim,
                ),
              ),
            ),
            // D-067: 失效徽标给「为什么点不开」一个当场可读的答案；长按/
            // 悬停提示解释来历和清理办法。
            if (dead && !archived)
              Padding(
                padding: const EdgeInsets.only(right: AppTheme.xs),
                child: Tooltip(
                  message: L10n.of(context).workspacesDeadHint,
                  child: Text(
                    L10n.of(context).workspacesDeadBadge,
                    style: const TextStyle(
                        fontSize: 9.5, color: AppTheme.inkDim),
                  ),
                ),
              ),
            // Pinned state lives on the **button**, not on a second badge icon
            // beside it: two identical glyphs in one row is visual noise, and
            // it makes "which one do I tap" a real question. A filled, accented
            // pin still scans at a glance.
            if (archived)
              _RowAction(
                icon: Icons.unarchive_outlined,
                tooltip: L10n.of(context).workspacesUnarchive,
                onPressed: onUnarchive,
              )
            else if (dead) ...[
              // 死行只留归档：置顶一个引擎里不存在的会话没有意义。
              _RowAction(
                icon: Icons.archive_outlined,
                tooltip: L10n.of(context).workspacesArchive,
                onPressed: onArchive,
              ),
            ] else ...[
              _RowAction(
                icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
                tooltip: pinned
                    ? L10n.of(context).workspacesUnpin
                    : L10n.of(context).workspacesPin,
                active: pinned,
                onPressed: onTogglePin,
              ),
              _RowAction(
                icon: Icons.archive_outlined,
                tooltip: L10n.of(context).workspacesArchive,
                onPressed: onArchive,
              ),
            ],
            const SizedBox(width: AppTheme.xs),
          ],
        ),
      ),
    );
  }
}

/// One session row's icon button, sized for a thumb without dominating a row
/// that is mostly a session id.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Renders in the accent colour — used for "already pinned", so state is on
  /// the control the user would press rather than on a second glyph.
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: IconButton(
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          icon: Icon(
            icon,
            size: 16,
            color: active ? AppTheme.accent : AppTheme.inkDim,
          ),
        ),
      );
}

/// The archive-view toggle, beside the search field.
class _ArchiveFilterButton extends StatelessWidget {
  const _ArchiveFilterButton({required this.view, required this.onPressed});

  final ArchiveView view;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final active = view != ArchiveView.hide;
    return Tooltip(
      message: l10n.workspacesFilter,
      child: Material(
        color: active ? AppTheme.surfaceHigh : AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.m),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppTheme.m),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.s + 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.m),
              border: Border.all(
                color: active ? AppTheme.accent : Colors.transparent,
                width: 1,
              ),
            ),
            child: Icon(
              Icons.filter_list,
              size: 19,
              color: active ? AppTheme.accent : AppTheme.inkDim,
            ),
          ),
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.xl),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
        ),
      );
}
