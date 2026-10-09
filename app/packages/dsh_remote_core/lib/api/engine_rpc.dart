/// Unary engine RPC over the shared `/api` channel (M2 / plan T2.1).
///
/// dsh 0.1.7-rc.2 does **not** expose one REST path per engine method. `/api`
/// is a single *reserved shared channel*: `assertChannel()` in
/// `packages/client/connection/src/rpc-host.ts:313` explicitly rejects any
/// attempt to register a separate RPC channel on it, and
/// `client/connection/src/index.ts:141-155` mounts one `prefix` route for
/// `API_PATH = '/api'` that hands every request to the shared fetch handler.
///
/// So each call is a JSON-RPC envelope POSTed to `/api`, and the *method*
/// string carries the endpoint:
///
/// ```json
/// → {"type":"client-request","rpcId":"r1","method":"session.list","payload":{"args":{}}}
/// ← {"type":"server-response","rpcId":"r1","result":{"ok":true,"value":…}}
/// ← {"type":"server-response","rpcId":"r1","result":{"ok":false,
///         "error":{"code":"…","message":"…","details":{…}}}}
/// ```
///
/// Envelope shapes hand-copied from
/// `packages/client/connection/src/rpc-schema.ts` (dsh-root 0.1.7-rc.2):
/// - `clientRequestSchema` (line 35): `type` literal `client-request`,
///   `rpcId` string, `method` string, `payload` unknown
/// - `serverResponseSchema` (line 43): `type` literal `server-response`,
///   `rpcId` string, `result` = union of
///   `{ok:true, value}` and `{ok:false, error}`
/// - `rpcErrorSchema` (line 10): `code: string`, `message: string`, and
///   `details: Record<string, unknown>`
///
/// The `payload.args` wrapper is added one layer up, by the API client:
/// `packages/api/gateway/src/client/index.ts:445` calls
/// `connection.rpc.call('/api', endpoint, { args: prepared.args }, signal)`.
library;
import 'dart:async';

import 'error_code.dart';
import '../net/relay_client.dart';

/// A typed engine failure as it arrives on the wire.
///
/// Discrimination is always by [code] — never by exception class — matching
/// `RemoteError` in `packages/typert/protocol/src/remote-error.ts:10`.
class EngineRemoteError implements Exception {
  const EngineRemoteError({
    required this.code,
    required this.message,
    this.details = const <String, dynamic>{},
  });

  factory EngineRemoteError.fromWire(Map<String, dynamic> wire) {
    final details = wire['details'];
    return EngineRemoteError(
      code: wire['code'] as String? ?? 'gateway/internal',
      message: wire['message'] as String? ?? '',
      details: details is Map<String, dynamic> ? details : const <String, dynamic>{},
    );
  }

  final String code;
  final String message;
  final Map<String, dynamic> details;

  /// Fold into the app-wide error model (design §7.2).
  ///
  /// The engine is never translated — [code] travels through into
  /// [AppError.rawMessage] and the UI supplies the wording from the `err_*`
  /// resources. What this decides is *which* app code the console renders and
  /// therefore which presentation layer and retry policy apply.
  ///
  /// Only codes with a distinct, user-actionable meaning are listed. **Every
  /// other engine code falls through to [ErrorCode.engineUnknown] with the raw
  /// code preserved** — the App never invents wording for a code it has not
  /// been taught, and an unrecognised code is never swallowed.
  ///
  /// The table is hand-copied from the real `RemoteErrorCode` domain in
  /// `docs/engine-contract-m2.md` §11.2 (dsh-root 0.1.7-rc.2): 3 base gateway
  /// codes, 19 gateway infrastructure codes, 17 session-domain codes and
  /// 8 subagent-domain codes.
  AppError toAppError() {
    final mapped = switch (code) {
      // The target is gone. Usually deleted from the other end — which is a
      // normal outcome of two-ends relay, not a fault.
      'session/not-found' ||
      'workspace/not-found' ||
      'subagent/not-found' ||
      'job/not-found' ||
      'gateway/context-not-found' ||
      'gateway/lookup-not-found' =>
        ErrorCode.engineSessionGone,

      // Two-ends relay: the web UI currently owns the writer lock.
      'session/writer-held' => ErrorCode.sessionWriterHeld,

      'session/agent-busy' => ErrorCode.sessionAgentBusy,

      // The child is one-shot, its parent is offline, or it is not ours.
      'subagent/not-resumable' ||
      'subagent/parent-unavailable' ||
      'subagent/unauthorized' ||
      'subagent/delivery-unavailable' =>
        ErrorCode.subagentReadOnly,

      'session/model-unavailable' ||
      'session/provider-models-unavailable' ||
      'session/provider-credentials-unavailable' ||
      'llm/model-discovery-rejected' =>
        ErrorCode.modelUnavailable,

      // Version skew: this engine build does not mount the method at all.
      'gateway/method-unavailable' ||
      'gateway/signature-invalid' ||
      'gateway/definition-unavailable' ||
      'gateway/invocation-unavailable' =>
        ErrorCode.engineUnsupported,

      // A dependency is down but the engine is up; usually self-recovers.
      'gateway/service-unavailable' ||
      'gateway/context-unavailable' ||
      'gateway/lookup-unavailable' ||
      'gateway/provider-mismatch' ||
      'client/timeout' ||
      // D-044: the two codes this layer's own status switch emits for
      // 503/504 (`engine_rpc.dart:235-236`). Registering them in the
      // producer while leaving them out of this consumer is what made a busy
      // engine read as "未知错误" with `engine.timeout` printed underneath.
      'engine.unavailable' =>
        ErrorCode.engineUnavailable,

      // D-039/D-044: 504 is the relay's own 30s ceiling on a slow-but-healthy
      // engine. It means "wait and retry", not "something unknown".
      'engine.timeout' => ErrorCode.engineTimeout,

      // Not a fault — the UI suppresses this rather than rendering noise.
      'gateway/cancelled' => ErrorCode.engineCancelled,

      // An oversized uplink is the App's own doing, same as the relay-side
      // payload cap, so it shares that wording and manual retry.
      'gateway/uplink-overflow' => ErrorCode.payloadTooLarge,

      _ => ErrorCode.engineUnknown,
    };
    return AppError(
      mapped,
      rawMessage: code,
      detail: message.isEmpty ? null : message,
    );
  }

