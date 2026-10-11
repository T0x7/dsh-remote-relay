import 'dart:convert';

import 'package:dsh_remote_core/api/engine_models.dart';

import 'trajectory_model.dart';

/// D-042 把一条会话事件流投影成轨迹记录。
///
/// 引擎侧**没有** trajectory 端点：轨迹是纯客户端投影，料全在
/// `session/follow` 的 `records` 和 `session/page` 的历史页里
/// （契约 §3.3 / §3.5 / §3.6）。所以这一层只做一件事——把 61 种事件
/// 收敛成 7 种 [TrajectoryKind] 的记录，并补上 dsh 时间轴要的计时。
///
/// 两条硬规则，都照抄引擎自己的口径：
///
/// - **不虚构耗时。** `startedAt` 未知就是 null，`span` 也就为 null，
///   时间轴不画这一条。宁可少画，不可假画。
/// - **子工具靠嵌套判定，不靠猜。** 一个 `tool/call` 到来时若栈上还有未
///   闭合的调用，它就是嵌套的子工具——这是线上唯一可靠的信号，事件表里
///   没有「parent callId」这种字段。
TrajectoryProjection projectTrajectory(
  List<SessionWireEvent> events, {
  bool hasEarlierHistory = false,
  int maxWindow = defaultLedgerWindow,
}) {
  if (events.isEmpty) {
    return TrajectoryProjection(
      turns: const [],
      records: const [],
      hasEarlierHistory: hasEarlierHistory,
      windowDropped: 0,
    );
  }

  // 窗口裁剪在折叠**之前**做：保留窗口是一段独立历史，轮次/步骤状态要从
  // 这段的开头重新起算，否则第一条记录会挂在一个不属于它的轮次下。
  var dropped = 0;
  var window = events;
  int? resumedTurn;
  if (events.length > maxWindow) {
    dropped = events.length - maxWindow;
    window = events.sublist(dropped);
    // 切口可能落在某个轮次中间，被丢掉的那个 `turn/start` 里带着**真**
    // 轮次号。把它捞回来，否则幸存记录会全部变成「轮次之间」——那是在
    // 谎报归属。捞的是轮次号，不是事件本身。
    for (var i = dropped - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type == 'turn/start') {
        resumedTurn = _intOf(e.dataObject['turn']);
        break;
      }
    }
  }
  // 丢掉的部分就是真存在的更早历史，标成 false 等于骗用户说没有。
  final earlier = hasEarlierHistory || dropped > 0;

  int? turn = resumedTurn;
  int? step;
  int? stepStartTime;
  var requestNo = 0;
  String? provider;
  String? model;
  final endReasons = <int, String>{};
  final failedTurns = <int>{};

  final out = <_Rec>[];
  final byCallId = <String, _Rec>{};
  final openCalls = <String>[];

  for (final event in window) {
    final data = event.dataObject;
    final seq = event.seq;
    final time = event.time;

    // 每�� case 单独加花括号：case 体共享同一个块作用域，不加会撞
    // `final callId` / `final rec` 这类重复声明。
    switch (event.type) {
      case 'turn/start':
        {
          turn = _intOf(data['turn']);
          step = null;
          stepStartTime = null;
        }
      case 'turn/end':
        {
          final t = _intOf(data['turn']) ?? turn;
          if (t != null) {
            final kind = asObject(data['reason'])?['kind'];
            if (kind is String) endReasons[t] = kind;
            if (kind == 'error' || kind == 'aborted') failedTurns.add(t);
          }
          // 轮次已经闭合，状态必须清空：留在 t 的话，**之后**到达的记录
          // （典型是轮次之间的独立压缩）会被挂到这个已结束的轮次下，而 dsh
          // 把它放在自己的 `Between turns` 段里。带显式 turn 字段的事件不受
          // 影响——那些走 `_intOf(data['turn']) ?? turn`，字段优先。
          turn = null;
          step = null;
          stepStartTime = null;
        }
      case 'step/start':
        {
          step = _intOf(data['step']);
          stepStartTime = time;
          turn ??= _intOf(data['turn']);
        }
      case 'step/end':
        {
          step = _intOf(data['step']);
          turn ??= _intOf(data['turn']);
        }

      // 普通生成请求与压缩请求共用一套编号（dsh 的明确决策：按用途区分，
      // 不拆成两个集合），所以这里和 compaction/start 走同一个计数器。
      case 'request/header':
        {
          requestNo++;
          provider = null;
          model = null;
        }
      case 'request/context':
        {
          final p = data['provider'];
          final m = data['model'];
          if (p is String) provider = p;
          if (m is String) model = m;
        }
      case 'user/message':
        {
          out.add(_Rec(
            seq: seq,
            eventType: event.type,
            kind: TrajectoryKind.user,
            time: time,
            preview: _textOf(data['content']),
            raw: data,
            turn: turn,
            step: step,
            requestNumber: requestNo == 0 ? null : requestNo,
            provider: provider,
            model: model,
          ));
        }
      case 'developer/message':
      case 'system/message':
        {
          out.add(_Rec(
            seq: seq,
            eventType: event.type,
            kind: TrajectoryKind.system,
            time: time,
            preview: _textOf(asObject(data['message'])?['content']),
            raw: data,
            turn: turn,
            step: step,
            requestNumber: requestNo == 0 ? null : requestNo,
            provider: provider,
            model: model,
          ));
        }
      case 'assistant/message':
        {
          final timing =
              _assistantTiming(asList(data['stream']), stepStartTime, time);
          final usage = asObject(data['usage']);
          final message = asObject(data['message']);
          out.add(_Rec(
            seq: seq,
            eventType: event.type,
            kind: TrajectoryKind.message,
            time: time,
            preview: _textOf(message?['content']),
            // D-088：思考随 assistant/message 落库（reasoning 块），
            // 轨迹记账同样留痕——与 usage 的 reasoningTokens（计费口径）
            // 是两个数：这里是正文块字符数。
            reasoningChars: _reasoningCharsOf(message?['content']),
            raw: data,
            turn: _intOf(data['turn']) ?? turn,
            step: _intOf(data['step']) ?? step,
            requestNumber: requestNo == 0 ? null : requestNo,
            // dsh 口径（契约 §8.3 的 sessionStats 同款）：`ttftMs` 自
            // `step/start` 到首个 token（含更早重试里的输出），`decodeMs`
            // 从首 token 到 `assistant/message`。
            startedAt: stepStartTime,
            durationMs:
                stepStartTime == null ? null : time - stepStartTime,
            ttftMs: timing.ttftMs,
            decodeMs: timing.decodeMs,
            inputTokens: _intOf(usage?['inputTokens']),
            cacheReadTokens: _intOf(usage?['cacheReadTokens']),
            cacheWriteTokens: _intOf(usage?['cacheWriteTokens']),
            outputTokens: _intOf(usage?['outputTokens']),
            reasoningTokens: _intOf(usage?['reasoningTokens']),
            provider: provider,
            model: model,
          ));
        }
      case 'tool/call':
        {
          final callId = data['callId'];
          final name = data['name'];
          final rec = _Rec(
            seq: seq,
            eventType: event.type,
            // 栈上还有未闭合的调用，说明这次调用发生在另一次调用的执行期里。
            kind: openCalls.isEmpty
                ? TrajectoryKind.tool
                : TrajectoryKind.subtool,
            time: time,
            preview: name is String ? name : 'tool',
            raw: data,
            turn: _intOf(data['turn']) ?? turn,
            step: _intOf(data['step']) ?? step,
            requestNumber: requestNo == 0 ? null : requestNo,
            callId: callId is String ? callId : null,
            toolName: name is String ? name : null,
            startedAt: time,
            provider: provider,
            model: model,
          );
          out.add(rec);
          if (callId is String) {
            byCallId[callId] = rec;
            openCalls.add(callId);
          }
        }
      case 'tool/result':
        {
          final callId = data['callId'];
          final rec = callId is String ? byCallId[callId] : null;
          final error = asObject(data['error']);
          if (rec != null) {
            final started = rec.startedAt;
            rec
              ..isError = error != null
              // 结果挂到调用记录上，检查器一次就能看完「发起了什么、回 了
              // 什么」；结果本身另起一行，下面单独讲。
              ..raw = {...rec.raw, 'result': data};
            if (started != null) rec.durationMs = time - started;
            final id = rec.callId;
            if (id != null) openCalls.remove(id);
          }
          final parts = _resultPreview(data, rec?.toolName);
          out.add(_Rec(
            seq: seq,
            eventType: event.type,
            kind: TrajectoryKind.context,
            time: time,
            preview: parts.body,
            previewParts: parts.body == null ? parts : null,
            raw: data,
            turn: _intOf(data['turn']) ?? turn,
            step: _intOf(data['step']) ?? step,
            requestNumber: requestNo == 0 ? null : requestNo,
            callId: callId is String ? callId : null,
            toolName: rec?.toolName,
            isError: error != null,
            provider: provider,
            model: model,
          ));
        }
      case 'compaction/start':
        {
          requestNo++;
          out.add(_Rec(
            seq: seq,
            eventType: event.type,
            kind: TrajectoryKind.compacted,
            time: time,
            preview: 'compaction',
            raw: data,
            turn: turn,
            step: step,
            requestNumber: requestNo,
            startedAt: time,
            provider: provider,
            model: model,
          ));
        }
      case 'compaction/end':
        {
          for (var i = out.length - 1; i >= 0; i--) {
            final rec = out[i];
            if (rec.kind == TrajectoryKind.compacted &&
                rec.durationMs == null) {
              final started = rec.startedAt;
              if (started != null) rec.durationMs = time - started;
              rec.raw = {...rec.raw, 'summary': asObject(data['summary'])};
              break;
            }
          }
        }
      case 'compaction/summary':
        {
          // 摘要挂在压缩记录上，不单独成行——它是压缩的内容，不是第四种操作。
          final text = _defaultPreview(data);
          for (var i = out.length - 1; i >= 0; i--) {
            final rec = out[i];
            if (rec.kind == TrajectoryKind.compacted) {
              if (text.isNotEmpty) rec.preview = text;
              rec.raw = {...rec.raw, 'summary': data};
              break;
            }
          }
        }
      default:
        {
          // 61 种事件里剩下的、以及未来引擎新增的类型，一律留成 context 行：
          // 轨迹的第一职责是「不丢东西」，不认识不等于可以扔。
          out.add(_Rec(
            seq: seq,
            eventType: event.type,
            kind: TrajectoryKind.context,
            time: time,
            preview: _defaultPreview(data),
            raw: data,
            turn: turn,
            step: step,
            requestNumber: requestNo == 0 ? null : requestNo,
            provider: provider,
            model: model,
          ));
        }
    }
  }

  return _group(out, endReasons, failedTurns, earlier, dropped);
}

