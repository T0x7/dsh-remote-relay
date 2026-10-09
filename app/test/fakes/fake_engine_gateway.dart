import 'dart:async';

import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/workspace_registry.dart';
/// In-memory [EngineGateway] for widget tests (plan T2.3 DoD).
///
/// Drives the console pages without a relay, an engine, or a socket, and
/// records every outbound call so a test can assert the **request shape** —
/// which is where the contract actually lives. It is deliberately strict
/// about the two rules the App keeps getting wrong:
///
/// - an approval answer is the bare wire string, not an envelope;
/// - a question answer is `{answers: [...]}` as the bare value, and a skipped
///   question is expressed by *omission* from `answers`.
class FakeEngineGateway implements EngineGateway {
  FakeEngineGateway({this.sessions = const [], this.catalog});

  /// Seeded session rows shown by the sessions page.
  final List<SessionSummary> sessions;

  /// Seeded model catalog; null makes [modelCatalog] fail like an unconfigured
  /// engine.
  final ModelCatalog? catalog;

  /// Every call the UI made, in order, as `(endpoint, args)`.
  final List<({String call, Object? args})> calls = [];

  /// Answers sent back through `$events/result`, in order.
  final List<Object?> sentAnswers = [];
  final List<Object?> sentRejections = [];
  final List<List<PromptContentPart>> sentPrompts = [];

  /// Fail the next `prompt` with this code (for L2 inline-card tests).
  String? failPromptWith;

  /// Fail `listSessions` with this engine code (for the sessions-page L2 card).
  String? failListSessions;

  /// D-037: transient failures consumed one per call, so a test can say "the
  /// engine is busy for the first two attempts" without a wall clock. An
  /// EMPTY list means the list always succeeds; [sessionListAlwaysFailing]
  /// is how a test says "never recovers".
  List<String> sessionListFailures = const [];

  /// When true every `listSessions` fails, so the retry budget runs out.
  bool sessionListAlwaysFailing = false;

  /// What `listSessions` serves; the fake keeps its own copy so a test can
  /// swap the whole host's size between refreshes.
  List<SessionSummary> sessionListItems = const [];

  /// How many `listSessions` calls the fake has served.
  int sessionListCalls = 0;

  /// When set, a `listSessions` call hangs on this completer instead of
  /// answering — the only reliable way to test a retry timer, because a fake
  /// clock cannot observe a real `Timer` across an async gap.
  Completer<void>? sessionListGate;

  /// The cap the sessions page is expected to build into the tree at once
  /// (D-037: `session/list` cannot page server-side, so the client must).
  static const int sessionListRenderCap = 60;

  final _followController = StreamController<SessionFollowFrame>.broadcast();
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  final _controlController = StreamController<Object?>.broadcast();
  final _jobsController = StreamController<Object?>.broadcast();

  int _requestSeq = 0;


  /// Push a frame onto the fake `session/follow` stream.
  void pushFrame(SessionFollowFrame frame) => _followController.add(frame);

  /// D-058: 推一个流错误，用来和「一帧都不来」区分开。
  void pushFrameError(Object error) => _followController.addError(error);

  /// The projection baseline a real snapshot carries, so widget tests can
  /// exercise the context capsule.
  static const liveProjections = SessionProjectionBaseline(
    asOfSeq: 10,
    values: Projections(
      contextPressure: ContextPressure(
        pressureTokens: 1000,
        projectedTokens: 3800,
        contextWindow: 10000,
      ),
      sessionStats: SessionStatsProjection(
        turns: 4,
        steps: 9,
        llmMs: 8000,
        toolMs: 1500,
        ttftMs: 3000,
        ttftSteps: 9,
        decodeMs: 2000,
        decodeTokens: 24000,
      ),
      tokenUsage: TokenUsageProjection(
        uncachedInputTokens: 1000,
        outputTokens: 2000,
        cacheReadTokens: 3000,
        cacheWriteTokens: 0,
      ),
    ),
  );

