import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';

import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// D-073: 「新会话」的 agent 预设选择面板。
///
/// dsh web 在工作区选择器旁常驻一个 preset 下拉（「标准模式 ▾」），手机上
/// 顶栏塞不下，收进「新会话」的第一跳：面板顶部一颗**直接新建**（不传
/// preset，引擎默认 standard），下面按 `order` 列出全部预设。
///
/// 返回值：null = 用户关闭面板/放弃；`''` = 直接新建（不带 preset）；
/// 非空 = 所选 preset id。`broken` 的预设可见但**不可选**——引擎侧自己
/// 都标了配置损坏，选了也会在回合开始时炸。
Future<String?> showAgentPresetSheet(
  BuildContext context,
  EngineGateway gateway,
) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => SafeArea(
      child: _AgentPresetSheet(gateway: gateway),
    ),
  );
}

class _AgentPresetSheet extends StatefulWidget {
  const _AgentPresetSheet({required this.gateway});

  final EngineGateway gateway;

  @override
  State<_AgentPresetSheet> createState() => _AgentPresetSheetState();
}

class _AgentPresetSheetState extends State<_AgentPresetSheet> {
  late final Future<EngineRpcResult> _loaded = widget.gateway.listAgentPresets();

  void _pop(String value) => Navigator.of(context).pop(value);

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 520),
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
