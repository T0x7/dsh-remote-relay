/// D-042 轨迹视图的记录模型。
///
/// 这一层刻意**不引入** dsh web 端那套 `ConversationNodeAssembler` / stage
/// builder：那边是 30 个文件加一个共享装配层，我们只有一条 `SessionWireEvent`
/// 事件流，从原始事件直接投影成行就够了，中间那层在我们这儿是纯开销。
///
/// 字段的**名字**沿用 dsh `ui-trajectory/src/client/trajectory-record.ts` 的
/// 叫法（`kind` / `lane` / `startedAt` / `requestNumber`），这样两边对同一段
/// 会话的理解可以直接对照。
library;

/// 一条记录的业务类别。取值域与 dsh `TrajectoryCellKind` 一致
/// （`trajectory-record.ts:9-16`）。
enum TrajectoryKind {
  /// 系统提示词 / 开发者消息 / hook 等注入内容。
  system,

  /// 用户消息。
  user,

  /// 上下文事件：`image/offload`、`todo/write`、`workspace/changes`、
  /// `hook/*`、`llm/retry`、`subagent/catalog` 等——有因果意义但不是操作。
  context,

  /// 压缩（compaction）请求产生的记录。
  compacted,

  /// 助手消息。
  message,

  /// 工具调用。
  tool,

  /// 嵌套子工具调用。
  subtool,
}

/// 记录所在的时间轨道。分轨规则照抄 dsh `timeline.ts:51-55`：
///
/// ```
/// function laneFor(kind) {
///   if (kind === 'tool' || kind === 'subtool') return 2
///   if (kind === 'message' || kind === 'compacted') return 1
///   return 0
/// }
/// ```
///
/// 注意 `user` 落在 lane 0 而不是和 `message` 同轨：用户消息没有自身耗时
/// （`startedAt` 为空），在 dsh 里压根不会被投影到时间轴上，lane 对它无意义。
/// 这里保持一致，免得手机上的三轨图和 dsh 对不上。
extension TrajectoryKindLane on TrajectoryKind {
  int get lane => switch (this) {
        TrajectoryKind.tool || TrajectoryKind.subtool => 2,
        TrajectoryKind.message || TrajectoryKind.compacted => 1,
        _ => 0,
      };
}

/// 一条轨迹记录。
///
/// [raw] 保留事件的完整 `data`，检查器原样展示——轨迹的意义就是能翻到
/// 机器载荷，摘要代替不了它。
class TrajectoryRecord {
  const TrajectoryRecord({
    required this.seq,
    required this.eventType,
    required this.kind,
    required this.time,
    this.preview,
    this.previewParts,
    required this.raw,
    this.turn,
    this.step,
    this.requestNumber,
    this.callId,
    this.toolName,
    this.isError = false,
    this.startedAt,
    this.durationMs,
    this.ttftMs,
    this.decodeMs,
    this.inputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.outputTokens,
    this.reasoningTokens,
    this.reasoningChars,
    this.provider,
    this.model,
  });

  /// 来源事件的 `seq`，跨视图定位的唯一稳定标识。
  final int seq;

  /// 事件的原始 `type`（如 `assistant/message`），直接显示在类型列。
  final String eventType;

  final TrajectoryKind kind;

  /// 事件的 `time`（epoch ms）。
  final int time;

  /// 单行内容预览。
  ///
  /// D-049: when the projection could not summarise a value, this is `null` and
  /// [previewParts] carries the pieces instead. The App layer assembles the
  /// sentence so the two connective words can come from `L10n`; a projection
  /// fold has no locale and putting Chinese here would ship it into the
  /// English UI.
  final String? preview;

  /// Structured fallback for [preview], when the record is a tool result the
  /// projection could not read.
  final TrajectoryRecordPreview? previewParts;

  /// 事件的完整 `data`。
  final Map<String, dynamic> raw;

  final int? turn;
  final int? step;

  /// 请求编号。普通生成请求与压缩请求**共用**一套编号（dsh 的明确决策：
  /// 「以用途区分而不是放入不同集合」）。
  final int? requestNumber;

  final String? callId;
  final String? toolName;
  final bool isError;