  /// Convenience: push a durable event.
  void pushEvent(SessionWireEvent event) => pushFrame(FollowEvent(event));

  /// Raise a waterfall on `$events`, returning its eventId.
  String raiseWaterfall(String event, Map<String, dynamic> request) {
    final eventId = 'evt-${_requestSeq++}';
    final frame = <String, dynamic>{
      'type': 'waterfall',
      'event': event,
      'eventId': eventId,
      'agentId': 'agent-fake',
      'request': request,
    };
    _eventController.add(frame);
    // D-079: stays pending until answered, so a re-subscribe replays it.
    _pendingWaterfalls.add(frame);
    return eventId;
  }

  /// Deliver the `ready` frame, publishing the clientId answers must echo.
  void raiseReady({String clientId = 'client-fake'}) {

    _eventController.add({
      'type': 'ready',
      'clientId': clientId,
      'host': const {'home': '/fake/home'},
    });
  }

  void raiseControlBaseline(Map<String, dynamic> projections) {
    _controlController.add({'type': 'baseline', 'value': {'projections': projections}});
  }

  void raiseJobRows(List<Map<String, dynamic>> jobs) {
    _jobsController.add({'type': 'rows', 'jobs': jobs});
  }

  @override
  String newRequestId() => 'fake-req-${_requestSeq++}';

  @override
  Future<EngineRpcResult> listSessions() async {
    calls.add((call: 'listSessions', args: null));
    sessionListCalls++;
    final gate = sessionListGate;
    if (gate != null) await gate.future;
    if (sessionListAlwaysFailing) {
      return const EngineRpcResult.err(
          EngineRemoteError(code: 'gateway/internal', message: 'engine busy'));
    }
    if (sessionListFailures.isNotEmpty) {
      return EngineRpcResult.err(EngineRemoteError(
          code: sessionListFailures.removeAt(0), message: 'engine busy'));
    }
    final failure = failListSessions;
    if (failure != null) {
      return EngineRpcResult.err(EngineRemoteError(code: failure, message: 'nope'));
    }
    return EngineRpcResult.ok({
      'items': sessionListItems.isEmpty ? sessions : sessionListItems,
    });
  }

  @override
  Future<EngineRpcResult> createSession({
    String? cwd,
    String? sessionId,
    String? agentPreset,
  }) async {
    calls.add((call: 'createSession', args: {
      'cwd': cwd,
      'sessionId': sessionId,
      'agentPreset': agentPreset,
    }));
    return EngineRpcResult.ok({'sessionId': sessionId ?? 'session-new'});
  }

  /// D-073: agentPresets/list 的种子行（原样 wire 形态）。
  List<Map<String, Object?>> agentPresets = const [
    {'id': 'standard', 'order': 1, 'isDefault': true},
    {
      'id': 'news-radar',
      'name': '换仓雷达判读官',
      'description': '新闻判读 Agent',
      'order': 100,
    },
    {
      'id': 'image-creator',
      'name': '图片创作官',
      'order': 100,
      'broken': 'invalid config',
    },
  ];

  /// 置非空则 listAgentPresets 以该 code 失败。
  String? agentPresetsError;

  @override
  Future<EngineRpcResult> listAgentPresets() async {
    calls.add((call: 'listAgentPresets', args: null));
    if (agentPresetsError != null) {
      return EngineRpcResult.err(
          EngineRemoteError(code: agentPresetsError!, message: 'presets'));
    }
    return EngineRpcResult.ok({'presets': agentPresets});
  }

  @override
  Future<EngineRpcResult> prompt({
    required String sessionId,
    required List<PromptContentPart> content,
    String? requestId,
    PromptDelivery mode = PromptDelivery.queue,
    String? clientTimeZone,
  }) async {
    calls.add((call: 'prompt', args: {'sessionId': sessionId, 'mode': mode.wire}));
    sentPrompts.add(content);
    final failure = failPromptWith;
    if (failure != null) {
      return EngineRpcResult.err(EngineRemoteError(code: failure, message: 'nope'));
    }
    return EngineRpcResult.ok(null);
  }

