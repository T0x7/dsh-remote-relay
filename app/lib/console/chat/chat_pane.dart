import 'dart:convert';

import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';

import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

import '../context/context_sheet.dart';
import '../inline_error_card.dart';
import 'chat_controller.dart';
import 'question_batch_card.dart';

/// The conversation screen (mockup 屏 E): bubble flow, inline approval and
/// question cards, the context/statistics bar, and the composer.
///
/// Stateless over a [ChatController] — every interaction is a controller call
/// and the widget rebuilds from its notifications, so the same tree renders
/// both live and under test.
class ChatPane extends StatefulWidget {
  const ChatPane({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane>
    with SingleTickerProviderStateMixin {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  /// D-071: 思考指示器的三点脉冲。启停由 _syncDots 按指示器可见性驱动。
  late final AnimationController _dotsPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  /// D-072: 贴底跟随开关。true = 用户在列表底部（±80px），内容增长时自动
  /// 钉住底部；用户上滚翻历史即置 false——阅读历史时被拽回是最招人恨的，
  /// 此时右下角给「回到底部」悬浮钮，点它或滑回底部即恢复跟随。
  bool _followBottom = true;

  /// D-102: 手指正按在列表上（drag 已开始、尚未结束）。
  ///
  /// 自动贴底的每个 `jumpTo` 都是一次「抢占」——落在手势中途就把它打断。
  /// 有了这个标志，手势期间一律不自动跳底，手指说了算。
  bool _dragging = false;

  static const _followThreshold = 80.0;

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom = _scroll.position.pixels >=
        _scroll.position.maxScrollExtent - _followThreshold;
    // 手势进行中不接受「其实还在底部」把跟随抢回去：哪怕只滑了 3px，
    // 一旦开了跟随，接下来每一帧的自动跳底都会跟手指对着干。
    if (_dragging && atBottom) return;
    _setFollowBottom(atBottom);
  }

  /// D-102: 用户手势一落上列表，自动贴底立即让位。
  ///
  /// 改之前是靠 [_onScroll] 的 ±80px 阈值判断「用户是不是想翻历史」，而阈值
  /// 判定发生在手势开始**之后**——密集事件流（后台恢复重放、投影刷新）在
  /// 这几帧里每次 notify 都 postFrame `jumpTo`，直接和进行中的 drag 抢滚动
  /// 位置：手指不动、动画被反复取消重排，表现为「滑动完全失灵，点回底也没
  /// 用」，切走 tab 再回来（widget 重建）才恢复。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragging = true;
      _setFollowBottom(false);
    } else if (notification is ScrollEndNotification) {
      _dragging = false;
      // 抬手时重新判一次：轻轻拖 3px 松手的人不该被留下一颗回底钮。
      _onScroll();
      // `_dragging` 本身参与按钮显隐判定（手势中不显示），所以清掉它必须
      // 重画一次。此时 `_followBottom` 多半已经是 false，[_setFollowBottom]
      // 不会触发 setState —— 少了这一句，回底钮就会永远停在「手势中」的
      // 隐藏态，用户在列表失灵时连逃生出口都没有。
      if (mounted) setState(() {});
    }
    return false;
  }

  /// 贴底开关的唯一写入口，保证按钮显隐（依赖它）随之刷新。
  void _setFollowBottom(bool value) {
    if (_followBottom == value) return;
    _followBottom = value;
    if (mounted) setState(() {});
  }

  /// D-070: 被点开的工具行（按事件 seq）。同 _unfoldedSeqs 的理由：状态要
  /// 活过 controller notify 引发的列表重建。
  final Set<int> _openToolSeqs = {};

  /// D-068: 被用户展开过的长文案（按事件 seq）。记在页面 State 而不是气泡
  /// 自己的 StatefulWidget 里——ListView 的重建/元素复用会把局部状态冲掉，
  /// 而「用户展开过」必须活过每一次 controller notify。
  final Set<int> _unfoldedSeqs = {};

