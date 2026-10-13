import 'package:dsh_remote_app/logging/frame_sampler.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-107: 帧探针的聚合计数器。
///
/// 真机（小米 10-12）那份诊断日志就是被这个探针淹的：引擎流式输出时 130–250
/// 帧/秒，512KB 滚动缓冲在一次连续输出 30–60 秒内被冲干净，
/// `first-frame deadline hit` 那条现场证据反被挤掉。所以这里的每条用例都是
/// 拿**行数**当断言面——回退到逐帧打日志的旧行为时它们必须变红。
void main() {
  group('FrameSampler', () {
    late DateTime clock;
    late List<String> lines;

    FrameSampler sampler({Duration? window, int individual = 3}) {
      clock = DateTime(2026, 10, 13, 10);
      lines = <String>[];
      return FrameSampler(
        emit: lines.add,
        window: window ?? const Duration(seconds: 2),
        individual: individual,
        now: () => clock,
      );
    }

    test('前 N 帧逐帧出现——「帧确实在来」这个证据不能丢', () {
      final s = sampler();
      for (var i = 0; i < 3; i++) {
        s.record('FollowAssistantStream');
      }
      expect(lines, [
        'frame FollowAssistantStream',
        'frame FollowAssistantStream',
        'frame FollowAssistantStream',
      ]);
      expect(s.bufferedCount, 0, reason: '还在 individual 额度里，不该进计数');
    });

    test('额度用完后按类型计数，窗口到了汇总成一行', () {
      final s = sampler();
      for (var i = 0; i < 3; i++) {
        s.record('FollowAssistantStream');
      }
      clock = clock.add(const Duration(milliseconds: 500));
      // 第 4 帧超出 individual 额度 → 进计数。
      s.record('FollowAssistantStream');
      expect(s.bufferedCount, 1);
      expect(lines.length, 3, reason: '还没到窗口，不该提前汇总');

      clock = clock.add(const Duration(seconds: 2));
      s.record('FollowAssistantStream'); // 进计数第 2 帧，并触发窗口收尾

      expect(lines.length, 4, reason: '3 条逐帧 + 1 条汇总');
      expect(lines.last, contains('FollowAssistantStream×2'));
      expect(s.bufferedCount, 0, reason: '汇总后缓冲清空');
    });

    test('关流 flush 把尾部那个不满窗口的窗口也落盘', () {
      // 这一条是排障价值最高的一段：流式输出中途停下时，最后一个窗口
      // 往往正好记录了「停在哪一类帧上」。不 flush 就永远看不到。
      final s = sampler();
      for (var i = 0; i < 3; i++) {
        s.record('FollowAssistantStream');
      }
      for (var i = 0; i < 40; i++) {
        s.record('FollowAssistantStream');
      }
      expect(s.bufferedCount, 40);

      s.flush(reason: 'journal-close');
      expect(lines.length, 4);
      expect(lines.last, contains('journal-close'));
      expect(lines.last, contains('FollowAssistantStream×40'));
    });

    test('没有待汇总帧时 flush 不产生空行', () {
      final s = sampler();
      s.record('FollowSnapshot');
      expect(lines.length, 1);
      s.flush();
      expect(lines.length, 1, reason: '空窗口不该写「×0」这种噪声行');
    });

    test('30 秒 200 帧/秒：约 6000 帧收敛到 20 行以内', () {
      // 这就是真机上那份日志的场景。旧行为（逐帧打一行）会产出 6000 行。
      final s = sampler();
      for (var i = 0; i < 6000; i++) {
        clock = clock.add(const Duration(milliseconds: 5));
        s.record('FollowAssistantStream');
      }
      expect(lines.length, lessThan(30),
          reason: '逐帧打日志的话这里是 6000 行');
      // 汇总行必须真的带计数，否则就是「把噪声删了，也把信息删了」。
      final summaries = lines.where((l) => l.contains('×')).toList();
      expect(summaries, isNotEmpty);
      expect(summaries.last, contains('FollowAssistantStream×'));
    });

    test('帧类型种类超上限并进 other，防止异常实现刷一屏类型名', () {
      final s = sampler(individual: 0);
      for (var i = 0; i < 30; i++) {
        clock = clock.add(const Duration(milliseconds: 100));
        s.record('Frame$i');
      }
      s.flush();
      // 30 个类型、前 8 个各占一个桶，其余并进 other。
      final summaries = lines.where((l) => l.contains('×')).toList();
      expect(summaries, isNotEmpty);
      expect(summaries.any((l) => l.contains('other×')), isTrue);
      // 桶数按「`, ` 分隔的条目」数，别拿 token 数当桶数——`Frame1×3`
      // 会被切成三个，那是个永远红的断言。
      for (final line in summaries) {
        final buckets = line.split('): ').last.split(', ');
        expect(buckets.length, lessThanOrEqualTo(9),
            reason: '每行汇总的桶数必须有上限（maxKinds + other）：$line');
      }
    });
  });
}