  @override
  Future<EngineRpcResult> cancelSession(String sessionId) async {
    calls.add((call: 'cancelSession', args: sessionId));
    return EngineRpcResult.ok({'accepted': true});
  }

  @override
  Future<EngineRpcResult> renameSession(String sessionId, String title) async {
    calls.add((call: 'renameSession', args: {'sessionId': sessionId, 'title': title}));
    return EngineRpcResult.ok({'title': title, 'seq': 1});
  }

  @override
  Future<EngineRpcResult> forkSession(String sessionId, {int? atSeq}) async {
    calls.add((call: 'forkSession', args: sessionId));
    return EngineRpcResult.ok({'sessionId': '$sessionId-fork'});
  }

  @override
  Future<EngineRpcResult> projections(String sessionId) async {
    calls.add((call: 'projections', args: sessionId));
    return EngineRpcResult.ok(SessionProjectionBaseline(
      asOfSeq: 10,
      values: Projections(
        contextPressure: const ContextPressure(
          pressureTokens: 1000,
          projectedTokens: 3800,
          contextWindow: 10000,
        ),
        sessionStats: const SessionStatsProjection(
          turns: 4,
          steps: 9,
          llmMs: 8000,
          toolMs: 1500,
          ttftMs: 3000,
          ttftSteps: 9,
          decodeMs: 2000,
          decodeTokens: 24000,
        ),
        modelSelection: const ModelSelectionProjection(
          lastUsed: ModelSelection(provider: 'p', model: 'deepseek-chat'),
        ),
      ),
    ));
  }

  /// D-042: paging answers, in order, one per `page` call. Empty list (the
  /// default) answers `hasMore: false` with no records — the "there is no
  /// earlier history" case.
  final List<({List<FollowEvent> records, bool hasMore})> pageResults = [];

  /// D-042: when set, `page` fails with this engine code instead.
  String? pageFailure;

  @override
  Future<EngineRpcResult> page({
    required SessionAddress address,
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
  }) async {
    calls.add((call: 'page', args: throughSeq));
    final failure = pageFailure;
    if (failure != null) {
      return EngineRpcResult.err(
        EngineRemoteError(code: failure, message: 'nope'),
      );
    }
    if (pageResults.isEmpty) {
      return EngineRpcResult.ok({'records': <Object?>[], 'hasMore': false});
    }
    final next = pageResults.removeAt(0);
    return EngineRpcResult.ok({
      'records': [for (final r in next.records) r],
      'hasMore': next.hasMore,
    });
  }

  @override
  SessionEventStream follow({
    required SessionAddress address,
    bool withAssistantStream = true,
    int? maxMessages,
  }) {
    calls.add((call: 'follow', args: address));
    return SessionEventStream.fromSource(_followController.stream);
  }


  @override
  MuxStream control() => MuxStream.forTesting(_controlController.stream);

  // ------------------------------------------------- D-046 workspace registry

  /// Frames the fake's `workspace/follow` stream will hand out, in order. The
  /// default answers with a two-workspace baseline so a page that forgets to
  /// seed still renders something real rather than an empty shell.
  final List<Object?> workspaceFrames = [
    {
      'type': 'baseline',
      'value': {
        'items': [
          {
            'workspaceId': 'w-jobs',
            'path': '/tmp/jobs',
            'title': '定时任务',
            'sessionIds': ['job-1', 'job-2'],
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': '2026-10-02T00:00:00Z',
          },
          {
            'workspaceId': 'w-workspace',
            'path': '/tmp/workspace',
            'title': 'workspace',
            'sessionIds': ['chat-1'],
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': '2026-10-02T00:00:00Z',
          },
        ],
        'archivedSessionIds': <String>[],
        'pinnedSessionIds': <String>[],
      },
    },
  ];

  /// Replace what the next `followWorkspaces` call will emit.
  void seedWorkspaces(List<Object?> frames) =>
      workspaceFrames
        ..clear()
        ..addAll(frames);