  /// D-069: 思考块的开关。自动规则 = 回答正文没到就展开、到了就收起；
  /// 用户点过一次即「钉住」自己的选择，正文到达不再自动收。
  /// （引擎不持久化 reasoning，流式行被 durable 气泡覆盖后整块消失。）
  bool _thinkingPinned = false;
  bool _thinkingOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    _scroll.addListener(_onScroll);
    _syncDots();
  }

  @override
  void didUpdateWidget(ChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      // 换 controller = 换会话，直接复位；didUpdateWidget 之后必然有一次
      // build，按钮显隐在这一帧就是对的，不必再 setState。
      _followBottom = true;
      _dragging = false;
      _syncDots();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _scroll.removeListener(_onScroll);
    _dotsPulse.dispose();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// D-071: 脉冲动画只在指示器可见时跑——模型安静时让 ticker 停下来，
  /// 不给电池交无意义的税；测试里的无限等待问题也随之消掉大半。
  void _syncDots() {
    final shouldRun = widget.controller.modelWorkingSilently;
    if (shouldRun && !_dotsPulse.isAnimating) {
      _dotsPulse.repeat();
    } else if (!shouldRun && _dotsPulse.isAnimating) {
      _dotsPulse.stop();
    }
  }

  void _onChanged() {
    if (!mounted) return;
    _syncDots();
    setState(() {});
    if (_followBottom) {
      // 内容增长后布局才有新的 maxScrollExtent，延后一帧跳底。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_followBottom || _dragging || !_scroll.hasClients) {
          return;
        }
        if (_scroll.position.maxScrollExtent > _scroll.position.pixels) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  /// D-090: 滚到底部。
  ///
  /// 不能只 `animateTo(maxScrollExtent)` 一次就完事：**懒加载 ListView 的
  /// `maxScrollExtent` 是估算值**，列表里只要有一个超过视口高度的展开气泡
  /// （比如「展开全文」点开后的长文），估算就和真实布局差出好一屏。实测两次：
  /// 一次落进纯空白区（视口里什么都没有），一次停在距底一屏处而「回到底部」
  /// 按钮还亮着——两种都表现为「点了没反应」。
  ///
  /// 所以布局稳定后再重查一次真实落点，没到底就再跳。跳的次数有界
  /// （[_maxBottomNudges]）：布局真的对不上时无限跳会把页面变成抽搐。
  ///
  /// D-102（改版）：**改用同步 `jumpTo`，不再用 `animateTo` 的递归补跳**。
  /// 动画是一条有状态的 activity：密集事件流里每次 notify 打断它、
  /// `whenComplete` 又立刻排下一次 animate，动画状态机自己跟自己打转，把
  /// 用户手势一起绞死（真机表现：点过回底之后整条列表手势失灵）。同步跳
  /// 没有 activity 可抢，补跳退化成一次 postFrame 重查。
  void _scrollToEnd({int nudge = 0}) {
    // 点回底钮是用户明确要的落点：顺手清掉手势标志（万一上一次手势的
    // ScrollEnd 没送达，这里是唯一可靠的逃生出口）。
    _dragging = false;
    _setFollowBottom(true);
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.maxScrollExtent <= position.pixels) return;
    _scroll.jumpTo(position.maxScrollExtent);
    if (nudge >= _maxBottomNudges) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_followBottom || _dragging || !_scroll.hasClients) {
        return;
      }
      final next = _scroll.position;
      if (next.maxScrollExtent > next.pixels) {
        _scrollToEnd(nudge: nudge + 1);
      }
    });
  }

  /// 回底的补跳上限。两次足够覆盖「估算偏一屏」；再多就是布局有病。
  static const _maxBottomNudges = 2;

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    _composer.clear();
    await widget.controller.send(text);
    _scrollToEnd();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final controller = widget.controller;

    if (controller.sessionId == null) {
      return _NoSession(l10n: l10n);
    }

    return Column(
      children: [
        Expanded(
          child: controller.loading && controller.bubbles.isEmpty
              ? const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Stack(
                  children: [
                    // D-102: 挂在列表上而不是 ScrollController 上——只有
                    // ScrollNotification 能分辨「手指拖的」和「代码跳的」。
                    NotificationListener<ScrollNotification>(
                      onNotification: _onScrollNotification,
                      child: ListView.builder(
                        controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                        AppTheme.l, AppTheme.m, AppTheme.l, AppTheme.s),
                    // D-071: 模型被请求但尚无任何可上屏输出时，列表末尾追加
                    // 一颗「思考中」指示器——别让用户对着死寂猜卡没卡。
                    itemCount: controller.bubbles.length +
                        (controller.modelWorkingSilently ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == controller.bubbles.length) {
                        return _ThinkingIndicator(
                          key: const ValueKey('thinking-indicator'),
                          pulse: _dotsPulse,
                          label: l10n.chatThinkingActive,
                        );
                      }
                      final bubble = controller.bubbles[index];
                      final isMsg = bubble is ChatMessage;
                      final expanded =
                          isMsg && _unfoldedSeqs.contains(bubble.seq);
                      // D-087（改版 D-069）：移动端惯例（Claude / ChatGPT App）
                      // ——思考中默认也只显示 pill（带实时字数），点开才看
                      // 实时流；正文到达照旧收起。钉住仍全权覆盖默认。
                      String? reasoning;
                      if (isMsg) {
                        reasoning = bubble.reasoningText;
                      }
                      final thinkingOpen =
                          _thinkingPinned ? _thinkingOpen : false;
                      final toolOpen =
                          bubble is ToolNode && _openToolSeqs.contains(bubble.seq);
                      return _BubbleTile(
                        bubble: bubble,
                        l10n: l10n,
                        controller: controller,
                        foldExpanded: expanded,
                        onToggleFold: isMsg
                            ? () => setState(() {
                                  // remove 返回 false = 原本不在 → 现在展开。
                                  if (!_unfoldedSeqs.remove(bubble.seq)) {
                                    _unfoldedSeqs.add(bubble.seq);
                                  }
                                })
                            : null,
                        reasoning: reasoning,
                        thinkingOpen: thinkingOpen,
                        onToggleThinking:
                            (reasoning != null && reasoning.isNotEmpty)
                                ? () => setState(() {
                                      _thinkingPinned = true;
                                      _thinkingOpen = !thinkingOpen;
                                    })
                                : null,
                        toolOpen: toolOpen,
                        onToggleTool: bubble is ToolNode
                            ? () => setState(() {
                                  // 同上：remove false = 原本收起 → 现在展开。
                                  if (!_openToolSeqs.remove(bubble.seq)) {
                                    _openToolSeqs.add(bubble.seq);
                                  }
                                })
                            : null,
                      );
                    },
                  ),
                    ),
            // D-072: 离底阅读历史时给一颗回底钮——跟随被你亲自关掉，
            // 回底也该由你亲自开启。
            // D-102: 手势进行中不给：拇指底下冒出一颗按钮既没用又挡路，
            // 还可能被同一次手势的点按误命中。
            if (!_followBottom && !_dragging)
              Positioned(
                right: AppTheme.m,
                bottom: AppTheme.m,
                child: Material(
                  key: const ValueKey('scroll-to-bottom'),
                  color: AppTheme.surfaceHigh,
                  elevation: 3,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _scrollToEnd,
                    child: const SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(Icons.arrow_downward,
                          size: 20, color: AppTheme.ink),
                    ),
                  ),
                ),
              ),
          ],
        ),
        ),
        ContextBar(
          controller: controller,
          l10n: l10n,
          onTap: () => ContextSheet.show(
            context,
            projections: controller.projections,
            l10n: l10n,
          ),
        ),
        _Composer(
          text: _composer,
          l10n: l10n,
          readOnly: controller.readOnly,
          sending: controller.sending,
          onSend: _send,
        ),
      ],
    );
  }
}

