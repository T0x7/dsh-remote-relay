/// dsh engine domain models for the M2 console (plan T2.1c).
///
/// Every shape here is hand-copied from dsh-root **0.1.7-rc.2** and traced to
/// a source location, either directly or through
/// `docs/engine-contract-m2.md` (which carries the `文件:行号` citations).
/// Field names are the wire's own — the App never renames them.
///
/// Three structural facts from the contract shape everything here and are easy
/// to get wrong:
///
/// 1. **`contextPressure` / `contextBreakdown` / `tokenUsage` /
///    `subagentCatalog` are projections, not events.** None of them appear
///    among the 61 `SessionEvent` types
///    (`core/session/src/known-event-types.ts:22-83`). The console reads them
///    from a projection baseline, not from the event stream.
/// 2. **A missing projection key means "this session cannot express that at
///    this cut", not zero** (`api/session-controller/src/types.ts:75-77`).
///    [Projections.has] is therefore meaningful and must not be collapsed
///    into a default value.
/// 3. **Approval and question answers are bare values**, not enveloped
///    objects: the `$events/result` `outcome.value` is the literal string
///    `"allowed-once"` or a `{answers: [...]}` map — no wrapper
///    (`docs/engine-contract-m2.md` §4.3, §5.3).
library;

/// Field-level accessors used by the decoders below and by the client facade.
///
/// Every decoder degrades rather than throws: an engine that adds a field must
/// not blank the console, and a malformed projection must not take down a
/// session. Required-ness is documented per field from the zod schema
/// (`.strict()` with no `.optional()` = wire-required).
///
/// Safely read a `Map`, tolerating absent / wrong-typed values.
///
/// Public because the [EngineClient] facade needs the same guard: a raw
/// `value as Map<String, dynamic>` throws on a const map or any
/// `Map<dynamic, dynamic>`, and one malformed envelope must never take down a
/// session screen.
Map<String, dynamic>? asObject(Object? v) =>
    v is Map<String, dynamic> ? v : null;

/// List access that tolerates absent / wrong-typed values.
List<Object?>? asList(Object? v) => v is List<Object?> ? v : null;

Map<String, dynamic>? _obj(Object? v) => asObject(v);

List<Object?>? _arr(Object? v) => asList(v);

String _str(Object? v, [String fallback = '']) =>
    v is String ? v : fallback;

bool _bool(Object? v, [bool fallback = false]) =>
    v is bool ? v : fallback;

int _int(Object? v, [int fallback = 0]) =>
    v is num ? v.toInt() : fallback;

/// Addresses an ordinary session or a direct-subagent child.
///
/// `api/session-controller/src/types.ts:407-415`. The two shapes are mutually
/// exclusive and the host enforces several consistency rules (§1.6 of the
/// contract) — most importantly, addressing a subagent child with
/// `kind: 'session'` fails with `session/agent-busy`.
sealed class SessionAddress {
  const SessionAddress();

  /// Ordinary top-level session.
  const factory SessionAddress.session(String sessionId) = PlainSessionAddress;

  /// A subagent child, addressed directly.
  const factory SessionAddress.subagent({
    required String parentSessionId,
    required String childSessionId,
    required SubagentMode mode,
  }) = SubagentSessionAddress;

  factory SessionAddress.fromJson(Map<String, dynamic> j) =>
      j['kind'] == 'subagent'
          ? SubagentSessionAddress(
              parentSessionId: _str(j['parentSessionId']),
              childSessionId: _str(j['childSessionId']),
              mode: SubagentMode.fromJson(j['mode'] as String?),
            )
          : PlainSessionAddress(_str(j['sessionId']));

  Map<String, dynamic> toJson();
}

final class PlainSessionAddress extends SessionAddress {
  const PlainSessionAddress(this.sessionId);
  final String sessionId;

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'session', 'sessionId': sessionId};
}

final class SubagentSessionAddress extends SessionAddress {
  const SubagentSessionAddress({
    required this.parentSessionId,
    required this.childSessionId,
    required this.mode,
  });

  final String parentSessionId;
  final String childSessionId;
  final SubagentMode mode;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'subagent',
        'parentSessionId': parentSessionId,
        'childSessionId': childSessionId,
        'mode': mode.wire,
      };
}

/// Subagent lifecycle mode — the discriminator for the read-only rule.
///
/// `subagent/subagent/src/projection-types.ts:10-19`. This single field is what
/// makes a subagent read-only: `one-shot` is terminal, so the console must not
/// offer a composer for it. There is **no** `readOnly: true` flag anywhere in
/// the protocol (§9.2).
enum SubagentMode {
  oneShot('one-shot'),
  continuable('continuable'),
  unknown('unknown');

  const SubagentMode(this.wire);
  final String wire;

  static SubagentMode fromJson(String? v) => switch (v) {
        'one-shot' => SubagentMode.oneShot,
        'continuable' => SubagentMode.continuable,
        _ => SubagentMode.unknown,
      };

  /// `continuable` is the only mode a write may target; `subagents.prompt`
  /// requires the literal `'continuable'` and rejects anything else with
  /// `subagent/not-resumable`.
  bool get acceptsInput => this == SubagentMode.continuable;
}

/// `SessionHeader` as it appears in the `follow` snapshot (`SessionWireHeader`).
///
/// `core/session/src/types.ts:94-139`. `version` is pinned at
/// `SESSION_FORMAT_VERSION = 4`.
class SessionHeader {
  const SessionHeader({
    required this.version,
    required this.id,
    required this.createdAt,
    required this.isSeeded,
    this.cwd,
    this.parentSession,
    this.origin,
    this.delegationDepth,
    this.agentPreset,
    this.title,
  });

  factory SessionHeader.fromJson(Map<String, dynamic> j) => SessionHeader(
        version: _int(j['version']),
        id: _str(j['id']),
        createdAt: _int(j['createdAt']),
        isSeeded: _bool(j['isSeeded']),
        cwd: j['cwd'] as String?,
        parentSession: j['parentSession'] as String?,
        origin: j['origin'] as String?,
        delegationDepth: j['delegationDepth'] is num
            ? (j['delegationDepth']! as num).toInt()
            : null,
        agentPreset: j['agentPreset'] as String?,
        title: j['title'] as String?,
      );

  final int version;
  final String id;
  final int createdAt;
  final bool isSeeded;
  final String? cwd;
  final String? parentSession;

  /// `'subagent'` marks a child session.
  final String? origin;
  final int? delegationDepth;
  final String? agentPreset;
  final String? title;

  bool get isSubagent => origin == 'subagent';
}

/// One row of `session/list` (`SessionSummary`).
///
/// `api/session-controller/src/types.ts:176-188`. The five booleans are
/// wire-required; the rest are optional hints.
class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.updatedAt,
    required this.running,
    required this.blank,
    required this.agentAvailable,
    this.parentSessionId,
    this.origin,
    this.cwd,
    this.projections,
  });

  factory SessionSummary.fromJson(Map<String, dynamic> j) => SessionSummary(
        sessionId: _str(j['sessionId']),
        updatedAt: _int(j['updatedAt']),
        running: _bool(j['running']),
        blank: _bool(j['blank']),
        agentAvailable: _bool(j['agentAvailable']),
        parentSessionId: j['parentSessionId'] as String?,
        origin: j['origin'] as String?,
        cwd: j['cwd'] as String?,
        projections: _obj(j['projections']) == null
            ? null
            : SessionProjectionHints.fromJson(_obj(j['projections'])!),
      );

  final String sessionId;
  final int updatedAt;
  final bool running;
  final bool blank;
  final bool agentAvailable;
  final String? parentSessionId;
  final String? origin;
  final String? cwd;
  final SessionProjectionHints? projections;

  bool get isSubagent => origin == 'subagent';
}