  @override
  WorkspaceFollowStream followWorkspaces() {
    calls.add((call: 'workspace/follow', args: null));
    return WorkspaceFollowStream.fromSource(
      Stream<Object?>.fromIterable(workspaceFrames),
    );
  }

  // --------------------------------------------- workspace registry writes
  //
  // D-055. Every one of these records the exact request object it received, so
  // a test can assert what crossed the wire — the engine's own transport spec
  // pins those shapes (`api/workspace-controller/tests/transport.client.spec.ts`),
  // and a silently-wrong `args` is invisible otherwise.

  /// What the next archive/unarchive answers with: the **complete** resulting
  /// archive set, which is what the engine sends (never a delta).
  Map<String, dynamic>? workspaceArchiveValue;

  /// Rejection for the next archive call — the `workspace/session-active`
  /// path, whose `details.activity` drives the confirm dialog.
  Map<String, dynamic>? workspaceArchiveRejection;

  /// Runs before each archive answers, so a test can change what the *second*
  /// call says. Without this, "the first call is refused, the forced one
  /// succeeds" is untestable — which is the only sequence that actually
  /// happens in production.
  void Function(Map<String, dynamic> args)? onBeforeArchiveCall;

  /// What the next pin/unpin answers with: the complete pin set.
  Map<String, dynamic>? workspacePinValue;

  /// The archive set the fake last installed, so a test can prove the caller
  /// took the engine's answer wholesale instead of patching its own guess.
  List<String> archivedAfterUnarchive = const [];

