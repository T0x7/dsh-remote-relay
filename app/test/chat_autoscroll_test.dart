import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-072：流式输出时的滚动跟随。
///
/// 真机反馈：模型输出时新内容长在视口下面，列表不跟着走，得手动滑。
/// 规则对齐成熟聊天 App：
/// 1. **贴底即跟随**——用户在列表底部（±80px）时，内容增长自动钉住底部；
/// 2. **上滚不拽人**——用户往上翻历史时不自动拉回，右下角出现
///    「回到底部」悬浮钮，点它或手动滑回底部即恢复跟随。
///
/// 滚动位置经 ScrollableState 读取；动画/帧时序一律定长 pump。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

SessionWireEvent _userMessage(int seq, String text) => SessionWireEvent(
      type: 'user/message',
      seq: seq,
      time: DateTime.now().millisecondsSinceEpoch,
      data: {
        'id': 'm$seq',
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'user'},
        'role': 'user',
      },
    );

FollowSnapshot _snapshot({
  String id = 'session-1',
  List<FollowEvent> records = const [],
}) =>
    FollowSnapshot(
      header: SessionHeader(version: 4, id: id, createdAt: 0, isSeeded: false),
      cursor: 0,
      records: records,
      hasMore: false,
      projections: const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
    );

FollowAssistantStream _frame(Map<String, Object?> json) =>
    FollowAssistantStream(json);

/// 测试台：controller + gateway 一起交出。D-102 需要在「手指按住」期间往
/// 事件流里灌新记录，所以用例得自己能 pushFrame。
typedef _ChatHarness = ({ChatController controller, FakeEngineGateway gateway});

Future<_ChatHarness> _openConsole(
  WidgetTester tester, {
  String sessionId = 'session-1',
  List<FollowEvent> records = const [],
}) async {
  final gateway = FakeEngineGateway();
  final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero)
    ..startEvents();
  gateway.raiseReady();
  await controller.open(sessionId);
  addTearDown(() async {
    controller.dispose();
    await gateway.dispose();
  });
  await tester.pumpWidget(_host(ChatPane(controller: controller)));
  gateway.pushFrame(_snapshot(id: sessionId, records: records));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (controller: controller, gateway: gateway);
}

ScrollPosition _listPosition(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find.descendant(
          of: find.byType(ListView), matching: find.byType(Scrollable)),
    ).position;

void _delta(ChatController controller, int revision, String text) =>
    controller.applyFrame(_frame({
      'type': 'chunk',
      'attemptId': 'att-1',
      'revision': revision,
      'index': 1,
      'turn': 1,
      'step': 1,
      'chunk': {'type': 'text-delta', 'text': text},
    }));

void _beginTurn(ChatController controller) => controller.applyFrame(_frame({
  'type': 'start',
  'attemptId': 'att-1',
  'revision': 1,
  'index': 0,
  'turn': 1,
  'step': 1,
}));

/// 造一份远超视口的内容并进入「贴底跟随」态——D-102 的前置条件。
Future<void> _pumpStickyBottom(
    WidgetTester tester, ChatController controller) async {
  _beginTurn(controller);
  _delta(controller, 2, '输出' * 2500);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  final p = _listPosition(tester);
  expect(p.pixels, greaterThan(p.maxScrollExtent - 4),
      reason: '前置条件：此刻应处于贴底跟随态');
}

/// 手指按住列表拖一段但**还没抬手**。
Future<TestGesture> _dragHeld(
    WidgetTester tester, {List<Offset> moves = const [Offset(0, 200)]}) async {
  final gesture =
      await tester.startGesture(tester.getCenter(find.byType(ListView)));
  for (final move in moves) {
    await gesture.moveBy(move);
    await tester.pump();
  }
  return gesture;
}