  /// 实际开始的 epoch ms；未知时为 null，**不拿 `time` 顶替**。
  final int? startedAt;

  /// 自身耗时（毫秒）。
  final int? durationMs;

  /// 首 token 延迟：从步骤开始到首个 token，含更早重试尝试里的输出。
  final int? ttftMs;

  /// 解码耗时：首 token 到末 token。
  final int? decodeMs;

  final int? inputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final int? outputTokens;
  final int? reasoningTokens;

  /// D-088：assistant/message 里 reasoning 块的正文长度（字符数）。
  /// 与 [reasoningTokens]（usage 计费口径）是两个数。null = 无思考块。
  final int? reasoningChars;

  /// `request/context` 记录的 provider / model。
  final String? provider;
  final String? model;

  /// 时间轴投影用的闭区间。`startedAt` 未知就不投影——**不虚构耗时**。
  ({int start, int end})? get span {
    final start = startedAt;
    if (start == null) return null;
    return (start: start, end: start + (durationMs ?? 0));
  }

  /// 检查器「计时」页的可用性：有起点或有时长其一就能显示。
  bool get hasTiming => startedAt != null || durationMs != null;

  /// 检查器「用量」页的可用性。
  bool get hasUsage =>
      inputTokens != null ||
      outputTokens != null ||
      reasoningTokens != null ||
      reasoningChars != null ||
      cacheReadTokens != null ||
      cacheWriteTokens != null;
}

/// 一个轮次（或一段轮次之外的压缩），是记录表的分组单位。
class TrajectoryTurn {
  const TrajectoryTurn({
    required this.records,
    this.turn,
    this.endReason,
    this.isError = false,
  });

  /// `null` 表示「轮次之间」的独立压缩段（dsh 里的 `Between turns`）。
  final int? turn;

  final List<TrajectoryRecord> records;

  /// `turn/end` 的 `reason.kind`。
  final String? endReason;

  final bool isError;

  int? get startedAt => records.isEmpty ? null : records.first.time;
}

/// 一次投影的完整结果。
class TrajectoryProjection {
  const TrajectoryProjection({
    required this.turns,
    required this.records,
    required this.hasEarlierHistory,
    required this.windowDropped,
  });

  static const empty = TrajectoryProjection(
    turns: [],
    records: [],
    hasEarlierHistory: false,
    windowDropped: 0,
  );

  final List<TrajectoryTurn> turns;

  /// 扁平的全部记录，按 `seq` 升序。时间轴和区间筛选走这条，不用翻树。
  final List<TrajectoryRecord> records;

  /// 引擎说还有更早的历史（follow 首帧的 `hasMore`）。
  final bool hasEarlierHistory;

  /// 因窗口上限被丢掉的记录条数。UI 必须如实报出来。
  final int windowDropped;
}

/// One tool-result row's summary.
///
/// D-049: the two words are **user-facing values**, not decoration — they land
/// in the record table and would render as Chinese inside an English UI.
///
/// The projection itself stays pure and locale-free: it emits the *parts* and
/// lets the App layer assemble the sentence (see
/// `TrajectoryRecordPreview.parts`), because a pure fold has no `L10n` and
/// threading one through would make every call site build-dependent. Words that
/// come from the wire (`toolName`, error name/code) never pass through here.
class TrajectoryRecordPreview {
  const TrajectoryRecordPreview._(this.errorName, this.errorCode, this.body);

  /// Not used outside this file; named so the public factories below read as
  /// the only way in.
  const TrajectoryRecordPreview.parts(this.errorName, this.errorCode, this.body);

  /// A failed call: the tool, the error's name and its code.
  factory TrajectoryRecordPreview.error(Object? name, Object? code) =>
      TrajectoryRecordPreview._(
        name?.toString() ?? '',
        code?.toString(),
        null,
      );

  /// A call that returned something the projection cannot summarise.
  factory TrajectoryRecordPreview.returned() =>
      const TrajectoryRecordPreview._('', null, null);

  final String errorName;
  final String? errorCode;

  /// The raw JSON body when there is one; null means "fell through".
  final String? body;

  bool get isError => errorName.isNotEmpty || errorCode != null;
}
