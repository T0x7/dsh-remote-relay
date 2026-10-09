import 'dart:async';

import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';

import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

import '../inline_error_card.dart';

/// The session list (mockup 屏 M), one screen per machine.
///
/// Rows come from `session/list`; a subagent child is **indented under its
/// parent** rather than listed flat, because the engine reports it as a child
/// session and the parent link is what makes the tree legible. Tapping a row
/// restores the *engine-side* session, so the phone and the web client resume
/// the same conversation (两端接力).
class SessionsPage extends StatefulWidget {
  const SessionsPage({
    super.key,
    required this.gateway,
    required this.machineName,
    required this.onOpenSession,
    this.refreshInterval = const Duration(seconds: 30),
    this.retryDelay = const Duration(seconds: 2),
    this.scheduleRetry,
  });

  final EngineGateway gateway;
  final String machineName;
  final void Function(SessionSummary session) onOpenSession;


  /// D-037: how often to re-read the list. The control stream drives projection
  /// updates; the list itself is polled because `session/list` is a cold read
  /// and the engine exposes no delta for it.
  final Duration refreshInterval;

  /// D-037: first backoff wait after a transient failure. The second waits
  /// twice as long, so a briefly busy engine recovers without a tap and a
  /// wedged one still surfaces the retry button quickly.
  final Duration retryDelay;

  /// D-037: how a backoff is armed. Production uses a [Timer]; a test injects
  /// its own so the retry path is drivable without a real clock — a
  /// `testWidgets` fake clock cannot reach a Timer armed from inside an async
  /// callback, which would otherwise leave the whole recovery path untested.
  final void Function(Duration delay, void Function() action)? scheduleRetry;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  List<SessionSummary> _rows = [];
  bool _loading = true;
  AppError? _error;

  /// D-037: how many transient failures this page has retried through. Reset
  /// on any success, so a load that recovers stops counting.
  int _attempt = 0;
  Timer? _retryTimer;

  /// D-037: `session/list` cannot page. The request carries a `cursor` the
  /// engine ignores (`api/session-controller/src/index.ts:252` names the
  /// parameter `_request`), so a host with years of job sessions answers with
  /// every one of them — 1567 rows measured on this host. Building a row per
  /// session on a phone is what turned a slow read into a 504, so the list is
  /// capped here and says so instead of pretending it is complete.
  static const int maxRenderedRows = 60;

