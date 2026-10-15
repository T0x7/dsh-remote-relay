import 'dart:convert';

import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:dsh_remote_app/services/update_checker.dart';
import 'package:dsh_remote_app/settings/about_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-114：更新检查。
///
/// 重点钉两件容易错、错了又很难看出来的事：
/// 1. **版本新旧只能按版本号判**，不能用 GitHub 返回顺序或 `published_at`——
///    GitHub 的 `latest` 是按发布时间挑的，发版顺序一乱就会把旧版当新版推给用户。
/// 2. **检查失败不许抛**：这是设置页里的一个按钮，网络抖一下不该崩页面。
void main() {
  tearDown(() {
    releaseFetcher = (uri) async => throw StateError('no fetch in this test');
  });

  group('版本比较（自写，不引依赖）', () {
    test('逐段比较，而不是按字符串比', () {
      expect(isNewer('1.0.10', '1.0.9'), isTrue, reason: '10 > 9，字符串比会判反');
      expect(isNewer('1.10.0', '1.9.0'), isTrue);
      expect(isNewer('2.0.0', '1.99.99'), isTrue);
      expect(isNewer('1.0.0', '1.0.0'), isFalse);
      expect(isNewer('1.0.0', '1.0.1'), isFalse);
      expect(isNewer('0.9.9', '1.0.0'), isFalse, reason: '不能把旧版当新版推');
    });

    test('缺段按 0 补齐；非法段不抛', () {
      expect(isNewer('1.0', '1.0.0'), isFalse);
      expect(isNewer('1.1', '1.0.9'), isTrue);
      expect(isNewer('1.x.0', '1.0.0'), isFalse, reason: 'x 段按 0，不该崩');
    });

    test('预发布后缀与 build 号不参与比较', () {
      expect(isNewer('1.0.0+2', '1.0.0+1'), isFalse, reason: '同版本不同 build 不是新版本');
      expect(isNewer('1.0.1-rc1', '1.0.0'), isTrue);
    });
  });

  group('release JSON 解析', () {
    Map<String, dynamic> release(String tag,
            {List<Map<String, dynamic>>? assets}) => {
          'tag_name': tag,
          'body': 'notes here',
          if (assets != null) 'assets': assets, // ignore: use_null_aware_elements
        };

    /// 从当前版本**推导**出一个必定更新的 tag。
    ///
    /// 同一个坑本文件已经踩过两次：下面「tag 比当前旧」那条写着「写死版本号会在
    /// kAppVersion 降到 0.0.1 时红」，而**紧挨着**的 prerelease 那条却把
    /// `v0.0.2` 写死当"比当前新"——发到 0.0.2 的当天它就成了「和当前相同」，
    /// `isNewer` 返回 false，用例红。**教训：这类夹具必须从 kAppVersion 推导，
    /// 且要一次改全**——修了同族的一条、留下另一条，等于把同一个 bug 推迟一轮。
    String newerTag() {
      final parts = kAppVersion.split('.');
      return '${parts[0]}.${parts[1]}.${int.parse(parts[2]) + 1}';
    }

    test('v 前缀能剥；新版本 → available + 挑 arm64 apk', () {
      final c = UpdateCheck.fromReleaseJson(release('v1.1.0', assets: [
        {'name': 'app-x86_64.apk', 'browser_download_url': 'u1', 'size': 1},
        {'name': 'app-arm64-v8a.apk', 'browser_download_url': 'u2', 'size': 42},
      ]));
      expect(c.available, isTrue);
      expect(c.latest, '1.1.0');
      expect(c.url, 'u2', reason: '小米 Civi 是 arm64，挑错架构会装不上');
      expect(c.bytes, 42);
      expect(c.notes, 'notes here');
    });

    test('没有 arm64 时回落任意 apk；只有 universal 也能用', () {
      final c = UpdateCheck.fromReleaseJson(release('v1.1.0', assets: [
        {'name': 'app-x86_64.apk', 'browser_download_url': 'u1', 'size': 1},
      ]));
      expect(c.url, 'u1');
    });

    test('tag 比当前旧 → 不提示（哪怕它是 GitHub 的 latest）', () {
      // **不能写死一个版本号**：当前版本随发版变动，写死的"旧版本"某天会变成
      // 比当前新（kAppVersion 降到 0.0.1 时，这条用例就是这么红的）。
      // 正确做法是从当前版本**推导**出一个必定更旧的 tag。
      final parts = kAppVersion.split('.');
      final older = '${parts[0]}.${int.tryParse(parts[1])! - 1 < 0 ? 0 : int.tryParse(parts[1])! - 1}.0';
      final c = UpdateCheck.fromReleaseJson(release('v$older'));
      expect(c.available, isFalse,
          reason: '发版顺序错了也不能把旧版当新版推');
      expect(c.latest, older);
    });

    // v0.0.1 真机踩的：GitHub 的 /releases/latest **排除 prerelease**，
    // 一旦把发布标成 beta 那个端点就 404 ⇒「检查更新永远失败」。
    // 所以端点必须是 /releases 列表 + 自己按版本号挑。
    test('列表里挑版本号最高的，且 draft 被跳过', () {
      final c = UpdateCheck.fromReleaseList([
        {'tag_name': 'v0.0.9', 'prerelease': true, 'draft': false},
        {'tag_name': 'v0.2.0', 'draft': false},
        {'tag_name': 'v0.3.0-draft', 'draft': true},
        {'tag_name': 'v0.1.0', 'prerelease': true},
      ]);
      expect(c.latest, '0.2.0',
          reason: '按版本号挑，不是按数组顺序；draft 必须跳过');
      expect(c.available, isTrue, reason: '0.2.0 比当前 $kAppVersion 新');
    });

    test('prerelease 也要能被看到——本项目自己就是 beta（走 fetch()）', () async {
      // ⚠️ 必须走 fetch()：直接调 fromReleaseList 时**改端点根本不会红**——
      // 这条守门一度是假绿的（今天第二次同族：守门守在了错误的层）。
      // 真正的不变量在 fetch() 选的那个 URL 上。
      final newer = newerTag();
      Uri? hit;
      releaseFetcher = (uri) async {
        hit = uri;
        return jsonEncode([
          {'tag_name': 'v$newer', 'prerelease': true, 'draft': false},
        ]);
      };
      final c = await UpdateChecker.instance().fetch();
      expect(hit!.path, '/repos/T0x7/dsh-remote-relay/releases',
          reason: '不能用 /releases/latest —— 它排除 prerelease，'
              '本项目首个公开版就标成 beta，那条路真机实测 404');
      expect(hit!.path, isNot(contains('/latest')));
      expect(c.latest, newer);
      expect(c.available, isTrue);
    });

    test('空列表 / 全是 draft → 失败而不是崩', () {
      expect(UpdateCheck.fromReleaseList(const []).available, isFalse);
      expect(UpdateCheck.fromReleaseList([
        {'tag_name': 'v9.9.9', 'draft': true},
      ]).available, isFalse);
    });

    test('缺 tag_name → 失败而不是崩', () {
      final c = UpdateCheck.fromReleaseJson({'body': 'no tag'});
      expect(c.available, isFalse);
      expect(c.error, UpdateError.noTag);
    });
  });

  group('网络层', () {
    test('HTTP 失败 → 归一成 failed，不抛', () async {
      releaseFetcher = (uri) async => throw const FormatException('boom');
      final c = await UpdateChecker.instance().fetch();
      expect(c.available, isFalse);
      expect(c.error, isNotNull);
    });

    test('非 JSON → failed', () async {
      releaseFetcher = (uri) async => 'not json at all';
      final c = await UpdateChecker.instance().fetch();
      expect(c.available, isFalse);
    });

    test('每次检查都落一行 audit —— 今天一整轮的核心教训', () async {
      final sink = MemoryLogSink();
      final previous = AppLog.sink;
      AppLog.sink = sink;
      addTearDown(() => AppLog.sink = previous);

      // fetch() 现在要 /releases 的**列表**（见 fromReleaseList）
      releaseFetcher = (uri) async => jsonEncode([
        {'tag_name': 'v9.9.9', 'draft': false},
      ]);
      final c = await UpdateChecker.instance().fetch();
      c.logAudit();

      expect(c.available, isTrue);
      expect(sink.lines.any((l) => l.contains('action=update.check')
          && l.contains('latest=9.9.9')), isTrue);
    });
  });
}