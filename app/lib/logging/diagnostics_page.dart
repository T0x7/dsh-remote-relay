import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/generated/app_localizations.dart';
import '../ui/theme.dart';
import 'app_log.dart';

/// 屏 G「诊断日志」的查看页（logging plan P4）。
///
/// 只读视图 + 三个动作：复制全部 / 分享（系统分享面板，share_plus）/
/// 清空（二次确认）。内容来自 [AppLog.sink] 的**已脱敏**读回——文件里存的
/// 就是脱敏后的行，这里不存在第二套脱敏逻辑。sink 未安装（测试 / main 之前的
/// 极早期）时显示空态。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  late Future<_LogSnapshot> _snapshot;

  @override
  void initState() {
    super.initState();
    _snapshot = _load();
  }

  Future<_LogSnapshot> _load() async {
    final sink = AppLog.sink;
    if (sink == null) return _LogSnapshot.empty;
    final content = await sink.readAll();
    final size = await sink.sizeBytes();
    final files = await sink.files();
    return _LogSnapshot(content: content, size: size, files: files);
  }

  void _refresh() {
    // 先起 Future 再 setState：setState 的闭包不能返回 Future（框架断言），
    // 而箭头闭包 `() => _snapshot = future` 恰好把赋值表达式的 Future 返回了。
    final future = _load();
    setState(() {
      _snapshot = future;
    });
  }

  Future<void> _copyAll() async {
    final snap = await _snapshot;
    if (!mounted || snap.content.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: snap.content));
    if (!mounted) return;
    _snack(L10n.of(context).diagnosticsCopied);
  }

  /// 系统分享面板带出磁盘上的日志文件本体（含滚动出的 .old 一代），接收方
  /// 看到的是与 App 内查看完全相同的脱敏字节。
  Future<void> _share() async {
    final snap = await _snapshot;
    if (!mounted || snap.files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(
      files: [for (final f in snap.files) XFile(f.path)],
      subject: L10n.of(context).diagnosticsShareSubject,
      title: L10n.of(context).diagnosticsShareSubject,
    ));
  }

  Future<void> _clear() async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.diagnosticsClearTitle),
        content: Text(l10n.diagnosticsClearBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.diagnosticsCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.diagnosticsClear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AppLog.sink?.clear();
    if (!mounted) return;
    _snack(L10n.of(context).diagnosticsCleared);
    _refresh();
  }

  void _snack(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsDiagnosticsTitle),
        actions: [
          IconButton(
            tooltip: l10n.diagnosticsCopyAll,
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: l10n.diagnosticsShare,
            icon: const Icon(Icons.ios_share_rounded, size: 20),
            onPressed: _share,
          ),
          IconButton(
            tooltip: l10n.diagnosticsClear,
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            onPressed: _clear,
          ),
        ],
      ),
      body: FutureBuilder<_LogSnapshot>(
        future: _snapshot,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!;
          if (data.content.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.article_outlined,
                      size: 56, color: AppTheme.inkDim),
                  const SizedBox(height: AppTheme.m),
                  Text(l10n.diagnosticsEmpty,
                      style: const TextStyle(
                          fontSize: 13, color: AppTheme.inkDim)),
                ],
              ),
            );
          }
          final lines =
              data.content.split('\n')..removeWhere((l) => l.isEmpty);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppTheme.m, AppTheme.s, AppTheme.m, 0),
                child: Text(
                  l10n.diagnosticsMeta(
                      _humanBytes(data.size), lines.length.toString()),
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.inkDim),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(AppTheme.m),
                  itemCount: lines.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Text(
                      lines[i],
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.45,
                        fontFamily: 'monospace',
                        color: AppTheme.ink,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _humanBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _LogSnapshot {
  const _LogSnapshot({
    required this.content,
    required this.size,
    required this.files,
  });

  static const _LogSnapshot empty =
      _LogSnapshot(content: '', size: 0, files: []);

  final String content;
  final int size;
  final List<File> files;
}