  /// Whether [_rows] was cut by [maxRenderedRows].
  bool get _truncated => _rows.length > maxRenderedRows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final result = await widget.gateway.listSessions();
    AppLog.d('e2e', '[e2e] session/list ok=${result.isOk} err=${result.error}');
    if (!mounted) return;
    if (result.isOk) {
      _attempt = 0;
      setState(() {
        _loading = false;
        final items = (result.value! as Map<String, dynamic>)['items']! as List<SessionSummary>;
        // D-037: the newest-first order is the App's promise, not the engine's:
        // `session/list` documents no ordering, and the render cap keeps the
        // first N — so the sort has to happen before the cut, here.
        final sorted = [...items]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        _rows = sorted;
        _error = null;
      });
      return;
    }
    final error = result.error!.toAppError();
    // Stale rows beat an empty screen: a refresh that times out must not throw
    // away the list the user was reading.
    if (_rows.isNotEmpty) {
      setState(() => _error = null);
      _scheduleRetry();
      return;
    }
    setState(() {
      _loading = false;
      _error = error;
    });
    _scheduleRetry();
  }

  /// D-037: recover from a busy engine on its own. Two attempts is the whole
  /// budget — after that the error card with its button is the honest answer,
  /// and the user decides.
  void _scheduleRetry() {
    if (_attempt >= 2) return;
    final wait = widget.retryDelay * (1 << _attempt);
    void fire() {
      _attempt++;
      if (mounted) _load();
    }
    final schedule = widget.scheduleRetry;
    if (schedule != null) {
      schedule(wait, fire);
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, fire);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.sessionsTitle(widget.machineName),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppTheme.bg,
      ),
      body: _body(l10n),
    );
  }

  Widget _body(L10n l10n) {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(AppTheme.l),
        children: [
          InlineErrorCard(error: _error!, l10n: l10n),
          const SizedBox(height: AppTheme.m),
          FilledButton(
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
            child: Text(l10n.retry),
          ),
        ],
      );
    }
    if (_rows.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(AppTheme.xl),
        children: [
          const SizedBox(height: 80),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.chat_bubble_outline, size: 44, color: AppTheme.inkDim),
                const SizedBox(height: AppTheme.m),
                Text(l10n.sessionsEmpty,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: AppTheme.xs),
                Text(l10n.sessionsEmptyBody,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.xl),
          // The two-ends note is true whether or not there is anything to
          // resume, and it is the question every first-time user has.
          Text(l10n.sessionsFooter,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppTheme.m, AppTheme.s, AppTheme.m, AppTheme.xl),
      children: [
        if (_truncated)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.s),
            child: Text(l10n.sessionsTruncated(maxRenderedRows, _rows.length),
                style: const TextStyle(fontSize: 11, color: AppTheme.warn)),
          ),
        for (final row in _tree()) _SessionRowTile(
              session: row.session,
              child: row.child,
              l10n: l10n,
              // The tile draws `child ?? session`, so the tap has to resolve the
              // same way — otherwise tapping a subagent row restored its parent.
              onTap: () => widget.onOpenSession(row.child ?? row.session),
            ),
        const SizedBox(height: AppTheme.m),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.s),
          child: Text(l10n.sessionsFooter,
              style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
        ),
      ],
    );
  }

  /// Flatten to parent rows with their children nested underneath.
  ///
  /// A child whose parent is not in the list (filtered out or already pruned)
  /// is promoted to a top row rather than dropped — losing a live subagent
  /// from the list would be worse than a slightly flat layout.
  ///
  /// D-037: the engine returns every session in one body (its `cursor` is
  /// ignored), so the cut happens here, on the flattened rows, and only after
  /// the tree is built — capping parents first would orphan their children.
  /// The engine's list is already ordered by `updatedAt` descending, so the
  /// newest conversations are the ones kept.
  List<({SessionSummary session, SessionSummary? child})> _tree() {
    final parents = <String, SessionSummary>{};
    final children = <String, List<SessionSummary>>{};
    for (final row in _rows) {
      if (row.parentSessionId != null) {
        (children[row.parentSessionId!] ??= []).add(row);
      } else {
        parents[row.sessionId] = row;
      }
    }
    final out = <({SessionSummary session, SessionSummary? child})>[];
    for (final parent in parents.values) {
      out.add((session: parent, child: null));
      for (final child in children[parent.sessionId] ?? const <SessionSummary>[]) {
        out.add((session: parent, child: child));
      }
    }
    for (final orphan in _rows.where((r) =>
        r.parentSessionId != null && !parents.containsKey(r.parentSessionId!))) {
      out.add((session: orphan, child: null));
    }
    if (out.length <= maxRenderedRows) return out;
    return out.take(maxRenderedRows).toList(growable: false);
  }
}

class _SessionRowTile extends StatelessWidget {
  const _SessionRowTile({
    required this.session,
    required this.child,
    required this.l10n,
    required this.onTap,
  });

  final SessionSummary session;
  final SessionSummary? child;
  final L10n l10n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final target = child ?? session;
    final isChild = child != null;
    final title = _titleOf(target);
    final subtitle = isChild
        ? l10n.sessionsChildSubtitle(_relativeTime(target.updatedAt))
        : l10n.sessionsRowSubtitle(
            _relativeTime(target.updatedAt),
            target.projections?.values.sessionStats?.turns ?? 0,
          );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.m),
      child: Container(
        margin: EdgeInsets.only(
            bottom: AppTheme.xs, left: isChild ? AppTheme.xl : 0, right: 0),
        padding: const EdgeInsets.all(AppTheme.m),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.m),
        ),
        child: Row(
          children: [
            _StatusDot(running: target.running, isChild: isChild),
            const SizedBox(width: AppTheme.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                        fontSize: isChild ? 12.5 : 13.5,
                        fontWeight: FontWeight.w600,
                        color: isChild ? AppTheme.inkDim : AppTheme.ink,
                      )),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
                ],
              ),
            ),
            if (target.running)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.s, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(l10n.sessionsRunning,
                    style: const TextStyle(fontSize: 9.5, color: AppTheme.accent)),
              ),
          ],
        ),
      ),
    );
  }

  /// A session's own title, falling back to a short id: the engine may not
  /// have named it yet, and a blank row is unusable on a phone.
  String _titleOf(SessionSummary session) {
    if (session.sessionId.isEmpty) return l10n.sessionsUntitled;
    return session.sessionId.length <= 24
        ? session.sessionId
        : '${session.sessionId.substring(0, 24)}…';
  }

  static String _relativeTime(int epochMs) {
    final delta = DateTime.now().millisecondsSinceEpoch - epochMs;
    if (delta < 60 * 1000) return 'now';
    if (delta < 3600 * 1000) return '${delta ~/ 60000}m';
    if (delta < 86400 * 1000) return '${delta ~/ 3600000}h';
    return '${delta ~/ 86400000}d';
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.running, required this.isChild});

  final bool running;
  final bool isChild;

  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: running ? AppTheme.accent : AppTheme.line,
        ),
      );
}