/// How fresh a list row's inline projections are.
///
/// `api/session-controller/src/types.ts:58-71`. `kind` decides whether
/// [asOfSeq] may be compared against the control stream's cursor — a `cached`
/// row may be stale and must not be diffed.
class SessionProjectionHints {
  const SessionProjectionHints({
    required this.kind,
    required this.asOfSeq,
    required this.values,
  });

  factory SessionProjectionHints.fromJson(Map<String, dynamic> j) =>
      SessionProjectionHints(
        kind: j['kind'] == 'sequenced' ? 'sequenced' : 'cached',
        asOfSeq: _int(j['asOfSeq']),
        values: Projections.fromJson(_obj(j['values']) ?? const {}),
      );

  /// `'cached'` or `'sequenced'`.
  final String kind;
  final int asOfSeq;
  final Projections values;

  bool get isSequenced => kind == 'sequenced';
}

/// Trimmed title off the wire, or null. Whitespace-only counts as absent —
/// an unnamed session sometimes carries an empty-string title.
String? _titleOf(Object? v) {
  final t = v as String?;
  if (t == null) return null;
  final trimmed = t.trim();
  return trimmed.isEmpty ? null : t;
}

/// The session's projection set at one cut.
///
/// `SessionProjectionBaseline` = `{asOfSeq, values}`
/// (`api/session-controller/src/types.ts:73-78`). **Absence of a key means
/// the capability is not available at this cut — not a zero value.**
class Projections {
  const Projections({
    this.title,
    this.tokenUsage,
    this.contextPressure,
    this.contextBreakdown,
    this.modelSelection,
    this.sessionStats,
    this.subagentCatalog,
    this.subagent,
  });

  factory Projections.fromJson(Map<String, dynamic> j) {
    final subagent = _obj(j['subagent']);
    return Projections(
      title: _titleOf(j['title']),
      tokenUsage: _obj(j['tokenUsage']) == null
          ? null
          : TokenUsageProjection.fromJson(_obj(j['tokenUsage'])!),
      contextPressure: _obj(j['contextPressure']) == null
          ? null
          : ContextPressure.fromJson(_obj(j['contextPressure'])!),
      contextBreakdown: _obj(j['contextBreakdown']) == null
          ? null
          : ContextBreakdown.fromJson(_obj(j['contextBreakdown'])!),
      modelSelection: _obj(j['modelSelection']) == null
          ? null
          : ModelSelectionProjection.fromJson(_obj(j['modelSelection'])!),
      sessionStats: _obj(j['sessionStats']) == null
          ? null
          : SessionStatsProjection.fromJson(_obj(j['sessionStats'])!),
      subagentCatalog: _arr(j['subagentCatalog']) == null
          ? null
          : (_arr(j['subagentCatalog'])!)
              .whereType<Map<String, dynamic>>()
              .map(SubagentCatalogEntry.fromJson)
              .toList(growable: false),
      subagent: subagent == null ? null : SubagentIdentity.fromJson(subagent),
    );
  }

  /// D-063: the projection-side title (`values.title`).
  ///
  /// Present on most `session/list` rows (58/62 on the reference host), but
  /// **the field is "first eligible prompt prefix", not a curated name**: the
  /// scheduler family stores its prompt's date line, and subagent children
  /// store their `<system-reminder> You are teammate…` preamble. Use
  /// [titleLike] to tell a real name from such truncations before rendering.
  final String? title;

  final TokenUsageProjection? tokenUsage;
  final ContextPressure? contextPressure;
  final ContextBreakdown? contextBreakdown;
  final ModelSelectionProjection? modelSelection;
  final SessionStatsProjection? sessionStats;
  final List<SubagentCatalogEntry>? subagentCatalog;

  /// The child's own subagent identity — non-null only on a child session.
  final SubagentIdentity? subagent;

  /// Whether [title] is a *name* rather than a truncation of the first prompt.
  ///
  /// Two families dominate the mislabeled share (measured 2026-10-05:
  /// 57/58 mislabeled on the reference host):
  /// - scheduler prompts, whose first line is the harness date stamp
  ///   「今天是 YYYY-MM-DD。当前时刻 HH:mm」；
  /// - subagent children, whose first line is
  ///   `<system-reminder> You are teammate "…"`.
  ///
  /// Displaying either as a title makes 37 rows read identically, which is
  /// worse than showing the id — an id is honest about being an id.
  static bool _looksLikeTitle(String t) =>
      t.trim().isNotEmpty &&
      !t.startsWith('今天是') &&
      !t.startsWith('<system-reminder>');

  /// The renderable title from this projection, or null when [title] is
  /// absent or reads as a prompt truncation.
  String? get titleLike {
    final t = title?.trim();
    if (t == null || t.isEmpty) return null;
    return _looksLikeTitle(t) ? t : null;
  }

  /// Whether [key] is present, i.e. whether this session expresses the
  /// capability at all. Never infer this from a zero value.
  bool has(String key) => switch (key) {
        'tokenUsage' => tokenUsage != null,
        'contextPressure' => contextPressure != null,
        'contextBreakdown' => contextBreakdown != null,
        'modelSelection' => modelSelection != null,
        'sessionStats' => sessionStats != null,
        'subagentCatalog' => subagentCatalog != null,
        'subagent' => subagent != null,
        'title' => titleLike != null,
        _ => false,
      };
}

/// A projection baseline: the values plus the seq they were cut at.
class SessionProjectionBaseline {
  const SessionProjectionBaseline({required this.asOfSeq, required this.values});

  factory SessionProjectionBaseline.fromJson(Map<String, dynamic> j) =>
      SessionProjectionBaseline(
        asOfSeq: _int(j['asOfSeq']),
        values: Projections.fromJson(_obj(j['values']) ?? const {}),
      );

  final int asOfSeq;
  final Projections values;
}

/// Prompt-side context occupancy (projection `contextPressure`).
///
/// `llm/token-meter/src/projection.ts:30-48`; wire zod
/// `llm/token-meter/src/usage-projection.ts:67-75` marks **all three fields
/// optional**.
///
/// The three values are deliberately *not* an atomic observation of one
/// request — switching models can pair a new window with the previous route's
/// pressure. Present this as advisory context, never as billing or a gate.
class ContextPressure {
  const ContextPressure({this.pressureTokens, this.projectedTokens, this.contextWindow});

  factory ContextPressure.fromJson(Map<String, dynamic> j) => ContextPressure(
        pressureTokens: j['pressureTokens'] is num
            ? (j['pressureTokens']! as num).toInt()
            : null,
        projectedTokens: j['projectedTokens'] is num
            ? (j['projectedTokens']! as num).toInt()
            : null,
        contextWindow:
            j['contextWindow'] is num ? (j['contextWindow']! as num).toInt() : null,
      );

  /// Last request's prompt-side occupancy = input + cacheRead + cacheWrite.
  /// Excludes output.
  final int? pressureTokens;

  /// Estimated next prompt cost = pressure + surface delta.
  final int? projectedTokens;

  /// Capacity of the most recently recorded route.
  final int? contextWindow;