  @override
  String toString() => 'EngineRemoteError($code: $message)';
}

/// Result of one unary engine call: either a decoded value or a typed failure.
///
/// Mirrors `ConnectionRpcResult<T>` (`packages/client/connection/src/rpc.ts:18`).
class EngineRpcResult {
  const EngineRpcResult.ok(this.value) : error = null;
  const EngineRpcResult.err(this.error) : value = null;

  final Object? value;
  final EngineRemoteError? error;

  bool get isOk => error == null;

  /// The decoded value cast to [T], or null when the call failed.
  T? okValue<T>() => isOk ? value as T? : null;
}

/// Unary caller for the engine control plane.
///
/// Reuses [RelayClient] rather than owning a socket: the relay already injects
/// the Bearer and `Accept-Language` and already maps 401/429/transport faults
/// into [AppError] (design §7.3), so this class only owns the RPC envelope.
class EngineRpc {
  EngineRpc({required this.relay, this.callTimeout = defaultCallTimeout});

  final RelayClient relay;

  /// Ceiling on one unary call, tuned to sit just above the relay's proxy
  /// timeout so a healthy-but-slow tunnel still gets the relay's own 504
  /// (which maps through the HTTP table), while a true stall surfaces here.
  ///
  /// D-045: `session/list` on a real host started answering in ~85 s (1583
  /// sessions, 78% of the 1.8 MB body being `projections`), against a relay
  /// ceiling of 30 s — so every list request was a guaranteed 504 and the
  /// App's "browse and resume a session" path was dead. The relay ceiling is
  /// now 180 s; this one follows it to 195 s, 15 s of slack.
  ///
  /// **This number and `WSS_PROXY_TIMEOUT_MS` in `server/src/index.ts` are one
  /// decision living in two languages.** Move one without the other and the
  /// smaller one silently wins. `engine_rpc_timeout_test.dart` restates the
  /// relay's value on purpose so the drift is at least visible here.
  /// Injectable for tests; production always uses [defaultCallTimeout].
  static const Duration defaultCallTimeout = Duration(seconds: 195);

  final Duration callTimeout;

  int _seq = 0;

  /// Correlation id for the next call. Any non-empty string is valid
  /// (`rpcIdSchema` is a bare `z.string()`); the counter keeps traces readable.
  String _nextRpcId() => 'app-${_seq++}';

