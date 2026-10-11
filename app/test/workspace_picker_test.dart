import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_picker_page.dart';
import 'package:dsh_remote_app/console/workspaces/workspace_registry_controller.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-047: the workspace picker reads **only** the registry.
///
/// The previous version (D-046) drew the registry by filtering a
/// `session/list` the console had already loaded. That put a call currently
/// taking 130+ seconds on the critical path of opening the session list, for
/// data the registry already carries. These tests exist to make that impossible
/// to reintroduce: the last two are the ones that would fail if anyone wired
/// `session/list` back into this page.
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

void main() {
  late FakeEngineGateway gateway;
  final opened = <String>[];

  setUp(() {
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    opened.clear();
  });

  /// Built **inside** the test body on purpose (the repo's standing trap, see
  /// `console_screens_test.dart`): a controller created in `setUp` lives in the
  /// real-async zone while the body runs on the fake clock, so the registry's
  /// baseline is broadcast into a controller nobody is listening to yet and is
  /// dropped.
  Future<void> mount(
    WidgetTester tester, {
    List<SessionSummary>? knownSessions,
    List<Object?>? frames,
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
      onOpenSession: opened.add,
    )));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  testWidgets('renders the registry from the baseline alone, with no session '
      'list in hand', (tester) async {
    await mount(tester); // knownSessions: empty

    expect(find.text('定时任务'), findsOneWidget);
    expect(find.text('workspace'), findsOneWidget);
    expect(find.text('/tmp/jobs'), findsOneWidget);
    expect(find.text('job-1'), findsOneWidget);
    expect(find.text('chat-1'), findsOneWidget);
    expect(gateway.calls.where((c) => c.call == 'listSessions'), isEmpty,
        reason: 'the registry carries every workspace\'s sessionIds; the list '
            'is the 130-second call this page exists to avoid');
  });

  testWidgets('the ungrouped row says "unknown" rather than "0" until the '
      'list lands — 0 would be a fact, and it is not one yet', (tester) async {
    await mount(tester);
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);

    // Once the background list arrives the count becomes real.
    await mount(tester, knownSessions: [s('job-1'), s('loose-1')]);
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.text('loose-1'), findsOneWidget);
  });

  testWidgets('tapping a previewed session opens exactly that session',
      (tester) async {
    await mount(tester);
    await tester.tap(find.text('job-1'));
    expect(opened, ['job-1']);
  });

  testWidgets('drilling into a workspace lists that workspace\'s own ids and '
      'still never queries the engine', (tester) async {
    await mount(tester);

    await tester.tap(find.text('定时任务'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(find.text('job-2'), findsWidgets,
        reason: 'job-2 is only visible inside its own workspace — and it also '
            'appears in the picker preview, hence more than once');
    expect(gateway.calls.where((c) => c.call == 'listSessions'), isEmpty);

    // Tap the row on the page we just navigated to, not the picker's preview.
    await tester.tap(find.text('job-2').last);
    expect(opened, ['job-2']);
  });

  testWidgets('a session claimed by a workspace is not in 未分组', (tester) async {
    await mount(tester, knownSessions: [s('job-1'), s('loose-1')]);
    // job-1 belongs to 定时任务; only loose-1 is unclaimed.
    expect(find.text('loose-1'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
  });

  group('T2.2 的两个 DoD 补回', () {
    /// One parent with a child, the shape `parentSessionId` describes.
    List<Object?> framesWith(String workspace, List<String> sessionIds) => [
          {
            'type': 'baseline',
            'value': {
              'items': [
                {
                  'workspaceId': 'w',
                  'path': '/tmp/w',
                  'title': workspace,
                  'sessionIds': sessionIds,
                  'createdAt': '2026-10-01T00:00:00Z',
                  'updatedAt': '2026-10-02T00:00:00Z',
                },
              ],
              'archivedSessionIds': <String>[],
              'pinnedSessionIds': <String>[],
            },
          },
        ];

    testWidgets('a subagent hangs under its parent once the background list '
        'has said who the parent is', (tester) async {
      await mount(
        tester,
        frames: framesWith('回测研究', ['parent-1', 'child-1']),
        knownSessions: [
          s('parent-1'),
          SessionSummary(
            sessionId: 'child-1',
            parentSessionId: 'parent-1',
            updatedAt: 1,
            running: false,
            blank: false,
            agentAvailable: true,
          ),
        ],
      );

      // The parent row's left edge; the child must be indented past it.
      final parentLeft = tester.getTopLeft(find.text('parent-1')).dx;
      final childLeft = tester.getTopLeft(find.text('child-1')).dx;
      expect(childLeft, greaterThan(parentLeft),
          reason: 'T2.2 DoD「子代理缩进挂父」');
    });

    testWidgets('a child whose parent is filtered out is promoted, not dropped',
        (tester) async {
      await mount(
        tester,
        frames: framesWith('回测研究', ['parent-1', 'orphan-1']),
        knownSessions: [
          s('parent-1'),
          SessionSummary(
            sessionId: 'orphan-1',
            parentSessionId: 'not-in-this-workspace',
            updatedAt: 1,
            running: false,
            blank: false,
            agentAvailable: true,
          ),
        ],
      );
      expect(find.text('orphan-1'), findsOneWidget,
          reason: 'losing a live session to a layout rule is worse than flat');
    });

    testWidgets('search filters sessions by id and keeps workspaces visible',
        (tester) async {
      await mount(
        tester,
        frames: framesWith('Reports', ['job-scheduled-judge-1', 'job-gamma-x']),
      );

      await tester.enterText(find.byType(TextField), 'gamma');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(find.text('Reports'), findsOneWidget,
          reason: 'a search that empties the screen tells the user nothing');
      expect(find.text('job-gamma-x'), findsOneWidget);
      expect(find.text('job-scheduled-judge-1'), findsNothing);
    });

    testWidgets('searching a workspace name keeps the group but drops its rows',
        (tester) async {
      await mount(tester, frames: framesWith('Reports', ['job-a', 'job-b']));

      await tester.enterText(find.byType(TextField), 'Report');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(find.text('Reports'), findsOneWidget);
      expect(find.text('job-a'), findsNothing,
          reason: 'the user asked for the workspace, not for its first sessions');
    });
  });

  testWidgets('an increment before any baseline is a protocol fault, and the '
      'page says so rather than spinning forever', (tester) async {
    // A frame that is not a baseline means the producer and the consumer
    // disagree about state. Rendering an empty machine would be a lie, and
    // spinning forever would be a hang — the honest answer is "unavailable".
    await mount(tester, frames: [
      {'type': 'nonsense-the-client-does-not-model'},
    ]);
    expect(find.textContaining('拿不到'), findsOneWidget);
  });
}