class _NoSession extends StatelessWidget {
  const _NoSession({required this.l10n});
  final L10n l10n;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 44, color: AppTheme.inkDim),
              const SizedBox(height: AppTheme.m),
              Text(l10n.consoleNoSessionTitle,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: AppTheme.xs),
              Text(l10n.consoleNoSessionBody,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
            ],
          ),
        ),
      );
}

/// D-068: 长文案折叠的阈值与裁剪行数。600 字约等于手机上一整屏气泡，
/// 25 个硬换行即使全是短行也该折了。
const int _foldChars = 600;
const int _foldLines = 25;
const int _foldPreviewLines = 18;

bool _isFoldWorthy(String text) =>
    text.length > _foldChars || text.split('\n').length > _foldLines;

/// D-074: 工具行的参数摘要——对齐 dsh web 的「工具调用 · 06067.HK」样式。
/// 从参数 JSON 里挑第一个有辨识度的字符串值（优先 symbol/code/file 等键，
/// 路径取 basename），没有就用结果首行。纯展示层，详情面板仍是全量原文。
String? _toolDigest(String? arguments, String? result) {
  if (arguments != null && arguments.isNotEmpty) {
    try {
      final decoded = jsonDecode(arguments);
      if (decoded is Map) {
        const keys = [
          'symbol', 'code', 'ticker', 'query', 'q', 'command', 'url',
          'content', 'text', 'prompt', 'file_path', 'path', 'file',
        ];
        for (final k in keys) {
          final v = decoded[k];
          if (v is String && v.trim().isNotEmpty) {
            var s = v.trim().replaceAll('\n', ' ');
            if (k == 'file_path' || k == 'path' || k == 'file') {
              s = s.split('/').last;
            }
            return s.length > 28 ? '${s.substring(0, 28)}…' : s;
          }
        }
        for (final v in decoded.values) {
          if (v is String && v.trim().isNotEmpty) {
            final s = v.trim().replaceAll('\n', ' ');
            return s.length > 28 ? '${s.substring(0, 28)}…' : s;
          }
        }
      }
    } catch (_) {}
    return arguments.length > 28 ? '${arguments.substring(0, 28)}…' : arguments;
  }
  if (result != null && result.isNotEmpty) {
    // 真机教训：美化排版的 JSON 首行恰好只有 '['/'{'，摘要会退化成单字符。
    // 先压平换行再截取，摘要永远是有内容的 28 个字符。
    final flat = result.replaceAll('\n', ' ').trim();
    if (flat.isNotEmpty) {
      return flat.length > 28 ? '${flat.substring(0, 28)}…' : flat;
    }
  }
  return null;
}

