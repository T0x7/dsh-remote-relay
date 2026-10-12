import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

SessionWireEvent _msg(int seq, String text) => SessionWireEvent(
      type: 'assistant/message',
      seq: seq,
      time: DateTime.now().millisecondsSinceEpoch,
      data: {
        'turn': 1, 'step': 1,
        'message': {
          'id': 'a$seq',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
          'role': 'assistant',
        },
        'stream': <Object?>[],
      },
    );

FollowSnapshot _snap(List<FollowEvent> records) => FollowSnapshot(
      header: SessionHeader(version: 4, id: 'session-1', createdAt: 0, isSeeded: false),
      cursor: 0, records: records, hasMore: false,
      projections: const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
    );

Future<void> _show(WidgetTester tester, String text) async {
  final gateway = FakeEngineGateway();
  final controller =
      ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero)
        ..startEvents();
  gateway.raiseReady();
  await controller.open('session-1');
  addTearDown(() async {
    controller.dispose();
    await gateway.dispose();
  });
  await tester.pumpWidget(_host(ChatPane(controller: controller)));
  gateway.pushFrame(_snap([FollowEvent(_msg(1, text))]));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('PROBE 完整表格', (tester) async {
    await _show(tester, '结论如下\n\n| 位置 | 含义 |\n|----|----|\n| 20.00 | 整数关口 |\n| 21.00 | 前高 |\n');
    debugPrint('PROBE 完整表格 Table=${find.byType(Table).evaluate().length} '
        'TableRow=${find.byType(TableRow).evaluate().length} '
        '裸竖线=${find.textContaining('|----', findRichText: true).evaluate().length}');
  });

  testWidgets('PROBE 流式截断的表格', (tester) async {
    await _show(tester, '结论如下\n\n| 位置 | 含义 |\n|----|----|\n| 20.00 | 9 月中下旬多次触及的整数关口，第一支');
    debugPrint('PROBE 截断表格 Table=${find.byType(Table).evaluate().length} '
        '裸竖线=${find.textContaining('|----', findRichText: true).evaluate().length}');
  });

  testWidgets('PROBE 表格前缺空行', (tester) async {
    await _show(tester, '结论如下\n| 位置 | 含义 |\n|----|----|\n| 20.00 | 整数关口 |\n');
    debugPrint('PROBE 缺空行 Table=${find.byType(Table).evaluate().length}');
  });
}