  /// Occupancy ratio in 0..1 for the ring, or null when the engine has not
  /// reported usage yet (both token fields are absent until it does).
  double? get fillRatio {
    final projected = projectedTokens ?? pressureTokens;
    final window = contextWindow;
    if (projected == null || window == null || window <= 0) return null;
    return (projected / window).clamp(0.0, 1.0);
  }
}

/// The system / tools / conversation split (projection `contextBreakdown`).
///
/// `llm/token-meter/src/projection.ts:59-66`; all three fields are
/// wire-required. These are fixed-density estimates and deliberately **do not**
/// sum to `projectedTokens` — show them as composition, never as a total.
class ContextBreakdown {
  const ContextBreakdown({
    required this.systemTokens,
    required this.toolsTokens,
    required this.messageTokens,
  });

  factory ContextBreakdown.fromJson(Map<String, dynamic> j) => ContextBreakdown(
        systemTokens: _int(j['systemTokens']),
        toolsTokens: _int(j['toolsTokens']),
        messageTokens: _int(j['messageTokens']),
      );

  final int systemTokens;
  final int toolsTokens;
  final int messageTokens;

  int get total => systemTokens + toolsTokens + messageTokens;
}

/// Session-wide token usage (projection `tokenUsage`) — **all four required**.
///
/// `llm/token-meter/src/projection.ts:13-18`. There is no `tokenUsage` event;
/// this is projection-only. Billable input is the sum of
/// uncached + cacheRead + cacheWrite.
class TokenUsageProjection {
  const TokenUsageProjection({
    required this.uncachedInputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
  });

  factory TokenUsageProjection.fromJson(Map<String, dynamic> j) =>
      TokenUsageProjection(
        uncachedInputTokens: _int(j['uncachedInputTokens']),
        outputTokens: _int(j['outputTokens']),
        cacheReadTokens: _int(j['cacheReadTokens']),
        cacheWriteTokens: _int(j['cacheWriteTokens']),
      );

  final int uncachedInputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// Reasoning tokens are already inside [outputTokens] — do not add them.
  int get billableInputTokens =>
      uncachedInputTokens + cacheReadTokens + cacheWriteTokens;
}

/// Turn/step timings (projection `sessionStats`) — all eight required.
///
/// `session/session-stats/src/types.ts:22-39`. There is no tok/s field
/// anywhere in the protocol: the console divides [decodeTokens] by
/// [decodeMs] exactly as the official client does.
class SessionStatsProjection {
  const SessionStatsProjection({
    required this.turns,
    required this.steps,
    required this.llmMs,
    required this.toolMs,
    required this.ttftMs,
    required this.ttftSteps,
    required this.decodeMs,
    required this.decodeTokens,
  });

  factory SessionStatsProjection.fromJson(Map<String, dynamic> j) =>
      SessionStatsProjection(
        turns: _int(j['turns']),
        steps: _int(j['steps']),
        llmMs: _int(j['llmMs']),
        toolMs: _int(j['toolMs']),
        ttftMs: _int(j['ttftMs']),
        ttftSteps: _int(j['ttftSteps']),
        decodeMs: _int(j['decodeMs']),
        decodeTokens: _int(j['decodeTokens']),
      );

  final int turns;
  final int steps;
  final int llmMs;
  final int toolMs;
  final int ttftMs;
  final int ttftSteps;
  final int decodeMs;
  final int decodeTokens;

  /// Tokens per second, derived — null when there is no decode window.
  double? get tokensPerSecond {
    if (decodeMs <= 0) return null;
    return decodeTokens / (decodeMs / 1000.0);
  }

  /// Mean time to first token across steps that produced one.
  int? get meanTtftMs => ttftSteps <= 0 ? null : ttftMs ~/ ttftSteps;
}

/// The model/effort a session uses, as a projection.
///
/// `api/session-controller/src/model-selection-projection.ts:58-68`.
class ModelSelectionProjection {
  const ModelSelectionProjection({this.lastUsed, this.next});

  factory ModelSelectionProjection.fromJson(Map<String, dynamic> j) =>
      ModelSelectionProjection(
        lastUsed: _obj(j['lastUsed']) == null
            ? null
            : ModelSelection.fromJson(_obj(j['lastUsed'])!),
        next: _obj(j['next']) == null
            ? null
            : ModelSelection.fromJson(_obj(j['next'])!),
      );

  final ModelSelection? lastUsed;

  /// `pending ?? lastUsed`. **Null means the session has never chosen — i.e.
  /// it is following the deployment default.** This is how "follow default" is
  /// expressed; the protocol has no `followDefault` flag (§6.3).
  final ModelSelection? next;

  /// Whether this session is following the deployment default.
  bool get followsDefault => next == null;
}