/// 把扁平记录按轮次切段。
///
/// 切点就是 `turn` 值变化的地方。轮次之外的压缩（`turn == null`）自然成为
/// 自己的一段——这正是 dsh 里的 `Between turns`。
TrajectoryProjection _group(
  List<_Rec> out,
  Map<int, String> endReasons,
  Set<int> failedTurns,
  bool hasEarlierHistory,
  int dropped,
) {
  final records = [for (final rec in out) rec.freeze()];
  final turns = <TrajectoryTurn>[];
  var index = 0;
  while (index < records.length) {
    final turnNo = records[index].turn;
    var end = index;
    while (end < records.length && records[end].turn == turnNo) {
      end++;
    }
    final slice = records.sublist(index, end);
    turns.add(TrajectoryTurn(
      turn: turnNo,
      records: slice,
      endReason: turnNo == null ? null : endReasons[turnNo],
      isError: turnNo != null && failedTurns.contains(turnNo),
    ));
    index = end;
  }
  return TrajectoryProjection(
    turns: turns,
    records: records,
    hasEarlierHistory: hasEarlierHistory,
    windowDropped: dropped,
  );
}

/// 保留窗口上限。轨迹要在手机上滚动，事件又普遍不大，但 `tool/result`
/// 的载荷可以很大——定一个上限并把丢了多少如实报出来，好过无界增长。
const int defaultLedgerWindow = 500;