/// D-070.1: 折叠预览的去符号净化。真机反馈：18 行预览里满屏 `#`/`**`/
/// 反引号依旧扎眼——预览是给人读的摘要，不是原文引用。只净化展示层，
/// 展开后的正文仍是原文渲染的 markdown。
String _previewOf(String src) => src
    .split('\n')
    .map((line) {
      var l = line.replaceFirst(RegExp(r'^\s{0,3}#{1,6}\s+'), '');
      l = l.replaceAll('**', '');
      l = l.replaceAll('`', '');
      l = l.replaceFirst(RegExp(r'^\s*[-*]\s+'), '· ');
      return l;
    })
    .join('\n');

/// D-069: 系统注入的识别标记。这些前缀是宿主/引擎塞进对话的样板（工作须知、
/// 运行时上下文快照、技能清单…），不是对话内容——无论长短一律收成一行摘要条。
/// **不区分消息角色**：实测引擎把运行时上下文快照走 user 通道注入
///（`user/message`，repr 干净无前导空白），AGENTS.md 提醒走 developer 通道；
/// 两个通道都要接。这些前缀不会是人手打的，定时任务提示词（「今天是…」）
/// 不受影响，归 D-068 的长度折叠管。
enum _MetaKind { systemReminder, runtimeContext, injected }

_MetaKind? _metaKindOf(String text) {
  if (text.startsWith('<system-reminder>')) return _MetaKind.systemReminder;
  if (text.startsWith('Current runtime context.')) {
    return _MetaKind.runtimeContext;
  }
  if (text.startsWith('<system-warning>') ||
      text.startsWith('<task-notification>')) {
    return _MetaKind.injected;
  }
  return null;
}

/// 一条消息气泡的正文：折叠态裁到 [_foldPreviewLines] 行 + 渐隐，尾部给
/// 「展开全文（N 字）/ 收起」。剪裁用 maxLines 而不是截断字符串——Text 的
/// data 始终是全文，复制、搜索、无障碍读屏拿到的都还是完整内容。
class _MessageBody extends StatelessWidget {
  const _MessageBody({
    required this.text,
    required this.foldable,
    required this.expanded,
    required this.onToggle,
  });

