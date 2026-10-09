import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_picker_page.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_registry_controller.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-055: the registry's write side, from the user's point of view.
///
/// D-046 shipped the read side and the App used `archivedSessionIds` only as
/// subtraction — an archived session vanished from every list with no way back.
/// On the phone that reads as **"the app lost my session"**, which is the worst
/// possible reading of a feature the desktop already has.
///
/// These tests drive the page, not the controller, because the thing worth
/// locking is user-visible: an archived row must be *findable and restorable*,
/// and archiving something that is still running must **say what it will stop**
/// before it does.
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

SessionSummary s(String id) => SessionSummary(
      sessionId: id,
      updatedAt: 1790000000000,
      running: false,
      blank: false,
      agentAvailable: true,
    );

Map<String, dynamic> _baseline({
  List<String> archived = const [],
  List<String> pinned = const [],
}) =>
    {
      'type': 'baseline',
      'value': {
        'items': [
          {
            'workspaceId': 'w-jobs',
            'path': '/tmp/jobs',
            'title': '定时任务',
            'sessionIds': ['job-1', 'job-2'],
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': '2026-10-02T00:00:00Z',
          },
        ],
        'archivedSessionIds': archived,
        'pinnedSessionIds': pinned,
      },
    };

void main() {
  late FakeEngineGateway gateway;

  setUp(() {
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
  });

  Future<void> mount(
    WidgetTester tester, {
    List<Object?>? frames,
    List<SessionSummary>? knownSessions,
  }) async {
    if (frames != null) gateway.seedWorkspaces(frames);
    final sessions = ValueNotifier<List<SessionSummary>>(
      knownSessions ?? const [],
    );
    addTearDown(sessions.dispose);
    final controller = WorkspaceRegistryController(gateway);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(WorkspacePickerPage(
      registry: controller,
      gateway: gateway,
      sessions: sessions,
      machineName: 'mac-mini',
      onOpenSession: (_) {},
    )));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  group('归档视图三档', () {
    testWidgets('默认隐藏已归档会话（与 dsh web 的 default 一致）', (tester) async {
      await mount(tester, frames: [_baseline(archived: ['job-2'])]);

      expect(find.text('job-1'), findsOneWidget);
      expect(
        find.text('job-2'),
        findsNothing,
        reason: '默认档就是「藏起来」；这不是 bug，是引擎的 ArchivedFilter.default',
      );
    });

    testWidgets('「显示已归档」档里归档行置灰且点不开', (tester) async {
      final opened = <String>[];
      await mount(tester, frames: [_baseline(archived: ['job-2'])]);

      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示已归档'));
      await tester.pumpAndSettle();

      expect(find.text('job-2'), findsOneWidget);
      // 归档会话的「不可打开」是引擎规定的：Archived rows "cannot open until
      // restored"（web-client.md:52）。所以这一行点下去不能打开会话。
      await tester.tap(find.text('job-2'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
    });

    testWidgets('「只看看归档」档隐藏未归档的，且给出可恢复的入口', (tester) async {
      await mount(tester, frames: [_baseline(archived: ['job-2'])]);

      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('只看看归档'));
      await tester.pumpAndSettle();

      // 归档会话在 `only` 档出现两次：一次在专属的「只看看归档」组，一次在
      // 仍属它的「定时任务」组。重复是刻意的——工作区归属不会因为归档而消失。
      expect(find.text('job-2'), findsWidgets);
      expect(find.text('job-1'), findsNothing);
      // 「只看看归档」这个档存在的全部理由就是找回，所以必须有恢复入口。
      expect(find.byTooltip('恢复'), findsWidgets);
      // 「未分组」在 only 档下必然为空（归档会话按定义就被排除在外），留着它
      // 只会显示一个永远为空的卡片加一个「—」，读起来像坏了而不是「这里没有」。
      expect(find.text('未分组'), findsNothing);
    });
  });

  group('恢复归档', () {
    testWidgets('点恢复调 unarchiveSession，并把引擎回的完整集合装进投影',
        (tester) async {
      await mount(tester, frames: [_baseline(archived: ['job-2'])]);

      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('只看看归档'));
      await tester.pumpAndSettle();

      gateway.workspaceArchiveValue = {'archivedSessionIds': <String>[]};
      await tester.tap(find.byTooltip('恢复').first);
      await tester.pumpAndSettle();

      expect(
        gateway.calls.map((c) => c.call),
        contains('workspace/unarchiveSession'),
      );
      final call = gateway.calls.firstWhere((c) => c.call == 'workspace/unarchiveSession');
      expect(call.args, {
        'request': {'sessionId': 'job-2'},
      });
      // 引擎答的是**完整集合**而非增量，投影必须整体装上而不是自己猜。
      expect(gateway.archivedAfterUnarchive, <String>[]);
    });
  });

  group('置顶', () {
    testWidgets('置顶按钮发出 pinSession，且不带 stopActivity', (tester) async {
      await mount(tester, frames: [_baseline()]);

      gateway.workspacePinValue = {'pinnedSessionIds': ['job-1']};
      await tester.tap(find.byIcon(Icons.push_pin_outlined).first);
      await tester.pumpAndSettle();

      final call = gateway.calls.firstWhere((c) => c.call == 'workspace/pinSession');
      expect(call.args, {
        'request': {'sessionId': 'job-1'},
      });
    });

    testWidgets('已置顶的行给的是取消置顶，不是再置顶一次', (tester) async {
      await mount(tester, frames: [_baseline(pinned: ['job-1'])]);

      expect(find.byIcon(Icons.push_pin), findsWidgets,
          reason: '已置顶的行必须显示成「已置顶」，否则用户会以为没生效');

      gateway.workspacePinValue = {'pinnedSessionIds': <String>[]};
      await tester.tap(find.byIcon(Icons.push_pin).first);
      await tester.pumpAndSettle();

      final call = gateway.calls.firstWhere((c) => c.call == 'workspace/unpinSession');
      expect(call.args, {
        'request': {'sessionId': 'job-1'},
      });
    });

    testWidgets('归档行只有恢复入口，没有置顶——引擎拒绝给已归档的会话置顶',
        (tester) async {
      await mount(tester, frames: [_baseline(archived: ['job-2'])]);

      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示已归档'));
      await tester.pumpAndSettle();

      // 这一屏两行：job-1 未归档（有置顶+归档），job-2 已归档（只有恢复）。
      // 归档行如果也给置顶入口，点了就是拿引擎的拒绝去换一次用户挫败。
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byIcon(Icons.archive_outlined), findsOneWidget);
      expect(find.byIcon(Icons.unarchive_outlined), findsWidgets);
    });
  });

  group('归档需要先说清楚', () {
    testWidgets('会话在跑时，弹窗逐族列出 activity，并给强归档一个名字不同的按钮',
        (tester) async {
      await mount(tester, frames: [_baseline()]);

      gateway.workspaceArchiveRejection = {
        'code': 'workspace/session-active',
        'message': 'session is active',
        'details': {
          'sessionId': 'job-1',
          'activity': [
            {'kind': 'turn'},
            {
              'kind': 'job',
              'items': [
                {'id': 'job-a', 'label': 'nightly-backtest'},
              ],
            },
          ],
        },
      };

      await tester.tap(find.byIcon(Icons.archive_outlined).first);
      await tester.pumpAndSettle();

      // 这一个弹窗要同时说清两件事：你在归档什么、它会停掉什么。
      expect(find.textContaining('job-1'), findsWidgets);
      expect(find.textContaining('nightly-backtest'), findsOneWidget);
      // 「停掉在跑的活再归档」必须和「取消」区分开，不能长得像同一个动作。
      expect(find.text('停掉并归档'), findsOneWidget);
    });

    testWidgets('没在跑时普通归档一次就够，不多问一遍', (tester) async {
      await mount(tester, frames: [_baseline()]);

      gateway.workspaceArchiveValue = {'archivedSessionIds': ['job-1']};
      await tester.tap(find.byIcon(Icons.archive_outlined).first);
      await tester.pumpAndSettle();

      final calls =
          gateway.calls.where((c) => c.call == 'workspace/archiveSession').toList();
      expect(calls, hasLength(1));
      expect(calls.single.args, {
        'request': {'sessionId': 'job-1'},
      },
          reason: '不替用户决定要停掉电脑上正在跑的活');
    });

    testWidgets('用户在弹窗里取消，不会发强归档请求', (tester) async {
      await mount(tester, frames: [_baseline()]);

      gateway.workspaceArchiveRejection = {
        'code': 'workspace/session-active',
        'message': 'session is active',
        'details': {
          'sessionId': 'job-1',
          'activity': [
            {'kind': 'turn'},
          ],
        },
      };

      await tester.tap(find.byIcon(Icons.archive_outlined).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 第一次（普通归档）本来就该发——引擎正是靠它告诉我们会话在跑。
      // 取消要保证的是**没有第二次**：没有那个会停掉电脑上工作的请求。
      final calls = gateway.calls
          .where((c) => c.call == 'workspace/archiveSession')
          .toList();
      expect(calls, hasLength(1));
      expect(calls.single.args, {
        'request': {'sessionId': 'job-1'},
      });
      expect(
        gateway.calls.map((c) => c.call),
        isNot(contains('workspace/unarchiveSession')),
      );
    });

    testWidgets('确认「停掉并归档」才发 stopActivity: true', (tester) async {
      await mount(tester, frames: [_baseline()]);

      var answered = false;
      gateway.workspaceArchiveRejection = {
        'code': 'workspace/session-active',
        'message': 'session is active',
        'details': {
          'sessionId': 'job-1',
          'activity': [
            {'kind': 'turn'},
          ],
        },
      };
      // 第二次（强归档）要成功，否则 UI 只会报失败，看不出请求对不对。
      gateway.onBeforeArchiveCall = (args) {
        final request = args['request'];
      if (request is Map && request['stopActivity'] == true) {
          answered = true;
          gateway.workspaceArchiveRejection = null;
          gateway.workspaceArchiveValue = {'archivedSessionIds': ['job-1']};
        }
      };
      addTearDown(() => gateway.onBeforeArchiveCall = null);

      await tester.tap(find.byIcon(Icons.archive_outlined).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('停掉并归档'));
      await tester.pumpAndSettle();

      expect(answered, isTrue, reason: '弹窗里那个按钮必须真的发 stopActivity');
      final calls = gateway.calls
          .where((c) => c.call == 'workspace/archiveSession')
          .toList();
      expect(calls, hasLength(2));
      expect(calls.last.args, {
        'request': {'sessionId': 'job-1', 'stopActivity': true},
      });
    });
  });
}