void main() {
  testWidgets('流式输出增长时贴底跟随：视口始终钉在最新内容', (tester) async {
    final harness = await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '开始输出'))]);
    final controller = harness.controller;
    controller.applyFrame(_frame({
      'type': 'start',
      'attemptId': 'att-1',
      'revision': 1,
      'index': 0,
      'turn': 1,
      'step': 1,
    }));
    // 第一段长文本：内容撑爆视口。
    _delta(controller, 2, '输出' * 2500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final p1 = _listPosition(tester);
    expect(p1.pixels, greaterThan(p1.maxScrollExtent - 4),
        reason: '贴底状态下内容增长应自动钉在底部');

    // 第二段：继续增长，依旧跟随。
    _delta(controller, 3, '继续' * 700);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final p2 = _listPosition(tester);
    expect(p2.pixels, greaterThan(p2.maxScrollExtent - 4));
  });

  testWidgets('用户上滚看历史：不被拽回，悬浮钮出现，点它回底', (tester) async {
    final harness = await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '开始输出'))]);
    final controller = harness.controller;
    controller.applyFrame(_frame({
      'type': 'start',
      'attemptId': 'att-1',
      'revision': 1,
      'index': 0,
      'turn': 1,
      'step': 1,
    }));
    // 第一段：内容远超视口（~5000 字），让 600px 的 drag 滚不到头。
    _delta(controller, 2, '输出' * 2500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 用户上滚 600px 阅读历史。
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final before = _listPosition(tester);
    expect(before.pixels, lessThan(before.maxScrollExtent - 80),
        reason: 'drag 应该真的把列表滚离底部');
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsOneWidget,
        reason: '离底了就该给一颗回底按钮');

    // 内容继续增长：不拽人。
    _delta(controller, 3, '新增' * 2500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final after = _listPosition(tester);
    expect(after.pixels, lessThan(after.maxScrollExtent - 100),
        reason: '用户在看历史，自动跟随必须闭嘴');

    // 点悬浮钮回底，恢复跟随。
    await tester.tap(find.byKey(const ValueKey('scroll-to-bottom')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final back = _listPosition(tester);
    expect(back.pixels, greaterThan(back.maxScrollExtent - 4));
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing);
  });

  /// D-102：手指按住列表时的密集事件流不得把滚动位置抢回去。
  ///
  /// 真机症状（小米，子会话）：点过「回到底部」之后对话列表**手势彻底失灵**
  /// ——滑动无反应、再点回底也没用，切走 tab 再切回来立刻恢复；进程 CPU 3.4%
  /// （非忙循环）、无 ANR、logcat 无 flutter 异常、tab 切换正常。
  ///
  /// 病根是「自动贴底」与「用户手势」抢同一条滚动位置：贴底开关原先靠 ±80px
  /// 阈值判断，而阈值判定发生在手势开始**之后**；密集事件流（后台恢复重放、
  /// 投影刷新就是这种形态）在那几帧里每帧一次 postFrame `jumpTo`，落在手势
  /// 中途就把 drag 打断。回底那阵又叠加 `animateTo` 的递归补跳——动画被打
  /// 断后 `whenComplete` 立刻排下一次 animate，状态机自己跟自己打转。
  ///
  /// 修法：用户手势一落上列表就让自动贴底闭嘴（`_dragging`），回底改同步
  /// `jumpTo`，没有 activity 可抢。
  testWidgets('D-102 手势进行中：密集事件流不得把列表拽回底部', (tester) async {
    final harness = await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '开始输出'))]);
    final controller = harness.controller;
    await _pumpStickyBottom(tester, controller);

    // 手指按下往上拖一点点（**手指还按着**）。注意这里只拖 60px：仍在 ±80px
    // 的贴底阈值内——这正是旧逻辑的盲区，它只能看到「滑完之后还在不在底部」，
    // 看不到「此刻有人正按着列表」。
    final gesture = await _dragHeld(tester, moves: const [Offset(0, 60)]);
    final held = _listPosition(tester);
    expect(held.pixels, lessThan(held.maxScrollExtent - 1),
        reason: '前置条件：drag 应该真的把列表推开一点');

    // 手指还按着，事件流密集到来——后台恢复重放/投影刷新就是这种形态。
    for (var i = 0; i < 8; i++) {
      _delta(controller, 3 + i, '追加' * 800);
    }
    // 必须推进时钟：`applyFrame` 的通知被 48ms 的 stream-paint 合并定时器
    // 延后（`ChatController._scheduleStreamPaint`）。只 pump() 零时长的���，通知
    // 压根没落地，守门就成了摆设——这一条曾经把假绿放过去。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final afterEvents = _listPosition(tester);
    // 手指往上拖，pixels 只会变小；自动贴底只会把它**往上**拽回
    // maxScrollExtent。「不许变大」正是这条守门的全部要害。
    expect(afterEvents.pixels, lessThanOrEqualTo(held.pixels + 1),
        reason: '手势进行中不得被自动跳底：手指说了算（修复前这里被每帧的 '
            'postFrame jumpTo 拽回 maxScrollExtent）');
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing,
        reason: '手势进行中不给回底钮（拇指底下，还可能被同一次手势误命中）');

    // 拖成真正的历史区再抬手：回底钮该出现，点它还能回底——这条路径是用户
    // 在「列表没反应」时的唯一逃生出口，必须一直是通的。
    await gesture.moveBy(const Offset(0, 400));
    await gesture.up();
    // 冲一次时钟：stream-paint 的 48ms 定时器不清掉，testWidgets 会报
    // "A Timer is still pending"。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final settled = _listPosition(tester);
    expect(settled.pixels, lessThan(settled.maxScrollExtent - 80),
        reason: '松手后仍留在历史区，不得被弹回底部');
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsOneWidget,
        reason: '离底后应给出回底钮');

    await tester.tap(find.byKey(const ValueKey('scroll-to-bottom')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final back = _listPosition(tester);
    expect(back.pixels, greaterThan(back.maxScrollExtent - 80),
        reason: '回底必须一次到位');
  });

  /// D-102 续：真机上「点回底也没用」的那一步。回底必须**同步一次到位**
  /// （修复前是 220ms `animateTo`：被事件流打断 → `whenComplete` 重排下一次
  /// 动画，状态机自己跟自己打转），且回底之后紧接着的新手势必须立即生效。
  testWidgets('D-102 点回底之后：新手势立即生效，事件流也抢不走', (tester) async {
    final harness = await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '开始输出'))]);
    final controller = harness.controller;
    await _pumpStickyBottom(tester, controller);

    // 先离底，才能有回底钮可点。
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsOneWidget);

    // 事件流仍在密集到来时点回底。
    for (var i = 0; i < 5; i++) {
      _delta(controller, 3 + i, '追加' * 800);
    }
    await tester.tap(find.byKey(const ValueKey('scroll-to-bottom')));
    // 只过一帧、**不推进动画时长**：同步 jumpTo 必须已经到底（修复前是
    // 220ms animateTo，此刻几乎还在起点）。
    await tester.pump();
    final bottom = _listPosition(tester);
    expect(bottom.pixels, greaterThan(bottom.maxScrollExtent - 80),
        reason: '回底必须一次到位，不能依赖一段可被打断的动画');
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing,
        reason: '回底后恢复跟随，按钮应当消失');

    // 紧接着的新手势：轻轻上移 60px（仍在贴底阈值内）探一眼历史，同时事件
    // 流继续到达。修复前这一档会被判定成「还在底部」而重新开启跟随。
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    final peeked = _listPosition(tester).pixels;

    for (var i = 0; i < 6; i++) {
      _delta(controller, 20 + i, '再追加' * 800);
    }
    await tester.pump();
    // 同样必须推进时钟，让 48ms 的 stream-paint 定时器把通知放出来。
    await tester.pump(const Duration(milliseconds: 100));
    expect(_listPosition(tester).pixels, lessThanOrEqualTo(peeked + 1),
        reason: '新手势进行中不得被拽回底部（真机症状：列表整体手势失灵）');
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  });
  /// D-103：换到**空会话**后不得残留回底钮。
  ///
  /// 真机（小米）：在长会话里往上翻了历史，接着新建一个 0 轮空会话——
  /// 右下角那颗「回到底部」仍然亮着，而列表里连一个气泡都没有，根本没有
  /// 「底」可回。
  ///
  /// 病根（探针实锤，不是猜的）：ConsolePage 新建会话时**复用同一个
  /// ChatController**（调 `open()` 换 sessionId），于是 ChatPane 的
  /// widget/controller 都没换——`didUpdateWidget` 里那条「换会话就复位
  /// 贴底开关」根本没执行，`_followBottom=false` 原样带进了空会话；而空
  /// 列表不会再产生任何滚动事件去纠正它，按钮就一直挂在那儿。
  ///
  /// 修法两处：① ChatPane 在 build 里按 sessionId 变化复位（真正收到
  /// 「换会话」信号的地方）；② 按钮显隐加「列表里有东西」兜底。
  testWidgets('D-103 换到空会话：不残留回底钮', (tester) async {
    final harness = await _openConsole(
        tester, records: [FollowEvent(_userMessage(1, '开始输出'))]);
    final controller = harness.controller;
    await _pumpStickyBottom(tester, controller);

    // 先离底：此刻回底钮理应出现，贴底开关置 false。
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsOneWidget,
        reason: '前置条件：离底后回底钮应出现');

    // 走真机那条路：**同一个 controller** 再 open 另一个（空）会话。
    // 必须包在 runAsync 里——`open` 首行 `await _closeJournal()` 会等旧流
    // 关闭，在 testWidgets 的 FakeAsync 区里直接 await 会把测试吊死。
    await tester.runAsync(() async {
      await controller.open('session-2');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      harness.gateway.pushFrame(_snapshot(id: 'session-2', records: const []));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.bubbles, isEmpty, reason: '前置条件：这确实是个空会话');
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing,
        reason: '空会话没有任何东西可回，不该残留回底钮');
  });
}
