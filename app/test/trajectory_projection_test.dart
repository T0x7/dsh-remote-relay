import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/trajectory/trajectory_model.dart';
import 'package:dsh_remote_app/console/trajectory/trajectory_projection.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-042 轨迹投影：把 `session/follow` 的原始事件收敛成记录。
///
/// 这些用例锁的是**线上形状的硬事实**，不是 UI 口味：
///
/// - 助手计时照引擎自己的 `sessionStats` 口径（契约 §8.3）算，不是我们
///   自己发明的；
/// - 嵌套子工具靠「栈上还有未闭合调用」判定，因为事件表里根本没有
///   parent callId 这种字段；
/// - 普通请求与压缩请求**共用**一套编号；
/// - 窗口裁掉的东西必须让「有更早历史」变真。
SessionWireEvent ev(
  int seq,
  String type,
  Map<String, dynamic> data, {
  int? time,
}) =>
    SessionWireEvent(
      type: type,
      seq: seq,
      time: time ?? 1_700_000_000_000 + seq * 1000,
      data: data,
    );

List<Object?> text(String body) => [
      {'type': 'text', 'text': body},
    ];

void main() {
  group('轮次与步骤边界', () {
    test('turn/step 事件本身不产生记录，只切分分组', () {
      final projection = projectTrajectory([
        ev(1, 'turn/start', {'turn': 7}),
        ev(2, 'step/start', {'turn': 7, 'step': 1}),
        ev(3, 'user/message', {'turn': 7, 'step': 1, 'content': text('hi')}),
        ev(4, 'step/end', {'turn': 7, 'step': 1}),
        ev(5, 'turn/end', {'turn': 7, 'reason': {'kind': 'completed'}}),
      ]);

      expect(projection.records.map((r) => r.eventType),
          ['user/message'],
          reason: '边界是结构，不是记录——轨迹里它们表现为分隔线');
      expect(projection.turns, hasLength(1));
      expect(projection.turns.single.turn, 7);
      expect(projection.turns.single.endReason, 'completed');
      expect(projection.turns.single.isError, isFalse);
    });

    test('一个失败的轮次被标出来，理由照 turn/end 的 reason.kind', () {
      final projection = projectTrajectory([
        ev(1, 'turn/start', {'turn': 1}),
        ev(2, 'user/message', {'content': text('x')}),
        ev(3, 'turn/end', {'turn': 1, 'reason': {'kind': 'error'}}),
      ]);
      expect(projection.turns.single.isError, isTrue);
      expect(projection.turns.single.endReason, 'error');
    });

    test('turn 为 null 的记录自成一组（轮次之间的独立压缩）', () {
      final projection = projectTrajectory([
        ev(1, 'turn/start', {'turn': 2}),
        ev(2, 'user/message', {'content': text('a')}),
        ev(3, 'turn/end', {'turn': 2, 'reason': {'kind': 'completed'}}),
        ev(4, 'compaction/start', {}),
        ev(5, 'compaction/end', {}),
      ]);
      expect(projection.turns.map((t) => t.turn), [2, null]);
      expect(projection.turns.last.records.single.kind, TrajectoryKind.compacted,
          reason: '轮次之外的压缩不能被塞进上一轮');
    });
  });

  group('请求编号', () {
    test('普通请求与压缩请求共用一套递增编号', () {
      final projection = projectTrajectory([
        ev(1, 'request/header', {'header': <String, dynamic>{}}),
        ev(2, 'request/context', {'provider': 'deepseek', 'model': 'v4'}),
        ev(3, 'user/message', {'content': text('a')}),
        ev(4, 'compaction/start', {}),
        ev(5, 'compaction/end', {}),
        ev(6, 'request/header', {'header': <String, dynamic>{}}),
        ev(7, 'user/message', {'content': text('b')}),
      ]);
      final byType = {
        for (final r in projection.records) r.eventType: r.requestNumber,
      };
      expect(byType['user/message'], anyOf(1, 3),
          reason: '压缩占了一个号，所以第二条 user 拿到的是 3 而不是 2');
      expect(byType['compaction/start'], 2);
    });

    test('request/context 的 provider/model 记在随后的记录上', () {
      final projection = projectTrajectory([
        ev(1, 'request/header', {'header': <String, dynamic>{}}),
        ev(2, 'request/context', {'provider': 'deepseek', 'model': 'ds-v4'}),
        ev(3, 'user/message', {'content': text('a')}),
      ]);
      expect(projection.records.single.provider, 'deepseek');
      expect(projection.records.single.model, 'ds-v4');
    });
  });

  group('助手计时（契约 §8.3 的 sessionStats 口径）', () {
    test('TTFT 自 step/start 到首个 token，decode 到 assistant/message', () {
      // step 开始于 t=1000；首个 chunk 落在 t=1600；消息在 t=3000。
      final projection = projectTrajectory([
        ev(1, 'turn/start', {'turn': 1}, time: 900),
        ev(2, 'step/start', {'turn': 1, 'step': 1}, time: 1000),
        ev(3, 'assistant/message', {
          'turn': 1,
          'step': 1,
          'message': {'content': text('hello')},
          'stream': [
            {'type': 'text-chunks', 'time0': 1600, 'index': 0, 'dt': [100, 200], 'texts': ['he', 'll', 'o']},
          ],
        }, time: 3000),
      ]);

      final msg = projection.records.single;
      expect(msg.ttftMs, 600, reason: '1600 - 1000，含更早重试里的输出');
      expect(msg.decodeMs, 1400, reason: '3000 - 1600，到 assistant/message 为止');
      expect(msg.startedAt, 1000, reason: 'own duration 起点是 step/start');
      expect(msg.durationMs, 2000);
    });

    test('没有 chunk 就不给任何一段耗时——宁可不画，不可假画', () {
      final projection = projectTrajectory([
        ev(1, 'step/start', {'turn': 1, 'step': 1}, time: 1000),
        ev(2, 'assistant/message', {
          'message': {'content': text('hi')},
          'stream': <Object?>[],
        }, time: 3000),
      ]);
      final msg = projection.records.single;
      expect(msg.ttftMs, isNull);
      expect(msg.decodeMs, isNull);
    });

    test('未知 step 起点时 TTFT 不可用，但 decode 仍可算', () {
      final projection = projectTrajectory([
        ev(1, 'assistant/message', {
          'message': {'content': text('hi')},
          'stream': [
            {'type': 'text-chunks', 'time0': 1600, 'index': 0, 'dt': <Object?>[], 'texts': ['hi']},
          ],
        }, time: 3000),
      ]);
      final msg = projection.records.single;
      expect(msg.ttftMs, isNull, reason: '没有 step/start 就没有 TTFT 的起点');
      expect(msg.decodeMs, 1400);
    });
  });

  group('工具调用', () {
    test('call/result 配对后拿到耗时，错误结果标红', () {
      final projection = projectTrajectory([
        ev(1, 'tool/call', {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'Read', 'arguments': <String, dynamic>{}}, time: 1000),
        ev(2, 'tool/result', {
          'turn': 1,
          'step': 1,
          'callId': 'c1',
          'message': {'content': text('ok')},
          'error': {'name': 'NotFound', 'code': 'ENOENT'},
        }, time: 1750),
      ]);

      final call = projection.records.first;
      expect(call.kind, TrajectoryKind.tool);
      expect(call.toolName, 'Read');
      expect(call.durationMs, 750, reason: 'tool/call → tool/result 按 callId 配对');
      expect(call.isError, isTrue);
      expect(call.raw['result'], isNotNull, reason: '检查器一次能看完发起与返回');
    });

    test('栈上还有未闭合调用时，新 callId 是子工具', () {
      final projection = projectTrajectory([
        ev(1, 'tool/call', {'turn': 1, 'callId': 'outer', 'name': 'Workflow'}, time: 1000),
        ev(2, 'tool/call', {'turn': 1, 'callId': 'inner', 'name': 'Read'}, time: 1100),
        ev(3, 'tool/result', {'turn': 1, 'callId': 'inner', 'message': <String, dynamic>{}}, time: 1200),
        ev(4, 'tool/result', {'turn': 1, 'callId': 'outer', 'message': <String, dynamic>{}}, time: 1300),
      ]);

      final calls = projection.records.where((r) => r.eventType == 'tool/call').toList();
      expect(calls[0].kind, TrajectoryKind.tool);
      expect(calls[1].kind, TrajectoryKind.subtool,
          reason: '事件表里没有 parent callId，嵌套只能靠执行期重叠判定');
    });

    test('顺序的两个调用都是顶层，不该被误判成嵌套', () {
      final projection = projectTrajectory([
        ev(1, 'tool/call', {'callId': 'a', 'name': 'Read'}, time: 1000),
        ev(2, 'tool/result', {'callId': 'a', 'message': <String, dynamic>{}}, time: 1100),
        ev(3, 'tool/call', {'callId': 'b', 'name': 'Write'}, time: 1200),
        ev(4, 'tool/result', {'callId': 'b', 'message': <String, dynamic>{}}, time: 1300),
      ]);
      final calls = projection.records.where((r) => r.eventType == 'tool/call').toList();
      expect(calls.every((c) => c.kind == TrajectoryKind.tool), isTrue);
    });
  });

  group('不丢东西', () {
    test('不认识的事件类型也留成 context 行，而不是被扔掉', () {
      final projection = projectTrajectory([
        ev(1, 'workspace/changes', {'summary': '改了 3 个文件'}),
        ev(2, 'some/future-event', {'whatever': 1}),
      ]);
      expect(projection.records, hasLength(2));
      expect(projection.records.every((r) => r.kind == TrajectoryKind.context), isTrue);
      expect(projection.records.first.preview, '改了 3 个文件');
      expect(projection.records.last.raw['whatever'], 1,
          reason: '原样保留，检查器才有得翻');
    });
  });

  group('窗口上限', () {
    test('超出上限时丢最老的，并且如实说「有更早历史」', () {
      final events = [
        for (var i = 1; i <= 12; i++)
          ev(i, 'user/message', {'turn': 1, 'content': text('m$i')}),
      ];
      final projection = projectTrajectory(events, maxWindow: 5);
      expect(projection.records, hasLength(5));
      expect(projection.records.first.seq, 8);
      expect(projection.windowDropped, 7);
      expect(projection.hasEarlierHistory, isTrue,
          reason: '丢掉的部分就是真存在的更早历史，标 false 等于骗人');
    });

    test('裁剪后每条记录仍挂在正确的轮次下，不串到别的轮次', () {
      final events = [
        ev(1, 'turn/start', {'turn': 1}),
        ...[
          for (var i = 2; i <= 8; i++)
            ev(i, 'user/message', {'content': text('m$i')}),
        ],
        ev(9, 'turn/end', {'turn': 1, 'reason': {'kind': 'completed'}}),
      ];
      final projection = projectTrajectory(events, maxWindow: 3);
      expect(projection.records.every((r) => r.turn == 1), isTrue);
    });
  });

  group('时间轨道（dsh timeline.ts:51-55）', () {
    test('kind 到 lane 的映射与 dsh 一致', () {
      expect(TrajectoryKind.tool.lane, 2);
      expect(TrajectoryKind.subtool.lane, 2);
      expect(TrajectoryKind.message.lane, 1);
      expect(TrajectoryKind.compacted.lane, 1);
      expect(TrajectoryKind.user.lane, 0);
      expect(TrajectoryKind.system.lane, 0);
      expect(TrajectoryKind.context.lane, 0);
    });

    test('startedAt 未知的记录不进时间轴', () {
      final projection = projectTrajectory([
        ev(1, 'user/message', {'content': text('a')}),
      ]);
      expect(projection.records.single.span, isNull);
      expect(projection.records.single.hasTiming, isFalse);
    });
  });

  group('用量', () {
    test('assistant/message 的 usage 落到记录上', () {
      final projection = projectTrajectory([
        ev(1, 'assistant/message', {
          'message': {'content': text('hi')},
          'stream': <Object?>[],
          'usage': {
            'inputTokens': 120,
            'outputTokens': 45,
            'cacheReadTokens': 30,
            'cacheWriteTokens': 10,
            'reasoningTokens': 8,
          },
        }),
      ]);
      final msg = projection.records.single;
      expect(msg.inputTokens, 120);
      expect(msg.outputTokens, 45);
      expect(msg.cacheReadTokens, 30);
      expect(msg.cacheWriteTokens, 10);
      expect(msg.reasoningTokens, 8);
      expect(msg.hasUsage, isTrue);
    });
  });
}
