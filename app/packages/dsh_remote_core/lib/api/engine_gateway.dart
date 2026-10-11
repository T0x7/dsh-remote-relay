/// The console-facing surface of the engine control plane.
///
/// Extracted from [EngineClient] so the UI layer depends on an interface,
/// not a socket-owning concrete class: widget tests drive pages with an
/// in-memory fake (`FakeEngineGateway`) and assert the callback round-trips
/// (plan T2.3 DoD), while production wires [EngineClient] over the real
/// relay transport.
///
/// Method-by-method this mirrors [EngineClient]; see that class for the wire
/// contracts each call honours.
library;

import 'engine.dart';
import 'engine_models.dart';
import 'engine_mux.dart';
import 'engine_rpc.dart';
import 'workspace_registry.dart';
abstract interface class EngineGateway {
  /// Client-minted idempotency key for `session/prompt`.
  String newRequestId();

  Future<EngineRpcResult> listSessions();

  Future<EngineRpcResult> createSession({
    String? cwd,
    String? sessionId,
    String? agentPreset,
    String? workspaceId,
  });

  /// D-073: agent 预设目录（新建会话时选择「由哪种 agent 处理」）。
  Future<EngineRpcResult> listAgentPresets();

  Future<EngineRpcResult> prompt({
    required String sessionId,
    required List<PromptContentPart> content,
    String? requestId,
    PromptDelivery mode,
    String? clientTimeZone,
  });

  Future<EngineRpcResult> cancelSession(String sessionId);

  Future<EngineRpcResult> renameSession(String sessionId, String title);

  Future<EngineRpcResult> forkSession(String sessionId, {int? atSeq});

  Future<EngineRpcResult> projections(String sessionId);

  Future<EngineRpcResult> page({
    required SessionAddress address,
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
  });

  SessionEventStream follow({
    required SessionAddress address,
    bool withAssistantStream,
    int? maxMessages,
  });

  MuxStream control();

  /// D-046: the machine's Workspace registry as a live subscription.
  ///
  /// **Machine-scoped, not session-scoped** — it takes no address because it
  /// answers for the whole engine. Kept separate from [follow] on purpose:
  /// mixing a registry frame into the conversation's event stream would put
  /// workspace churn in the same reconnect algebra as session events.
  WorkspaceFollowStream followWorkspaces();

  // D-055: the registry's write side. Read the doc comments on
  // `EngineClient` before using these — archiving is *not* deletion, and the
  // default path can be refused by the engine when a session is still running.

  /// `workspace/archiveSession` → `{archivedSessionIds}`.
  ///
  /// Hides a session; it does not delete one. Without [stopActivity] the
  /// engine answers `workspace/session-active` (with `details.activity`) when
  /// the session still has running work.
  Future<EngineRpcResult> archiveSession(
    String sessionId, {
    bool stopActivity = false,
  });

  /// `workspace/unarchiveSession` → `{archivedSessionIds}`.
  ///
  /// Never refused for activity, and never restores a dropped pin.
  Future<EngineRpcResult> unarchiveSession(String sessionId);

  /// `workspace/pinSession` → `{pinnedSessionIds}`, most recent first.
  Future<EngineRpcResult> pinSession(String sessionId);

  /// `workspace/unpinSession` → `{pinnedSessionIds}`.
  Future<EngineRpcResult> unpinSession(String sessionId);

  /// Direct children of [path] inside the session's workspace; `''` is the
  /// workspace root.
  Future<EngineRpcResult> workspaceList({
    required String sessionId,
    required String path,
  });

  /// One page of lines of the file at [absolutePath] (lines are 1-based).
  Future<EngineRpcResult> workspaceRead({
    required String sessionId,
    required String absolutePath,
    int? offset,
    int? limit,
  });

  /// Size and freshness of one file, without its content.
  Future<EngineRpcResult> workspaceStat({
    required String sessionId,
    required String absolutePath,
  });

  Future<EngineRpcResult> modelCatalog();

  Future<EngineRpcResult> selectModel({
    required String sessionId,
    required String provider,
    required String model,
    String? reasoningEffort,
  });

  MuxStream openEventStream();

  Future<EngineRpcResult> answerEvent({
    required String clientId,
    required String eventId,
    required Object? value,
  });

  Future<EngineRpcResult> rejectEvent({
    required String clientId,
    required String eventId,
    String name,
    required String message,
    String code,
  });

  Future<EngineRpcResult> promptSubagent({
    required String parentSessionId,
    required String childSessionId,
    required List<PromptContentPart> content,
    PromptDelivery delivery,
    String? requestId,
  });

  Future<EngineRpcResult> interruptSubagent({
    required String parentSessionId,
    required String childSessionId,
  });

  MuxStream listJobs({required String sessionId});

  MuxStream followJob({required String jobId, String? sessionId, int? from});

  Future<EngineRpcResult> killJob({
    required String sessionId,
    required String jobId,
  });

  /// `pluginInventory/list` — the mounted plugin roster.
  ///
  /// The only surface this engine version exposes about what the host is
  /// actually running. There is **no** host-metrics route or `events.host`
  /// stream in 0.1.7-rc.2, so the console must not fabricate CPU/memory
  /// figures; this list is the honest substitute.
  Future<EngineRpcResult> pluginInventory();

  /// `pluginManager/listPlugins` — the toggleable plugin roster with per-row
  /// capability (`patchId` vs `readOnlyReason`).
  Future<EngineRpcResult> pluginManagerListPlugins();

  /// `pluginManager/listBundles` — the installed-package view (live-probed
  /// 2026-10-08: 16 rows, each with its internal module `rows[]`).
  Future<EngineRpcResult> pluginManagerListBundles();

  /// `pluginManager/setPluginEnabled` — flips one loader entry.
  Future<EngineRpcResult> pluginManagerSetPluginEnabled({
    required String id,
    required bool enabled,
  });

  /// `pluginManager/setBundleEnabled` — flips a whole bundle.
  Future<EngineRpcResult> pluginManagerSetBundleEnabled({
    required String name,
    required bool enabled,
  });
}
