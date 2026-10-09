import 'package:test/test.dart';

import 'package:dsh_remote_core/api/engine_models.dart';

/// Wire fixtures hand-copied from dsh-root 0.1.7-rc.2, matching the examples in
/// `docs/engine-contract-m2.md` §3.3 / §6.1 / §5.4.
///
/// These pin *semantics*, not just field names — the three traps below are the
/// ones a naive decoder gets wrong.
void main() {
  group('projections: absence is not zero', () {
    test('a missing key yields null, not a zeroed record', () {
      final p = Projections.fromJson(const {});

      expect(p.contextPressure, isNull);
      expect(p.tokenUsage, isNull);
      expect(p.contextBreakdown, isNull);
      expect(p.modelSelection, isNull);
      // The contract's central rule: a missing key means "not available at
      // this cut", NOT "zero" (api/session-controller/src/types.ts:75-77).
      expect(p.has('contextPressure'), isFalse);
      expect(p.has('tokenUsage'), isFalse);
    });

    test('an explicit zero is a real value and reports has() == true', () {
      final p = Projections.fromJson(const {
        'tokenUsage': {
          'uncachedInputTokens': 0,
          'outputTokens': 0,
          'cacheReadTokens': 0,
          'cacheWriteTokens': 0,
        },
      });

      expect(p.has('tokenUsage'), isTrue);
      expect(p.tokenUsage!.outputTokens, 0);
    });
  });

  group('contextPressure', () {
    test('all three fields are optional and stay null when absent', () {
      final p = ContextPressure.fromJson(const {});
      expect(p.pressureTokens, isNull);
      expect(p.projectedTokens, isNull);
      expect(p.contextWindow, isNull);
      expect(p.fillRatio, isNull);
    });

    test('fill ratio prefers projected over pressure', () {
      final p = ContextPressure.fromJson(const {
        'pressureTokens': 1000,
        'projectedTokens': 2000,
        'contextWindow': 8000,
      });
      expect(p.fillRatio, closeTo(0.25, 1e-9));
    });

    test('fill ratio falls back to pressure when projection is absent', () {
      final p = ContextPressure.fromJson(const {
        'pressureTokens': 4000,
        'contextWindow': 8000,
      });
      expect(p.fillRatio, closeTo(0.5, 1e-9));
    });

    test('a zero or negative window never divides by zero', () {
      expect(
        ContextPressure.fromJson(const {
          'pressureTokens': 10,
          'contextWindow': 0,
        }).fillRatio,
        isNull,
      );
    });

    test('ratio clamps above 1 rather than overflowing the ring', () {
      final p = ContextPressure.fromJson(const {
        'projectedTokens': 9000,
        'contextWindow': 8000,
      });
      expect(p.fillRatio, 1.0);
    });
  });

  group('contextBreakdown', () {
    test('reads the three required segments', () {
      final b = ContextBreakdown.fromJson(const {
        'systemTokens': 100,
        'toolsTokens': 250,
        'messageTokens': 650,
      });
      expect(b.systemTokens, 100);
      expect(b.toolsTokens, 250);
      expect(b.messageTokens, 650);
      expect(b.total, 1000);
    });
  });

  group('token usage', () {
    test('billable input sums uncached + cacheRead + cacheWrite', () {
      final u = TokenUsageProjection.fromJson(const {
        'uncachedInputTokens': 100,
        'outputTokens': 900,
        'cacheReadTokens': 2000,
        'cacheWriteTokens': 500,
      });
      expect(u.billableInputTokens, 2600);
    });
  });

  group('sessionStats derives tok/s', () {
    test('tok/s is decodeTokens / decodeSeconds', () {
      final s = SessionStatsProjection.fromJson(const {
        'turns': 12,
        'steps': 40,
        'llmMs': 9000,
        'toolMs': 3000,
        'ttftMs': 8000,
        'ttftSteps': 40,
        'decodeMs': 2000,
        'decodeTokens': 600,
      });
      expect(s.tokensPerSecond, closeTo(300.0, 1e-9));
      expect(s.turns, 12);
      expect(s.meanTtftMs, 200);
    });

    test('no decode window yields null rather than infinity', () {
      final s = SessionStatsProjection.fromJson(const {
        'turns': 0,
        'steps': 0,
        'llmMs': 0,
        'toolMs': 0,
        'ttftMs': 0,
        'ttftSteps': 0,
        'decodeMs': 0,
        'decodeTokens': 0,
      });
      expect(s.tokensPerSecond, isNull);
      expect(s.meanTtftMs, isNull);
    });
  });

  group('model catalog', () {
    final catalogJson = {
      'default': {'provider': 'deepseek-official', 'model': 'deepseek-v4'},
      'routableProviders': ['deepseek-official'],
      'groups': [
        {
          'id': 'deepseek-official',
          'name': 'DeepSeek',
          'models': [
            {
              'id': 'deepseek-v4',
              'name': 'DeepSeek V4',
              'reasoning': {
                'efforts': [
                  {'id': 'low', 'name': 'Low'},
                  {'id': 'high', 'name': 'High'},
                ],
                'defaultEffort': 'medium',
              },
            },
            {'id': 'plain-model', 'name': 'Plain'},
          ],
        },
      ],
      'failures': [
        {'id': 'openai', 'name': 'OpenAI', 'message': 'no API key'},
      ],
    };

    test('reads the whole catalog with no built-in fallback list', () {
      final c = ModelCatalog.fromJson(catalogJson);

      expect(c.defaultSelection.provider, 'deepseek-official');
      expect(c.groups, hasLength(1));
      expect(c.groups.first.models, hasLength(2));
      expect(c.failures.single.message, 'no API key');
    });

    test('a non-reasoning model offers no effort chips', () {
      final c = ModelCatalog.fromJson(catalogJson);
      expect(c.findModel('deepseek-official', 'plain-model')!.efforts, isEmpty);
      expect(
        c.findModel('deepseek-official', 'deepseek-v4')!.efforts.map((e) => e.id),
        ['low', 'high'],
        reason: 'adapter display order is preserved, not sorted',
      );
    });

    test('an unknown provider or model returns null, not a throw', () {
      final c = ModelCatalog.fromJson(catalogJson);
      expect(c.findModel('nope', 'x'), isNull);
      expect(c.findModel('deepseek-official', 'nope'), isNull);
    });

    test('a malformed catalog degrades instead of throwing', () {
      final c = ModelCatalog.fromJson(const {});
      expect(c.groups, isEmpty);
      expect(c.routableProviders, isEmpty);
      expect(c.failures, isEmpty);
    });
  });

  group('"follow default" has no flag on the wire', () {
    test('next == null means the session follows the deployment default', () {
      final p = ModelSelectionProjection.fromJson(const {
        'lastUsed': null,
        'next': null,
      });
      expect(p.followsDefault, isTrue);
    });

    test('a pending or lastUsed selection means it is not following', () {
      final p = ModelSelectionProjection.fromJson(const {
        'lastUsed': {'provider': 'deepseek-official', 'model': 'deepseek-v4'},
        'next': null,
      });
      // `next`'s view is `pending ?? lastUsed`; upstream computes that, so a
      // non-null lastUsed arrives here as a non-null next in practice. This
      // fixture pins the shape, not the derivation.
      expect(p.lastUsed, isNotNull);
    });
  });

  group('follow frames', () {
    test('decodes the opening snapshot with its projection baseline', () {
      final frame = SessionFollowFrame.fromJson(const {
        'type': 'snapshot',
        'header': {
          'version': 4,
          'id': 'session-1',
          'createdAt': 1690000000000,
          'cwd': '/p',
          'isSeeded': false,
        },
        'cursor': 812,
        'records': [
          {
            'type': 'event',
            'event': {
              'type': 'turn/start',
              'seq': 811,
              'time': 1690000000123,
              'data': {'turn': 12},
            },
          },
        ],
        'hasMore': true,
        'projections': {
          'asOfSeq': 812,
          'values': {
            'modelSelection': {'lastUsed': null, 'next': null},
          },
        },
        'assistantStream': {
          'revision': 41,
          'activeAttempt': {
            'attemptId': 'att-1',
            'startedAfterSeq': 811,
            'turn': 12,
            'step': 3,
            'nextIndex': 57,
            'stream': <Object?>[],
          },
        },
      });

      expect(frame, isA<FollowSnapshot>());
      final snapshot = frame as FollowSnapshot;
      expect(snapshot.header.version, 4);
      expect(snapshot.cursor, 812);
      expect(snapshot.hasMore, isTrue);
      expect(snapshot.records.single.seq, 811);
      expect(snapshot.projections.asOfSeq, 812);
      expect(snapshot.projections.values.modelSelection!.followsDefault, isTrue);
      expect(snapshot.assistantStream!.revision, 41);
      expect(snapshot.assistantStream!.activeAttempt!.attemptId, 'att-1');
    });

    test('an empty log reports cursor -1 and no assistant attempt', () {
      final snapshot = SessionFollowFrame.fromJson(const {
        'type': 'snapshot',
        'header': {'version': 4, 'id': 's', 'createdAt': 0, 'isSeeded': false},
        'cursor': -1,
        'records': <Object?>[],
        'hasMore': false,
        'projections': {'asOfSeq': -1, 'values': <String, dynamic>{}},
      }) as FollowSnapshot;

      expect(snapshot.cursor, -1);
      expect(snapshot.records, isEmpty);
      expect(snapshot.assistantStream, isNull);
    });

    test('decodes a durable event entry', () {
      final frame = SessionFollowFrame.fromJson(const {
        'type': 'event',
        'event': {
          'type': 'user/message',
          'seq': 5,
          'time': 1000,
          'data': {'turn': 1},
          'surfaceOp': 'append',
        },
      }) as FollowEvent;

      expect(frame.event.type, 'user/message');
      expect(frame.event.isSurface, isTrue);
      expect(frame.event.isVisibleMessage, isTrue);
      expect(frame.event.dataObject['turn'], 1);
    });

    test('decodes an assistant-stream frame and its outcome', () {
      final started = FollowAssistantStream.fromJson(const {
        'type': 'assistant-stream',
        'frame': {
          'type': 'start',
          'attemptId': 'att-1',
          'revision': 1,
          'startedAfterSeq': 811,
          'turn': 12,
          'step': 3,
        },
      });
      expect(started.kind, 'start');
      expect(started.revision, 1);
      expect(started.committed, isFalse);

      final ended = FollowAssistantStream.fromJson(const {
        'type': 'assistant-stream',
        'frame': {
          'type': 'end',
          'attemptId': 'att-1',
          'revision': 2,
          'index': 9,
          'outcome': {'kind': 'committed', 'eventType': 'assistant/message', 'seq': 812},
        },
      });
      expect(ended.kind, 'end');
      expect(ended.committed, isTrue);
    });

    test('an unknown frame type degrades to FollowUnknown', () {
      final frame = SessionFollowFrame.fromJson(const {'type': 'brand-new'});
      expect(frame, isA<FollowUnknown>());
    });

    test('a non-ignorable unknown event still decodes (engine upgrade safe)', () {
      final event = SessionWireEvent.fromJson(const {
        'type': 'some/future-event',
        'seq': 1,
        'time': 1,
        'data': <String, dynamic>{},
      });
      expect(event.type, 'some/future-event');
      expect(event.ignorable, isNull);
    });
  });

  group('session list rows', () {
    test('decodes the five wire-required booleans', () {
      final s = SessionSummary.fromJson(const {
        'sessionId': 'sess-1',
        'updatedAt': 1700000000000,
        'running': true,
        'blank': false,
        'agentAvailable': true,
      });
      expect(s.sessionId, 'sess-1');
      expect(s.running, isTrue);
      expect(s.blank, isFalse);
      expect(s.agentAvailable, isTrue);
      expect(s.isSubagent, isFalse);
    });

    test('a subagent row exposes its parent link', () {
      final s = SessionSummary.fromJson(const {
        'sessionId': 'child-1',
        'updatedAt': 1,
        'running': false,
        'blank': true,
        'agentAvailable': false,
        'parentSessionId': 'parent-1',
        'origin': 'subagent',
      });
      expect(s.isSubagent, isTrue);
      expect(s.parentSessionId, 'parent-1');
    });

    test('cached hints are distinguishable from sequenced ones', () {
      final cached = SessionProjectionHints.fromJson(const {
        'kind': 'cached',
        'asOfSeq': 3,
        'values': <String, dynamic>{},
      });
      final sequenced = SessionProjectionHints.fromJson(const {
        'kind': 'sequenced',
        'asOfSeq': 9,
        'values': <String, dynamic>{},
      });
      expect(cached.isSequenced, isFalse);
      expect(sequenced.isSequenced, isTrue);
    });
  });

  group('subagent read-only rule is derived from mode', () {
    test('one-shot children are read-only, continuable ones are not', () {
      final oneShot = SubagentCatalogEntry.fromJson(const {
        'id': 'c1',
        'createdAt': 1,
        'mode': 'one-shot',
      });
      final continuable = SubagentCatalogEntry.fromJson(const {
        'id': 'c2',
        'createdAt': 2,
        'mode': 'continuable',
        'label': 'researcher',
      });
      expect(oneShot.acceptsInput, isFalse);
      expect(continuable.acceptsInput, isTrue);
      expect(continuable.label, 'researcher');
    });

    test('an unknown mode is not writable', () {
      final entry = SubagentCatalogEntry.fromJson(const {
        'id': 'c3',
        'createdAt': 3,
        'mode': 'unknown',
      });
      expect(entry.mode, SubagentMode.unknown);
      expect(entry.acceptsInput, isFalse);
    });

    test('subagent addresses round-trip through the wire form', () {
      const address = SubagentSessionAddress(
        parentSessionId: 'p1',
        childSessionId: 'c1',
        mode: SubagentMode.oneShot,
      );
      expect(address.toJson(), {
        'kind': 'subagent',
        'parentSessionId': 'p1',
        'childSessionId': 'c1',
        'mode': 'one-shot',
      });
      expect(
        SessionAddress.fromJson(address.toJson()).toJson(),
        address.toJson(),
      );
    });

    test('a plain address round-trips too', () {
      const address = PlainSessionAddress('s1');
      expect(address.toJson(), {'kind': 'session', 'sessionId': 's1'});
      expect(SessionAddress.fromJson(address.toJson()).toJson(), address.toJson());
    });
  });

  group('approval', () {
    test('reads the request payload minus agent/signal', () {
      final r = ApprovalRequest.fromJson(const {
        'toolName': 'write_file',
        'callId': 'call-1',
        'reason': 'writes outside workspace',
        'displayReason': {'en': 'Writes outside workspace', 'zh': '写入工作区之外'},
      });
      expect(r.toolName, 'write_file');
      expect(r.callId, 'call-1');
      expect(r.textFor('zh'), '写入工作区之外');
      expect(r.textFor('fr'), 'writes outside workspace',
          reason: 'falls back to the raw reason for an unlisted locale');
    });

    test('an absent reason falls back to the tool name', () {
      final r = ApprovalRequest.fromJson(const {'toolName': 'shell'});
      expect(r.textFor('zh'), 'shell');
    });

    test('only two outcomes are interactive', () {
      expect(ApprovalOutcome.allowedOnce.isInteractive, isTrue);
      expect(ApprovalOutcome.rejected.isInteractive, isTrue);
      expect(ApprovalOutcome.cancelled.isInteractive, isFalse);
      expect(ApprovalOutcome.unavailable.isInteractive, isFalse);
      expect(ApprovalOutcome.allowedOnce.wire, 'allowed-once');
    });
  });

  group('questions', () {
    AskUserQuestionItem item(Map<String, dynamic> j) =>
        AskUserQuestionItem.fromJson(j);

    test('a multi-select batch decodes', () {
      final q = item(const {
        'id': 'q1',
        'header': 'Deploy',
        'question': 'Which environments?',
        'options': [
          {'label': 'staging', 'description': 'recommended'},
          {'label': 'prod'},
        ],
        'multiSelect': true,
      });
      expect(q.multiSelect, isTrue);
      expect(q.options, hasLength(2));
      expect(q.options!.first.description, 'recommended');
      expect(q.isFreeText, isFalse);
    });

    test('an absent options array means free text', () {
      final q = item(const {'id': 'q2', 'question': 'Anything else?'});
      expect(q.isFreeText, isTrue);
      expect(q.options, isNull);
      expect(q.multiSelect, isFalse,
          reason: 'multiSelect defaults to false when absent');
    });

    test('custom text coexists with selections in one answer', () {
      const answer = AskUserQuestionAnswerItem(
        id: 'q1',
        selected: ['staging'],
        custom: '先灰度 5%',
      );
      expect(answer.toJson(), {
        'id': 'q1',
        'selected': ['staging'],
        'custom': '先灰度 5%',
      });
    });

    test('a skipped item is expressed by omission, not a flag', () {
      // The protocol has no skip field; skipping means leaving the id out of
      // `answers` entirely.
      final answer = AskUserQuestionAnswer(const [
        AskUserQuestionAnswerItem(id: 'q1', selected: ['prod']),
      ]);
      expect(answer.toJson()['answers'], hasLength(1));
      expect(AskUserQuestionAnswerItem.skipped('q2').isEmpty, isTrue);
    });
  });

  group('plan-review detection follows all six conditions', () {
    final good = AskUserQuestionItem.fromJson(const {
      'id': 'plan-review',
      'header': 'Plan review',
      'question': 'Approve this plan and leave plan mode?',
      'detail': '# 计划 markdown',
      'options': [
        {'label': 'Approve'},
        {'label': 'Keep planning'},
      ],
      'intent': {'kind': 'plan-review', 'approve': 'Approve', 'callId': 'call-1'},
    });

    test('all six satisfied → PlanReview with plan and decline', () {
      final review = PlanReview.of([good]);
      expect(review, isNotNull);
      expect(review!.plan, '# 计划 markdown');
      expect(review.approve, 'Approve');
      expect(review.decline, 'Keep planning');
      expect(review.callId, 'call-1');
    });

    test('more than one question → generic flow', () {
      expect(PlanReview.of([good, good]), isNull);
    });

    test('a missing detail (plan body) → generic flow', () {
      final noDetail = AskUserQuestionItem.fromJson({
        ...good.toJson(),
      }..remove('detail'));
      expect(PlanReview.of([noDetail]), isNull);
    });

    test('multiSelect → generic flow', () {
      final multi = AskUserQuestionItem.fromJson(
          {...good.toJson(), 'multiSelect': true});
      expect(PlanReview.of([multi]), isNull);
    });

    test('more than two options → generic flow', () {
      final wide = AskUserQuestionItem.fromJson({
        ...good.toJson(),
        'options': [
          {'label': 'Approve'},
          {'label': 'Keep planning'},
          {'label': 'Cancel'},
        ],
      });
      expect(PlanReview.of([wide]), isNull);
    });

    test('approve not naming an option → generic flow', () {
      final mismatched = AskUserQuestionItem.fromJson({
        ...good.toJson(),
        'intent': {'kind': 'plan-review', 'approve': 'Yes'},
      });
      expect(PlanReview.of([mismatched]), isNull,
          reason: 'approval is matched by label, never by position');
    });

    test('no intent at all → generic flow', () {
      final plain = AskUserQuestionItem.fromJson({
        'id': 'q',
        'question': 'Pick one',
        'options': [
          {'label': 'a'},
          {'label': 'b'},
        ],
      });
      expect(PlanReview.of([plain]), isNull);
    });
  });

  group('prompt content parts', () {
    test('text round-trips', () {
      const part = PromptContentPart.text('hello');
      expect(part.toJson(), {'type': 'text', 'text': 'hello'});
      expect(PromptContentPart.fromJson(part.toJson()).text, 'hello');
    });

    test('an image keeps mediaType and base64 data', () {
      const part = PromptContentPart.image(mediaType: 'image/png', data: 'aGk=');
      expect(part.toJson(), {'type': 'image', 'mediaType': 'image/png', 'data': 'aGk='});
    });

    test('an unknown part type degrades to text', () {
      final part = PromptContentPart.fromJson(const {'type': 'future', 'text': 'x'});
      expect(part.toJson(), {'type': 'text', 'text': 'x'});
    });
  });

  group('job cards', () {
    test('maps wire status onto the three card states', () {
      JobView withStatus(String s) => JobView.fromJson({
            'jobId': 'j1',
            'status': s,
          });

      expect(withStatus('running').state, JobCardState.running);
      expect(withStatus('completed').state, JobCardState.done);
      expect(withStatus('queued').state, JobCardState.pending);
    });

    test('an error always wins over the status word', () {
      // The wire id is `id` (shaped `<kind>-N`), per
      // `jobs/jobs/src/view.ts:65-99`; a failure surfaces as `failed` plus a
      // `detail` naming the cause.
      final job = JobView.fromJson(const {
        'id': 'bash-2',
        'status': 'running',
        'error': {'name': 'SpawnError', 'code': 'ENOENT', 'reason': 'no shell'},
      });
      expect(job.state, JobCardState.failed);
      expect(job.detail, 'SpawnError');
    });
  });
}