/// `assistant/message` 的计时。
///
/// `AssistantStreamRecord` 的紧凑格式（`llm/llm/src/assistant-stream.ts:20-45`）
/// 是：`time0` 是**第一个** chunk 的绝对时刻，`dt[i]` 是第 i 到 i+1 个 chunk
/// 的间隔（还原见同文件 `:211-213`）。所以 chunk i 的绝对时刻是
/// `time0 + sum(dt[0..i-1])`。
///
/// 口径照引擎自己的 `sessionStats`（契约 §8.3）：
/// `ttftMs` = `step/start` → 首个 token（含更早重试尝试中的输出）；
/// `decodeMs` = 首个 token → `assistant/message`。
({int? ttftMs, int? decodeMs}) _assistantTiming(
  List<Object?>? stream,
  int? stepStartTime,
  int messageTime,
) {
  if (stream == null || stream.isEmpty) {
    // 没有 chunk 就只有一个已知端点，任何一段耗时都是编的。
    return (ttftMs: null, decodeMs: null);
  }
  int? firstToken;
  for (final entry in stream) {
    final record = asObject(entry);
    if (record == null) continue;
    final type = record['type'];
    if (type == 'chunk') {
      // 未打包的原始 chunk 自带绝对 time。
      final t = _intOf(record['time']);
      if (t != null && (firstToken == null || t < firstToken)) firstToken = t;
      continue;
    }
    if (type != 'text-chunks' &&
        type != 'reasoning-chunks' &&
        type != 'tool-call-chunks') {
      continue;
    }
    final time0 = _intOf(record['time0']);
    if (time0 != null && (firstToken == null || time0 < firstToken)) {
      firstToken = time0;
    }
  }
  if (firstToken == null) return (ttftMs: null, decodeMs: null);
  return (
    ttftMs: stepStartTime == null ? null : firstToken - stepStartTime,
    decodeMs: messageTime - firstToken,
  );
}

