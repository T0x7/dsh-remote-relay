/// D-046: the engine's Workspace registry, as a client sees it.
///
/// Shapes are hand-copied from the engine and carry its own citations:
/// `packages/api/workspace-controller/src/types.ts:18-29` (`WorkspaceView`),
/// `:153-157` (`WorkspaceBaseline`), `:161-167` (`WorkspaceFollowIncrement`),
/// `:169-170` (`WorkspaceFollowFrame`).
///
/// The registry is **machine-scoped**: it answers "which workspaces does this
/// engine host", not "where is the open session working". That is the whole
/// point of D-046 — the console already knows which machine it is talking to,
/// so the workspace list belongs to the machine, while a session's `cwd` is a
/// detail that lives *inside* the conversation.
library;

import 'dart:async';

import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_models.dart';

/// One registered workspace.
class WorkspaceView {
  const WorkspaceView({
    required this.workspaceId,
    required this.path,
    required this.title,
    required this.sessionIds,
    required this.createdAt,
    required this.updatedAt,
  });

  factory WorkspaceView.fromJson(Map<String, dynamic> j) => WorkspaceView(
        workspaceId: _str(j['workspaceId']),
        path: _str(j['path']),
        title: _str(j['title']),
        sessionIds: [
          for (final id in asList(j['sessionIds']) ?? const <Object?>[])
            if (id is String) id,
        ],
        createdAt: _str(j['createdAt']),
        updatedAt: _str(j['updatedAt']),
      );

  final String workspaceId;

  /// `fs.realpath` of the registered path, resolved once at create time and
  /// never rewritten (engine `types.ts:67-72`).
  final String path;

  /// Display title — `定时任务` / `策略交易` / … Defaults to the last path
  /// segment when the host does not set one.
  final String title;

  final List<String> sessionIds;
  final String createdAt;
  final String updatedAt;
}

/// The opening snapshot: every workspace plus the host's archived / pinned
/// session sets. Exactly one baseline per subscription.
class WorkspaceBaseline {
  const WorkspaceBaseline({
    required this.items,
    required this.archivedSessionIds,
    required this.pinnedSessionIds,
  });

  factory WorkspaceBaseline.fromJson(Map<String, dynamic> j) => WorkspaceBaseline(
        items: [
          for (final item in asList(j['items']) ?? const <Object?>[])
            if (asObject(item) case final Map<String, dynamic> m)
              WorkspaceView.fromJson(m),
        ],
        archivedSessionIds: _strings(j['archivedSessionIds']),
        pinnedSessionIds: _strings(j['pinnedSessionIds']),
      );

  final List<WorkspaceView> items;
  final List<String> archivedSessionIds;
  final List<String> pinnedSessionIds;
}

/// One decoded frame off the `workspace/follow` stream.
///
/// A fresh subscription's *first* frame is always [WorkspaceBaselineFrame];
/// everything after is an increment. A second baseline on the same
/// subscription is a protocol fault rather than a refresh, exactly like
/// `session/follow`.
sealed class WorkspaceFollowFrame {
  const WorkspaceFollowFrame();
}

class WorkspaceBaselineFrame extends WorkspaceFollowFrame {
  const WorkspaceBaselineFrame(this.value);
  final WorkspaceBaseline value;
}

class WorkspaceUpsertFrame extends WorkspaceFollowFrame {
  const WorkspaceUpsertFrame(this.workspace);
  final WorkspaceView workspace;
}

class WorkspaceRemoveFrame extends WorkspaceFollowFrame {
  const WorkspaceRemoveFrame(this.workspaceId);
  final String workspaceId;
}

/// A full replacement of the manual order. Absolute, not a delta — the engine
/// sends the complete id list so a dropped frame cannot leave a hole.
class WorkspaceOrderFrame extends WorkspaceFollowFrame {
  const WorkspaceOrderFrame(this.workspaceIds);
  final List<String> workspaceIds;
}

class WorkspaceArchivedFrame extends WorkspaceFollowFrame {
  const WorkspaceArchivedFrame(this.sessionIds);
  final List<String> sessionIds;
}