  /// Call [endpoint] (e.g. `session/list`, `session/modelCatalog`) with
  /// positional-free [args], returning the decoded `value` or a typed failure.
  ///
  /// The request goes to `/api/<endpoint>`, **not** to `/api`. The channel is a
  /// mount prefix, and the client appends the endpoint to it:
  /// `` `${channel}/${endpoint}`.slice(1) ``
  /// (`client/connection/src/client/rpc.ts:48`) — so channel `/api` plus
  /// endpoint `session/prompt` becomes `/api/session/prompt`. Posting to the
  /// bare `/api` 404s against the real host, and the relay's `/api/*` wildcard
  /// does not match a path with nothing after the slash.
  ///
  /// Transport-level faults (401/429/TLS/timeout) surface as [AppError] from
  /// [RelayClient]; protocol-level failures surface as [EngineRpcResult.err].
  Future<EngineRpcResult> call(String endpoint, {Map<String, dynamic>? args}) async {
    // D-026: client-side ceiling. Real-device E2E measured unary RPC latency
    // through the tunnel rising from ~0.5 s (engine-direct) to 20–30 s while a
    // `/api/remote.mux` stream is bridged on the same pairing — the relay's own
    // 504 ceiling is 30 s (server `WSS_PROXY_TIMEOUT_MS`), so anything above
    // that is a genuine stall. Without this the UI spun forever with no error
    // affordance; now a stall becomes a typed `client/timeout` failure the UI
    // renders as an inline card with a retry.
    (int, dynamic) response;
    try {
      response = await relay
          .postJson('/api/$endpoint', {
            'type': 'client-request',
            'rpcId': _nextRpcId(),
            'method': endpoint,
            'payload': {'args': args ?? const <String, dynamic>{}},
          })
          .timeout(callTimeout);
    } on TimeoutException {
      return EngineRpcResult.err(EngineRemoteError(
        code: 'client/timeout',
        message: 'engine RPC $endpoint exceeded ${callTimeout.inSeconds}s',
      ));    }
    final (status, body) = response;

    if (status != 200) {
      // Transport-level, not an engine business code. 401/403 are the relay
      // gate (already handled upstream by SessionClock's three causes), so
      // only the engine's own failures land in the table below.
      return EngineRpcResult.err(EngineRemoteError(
        code: switch (status) {
          401 || 403 => 'auth/refused',
          404 => 'gateway/lookup-not-found',
          413 => 'gateway/uplink-overflow',
          415 => 'gateway/input-invalid',
          // D-039: 503/504 carry distinct meaning (unavailable vs. our own
          // 30s ceiling), so they keep their own codes instead of collapsing
          // into gateway/internal and surfacing as "unknown error".
          503 => 'engine.unavailable',
          504 => 'engine.timeout',
          >= 500 => 'gateway/internal',
          _ => 'gateway/http-$status',
        },
        message: 'engine RPC $endpoint returned HTTP $status',
      ));
    }
    if (body is! Map<String, dynamic>) {
      return const EngineRpcResult.err(EngineRemoteError(
        code: 'gateway/result-invalid',
        message: 'engine RPC response envelope is not an object',
      ));
    }
    if (body['type'] != 'server-response') {
      return EngineRpcResult.err(EngineRemoteError(
        code: 'gateway/protocol',
        message: 'engine RPC response type is ${body['type']}',
      ));
    }
    final result = body['result'];
    if (result is! Map<String, dynamic>) {
      return const EngineRpcResult.err(EngineRemoteError(
        code: 'gateway/result-invalid',
        message: 'engine RPC result envelope is not an object',
      ));
    }
    if (result['ok'] == true) return EngineRpcResult.ok(result['value']);
    final error = result['error'];
    return EngineRpcResult.err(error is Map<String, dynamic>
        ? EngineRemoteError.fromWire(error)
        : const EngineRemoteError(
            code: 'gateway/internal',
            message: 'engine RPC failure carried no error object',
          ));
  }

  /// Call [endpoint] and throw [EngineRemoteError] on failure.
  ///
  /// Use where a failure is genuinely exceptional (fire-and-forget commands);
  /// use [call] where the UI must render the error inline.
  Future<Object?> callOrThrow(String endpoint, {Map<String, dynamic>? args}) async {
    final result = await call(endpoint, args: args);
    final error = result.error;
    if (error != null) throw error;
    return result.value;
  }
}

/// Canonical session endpoints.
///
/// **Separator is a slash, not a dot** — `endpointOf()` returns
/// `` `${namespace}/${method}` `` (`api/gateway/src/index.ts:1370-1372`), so
/// the wire method string is `session/prompt`, never `session.prompt`. The
/// endpoint must be exactly two segments, each matching `^[A-Za-z0-9_$.-]+$`
/// (`api/gateway/src/index.ts:1114-1123`).
///
/// Names below are hand-copied from the `@Remote(...)` decorators in
/// `packages/api/session-controller/src/index.ts`; the namespace is the value
/// bound by `super(ctx, 'sessionController', { namespace: 'session' })` at
/// line 136.
///
/// Not present in 0.1.7-rc.2: `session.export`. The dot-separated
/// `/api/session.list` and `/api/sessions.list` forms seen in older notes do
/// not exist in this version either — `sessions` is a *client-side* service
/// name (`client/sessions/service.ts`), not a Remote namespace.
class SessionEndpoints {
  SessionEndpoints._();