  final String text;
  final bool foldable;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    // D-070: 展开态/非折叠态用 markdown 富文本；折叠预览保持纯 Text——
    // 18 行裁剪靠 maxLines，GptMarkdown 不支持，且预览态看原始符号也是
    // 「这是原文」的诚实信号。
    final body = (!foldable || expanded)
        ? GptMarkdown(
            text,
            style: const TextStyle(fontSize: 13.5, color: AppTheme.ink),
          )
        : Text(_previewOf(text),
            maxLines: _foldPreviewLines,
            overflow: TextOverflow.fade,
            style: const TextStyle(fontSize: 13.5, color: AppTheme.ink));
    if (!foldable) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        body,
        // 整行宽 + 上下各 6px 热区：真机实测按钮命中区贴着文字时拇指很难
        // 点中（u41-u43 连续脱靶），撑满行宽才是一年级的按钮做法。
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                expanded
                    ? L10n.of(context).chatFoldCollapse
                    : L10n.of(context).chatFoldExpand(text.length),
                style: const TextStyle(fontSize: 11, color: AppTheme.accent),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BubbleTile extends StatelessWidget {
  const _BubbleTile({
    required this.bubble,
    required this.l10n,
    required this.controller,
    required this.foldExpanded,
    required this.onToggleFold,
    required this.reasoning,
    required this.thinkingOpen,
    required this.onToggleThinking,
    required this.toolOpen,
    required this.onToggleTool,
  });

  final ChatBubble bubble;
  final L10n l10n;
  final ChatController controller;

  /// D-068: 该消息当前是否处于展开态（由页面 State 按 seq 计算）。
  final bool foldExpanded;

  /// 折叠/展开切换；非消息气泡恒为 null。
  final VoidCallback? onToggleFold;

  /// D-069: 流式行的思考内容；非流式/无思考为 null。
  final String? reasoning;

  /// D-069: 思考块当前是否展开（页面 State 的自动规则 + 用户钉住）。
  final bool thinkingOpen;
  final VoidCallback? onToggleThinking;

  /// D-070: 工具行详情是否展开（页面 State 按 seq 计算）。
  final bool toolOpen;
  final VoidCallback? onToggleTool;

  @override
  Widget build(BuildContext context) {
    switch (bubble) {
      case ChatMessage(
          :final fromUser,
          :final text,
          :final subagentLabel,
          :final streaming,
          :final reasoningText,
        ):
        // D-069: 系统注入收摘要条（无论长短、无论角色——运行时上下文走
        // user 通道注入）；其余走 D-068 长度折叠。
        // 流式中的消息不折叠——它挂在列表底部自动滚动区，用户正看着它长；
        // 收进 durable 气泡之后才允许折叠。
        final kind = _metaKindOf(text);
        final metaOpen = foldExpanded;
        // 思考块挂在气泡上方：先思考后回答，读序即时间序。
        // D-088：reasoning 不再是流式行专属——durable 气泡也带（引擎落库
        // reasoning 块），历史思考同样走折叠 chip。
        final thinking = reasoningText;
        final hasThinking = thinking != null && thinking.isNotEmpty;
        Widget body;
        if (kind != null) {
          // 注入内容：收起时正文根本不建 widget（一万字样板不进元素树），
          // 展开时全文直出——用户点了就是要看全部，不再套 18 行。
          body = Text(text,
              style: const TextStyle(fontSize: 12, color: AppTheme.ink));
        } else {
          final foldable = !streaming && _isFoldWorthy(text);
          body = _MessageBody(
            text: text,
            foldable: foldable,
            expanded: foldable && foldExpanded,
            onToggle: onToggleFold,
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: AppTheme.s),
          child: Column(
            crossAxisAlignment:
                fromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (hasThinking) ...[
                _ThinkingBlock(
                  reasoning: thinking,
                  open: thinkingOpen,
                  active: text.isEmpty,
                  onToggle: onToggleThinking,
                ),
                const SizedBox(height: AppTheme.xs),
              ],
              if (!fromUser && subagentLabel != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.xs, left: AppTheme.xs),
                  child: Text('${l10n.chatFromSubagent} $subagentLabel',
                      style: const TextStyle(
                          fontSize: 10.5, color: AppTheme.warn, fontFamily: 'monospace')),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.m, vertical: AppTheme.s),
                decoration: BoxDecoration(
                  color: fromUser ? AppTheme.accent.withValues(alpha: 0.12) : AppTheme.surfaceHigh,
                  borderRadius: BorderRadius.circular(AppTheme.m),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (kind != null)
                      _MetaChip(
                        kind: kind,
                        count: text.length,
                        open: metaOpen,
                        onTap: onToggleFold,
                      ),
                    // 收起的注入只有摘要条，正文不进元素树。
                    if (kind == null || metaOpen) body,
                  ],
                ),
              ),
            ],
          ),
        );
      case ToolNode(
          :final name,
          :final failed,
          :final detail,
          :final arguments,
          :final result,
        ):
        // D-070: 工具行可点开——参数与结果详情挂在行下（不可点区域内），
        // 再点行收起。无任何详情时保持纯展示行。
        final hasDetails = (arguments != null && arguments.isNotEmpty) ||
            (result != null && result.isNotEmpty);
        final open = hasDetails && toolOpen;
        // D-074: dsh web 同款两行——标签行「工具调用」（失败附错误名），
        // 内容行「全名 · 参数摘要」。被前缀折叠裁掉 tool/call 的行回落
        // 结果首行摘要，不再是干巴巴的 tool。
        final nameShown = (name.isEmpty || name == 'tool') ? null : name;
        final digest = _toolDigest(arguments, result);
        final contentLine = [
          ?nameShown,
          ?digest,
        ].join(' · ');
        return Padding(
          padding: const EdgeInsets.only(bottom: AppTheme.s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: hasDetails ? onToggleTool : null,
                borderRadius: BorderRadius.circular(AppTheme.xs),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        failed && detail != null
                            ? '${L10n.of(context).chatToolCallLabel} · $detail'
                            : L10n.of(context).chatToolCallLabel,
                        style: TextStyle(
                          fontSize: 10,
                          color: failed ? AppTheme.danger : AppTheme.inkDim,
                        ),
                      ),
                      if (contentLine.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            contentLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: failed ? AppTheme.danger : AppTheme.inkDim,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (open) ...[
                if (arguments != null && arguments.isNotEmpty)
                  _ToolDetail(
                    label: L10n.of(context).chatToolArgs,
                    content: arguments,
                  ),
                if (result != null && result.isNotEmpty)
                  _ToolDetail(
                    label: L10n.of(context).chatToolResult,
                    content: result,
                  ),
              ],
            ],
          ),
        );
      case PendingApproval(:final request, :final eventId):
        return ApprovalCard(
          key: ValueKey(eventId),
          request: request,
          l10n: l10n,
          onAllow: () => controller.answerApproval(ApprovalOutcome.allowedOnce),
          onReject: () => controller.answerApproval(ApprovalOutcome.rejected),
        );
      case PendingQuestion(:final eventId, :final questions, :final planReview):
        // One pending question renders as EITHER a plan-review card (the six
        // conditions held) or the generic batch — never both, and never a
        // separate code path for answering: both post bare `{answers:[…]}`.
        final review = planReview;
        return review != null
            ? QuestionCard(
                key: ValueKey(eventId),
                planReview: review,
                l10n: l10n,
                onApprove: () => controller.answerQuestion([
                      AskUserQuestionAnswerItem(
                          id: review.id, selected: [review.approve]),
                    ]),
                onDecline: review.decline == null
                    ? null
                    : () => controller.answerQuestion([
                          AskUserQuestionAnswerItem(
                              id: review.id, selected: [review.decline!]),
                        ]),
              )
            : QuestionBatchCard(
                key: ValueKey(eventId),
                questions: questions,
                l10n: l10n,
                onSubmit: (wire) => controller.answerQuestionWire(wire),
                onAbandon: () => controller.rejectQuestion(l10n.chatQuestionAbandonReason),
              );
      case ErrorNotice(:final error):
        return Padding(
          padding: const EdgeInsets.only(bottom: AppTheme.s),
          child: InlineErrorCard(error: error, l10n: l10n),
        );
    }
  }
}

