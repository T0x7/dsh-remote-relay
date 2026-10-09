import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:test/test.dart';

/// D-065：`job-*` 会话的 id 里藏着可读名字，别让用户看整串。
///
/// host-app 的 scheduler 用 `job-<任务名>-<YYYYMMDD>-<HHMMSS>` 当会话 id。
/// 实测 2026-10-05 的 62 个会话里 37 个是这种形状：`job-cnradar-20261005-110450`、
/// `job-hkradar-20261005-155119`……它们的投影 title 全是日期行（任务提示词的
/// 首行截断，见 D-063 的 titleLike 过滤），所以引擎侧**没有**更好的名字——
/// 但 id 本身就编码了「哪个任务 + 哪天几点」，比一串不换行的
/// `job-cnradar-20261005-110450` 可读得多。
///
/// 解析出来的显示形如「cnradar · 10-05 11:04」。解析不了的（裸 uuid、
/// `session-*`）原样返回——那是 D-063 兜底的活，不抢。
SessionSummary _row(String id) => SessionSummary(
      sessionId: id,
      updatedAt: 1790000000000,
      running: false,
      blank: false,
      agentAvailable: true,
    );

void main() {
  group('D-065 scheduler 会话 id 的可读化', () {
    test('标准形状：任务名 + 月-日 + 时:分', () {
      final row = _row('job-cnradar-20261005-110450');
      expect(readableSessionName(row), 'cnradar · 10-05 11:04');
    });

    test('任务名自身含连字符时不被切断', () {
      // guba-judge / intraday-review / news-digest 都是两段任务名。
      final row = _row('job-intraday-review-20261005-160047');
      expect(readableSessionName(row), 'intraday-review · 10-05 16:00');
    });

    test('小时补零：0 点整不显示成 0:5', () {
      final row = _row('job-morning-20261005-000509');
      expect(readableSessionName(row), 'morning · 10-05 00:05');
    });

    test('已有投影真标题时让位给标题', () {
      final row = SessionSummary(
        sessionId: 'job-cnradar-20261005-110450',
        updatedAt: 1790000000000,
        running: false,
        blank: false,
        agentAvailable: true,
        projections: SessionProjectionHints.fromJson({
          'values': {
            'title': '盘中雷达候选精评任务',
          },
        }),
      );
      expect(readableSessionName(row), '盘中雷达候选精评任务',
          reason: '用户起的名字永远比解析 id 的猜测优先');
    });

    test('非 scheduler 形状原样返回，不硬解析', () {
      expect(readableSessionName(_row('session-3dc80192-1ddb')), 
             'session-3dc80192-1ddb');
      expect(readableSessionName(_row('31a580dc-bd6a-48bc')),
             '31a580dc-bd6a-48bc');
    });

    test('形状对但时间非法也原样返回（防御性）', () {
      // 13 月、61 秒——scheduler 不会生成，但解析器不该因此崩或输出怪东西。
      expect(readableSessionName(_row('job-x-20261305-610450')),
             'job-x-20261305-610450');
    });
  });

  group('D-066 子代理会话：subagent.label 就是它的名字', () {
    SessionSummary subRow(String id, String label) => SessionSummary(
          sessionId: id,
          updatedAt: 1790000000000,
          running: false,
          blank: false,
          agentAvailable: true,
          projections: SessionProjectionHints.fromJson({
            'values': {
              'subagent': {'mode': 'continuable', 'seq': 0, 'label': label},
            },
          }),
        );

    test('裸 uuid 的子代理显示 label', () {
      final row = subRow('791e5254-0b1f', '中新赛克(002912)调查案 risk 终局质询');
      expect(readableSessionName(row), '中新赛克(002912)调查案 risk 终局质询');
    });

    test('label 超长时截断到一行可读的长度（省略号）', () {
      // 真实数据：80+ 字的中文 label 在列表行里会折成三行。
      final row = subRow('e014bd3f-c55e',
          '中新赛克(002912)调查腿C：舆情时间线取证——新闻密度/主题漂移/股吧情绪');
      final name = readableSessionName(row);
      expect(name.length, lessThanOrEqualTo(31),
          reason: '30 字 + 省略号，一行放得下');
      expect(name.endsWith('…'), isTrue);
    });

    test('label 空白时回落 id', () {
      final row = subRow('791e5254-0b1f', '   ');
      expect(readableSessionName(row), '791e5254-0b1f');
    });

    test('titleLike 的真标题仍然压过 subagent.label（优先级不乱）', () {
      // 投影 title 和 subagent.label 同时存在且都像真名：title 是 durable 的
      // （用户/LLM 起的），label 是运行时身份——前者赢。
      final row = SessionSummary(
        sessionId: '791e5254-0b1f',
        updatedAt: 1790000000000,
        running: false,
        blank: false,
        agentAvailable: true,
        projections: SessionProjectionHints.fromJson({
          'values': {
            'title': 'risk 腿的正式名字',
            'subagent': {'mode': 'continuable', 'seq': 0, 'label': '运行时身份'},
          },
        }),
      );
      expect(readableSessionName(row), 'risk 腿的正式名字');
    });
  });
}
