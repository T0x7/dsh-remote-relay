import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/chat/chat_controller.dart';
import 'package:dsh_remote_app/console/chat/chat_pane.dart';
import 'package:dsh_remote_app/console/chat/question_answer_state.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// T2.4 — the generic question card (屏 P).
///
/// The contract leaves two things to the App, and both are tested here
/// because neither is visible on the wire:
///
/// - **Skip has no flag.** A skipped question is *absent* from `answers`.
/// - **`custom` coexists with `selected`** in one answer item.
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

FollowSnapshot _snapshot() => FollowSnapshot(
      header: const SessionHeader(
          version: 4, id: 's1', createdAt: 0, isSeeded: false),
      cursor: 0,
      records: const [],
      hasMore: false,
      projections: const SessionProjectionBaseline(
          asOfSeq: 0, values: Projections()),
      assistantStream: AssistantStreamBaseline(revision: 0),
    );

AskUserQuestionItem _q(
  String id, {
  List<Map<String, dynamic>>? options,
  bool multiSelect = false,
  String? detail,
  String? header,
}) =>
    AskUserQuestionItem.fromJson({
      'id': id,
      'question': 'Q:$id',
      'detail': ?detail,
      'header': ?header,
      'options': ?options,
      if (multiSelect) 'multiSelect': true,
    });

