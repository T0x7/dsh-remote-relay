import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// What the console shows for a session's current model, and what tapping the
/// top-bar chip opens (mockup 屏 K).
///
/// Two contract facts shape this whole file:
///
/// - **The catalog is the only source of truth.** The App ships no model list:
///   providers, models, effort levels and their defaults all arrive from
///   `session/modelCatalog` (§6.1). A non-reasoning model simply arrives with
///   no `reasoning` block and therefore offers no chips — never a hardcoded
///   "Off/Low/High/Max".
/// - **"Follow default" is not a flag.** It means the `modelSelection`
///   projection's `next` is null: the session has never chosen, so the
///   effective selection is `ModelCatalog.default` (§6.3). Picking the
///   default explicitly posts those same three fields with
///   `reasoningEffort` omitted.
class ModelPickerSheet extends StatefulWidget {
  const ModelPickerSheet({
    super.key,
    required this.catalog,
    required this.current,
    required this.l10n,
    required this.onSelect,
  });

  final ModelCatalog catalog;

  /// The session's live selection, or null when it follows the default.
  final ModelSelection? current;

  final L10n l10n;
  final void Function(String provider, String model, String? effort) onSelect;

  /// Present the sheet. Returns the chosen triple, or null if dismissed.
  static Future<({String provider, String model, String? effort})?> show(
    BuildContext context, {
    required ModelCatalog catalog,
    required ModelSelection? current,
    required L10n l10n,
    required void Function(String provider, String model, String? effort) onSelect,
  }) =>
      showModalBottomSheet<({String provider, String model, String? effort})>(
        context: context,
        backgroundColor: AppTheme.surface,
        isScrollControlled: true,
        builder: (_) => ModelPickerSheet(
          catalog: catalog,
          current: current,
          l10n: l10n,
          onSelect: onSelect,
        ),
      ).then((choice) {
        if (choice == null) return null;
        onSelect(choice.provider, choice.model, choice.effort);
        return choice;
      });

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  String? _expandedModel;

  /// The selection the session effectively uses right now.
  ModelSelection get _effective =>
      widget.current ?? widget.catalog.defaultSelection;