/// A concrete provider + model + effort triple.
class ModelSelection {
  const ModelSelection({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  factory ModelSelection.fromJson(Map<String, dynamic> j) => ModelSelection(
        provider: _str(j['provider']),
        model: _str(j['model']),
        reasoningEffort: j['reasoningEffort'] as String?,
      );

  final String provider;
  final String model;

  /// Absent means "use this model's own `defaultEffort`".
  final String? reasoningEffort;
}

/// The engine's full model catalog (`session/modelCatalog`).
///
/// `api/session-controller/src/types.ts:157-164` — all four fields required.
/// The App ships **no** built-in model list: providers whose catalog fetch
/// failed are isolated into [failures] instead of breaking the list, and
/// providers with no usable model are already filtered out upstream.
class ModelCatalog {
  const ModelCatalog({
    required this.defaultSelection,
    required this.routableProviders,
    required this.groups,
    required this.failures,
  });

  factory ModelCatalog.fromJson(Map<String, dynamic> j) => ModelCatalog(
        defaultSelection: ModelSelection.fromJson(_obj(j['default']) ?? const {}),
        routableProviders: (_arr(j['routableProviders']) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        groups: (_arr(j['groups']) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ModelProviderGroup.fromJson)
            .toList(growable: false),
        failures: (_arr(j['failures']) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ModelCatalogFailure.fromJson)
            .toList(growable: false),
      );

  final ModelSelection defaultSelection;
  final List<String> routableProviders;
  final List<ModelProviderGroup> groups;
  final List<ModelCatalogFailure> failures;

  /// Find a model by provider + id across [groups].
  ModelCatalogModel? findModel(String providerId, String modelId) {
    for (final group in groups) {
      if (group.id != providerId) continue;
      for (final model in group.models) {
        if (model.id == modelId) return model;
      }
    }
    return null;
  }
}

class ModelProviderGroup {
  const ModelProviderGroup({
    required this.id,
    required this.name,
    required this.models,
  });

  factory ModelProviderGroup.fromJson(Map<String, dynamic> j) => ModelProviderGroup(
        id: _str(j['id']),
        name: _str(j['name']),
        models: (_arr(j['models']) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ModelCatalogModel.fromJson)
            .toList(growable: false),
      );

  final String id;
  final String name;
  final List<ModelCatalogModel> models;
}

class ModelCatalogModel {
  const ModelCatalogModel({
    required this.id,
    required this.name,
    this.description,
    this.reasoning,
  });

  factory ModelCatalogModel.fromJson(Map<String, dynamic> j) => ModelCatalogModel(
        id: _str(j['id']),
        name: _str(j['name']),
        description: j['description'] as String?,
        reasoning: _obj(j['reasoning']) == null
            ? null
            : ModelReasoning.fromJson(_obj(j['reasoning'])!),
      );

  final String id;
  final String name;
  final String? description;
  final ModelReasoning? reasoning;

  /// A non-reasoning model offers only "off", so the chips row is a single
  /// entry — never hardcode the four levels Off/Low/High/Max.
  List<ModelReasoningEffort> get efforts => reasoning?.efforts ?? const [];
}

class ModelReasoning {
  const ModelReasoning({required this.efforts, this.defaultEffort});

  factory ModelReasoning.fromJson(Map<String, dynamic> j) => ModelReasoning(
        efforts: (_arr(j['efforts']) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ModelReasoningEffort.fromJson)
            .toList(growable: false),
        defaultEffort: j['defaultEffort'] as String?,
      );

  /// Adapter-preferred display order. Do not sort.
  final List<ModelReasoningEffort> efforts;

  /// Absent means "keep the provider's own default".
  final String? defaultEffort;
}

class ModelReasoningEffort {
  const ModelReasoningEffort({required this.id, required this.name, this.description});

  factory ModelReasoningEffort.fromJson(Map<String, dynamic> j) =>
      ModelReasoningEffort(
        id: _str(j['id']),
        name: _str(j['name']),
        description: j['description'] as String?,
      );

  final String id;
  final String name;
  final String? description;
}

class ModelCatalogFailure {
  const ModelCatalogFailure({required this.id, required this.name, required this.message});

  factory ModelCatalogFailure.fromJson(Map<String, dynamic> j) => ModelCatalogFailure(
        id: _str(j['id']),
        name: _str(j['name']),
        message: _str(j['message']),
      );

  final String id;
  final String name;
  final String message;
}

/// One child in the `subagentCatalog` projection.
///
/// `subagent/subagent/src/projection-types.ts:10-19`. Note there is **no**
/// `parentSessionId` here — the parent is implied by which session's
/// projection set you read this from, so a read must always carry the parent
/// session id.
class SubagentCatalogEntry {
  const SubagentCatalogEntry({
    required this.id,
    required this.createdAt,
    required this.mode,
    this.label,
  });

  factory SubagentCatalogEntry.fromJson(Map<String, dynamic> j) => SubagentCatalogEntry(
        id: _str(j['id']),
        createdAt: _int(j['createdAt']),
        mode: SubagentMode.fromJson(j['mode'] as String?),
        label: j['label'] as String?,
      );

  /// The child session id.
  final String id;
  final int createdAt;
  final SubagentMode mode;
  final String? label;

  /// Whether the console may offer a composer for this child. Derived from
  /// [mode] alone — the protocol has no `readOnly` flag (§9.2).
  bool get acceptsInput => mode.acceptsInput;
}

/// A child session's own subagent identity (projection `subagent`).
///
/// `subagent/subagent/src/projection-types.ts:45-66`. A missing projection
/// (`null` upstream) means the child has no valid descriptor — treat the child
/// as unsupported rather than read-write.
class SubagentIdentity {
  const SubagentIdentity({required this.mode, required this.seq, this.label});

  factory SubagentIdentity.fromJson(Map<String, dynamic> j) => SubagentIdentity(
        mode: SubagentMode.fromJson(j['mode'] as String?),
        seq: _int(j['seq']),
        label: j['label'] as String?,
      );

  final SubagentMode mode;
  final int seq;
  final String? label;

  bool get acceptsInput => mode.acceptsInput;
}

/// One durable session event as it arrives on the `follow` stream.
///
/// `api/session-controller/src/types.ts:453-468`. The official client accepts
/// exactly seven keys and throws on an eighth
/// (`client/session-wire-event.ts:20-33`), so [knownKeys] mirrors that set.
class SessionWireEvent {
  const SessionWireEvent({
    required this.type,
    required this.seq,
    required this.time,
    required this.data,
    this.ignorable,
    this.surfaceOp,
    this.sourceEventSeqs,
  });

  factory SessionWireEvent.fromJson(Map<String, dynamic> j) => SessionWireEvent(
        type: _str(j['type']),
        seq: _int(j['seq']),
        time: _int(j['time']),
        data: j['data'],
        // Present only when strictly `true`.
        ignorable: j['ignorable'] == true ? true : null,
        surfaceOp: j['surfaceOp'] is String ? j['surfaceOp']! as String : null,
        sourceEventSeqs: _arr(j['sourceEventSeqs']),
      );

  /// The seven keys the client accepts.
  static const knownKeys = {
    'type',
    'seq',
    'time',
    'data',
    'ignorable',
    'surfaceOp',
    'sourceEventSeqs',
  };

  final String type;
  final int seq;
  final int time;
  final Object? data;
  final bool? ignorable;

  /// `'append'` or a replace descriptor; only the five surface event types may
  /// carry it (`core/session/src/types.ts:447-453`).
  final String? surfaceOp;
  final List<Object?>? sourceEventSeqs;

  bool get isSurface => surfaceOp != null;

  /// Events the bubble list renders directly. The remaining ~56 types are
  /// bookkeeping the console deliberately ignores.
  bool get isVisibleMessage =>
      type == 'user/message' ||
      type == 'assistant/message' ||
      type == 'system/message' ||
      type == 'developer/message' ||
      type == 'tool/result';

  /// `data` decoded as a map, or empty when the payload is not an object.
  Map<String, dynamic> get dataObject => _obj(data) ?? const {};
}

/// The three `follow` frame shapes (`SessionFollowFrame`).
///
/// `api/session-controller/src/types.ts:551-563`. Exactly one snapshot opens
/// the stream; every later frame is an entry or an assistant-stream frame.
sealed class SessionFollowFrame {
  const SessionFollowFrame();

  factory SessionFollowFrame.fromJson(Map<String, dynamic> j) =>
      switch (j['type']) {
        'snapshot' => FollowSnapshot.fromJson(j),
        'event' => FollowEvent.fromJson(j),
        'assistant-stream' => FollowAssistantStream.fromJson(j),
        _ => FollowUnknown(j['type'] as String? ?? '?'),
      };
}

/// Frame A — the opening snapshot, sent exactly once.
class FollowSnapshot extends SessionFollowFrame {
  const FollowSnapshot({
    required this.header,
    required this.cursor,
    required this.records,
    required this.hasMore,
    required this.projections,
    this.assistantStream,
  });

  factory FollowSnapshot.fromJson(Map<String, dynamic> j) => FollowSnapshot(
        header: SessionHeader.fromJson(_obj(j['header']) ?? const {}),
        cursor: _int(j['cursor']),
        records: (_arr(j['records']) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FollowEvent.fromJson)
            .toList(growable: false),
        hasMore: _bool(j['hasMore']),
        projections: SessionProjectionBaseline.fromJson(
            _obj(j['projections']) ?? const {}),
        assistantStream: _obj(j['assistantStream']) == null
            ? null
            : AssistantStreamBaseline.fromJson(_obj(j['assistantStream'])!),
      );

  final SessionHeader header;

  /// Last committed seq; `-1` for an empty log.
  final int cursor;
  final List<FollowEvent> records;
  final bool hasMore;
  final SessionProjectionBaseline projections;

  /// Present **only** because the request asked for `assistantStream: true`.
  /// If it was requested and this is null, that is a protocol fault, not an
  /// empty stream (`client/transport.ts:186-192`).
  final AssistantStreamBaseline? assistantStream;
}

/// Frame B — one durable event entry.
class FollowEvent extends SessionFollowFrame {
  const FollowEvent(this.event);

  factory FollowEvent.fromJson(Map<String, dynamic> j) => FollowEvent(
        SessionWireEvent.fromJson(_obj(j['event']) ?? const {}),
      );

  final SessionWireEvent event;

  int get seq => event.seq;
}

/// Frame C — a live assistant chunk frame (`assistant/live-chunk` presentation).
///
/// These carry **no seq** and take no part in cursor algebra; they must render
/// after any gap repair (`api/gateway/src/client/journal-stream.ts:22`).
class FollowAssistantStream extends SessionFollowFrame {
  const FollowAssistantStream(this.frame);

  factory FollowAssistantStream.fromJson(Map<String, dynamic> j) =>
      FollowAssistantStream(_obj(j['frame']) ?? const {});

  final Map<String, dynamic> frame;

  /// `start` | `chunk` | `end` (`api/session-controller/src/types.ts:512-543`).
  String get kind => _str(frame['type']);

  String get attemptId => _str(frame['attemptId']);
  int get revision => _int(frame['revision']);
  int get index => _int(frame['index']);
  int get turn => _int(frame['turn']);
  int get step => _int(frame['step']);

  /// The transient `StreamChunk` for a `chunk` frame, or null.
  Map<String, dynamic>? get chunk => _obj(frame['chunk']);

  /// Whether the attempt's last durable event superseded the transient rows.
  bool get committed =>
      _obj(frame['outcome'])?['kind'] == 'committed';
}

/// A frame the console does not model — kept rather than dropped so an engine
/// upgrade degrades to "ignored" instead of a crash.
class FollowUnknown extends SessionFollowFrame {
  const FollowUnknown(this.type);
  final String type;
}

/// The assistant-stream opening baseline carried by the snapshot.
class AssistantStreamBaseline {
  const AssistantStreamBaseline({required this.revision, this.activeAttempt});

  factory AssistantStreamBaseline.fromJson(Map<String, dynamic> j) =>
      AssistantStreamBaseline(
        revision: _int(j['revision']),
        activeAttempt: _obj(j['activeAttempt']) == null
            ? null
            : _obj(j['activeAttempt'])!.containsKey('attemptId')
                ? AssistantStreamAttempt.fromJson(_obj(j['activeAttempt'])!)
                : null,
      );

  /// The first assistant-stream frame must be `revision + 1`; a skip is a
  /// carrier error and the client throws (`client/transport.ts:206-215`).
  final int revision;
  final AssistantStreamAttempt? activeAttempt;
}

class AssistantStreamAttempt {
  const AssistantStreamAttempt({
    required this.attemptId,
    required this.startedAfterSeq,
    required this.turn,
    required this.step,
    required this.nextIndex,
  });

  factory AssistantStreamAttempt.fromJson(Map<String, dynamic> j) =>
      AssistantStreamAttempt(
        attemptId: _str(j['attemptId']),
        startedAfterSeq: _int(j['startedAfterSeq']),
        turn: _int(j['turn']),
        step: _int(j['step']),
        nextIndex: _int(j['nextIndex']),
      );

  final String attemptId;
  final int startedAfterSeq;
  final int turn;
  final int step;
  final int nextIndex;
}

/// A prompt content part (`PromptContentPart`).
///
/// `api/session-controller/src/types.ts:89-97`. v1 sends text only; image and
/// file parts are the attachment long tail.
class PromptContentPart {
  const PromptContentPart.text(this.text) : type = 'text', mediaType = null, data = null, name = null, receiptId = null;

  const PromptContentPart.image({
    required this.mediaType,
    required this.data,
    this.name,
  })  : type = 'image',
        text = null,
        receiptId = null;

  const PromptContentPart.file(this.receiptId)
      : type = 'file',
        text = null,
        mediaType = null,
        data = null,
        name = null;

  factory PromptContentPart.fromJson(Map<String, dynamic> j) =>
      switch (j['type']) {
        'image' => PromptContentPart.image(
            mediaType: _str(j['mediaType']),
            data: _str(j['data']),
            name: j['name'] as String?),
        'file' => PromptContentPart.file(_str(j['receiptId'])),
        _ => PromptContentPart.text(_str(j['text'])),
      };

  final String type;
  final String? text;
  final String? mediaType;

  /// base64, for image parts.
  final String? data;
  final String? name;
  final String? receiptId;

  Map<String, dynamic> toJson() => switch (type) {
        'image' => {
            'type': 'image',
            'mediaType': mediaType,
            'data': data,
            if (name != null) 'name': name,
          },
        'file' => {'type': 'file', 'receiptId': receiptId},
        _ => {'type': 'text', 'text': text},
      };
}

/// An `approval/request` waterfall payload.
///
/// `interaction/user-approval/src/types.ts:67-73` minus `agent` / `signal`.
/// Note `displayReason` is a locale map used for display only and is never
/// persisted.
class ApprovalRequest {
  const ApprovalRequest({
    required this.toolName,
    this.callId,
    this.reason,
    this.displayReason,
  });

  factory ApprovalRequest.fromJson(Map<String, dynamic> j) {
    final display = _obj(j['displayReason']);
    return ApprovalRequest(
      toolName: _str(j['toolName']),
      callId: j['callId'] as String?,
      reason: j['reason'] as String?,
      displayReason: display?.map((k, v) => MapEntry(k, v is String ? v : '')),
    );
  }

  final String toolName;
  final String? callId;
  final String? reason;
  final Map<String, String>? displayReason;

  /// Localized text for [locale], falling back to the raw [reason].
  String textFor(String locale) =>
      displayReason?[locale] ?? reason ?? toolName;
}

/// The four approval outcomes (`ApprovalOutcome`).
///
/// `interaction/user-approval/src/types.ts:32` — bare string literals with no
/// object structure. An interactive UI returns only [allowedOnce] or
/// [rejected]; the other two exist for Host-side and no-responder paths
/// (`client/ui-approval/src/client/contract/slots.ts:66`).
enum ApprovalOutcome {
  allowedOnce('allowed-once'),
  rejected('rejected'),
  cancelled('cancelled'),
  unavailable('unavailable');

  const ApprovalOutcome(this.wire);
  final String wire;

  bool get isInteractive => this == allowedOnce || this == rejected;
}

/// One `user-questions/request` item (`AskUserQuestionItem`).
///
/// `interaction/user-questions/src/types.ts:36-51`. `multiSelect` defaults to
/// false when absent; absent `options` means free text.
class AskUserQuestionItem {
  const AskUserQuestionItem({
    required this.id,
    required this.question,
    this.detail,
    this.header,
    this.options,
    this.multiSelect = false,
    this.intent,
  });

  factory AskUserQuestionItem.fromJson(Map<String, dynamic> j) => AskUserQuestionItem(
        id: _str(j['id']),
        question: _str(j['question']),
        detail: j['detail'] as String?,
        header: j['header'] as String?,
        options: _arr(j['options']) == null
            ? null
            : (_arr(j['options'])!)
                .whereType<Map<String, dynamic>>()
                .map(QuestionOption.fromJson)
                .toList(growable: false),
        multiSelect: _bool(j['multiSelect']),
        intent: _obj(j['intent']) == null
            ? null
            : AskUserQuestionIntent.fromJson(_obj(j['intent'])!),
      );

  final String id;
  final String question;
  final String? detail;
  final String? header;
  final List<QuestionOption>? options;
  final bool multiSelect;
  final AskUserQuestionIntent? intent;

  bool get isFreeText => options == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'question': question,
        if (detail != null) 'detail': detail,
        if (header != null) 'header': header,
        if (options != null)
          'options': options!.map((o) => o.toJson()).toList(growable: false),
        if (multiSelect) 'multiSelect': true,
        if (intent != null) 'intent': intent!.toJson(),
      };
}

class QuestionOption {
  const QuestionOption({required this.label, this.description});

  factory QuestionOption.fromJson(Map<String, dynamic> j) => QuestionOption(
        label: _str(j['label']),
        description: j['description'] as String?,
      );

  final String label;
  final String? description;

  Map<String, dynamic> toJson() => {
        'label': label,
        if (description != null) 'description': description,
      };
}

/// The `plan-review` intent — the only value [AskUserQuestionItem.intent] has.
///
/// `interaction/user-questions/src/types.ts:22-33`. [approve] is an **option
/// label, not an index**: any other option means decline, so the UI must match
/// by name and must never infer from position.
class AskUserQuestionIntent {
  const AskUserQuestionIntent({required this.approve, this.callId});

  factory AskUserQuestionIntent.fromJson(Map<String, dynamic> j) =>
      AskUserQuestionIntent(
        approve: _str(j['approve']),
        callId: j['callId'] as String?,
      );

  final String approve;
  final String? callId;

  Map<String, dynamic> toJson() => {
        'kind': 'plan-review',
        'approve': approve,
        if (callId != null) 'callId': callId,
      };
}

/// A `plan-review` question, narrowed by the official client's six conditions.
///
/// `client/ui-user-questions/src/client/contract/slots.ts:81-101`. If any
/// condition fails the console falls back to the generic question flow — the
/// answer encoding is identical either way, so the fallback is safe.
class PlanReview {
  const PlanReview({
    required this.id,
    required this.question,
    required this.plan,
    required this.approve,
    this.callId,
    this.decline,
  });

  /// The single question of a plan-review request, or null when the payload
  /// does not meet all six conditions.
  static PlanReview? of(List<AskUserQuestionItem> questions) {
    if (questions.length != 1) return null;
    final q = questions.first;
    final intent = q.intent;
    if (intent == null || q.detail == null) return null;
    if (q.multiSelect) return null;
    final options = q.options;
    if (options == null || options.length > 2) return null;
    final approved = options.where((o) => o.label == intent.approve).toList();
    if (approved.isEmpty) return null;
    final declined = options.where((o) => o.label != intent.approve).toList();
    return PlanReview(
      id: q.id,
      question: q.question,
      plan: q.detail!,
      approve: intent.approve,
      callId: intent.callId,
      decline: declined.isEmpty ? null : declined.first.label,
    );
  }

  final String id;
  final String question;

  /// The plan body — carried in the question's `detail` as markdown.
  final String plan;

  /// The option label that means approve.
  final String approve;
  final String? callId;

  /// The other option's label, when the question offers one.
  final String? decline;
}

/// One answer item (`AskUserQuestionAnswerItem`).
///
/// `interaction/user-questions/src/types.ts:54-61`. `selected` is required and
/// may be empty; `custom` may **coexist** with selections (a multi-select with
/// an extra free-text addition).
class AskUserQuestionAnswerItem {
  const AskUserQuestionAnswerItem({
    required this.id,
    required this.selected,
    this.custom,
  });

  /// Omitting a question's id entirely is how "skip" is expressed — the
  /// protocol has no skip flag (§5.2), so skipping is a UI decision.
  factory AskUserQuestionAnswerItem.skipped(String id) =>
      AskUserQuestionAnswerItem(id: id, selected: const []);

  final String id;
  final List<String> selected;
  final String? custom;

  bool get isEmpty => selected.isEmpty && (custom == null || custom!.isEmpty);

  Map<String, dynamic> toJson() => {
        'id': id,
        'selected': selected,
        if (custom != null) 'custom': custom,
      };
}

/// The `outcome.value` of a question answer: `{answers: [...]}`.
class AskUserQuestionAnswer {
  const AskUserQuestionAnswer(this.answers);

  final List<AskUserQuestionAnswerItem> answers;

  Map<String, dynamic> toJson() => {
        'answers': answers.map((a) => a.toJson()).toList(growable: false),
      };
}

/// A `job` row (`JobView`) — the task-card fields.
///
/// `jobs/jobs/src/view.ts:65-99`. Note [jobId] comes from the wire's own `id`
/// (shaped `<kind>-N`), and the lifecycle is **five** states — `running` →
/// optional `stopping` → exactly one terminal state — so the three card states
/// are the terminal choice, not the whole story.
class JobView {
  const JobView({
    required this.jobId,
    required this.status,
    this.kind,
    this.label,
    this.owner,
    this.progress,
    this.detail,
    this.startedAt,
    this.finishedAt,
    this.failed = false,
  });

  factory JobView.fromJson(Map<String, dynamic> j) {
    final error = _obj(j['error']);
    return JobView(
      jobId: _str(j['id'], _str(j['jobId'])),
      status: _str(j['status'], 'unknown'),
      kind: j['kind'] as String?,
      label: j['label'] as String?,
      owner: j['owner'] as String?,
      progress: j['progress'] as String?,
      detail: (error?['name'] as String?) ?? j['detail'] as String?,
      startedAt: j['startedAt'] is num ? (j['startedAt']! as num).toInt() : null,
      finishedAt:
          j['finishedAt'] is num ? (j['finishedAt']! as num).toInt() : null,
      failed: error != null || j['status'] == 'failed',
    );
  }

  final String jobId;

  /// Wire status verbatim; [state] normalizes it for the card.
  final String status;

  /// Producer kind — an open string (`bash`, `subagent`, …), not an enum.
  final String? kind;
  final String? label;

  /// Owning session; absent means unowned and therefore visible to all.
  final String? owner;
  final String? progress;

  /// Why it ended — exit code, kill reason, or the error name.
  final String? detail;
  final int? startedAt;
  final int? finishedAt;
  final bool failed;

  /// The three card states the console renders.
  JobCardState get state {
    if (failed) return JobCardState.failed;
    switch (status) {
      case 'running':
      case 'stopping':
        return JobCardState.running;
      case 'completed':
      case 'killed':
        return JobCardState.done;
      case 'failed':
        return JobCardState.failed;
      default:
        return JobCardState.pending;
    }
  }

  /// Whether `job/kill` would still do anything.
  bool get isTerminal => state == JobCardState.done || state == JobCardState.failed;

  /// Best available display name.
  String get title {
    final label = this.label;
    if (label != null && label.isNotEmpty) return label;
    final kind = this.kind;
    if (kind != null && kind.isNotEmpty) return '$kind · $jobId';
    return jobId;
  }
}

enum JobCardState { pending, running, done, failed }

/// Identity and freshness of one workspace file, without its content.
///
/// `WorkspaceFileStat` (`api/workspace-files/src/types.ts:20-37`).
class WorkspaceFileStat {
  const WorkspaceFileStat({
    required this.absolutePath,
    required this.version,
    this.bytes,
  });

  factory WorkspaceFileStat.fromJson(Map<String, dynamic> j) => WorkspaceFileStat(
        absolutePath: _str(j['absolutePath']),
        // The version is an opaque freshness token: compared, never parsed.
        version: _str(j['version']),
        bytes: j['bytes'] is num ? (j['bytes']! as num).toInt() : null,
      );

  /// Absolute path in the filesystem's execution world, symlinks resolved.
  final String absolutePath;

  /// Opaque freshness token at stat time.
  final String version;

  /// Byte size, when the backend reports it.
  final int? bytes;
}

/// One page of a workspace text file (`WorkspaceFileText`).
class WorkspaceFileText extends WorkspaceFileStat {
  const WorkspaceFileText({
    required super.absolutePath,
    required super.version,
    super.bytes,
    required this.offset,
    required this.text,
    required this.lines,
    required this.eof,
  });

  factory WorkspaceFileText.fromJson(Map<String, dynamic> j) => WorkspaceFileText(
        absolutePath: _str(j['absolutePath']),
        version: _str(j['version']),
        bytes: j['bytes'] is num ? (j['bytes']! as num).toInt() : null,
        offset: _int(j['offset']),
        text: _str(j['text']),
        lines: _int(j['lines']),
        eof: _bool(j['eof']),
      );

  /// First line of the page, 1-based, as requested.
  final int offset;

  /// The page's lines joined by `\n`, with no terminator after the last one.
  final String text;

  /// How many lines the page holds; 0 when past the file's last line.
  final int lines;

  /// Whether the page includes the file's last line.
  final bool eof;

  /// Whether a further page exists behind this one.
  bool get hasMore => !eof;
}

/// What one listed child resolves to (`WorkspaceDirectoryEntry.type`).
enum WorkspaceEntryType { file, directory, other }

WorkspaceEntryType _workspaceEntryType(Object? v) => switch (v) {
      'directory' => WorkspaceEntryType.directory,
      'file' => WorkspaceEntryType.file,
      _ => WorkspaceEntryType.other,
    };

/// One direct child of a listed directory (`WorkspaceDirectoryEntry`).
class WorkspaceDirectoryEntry {
  const WorkspaceDirectoryEntry({
    required this.name,
    required this.type,
    this.size,
  });

  factory WorkspaceDirectoryEntry.fromJson(Map<String, dynamic> j) =>
      WorkspaceDirectoryEntry(
        name: _str(j['name']),
        type: _workspaceEntryType(j['type']),
        size: j['size'] is num ? (j['size']! as num).toInt() : null,
      );

  /// Basename inside the listed directory.
  final String name;

  /// A symlink reports its destination's type, and `other` covers everything
  /// that is neither a regular file nor a directory; `read` still refuses a
  /// symlink, so this is a listing fact, not a promise the content is
  /// readable.
  final WorkspaceEntryType type;

  /// Byte size, present only for a regular file.
  final int? size;

  bool get isDirectory => type == WorkspaceEntryType.directory;
}

/// Direct children of one workspace directory (`WorkspaceDirectoryListing`).
class WorkspaceDirectoryListing {
  const WorkspaceDirectoryListing({
    required this.path,
    required this.entries,
    required this.truncated,
  });

  factory WorkspaceDirectoryListing.fromJson(Map<String, dynamic> j) =>
      WorkspaceDirectoryListing(
        // `""` is the root itself — a real value, not a missing field.
        path: _str(j['path']),
        entries: (_arr(j['entries']) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(WorkspaceDirectoryEntry.fromJson)
            .toList(growable: false),
        truncated: _bool(j['truncated']),
      );

  /// The listed directory as a workspace path; a child's path is this joined
  /// with the child's [WorkspaceDirectoryEntry.name] by `/`.
  final String path;

  /// Direct children in the backend's stable name order.
  final List<WorkspaceDirectoryEntry> entries;

  /// Whether the entry cap dropped children.
  final bool truncated;

  /// The workspace path of one child of this directory.
  String pathOf(WorkspaceDirectoryEntry child) =>
      path.isEmpty ? child.name : '$path/${child.name}';
}

/// D-065: A human-readable name for a session row, or the id itself.
///
/// Priority:
/// 1. a curated projection title ([Projections.titleLike]) — the user named it;
/// 2. for scheduler sessions (`job-<task>-<YYYYMMDD>-<HHMMSS>`), the task name
///    plus a compact timestamp — the id *is* the metadata;
/// 3. the raw id, unchanged.
///
/// Returns the input unchanged (same instance semantics, not a copy) whenever
/// nothing better exists, so callers can `==` against the id to detect fallback.
String readableSessionName(SessionSummary summary) {
  final projected = summary.projections?.values.titleLike;
  if (projected != null) return _clamp(projected);

  // D-066: subagent children carry their run-time identity in
  // `values.subagent.label` — often the most descriptive string available
  // (e.g. 「中新赛克(002912)调查腿C：舆情时间线取证…」 on an otherwise
  // anonymous `e014bd3f-…` row). Clamp to one line: these labels run 80+
  // CJK chars and would wrap the row into three.
  final label = summary.projections?.values.subagent?.label?.trim();
  if (label != null && label.isNotEmpty) return _clamp(label);

  // D-065: scheduler ids encode task + time.
  final scheduler = _schedulerName(summary.sessionId);
  if (scheduler != null) return scheduler;

  return summary.sessionId;
}

/// One-line clamp for labels that were never designed to fit a row.
String _clamp(String value, [int limit = 30]) {
  if (value.length <= limit) return value;
  return '${value.substring(0, limit)}…';
}

/// Scheduler shape: `job-<task (may contain hyphens)>-<YYYYMMDD>-<HHMMSS>`.
final _schedulerId = RegExp(r'^job-(.+)-(\d{8})-(\d{6})$');

/// Scheduler-id → readable name, parsed defensively.
String? _schedulerName(String sessionId) {
  final m = _schedulerId.firstMatch(sessionId);
  if (m == null) return null;

  final task = m.group(1)!;
  final date = m.group(2)!;
  final time = m.group(3)!;

  // Defensive: a scheduler never emits 13-months or 90-seconds, but a
  // hand-crafted or renamed id passing the shape check shouldn't render as
  // "13-05 90:45". Anything non-parseable falls back to null (→ raw id).
  final month = int.tryParse(date.substring(4, 6));
  final day = int.tryParse(date.substring(6, 8));
  final hour = int.tryParse(time.substring(0, 2));
  final minute = int.tryParse(time.substring(2, 4));
  if (month == null || day == null || hour == null || minute == null) {
    return null;
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59) return null;

  final mm = month.toString().padLeft(2, '0');
  final dd = day.toString().padLeft(2, '0');
  final hh = hour.toString().padLeft(2, '0');
  final mi = minute.toString().padLeft(2, '0');
  return '$task · $mm-$dd $hh:$mi';
}

/// D-073: agent 预设摘要（`agentPresets/list` 的行）。
///
/// `broken` 非空 = 该 preset 的 persona/config 校验失败，引擎侧自己都标了
/// 坏——选择器里要可见但不可选（选了也会在回合开始时炸）。
class AgentPresetSummary {
  const AgentPresetSummary({
    required this.id,
    this.name,
    this.description,
    this.isDefault = false,
    this.broken,
    this.order = 1000,
  });

  factory AgentPresetSummary.fromJson(Map<String, dynamic> j) =>
      AgentPresetSummary(
        id: _str(j['id']),
        name: j['name'] as String?,
        description: j['description'] as String?,
        isDefault: j['isDefault'] == true,
        broken: j['broken'] as String?,
        order: (j['order'] as num?)?.toInt() ?? 1000,
      );

  final String id;

  /// 显示名；缺席时回落 [id]（standard/ptc/minimal 这批引擎内置 preset
  /// 实测只有 id，没有 name）。
  final String? name;
  final String? description;

  /// 引擎默认预设（实测 standard）。
  final bool isDefault;

  /// 配置校验失败的原因；非 null = 不可用。
  final String? broken;

  /// 展示排序键（实测 1~100，缺省排最后）。
  final int order;

  String get displayName => (name == null || name!.isEmpty) ? id : name!;
}

/// One row of `pluginManager/listPlugins` — the toggleable plugin roster.
///
/// `packages/boot/plugin-manager/src/index.ts:255` wraps a pluginInventory
/// entry with per-row capability: either `{patchId}` (the profile patch makes
/// this row switchable) or `{readOnlyReason}` (a protected/unaddressable row).
/// Real engine sample probed 2026-10-08:
/// `{"entryId":"include:tool-plugin-manager","moduleName":"@deepseek-ai/
/// dsh-plugin-manager/tools","enabled":false,"fiberPhase":null,
/// "patchId":"tool-plugin-manager"}`.
class PluginManagerEntry {
  const PluginManagerEntry({
    required this.entryId,
    required this.moduleName,
    required this.enabled,
    this.fiberPhase,
    this.patchId,
    this.readOnlyReason,
    this.titles = const {},
    this.descriptions = const {},
  });

  factory PluginManagerEntry.fromJson(Map<String, dynamic> j) {
    final meta = asObject(j['meta']);
    return PluginManagerEntry(
      entryId: _str(j['entryId']),
      moduleName: _str(j['moduleName']),
      enabled: j['enabled'] == true,
      fiberPhase: j['fiberPhase'] as String?,
      patchId: j['patchId'] as String?,
      readOnlyReason: j['readOnlyReason'] as String?,
      titles: localizedMeta(meta?['title']),
      descriptions: localizedMeta(meta?['description']),
    );
  }

  /// Engine metadata is **either** a flat string or a locale map
  /// (`{en: "Team Collaboration", zh: "团队协作"}`) — live-probed 2026-10-08,
  /// 4 of 193 rows use the map form; treating it as `as String?` crashed the
  /// Host pane (D-081 真机实证). Flat strings land under [defaultLocaleKey].
  static Map<String, String> localizedMeta(Object? v) {
    final flat = asObject(v);
    if (flat != null) {
      return {
        for (final e in flat.entries)
          if (e.value is String) e.key: e.value! as String,
      };
    }
    if (v is String && v.isNotEmpty) return {defaultLocaleKey: v};
    return const {};
  }

  static List<PluginManagerEntry> listFrom(Object? value) =>
      (asList(value) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PluginManagerEntry.fromJson)
          .toList(growable: false);

  final String entryId;
  final String moduleName;

  /// Live enablement state of the loader entry.
  final bool enabled;

  /// Loader phase (`active` on running rows), informational.
  final String? fiberPhase;

  /// The profile patch id that makes this row switchable; absent on rows the
  /// manager refuses to touch.
  final String? patchId;

  /// Why the row cannot be switched: `management-required` (protected core
  /// module) or `unaddressable` (no unique live loader entry).
  final String? readOnlyReason;

  /// Engine display metadata per locale (may be empty — then [moduleName]
  /// is shown).
  final Map<String, String> titles;
  final Map<String, String> descriptions;

  /// Switchable rows carry a patch; the rest show a lock with the reason.
  bool get switchable => patchId != null;

  /// Locale key for metadata the engine sends as a flat string.
  static const String defaultLocaleKey = '';

  /// locale → English → first present, or null.
  static String? pickLocale(Map<String, String> table, String locale) =>
      table[locale] ??
      table['en'] ??
      (table.isEmpty ? null : table.values.first);

  /// Localized title with `locale` → English → any → null.
  String? localizedTitle(String locale) =>
      titles[locale] ?? titles['en'] ?? (titles.isEmpty ? null : titles.values.first);

  /// What to render for [locale]: metadata title, else the module name.
  String displayName(String locale) {
    final t = localizedTitle(locale);
    return (t == null || t.isEmpty) ? moduleName : t;
  }
}

/// One row of `pluginManager/listBundles` — the bundle (installed package)
/// view, which is the human-facing unit: a bundle is what a user installed,
/// and its rows are its internal modules.
///
/// Live engine probe 2026-10-08: 16 rows, each
/// `{name, version, description, meta, enabled, installed, optional, removable,
/// readOnlyReason?, rows[]}` where a row is `{rowId, moduleName, entryId}`.
/// `management-required` marks the profile-provided core bundles
/// (`dsh-base`, `dsh-web-app`, `dsh-sdk-minimal`).
class PluginBundle {
  const PluginBundle({
    required this.name,
    required this.enabled,
    required this.installed,
    this.version,
    this.optional = false,
    this.removable = false,
    this.readOnlyReason,
    this.rows = const [],
    this.titles = const {},
    this.descriptions = const {},
  });

  factory PluginBundle.fromJson(Map<String, dynamic> j) {
    final meta = asObject(j['meta']);
    return PluginBundle(
      name: _str(j['name']),
      version: j['version'] as String?,
      enabled: j['enabled'] == true,
      installed: j['installed'] == true,
      optional: j['optional'] == true,
      removable: j['removable'] == true,
      readOnlyReason:
          j['readOnlyReason'] is String ? j['readOnlyReason'] as String : null,
      rows: (asList(j['rows']) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PluginBundleRow.fromJson)
          .toList(growable: false),
      titles: PluginManagerEntry.localizedMeta(meta?['title']),
      descriptions: PluginManagerEntry.localizedMeta(meta?['description']),
    );
  }

  static List<PluginBundle> listFrom(Object? value) =>
      (asList(value) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PluginBundle.fromJson)
          .toList(growable: false);

  final String name;
  final String? version;

  /// Whether the bundle is currently selected for this profile.
  final bool enabled;

  /// Present in `dependencies` (i.e. a real installed package, not merely
  /// offered by this dsh installation).
  final bool installed;

  /// Offered as an opt-in bundle by this installation.
  final bool optional;

  /// The installer may remove it (M2 UI stays read-only on this bit).
  final bool removable;

  final String? readOnlyReason;
  final List<PluginBundleRow> rows;
  final Map<String, String> titles;
  final Map<String, String> descriptions;

  /// Management-only bundles cannot be switched from any client.
  bool get switchable => readOnlyReason == null;

  String? localizedTitle(String locale) =>
      PluginManagerEntry.pickLocale(titles, locale);

  String? localizedDescription(String locale) =>
      PluginManagerEntry.pickLocale(descriptions, locale);

  String displayName(String locale) {
    final t = localizedTitle(locale);
    return (t == null || t.isEmpty) ? name : t;
  }
}

/// One internal module row inside a bundle (`rows[]` of listBundles).
class PluginBundleRow {
  const PluginBundleRow({required this.rowId, required this.moduleName, this.entryId});

  factory PluginBundleRow.fromJson(Map<String, dynamic> j) => PluginBundleRow(
        rowId: _str(j['rowId']),
        moduleName: _str(j['moduleName']),
        entryId: j['entryId'] as String?,
      );

  final String rowId;
  final String moduleName;
  final String? entryId;
}
