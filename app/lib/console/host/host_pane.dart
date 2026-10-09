import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

import '../inline_error_card.dart';

/// The host view (mockup 屏 F, 主机 segment).
///
/// **D-081**: the roster moved from `pluginInventory/list` (read-only) to
/// `pluginManager/listPlugins` — the same rows plus per-row switchability
/// (`patchId`) or the engine's own refusal reason (`readOnlyReason`:
/// `management-required` on protected core modules, `unaddressable` when no
/// unique live loader entry exists). Switchable rows render a Switch wired to
/// `pluginManager/setPluginEnabled`; per the D-078 lesson the row updates only
/// after the engine confirms — a failed toggle reverts and surfaces the error.
class HostPane extends StatefulWidget {
  const HostPane({
    super.key,
    required this.gateway,
    required this.machineName,
    required this.sessions,
    required this.selection,
    required this.l10n,
  });

  final EngineGateway gateway;
  final String machineName;
  final List<SessionSummary> sessions;
  final ModelSelection? selection;
  final L10n l10n;

  @override
  State<HostPane> createState() => _HostPaneState();
}

class _HostPaneState extends State<HostPane> {
  List<PluginBundle> _bundles = const [];
  Set<String> _expanded = const {};
  AppError? _error;
  bool _loading = true;

  /// entryId → in-flight toggle; the Switch shows progress and ignores taps.
  final Set<String> _pending = {};

  /// entryId → engine said `restart-required`; the live state stays as-is.
  final Map<String, bool> _restartRequired = {};



  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await widget.gateway.pluginManagerListBundles();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.isOk) {
        _bundles = PluginBundle.listFrom(result.value);
        _error = null;
      } else {
        _error = result.error!.toAppError();
      }
    });
  }

  Future<void> _toggle(PluginBundle bundle) async {
    if (_pending.contains(bundle.name) || !bundle.switchable) return;
    setState(() => _pending.add(bundle.name));
    final result = await widget.gateway.pluginManagerSetBundleEnabled(
      name: bundle.name,
      enabled: !bundle.enabled,
    );
    if (!mounted) return;
    setState(() => _pending.remove(bundle.name));
    if (!result.isOk) {
      // D-078：失败保留原状并把错误顶给用户，绝不静默。
      setState(() => _error = result.error!.toAppError());
      return;
    }

    // D-086：**别把回复当成「已经改了」的证据** —— 重新读一次清单，以引擎
    // 自己的答案为准。
    //
    // 真机 L3 实证（2026-10-09）：引擎写路径挂死时返回了 ok /
    // `application: applied`，而 `package.json` 的 mtime 停在 Oct 4、
    // 引擎日志里连一条插件痕迹都没有。按旧逻辑（`isOk` 即翻转）UI 会显示
    // 一个从未发生的变更，且没有错误提示——比 D-078 当初修的「失败被吞掉」
    // 更隐蔽，因为这次失败穿的是「成功」。
    //
    // 重读对真正成功的切换同样无害：读回来的正是刚写下的值。区别在于，
    // 「说成功其实没做」只有重读能识破。
    final wants = !bundle.enabled;
    final change = asObject(result.value) ?? const <String, dynamic>{};
    final application = change['application'] as String? ?? 'applied';

    await _load();
    if (!mounted) return;

    final landed = _bundles.firstWhere((b) => b.name == bundle.name).enabled;
    setState(() {
      if (landed == wants) {
        // 运行时已经是目标状态（当场生效，或引擎的「待重启」已写进配置）。
        _error = null;
        _restartRequired.remove(bundle.name);
      } else if (application == 'restart-required') {
        // 引擎明说「重启后才生效」，重读也确认运行态没变——两处一致。
        _error = null;
        _restartRequired[bundle.name] = wants;
      } else {
        // 引擎说「已生效」而重读说没变——它撒谎了，或者请求根本没落地
        // （真机 L3 实测：写路径挂死时正是如此）。标成「待重启」会骗用户
        // 说重启就会生效，而事实上永远不会。只能如实说没验成。
        _restartRequired.remove(bundle.name);
        _error = AppError(
          ErrorCode.engineUnknown,
          detail: 'engine reported "${bundle.name}" as applied, but the '
              're-read shows it unchanged — the change did not land',
        );
      }
    });
  }

  void _toggleExpanded(String name) => setState(() {
        _expanded = _expanded.contains(name)
            ? ({..._expanded}..remove(name))
            : {..._expanded, name};
      });

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppTheme.m, AppTheme.m, AppTheme.m, AppTheme.xl),
      children: [
        _HostHeader(machine: widget.machineName, l10n: l10n),
        const SizedBox(height: AppTheme.m),
        _Row(l10n.hostSessions, '${widget.sessions.length}'),
        _Row(
          l10n.hostModel,
          widget.selection == null
              ? l10n.modelFollowDefault
              : widget.selection!.model,
        ),
        const SizedBox(height: AppTheme.m),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(AppTheme.l),
            child: Center(
              child: SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          )
        else ...[
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.s),
              child: InlineErrorCard(error: _error!, l10n: l10n),
            ),
          Text(l10n.hostPlugins,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: AppTheme.xs),
          Text(l10n.hostPluginsNote,
              style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
          const SizedBox(height: AppTheme.s),
          for (final bundle in _bundles)
            _BundleCard(
              bundle: bundle,
              l10n: l10n,
              locale: Localizations.localeOf(context).languageCode,
              expanded: _expanded.contains(bundle.name),
              pending: _pending.contains(bundle.name),
              restartRequired: _restartRequired.containsKey(bundle.name),
              onToggle: () => _toggle(bundle),
              onExpand: () => _toggleExpanded(bundle.name),
            ),

        ],
        const SizedBox(height: AppTheme.m),
        Text(l10n.hostMetricsUnavailable,
            style: const TextStyle(fontSize: 10.5, color: AppTheme.inkDim)),
      ],
    );
  }
}

