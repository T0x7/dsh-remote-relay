import 'dart:async';
import 'dart:convert';

import 'package:dsh_remote_core/api/engine.dart';
import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_mux.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:flutter/foundation.dart';

import '../../services/app_lifecycle_gate.dart';
import '../../services/job_completion_watcher.dart';
import '../../services/reminder_router.dart';
import '../trajectory/trajectory_ledger.dart';
import '../workspaces/session_title_cache.dart';

/// One rendered turn in the conversation flow (mockup 屏 E).
///
/// A pure projection of wire events: the bubble list never parses JSON, and
/// the extraction rules are unit-testable without a widget tree.
sealed class ChatBubble {
  const ChatBubble();
}

/// A message the user sent, or the agent replied with.
class ChatMessage extends ChatBubble {
  const ChatMessage({
    required this.seq,
    required this.fromUser,
    required this.text,
    required this.time,
    this.subagentLabel,
    this.streaming = false,
    this.reasoningText,
  });

  final int seq;
  final bool fromUser;
  final String text;
  final DateTime time;

  /// Set when the message came from a subagent — rendered as a lineage chip
  /// (which subagent produced this line), per the web conversation view.
  final String? subagentLabel;

  /// D-034: true while the row is a live `assistant-stream` attempt that the
  /// durable `assistant/message` event has not superseded yet.
  final bool streaming;

  /// D-069: 本行的思考内容。流式行来自 reasoning-delta 帧；D-088 起
  /// durable 行也带——引擎 0.2.0-rc.2 起把 reasoning 作为
  /// `assistant/message.content[]` 的独立块落库（实测 347/1300 字等多份，
  /// `reasoningEffort=max`），旧结论「journal 全是纯 text 块」已过时。
  final String? reasoningText;
}

/// D-034: the attempt whose tokens are arriving right now.
class _LiveAttempt {
  _LiveAttempt({
    required this.attemptId,
    required this.turn,
    required this.step,
  }) : startedAt = DateTime.now();

  final String attemptId;
  final int turn;
  final int step;
  final DateTime startedAt;
  final StringBuffer _text = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();

  String get text => _text.toString();

  String get reasoning => _reasoning.toString();

  void append(String delta) => _text.write(delta);

  void appendReasoning(String delta) => _reasoning.write(delta);
}

/// D-070: `tool/call` 的前向记录——result 到达时凑成一行完整工具节点。
class ToolCallInfo {
  const ToolCallInfo(this.name, this.arguments);

  final String name;

  /// 原样保留的参数 JSON 字符串（journal 实测就是字符串形态，且含可读
  /// CJK；非字符串形态的防御性 jsonEncode）。
  final String arguments;
}

/// A tool call or result, simplified for the phone: what ran, and whether it
/// failed. The full transcript stays in the team page (屏 N).
///
/// D-070: `arguments`（call 的参数 JSON 原样）与 `result`（result 消息的
/// text 块拼接，截断）随行保存——手机上点工具行展开详情，不用再开电脑。
class ToolNode extends ChatBubble {
  const ToolNode({
    required this.seq,
    required this.name,
    this.failed = false,
    this.detail,
    this.arguments,
    this.result,
  });

  final int seq;
  final String name;
  final bool failed;
  final String? detail;
  final String? arguments;
  final String? result;
}

/// A pending approval waterfall, rendered as an inline card.
class PendingApproval extends ChatBubble {
  const PendingApproval({required this.eventId, required this.request});

  final String eventId;
  final ApprovalRequest request;
}

/// A pending question batch. A plan review is the single-question special
/// case, not a separate flow.
class PendingQuestion extends ChatBubble {
  const PendingQuestion({required this.eventId, required this.questions, this.planReview});

  final String eventId;
  final List<AskUserQuestionItem> questions;

  /// Non-null when the payload met all six plan-review conditions.
  final PlanReview? planReview;
}

/// An engine failure rendered inline (L2, design §7.2).
class ErrorNotice extends ChatBubble {
  const ErrorNotice(this.error);
  final AppError error;
}

/// Projection of wire events into bubbles.
///
/// The five surface event types are the ones the contract allows to carry a
/// `surfaceOp` (`core/session/src/types.ts:447-453`); everything else is
/// bookkeeping the phone deliberately does not render.
///
/// [toolCalls] carries `tool/call` → (name, arguments) forward so a `tool/result` can be
/// labelled. The result event itself has **no** `name` — verified against a
/// real session on 2026-10-02, where `tool/result` data is exactly
/// `{turn, step, message}` and `message` is a content-block message. Reading
/// a name off the result yields the literal fallback for every real call.
abstract final class ChatEventReader {
  static List<ChatBubble> bubblesOf(
    SessionWireEvent event, {
    String? subagentLabel,
    Map<String, ToolCallInfo>? toolCalls,
  }) {
    switch (event.type) {
      case 'user/message':
        final text = _textOf(event.dataObject['content']);
        if (text.isEmpty) return const [];
        return [ChatMessage(
          seq: event.seq,
          fromUser: true,
          text: text,
          time: _timeOf(event.time),
        )];
      case 'assistant/message':
        final message = asObject(event.dataObject['message']) ?? const {};
        final text = _textOf(message['content']);
        if (text.isEmpty) return const [];
        return [ChatMessage(
          seq: event.seq,
          fromUser: false,
          text: text,
          time: _timeOf(event.time),
          subagentLabel: subagentLabel,
          // D-088：reasoning 块随 assistant/message 落库（引擎 0.2.0-rc.2
          // 起），durable 气泡据此渲染「已思考 · N 字」chip，历史可回看。
          // reasoning+tool-call 且无 text 的消息仍不产气泡——那轮的输出
          // 由 tool 节点承载，不为凑 chip 造空卡。
          reasoningText: _reasoningOf(message['content']),
        )];
      case 'tool/call':
        // No bubble of its own: the matching result carries the node, and a
        // call/result pair is one line in the conversation, not two.
        // D-070: arguments 随名字一起前向记录，result 到达时凑成完整节点。
        final callId = event.dataObject['callId'];
        final name = event.dataObject['name'];
        if (toolCalls != null && callId is String && name is String) {
          final rawArgs = event.dataObject['arguments'];
          final argsString = switch (rawArgs) {
            final String s => s,
            null => '',
            final Object? other => jsonEncode(other),
          };
          toolCalls[callId] = ToolCallInfo(name, argsString);
        }
        return const [];
      case 'tool/result':
        final error = asObject(event.dataObject['error']);
        // D-093：callId 在 `message.toolCallId` 里，不在顶层。
        //
        // 引擎契约（session-controller 的 SessionEventMap）：
        //   'tool/result': { turn, step, message: ToolResultMessage, error?, meta? }
        //   ToolResultMessage.toolCallId —— 「Provider-issued id of the tool
        //   call this message answers」。
        //
        // 之前从 `dataObject['callId']` 读，顶层根本没有这个键 → 永远是 null →
        // 前向记录 `toolCalls[callId]` 匹配不上 → name 落到默认的 'tool' →
        // 界面再把 'tool' 过滤掉。合起来的效果是：**真机上每一条工具调用都
        // 不显示工具名**，只剩一串参数摘要（轨迹页读 `data.name` 所以不受影响，
        // 于是同一份数据在两屏上表现不一致）。
        final resultMessage = asObject(event.dataObject['message']);
        final callId = resultMessage?['toolCallId'];
        String name = 'tool';
        String? arguments;
        // D-070: `?[` 在三元分支里有解析歧义（`toolCalls?` 会被当可空类型），
        // 用 if 语句取值，别"聪明"。
        ToolCallInfo? info;
        if (callId is String) info = toolCalls?[callId];
        if (info != null) {
          name = info.name;
          arguments = info.arguments;
        }
        // D-070: 结果取 result 消息的 text 块拼接，截断到 8000 字——详情
        // 面板是可滚动的，超长结果的尾部在手机上也没有阅读价值。
        String? result;
        if (resultMessage != null) {
          final text = _textOf(resultMessage['content']);
          if (text.isNotEmpty) {
            // 截断后缀用 U+2026 而非中文括号文案——i18n 守卫禁止 lib/ 出现
            // CJK 字面量，且这里是静态类拿不到 l10n。
            result = text.length > 8000 ? '${text.substring(0, 8000)}…' : text;
          }
        }
        return [ToolNode(
          seq: event.seq,
          name: name,
          failed: error != null,
          detail: error?['name'] as String?,
          arguments: (arguments == null || arguments.isEmpty) ? null : arguments,
          result: result,
        )];
      case 'system/message':
      case 'developer/message':
        final text = _textOf(event.dataObject['message']);
        if (text.isEmpty) return const [];
        return [ChatMessage(
          seq: event.seq,
          fromUser: false,
          text: text,
          time: _timeOf(event.time),
        )];
      default:
        return const [];
    }
  }