void main() {
  group('answer state', () {
    test('single-select replaces, and tapping the picked option clears it', () {
      final state = QuestionAnswerState([
        _q('q1', options: [
          {'label': 'a'},
          {'label': 'b'},
        ]),
      ]);

      state.toggle('q1', 'a');
      expect(state.selectionOf('q1'), {'a'});

      state.toggle('q1', 'b');
      expect(state.selectionOf('q1'), {'b'}, reason: 'single-select replaces');

      state.toggle('q1', 'b');
      expect(state.selectionOf('q1'), isEmpty, reason: 'tapping again clears');
    });

    test('multi-select accumulates and deselects', () {
      final state = QuestionAnswerState([
        _q('q1', options: [
          {'label': 'a'},
          {'label': 'b'},
        ], multiSelect: true),
      ]);

      state.toggle('q1', 'a');
      state.toggle('q1', 'b');
      expect(state.selectionOf('q1'), {'a', 'b'});

      state.toggle('q1', 'a');
      expect(state.selectionOf('q1'), {'b'});
    });

    test('a skipped question is OMITTED from the wire, not sent empty', () {
      final state = QuestionAnswerState([
        _q('q1', options: [
          {'label': 'a'},
        ]),
        _q('q2', options: [
          {'label': 'x'},
        ]),
      ]);

      state.toggle('q1', 'a');
      // q2 is never touched — that IS the skip.
      expect(state.isAnswered('q2'), isFalse);
      expect(state.answerItems.map((a) => a.id), ['q1']);
      expect(state.toWire(), {
        'answers': [
          {'id': 'q1', 'selected': ['a']},
        ],
      });
    });

    test('custom coexists with selections in ONE answer item', () {
      final state = QuestionAnswerState([
        _q('q1', options: [
          {'label': 'staging'},
          {'label': 'prod'},
        ], multiSelect: true),
      ]);

      state.toggle('q1', 'staging');
      state.setCustom('q1', '  先灰度 5%  ');

      expect(state.answerItems, hasLength(1));
      expect(state.answerItems.single.toJson(), {
        'id': 'q1',
        'selected': ['staging'],
        'custom': '先灰度 5%',
      });
    });

    test('whitespace-only custom counts as unanswered', () {
      final state = QuestionAnswerState([_q('q1')]);
      state.setCustom('q1', '   ');

      expect(state.isAnswered('q1'), isFalse);
      expect(state.answerItems, isEmpty);
    });

    test('a free-text question with content is answered', () {
      final state = QuestionAnswerState([_q('q1')]);
      state.setCustom('q1', '没有了');

      expect(state.isAnswered('q1'), isTrue);
      expect(state.toWire(), {
        'answers': [
          {'id': 'q1', 'selected': <String>[], 'custom': '没有了'},
        ],
      });
    });

    test('completion needs every question answered', () {
      final state = QuestionAnswerState([
        _q('q1', options: [
          {'label': 'a'},
        ]),
        _q('q2'),
      ]);
      expect(state.isComplete, isFalse);

      state.toggle('q1', 'a');
      expect(state.isComplete, isFalse, reason: 'q2 still open');

      state.setCustom('q2', 'done');
      expect(state.isComplete, isTrue);
      expect(state.answeredCount, 2);
    });

    test('reset returns a question to unanswered', () {
      final state = QuestionAnswerState([_q('q1', options: [
        {'label': 'a'},
      ])]);
      state.toggle('q1', 'a');
      state.reset('q1');

      expect(state.isAnswered('q1'), isFalse);
    });
  });

  group('plan review decision', () {
    // A real plan review carries the intent; without it `PlanReview.of`
    // correctly returns null and the console shows the generic batch instead.
    final review = PlanReview.of([
      AskUserQuestionItem.fromJson({
        'id': 'plan-review',
        'question': 'Approve this plan?',
        'detail': '# plan',
        'options': [
          {'label': 'Approve'},
          {'label': 'Keep planning'},
        ],
        'intent': {'kind': 'plan-review', 'approve': 'Approve'},
      }),
    ])!;

    test('approve matches the named label', () {
      expect(const PlanReviewDecision.approve().toWire(review), {
        'answers': [
          {'id': 'plan-review', 'selected': ['Approve']},
        ],
      });
    });

    test('decline matches the OTHER label, by name', () {
      expect(const PlanReviewDecision.decline('Keep planning').toWire(review), {
        'answers': [
          {'id': 'plan-review', 'selected': ['Keep planning']},
        ],
      });
    });
  });

  group('screen', () {
    Future<({FakeEngineGateway gateway, ChatController controller})> open(
      WidgetTester tester, {
      required List<Map<String, dynamic>> questions,
    }) async {
      final gateway = FakeEngineGateway();
      final controller = ChatController(gateway: gateway, eventsRefreshInterval: Duration.zero)..startEvents();
      gateway.raiseReady();
      await controller.open('session-1');
      addTearDown(() async {
        controller.dispose();
        await gateway.dispose();
      });
      await tester.pumpWidget(_host(ChatPane(controller: controller)));
      gateway.pushFrame(_snapshot());
      gateway.raiseWaterfall('user-questions/request', {'questions': questions});
      await tester.pumpAndSettle();
      return (gateway: gateway, controller: controller);
    }

    testWidgets('renders every question in the batch', (tester) async {
      await open(tester, questions: [
        {'id': 'q1', 'question': 'Q:q1', 'options': [
          {'label': 'staging'},
          {'label': 'prod'},
        ]},
        {'id': 'q2', 'question': 'Q:q2'},
      ]);

      expect(find.text('Q:q1'), findsOneWidget);
      // q2 sits below the fold on the default 800x600 test viewport.
      await tester.scrollUntilVisible(
        find.text('Q:q2'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Q:q2'), findsOneWidget);
      expect(find.text('staging'), findsOneWidget);
    });

    testWidgets('submit stays disabled until every question is answered',
        (tester) async {
      await open(tester, questions: [
        {
          'id': 'q1',
          'question': 'Which env?',
          'options': [
            {'label': 'staging'},
            {'label': 'prod'},
          ],
        },
        {'id': 'q2', 'question': 'Anything else?'},
      ]);

      var submit = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交'));
      expect(submit.onPressed, isNull, reason: 'q2 is still open');

      await tester.tap(find.text('staging'));
      await tester.pumpAndSettle();
      expect(find.text('已答 1/2'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, '自由输入（可留空跳过）'),
        '没有了',
      );
      await tester.pumpAndSettle();

      submit = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交'));
      expect(submit.onPressed, isNotNull);
    });

    testWidgets('submitting posts the bare {answers:[...]} value',
        (tester) async {
      final env = await open(tester, questions: [
        {
          'id': 'q1',
          'question': 'Which env?',
          'options': [
            {'label': 'staging'},
            {'label': 'prod'},
          ],
        },
      ]);

      await tester.tap(find.text('staging'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '提交'));
      await tester.pumpAndSettle();

      expect(env.gateway.sentAnswers.single, {
        'answers': [
          {'id': 'q1', 'selected': ['staging']},
        ],
      });
      expect(find.text('staging'), findsNothing, reason: 'the card is settled');
    });

    testWidgets('a multi-select plus free text posts one item with both',
        (tester) async {
      final env = await open(tester, questions: [
        {
          'id': 'q1',
          'question': 'Which env?',
          'multiSelect': true,
          'options': [
            {'label': 'staging'},
            {'label': 'prod'},
          ],
        },
      ]);

      await tester.tap(find.text('staging'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('prod'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '补充说明（可选，与选项并存）'),
        '先灰度 5%',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '提交'));
      await tester.pumpAndSettle();

      final answers =
          (env.gateway.sentAnswers.single! as Map<String, dynamic>)['answers']! as List;
      expect(answers, hasLength(1), reason: 'one question, one answer item');
      expect((answers.single! as Map<String, dynamic>), {
        'id': 'q1',
        'selected': ['staging', 'prod'],
        'custom': '先灰度 5%',
      });
    });

    testWidgets('abandoning rejects the waterfall instead of answering',
        (tester) async {
      final env = await open(tester, questions: [
        {'id': 'q1', 'question': 'Which env?', 'options': [
          {'label': 'staging'},
        ]},
      ]);

      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();

      expect(env.gateway.sentAnswers, isEmpty);
      expect(env.gateway.sentRejections, hasLength(1));
      expect(
        (env.gateway.sentRejections.single! as Map<String, dynamic>)['code'],
        'ASK_CANCELLED',
      );
    });

    testWidgets('tapping an option fills its radio, and the radio itself is tappable (D-035)',
        (tester) async {
      await open(tester, questions: [
        {'id': 'q1', 'question': 'Which env?', 'options': [
          {'label': 'staging'},
          {'label': 'prod'},
        ]},
      ]);

      // The row's InkWell toggles state, and the progress text follows.
      await tester.tap(find.text('staging'));
      await tester.pumpAndSettle();
      expect(find.text('已答 1/1'), findsOneWidget);

      // D-035 (found on device): the radio showed NO selected state even
      // though the answer counted. The card rendered `Radio<bool>` under a
      // `RadioGroup<String>` — the generics never matched, so the radio never
      // received a groupValue and always drew hollow.
      final radios = tester.widgetList<Radio<Object?>>(
          find.byWidgetPredicate((w) => w is Radio)).toList();
      final radio = radios.first;
      expect(radio, isA<Radio<String>>(),
          reason: 'the radio must join the RadioGroup<String> above it');
      final group = tester.widget<RadioGroup<String>>(
          find.byType(RadioGroup<String>));
      expect(radio.value, group.groupValue,
          reason: 'the tapped option is the group value, so its radio is the filled one');

      // Tapping the radio control itself (not just the row) must also toggle.
      await tester.tap(find.byWidgetPredicate((w) => w is Radio).first);
      await tester.pumpAndSettle();
      expect(find.text('已答 1/1'), findsOneWidget,
          reason: 'the radio inherits onChanged from the group');
    });

    testWidgets('a plan review still renders the specialized card',
        (tester) async {
      await open(tester, questions: [
        {
          'id': 'plan-review',
          'question': 'Approve this plan?',
          'detail': '# 计划',
          'options': [
            {'label': 'Approve'},
            {'label': 'Keep planning'},
          ],
          'intent': {'kind': 'plan-review', 'approve': 'Approve'},
        },
      ]);

      expect(find.text('计划待批准'), findsOneWidget);
      expect(find.textContaining('Approve this plan?'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('已答 0/1'), findsNothing,
          reason: 'a plan review is a decision, not a batch to fill in');
    });
  });
}