/// 折叠期的可变记录，最后 freeze 成不可变值。
class _Rec {
  _Rec({
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

  final int seq;
  final String eventType;
  final TrajectoryKind kind;
  final int time;
  String? preview;
  TrajectoryRecordPreview? previewParts;
  Map<String, dynamic> raw;
  final int? turn;
  final int? step;
  final int? requestNumber;
  final String? callId;
  final String? toolName;
  bool isError;
  int? startedAt;
  int? durationMs;
  int? ttftMs;
  int? decodeMs;
  int? inputTokens;
  int? cacheReadTokens;
  int? cacheWriteTokens;
  int? outputTokens;
  int? reasoningTokens;
  int? reasoningChars;
  final String? provider;
  final String? model;

  TrajectoryRecord freeze() => TrajectoryRecord(
        seq: seq,
        eventType: eventType,
        kind: kind,
        time: time,
        preview: preview,
        previewParts: previewParts,
        raw: raw,
        turn: turn,
        step: step,
        requestNumber: requestNumber,
        callId: callId,
        toolName: toolName,
        isError: isError,
        startedAt: startedAt,
        durationMs: durationMs,
        ttftMs: ttftMs,
        decodeMs: decodeMs,
        inputTokens: inputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens,
        outputTokens: outputTokens,
        reasoningTokens: reasoningTokens,
        reasoningChars: reasoningChars,
        provider: provider,
        model: model,
      );
}

/// D-088: 数 `content` 里 reasoning 块的正文长度——轨迹记账用，
/// 与 usage 的 reasoningTokens（计费口径）是两个数。
int? _reasoningCharsOf(Object? content) {
  if (content is! List) return null;
  final total = content
      .map(asObject)
      .whereType<Map<String, dynamic>>()
      .where((block) => block['type'] == 'reasoning')
      .fold(0, (sum, block) => sum + (block['text'] as String? ?? '').length);
  return total > 0 ? total : null;
}

/// 拼 `content` 里的 text 块。
String _textOf(Object? content) {
  if (content is! List) return '';
  return content
      .map(asObject)
      .whereType<Map<String, dynamic>>()
      .where((block) => block['type'] == 'text')
      .map((block) => block['text'])
      .whereType<String>()
      .where((text) => text.isNotEmpty)
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

TrajectoryRecordPreview _resultPreview(
  Map<String, dynamic> data,
  String? toolName,
) {
  final error = asObject(data['error']);
  if (error != null) {
    return TrajectoryRecordPreview.error(error['name'], error['code']);
  }
  final message = asObject(data['message']);
  final text = _textOf(message?['content']);
  if (text.isNotEmpty) return TrajectoryRecordPreview.parts('', null, text);
  if (message != null && message.isNotEmpty) {
    return TrajectoryRecordPreview.parts('', null, jsonEncode(message));
  }
  return TrajectoryRecordPreview.returned();
}


/// 未专门识别的事件的单行摘要。
///
/// 刻意做得保守：认得出的字段就取一个，认不出就只给事件类型。宁可预览
/// 平淡，也不要在这里编一段看起来像内容的东西。
String _defaultPreview(Map<String, dynamic> data) {
  for (final key in const ['summary', 'text', 'reason', 'name', 'mode']) {
    final value = data[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return '';
}

int? _intOf(Object? v) => v is num ? v.toInt() : null;