  /// Join the `text` blocks of a ContentBlock list; non-text blocks (images,
  /// tool calls) contribute nothing to the plain-text bubble.
  static String _textOf(Object? content) {
    if (content is! List) return '';
    return content
        .map(asObject)
        .whereType<Map<String, dynamic>>()
        .where((block) => block['type'] == 'text')
        .map((block) => block['text'] as String? ?? '')
        .where((text) => text.isNotEmpty)
        .join('\n')
        .trim();
  }

  /// D-088: join the `reasoning` blocks of a ContentBlock list — the
  /// engine's persisted thinking (0.2.0-rc.2+, `reasoningEffort > 0`).
  /// Absent on older journals → null, and the pane renders no chip.
  static String? _reasoningOf(Object? content) {
    if (content is! List) return null;
    final reasoning = content
        .map(asObject)
        .whereType<Map<String, dynamic>>()
        .where((block) => block['type'] == 'reasoning')
        .map((block) => block['text'] as String? ?? '')
        .where((text) => text.isNotEmpty)
        .join('\n\n')
        .trim();
    return reasoning.isEmpty ? null : reasoning;
  }

  static DateTime _timeOf(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms);
}

/// Drives one machine's console: the session journal, its live projections,
/// and the approval / question waterfalls waiting for an answer.
///
/// Owns the two streams a conversation needs (`session/follow` and
/// `$events`) and keeps them torn down when the machine or session changes,
/// so switching machines never leaves an orphan stream writing into a dead
/// view.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.gateway,
    this.eventsRefreshInterval = const Duration(seconds: 60),
    this.answerReadyTimeout = const Duration(seconds: 5),
    this.machineId,
    AppLifecycleGate? lifecycle,
    ReminderRouter? reminders,
    this.titles,
  })  : _lifecycle = lifecycle ?? AppLifecycleGate.instance,
        _reminders = reminders ?? ReminderRouter.instance {
    _lifecycle.addListener(_onLifecycle);
    _watchCarrier();
  }

  final EngineGateway gateway;

  /// D-059: 打开过的会话的标题会记在这里，好让工作区列表能显示它而不是 id。
  /// null = 不记（默认），测试与不需要的调用方不必提供。
  final SessionTitleCache? titles;

  /// D-032: how often the `$events` stream is re-opened to defeat the relay's
  /// deaf long-lived carrier. Injectable for tests; `Duration.zero` disables
  /// the refresh timer entirely (widget tests).
  final Duration eventsRefreshInterval;

  /// The machine this console is bound to, when the caller knows it. Null keeps
  /// the console's own carrier a cause of its own in the reminder router.
  final String? machineId;

  final AppLifecycleGate _lifecycle;
  final ReminderRouter _reminders;

  /// The app-wide gate this controller obeys (design §5「切后台即断 WS」).
  @visibleForTesting
  AppLifecycleGate get lifecycle => _lifecycle;

  /// Whether the controller is currently parked because the app is in the
  /// background: streams down, carrier closed.
  @visibleForTesting
  bool get suspended => _suspended;

  String? _sessionId;
  String? _headerTitle;

  /// D-076: 本会话所属的 agent 预设（journal 首帧 header 自带）。null =
  /// 引擎没给，不编造。展示在 ContextBar，回答「这个会话由哪种 agent 处理」。
  String? _sessionPreset;
  String? get sessionPreset => _sessionPreset;
  List<ChatBubble> _bubbles = [];

  /// D-034: the attempt currently streaming tokens, or null.
  ///
  /// `assistant-stream` frames carry no seq and never enter [_bubbles]; the
  /// durable `assistant/message` event that supersedes them arrives only when
  /// the attempt ends. The live attempt therefore lives here and is projected
  /// into [bubbles] as a trailing [ChatMessage] while it is active.
  _LiveAttempt? _live;
  SessionProjectionBaseline? _projections;
  String? _subagentLabel;

  /// D-099: the parent half of the current subagent address, remembered so a
  /// background/resume re-open can rebuild the pair. Null for plain sessions.
  String? _parentSessionId;
  bool _loading = false;

  /// D-058: 首帧等待上限。
  ///
  /// 引擎对重会话的 `session/follow` 首帧实测 20s+（`session/projections`
  /// 单条 125s），而 mux 的 `_onFrame` 对未注册/已取消的流是**静默 return**
  /// （`engine_mux.dart:468`），连 error 都不发。所以「流活着但一帧不来」在
  /// 原实现里就是**永远 loading**：`_loading` 只在收到首帧或流报错时清除。
  ///
  /// 引擎慢是引擎的锅，但**慢和死在界面上长得一模一样**——都是转圈。把它
  /// 分开是 App 的活：到这个时间还没首帧，就停下来、说清楚、并允许重试。
  static const firstFrameTimeout = Duration(seconds: 45);

  Timer? _firstFrameTimer;

  /// 属于本次 `open` 的会话 id。定时器只对它有效——切走得快时，旧会话的
  /// 定时器仍在飞，到点后会把**新**会话错误地判成超时并弹一个假错误。
  String? _firstFrameTimerFor;
  bool _sending = false;
  AppError? _error;
  SessionEventStream? _journal;
  StreamSubscription<SessionFollowFrame>? _journalSub;
  StreamSubscription<Object?>? _journalErrorSub;
  StreamSubscription<Object?>? _eventSub;
  MuxStream? _eventStream;
  Timer? _eventsRefreshTimer;

  /// D-034: token frames arrive many times a second, so listener wake-ups are
  /// coalesced into one paint window instead of one per token.
  static const Duration _streamPaintInterval = Duration(milliseconds: 48);
  Timer? _streamPaint;

  /// D-032: how often the `$events` stream is re-opened to defeat the relay's
  /// deaf long-lived carrier (see the constructor).
  bool _disposed = false;
  String? _clientId;

  /// Completes when the current `$events` generation publishes `ready`.
  /// Armed by every (re)open; the answer path awaits it so an approval never
  /// rides a dead generation (D-078).
  Completer<void>? _readySignal;

  /// Upper bound for waiting on a fresh generation while settling an answer.
  /// Injectable so widget tests keep their post-test timer audit.
  final Duration answerReadyTimeout;

  /// design §5: the app is in the background and the console owns nothing.
  bool _suspended = false;

  /// Whether the opening snapshot for [_sessionId] has been projected. The
  /// second one on the same journal is a **re-baseline**, not a continuation.
  bool _journalBaselined = false;

  /// T1.12: the console's own `job/list` watch. The 屏 F pane is not the source
  /// for a completion prompt — the user is by definition somewhere else when a
  /// task finishes — so the console watches its own session and routes the
  /// terminal transition into the shared router.
  final JobCompletionWatcher _jobWatcher = JobCompletionWatcher();
  MuxStream? _jobsStream;
  StreamSubscription<Object?>? _jobsSub;

  /// D-049: the carrier state, so a tunnel drop becomes a reminder and the
  /// suspend/resume teardown can tell a real outage from its own doing.
  StreamSubscription<MuxState>? _carrierSub;
  MuxState? _lastCarrierState;

  /// `tool/call` callId → tool name, so a later `tool/result` can be labelled.
  final Map<String, ToolCallInfo> _toolCalls = {};

  String? get sessionId => _sessionId;
  String? get title => _headerTitle;

  /// The rendered conversation: settled events, then the live attempt.
  ///
  /// D-034 appends the in-flight assistant row last so the list reads in wire
  /// order without the transient frames ever being stored.
  List<ChatBubble> get bubbles {
    final live = _live;
    // An attempt that has produced neither text nor reasoning draws nothing:
    // an empty bubble would be a blank card between the question and the
    // first token. D-069: reasoning-only 阶段（思考先于答案）也要上屏。
    if (live == null || (live.text.isEmpty && live.reasoning.isEmpty)) {
      return _bubbles;
    }
    return [
      ..._bubbles,
      ChatMessage(
        // The wire gives transient frames no seq; -1 is the engine's own
        // "empty log" sentinel and the row is never correlated by seq.
        seq: -1,
        fromUser: false,
        text: live.text,
        time: live.startedAt,
        subagentLabel: _subagentLabel,
        streaming: true,
        reasoningText: live.reasoning.isEmpty ? null : live.reasoning,
      ),
    ];
  }

  SessionProjectionBaseline? get projections => _projections;

  /// D-071: 模型已被请求但还没有任何可上屏的输出（正文/思考都未到）。
  /// 会话里这时该有一颗「正在思考」指示器，而不是一段死寂。
  ///
  /// - `_sending`：prompt RPC 在途；
  /// - 流式行已开但正文/思考皆空：回合被引擎接受、首 token 未到；
  /// - 兜底：最后一泡是**刚发的**（<3 分钟）用户消息——流式行还没开的间隙。
  ///   超过 3 分钟视为回合已被引擎中断的死会话，不显示：对尸体转圈比死寂糟。
  bool get modelWorkingSilently {
    if (_sending) return true;
    final live = _live;
    if (live != null) return live.text.isEmpty && live.reasoning.isEmpty;
    final bubbles = this.bubbles;
    if (bubbles.isEmpty) return false;
    final last = bubbles.last;
    if (last is ChatMessage && last.fromUser) {
      final age = DateTime.now().difference(last.time);
      return !age.isNegative && age < const Duration(minutes: 3);
    }
    return false;
  }
  bool get loading => _loading;
  bool get sending => _sending;
  AppError? get error => _error;

  /// The pending approval card, or null.
  PendingApproval? get pendingApproval {
    for (final bubble in _bubbles.reversed) {
      if (bubble is PendingApproval) return bubble;
    }
    return null;
  }

  /// The pending question card, or null.
  PendingQuestion? get pendingQuestion {
    for (final bubble in _bubbles.reversed) {
      if (bubble is PendingQuestion) return bubble;
    }
    return null;
  }

  /// Open [sessionId] (null to clear), replacing any open journal.
  ///
  /// [subagentLabel] marks the conversation as a child's, which both tags
  /// messages with lineage and drives the read-only composer.
  Future<void> open(
    String? sessionId, {
    String? subagentLabel,
    SubagentMode mode = SubagentMode.continuable,
    String? parentSessionId,
  }) async {
    await _closeJournal();
    // D-041: `open` is deliberately NOT awaited in front of the navigation
    // that triggers it, so this await is now a real window in which the
    // console can go away (tab switch, machine change, route teardown).
    // Everything below re-sends `notifyListeners`, which throws on a disposed
    // controller — bail before touching any of it.
    if (_disposed) return;
    _sessionId = sessionId;
    _subagentLabel = subagentLabel;
    // D-099: the parent half of a subagent address must survive a
    // background/resume cycle — `_resumeFromBackground` re-opens the journal
    // and without this it would rebuild the address with parent = child id,
    // which the engine answers with `subagent/unauthorized` (真机 15:01 实测:
    // 回前台后子会话 45s 无首帧，恢复路径正是这个地址).
    _parentSessionId = parentSessionId;
    _bubbles = [];
    // D-042: 轨迹账本跟着会话走。换会话必须连它一起换，否则轨迹会显示
    // 上一段会话的事件——而两边看起来是同一个控制台页。
    _ledger.clear();
    // D-034: a stream belongs to the session it started in; switching machines
    // must not carry the previous conversation's live row over.
    _live = null;
    _projections = null;
    _error = null;
    _readOnly = mode;
    // A brand-new journal has not been baselined yet: its first snapshot is an
    // opening frame, not the re-baseline of a lost carrier.
    _journalBaselined = false;
    _jobWatcher.reset();
    // D-076: 无论新会话是否有 id，上一个会话的 agent 预设都不能泄漏过来。
    _sessionPreset = null;
    if (sessionId == null) {
      _headerTitle = null;
      notifyListeners();
      return;
    }

    _loading = true;
    _autoReopenSpent = false;
    notifyListeners();
    _armFirstFrameDeadline(sessionId);
    // D-079: entering a session re-subscribes `$events` so an approval raised
    // while the phone was elsewhere comes back **immediately**. The gateway
    // replays every still-pending waterfall to a fresh subscriber, while the
    // line above just cleared `_bubbles` — without this the card was gone
    // until the 60s periodic re-open happened to land.
    _subscribeEvents();

    // D-094: a subagent is addressed by the **pair** (parent, child) — the wire
    // type is `SubagentSessionAddress` precisely because a bare child id is not
    // addressable (`subagent/unauthorized`: "subagent does not belong to the
    // supplied parent"). This used to fill both halves with `sessionId`, which
    // on the team page IS the child's own id, so every subagent conversation
    // came back unauthorized — and D-095 then swallowed the error, leaving a
    // blank page. Callers that open a child must pass the parent's id.
    _openJournal(sessionId, subagentLabel: subagentLabel,
        parentSessionId: parentSessionId);
  }

  /// D-104: 同步打开 journal（[open] 与 [retry] 共用）。
  ///
  /// 子代理在 wire 上成对寻址（D-094）：`SubagentSessionAddress` 缺 parent 引擎
  /// 回 `subagent/unauthorized`，所以 parent 一律由调用方另传，兜底成 child
  /// 自己只会得到一个空白的子会话页。
  void _openJournal(
    String sessionId, {
    String? subagentLabel,
    String? parentSessionId,
  }) {
    final address = subagentLabel == null
        ? PlainSessionAddress(sessionId)
        : SubagentSessionAddress(
            parentSessionId: parentSessionId ?? sessionId,
            childSessionId: sessionId,
            mode: _readOnly,
          );
    final gen = ++_journalGeneration;
    _journal = gateway.follow(address: address);
    AppLog.d('e2e', '[e2e] open journal addr=$address gen=$gen');
    _journalSub = _journal!.frames.listen((f) {
      // 旧流（关闭动作是异步的）迟到的帧一律丢弃。
      if (_disposed || gen != _journalGeneration) return;
      AppLog.d('e2e', '[e2e] frame ${f.runtimeType}');
      applyFrame(f);
    });
    _journalErrorSub = _journal!.errors.listen((Object e) {
      if (_disposed || gen != _journalGeneration) return;
      AppLog.w('chat', 'journal error: $e');
      // D-095: `if (e is EngineRemoteError)` was the whole filter, and the
      // journal's errors arrive as `MuxStreamError` — every unauthorized
      // subagent address and every dropped carrier was logged and then dropped
      // on the floor. Same lesson as D-089 on the jobs pane: both types carry
      // `toAppError()` off one shared code table, so accepting both costs
      // nothing.
      //
      // D-095 (second half, found by the guard test): setting `_error` alone
      // still shows nothing — **no widget reads this getter**. The bubbles list
      // is the only surface ChatPane renders errors on (the prompt-failure path
      // has always done this), so a dead journal must land there too. Without
      // this the user sees an empty conversation with a composer, i.e. exactly
      // the 真机 blank page from 2026-10-11.
      final appError = switch (e) {
        final MuxStreamError err => err.toAppError(),
        final EngineRemoteError err => err.toAppError(),
        _ => AppError(ErrorCode.engineUnknown,
            rawMessage: e.toString()),
      };
      _error = appError;
      _bubbles = [..._bubbles, ErrorNotice(appError)];
      _disarmFirstFrameDeadline();
      _loading = false;
      notifyListeners();
    });

    // The opening snapshot carries the authoritative projection baseline at
    // its cursor, so there is deliberately NO `session/projections` call here:
    // racing a separate cold read against the live snapshot made the context
    // capsule flip between two cuts depending on which landed last. A missing
    // baseline renders as "context unknown", which is the honest state.
    if (!_suspended) _startJobWatch(sessionId);
  }

  /// T1.12: watch this session's tasks from the console, not from 屏 F.
  ///
  /// A completion prompt is only useful to someone who is **not** looking at
  /// the task list, so the pane's own `job/list` subscription cannot be the
  /// source. The rows are folded through [JobCompletionWatcher] (a replace, not
  /// a diff) and the terminal transition is routed into the shared
  /// [ReminderRouter].
  void _startJobWatch(String sessionId) {
    _closeJobWatch();
    final stream = gateway.listJobs(sessionId: sessionId);
    _jobsStream = stream;
    _jobsSub = stream.items.listen((value) {
      if (_disposed) return;
      final frame = asObject(value);
      if (frame?['type'] != 'rows') return;
      final rows = frame!['jobs'];
      if (rows is! List<Object?>) return;
      for (final done in _jobWatcher.onRows([
        for (final row in rows.whereType<Map<String, dynamic>>())
          JobView.fromJson(row),
      ])) {
        _reminders.reportJobFinished(
          jobId: done.jobId,
          machineId: machineId,
          title: done.title,
          failed: done.failed,
        );
      }
    });
  }

  void _closeJobWatch() {
    _jobsSub?.cancel();
    _jobsSub = null;
    _jobsStream?.cancel();
    _jobsStream = null;
  }

  late SubagentMode _readOnly;

  /// D-042 轨迹账本。
  ///
  /// **刻意挂在 controller 上而不是轨迹页自己开流**：轨迹和对话共享同一
  /// 条 `session/follow`（dsh 的决策：「Session 统一拥有一份连续 Event
  /// 窗口」）。再开一条流会让同一段会话在手机上跑两份，事件量翻倍，而且
  /// 两条流的游标可能落在不同位置，轨迹看到的东西和对话对不上。
  final TrajectoryLedger _ledger = TrajectoryLedger();

  /// 轨迹账本。
  TrajectoryLedger get ledger => _ledger;

  /// 打开中的会话是不是子代理（决定轨迹补页用哪种地址）。
  String? get subagentLabel => _subagentLabel;

  /// Whether the composer accepts input.
  ///
  /// A one-shot subagent is terminal: the protocol has no `readOnly` flag, so
  /// the mode IS the rule, and the console hides the composer rather than
  /// letting the engine reject a send.
  bool get readOnly => _readOnly == SubagentMode.oneShot;

  /// Refresh the live projection capsules (context ring, tok/s, cache).
  Future<void> refreshProjections() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final result = await gateway.projections(sessionId);
    if (result.isOk) {
      _projections = result.value! as SessionProjectionBaseline?;
      _error = null;
    }
    notifyListeners();
  }

  /// Send [text] as the user. Returns the failure instead of throwing so the
  /// composer can render an inline card.
  Future<AppError?> send(String text) async {
    final sessionId = _sessionId;
    final trimmed = text.trim();
    if (sessionId == null || trimmed.isEmpty || readOnly) return null;

    _sending = true;
    _error = null;
    notifyListeners();

    final result = await gateway.prompt(
      sessionId: sessionId,
      content: [PromptContentPart.text(trimmed)],
    );
    AppLog.d('e2e', '[e2e] prompt ok=${result.isOk} err=${result.error}');
    _sending = false;
    if (!result.isOk) {
      final failure = result.error!;
      _error = failure.toAppError();
      AppLog.w('chat', 'prompt failed: code=${failure.code} ${failure.message}');
      _bubbles = [..._bubbles, ErrorNotice(_error!)];
    }
    notifyListeners();
    return _error;
  }

  /// Answer the pending approval. The wire value is the **bare** string.
  ///
  /// D-078: the card is removed only after the engine accepted the answer —
  /// an optimistic removal used to hide generation churn, leaving dsh web
  /// pending while the phone believed it had approved.
  Future<void> answerApproval(ApprovalOutcome outcome) async {
    final pending = pendingApproval;
    if (pending == null) return;
    final settled =
        await _settleEvent(eventId: pending.eventId, value: outcome.wire);
    if (!settled) return;
    await _removeBubble((bubble) => bubble is PendingApproval && bubble.eventId == pending.eventId);
  }

  /// Settle one waterfall with generation discipline (D-078).
  ///
  /// The gateway only honors a result from a generation that actually received
  /// the delivery (`api/gateway/src/index.ts:618-621` — `deliveries.has`
  /// mismatch is a silent no-op; an unknown clientId is an rpcFailure). The
  /// `$events` generation changes on every periodic re-open, so:
  /// wait for the current generation's `ready` before sending, check the
  /// result, and on failure re-subscribe and retry exactly once — the host
  /// replays still-pending waterfalls to the fresh generation.
  Future<bool> _settleEvent({required String eventId, Object? value}) async {
    if (!await _awaitReadyGeneration()) {
      AppLog.w('chat', '[D-078] answer for $eventId aborted: no ready generation');
      return false;
    }
    var result =
        await gateway.answerEvent(clientId: _clientId!, eventId: eventId, value: value);
    if (result.isOk) return true;
    AppLog.w('chat',
        '[D-078] answer for $eventId failed (${result.error?.code}); re-subscribing and retrying once');
    _subscribeEvents();
    if (!await _awaitReadyGeneration()) return false;
    result =
        await gateway.answerEvent(clientId: _clientId!, eventId: eventId, value: value);
    if (!result.isOk) {
      AppLog.w('chat', '[D-078] retry for $eventId failed (${result.error?.code}); card kept');
    }
    return result.isOk;
  }

  /// True when `_clientId` belongs to a generation that has published `ready`.
  /// Resubscribes and bounded-waits otherwise.
  Future<bool> _awaitReadyGeneration() async {
    if (_clientId != null && (_readySignal?.isCompleted ?? false)) return true;
    _subscribeEvents();
    final signal = _readySignal;
    if (signal == null) return false;
    try {
      await signal.future.timeout(answerReadyTimeout);
    } on TimeoutException {
      return false;
    }
    return _clientId != null;
  }

  /// Answer the pending question with an already-built `{answers: [...]}` map.
  ///
  /// The UI owns the answer *shape* — including the omission that expresses a
  /// skip — and hands over the wire value verbatim. The controller settles the
  /// card only after the engine accepts (D-078).
  Future<void> answerQuestionWire(Object? wire) async {
    final pending = pendingQuestion;
    if (pending == null) return;
    final settled = await _settleEvent(eventId: pending.eventId, value: wire);
    if (!settled) return;
    await _removeBubble((bubble) => bubble is PendingQuestion && bubble.eventId == pending.eventId);
  }

  /// Answer the pending question from typed items (plan review, tests).
  Future<void> answerQuestion(List<AskUserQuestionAnswerItem> answers) =>
      answerQuestionWire(AskUserQuestionAnswer(answers).toJson());

  /// Abandon a question, e.g. dismissing the plan review without deciding.
  Future<void> rejectQuestion(String reason) async {
    final pending = pendingQuestion;
    if (pending == null) return;
    if (!await _awaitReadyGeneration()) return;
    final result = await gateway.rejectEvent(
      clientId: _clientId!,
      eventId: pending.eventId,
      message: reason,
    );
    if (!result.isOk) {
      AppLog.w('chat', '[D-078] reject for ${pending.eventId} failed (${result.error?.code}); card kept');
      return;
    }
    await _removeBubble((bubble) => bubble is PendingQuestion && bubble.eventId == pending.eventId);
  }

  /// Open the waterfall stream once per console; approvals and questions
  /// arrive here rather than on the journal.
  void startEvents() {
    if (_eventSub != null) return;
    _subscribeEvents();
    // D-032: the relay's mux bridge stops forwarding frames on a long-lived
    // `$events` carrier while still accepting pings, so the socket looks alive
    // but the channel is deaf — approvals/questions never arrive. Re-opening
    // the stream periodically heals it: the host replays every still-pending
    // waterfall to a fresh subscriber, so the worst-case staleness is bounded
    // by this interval. Duration.zero disables the timer (widget tests —
    // a pending periodic timer would fail their post-test timer audit).
    if (eventsRefreshInterval > Duration.zero) {
      _eventsRefreshTimer = Timer.periodic(eventsRefreshInterval, (_) {
        if (_disposed) return;
        _subscribeEvents();
      });
    }
  }

  /// (Re-)open `$events`. Idempotent: the previous subscription and stream are
  /// torn down first, so repeated calls from the refresh timer are safe.
  void _subscribeEvents() {
    _eventSub?.cancel();
    _eventStream?.cancel();
    _readySignal = Completer<void>();
    final stream = gateway.openEventStream();
    _eventStream = stream;
    _eventSub = stream.items.listen(_onEvent);
  }

  void _onEvent(Object? value) {
    final frame = asObject(value);
    if (frame == null) return;
    AppLog.d('e2e', '[e2e] \$event frame type=${frame['type']}');
    switch (frame['type']) {
      case 'ready':
        _clientId = frame['clientId'] as String?;
        if (_readySignal != null && !_readySignal!.isCompleted) {
          _readySignal!.complete();
        }
        AppLog.d('e2e', '[e2e] \$events clientId=$_clientId');
      case 'waterfall':
        _onWaterfall(frame);
    }
    notifyListeners();
  }

  void _onWaterfall(Map<String, dynamic> frame) {
    final event = frame['event'] as String?;
    final eventId = frame['eventId'] as String?;
    final request = asObject(frame['request']);
    if (eventId == null || request == null) return;
    // D-032: the periodic `$events` re-open makes the host replay every
    // still-pending waterfall, so the same eventId can arrive repeatedly.
    // Skip if a card for it is already on screen.
    if (_bubbles.any((b) =>
        b is PendingApproval && b.eventId == eventId ||
        b is PendingQuestion && b.eventId == eventId)) {
      return;
    }
    switch (event) {
      case 'approval/request':
        _bubbles = [
          ..._bubbles,
          PendingApproval(eventId: eventId, request: ApprovalRequest.fromJson(request)),
        ];
        // T1.12 审批请求: the user may be on the machines tab when the engine
        // asks. The router keys on the eventId, so the D-032 replay of a
        // still-pending approval stays one prompt.
        _reminders.reportApproval(
          eventId: eventId,
          machineId: machineId,
          title: request['title'] as String? ?? request['command'] as String?,
        );
      case 'user-questions/request':
        final questions = (request['questions'] is List)
            ? (request['questions']! as List)
                .whereType<Map<String, dynamic>>()
                .map(AskUserQuestionItem.fromJson)
                .toList(growable: false)
            : const <AskUserQuestionItem>[];
        _bubbles = [
          ..._bubbles,
          PendingQuestion(
            eventId: eventId,
            questions: questions,
            planReview: PlanReview.of(questions),
          ),
        ];
    }
  }

  /// D-104: 自动重开预算与重入保护。
  ///
  /// 自动重开**只做一次**：反复 45s 超时反复重开会把设备电和网络一起耗在
  /// 一件注定失败的事上，第二次起就交给用户手上的「重试」按钮。
  bool _autoReopenSpent = false;
  bool _reopening = false;

  /// D-104: 每次开 journal 递增。关闭旧流的 `cancel()` 是异步的，新流已经
  /// 绑定时旧流可能还递上来几帧——代号不符的一律丢弃，别让上一段会话的
  /// 幽灵帧画到新会话屏幕上。
  int _journalGeneration = 0;
  Timer? _autoReopenTimer;

  /// D-104: 会话页该给用户一个「重试」按钮吗？
  ///
  /// 错误码表已经把重试策略写死了（`RetryPolicy.autoBackoff` 等），这里只是
  /// 把「这条错误值得重试」翻译成 UI 事实——修之前错误卡只印文案、不可点，
  /// 而文案还写着「正在重试」，是真机实测出来的谎（D-104）。
  bool get canRetry =>
      _error != null && _error!.retry != RetryPolicy.none && !_reopening;

  /// D-104: 手动重试——重开当前会话的 journal。
  ///
  /// **刻意不走 [open]**：`open` 首行 `await _closeJournal()`，而取消订阅要等
  /// 真实异步；在 widget 测试的 FakeAsync 区里这个 await 永远不完成（真机上
  /// 没事，但守门会被吊死，见 D-103 那条）。所以重试走同步路径：发起取消、
  /// 立刻重开，用 [_journalGeneration] 挡住旧流的迟到帧。
  ///
  /// 手动重试会重置自动重开预算——用户既然主动点了，就该再给他一次自动兜底。
  void retry() => _reopenJournal(manual: true);

  /// D-104: 自动重开走同一条路，但**不重置** [_autoReopenSpent]。
  ///
  /// 真机（小米 10:49）当场抓到过这个坑：自动重开当初也调 [retry]，而
  /// [retry] 为了「用户主动点了就给一次自动兜底」把预算重置了——于是
  /// 每 48 秒重开一次、无穷无尽，用户永远只看到一个转圈。手动手���重置预算
  /// 是对的，让自动路径跟着一起重置就是错的。
  void _autoReopen() => _reopenJournal(manual: false);

  void _reopenJournal({required bool manual}) {
    if (_disposed || _reopening) return;
    final sessionId = _sessionId;
    if (sessionId == null) return;
    _reopening = true;
    if (manual) _autoReopenSpent = false;
    _autoReopenTimer?.cancel();
    _autoReopenTimer = null;

    _journalSub?.cancel();
    _journalErrorSub?.cancel();
    _journal?.cancel();
    _journal = null;
    _journalSub = null;
    _journalErrorSub = null;

    // 旧错误卡是上一次失败的叙述，重试时它该让位给新内容。
    _bubbles = _bubbles.where((b) => b is! ErrorNotice).toList();
    _error = null;
    _loading = true;
    _armFirstFrameDeadline(sessionId);
    _subscribeEvents();
    _openJournal(sessionId);

    _reopening = false;
    notifyListeners();
  }

  /// D-058: 给这次 `open` 装一个首帧看门狗。
  ///
  /// [_sessionIdAtArm] 是防串门的锚：定时器只为它装的那个会话负责，切走后
  /// 到点也只是空转。
  void _armFirstFrameDeadline(String sessionId) {
    _firstFrameTimer?.cancel();
    _firstFrameTimerFor = sessionId;
    _firstFrameTimer = Timer(firstFrameTimeout, () {
      _onFirstFrameDeadlinePassed();
    });
  }

  void _disarmFirstFrameDeadline() {
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
    _firstFrameTimerFor = null;
  }

  void _onFirstFrameDeadlinePassed() {
    _firstFrameTimer = null;
    final armed = _firstFrameTimerFor;
    _firstFrameTimerFor = null;
    if (_disposed) return;
    // 已经不在等首帧了（首帧到了、或用户已经切走、或已经报错）——什么都不做。
    if (armed == null || armed != sessionId || !_loading) return;
    _loading = false;
    // 说的是「等不到」而不是「坏了」：引擎可能只是慢。`engine.timeout` 已有
    // 三段式文案与重试入口（D-044 补过它的映射），不新造一个 code。
    _error = AppError(
      ErrorCode.engineTimeout,
      detail: 'no first frame within ${firstFrameTimeout.inSeconds}s',
    );
    // D-100: `_error` alone renders nowhere — ChatPane draws errors only
    // through `ErrorNotice` bubbles (the same gap as D-095's first half). The
    // 真机 15:02 symptom was exactly this: deadline hit, log warned, screen
    // stayed blank. The bubble is also the retry affordance.
    _bubbles = [..._bubbles, ErrorNotice(_error!)];
    AppLog.w('chat',
        'first-frame deadline hit (${firstFrameTimeout.inSeconds}s) session=$sessionId');
    notifyListeners();

    // D-104: 文案写着「正在重试」，那就让它真的重试——否则用户在网络恢复后
    // 永远停在这张卡上（真机：切 tab 不恢复、点卡不响应，只有从会话列表重新
    // 进入才活）。按错误码表自己的 RetryPolicy 决定要不要自动退避重开，
    // 且**只做一次**：第二次起必须由用户点按钮，避免 45s 超时循环。
    if (_error!.retry == RetryPolicy.autoBackoff && !_autoReopenSpent) {
      _autoReopenSpent = true;
      AppLog.i('chat', 'auto-reopening journal once after deadline hit');
      _autoReopenTimer?.cancel();
      _autoReopenTimer = Timer(_autoReopenBackoff, () {
        _autoReopenTimer = null;
        _autoReopen();
      });
    }
  }

  /// D-104: 自动重开前的退避间隔。立刻重开等于对着刚超时的链路再敲一次。
  static const _autoReopenBackoff = Duration(seconds: 3);

  /// 测试用：直接触发首帧看门狗。
  @visibleForTesting
  void onFirstFrameDeadlinePassedForTest() => _onFirstFrameDeadlinePassed();

  /// Apply one `session/follow` frame.
  ///
  /// Public so the streaming lifecycle is testable without a live carrier; the
  /// journal subscription is the production caller.
  @visibleForTesting
  void applyFrame(SessionFollowFrame frame) {
    switch (frame) {
      case FollowSnapshot(:final header, :final projections, :final records, :final cursor, :final hasMore):
        _headerTitle = header.title ?? _headerTitle;
        // D-059: 首帧 header 自带 title，趁这次请求还在把它记下来。
        titles?.remember(header.id, header.title);
        // D-076: header 同时带着本会话的 agent 预设——数据一直都在，
        // 之前只取了 title 把它扔了。
        _sessionPreset = header.agentPreset ?? _sessionPreset;
        _projections = projections;
        // D-058: 首帧到了，看门狗就没用了。
        _disarmFirstFrameDeadline();
        _loading = false;
        // D-042: 首帧换掉整本账本。`records` 是引擎给的这段窗口，加上
        // `hasMore`（还有更早的历史）——分页入口就这么来的。
        _ledger.reset(
          records: [for (final r in records) r.event],
          cursor: cursor,
          hasMore: hasMore,
        );
        // A fresh snapshot ends whatever the previous carrier was streaming:
        // its rows are transient and the new journal re-opens the live attempt
        // from the baseline it carries.
        _live = null;
        // `tool/call` must be projected before its `tool/result`, or the node
        // loses the tool's name.
        final restored = <ChatBubble>[];
        for (final entry in records) {
          restored.addAll(ChatEventReader.bubblesOf(
            entry.event,
            subagentLabel: _subagentLabel,
            toolCalls: _toolCalls,
          ));
        }
        // D-049: a snapshot that is not the first one on this journal is a
        // **re-baseline** (D-027: the carrier died, the resume re-answered
        // `open`). Its window starts from the beginning, so appending would
        // draw the whole conversation a second time — the user would read their
        // own history twice and the gap as a duplicate. Replace instead, and
        // keep the bubbles that came from `$events`: a pending approval is not
        // in the journal window at all, and the host re-delivers it on its next
        // `$events` frame (D-032) — dropping it here would be losing it.
        final fromEvents = _journalBaselined
            ? _bubbles
                .where((b) => b is PendingApproval || b is PendingQuestion)
                .toList(growable: false)
            : const <ChatBubble>[];
        _journalBaselined = true;
        _bubbles = [...fromEvents, ...restored];
      case FollowEvent(:final event):
        // D-042: 事件进账本。`bubblesOf` 认不出的类型会被丢掉，但轨迹
        // 必须留着——这是「能翻到机器载荷」和「只看见对话」的区别。
        _ledger.append(event);
        _bubbles = [
          ..._bubbles,
          ...ChatEventReader.bubblesOf(
            event,
            subagentLabel: _subagentLabel,
            toolCalls: _toolCalls,
          ),
        ];
      case FollowAssistantStream():
        if (_onAssistantStream(frame)) {
          _scheduleStreamPaint();
          return;
        }
      case FollowUnknown():
        // An engine upgrade may add a frame kind; ignoring it degrades to
        // "no live row" rather than a crash.
        break;
    }
    notifyListeners();
  }

  /// Fold one transient frame into [_live]. Returns whether anything changed.
  bool _onAssistantStream(FollowAssistantStream frame) {
    switch (frame.kind) {
      case 'start':
        // A replayed start for the attempt already on screen (D-032's periodic
        // `$events` re-open replays it) restarts the row rather than adding a
        // second one; the replayed chunks then refill the same text.
        _live = _LiveAttempt(
          attemptId: frame.attemptId,
          turn: frame.turn,
          step: frame.step,
        );
        return true;
      case 'chunk':
        final chunk = frame.chunk;
        if (chunk == null) return false;
        final live = _live;
        if (live == null || live.attemptId != frame.attemptId) return false;
        if (chunk['type'] == 'text-delta') {
          final text = chunk['text'];
          if (text is! String || text.isEmpty) return false;
          live.append(text);
          return true;
        }
        // D-069: 思考内容只存在于流式帧（落库走 assistant/message 的
        // reasoning 块，D-088）。线上帧的准确字段名未实测过，这里按两种
        // 合理形态防御性接住——`reasoning-delta`
        //（对齐 text-delta 的单字符串）与 `reasoning-chunks`（durable stream
        // 记录里的数 组形态）。都不是就维持旧行为：丢弃。
        final reasoning = _reasoningDeltaOf(chunk);
        if (reasoning == null || reasoning.isEmpty) return false;
        live.appendReasoning(reasoning);
        return true;
      case 'end':
        // Both outcomes retire the row: `committed` means the durable
        // `assistant/message` event has (or is about to be) delivered, and
        // `abandoned` means nothing will.
        if (_live?.attemptId == frame.attemptId) _live = null;
        return false;
    }
    return false;
  }

  /// D-069: 从流式 chunk 里取思考增量；不是思考形态就返回 null。
  ///
  /// 两种形态都接：`reasoning-delta`（单字符串，对齐 text-delta）与
  /// `reasoning-chunks`（durable AssistantStreamRecord 的数 组形态，
  /// `{dt: [], texts: []}`）。字段名未真机实测——形态不匹配时静默丢弃，
  /// 与旧行为一致，绝不因此炸流。
  static String? _reasoningDeltaOf(Map<String, dynamic> chunk) {
    switch (chunk['type']) {
      case 'reasoning-delta':
        final text = chunk['text'];
        return text is String ? text : null;
      case 'reasoning-chunks':
        final texts = chunk['texts'];
        if (texts is! List) return null;
        return [
          for (final t in texts)
            if (t is String) t,
        ].join();
      default:
        return null;
    }
  }

  /// Coalesce token-rate wake-ups into one paint per [_streamPaintInterval].
  void _scheduleStreamPaint() {
    if (_disposed) return;
    if (_streamPaint?.isActive ?? false) return;
    _streamPaint = Timer(_streamPaintInterval, () {
      _streamPaint = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _removeBubble(bool Function(ChatBubble) test) async {
    _bubbles = _bubbles.where((bubble) => !test(bubble)).toList(growable: false);
    notifyListeners();
  }

  Future<void> _closeJournal() async {
    await _journalSub?.cancel();
    await _journalErrorSub?.cancel();
    _journal?.cancel();
    _journal = null;
    _journalSub = null;
    _journalErrorSub = null;
    _closeJobWatch();
  }

  Future<void> _closeEvents() async {
    await _eventSub?.cancel();
    _eventSub = null;
    _eventStream?.cancel();
    _eventStream = null;
  }

  /// The console's carrier, when the gateway really owns one. A fake gateway
  /// (widget tests) has none, and the suspend/resume contract then degrades to
  /// the streams alone — which is all a test can observe anyway.
  EngineMux? get _mux =>
      gateway is EngineClient ? (gateway as EngineClient).mux : null;

  /// D-049: turn a carrier drop into a 隧道断开 reminder.
  ///
  /// Only a transition **away from** a healthy carrier is an outage. The first
  /// state seen is the boot `connecting`, and the teardown this class performs
  /// on background is reported as `idle` — neither is something the user needs
  /// to be told about, and prompting for them would make every app switch look
  /// like a disconnection.
  void _watchCarrier() {
    final mux = _mux;
    if (mux == null) return;
    _carrierSub = mux.states.listen(_onCarrierState);
  }

  void _onCarrierState(MuxState state) {
    final was = _lastCarrierState;
    _lastCarrierState = state;
    if (_disposed || _suspended || was == null) return;
    if (state == MuxState.connected) {
      _reminders.reportTunnel(machineId: machineId, connected: true);
      return;
    }
    if (was == MuxState.connected) {
      _reminders.reportTunnel(machineId: machineId, connected: false);
    }
  }

  void _onLifecycle() {
    if (_disposed) return;
    if (_lifecycle.foreground) {
      unawaited(_resumeFromBackground());
    } else {
      unawaited(_suspendForBackground());
    }
  }

  /// design §5「切后台即断 WS」.
  ///
  /// The streams are cancelled **before** the socket goes down, so the host
  /// sees a clean `cancel` per logical stream and nothing is left half-open on
  /// a carrier that is about to be closed. Nothing is remembered: the resume
  /// re-opens from a known cursor (§_resumeFromBackground).
  Future<void> _suspendForBackground() async {
    if (_suspended) return;
    _suspended = true;
    _eventsRefreshTimer?.cancel();
    _eventsRefreshTimer = null;
    await _closeEvents();
    await _closeJournal();
    // A live attempt is a property of a carrier that no longer exists; the
    // re-open rebuilds it from the snapshot the host sends back.
    _live = null;
    await _mux?.stop();
  }

  /// The other half. **Nothing that happened while the socket was down is
  /// treated as never happened**: the journal is re-opened from scratch, and
  /// the host answers with a fresh authoritative snapshot whose window includes
  /// the gap — the same contract as switching machines (D-027/D-030's algebra,
  /// entered deliberately rather than by accident). `$events` comes back too,
  /// which is what replays a still-pending approval or question.
  Future<void> _resumeFromBackground() async {
    if (!_suspended) return;
    _suspended = false;
    final mux = _mux;
    mux?.start();
    final sessionId = _sessionId;
    if (sessionId != null) {
      await open(
        sessionId,
        // D-099: without the remembered parent the rebuilt subagent address
        // reads parent = child id and the engine refuses it.
        parentSessionId: _parentSessionId,
        subagentLabel: _subagentLabel,
        mode: _readOnly,
      );
      // A second backgrounding can land inside that await; if it did, park
      // again rather than leaving a carrier open behind a backgrounded app.
      if (_suspended || _disposed) {
        await _suspendForBackground();
        return;
      }
    }
    if (_disposed) return;
    startEvents();
  }

  @override
  void dispose() {
    // D-104: 不取消的话，这个 Timer 会在 controller 死后调 retry() →
    // notifyListeners() 打到已 dispose 的 ChangeNotifier 上。
    _autoReopenTimer?.cancel();
    _autoReopenTimer = null;
    _disposed = true;
    _lifecycle.removeListener(_onLifecycle);
    _eventsRefreshTimer?.cancel();
    _firstFrameTimer?.cancel();
    _streamPaint?.cancel();
    _closeJournal();
    _carrierSub?.cancel();
    _closeEvents();
    super.dispose();
  }
}
