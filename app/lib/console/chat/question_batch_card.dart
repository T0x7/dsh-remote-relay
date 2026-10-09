import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

import 'question_answer_state.dart';

/// The generic question card (mockup 屏 P).
///
/// Renders a whole batch: each question is single-select, multi-select, or
/// free text depending on what the engine sent. A question the user does not
/// answer is **omitted** from the payload — that is the wire's only way to
/// express a skip, so "跳过" is a local affordance, never a flag.
class QuestionBatchCard extends StatefulWidget {
  const QuestionBatchCard({
    super.key,
    required this.questions,
    required this.l10n,
    required this.onSubmit,
    required this.onAbandon,
  });

  final List<AskUserQuestionItem> questions;
  final L10n l10n;
  final void Function(Map<String, dynamic> wire) onSubmit;
  final VoidCallback onAbandon;

  @override
  State<QuestionBatchCard> createState() => _QuestionBatchCardState();
}

class _QuestionBatchCardState extends State<QuestionBatchCard> {
  late final QuestionAnswerState _state =
      QuestionAnswerState(widget.questions);

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.s),
      padding: const EdgeInsets.all(AppTheme.m),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.05),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(AppTheme.m),
      ),
      child: AnimatedBuilder(
        animation: _state,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.chatQuestionPending,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: AppTheme.s),
            for (final question in widget.questions)
              _QuestionBlock(question: question, state: _state, l10n: l10n),
            const SizedBox(height: AppTheme.s),
            Row(
              children: [
                Text(
                  l10n.chatQuestionProgress(
                      _state.answeredCount, widget.questions.length),
                  style: const TextStyle(fontSize: 11, color: AppTheme.inkDim),
                ),
                const Spacer(),
                TextButton(
                  onPressed: widget.onAbandon,
                  child: Text(l10n.chatQuestionAbandon,
                      style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: AppTheme.xs),
                FilledButton(
                  onPressed: _state.isComplete
                      ? () => widget.onSubmit(_state.toWire())
                      : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    backgroundColor: AppTheme.accent,
                    foregroundColor: AppTheme.bg,
                  ),
                  child: Text(l10n.chatQuestionSubmit),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionBlock extends StatelessWidget {
  const _QuestionBlock({
    required this.question,
    required this.state,
    required this.l10n,
  });

  final AskUserQuestionItem question;
  final QuestionAnswerState state;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final options = question.options;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (question.header != null)
            Text(question.header!,
                style: const TextStyle(
                    fontSize: 10.5, color: AppTheme.inkDim, fontFamily: 'monospace')),
          Text(question.question,
              style: const TextStyle(fontSize: 13, color: AppTheme.ink)),
          if (question.detail != null && question.detail!.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: AppTheme.xs),
              padding: const EdgeInsets.all(AppTheme.s),
              constraints: const BoxConstraints(maxHeight: 120),
              decoration: BoxDecoration(
                color: AppTheme.bg,
                borderRadius: BorderRadius.circular(AppTheme.s),
              ),
              child: SingleChildScrollView(
                child: Text(question.detail!,
                    style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: AppTheme.inkDim)),
              ),
            ),
          const SizedBox(height: AppTheme.xs),
          if (options == null)
            _FreeTextField(question: question, state: state, l10n: l10n)
          else ...[
            RadioGroup<String>(
              // Single-select by contract: `multiSelect` absent means radio
              // semantics, and tapping the selected option clears it.
              groupValue: state.selectionOf(question.id).firstOrNull ?? '',
              onChanged: (value) {
                if (value == null) {
                  state.reset(question.id);
                } else {
                  state.toggle(question.id, value);
                }
              },
              child: Column(
                children: [
                  for (final option in options)
                    if (question.multiSelect)
                      _OptionRow(
                        label: option.label,
                        description: option.description,
                        selected:
                            state.selectionOf(question.id).contains(option.label),
                        control: Checkbox(
                          value: state
                              .selectionOf(question.id)
                              .contains(option.label),
                          onChanged: (_) =>
                              state.toggle(question.id, option.label),
                        ),
                        onTap: () => state.toggle(question.id, option.label),
                      )
                    else
                      _OptionRow(
                        label: option.label,
                        description: option.description,
                        selected:
                            state.selectionOf(question.id).contains(option.label),
                        control: null,
                        onTap: () => state.toggle(question.id, option.label),
                      ),
                ],
              ),
            ),
            // A multi-select answer item may ALSO carry `custom` — the
            // contract's example is "picked options plus one extra note", so
            // the field belongs to multi-select questions, not only to
            // free-text ones (§5.2).
            if (question.multiSelect) ...[
              const SizedBox(height: AppTheme.xs),
              _FreeTextField(
                question: question,
                state: state,
                l10n: l10n,
                hint: l10n.chatCustomAlongsideHint,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.description,
    required this.selected,
    required this.control,
    required this.onTap,
  });

  final String label;
  final String? description;
  final bool selected;

  /// The leading control. Null means "render a default radio", which
  /// [RadioGroup] above supplies the value and handler for.
  final Widget? control;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.s),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                // D-035: must be `Radio<String>` — the RadioGroup above is
                // `RadioGroup<String>`, and a mismatched generic never joins
                // the group: no groupValue arrives, so the radio draws hollow
                // forever and ignores taps even while the row's own onTap
                // toggles state (the "已答 N/M counts but nothing looks
                // selected" bug found on device).
                child: control ?? Radio<String>(value: label),
              ),
              const SizedBox(width: AppTheme.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(fontSize: 12.5, color: AppTheme.ink)),
                    if (description != null)
                      Text(description!,
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.inkDim)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _FreeTextField extends StatefulWidget {
  const _FreeTextField({
    required this.question,
    required this.state,
    required this.l10n,
    this.hint,
  });

  final AskUserQuestionItem question;
  final QuestionAnswerState state;
  final L10n l10n;

  /// Overrides the default hint — a multi-select's field is an *addition* to
  /// the picked options, not a replacement for them.
  final String? hint;

  @override
  State<_FreeTextField> createState() => _FreeTextFieldState();
}

class _FreeTextFieldState extends State<_FreeTextField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.state.customOf(widget.question.id));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        minLines: 1,
        maxLines: 4,
        style: const TextStyle(fontSize: 12.5, color: AppTheme.ink),
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hint ?? widget.l10n.chatFreeTextHint,
          hintStyle: const TextStyle(fontSize: 12, color: AppTheme.inkDim),
          border: const OutlineInputBorder(
            borderSide: BorderSide(color: AppTheme.line),
          ),
        ),
        onChanged: (value) => widget.state.setCustom(widget.question.id, value),
      );
}
