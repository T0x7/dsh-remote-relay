import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/generated/app_localizations.dart';
import '../ui/theme.dart';

/// 屏 B — camera scan (mobile_scanner). Returns the first decodable payload
/// (a signed pairing URL) or null when the user backs out. Camera errors
/// (permission denied / no camera) surface inline instead of crashing.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          leading: const CloseButton(color: Colors.white),
          title: Text(l10n.scanTitle,
              style: const TextStyle(fontSize: 16, color: Colors.white)),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error, child) => _ScanError(
                // D-115：`genericError` 本身毫无诊断价值——mobile_scanner 把 start()
                // 抛的**任何** PlatformException 都硬编码映射成它
                // （mobile_scanner_method_channel.dart:193-201，不是 firstWhere
                // 兜底，是无条件写死）。真因（Android 侧的 "Error occurred when
                // setting up camera!" / "No camera found..." 等）保存在
                // errorDetails 里，不打出来就永远只剩一句没法查的 genericError。
                error: [
                  error.errorCode.name,
                  if (error.errorDetails?.message != null)
                    error.errorDetails!.message,
                ].join(' · '),
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.accent, width: 3),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 60,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.m, vertical: AppTheme.s),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.scanHint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Positioned(
                top: 20,
                left: 20,
                right: 20,
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.danger)),
              ),
            // D-115：上面这个 `_error` 是**死代码**——字段声明后再无任何赋值点，
            // 所以它永远不会渲染。留着它会让人以为这一屏已经有过错误上报，
            // 反而掩盖了「真因只走 errorBuilder」这件事，故在此标注（删除留待
            // 单独的清理批次，避免和 D-115 的 release 修复混在一起）。
          ],
        ),
      );
  }
}

class _ScanError extends StatelessWidget {
  const _ScanError({required this.error, required this.onClose});

  final String error;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Container(
        color: AppTheme.bg,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.no_photography_outlined,
                    size: 48, color: AppTheme.inkDim),
                const SizedBox(height: AppTheme.m),
                Text(l10n.cameraUnavailable,
                    style:
                        const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: AppTheme.s),
                // 相机权限/硬件错误码是英文枚举名，直接内插即可，不必翻译。
                Text(l10n.cameraError(error),
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(fontSize: 12, color: AppTheme.inkDim)),
                const SizedBox(height: AppTheme.xl),
                OutlinedButton(
                    onPressed: onClose, child: Text(l10n.actionBack)),
              ],
            ),
          ),
        ),
      );
  }
}