class WorkspacePinnedFrame extends WorkspaceFollowFrame {
  const WorkspacePinnedFrame(this.sessionIds);
  final List<String> sessionIds;
}

/// Something the client does not model. Kept rather than thrown so an engine
/// upgrade adds a row instead of killing the subscription.
class WorkspaceUnknownFrame extends WorkspaceFollowFrame {
  const WorkspaceUnknownFrame();
}

/// A typed view over the `workspace/follow` logical stream.
///
/// Decoding mirrors [SessionEventStream]: the mux yields raw JSON because it is
/// transport-agnostic, and the protocol's own invariants are checked here rather
/// than by every consumer.
class WorkspaceFollowStream {
  WorkspaceFollowStream._(this._raw, {void Function(Object error)? onError}) {
    _sub = _raw.items.listen(
      _accept,
      onError: (Object error) {
        if (onError != null) {
          onError(error);
        } else {
          _fail('workspace/follow stream error: $error');
        }
      },
    );
  }

  /// Open over a mux logical stream.
  factory WorkspaceFollowStream.fromWire(
    MuxStream raw, {
    void Function(Object error)? onError,
  }) =>
      WorkspaceFollowStream._(raw, onError: onError);

  /// Open over an already-decoded frame stream (tests).
  factory WorkspaceFollowStream.fromSource(
    Stream<Object?> source, {
    void Function(Object error)? onError,
  }) =>
      WorkspaceFollowStream._(MuxStream.forTesting(source), onError: onError);

  final MuxStream _raw;
  late final StreamSubscription<Object?> _sub;
  final _frames = StreamController<WorkspaceFollowFrame>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  /// The opening snapshot, once it has arrived.
  WorkspaceBaseline? get baseline => _baseline;
  WorkspaceBaseline? _baseline;
  bool _sawBaseline = false;
  bool _failed = false;

  Stream<WorkspaceFollowFrame> get frames => _frames.stream;
  Stream<Object> get errors => _errors.stream;

  void _accept(Object? value) {
    final json = asObject(value);
    if (json == null) {
      _fail('workspace/follow sent a non-object frame');
      return;
    }
    final frame = decodeWorkspaceFrame(json);
    if (frame is WorkspaceBaselineFrame) {
      if (_sawBaseline) {
        // Same rule as session/follow: one subscription is one baseline. A
        // second means the producer and the consumer disagree about state.
        _fail('workspace/follow sent a second baseline');
        return;
      }
      _sawBaseline = true;
      _baseline = frame.value;
    } else if (!_sawBaseline) {
      // An increment before the baseline would apply to a projection that does
      // not exist yet; dropping it silently is how a registry ends up wrong.
      _fail('workspace/follow sent an increment before its baseline');
      return;
    }
    if (!_frames.isClosed) _frames.add(frame);
  }

  void _fail(String message) {
    if (_failed) return;
    _failed = true;
    if (!_errors.isClosed) _errors.add(StateError(message));
  }

  Future<void> dispose() async {
    await _sub.cancel();
    _raw.cancel();
    await _frames.close();
    await _errors.close();
  }
}

/// Decode one wire frame. Exposed so the projection can be tested without a
/// socket.
WorkspaceFollowFrame decodeWorkspaceFrame(Map<String, dynamic> json) {
  switch (json['type']) {
    case 'baseline':
      final value = asObject(json['value']) ?? const <String, dynamic>{};
      return WorkspaceBaselineFrame(WorkspaceBaseline.fromJson(value));
    case 'upsert':
      final workspace = asObject(json['workspace']);
      if (workspace == null) {
        return const WorkspaceUnknownFrame();
      }
      return WorkspaceUpsertFrame(WorkspaceView.fromJson(workspace));
    case 'remove':
      final id = json['workspaceId'];
      return id is String
          ? WorkspaceRemoveFrame(id)
          : const WorkspaceUnknownFrame();
    case 'order':
      return WorkspaceOrderFrame(_strings(json['workspaceIds']));
    case 'archived':
      return WorkspaceArchivedFrame(_strings(json['archivedSessionIds']));
    case 'pinned':
      return WorkspacePinnedFrame(_strings(json['pinnedSessionIds']));
    default:
      return const WorkspaceUnknownFrame();
  }
}