/// D-070: 工具详情的一个分节（调用参数 / 运行结果）：小标签 + 等宽文本框，
/// 纵向限高可滚——结果可能很长，但不应把对话流撑爆。
class _ToolDetail extends StatelessWidget {
  const _ToolDetail({required this.label, required this.content});

  final String label;
  final String content;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.xs, left: AppTheme.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w600, color: AppTheme.inkDim)),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 320),
            padding: const EdgeInsets.all(AppTheme.s),
            decoration: BoxDecoration(
              color: AppTheme.bg,
              borderRadius: BorderRadius.circular(AppTheme.s),
            ),
            child: SingleChildScrollView(
              child: Text(content,
                  style: const TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: AppTheme.inkDim)),
            ),
          ),
        ],
      ),
    );
  }
}

/// D-071: 「正在思考」指示器——💭 文案 + 三点错相脉冲。挂在列表末尾，
/// 只在模型被请求且尚无任何可上屏输出时出现（modelWorkingSilently）。
class _ThinkingIndicator extends StatelessWidget {
  const _ThinkingIndicator({
    super.key,
    required this.pulse,
    required this.label,
  });

  final AnimationController pulse;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.m, vertical: AppTheme.s),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(AppTheme.m),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11.5, color: AppTheme.inkDim)),
            const SizedBox(width: AppTheme.s),
            AnimatedBuilder(
              animation: pulse,
              builder: (context, _) => Row(
                children: [
                  for (final i in [0, 1, 2])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Opacity(
                        // 三点错相：每个点 1/3 周期，三角波明暗。
                        opacity: 0.25 +
                            0.75 * (1 - ((pulse.value * 3 - i) % 1 * 2 - 1).abs()),
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.accent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// D-069: 系统注入的摘要条——一行「标签 · 字数」，整行可点。收起时正文
/// 不参与渲染；展开时它是标题行（再点收回），全文列在其下。
class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.kind,
    required this.count,
    required this.open,
    required this.onTap,
  });

  final _MetaKind kind;
  final int count;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final label = switch (kind) {
      _MetaKind.systemReminder => l10n.chatMetaSystemReminder,
      _MetaKind.runtimeContext => l10n.chatMetaRuntimeContext,
      _MetaKind.injected => l10n.chatMetaInjected,
    };
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(open ? Icons.expand_less : Icons.expand_more,
                  size: 14, color: AppTheme.inkDim),
              const SizedBox(width: AppTheme.xs),
              Expanded(
                child: Text(l10n.chatMetaChip(label, count),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// D-069: 流式思考块。D-087 改版（2026-10-10）：对齐移动端惯例（Claude /
/// ChatGPT App）——思考中默认只显示 pill「💭 思考中 · N 字」（字数实时增长
/// 证明活着），点按展开看实时流、再点收起；回答正文一到自动收成
/// 「已思考 · N 字」。D-088 起 durable 气泡同样带 reasoning（引擎
/// 0.2.0-rc.2+ 落库 reasoning 块），历史会话的思考也可回看——不再是
/// 「durable 覆盖即消失」。`active` 只影响文案时态，不再强制展开正文。
class _ThinkingBlock extends StatelessWidget {
  const _ThinkingBlock({
    required this.reasoning,
    required this.open,
    required this.active,
    required this.onToggle,
  });

  final String reasoning;
  final bool open;
  final bool active;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final Widget header;
    if (active) {
      header = Text(
        reasoning.isEmpty
            ? l10n.chatThinkingActive
            : (open
                ? l10n.chatThinkingActiveExpanded(reasoning.length)
                : l10n.chatThinkingActiveCount(reasoning.length)),
        style: const TextStyle(fontSize: 11, color: AppTheme.inkDim),
      );
    } else {
      header = Text(
        open
            ? l10n.chatThoughtExpanded(reasoning.length)
            : l10n.chatThoughtCollapsed(reasoning.length),
        style: const TextStyle(fontSize: 11, color: AppTheme.inkDim),
      );
    }
    final showBody = open;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.m, vertical: AppTheme.xs),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.m),
        border: Border.all(color: AppTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: double.infinity,
              child: header,
            ),
          ),
          if (showBody)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.xs),
              child: Text(reasoning,
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.inkDim)),
            ),
        ],
      ),
    );
  }
}

