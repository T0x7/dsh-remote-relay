import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:flutter/foundation.dart';

/// Answer state for one pending question batch (mockup 屏 P).
///
/// Two rules from the contract drive the whole design, and neither is
/// obvious from the wire shape:
///
/// - **A skipped question is expressed by omission.** The protocol has no skip
///  flag: the official client leaves the id out of `answers`, or sends it with
/// an empty `selected` (§5.2). So "skip" is a UI state that produces *no*
/// entry, and [answerItems] is where that becomes wire shape.
/// - **`custom` coexists with `selected`.** A multi-select with one free-text
///  addition is one answer item carrying both, not two items.
class QuestionAnswerState extends ChangeNotifier {
  QuestionAnswerState(this.questions)
      : _selections = {
          for (final question in questions) question.id: <String>{},
        },
        _customs = {for (final question in questions) question.id: ''};

  final List<AskUserQuestionItem> questions;
  final Map<String, Set<String>> _selections;
  final Map<String, String> _customs;

  Set<String> selectionOf(String id) => _selections[id] ?? const {};

  String customOf(String id) => _customs[id] ?? '';

  bool isMultiSelect(String id) =>
      questions.any((q) => q.id == id && q.multiSelect);

  bool isFreeText(String id) =>
      questions.any((q) => q.id == id && q.isFreeText);

  /// Toggle one option. Single-select questions replace rather than accumulate.
  void toggle(String id, String label) {
    final question = questions.firstWhere((q) => q.id == id);
    final current = _selections.putIfAbsent(id, () => <String>{});
    if (question.multiSelect) {
      if (!current.remove(label)) current.add(label);
    } else {
      final wasSelected = current.contains(label);
      current
        ..clear()
        ..addAll(wasSelected ? const <String>[] : [label]);
    }
    notifyListeners();
  }

  void setCustom(String id, String text) {
    _customs[id] = text;
    notifyListeners();
  }

  /// Mark a question answered without a choice — the wire's empty selection.
  void answerEmpty(String id) {
    _selections.putIfAbsent(id, () => <String>{});
    notifyListeners();
  }

  /// Undo a selection or free-text entry, returning the question to unanswered.
  void reset(String id) {
    _selections[id] = <String>{};
    _customs[id] = '';
    notifyListeners();
  }

  /// Whether the question carries anything worth sending.
  bool isAnswered(String id) =>
      selectionOf(id).isNotEmpty || customOf(id).trim().isNotEmpty;

  bool get isComplete => questions.every((q) => isAnswered(q.id));

  int get answeredCount => questions.where((q) => isAnswered(q.id)).length;

  /// The wire payload: **only answered questions appear**.
  ///
  /// A skipped question is simply absent, which is how the official client
  /// expresses it and how the tool result reads it back.
  List<AskUserQuestionAnswerItem> get answerItems => [
        for (final question in questions)
          if (isAnswered(question.id))
            AskUserQuestionAnswerItem(
              id: question.id,
              selected: selectionOf(question.id).toList(growable: false),
              custom: customOf(question.id).trim().isEmpty
                  ? null
                  : customOf(question.id).trim(),
            ),
      ];

  /// `{answers: [...]}` — the bare value posted to `$events/result`.
  Map<String, dynamic> toWire() => AskUserQuestionAnswer(answerItems).toJson();
}

/// A plan review answered as a decision, not a batch.
///
/// Approve and decline are the two option labels the intent named
/// (`intent.approve`, and any other label means decline). Matching is **by
/// name, never by position** — the engine asserts the approve label names a
/// real option and the UI must not infer from ordering.
class PlanReviewDecision {
  const PlanReviewDecision.approve()
      : selected = null,
        isApprove = true;

  const PlanReviewDecision.decline(this.selected) : isApprove = false;

  final String? selected;
  final bool isApprove;

  Map<String, dynamic> toWire(PlanReview review) => AskUserQuestionAnswer([
        AskUserQuestionAnswerItem(
          id: review.id,
          selected: [selected ?? review.approve],
        ),
      ]).toJson();
}
