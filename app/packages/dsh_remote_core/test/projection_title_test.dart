import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:test/test.dart';

/// D-063：工作区列表里的会话显示 id 而不是标题——根因是 App 把引擎给的
/// 标题数据扔了。
///
/// 引擎侧三个层级（全部实测确认，2026-10-05）：
///
/// 1. `projections.values.title` —— `session/list` 响应里 58/62 条都有。
///    但质量分三类：真标题（「盘中雷达候选精评任务」）、**首条消息截断**
///    （37 条「今天是 2026-10-05。当前时刻 21:3…」、20 条
///    「system-reminder 开头的子代理提示词」）——这两类不是标题，是
///    「第一条用户消息的开头」被当成标题存了下来。
/// 2. `header.title`（durable，用户改名/自动生成）——只在 `session/follow`
///    首帧里（D-059/D-062 已接）。
/// 3. id —— 什么都没有时的兜底。
///
/// 之前 `Projections.fromJson` **根本没有 title 字段**：数据在响应里，
/// App 把它扔了，然后用「引擎不提供」解释了现象。这条测试钉住解析层。
void main() {
  group('D-063 Projections 解析 title', () {
    test('从 wire 里解出 title', () {
      final p = Projections.fromJson({
        'title': '盘中雷达候选精评任务',
      });
      expect(p.title, '盘中雷达候选精评任务');
    });

    test('没有 title 时是 null（不是空串）——absence ≠ zero', () {
      final p = Projections.fromJson(const {});
      expect(p.title, isNull);
    });

    test('titleLike：真标题为真', () {
      expect(
        Projections.fromJson({'title': '盘中雷达候选精评任务'}).titleLike,
        '盘中雷达候选精评任务',
      );
    });

    test('titleLike：日期首行截断不是标题', () {
      // 这是定时任务最常见的「假标题」：host-app 的任务提示词第一行
      // 就是「今天是 YYYY-MM-DD。当前时刻 HH:mm」。
      expect(
        Projections.fromJson({'title': '今天是 2026-10-05。当前时刻 21:35'}).titleLike,
        isNull,
        reason: '把首条消息的日期行当标题显示，用户看到的 37 条会话全长一样',
      );
    });

    test('titleLike：子代理的 system-reminder 截断不是标题', () {
      expect(
        Projections.fromJson({
          'title': '<system-reminder> You are teammate "risk-scout"…',
        }).titleLike,
        isNull,
        reason: '这是子代理提示词的开头，不是人起的名字',
      );
    });

    test('titleLike：空白不是标题', () {
      expect(Projections.fromJson({'title': '   '}).titleLike, isNull);
      expect(Projections.fromJson({'title': ''}).titleLike, isNull);
      expect(Projections.fromJson(const {}).titleLike, isNull);
    });

    test('titleLike：长截断但内容真实的标题仍算标题（不误伤）', () {
      // 真标题也可能很长（用户手打的），不以「今天是」开头就放行。
      expect(
        Projections.fromJson({'title': '国庆前最后的调仓思路讨论'}).titleLike,
        '国庆前最后的调仓思路讨论',
      );
    });
  });
}
