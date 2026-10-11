/// Typed facade over the dsh engine control plane (plan T2.1c).
///
/// Binds the domain models in `engine_models.dart` to the two transports in
/// `engine_rpc.dart` / `engine_mux.dart`:
///
/// - **unary** endpoints (`session/list`, `session/prompt`, `session/modelCatalog`,
///   `session/selectModel`, `session/projections`, `session/page`, …) via
///   [EngineRpc];
/// - **server streams** (`session/follow`, `session/control`, `job/list`,
///   `$events`) via [EngineMux].
///
/// Failure policy, matching the App's error model (design §7.2):
/// - transport faults (401 / 429 / TLS / timeout) arrive as `AppError` from
///   [RelayClient] and propagate;
/// - engine business failures arrive as [EngineRemoteError] and are **returned**,
///   not thrown, so the UI can render them inline (L2 cards);
/// - only [callOrThrow] throws, for fire-and-forget commands.
///
/// Wire shapes are hand-copied from dsh-root 0.1.7-rc.2; see
/// `docs/engine-contract-m2.md` for per-field citations.
library;

import 'dart:async';

import 'engine_gateway.dart';
import 'engine_models.dart';
import 'engine_mux.dart';
import 'engine_rpc.dart';
import 'workspace_registry.dart';
/// Session + console endpoints the v1 console calls.
class EngineClient implements EngineGateway {
  EngineClient({required this.rpc, required this.mux});

  final EngineRpc rpc;
  final EngineMux mux;

  int _requestSeq = 0;

  /// Client-minted idempotency key for `session/prompt`
  /// (`api/session-controller/src/types.ts:398`).
  ///
  /// D-077: the sequence alone restarts at 0 every app launch, which collided
  /// with ids the engine had already processed — `session/prompt` answered
  /// ok but silently deduped the message (journal never saw it). The boot
  /// timestamp makes ids unique across restarts; the in-process sequence
  /// keeps retries distinct within a boot.
  @override
  String newRequestId() =>
      'app-req-${DateTime.now().microsecondsSinceEpoch}-${_requestSeq++}';

  // ---------------------------------------------------------------- sessions

  /// `session/list` → `{items: SessionSummary[]}`.
  ///
  /// The wrapper key is `_request`, the endpoint's declared (and ignored)
  /// parameter name. Verified live: sending `{}` fails with
  /// `gateway/arguments-invalid` ("missing \"_request\""), while
  /// `{_request: {}}` returns real rows.
  @override
  Future<EngineRpcResult> listSessions() async {
    final result = await rpc.call(
      SessionEndpoints.list,
      args: {'_request': const <String, dynamic>{}},
    );    return _mapValue(result, (value) {
      final items = asObject(value)?['items'];
      return {
        'items': (items is List<Object?>)
            ? items.whereType<Map<String, dynamic>>().map(SessionSummary.fromJson).toList()
            : <SessionSummary>[],
      };
    });
  }