  @override
  Future<EngineRpcResult> archiveSession(
    String sessionId, {
    bool stopActivity = false,
  }) async {
    // Mirrors EngineClient exactly, wrapper included: `workspace/*` declares a
    // single `request` parameter, so a flat sessionId is refused by the gateway
    // with `gateway/arguments-invalid`. A fake that skipped the wrapper would
    // let this regress silently — it did once, and only the device found it.
    final args = <String, dynamic>{
      'request': {
        'sessionId': sessionId,
        // The key is omitted unless the flag is set, so a test asserting `args`
        // sees the same shape the real client sends.
        if (stopActivity) 'stopActivity': true,
      },
    };
    calls.add((call: 'workspace/archiveSession', args: args));
    onBeforeArchiveCall?.call(args);
    final rejection = workspaceArchiveRejection;
    if (rejection != null) {
      return EngineRpcResult.err(EngineRemoteError(
        code: rejection['code']! as String,
        message: rejection['message']! as String,
        details: (rejection['details'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ));
    }
    return EngineRpcResult.ok(
      workspaceArchiveValue ?? {'archivedSessionIds': [sessionId]},
    );
  }

  @override
  Future<EngineRpcResult> unarchiveSession(String sessionId) async {
    calls.add((
      call: 'workspace/unarchiveSession',
      args: {
        'request': {'sessionId': sessionId},
      },
    ));
    final value = workspaceArchiveValue ?? {'archivedSessionIds': <String>[]};
    archivedAfterUnarchive = [
      for (final id in (value['archivedSessionIds'] as List? ?? const []))
        if (id is String) id,
    ];
    return EngineRpcResult.ok(value);
  }

  @override
  Future<EngineRpcResult> pinSession(String sessionId) async {
    calls.add((
      call: 'workspace/pinSession',
      args: {
        'request': {'sessionId': sessionId},
      },
    ));
    return EngineRpcResult.ok(
      workspacePinValue ?? {'pinnedSessionIds': [sessionId]},
    );
  }

  @override
  Future<EngineRpcResult> unpinSession(String sessionId) async {
    calls.add((
      call: 'workspace/unpinSession',
      args: {
        'request': {'sessionId': sessionId},
      },
    ));
    return EngineRpcResult.ok(
      workspacePinValue ?? {'pinnedSessionIds': <String>[]},
    );
  }

  // ------------------------------------------------------- workspace files

  /// Listings the tests set up, keyed by workspace path (`''` is the root).
  final Map<String, WorkspaceDirectoryListing> workspaceListings = {};

  /// File pages the tests set up, keyed by absolute path.
  final Map<String, WorkspaceFileText> workspaceFiles = {};

  /// Absolute paths `stat` refuses, so the "listed but unreadable" path is
  /// reachable in a test without a real symlink.
  final Set<String> workspaceUnreadable = {};

  /// The session's workspace root, mirroring what the Host derives from the
  /// session header. `stat`/`read` accept a workspace path and answer with
  /// the absolute one, which is what [workspaceStat] does here.
  String workspaceRoot = '/ws';

  @override
  Future<EngineRpcResult> workspaceList({
    required String sessionId,
    required String path,
  }) async {
    calls.add((call: 'workspaceList', args: path));
    final listing = workspaceListings[path];
    if (listing == null) {
      return const EngineRpcResult.err(EngineRemoteError(
          code: 'workspace-file/not-found', message: 'no such directory'));
    }
    return EngineRpcResult.ok(listing);
  }

  @override
  Future<EngineRpcResult> workspaceRead({
    required String sessionId,
    required String absolutePath,
    int? offset,
    int? limit,
  }) async {
    calls.add((call: 'workspaceRead', args: absolutePath));
    final page = _resolvePage(absolutePath);
    if (page == null) {
      return const EngineRpcResult.err(
          EngineRemoteError(code: 'workspace-file/not-found', message: 'no such file'));
    }
    return EngineRpcResult.ok(page);
  }

  @override
  Future<EngineRpcResult> workspaceStat({
    required String sessionId,
    required String absolutePath,
  }) async {
    calls.add((call: 'workspaceStat', args: absolutePath));
    if (workspaceUnreadable.contains(absolutePath)) {
      return const EngineRpcResult.err(EngineRemoteError(
          code: 'workspace-file/not-text', message: 'unreadable'));
    }
    final page = _resolvePage(absolutePath);
    if (page == null) {
      return const EngineRpcResult.err(EngineRemoteError(
          code: 'workspace-file/not-found', message: 'no such file'));
    }
    return EngineRpcResult.ok(
      WorkspaceFileStat(
          absolutePath: page.absolutePath, version: page.version, bytes: page.bytes),
    );
  }

  /// Accept either vocabulary, exactly like the Host: an absolute path as-is,
  /// or a workspace path resolved against [workspaceRoot].
  WorkspaceFileText? _resolvePage(String path) =>
      workspaceFiles[path] ??
      workspaceFiles['$workspaceRoot/${path.startsWith('/') ? path.substring(1) : path}'];

  @override
  Future<EngineRpcResult> modelCatalog() async {
    calls.add((call: 'modelCatalog', args: null));
    final value = catalog;
    if (value == null) {
      return const EngineRpcResult.err(
        EngineRemoteError(code: 'gateway/method-unavailable', message: 'no catalog'),
      );
    }
    return EngineRpcResult.ok(value);
  }

  @override
  Future<EngineRpcResult> selectModel({
    required String sessionId,
    required String provider,
    required String model,
    String? reasoningEffort,
  }) async {
    calls.add((call: 'selectModel', args: {
      'sessionId': sessionId,
      'provider': provider,
      'model': model,
      'reasoningEffort': reasoningEffort,
    }));
    return EngineRpcResult.ok(ModelSelection(
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
    ));
  }

  @override
  MuxStream openEventStream() {
    // D-079: the real gateway gives every fresh subscriber a `ready` frame
    // **and** replays each still-pending waterfall to it. The fake mirrors
    // that, so a re-subscribe actually recovers approvals instead of hanging
    // until the next scripted `raiseReady`. Tests that need to observe the
    // pre-ready window (D-078 generation gating) turn [autoEventReady] off.
    final pending = List<Map<String, dynamic>>.from(_pendingWaterfalls);
    if (autoEventReady) {
      final generation = 'client-gen-${_eventGeneration++}';
      scheduleMicrotask(() {
        _eventController.add({
          'type': 'ready',
          'clientId': generation,
          'host': const {'home': '/fake/home'},
        });
        for (final frame in pending) {
          _eventController.add(frame);
        }
      });
    }
    return MuxStream.forTesting(_eventController.stream);
  }

  /// When false, a fresh `$events` subscriber gets nothing until the test
  /// raises it — used to pin the generation-gating path.
  bool autoEventReady = true;

  int _eventGeneration = 0;

  /// Waterfalls this host considers still pending; replayed to new subscribers.
  final List<Map<String, dynamic>> _pendingWaterfalls = [];

  @override
  Future<EngineRpcResult> answerEvent({
    required String clientId,
    required String eventId,
    required Object? value,
  }) async {
    calls.add((call: 'answerEvent', args: {'clientId': clientId, 'eventId': eventId}));
    sentAnswers.add(value);
    // D-079: an answered waterfall is no longer pending (no further replay).
    _pendingWaterfalls.removeWhere((f) => f['eventId'] == eventId);
    // D-078 测试缝：按序弹出脚本化结果，空则维持历史 ok 行为。
    if (answerScript.isNotEmpty) return answerScript.removeAt(0);
    return const EngineRpcResult.ok(null);
  }

  /// Scripted [EngineRpcResult]s for [answerEvent], popped in order; an empty
  /// script keeps the historical always-ok behavior.
  final List<EngineRpcResult> answerScript = [];

  @override
  Future<EngineRpcResult> rejectEvent({
    required String clientId,
    required String eventId,
    String name = 'UserQuestionError',
    required String message,
    String code = 'ASK_CANCELLED',
  }) async {
    calls.add((call: 'rejectEvent', args: {
      'clientId': clientId,
      'eventId': eventId,
      'code': code,
    }));
    sentRejections.add({'name': name, 'message': message, 'code': code});
    return EngineRpcResult.ok(null);
  }

  @override
  Future<EngineRpcResult> promptSubagent({
    required String parentSessionId,
    required String childSessionId,
    required List<PromptContentPart> content,
    PromptDelivery delivery = PromptDelivery.queue,
    String? requestId,
  }) async {
    calls.add((call: 'promptSubagent', args: {
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
    }));
    return EngineRpcResult.ok({'messageId': 'm1'});
  }

  @override
  Future<EngineRpcResult> interruptSubagent({
    required String parentSessionId,
    required String childSessionId,
  }) async {
    calls.add((call: 'interruptSubagent', args: childSessionId));
    return EngineRpcResult.ok({'accepted': true});
  }

  @override
  MuxStream listJobs({required String sessionId}) =>
      MuxStream.forTesting(_jobsController.stream);

  @override
  MuxStream followJob({required String jobId, String? sessionId, int? from}) =>
      MuxStream.forTesting(_jobsController.stream);

  final List<Map<String, dynamic>> pluginManagerCalls = [];
  bool failPluginManager = false;

  /// D-086 test seam: runs before every `listBundles`, so a test can let the
  /// first read through and break the re-read that follows a toggle. That is
  /// the shape of "the write said OK but we cannot verify what landed".
  void Function()? onPluginManagerList;

  @override
  Future<EngineRpcResult> pluginManagerListBundles() async {
    pluginManagerCalls.add(const {'call': 'listBundles'});
    onPluginManagerList?.call();
    if (failPluginManager) {
      return const EngineRpcResult.err(
        EngineRemoteError(code: 'gateway/internal', message: 'pm down'),
      );
    }
    return EngineRpcResult.ok(const [
      {
        'name': '@deepseek-ai/dsh-base',
        'version': '0.2.0-rc.2',
        'enabled': true,
        'installed': false,
        'readOnlyReason': 'management-required',
        'rows': [
          {'rowId': 'r1', 'moduleName': '@deepseek-ai/dsh-llm', 'entryId': 'include:llm'},
        ],
      },
      {
        'name': 'dsh-remote-relay-plugin',
        'version': '0.1.1',
        'enabled': true,
        'installed': true,
        'removable': true,
        'rows': [
          {
            'rowId': 'remote-relay',
            'moduleName': 'dsh-remote-relay',
            'entryId': 'include:remote-relay',
          },
        ],
      },
      {
        'name': '@deepseek-ai/dsh-experimental-auto-review',
        'version': '0.2.0-rc.2',
        'enabled': false,
        'installed': false,
        'optional': true,
        'meta': {
          'title': {'en': 'Auto review', 'zh': 'Auto review 自动审查'},
        },
        'rows': [
          {
            'rowId': 'auto-review',
            'moduleName': '@deepseek-ai/dsh-experimental-auto-review',
          },
        ],
      },
    ]);
  }

  @override
  Future<EngineRpcResult> pluginManagerListPlugins() async {
    pluginManagerCalls.add(const {'call': 'listPlugins'});
    if (failPluginManager) {
      return const EngineRpcResult.err(
        EngineRemoteError(code: 'gateway/internal', message: 'pm down'),
      );
    }
    return EngineRpcResult.ok(const [
      {
        'entryId': 'include:tool-plugin-manager',
        'moduleName': '@deepseek-ai/dsh-plugin-manager/tools',
        'enabled': false,
        'patchId': 'tool-plugin-manager',
      },
      {
        'entryId': 'include',
        'moduleName': 'cordis:include',
        'enabled': true,
        'readOnlyReason': 'unaddressable',
      },
    ]);
  }

  @override
  Future<EngineRpcResult> pluginManagerSetPluginEnabled({
    required String id,
    required bool enabled,
  }) async {
    pluginManagerCalls.add({'call': 'setPluginEnabled', 'id': id, 'enabled': enabled});
    if (failPluginManager) {
      return const EngineRpcResult.err(
        EngineRemoteError(code: 'gateway/internal', message: 'pm down'),
      );
    }
    return EngineRpcResult.ok({
      'changed': true,
      'application': 'applied',
      'stage': 'enable',
      'target': id,
      'enabled': enabled,
    });
  }

  @override
  Future<EngineRpcResult> pluginManagerSetBundleEnabled({
    required String name,
    required bool enabled,
  }) async {
    pluginManagerCalls.add({'call': 'setBundleEnabled', 'name': name, 'enabled': enabled});
    return EngineRpcResult.ok({
      'changed': true,
      'application': 'applied',
      'stage': 'enable',
      'target': name,
      'enabled': enabled,
    });
  }

  @override
  Future<EngineRpcResult> pluginInventory() async {
    calls.add((call: 'pluginInventory', args: null));
    if (failInventory) {
      return const EngineRpcResult.err(
        EngineRemoteError(code: 'gateway/method-unavailable', message: 'no inventory'),
      );
    }
    // D-048: the real shape, captured from `pluginInventory/list` on
    // 2026-10-05. The previous `{id, name}` here was the **bug's**
    // assumption written into the double, which is why a wall of `?` could
    // ship with a green test suite.
    return EngineRpcResult.ok(const {
      'entries': [
        {
          'entryId': 'include:relay',
          'moduleName': 'host-app:remote-relay',
          'enabled': true,
          'fiberPhase': 'active',
        },
        {
          'entryId': 'include:plugin-manager',
          'moduleName': '@deepseek-ai/dsh-plugin-manager',
          'enabled': false,
          'fiberPhase': null,
        },
      ],
    });
  }

  /// Fail `pluginInventory` for the host pane's inline-card test.
  bool failInventory = false;

  @override
  Future<EngineRpcResult> killJob({
    required String sessionId,
    required String jobId,
  }) async {
    calls.add((call: 'killJob', args: jobId));
    return EngineRpcResult.ok({'outcome': 'requested'});
  }

  Future<void> dispose() async {
    await _followController.close();
    await _eventController.close();
    await _controlController.close();
    await _jobsController.close();
  }
}