/// One installed bundle (package) row: name + version + state, expandable to
/// its internal modules. The switch is per **bundle** — switching one loader
/// entry inside a core patch is what `management-required` forbids.
class _BundleCard extends StatelessWidget {
  const _BundleCard({
    required this.bundle,
    required this.l10n,
    required this.locale,
    required this.expanded,
    required this.pending,
    required this.restartRequired,
    required this.onToggle,
    required this.onExpand,
  });

  final PluginBundle bundle;
  final L10n l10n;
  final String locale;
  final bool expanded;
  final bool pending;
  final bool restartRequired;
  final VoidCallback onToggle;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final live = restartRequired ? !bundle.enabled : bundle.enabled;
    final desc = bundle.localizedDescription(locale);
    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.xs),
      padding: const EdgeInsets.fromLTRB(AppTheme.s, AppTheme.xs, AppTheme.xs, AppTheme.xs),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onExpand,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(bundle.displayName(locale),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: live ? AppTheme.ink : AppTheme.inkDim,
                            )),
                        if (bundle.version != null)
                          Text('v${bundle.version} · ${bundle.rows.length} ${l10n.hostBundleModules}',
                              style: const TextStyle(
                                  fontSize: 9.5, color: AppTheme.inkDim)),
                      ],
                    ),
                  ),
                ),
              ),
              if (!bundle.switchable)
                Text(l10n.hostPluginCoreLocked,
                    style: const TextStyle(fontSize: 9.5, color: AppTheme.inkDim))
              else if (restartRequired)
                Text(l10n.hostPluginRestartRequired,
                    style: const TextStyle(fontSize: 9.5, color: AppTheme.accent))
              else
                SizedBox(
                  height: 26,
                  child: Switch(
                    value: bundle.enabled,
                    onChanged: pending ? null : (_) => onToggle(),
                  ),
                ),
            ],
          ),
          if (expanded) ...[
            if (desc != null && desc.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.xs),
                child: Text(desc,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.inkDim)),
              ),
            for (final row in bundle.rows)
              Padding(
                padding: const EdgeInsets.only(left: AppTheme.s, top: 2, bottom: 2),
                child: Row(
                  children: [
                    const Icon(Icons.extension_outlined, size: 11, color: AppTheme.inkDim),
                    const SizedBox(width: AppTheme.xs),
                    Expanded(
                      child: Text(row.moduleName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10.5,
                              fontFamily: 'monospace',
                              color: AppTheme.inkDim)),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _HostHeader extends StatelessWidget {
  const _HostHeader({required this.machine, required this.l10n});
  final String machine;
  final L10n l10n;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.dns_outlined, size: 16, color: AppTheme.accent),
          const SizedBox(width: AppTheme.s),
          Text(machine,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ],
      );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 11.5, color: AppTheme.inkDim))),
            Text(value,
                style: const TextStyle(
                    fontSize: 11.5, fontFamily: 'monospace', color: AppTheme.ink)),
          ],
        ),
      );
}