  static const String list = 'session/list';
  static const String search = 'session/search';
  static const String create = 'session/create';
  static const String page = 'session/page';
  /// Server stream — multiplexed onto `/api/remote.mux`, not a unary call.
  static const String follow = 'session/follow';

  /// Server stream — multiplexed onto `/api/remote.mux`.
  static const String control = 'session/control';

  static const String projections = 'session/projections';
  static const String prompt = 'session/prompt';
  static const String cancel = 'session/cancel';
  static const String updateQueue = 'session/updateQueue';
  static const String fork = 'session/fork';
  static const String rename = 'session/rename';
  static const String modelCatalog = 'session/modelCatalog';
  static const String selectModel = 'session/selectModel';
  static const String attachment = 'session/attachment';
  static const String openWorkspacePath = 'session/openWorkspacePath';
  static const String workspacePathApplications = 'session/workspacePathApplications';
}

/// D-073: agent 预设目录——「这个会话由哪种 agent 处理」。dsh web 在新建
/// 会话旁常驻这个选择器，端点实测 `args` 为空对象即可（不带 `_request`
/// 信封，实测多传会被 `gateway/arguments-invalid` 拒掉）。
class AgentPresetsEndpoints {
  AgentPresetsEndpoints._();

  static const String list = 'agentPresets/list';
}

/// D-046: the machine's Workspace registry.
///
/// Namespace confirmed against the engine's own route table
/// (`api/workspace-controller/src/index.ts:68`; the contract's namespace list
/// in `docs/engine-contract-m2.md:25` names it `workspace`). `follow` is a
/// **stream**, not a unary call — the registry changes underneath a long-lived
/// client and dsh's own UI keeps a subscription open rather than re-pulling.
class WorkspaceRegistryEndpoints {
  WorkspaceRegistryEndpoints._();

  /// Server stream — multiplexed onto `/api/remote.mux`.
  static const String follow = 'workspace/follow';

  // D-055: the registry's write side. Wire names come from the engine's own
  // `@Remote(...)` decorators (`api/workspace-controller/src/index.ts:154-192`)
  // and are pinned by its transport spec
  // (`tests/transport.client.spec.ts:346-355`) — so these four strings are a
  // contract, not a naming preference.
  //
  // All four answer with the **complete** resulting set, not a delta, so the
  // caller installs the response as-is instead of guessing what changed.
  //
  // There is deliberately no `archiveSessions` here: bulk-archiving a whole
  // workspace exists on the registry API (`workspace.zh.md:575`) but is NOT a
  // Remote, so there is no endpoint to call.
  //
  // **All four take their fields wrapped in `request`.** The gateway validates
  // against the endpoint's declared parameter descriptor, and these declare a
  // single `request` parameter. A flat `{"sessionId": …}` is refused with
  // `gateway/arguments-invalid: missing "request"; unexpected "sessionId"` —
  // verified live against the engine, which is how D-055's first device test
  // caught it. Same wrapper shape as `session/*`.

  /// Hide one known session from Workspace grouping surfaces.
  static const String archive = 'workspace/archiveSession';

  /// Restore one archived session to grouping surfaces.
  static const String unarchive = 'workspace/unarchiveSession';

  /// Surface one known unarchived session ahead of unpinned ones.
  static const String pin = 'workspace/pinSession';

  /// Remove one session from the pin set.
  static const String unpin = 'workspace/unpinSession';
}

/// The `workspaceFiles` namespace — the Session's own file tree.
///
/// `api/workspace-files/src/index.ts:200`. Every method takes a
/// [WorkspaceFileScope] first, which the Host resolves from the Session header
/// to `{sessionId, workspaceRoot}`; the App only ever sends the session id.
///
/// **Two path vocabularies, one per consumer** (`types.ts:1-15`): `list` speaks
/// *workspace paths* (`""` is the root, children join with `/`), while
/// `read`/`stat` name a file by its **absolute** path. Mixing them is the one
/// way to get a confusing `not-found`.
class WorkspaceFileEndpoints {
  /// Direct children of one directory, stable name order, capped.
  static const String list = 'workspaceFiles/list';

  /// One page of lines (1-based) of a UTF-8 text file.
  static const String read = 'workspaceFiles/read';

  /// Size and freshness of one file, without its content.
  static const String stat = 'workspaceFiles/stat';
}

/// Gateway-internal logical stream carrying Host-wide application events.
///
/// `REMOTE_EVENT_STREAM_ENDPOINT` (`gateway/src/stream-protocol.ts:10`). The
/// approval / question waterfalls the console must answer arrive here as
/// `waterfall` frames, and the answer goes back over unary
/// `REMOTE_EVENT_RESULT_ENDPOINT` (`$events/result`, line 13).
class EventEndpoints {
  EventEndpoints._();

  static const String stream = r'$events';
  static const String result = r'$events/result';
}
