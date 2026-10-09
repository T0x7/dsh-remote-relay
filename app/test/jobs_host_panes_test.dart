import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/host/host_pane.dart';
import 'package:dsh_remote_app/console/inline_error_card.dart';
import 'package:dsh_remote_app/ui/error_copy.dart';
import 'package:dsh_remote_app/console/jobs/jobs_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// T2.8 — the tasks (屏 F 任务) and host (屏 F 主机) segments.
///
/// The lifecycle assertions follow the contract's **five** wire states rather
/// than the three the card shows: `running` → optional `stopping` → one of
/// `completed` / `killed` / `failed`.
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

JobView _job(Map<String, dynamic> j) => JobView.fromJson(j);

void main() {
  late L10n l10n;
  setUpAll(() async {
    l10n = await L10n.delegate.load(const Locale('zh'));
  });

  group('JobView card states', () {
    test('running and stopping are both "running" on the card', () {
      expect(_job(const {'id': 'bash-1', 'status': 'running'}).state,
          JobCardState.running);
      expect(_job(const {'id': 'bash-1', 'status': 'stopping'}).state,
          JobCardState.running);
    });

    test('completed and killed are both "done"', () {
      expect(_job(const {'id': 'bash-1', 'status': 'completed'}).state,
          JobCardState.done);
      expect(_job(const {'id': 'bash-1', 'status': 'killed'}).state,
          JobCardState.done);
    });

    test('failed is failed, with or without an error object', () {
      expect(_job(const {'id': 'b', 'status': 'failed'}).state, JobCardState.failed);
      final withError = _job(const {
        'id': 'b',
        'status': 'running',
        'error': {'name': 'SpawnError'},
      });
      expect(withError.state, JobCardState.failed,
          reason: 'an error object overrides a healthy-looking status word');
      expect(withError.detail, 'SpawnError');
    });

    test('an unknown status degrades to pending rather than guessing', () {
      expect(_job(const {'id': 'b', 'status': 'weird'}).state, JobCardState.pending);
    });

    test('only a live job offers kill', () {
      expect(_job(const {'id': 'b', 'status': 'running'}).isTerminal, isFalse);
      expect(_job(const {'id': 'b', 'status': 'completed'}).isTerminal, isTrue);
      expect(_job(const {'id': 'b', 'status': 'failed'}).isTerminal, isTrue);
    });

    test('the title prefers label, then kind, then id', () {
      expect(
        _job(const {'id': 'bash-1', 'kind': 'bash', 'label': 'build', 'status': 'running'}).title,
        'build',
      );
      expect(
        _job(const {'id': 'bash-1', 'kind': 'bash', 'status': 'running'}).title,
        'bash · bash-1',
      );
      expect(_job(const {'id': 'bash-1', 'status': 'running'}).title, 'bash-1');
    });
  });

  group('jobs pane', () {
    /// Mount the pane and settle. The `job/list` stream is a **broadcast**, so
    /// frames pushed before the widget subscribes in `initState` are dropped —
    /// every test therefore pushes after the mount, then settles.
    Future<void> mountJobs(
      WidgetTester tester,
      FakeEngineGateway gateway, {
      required void Function(FakeEngineGateway) afterMount,
    }) async {
      await tester.pumpWidget(_host(JobsPane(
        gateway: gateway,
        sessionId: 's1',
        l10n: l10n,
      )));
      afterMount(gateway);
      await tester.pumpAndSettle();
    }

    testWidgets('an empty list says so', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await mountJobs(tester, gateway, afterMount: (g) => g.raiseJobRows([]));

      expect(find.text('该会话没有任务'), findsOneWidget);
    });

    testWidgets('rows render with their state and detail', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await mountJobs(tester, gateway, afterMount: (g) => g.raiseJobRows([
            {'id': 'bash-1', 'kind': 'bash', 'label': 'build', 'status': 'running'},
            {'id': 'bash-2', 'label': 'test', 'status': 'completed'},
            {
              'id': 'bash-3',
              'label': 'lint',
              'status': 'running',
              'error': {'name': 'SpawnError'},
            },
          ]));

      expect(find.text('build'), findsOneWidget);
      expect(find.text('test'), findsOneWidget);
      expect(find.text('lint'), findsOneWidget);
      expect(find.text('运行中'), findsOneWidget);
      expect(find.text('已结束'), findsOneWidget);
      expect(find.text('失败'), findsOneWidget);
      expect(find.text('SpawnError'), findsOneWidget);
    });

    testWidgets('a later rows frame replaces the list wholesale',
        (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await mountJobs(tester, gateway, afterMount: (g) => g.raiseJobRows([
            {'id': 'bash-1', 'label': 'build', 'status': 'running'},
          ]));
      expect(find.text('build'), findsOneWidget);

      // The stream replaces rather than appends — a vanished job must vanish.
      gateway.raiseJobRows([
        {'id': 'bash-9', 'label': 'deploy', 'status': 'completed'},
      ]);
      await tester.pumpAndSettle();
      expect(find.text('build'), findsNothing);
      expect(find.text('deploy'), findsOneWidget);
    });

    testWidgets('kill is offered only on a live job', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await mountJobs(tester, gateway, afterMount: (g) => g.raiseJobRows([
            {'id': 'bash-1', 'label': 'build', 'status': 'running'},
            {'id': 'bash-2', 'label': 'test', 'status': 'completed'},
          ]));

      expect(find.text('终止'), findsOneWidget);
    });

    testWidgets('killing posts the job and reports the outcome',
        (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await mountJobs(tester, gateway, afterMount: (g) => g.raiseJobRows([
            {'id': 'bash-1', 'label': 'build', 'status': 'running'},
          ]));

      await tester.tap(find.text('终止'));
      await tester.pumpAndSettle();

      final call = gateway.calls.lastWhere((c) => c.call == 'killJob');
      expect(call.args, 'bash-1');
      expect(find.text('已请求终止'), findsOneWidget);
    });
  });

  group('host pane', () {
    testWidgets('reports session count and the current model', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(HostPane(
        gateway: gateway,
        machineName: 'mac-mini',
        sessions: [
          SessionSummary(
              sessionId: 'a', updatedAt: 1, running: false, blank: false, agentAvailable: true),
          SessionSummary(
              sessionId: 'b', updatedAt: 1, running: false, blank: false, agentAvailable: true),
        ],
        selection: const ModelSelection(provider: 'p', model: 'deepseek-v4'),
        l10n: l10n,
      )));
      await tester.pumpAndSettle();

      expect(find.text('mac-mini'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('deepseek-v4'), findsOneWidget);
    });

    testWidgets('lists installed bundles with one switch each', (tester) async {
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(HostPane(
        gateway: gateway,
        machineName: 'mac-mini',
        sessions: const [],
        selection: null,
        l10n: l10n,
      )));
      await tester.pumpAndSettle();

      // D-081.2: bundle 视角——16 个包，而不是 199 行 loader entry。
      // 核心 bundle（management-required）没有开关，内部模块收在展开里。
      expect(find.text('@deepseek-ai/dsh-base'), findsOneWidget);
      expect(find.text('dsh-remote-relay-plugin'), findsOneWidget);
      expect(find.text('核心模块'), findsWidgets);
      expect(find.text('不可寻址'), findsNothing,
          reason: 'bundle 层没有 unaddressable 概念');
      expect(find.byType(Switch), findsNWidgets(2),
          reason: '3 个 bundle 里 1 个是只读核心 → 2 个开关');
      expect(find.text('dsh-remote-relay'), findsNothing,
          reason: '内部模块默认收起');

      // 展开后才见内部模块。
      await tester.tap(find.text('dsh-remote-relay-plugin'));
      await tester.pumpAndSettle();
      expect(find.text('dsh-remote-relay'), findsOneWidget);

      // 点开关 → setBundleEnabled → **再重读一次清单**（D-086）。
      // 最后一条调用是重读，不是那次写入：App 不把「回复成功」当作
      // 「已经改了」的证据，状态一律以引擎自己的答案为准。
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(
        gateway.pluginManagerCalls.map((c) => c['call']).toList(),
        ['listBundles', 'setBundleEnabled', 'listBundles'],
        reason: 'D-086：切换后必须重读，让引擎决定真相，而不是相信回复',
      );
      expect(
        gateway.pluginManagerCalls[1],
        {'call': 'setBundleEnabled', 'name': 'dsh-remote-relay-plugin', 'enabled': false},
      );
    });

    testWidgets('states that host metrics are unavailable, and guesses none',
        (tester) async {
      // The design案 named `events.host`; it does not exist in 0.1.7-rc.2, so
      // the screen must say so rather than render invented CPU/memory.
      final gateway = FakeEngineGateway();
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(HostPane(
        gateway: gateway,
        machineName: 'mac-mini',
        sessions: const [],
        selection: null,
        l10n: l10n,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('未提供主机指标'), findsOneWidget);
      expect(find.textContaining('CPU'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('D-081: 错误卡把家目录路径缩成 ~', (tester) async {
      // 隐私表：保留 host 便于排障，但手机屏上不出现账号全名。
      expect(
        redactHomePath('/Users/someone/.dsh-host/dsh-home/profiles/web/package.json.lock'),
        '~/.dsh-host/dsh-home/profiles/web/package.json.lock',
      );
      expect(redactHomePath('no path here'), 'no path here');
    });

    testWidgets('a plugin-manager failure renders an inline card', (tester) async {
      final gateway = FakeEngineGateway()..failPluginManager = true;
      addTearDown(gateway.dispose);

      await tester.pumpWidget(_host(HostPane(
        gateway: gateway,
        machineName: 'mac-mini',
        sessions: const [],
        selection: null,
        l10n: l10n,
      )));
      // The fetch resolves as a microtask; a single pump after the first
      // frame is enough, the second covers the rebuild.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // D-081: 失败必须可见（D-078 教训），inline card 而不是静默空列表。
      expect(find.byType(InlineErrorCard), findsOneWidget);
    });
  });
}