  bool _isCurrent(String provider, String model) =>
      _effective.provider == provider && _effective.model == model;

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(
              AppTheme.l, AppTheme.m, AppTheme.l, AppTheme.xl),
          children: [
            Row(
              children: [
                Text(l10n.modelTitle,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (widget.current == null)
                  _FollowDefaultChip(label: l10n.modelFollowDefault),
              ],
            ),
            const SizedBox(height: AppTheme.xs),
            Text(
              widget.current == null
                  ? l10n.modelFollowDefaultBody
                  : l10n.modelPickedBody,
              style: const TextStyle(fontSize: 11.5, color: AppTheme.inkDim),
            ),
            const SizedBox(height: AppTheme.m),
            for (final group in widget.catalog.groups) ...[
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.s, bottom: AppTheme.xs),
                child: Text(group.name,
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.inkDim,
                        fontFamily: 'monospace')),
              ),
              for (final model in group.models)
                _ModelRow(
                  key: ValueKey('${group.id}/${model.id}'),
                  model: model,
                  selected: _isCurrent(group.id, model.id),
                  expanded: _expandedModel == '${group.id}/${model.id}',
                  l10n: l10n,
                  onTap: () {
                    final key = '${group.id}/${model.id}';
                    setState(() => _expandedModel = _expandedModel == key ? null : key);
                  },
                  onChoose: (effort) {
                    Navigator.of(context).pop((
                      provider: group.id,
                      model: model.id,
                      effort: effort,
                    ));
                  },
                ),
            ],
            if (widget.catalog.failures.isNotEmpty) ...[
              const SizedBox(height: AppTheme.m),
              Text(l10n.modelCatalogFailures,
                  style: const TextStyle(fontSize: 11, color: AppTheme.warn)),
              for (final failure in widget.catalog.failures)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('${failure.name}: ${failure.message}',
                      style: const TextStyle(
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                          color: AppTheme.inkDim)),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatefulWidget {
  const _ModelRow({
    super.key,
    required this.model,
    required this.selected,
    required this.expanded,
    required this.l10n,
    required this.onTap,
    required this.onChoose,
  });

  final ModelCatalogModel model;
  final bool selected;
  final bool expanded;
  final L10n l10n;
  final VoidCallback onTap;
  final void Function(String? effort) onChoose;

  @override
  State<_ModelRow> createState() => _ModelRowState();
}

class _ModelRowState extends State<_ModelRow> {
  /// The effort picked for this model; null means "the model's own default",
  /// which the wire expresses by omitting `reasoningEffort` entirely (§6.3).
  String? _effort;

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final model = widget.model;
    final efforts = model.efforts;
    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.s),
      padding: const EdgeInsets.all(AppTheme.m),
      decoration: BoxDecoration(
        color: widget.selected
            ? AppTheme.accent.withValues(alpha: 0.08)
            : AppTheme.surfaceHigh,
        border: Border.all(
          color: widget.selected ? AppTheme.accent : AppTheme.line,
          width: widget.selected ? 1.4 : 1,
        ),
        borderRadius: BorderRadius.circular(AppTheme.m),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: widget.onTap,
            child: Row(
              children: [
                if (widget.selected)
                  const Padding(
                    padding: EdgeInsets.only(right: AppTheme.xs),
                    child:
                        Icon(Icons.check_circle, size: 14, color: AppTheme.accent),
                  ),
                Expanded(
                  child: Text(model.name,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          if (model.description != null && model.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(model.description!,
                  style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
            ),
          // A model with no reasoning block offers no effort chips at all —
          // the levels are whatever the adapter reported, never a fixed set.
          if (efforts.isNotEmpty && widget.expanded) ...[
            const SizedBox(height: AppTheme.s),
            Wrap(
              spacing: AppTheme.s,
              runSpacing: AppTheme.s,
              children: [
                for (final effort in efforts)
                  ChoiceChip(
                    label: Text(effort.name),
                    selected: _effort == effort.id,
                    onSelected: (_) => setState(() => _effort = effort.id),
                    labelStyle: const TextStyle(fontSize: 11.5),
                    visualDensity: VisualDensity.compact,
                  ),
                ActionChip(
                  label: Text(l10n.modelUseThis),
                  onPressed: () => widget.onChoose(_effort),
                  labelStyle: const TextStyle(fontSize: 11.5),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FollowDefaultChip extends StatelessWidget {
  const _FollowDefaultChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.s, vertical: 3),
        decoration: BoxDecoration(
          color: AppTheme.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 10.5, color: AppTheme.accent)),
      );
}

/// The top-bar chip: `model · effort`, or a muted `跟随默认`.
class ModelChip extends StatelessWidget {
  const ModelChip({
    super.key,
    required this.selection,
    required this.followsDefault,
    required this.l10n,
    required this.onTap,
  });

  final ModelSelection? selection;
  final bool followsDefault;
  final L10n l10n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = followsDefault || selection == null
        ? l10n.modelFollowDefault
        // The generated getter takes its placeholders in declaration order,
        // which is `(effort, model)` for `{model} · {effort}`.
        : l10n.modelEffortChip(
            selection!.reasoningEffort ?? l10n.modelEffortDefault,
            selection!.model,
          );
    return LayoutBuilder(builder: (context, constraints) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.m, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.surfaceHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // D-038: a catalog model name is whatever the engine says, and
              // the app bar is shared with the machine chip. This chip is a
              // min-size Row, so the label needs the width the PARENT granted
              // — a `Flexible` here would inherit the Row's unbounded min-size
              // and stay just as unshrinkable as the bare Text it replaced.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppTheme.ink),
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 15, color: AppTheme.inkDim),
            ],
          ),
        ),
      ));
  }
}