/// Approval card (屏 E, L2 inline): the tool and its reason, then allow /
/// reject. The answer goes back as the bare wire string.
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.request,
    required this.l10n,
    required this.onAllow,
    required this.onReject,
  });

  final ApprovalRequest request;
  final L10n l10n;
  final VoidCallback onAllow;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final reason = request.reason;
    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.s),
      padding: const EdgeInsets.all(AppTheme.m),
      decoration: BoxDecoration(
        color: AppTheme.warn.withValues(alpha: 0.05),
        border: Border.all(color: AppTheme.warn.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(AppTheme.m),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, size: 15, color: AppTheme.warn),
              const SizedBox(width: AppTheme.xs),
              Expanded(
                child: Text('${l10n.chatApprovalTitle} · ${request.toolName}',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (reason != null && reason.isNotEmpty) ...[
            const SizedBox(height: AppTheme.xs),
            Text(reason,
                style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    color: AppTheme.inkDim)),
          ],
          const SizedBox(height: AppTheme.s),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onReject,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    foregroundColor: AppTheme.ink,
                  ),
                  child: Text(l10n.chatReject),
                ),
              ),
              const SizedBox(width: AppTheme.s),
              Expanded(
                child: FilledButton(
                  onPressed: onAllow,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    backgroundColor: AppTheme.accent,
                    foregroundColor: AppTheme.bg,
                  ),
                  child: Text(l10n.chatAllow),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Question card (屏 P) — a plan review is the same card in its specialized
/// shape: the plan body plus approve / decline matched **by label**.
class QuestionCard extends StatelessWidget {
  const QuestionCard({
    super.key,
    required this.planReview,
    required this.l10n,
    required this.onApprove,
    required this.onDecline,
  });

  final PlanReview? planReview;
  final L10n l10n;
  final VoidCallback? onApprove;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    if (planReview == null) {
      return Container(
        margin: const EdgeInsets.only(bottom: AppTheme.s),
        padding: const EdgeInsets.all(AppTheme.m),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(AppTheme.m),
        ),
        child: Text(l10n.chatQuestionPending,
            style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.s),
      padding: const EdgeInsets.all(AppTheme.m),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.05),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(AppTheme.m),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.chatPlanReviewTitle,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: AppTheme.xs),
          Text(planReview!.question,
              style: const TextStyle(fontSize: 12.5, color: AppTheme.ink)),
          const SizedBox(height: AppTheme.s),
          Container(
            constraints: const BoxConstraints(maxHeight: 160),
            padding: const EdgeInsets.all(AppTheme.s),
            decoration: BoxDecoration(
              color: AppTheme.bg,
              borderRadius: BorderRadius.circular(AppTheme.s),
            ),
            child: SingleChildScrollView(
              child: Text(planReview!.plan,
                  style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace', color: AppTheme.inkDim)),
            ),
          ),
          const SizedBox(height: AppTheme.s),
          Row(
            children: [
              if (onDecline != null)
                Expanded(
                  child: OutlinedButton(
                    onPressed: onDecline,
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36)),
                    child: Text(planReview!.decline!),
                  ),
                ),
              if (onDecline != null && onApprove != null) const SizedBox(width: AppTheme.s),
              if (onApprove != null)
                Expanded(
                  child: FilledButton(
                    onPressed: onApprove,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      backgroundColor: AppTheme.accent,
                      foregroundColor: AppTheme.bg,
                    ),
                    child: Text(planReview!.approve),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Context ring + statistics capsules (屏 L) above the composer.
class ContextBar extends StatelessWidget {
  const ContextBar({
    super.key,
    required this.controller,
    required this.l10n,
    this.onTap,
  });

  final ChatController controller;
  final L10n l10n;

  /// Opens the full breakdown (屏 L).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final values = controller.projections?.values;
    final pressure = values?.contextPressure;
    final stats = values?.sessionStats;
    final usage = values?.tokenUsage;

    // Absence is NOT zero: a missing projection means the engine has not
    // reported usage yet, so the ring shows nothing rather than a fake 0%.
    final ratio = pressure?.fillRatio;
    final tokensPerSecond = stats?.tokensPerSecond;
    final cacheHit = _cacheHitRate(usage);

    return InkWell(
      onTap: onTap,
      child: Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.l, vertical: AppTheme.s),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.line)),
      ),
      child: Row(
        children: [
          // D-076: 本会话所属 agent 预设——「由哪种 agent 处理」的常驻答案。
          // 数据来自 journal 首帧 header；引擎没给就不显示。
          if (ratio != null) ...[
            SizedBox(
              width: 17,
              height: 17,
              child: CircularProgressIndicator(
                value: ratio,
                strokeWidth: 2.4,
                backgroundColor: AppTheme.ink.withValues(alpha: 0.12),
                valueColor: const AlwaysStoppedAnimation(AppTheme.accent),
              ),
            ),
            const SizedBox(width: AppTheme.xs),
            Text(l10n.chatContextPercent((ratio * 100).round()),
                style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
          ] else
            Text(l10n.chatContextUnknown,
                style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
          if (controller.sessionPreset != null) ...[
            Icon(Icons.smart_toy_outlined, size: 12, color: AppTheme.inkDim),
            const SizedBox(width: 3),
            Flexible(
              child: Text(controller.sessionPreset!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
            ),
            const SizedBox(width: AppTheme.s),
          ],
          if (tokensPerSecond != null) ...[
            const SizedBox(width: AppTheme.s),
            _Pill(l10n.chatTokensPerSecond(tokensPerSecond.toStringAsFixed(1))),
          ],
          if (cacheHit != null) ...[
            const SizedBox(width: AppTheme.s),
            _Pill(l10n.chatCachePercent((cacheHit * 100).round())),
          ],
          const Spacer(),
          if (stats != null)
            Text(l10n.chatTurnsElapsed(stats.turns),
                style: const TextStyle(fontSize: 11, color: AppTheme.accent)),
          if (onTap != null)
            const Padding(
              padding: EdgeInsets.only(left: AppTheme.xs),
              child: Icon(Icons.open_in_full, size: 12, color: AppTheme.inkDim),
            ),
        ],
      ),
      ),
    );
  }

  /// Cache hits over total input; null when nothing has been counted yet.
  static double? _cacheHitRate(TokenUsageProjection? usage) {
    if (usage == null) return null;
    final total = usage.uncachedInputTokens + usage.cacheReadTokens;
    if (total <= 0) return null;
    return usage.cacheReadTokens / total;
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.s, vertical: 2),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 10.5, color: AppTheme.inkDim)),
      );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.text,
    required this.l10n,
    required this.readOnly,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController text;
  final L10n l10n;
  final bool readOnly;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    if (readOnly) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppTheme.l),
        color: AppTheme.surface,
        child: Text(l10n.chatReadOnly,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: AppTheme.inkDim)),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(AppTheme.m, AppTheme.s, AppTheme.s, AppTheme.s),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: text,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(fontSize: 13.5, color: AppTheme.ink),
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.chatComposerHint,
                hintStyle: const TextStyle(fontSize: 13, color: AppTheme.inkDim),
                border: const OutlineInputBorder(borderSide: BorderSide.none),
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: AppTheme.s),
          IconButton(
            onPressed: sending ? null : onSend,
            icon: sending
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send, size: 18, color: AppTheme.accent),
            tooltip: l10n.chatSend,
          ),
        ],
      ),
    );
  }
}