/// Fold a frame stream into the current projection.
///
/// Pure and synchronous so the whole registry — including "what happens when an
/// increment arrives before the baseline" — is testable without a socket.
class WorkspaceRegistryProjection {
  WorkspaceRegistryProjection();

  /// Ordered by the engine's manual order once it has sent one; otherwise by
  /// the baseline's own order, which is registry order.
  final Map<String, WorkspaceView> _byId = {};
  List<String> _order = [];
  List<String> _archived = [];
  List<String> _pinned = [];

  List<WorkspaceView> get items => [
        for (final id in _order)
          if (_byId[id] case final WorkspaceView w) w,
      ];

  List<String> get archivedSessionIds => List.unmodifiable(_archived);
  List<String> get pinnedSessionIds => List.unmodifiable(_pinned);

  /// Every session id claimed by at least one workspace.
  Set<String> get claimedSessionIds => {
        for (final w in _byId.values) ...w.sessionIds,
      };

  /// Apply [frame]. Returns whether the projection changed.
  bool apply(WorkspaceFollowFrame frame) {
    switch (frame) {
      case WorkspaceBaselineFrame(:final value):
        return _applyBaseline(value);
      case WorkspaceUpsertFrame(:final workspace):
        return _applyUpsert(workspace);
      case WorkspaceRemoveFrame(:final workspaceId):
        final existed = _byId.remove(workspaceId) != null;
        if (_order.remove(workspaceId)) {
          return true;
        }
        return existed;
      case WorkspaceOrderFrame(:final workspaceIds):
        return _applyOrder(workspaceIds);
      case WorkspaceArchivedFrame(:final sessionIds):
        return _replace(_archived, sessionIds);
      case WorkspacePinnedFrame(:final sessionIds):
        return _replace(_pinned, sessionIds);
      case WorkspaceUnknownFrame():
        return false;
    }
  }

  /// Install a complete archived set — from a unary mutation's response, not
  /// from the stream.
  ///
  /// The four write verbs answer with the whole resulting set rather than a
  /// delta, so a caller applies it verbatim. Keeping that a projection method
  /// (rather than letting callers reach into the lists) means the "replace"
  /// semantic is shared with the stream path and cannot drift into a merge.
  ///
  /// Returns whether anything actually changed, so a caller that owns
  /// notification can skip a pointless rebuild. An identical answer means the
  /// `follow` stream has nothing new to say either.
  bool setArchived(List<String> sessionIds) => _replace(_archived, sessionIds);

  /// Install a complete pin set — same rationale and contract as
  /// [setArchived].
  bool setPinned(List<String> sessionIds) => _replace(_pinned, sessionIds);

  bool _applyBaseline(WorkspaceBaseline value) {
    _byId.clear();
    for (final w in value.items) {
      _byId[w.workspaceId] = w;
    }
    _order = [for (final w in value.items) w.workspaceId];
    _archived = [...value.archivedSessionIds];
    _pinned = [...value.pinnedSessionIds];
    return true;
  }

  bool _applyUpsert(WorkspaceView workspace) {
    // A new workspace joins the end of the current order; the engine sends an
    // explicit `order` frame if the user dragged it, so guessing a position
    // here would be worse than appending.
    _byId[workspace.workspaceId] = workspace;
    if (!_order.contains(workspace.workspaceId)) {
      _order = [..._order, workspace.workspaceId];
    }
    return true;
  }

  bool _applyOrder(List<String> workspaceIds) {
    // The engine sends the complete list. Ids we have never seen are kept in
    // the order payload's place so a later `upsert` lands in the right spot
    // instead of at the end.
    _order = [...workspaceIds];
    return true;
  }

  bool _replace(List<String> target, List<String> next) {
    if (target.length == next.length) {
      var same = true;
      for (var i = 0; i < target.length; i++) {
        if (target[i] != next[i]) {
          same = false;
          break;
        }
      }
      if (same) return false;
    }
    target
      ..clear()
      ..addAll(next);
    return true;
  }
}

String _str(Object? v) => v is String ? v : '';

