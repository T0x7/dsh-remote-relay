import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

Widget _host(Widget child, {Locale locale = const Locale('zh')}) => MaterialApp(
      locale: locale,
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

/// D-034 — the console renders `assistant-stream` frames token by token.
///
/// The wire sends a transient stream (`start` → `chunk`×N → `end`) that carries
/// no seq and takes no part in cursor algebra; the durable `assistant/message`
/// event only lands when the attempt finishes. Before D-034 the controller
/// dropped those frames, so the phone showed nothing until the whole reply was
/// already done. These tests pin the transient row's lifecycle:
///
/// * `start` opens exactly one live row,
/// * `text-delta` appends to it (other chunk kinds must not leak into text),
/// * `end` retires it — the durable event draws the final bubble,
/// * a replayed `start` (D-032's periodic `$events` re-open replays the active
///   attempt) must not duplicate the row.
ChatController _controller() =>
    ChatController(gateway: FakeEngineGateway(), eventsRefreshInterval: Duration.zero);

FollowAssistantStream _start({
  String attemptId = 'att-1',
  int revision = 1,
  int turn = 1,
  int step = 1,
}) =>
    FollowAssistantStream({
      'type': 'start',
      'attemptId': attemptId,
      'revision': revision,
      'index': 0,
      'turn': turn,
      'step': step,
    });

FollowAssistantStream _chunk(
  int revision,
  Map<String, Object?> chunk, {
  String attemptId = 'att-1',
  int index = 1,
}) =>
    FollowAssistantStream({
      'type': 'chunk',
      'attemptId': attemptId,
      'revision': revision,
      'index': index,
      'turn': 1,
      'step': 1,
      'chunk': chunk,
    });

FollowAssistantStream _textDelta(int revision, String text,
        {String attemptId = 'att-1', int index = 1}) =>
    _chunk(
      revision,
      {'type': 'text-delta', 'index': 0, 'text': text},
      attemptId: attemptId,
      index: index,
    );

FollowAssistantStream _end(
  int revision, {
  String attemptId = 'att-1',
  int index = 3,
  String outcomeKind = 'committed',
  int eventSeq = 7,
}) =>
    FollowAssistantStream({
      'type': 'end',
      'attemptId': attemptId,
      'revision': revision,
      'index': index,
      'turn': 1,
      'step': 1,
      'outcome': outcomeKind == 'committed'
          ? {'kind': 'committed', 'eventType': 'assistant/message', 'seq': eventSeq}
          : {'kind': outcomeKind},
    });

void main() {
  group('assistant-stream live rendering', () {
    test('text-delta frames accumulate into one live assistant row', () {
      final controller = _controller();
      addTearDown(controller.dispose);

      controller.applyFrame(_start());
      expect(controller.bubbles.whereType<ChatMessage>().where((m) => !m.fromUser),
          isEmpty,
          reason: 'an empty attempt has nothing to show yet');

      controller.applyFrame(_textDelta(2, 'Hel'));
      controller.applyFrame(_textDelta(3, 'lo '));
      controller.applyFrame(_textDelta(4, 'world'));

      final live = controller.bubbles.whereType<ChatMessage>().where((m) => !m.fromUser);
      expect(live, hasLength(1));
      expect(live.single.text, 'Hello world');
    });

    test('the live row is the last bubble, after settled history', () {
      final controller = _controller();
      addTearDown(controller.dispose);

      controller.applyFrame(_start());
      controller.applyFrame(_textDelta(2, 'tail'));
      expect(controller.bubbles.last, isA<ChatMessage>());
      expect((controller.bubbles.last as ChatMessage).text, 'tail');
    });

    test('non-text chunk kinds never leak into the visible text', () {
      final controller = _controller();
      addTearDown(controller.dispose);

      controller.applyFrame(_start());
      controller.applyFrame(_chunk(2, {
        'type': 'reasoning-delta',
        'index': 0,
        'text': 'thinking...',
      }));
      controller.applyFrame(_chunk(3, {
        'type': 'tool-call-delta',
        'index': 1,
        'id': 'call-1',
        'name': 'read_file',
        'argumentsDelta': '{"path"',
      }));
      controller.applyFrame(_chunk(4, {'type': 'usage', 'usage': {'outputTokens': 12}}));
      controller.applyFrame(_textDelta(5, 'visible'));

      final live = controller.bubbles.whereType<ChatMessage>().where((m) => !m.fromUser);
      expect(live.single.text, 'visible');
    });

    test('end retires the live row so the durable event is the only one left', () {
      final controller = _controller();
      addTearDown(controller.dispose);

      controller.applyFrame(_start());
      controller.applyFrame(_textDelta(2, 'done'));
      controller.applyFrame(_end(3));

      expect(
        controller.bubbles.whereType<ChatMessage>().where((m) => !m.fromUser),
        isEmpty,
        reason: 'the transient row must not survive its own end frame',
      );
    });

    test('an abandoned attempt also retires the live row', () {
      final controller = _controller();
      addTearDown(controller.dispose);

      controller.applyFrame(_start());
      controller.applyFrame(_textDelta(2, 'half'));
      controller.applyFrame(_end(3, outcomeKind: 'abandoned'));

      expect(
        controller.bubbles.whereType<ChatMessage>().where((m) => !m.fromUser),
        isEmpty,
      );
    });

    test('a replayed start for the same attempt is idempotent (D-032 re-open)', () {
      final controller = _controller();
      addTearDown(controller.dispose);

      controller.applyFrame(_start());
      controller.applyFrame(_textDelta(2, 'kept'));
      // The 60s $events refresh replays the still-active attempt from scratch.
      controller.applyFrame(_start(revision: 1));
      controller.applyFrame(_textDelta(2, 'kept'));

      final live = controller.bubbles.whereType<ChatMessage>().where((m) => !m.fromUser);
      expect(live, hasLength(1), reason: 'replay must not open a second row');
      expect(live.single.text, 'kept');
    });

    test('a new attempt after a retired one opens a fresh row', () {
      final controller = _controller();
      addTearDown(controller.dispose);

      controller.applyFrame(_start());
      controller.applyFrame(_textDelta(2, 'first'));
      controller.applyFrame(_end(3));

      controller.applyFrame(_start(attemptId: 'att-2', revision: 4, step: 2));
      controller.applyFrame(_textDelta(5, 'second', attemptId: 'att-2', index: 1));

      final live = controller.bubbles.whereType<ChatMessage>().where((m) => !m.fromUser);
      expect(live, hasLength(1));
      expect(live.single.text, 'second');
    });

    test('the durable assistant message renders after the live row is gone', () {
      final controller = _controller();
      addTearDown(controller.dispose);

      controller.applyFrame(_start());
      controller.applyFrame(_textDelta(2, 'Hello '));
      controller.applyFrame(_textDelta(3, 'world'));
      controller.applyFrame(_end(4, eventSeq: 7));
      controller.applyFrame(FollowEvent(SessionWireEvent(
        type: 'assistant/message',
        seq: 7,
        time: 0,
        data: {
          'turn': 1,
          'step': 1,
          'message': {
            'id': 'a7',
            'content': [
              {'type': 'text', 'text': 'Hello world'},
            ],
            'source': {'kind': 'model', 'provider': 'p', 'model': 'm'},
            'role': 'assistant',
          },
        },
      )));

      final live = controller.bubbles.whereType<ChatMessage>().where((m) => !m.fromUser);
      expect(live, hasLength(1), reason: 'exactly one row, not a duplicate pair');
      expect(live.single.text, 'Hello world');
    });
  });

  group('assistant-stream in the mounted console', () {
    testWidgets('tokens appear in the conversation before the turn ends',
        (tester) async {
      final gateway = FakeEngineGateway();
      final controller =
          ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero);
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });
      await tester.pumpWidget(_host(ChatPane(controller: controller)));
      await controller.open('s1');
      gateway.pushFrame(FollowSnapshot(
        header: SessionHeader(version: 4, id: 's1', createdAt: 0, isSeeded: false),
        cursor: 0,
        records: const [],
        hasMore: false,
        projections:
            const SessionProjectionBaseline(asOfSeq: 0, values: Projections()),
        // The engine omits the baseline unless the follow asked for
        // `assistantStream: true`; without it the first stream frame is a
        // protocol fault, not a live row.
        assistantStream: const AssistantStreamBaseline(revision: 0),
      ));
      await tester.pumpAndSettle();

      gateway.pushFrame(_start());
      gateway.pushFrame(_textDelta(2, '正在'));
      await tester.pump(const Duration(milliseconds: 80));
      gateway.pushFrame(_textDelta(3, '思考'));
      await tester.pump(const Duration(milliseconds: 80));

      // The point of D-034: the text is on screen while the turn still runs.
      expect(find.text('正在思考'), findsOneWidget);
      expect(find.text('正在'), findsNothing, reason: 'each delta replaces the row');

      gateway.pushFrame(_end(4));
      await tester.pumpAndSettle();
      expect(find.text('正在思考'), findsNothing,
          reason: 'the transient row retires with its end frame');
    });
  });
}
