import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_core/api/workspace_registry.dart';

import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// What 「新会话」 hands back to the console: which preset runs the first
/// turn, and — optionally — which registered workspace the session opens in.
///
/// [preset] follows the sheet's original contract: `''` = 直接新建（不传
/// preset，引擎默认 standard）。[workspaceId] is `null` for the engine's
/// default cwd — the exact pre-feature behavior.
class NewSessionChoice {
  const NewSessionChoice({required this.preset, this.workspaceId});

  final String preset;
  final String? workspaceId;
}

/// D-073: 「新会话」的 agent 预设选择面板。
///
/// dsh web 在工作区选择器旁常驻一个 preset 下拉（「标准模式 ▾」），手机上
/// 顶栏塞不下，收进「新会话」的第一跳：面板顶部一颗**直接新建**（不传
/// preset，引擎默认 standard），下面按 `order` 列出全部预设。
///
/// 工作区选择（与预设**同一张面板**，用户定稿的 combined 方案）：面板头部
/// 一行 chips——「引擎默认」+ registry 里的每个工作区。默认选中「引擎默认」，
/// 快路径与加这个功能之前逐字节相同。[workspaces] 传空（registry 未就绪）
/// 时整段隐藏，面板退化为纯预设选择。
///
/// 返回值：null = 用户关闭面板/放弃；非 null = [NewSessionChoice]。
/// `broken` 的预设可见但**不可选**——引擎侧自己都标了配置损坏，选了也会在
/// 回合开始时炸。
Future<NewSessionChoice?> showAgentPresetSheet(
  BuildContext context,
  EngineGateway gateway, {
  List<WorkspaceView> workspaces = const [],
}) {
  return showModalBottomSheet<NewSessionChoice>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => SafeArea(
      child: _AgentPresetSheet(gateway: gateway, workspaces: workspaces),
    ),
  );
}

class _AgentPresetSheet extends StatefulWidget {
  const _AgentPresetSheet({required this.gateway, required this.workspaces});

  final EngineGateway gateway;
  final List<WorkspaceView> workspaces;

  @override
  State<_AgentPresetSheet> createState() => _AgentPresetSheetState();
}

class _AgentPresetSheetState extends State<_AgentPresetSheet> {
  late final Future<EngineRpcResult> _loaded = widget.gateway.listAgentPresets();

  /// `null` = 引擎默认 cwd——与功能上线前的行为完全一致。
  String? _workspaceId;

  void _pop(String preset) => Navigator.of(context).pop(NewSessionChoice(
        preset: preset,
        workspaceId: _workspaceId,
      ));

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.l, AppTheme.l, AppTheme.l, AppTheme.xs),
            child: Text(l10n.presetsSheetTitle,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          if (widget.workspaces.isNotEmpty)
            _WorkspacePicker(
              workspaces: widget.workspaces,
              selectedId: _workspaceId,
              onSelected: (id) => setState(() => _workspaceId = id),
            ),
          // 直接新建永远第一颗：默认 preset 的快路径保持一击直达，
          // 选预设是可选项而不是强制步骤。
          ListTile(
            dense: true,
            leading: const Icon(Icons.add, size: 20, color: AppTheme.accent),
            title: Text(l10n.presetsQuickCreate,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            onTap: () => _pop(''),
          ),
          const Divider(height: 1, color: AppTheme.line),
          Flexible(
            child: FutureBuilder<EngineRpcResult>(
              future: _loaded,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(AppTheme.l),
                    child: Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  );
                }
                final result = snap.data!;
                if (!result.isOk) {
                  return Padding(
                    padding: const EdgeInsets.all(AppTheme.l),
                    child: Text(l10n.presetsLoadFailed,
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.inkDim)),
                  );
                }
                final raw =
                    (result.value! as Map<String, dynamic>)['presets'];
                final presets = (raw is List ? raw : const <Object?>[])
                    .map(asObject)
                    .whereType<Map<String, dynamic>>()
                    .map(AgentPresetSummary.fromJson)
                    .toList()
                  ..sort((a, b) => a.order.compareTo(b.order));
                if (presets.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(AppTheme.l),
                    child: Text(l10n.presetsLoadFailed,
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.inkDim)),
                  );
                }
                return ListView(
                  shrinkWrap: true,
                  children: [
                    for (final preset in presets)
                      ListTile(
                        dense: true,
                        enabled: preset.broken == null,
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(preset.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: preset.broken == null
                                          ? AppTheme.ink
                                          : AppTheme.inkDim)),
                            ),
                            if (preset.isDefault) ...[
                              const SizedBox(width: AppTheme.xs),
                              Text(l10n.presetsDefaultChip,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: AppTheme.accent)),
                            ],
                            if (preset.broken != null) ...[
                              const SizedBox(width: AppTheme.xs),
                              Text(l10n.presetsBrokenChip,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: AppTheme.danger)),
                            ],
                          ],
                        ),
                        subtitle: (preset.description != null &&
                                preset.description!.isNotEmpty)
                            ? Text(preset.description!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    color: AppTheme.inkDim))
                            : null,
                        onTap: preset.broken == null ? () => _pop(preset.id) : null,
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: AppTheme.s),
        ],
      ),
    );
  }
}

/// 工作区 chips：第一颗恒为「引擎默认」，其后按 registry 原序列出。
///
/// registry 快照在弹窗打开的那一刻定格（console_page 把当前值传进来）——
/// 弹窗存续期间 registry 的更新不追：一次「新建会话」是秒级动作，
/// 面板内实时刷新只会带来跳动，不带来正确性。
class _WorkspacePicker extends StatelessWidget {
  const _WorkspacePicker({
    required this.workspaces,
    required this.selectedId,
    required this.onSelected,
  });

  final List<WorkspaceView> workspaces;
  final String? selectedId;
  final void Function(String?) onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTheme.l, 0, 0, AppTheme.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.presetsWorkspaceSection,
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.inkDim)),
          const SizedBox(height: AppTheme.xs),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              shrinkWrap: true,
              children: [
                _chip(
                  label: l10n.presetsWorkspaceDefault,
                  tooltip: null,
                  selected: selectedId == null,
                  onTap: () => onSelected(null),
                ),
                for (final workspace in workspaces)
                  _chip(
                    label: workspace.title,
                    tooltip: workspace.path,
                    selected: selectedId == workspace.workspaceId,
                    onTap: () => onSelected(workspace.workspaceId),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required String? tooltip,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.only(right: AppTheme.s),
        child: Tooltip(
          message: tooltip ?? '',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.m, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? AppTheme.accent.withValues(alpha: 0.14)
                    : AppTheme.surfaceHigh,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected ? AppTheme.accent : Colors.transparent,
                ),
              ),
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color:
                          selected ? AppTheme.accent : AppTheme.ink)),
            ),
          ),
        ),
      );
}
