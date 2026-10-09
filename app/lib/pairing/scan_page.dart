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
                error: error.errorCode.name,
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