List<String> _strings(Object? v) => [
      for (final x in asList(v) ?? const <Object?>[])
        if (x is String) x,
    ];

/// One still-running thing inside a session, as the archive admission
/// waterfall reports it (`workspace/workspace/src/types.ts:51-55`).
///
/// `label` is optional on the wire: a family may carry per-item identity
/// without a display label, and the archive dialog still has to say something
/// a human can read — so the label falls back to the id rather than rendering
/// an empty bullet.
class SessionActivityItem {
  const SessionActivityItem({required this.id, this.label});

  factory SessionActivityItem.fromJson(Map<String, dynamic> j) =>
      SessionActivityItem(
        id: _str(j['id']),
        label: j['label'] is String ? j['label'] as String : null,
      );

  final String id;

  /// Display label as the wire sent it, or null when the family reported
  /// identity without one.
  final String? label;

  /// What the dialog prints. Never null: an unlabeled item speaks for itself
  /// by id, because "归档会停掉：job-a" beats an empty line.
  String get display {
    final l = label;
    return (l == null || l.isEmpty) ? id : l;
  }

  @override
  String toString() => display;
}

/// The `activity` list on a `workspace/session-active` rejection, grouped by
/// family so the dialog can print one line per family.
///
/// **Unknown families are kept, not dropped.** The wire kind is
/// `keyof SessionActivityKindMap`, and each family is a key a *provider* merges
/// into that map — so an engine built with a plugin this App never compiled can
/// send a kind we have no translation for. dsh's own dialog handles this by
/// falling through to a generic line (`ArchiveSession.tsx` `activityLine`:
/// `default: return t('archive.confirm.other.…', { kind, n })`); dropping the
/// family instead would silently under-report what archiving is about to stop,
/// which is the one thing that dialog must never do.
class SessionActivityList {
  const SessionActivityList({
    required this.byKind,
    required this.unknownKinds,
  });

  /// Decoded from the error's `details.activity`; an absent or malformed list
  /// is an empty list, not a crash — the caller still reports "the session is
  /// active", just without the itemized list.
  factory SessionActivityList.decode(Object? details) {
    final raw = details is Map<String, dynamic> ? details['activity'] : null;
    final entries = asList(raw) ?? const <Object?>[];
    final byKind = <String, List<SessionActivityItem>>{};
    final unknown = <String>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) continue;
      final kind = _str(entry['kind']);
      if (kind.isEmpty) continue;
      final items = [
        for (final item in asList(entry['items']) ?? const <Object?>[])
          if (item is Map<String, dynamic>) SessionActivityItem.fromJson(item),
      ];
      byKind.putIfAbsent(kind, () => <SessionActivityItem>[]).addAll(items);
      // A family with no per-item identity (the engine's own `turn` does this)
      // still counts as "something is running" — record the kind with an empty
      // list so the dialog can say "a turn is running" rather than nothing.
      if (items.isEmpty) byKind.putIfAbsent(kind, () => <SessionActivityItem>[]);
      if (!_knownKinds.contains(kind)) unknown.add(kind);
    }
    return SessionActivityList(byKind: byKind, unknownKinds: unknown);
  }

  /// The four families the engine ships with
  /// (`workspace/workspace/src/types.ts`: `turn` in the agent registry,
  /// `job` in the jobs view, `subagent` in the subagent runtime, `schedule` in
  /// the schedule plugin).
  static const Set<String> _knownKinds = {
    'turn',
    'job',
    'subagent',
    'schedule',
  };

  final Map<String, List<SessionActivityItem>> byKind;

  /// Kinds present on the wire that this App has no dedicated wording for.
  final List<String> unknownKinds;

  /// Whether anything at all is reported as running. A rejected archive with an
  /// empty list would be a contradiction, but the decoder must not throw on it
  /// — the dialog falls back to a generic "this session is busy".
  bool get isEmpty => byKind.isEmpty;

  /// Total running items across every family. Families without per-item
  /// identity count as one, so a running turn is never reported as "0".
  int get totalItems {
    var n = 0;
    for (final items in byKind.values) {
      n += items.isEmpty ? 1 : items.length;
    }
    return n;
  }
}