  /// `session/create` → `{sessionId, agentPreset?}`.
  ///
  /// `workspaceId` and `cwd` are mutually exclusive; passing both is a
  /// `gateway/bad-request` (`commands.ts:106-108`), so this surfaces only
  /// [cwd] (or an explicit session id for idempotent re-claim). Prefer
  /// [workspaceId]: the engine resolves it through the registry (unknown id →
  /// `workspace/not-found`) and attaches the session to the workspace group;
  /// a raw [cwd] is used as-is and never enters the registry's grouping.
  @override
  Future<EngineRpcResult> createSession({
    String? cwd,
    String? sessionId,
    String? agentPreset,
    String? workspaceId,
  }) async {
    final result = await rpc.call(SessionEndpoints.create, args: {'request': {
      if (cwd != null) 'cwd': cwd,
      if (sessionId != null) 'sessionId': sessionId,
      if (agentPreset != null) 'agentPreset': agentPreset,
      if (workspaceId != null) 'workspaceId': workspaceId,
    }});
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// D-073: agent 预设目录。端点实测 `args` 为空对象即可（多传 `_request`
  /// 会被拒），返回 `{presets: [...]}` 原样交给调用方解析。
  @override
  Future<EngineRpcResult> listAgentPresets() async {
    final result = await rpc.call(
      AgentPresetsEndpoints.list,
      args: const <String, dynamic>{},
    );
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// `session/prompt` → void-ish value.
  ///
  /// `mode` is required: `queue` to append behind current work, `steer` to
  /// interrupt into the current turn. `requestId` makes a retried send
  /// idempotent rather than duplicating the message.
  @override
  Future<EngineRpcResult> prompt({
    required String sessionId,
    required List<PromptContentPart> content,
    String? requestId,
    PromptDelivery mode = PromptDelivery.queue,
    String? clientTimeZone,
  }) async {
    final result = await rpc.call(SessionEndpoints.prompt, args: {'request': {
      'requestId': requestId ?? newRequestId(),
      'sessionId': sessionId,
      'mode': mode.wire,
      'content': content.map((c) => c.toJson()).toList(growable: false),
      if (clientTimeZone != null) 'clientTimeZone': clientTimeZone,
    }});
    return _mapValue(result, (value) => value);
  }

  /// `session/cancel` → `{accepted: true}`.
  @override
  Future<EngineRpcResult> cancelSession(String sessionId) async {
    final result = await rpc.call(SessionEndpoints.cancel,
        args: {'request': {'sessionId': sessionId}});
    return _mapValue(result, (value) => value);
  }

  /// `session/rename` → `{title, seq}`.
  @override
  Future<EngineRpcResult> renameSession(String sessionId, String title) async {
    final result = await rpc.call(SessionEndpoints.rename,
        args: {'request': {'sessionId': sessionId, 'title': title}});
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// `session/fork` → `{sessionId}`.
  ///
  /// Omitting [atSeq] forks the prefix through the last completed turn.
  @override
  Future<EngineRpcResult> forkSession(String sessionId, {int? atSeq}) async {
    final result = await rpc.call(SessionEndpoints.fork, args: {'request': {
      'sessionId': sessionId,
      if (atSeq != null) 'atSeq': atSeq,
    }});
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// `session/projections` → a baseline, or null when the session is unknown.
  ///
  /// This is how the console reads context pressure, token usage and model
  /// selection: they are projections, never events.
  @override
  Future<EngineRpcResult> projections(String sessionId) async {
    final result = await rpc.call(SessionEndpoints.projections,
        args: {'request': {'sessionId': sessionId}});
    return _mapValue(result, (value) {
      if (value == null) return null;
      return SessionProjectionBaseline.fromJson(asObject(value) ?? const {});
    });
  }

  /// `session/page` — older history before [beforeSeq], bounded by the
  /// snapshot's [throughSeq] cursor.
  @override
  Future<EngineRpcResult> page({
    required SessionAddress address,
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
  }) async {
    final result = await rpc.call(SessionEndpoints.page, args: {'request': {
      'address': address.toJson(),
      'throughSeq': throughSeq,
      if (beforeSeq != null) 'beforeSeq': beforeSeq,
      if (maxMessages != null) 'maxMessages': maxMessages,
    }});
    return _mapValue(result, (value) {
      final map = asObject(value) ?? const <String, dynamic>{};
      return {
        'records': (map['records'] is List<Object?>)
            ? (map['records']! as List<Object?>)
                .whereType<Map<String, dynamic>>()
                .map(FollowEvent.fromJson)
                .toList()
            : <FollowEvent>[],
        'hasMore': map['hasMore'] == true,
      };
    });
  }

  /// How many messages a fresh journal asks for.
  ///
  /// Bounded on purpose: an unbounded follow pulls the **whole** history in
  /// one frame. Measured against a real 17-turn session on 2026-10-02, the
  /// snapshot was **2.2 MB** across 299 records — of which `assistant/message`
  /// was 1.0 MB and `request/header` 0.7 MB. The tunnel caps a request body at
  /// 4 MiB (`client/src/tunnel.ts:679`), so a long session would not just be
  /// slow on a phone, it would be refused. Older history is fetched on demand
  /// through [page].
  static const int defaultMaxMessages = 50;

  /// `session/follow` — the bubble list's event journal.
  ///
  /// [withAssistantStream] must be true for live token streaming: the engine
  /// omits the assistant-stream baseline entirely unless the request carries
  /// the literal `assistantStream: true` (§3.2), and the client treats its
  /// absence as a protocol fault.
  @override
  SessionEventStream follow({
    required SessionAddress address,
    bool withAssistantStream = true,
    int? maxMessages,
  }) {
    final raw = mux.open(SessionEndpoints.follow, args: {
      'request': {
        'address': address.toJson(),
        if (withAssistantStream) 'assistantStream': true,
        'maxMessages': maxMessages ?? defaultMaxMessages,
      },
    });
    return SessionEventStream.fromWire(raw.items, raw);
  }

  /// `session/control` — the Host-wide projection change stream.
  ///
  /// First frame is a `baseline` carrying every session's projections; later
  /// frames are single `projection` deltas. This is how context / usage
  /// capsules stay live without polling.
  @override
  MuxStream control() => mux.open(SessionEndpoints.control);

  // ------------------------------------------------------- workspace files

  /// `workspaceFiles/list` — the direct children of one workspace directory.
  ///
  /// [path] is a **workspace path**: the root is the empty string, children
  /// join with `/`. The Host derives the root from the session's header, so the
  /// App never sends a root of its own — only the id.
  ///
  /// D-040: the root is *spelled* `.` on the wire. The engine's argument
  /// validator rejects `''` as a missing field (`gateway/bad-request`, "path is
  /// required") and `/` as outside-workspace — both verified against a live
  /// engine on 2026-10-04, where `path: '.'` returns the root listing normally.
  /// The listing echoes its own `path` back as `''`, so the round-trip is
  /// unchanged; only the request differs from the prose.
  @override
  Future<EngineRpcResult> workspaceList({
    required String sessionId,
    required String path,
  }) async {
    final result = await rpc.call(
      WorkspaceFileEndpoints.list,
      args: {
        'workspaceFileScopeId': sessionId,
        'path': path.isEmpty ? '.' : path,
      },
    );
    return _mapValue(
      result,
      (value) => WorkspaceDirectoryListing.fromJson(
          asObject(value) ?? const <String, dynamic>{}),
    );
  }

  /// `workspaceFiles/read` — one page of lines of a text file.
  ///
  /// [absolutePath] is an **absolute** path (the other vocabulary in this
  /// namespace), and the range is 1-based like the file itself.
  @override
  Future<EngineRpcResult> workspaceRead({
    required String sessionId,
    required String absolutePath,
    int? offset,
    int? limit,
  }) async {
    final result = await rpc.call(
      WorkspaceFileEndpoints.read,
      args: {
        'workspaceFileScopeId': sessionId,
        'path': absolutePath,
        'range': {
          if (offset != null) 'offset': offset,
          if (limit != null) 'limit': limit,
        },
      },
    );
    return _mapValue(
      result,
      (value) =>
          WorkspaceFileText.fromJson(asObject(value) ?? const <String, dynamic>{}),
    );
  }

  @override
  Future<EngineRpcResult> workspaceStat({
    required String sessionId,
    required String absolutePath,
  }) async {
    final result = await rpc.call(
      WorkspaceFileEndpoints.stat,
      args: {'workspaceFileScopeId': sessionId, 'path': absolutePath},
    );
    return _mapValue(
      result,
      (value) => WorkspaceFileStat.fromJson(
          asObject(value) ?? const <String, dynamic>{}),
    );
  }

  @override
  WorkspaceFollowStream followWorkspaces() => WorkspaceFollowStream.fromWire(
        mux.open(WorkspaceRegistryEndpoints.follow, args: const {}),
      );

  // ------------------------------------------------- workspace registry writes

  /// `workspace/archiveSession` → `{archivedSessionIds}`.
  ///
  /// **This hides a session, it does not delete one.** The archive set is
  /// durable; a session in it is gated out of `agent/pre-step` so it runs no
  /// more model steps, and the conversation itself is still on disk.
  ///
  /// Without [stopActivity] the engine asks the composed providers what is
  /// still running (`workspace/session-activity`, a waterfall) and **refuses**
  /// with `workspace/session-active` — carrying `details.activity` so the caller
  /// can name what is in the way. We deliberately do not pass `stopActivity` on
  /// the user's behalf: archiving from a phone is enough to hide a session, and
  /// silently cancelling a running desktop job is not a decision this screen
  /// gets to make.
  @override
  Future<EngineRpcResult> archiveSession(
    String sessionId, {
    bool stopActivity = false,
  }) async {
    final result = await rpc.call(
      WorkspaceRegistryEndpoints.archive,
      args: {
        'request': {
          'sessionId': sessionId,
          // The engine treats a present-but-false flag as a caller asking for
          // the checked path, so the key is omitted rather than sent as false.
          if (stopActivity) 'stopActivity': true,
        },
      },
    );
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// `workspace/unarchiveSession` → `{archivedSessionIds}`.
  ///
  /// The safe direction: the engine runs no activity check here (removing an id
  /// cannot introduce an unknown one), so this never answers
  /// `workspace/session-active`.
  ///
  /// Note what it does **not** restore: a pin. Archiving drops the session's pin
  /// in the same durable write and unarchiving does not bring it back
  /// (`workspace.zh.md:130`), so the App must not "helpfully" re-pin here.
  @override
  Future<EngineRpcResult> unarchiveSession(String sessionId) async {
    final result = await rpc.call(
      WorkspaceRegistryEndpoints.unarchive,
      args: {
        'request': {'sessionId': sessionId},
      },
    );
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// `workspace/pinSession` → `{pinnedSessionIds}` (most recent first).
  ///
  /// The engine refuses to pin an archived session.
  @override
  Future<EngineRpcResult> pinSession(String sessionId) async {
    final result = await rpc.call(
      WorkspaceRegistryEndpoints.pin,
      args: {
        'request': {'sessionId': sessionId},
      },
    );
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// `workspace/unpinSession` → `{pinnedSessionIds}`.
  ///
  /// Unpinning does not restore the session's earlier position — display order
  /// is browser-local and already includes hidden archives.
  @override
  Future<EngineRpcResult> unpinSession(String sessionId) async {
    final result = await rpc.call(
      WorkspaceRegistryEndpoints.unpin,
      args: {
        'request': {'sessionId': sessionId},
      },
    );
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  // ------------------------------------------------------------------ models

  /// `session/modelCatalog` — the engine's full catalog.
  ///
  /// The App ships no built-in model list; this response is the only source
  /// of models, providers, effort levels and their defaults.
  @override
  Future<EngineRpcResult> modelCatalog() async {
    final result = await rpc.call(SessionEndpoints.modelCatalog);
    return _mapValue(result, (value) =>
        ModelCatalog.fromJson(asObject(value) ?? const <String, dynamic>{}));
  }

  /// `session/selectModel` — returns the **engine-normalized** selection.
  ///
  /// There is no `followDefault` flag (§6.3): to express "follow the
  /// deployment default", send `ModelCatalog.defaultSelection` verbatim with
  /// `reasoningEffort` omitted, or change nothing at all and let
  /// [ModelSelectionProjection.followsDefault] report the state.
  @override
  Future<EngineRpcResult> selectModel({
    required String sessionId,
    required String provider,
    required String model,
    String? reasoningEffort,
  }) async {
    final result = await rpc.call(SessionEndpoints.selectModel, args: {'request': {
      'sessionId': sessionId,
      'provider': provider,
      'model': model,
      if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
    }});
    return _mapValue(result, (value) {
      final selected = asObject(value)?['selected'];
      return selected is Map<String, dynamic>
          ? ModelSelection.fromJson(Map<String, dynamic>.from(selected))
          : null;
    });
  }

  // ------------------------------------------------- approvals and questions

  /// Open the Host event stream that carries approval and question waterfalls.
  ///
  /// The first frame is `ready` and carries the `clientId` that every answer
  /// must echo back through [answerEvent].
  @override
  MuxStream openEventStream() => mux.open(EventEndpoints.stream);

  /// Answer one approval or question waterfall.
  ///
  /// [value] is the **bare** business result: an [ApprovalOutcome] wire string
  /// for approvals, an [AskUserQuestionAnswer] map for questions — no wrapper.
  /// `clientId` comes from the stream's `ready` frame and `eventId` from the
  /// `waterfall` frame.
  ///
  /// D-078: the args are the result object **bare** — `{clientId, eventId,
  /// outcome}` with NO `request` wrapper. The gateway parses this endpoint
  /// before descriptor dispatch (`api/gateway/src/index.ts:430-441`), and the
  /// official client sends `{args: result}` verbatim
  /// (`api/gateway/src/client/remote-events.ts:218-223`). The `request`
  /// wrapper we used to send failed parsing as `gateway/internal`, so every
  /// phone approval silently never reached the engine.
  @override
  Future<EngineRpcResult> answerEvent({
    required String clientId,
    required String eventId,
    required Object? value,
  }) async {
    final result = await rpc.call(EventEndpoints.result, args: {
      'clientId': clientId,
      'eventId': eventId,
      'outcome': {
        'kind': 'result',
        if (value != null) 'value': value,
      },
    });
    return _mapValue(result, (v) => v);
  }

  /// Decline a question by rejecting the waterfall.
  ///
  /// `ASK_CANCELLED` is specifically recognised by plan mode
  /// (`plan/plan-mode/src/index.ts:325-334`), so it is the right code when the
  /// user abandons a plan review.
  @override
  Future<EngineRpcResult> rejectEvent({
    required String clientId,
    required String eventId,
    String name = 'UserQuestionError',
    required String message,
    String code = 'ASK_CANCELLED',
  }) async {
    // D-078: bare result object, no `request` wrapper — see [answerEvent].
    final result = await rpc.call(EventEndpoints.result, args: {
      'clientId': clientId,
      'eventId': eventId,
      'outcome': {
        'kind': 'rejected',
        'error': {'name': name, 'message': message, 'code': code},
      },
    });
    return _mapValue(result, (v) => v);
  }

  // --------------------------------------------------------------- subagents

  /// `subagents/prompt` — send into a `continuable` child only.
  ///
  /// The engine hard-rejects anything else with `subagent/not-resumable`, and
  /// an offline parent with `subagent/parent-unavailable`; the console keeps
  /// the composer hidden in both cases (§9.2).
  @override
  Future<EngineRpcResult> promptSubagent({
    required String parentSessionId,
    required String childSessionId,
    required List<PromptContentPart> content,
    PromptDelivery delivery = PromptDelivery.queue,
    String? requestId,
  }) async {
    final result = await rpc.call('subagents/prompt', args: {'request': {
      'requestId': requestId ?? newRequestId(),
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': 'continuable',
      'delivery': delivery.wire,
      'content': content.map((c) => c.toJson()).toList(growable: false),
    }});
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// `subagents/interruptByParent` → `{accepted: true}`.
  ///
  /// The three arguments are **flat wire fields**, not a nested object.
  @override
  Future<EngineRpcResult> interruptSubagent({
    required String parentSessionId,
    required String childSessionId,
  }) async {
    final result = await rpc.call('subagents/interruptByParent', args: {'request': {
      'childSessionId': childSessionId,
      'parentSessionId': parentSessionId,
      'mode': 'continuable',
    }});
    return _mapValue(result, (value) => value);
  }

  // -------------------------------------------------------------------- jobs

  /// `job/list` — the task list. The stream replaces wholesale; the first
  /// frame is the complete truth.
  @override
  MuxStream listJobs({required String sessionId}) =>
      mux.open('job/list', args: {
        'request': {'sessionId': sessionId},
      });

  /// `job/follow` — one job's output stream.
  @override
  MuxStream followJob({required String jobId, String? sessionId, int? from}) =>
      mux.open('job/follow', args: {
        'request': {
          if (sessionId != null) 'sessionId': sessionId,
          'jobId': jobId,
          if (from != null) 'from': from,
        },
      });

  /// `job/kill` → `{outcome: 'requested' | 'already-finished'}`.
  @override
  Future<EngineRpcResult> killJob({
    required String sessionId,
    required String jobId,
  }) async {
    final result = await rpc.call('job/kill',
        args: {'request': {'sessionId': sessionId, 'jobId': jobId}});
    return _mapValue(result, (value) => value);
  }

  /// `pluginInventory/list` — the mounted plugin roster.
  ///
  /// `super(ctx, 'pluginInventory')` in `host/plugin-inventory/src/index.ts:55`
  /// with `@Remote('list')` at `:70`, so the endpoint takes no arguments.
  @override
  Future<EngineRpcResult> pluginInventory() async {
    final result = await rpc.call('pluginInventory/list');
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// `pluginManager/listPlugins` — toggleable roster. D-081: probed live
  /// 2026-10-08, the endpoint takes **no** arguments (`args: {}`).
  @override
  Future<EngineRpcResult> pluginManagerListPlugins() async {
    final result = await rpc.call('pluginManager/listPlugins');
    return _mapValue(result, (value) => asList(value) ?? const []);
  }

  /// `pluginManager/listBundles` — the package-level roster. D-081: probed
  /// live 2026-10-08, no arguments (same shape as listPlugins).
  @override
  Future<EngineRpcResult> pluginManagerListBundles() async {
    final result = await rpc.call('pluginManager/listBundles');
    return _mapValue(result, (value) => asList(value) ?? const []);
  }

  /// `pluginManager/setPluginEnabled` — D-081: descriptor probed live, the
  /// args are the **bare** `{id, enabled}` (no `request` wrapper).
  @override
  Future<EngineRpcResult> pluginManagerSetPluginEnabled({
    required String id,
    required bool enabled,
  }) async {
    final result = await rpc.call('pluginManager/setPluginEnabled',
        args: {'id': id, 'enabled': enabled});
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  /// `pluginManager/setBundleEnabled` — bare `{name, enabled}`, see above.
  @override
  Future<EngineRpcResult> pluginManagerSetBundleEnabled({
    required String name,
    required bool enabled,
  }) async {
    final result = await rpc.call('pluginManager/setBundleEnabled',
        args: {'name': name, 'enabled': enabled});
    return _mapValue(result, (value) => asObject(value) ?? const <String, dynamic>{});
  }

  // ------------------------------------------------------------------ helper

  /// Preserve the failure branch untouched; map the success value.
  EngineRpcResult _mapValue(
    EngineRpcResult result,
    Object? Function(Object? value) map,
  ) =>
      result.isOk
          ? EngineRpcResult.ok(map(result.value))
          : EngineRpcResult.err(result.error!);
}

/// How a message joins the session's work (`session/prompt` `mode`).
enum PromptDelivery {
  /// Append behind whatever is already running.
  queue('queue'),

  /// Interrupt into the current turn.
  steer('steer');

  const PromptDelivery(this.wire);
  final String wire;
}

/// A typed view over a `session/follow` logical stream.
///
/// [MuxStream] yields raw JSON because it is transport-agnostic; the console
/// wants domain models and the protocol's own hard invariants checked. This
/// wrapper decodes frames and enforces the two rules the wire does not let you
/// ignore:
///
/// - the opening `snapshot` arrives exactly once;
/// - assistant-stream `revision` must advance strictly by one, since a skip
///   means the client missed frames and its transient render is incomplete
///   (`client/transport.ts:206-215`).
class SessionEventStream {
  SessionEventStream._(Stream<SessionFollowFrame> frames, [this._raw]) {
    _sub = frames.listen(
      _accept,
      onError: (Object error) {
        if (!_errors.isClosed) _errors.add(error);
      },
    );
  }

  /// Stream of already-decoded frames, for tests and for callers that hold
  /// domain objects.
  factory SessionEventStream.fromSource(Stream<SessionFollowFrame> source) =>
      SessionEventStream._(source);

  /// Stream of raw wire values from a live mux logical stream: each item is
  /// decoded here, so the JSON boundary stays in exactly one place.
  factory SessionEventStream.fromWire(Stream<Object?> raw, MuxStream mux) =>
      SessionEventStream._(
        raw.map((value) =>
            SessionFollowFrame.fromJson(asObject(value) ?? const {})),
        mux,
      );

  /// The opening snapshot, once it has arrived.
  FollowSnapshot? get snapshot => _snapshot;
  FollowSnapshot? _snapshot;

  void _accept(SessionFollowFrame frame) {
    if (frame is FollowSnapshot) {
      // D-027: a re-baseline is legitimate after a carrier loss — the reconnect
      // re-opens the stream and the host answers with a fresh snapshot. Only a
      // second snapshot on the SAME carrier is a protocol violation, because
      // then the host has nothing new to say and the journal desynchronised.
      if (_sawSnapshot) {
        // No carrier (`_raw == null`) means a caller-supplied Dart stream, which
        // has no reconnect semantics at all — a second snapshot there is the
        // same protocol violation as before.
        if (_raw == null || !_raw.detached) {
          _fail('session/follow sent a second snapshot');
          return;
        }
        // Re-baseline: the previous cursor died with its carrier, so the
        // revision chain restarts from this snapshot's own baseline. Bubbles
        // already rendered stay; the fresh snapshot is the new truth.
        _revision = null;
      }
      _sawSnapshot = true;
      _snapshot = frame;
      // Seed the revision from the baseline. The engine opens a live attempt
      // at `revision` 0 and the first `assistant-stream` frame carries
      // `revision` 1 (observed live: baseline `{"revision":0}`). Without this
      // the very first token of a real reply would look like a frame that
      // arrived before its baseline — and kill the stream mid-answer.
      final baseline = frame.assistantStream;
      if (baseline != null) _revision = baseline.revision;
    }
    if (frame is FollowAssistantStream) {
      if (_revision == null) {
        _fail('assistant-stream frame arrived before its baseline');
        return;
      }
      if (frame.revision != _revision! + 1) {
        _fail('assistant stream skipped revision ${frame.revision}');
        return;
      }
      _revision = frame.revision;
    }
    if (!_frames.isClosed) _frames.add(frame);
  }

  /// Ask the Host to stop sending, keeping the downlink open for any final
  /// frames.
  void end() => _raw?.end();

  /// D-027: whether the journal is waiting for its carrier to come back. The
  /// console reads this to show a reconnecting state instead of a conversation
  /// that has silently stopped updating.
  bool get detached => _raw?.detached ?? false;

  /// Tear the stream down in both directions.
  void cancel() => _raw?.cancel();

  void _fail(String message) {
    if (!_errors.isClosed) {
      _errors.add(const EngineRemoteError(
        code: 'gateway/protocol',
        message: 'session stream violated the follow contract',
      ));
    }
    // A desynchronised journal cannot be repaired by re-reading: stop it and
    // let the caller re-open from a known cursor.
    _raw?.cancel();
  }

  final MuxStream? _raw;
  StreamSubscription<SessionFollowFrame>? _sub;
  bool _sawSnapshot = false;
  int? _revision;

  final _frames = StreamController<SessionFollowFrame>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  /// Decoded frames in arrival order: one snapshot, then events and
  /// assistant-stream frames.
  Stream<SessionFollowFrame> get frames => _frames.stream;

  /// Protocol violations detected on this stream.
  Stream<Object> get errors => _errors.stream;

  Future<void> dispose() async {
    await _sub?.cancel();
    await _frames.close();
    await _errors.close();
  }
}
