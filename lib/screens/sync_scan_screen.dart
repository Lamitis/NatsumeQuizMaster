import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/sync/sync_pair_payload.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';

/// 扫码配对页：扫对方NatsumeQuizMaster的配对二维码即可连上。
///
/// 用户要求：「另一台设备只要通过NatsumeQuizMaster扫码就可以连上」。
/// 返回 [SyncPairPayload]（取消则返回 null）。
class SyncScanScreen extends StatefulWidget {
  const SyncScanScreen({super.key});

  @override
  State<SyncScanScreen> createState() => _SyncScanScreenState();
}

class _SyncScanScreenState extends State<SyncScanScreen> {
  /// 只有手机/平板才有摄像头（2026-10-30 真机反馈：Windows 端不该出现扫码）。
  /// 桌面端连控制器都不创建——mobile_scanner 在 Windows 上没有实现，
  /// 构造或销毁都可能抛 MissingPluginException。
  static bool get _canScan => Platform.isAndroid || Platform.isIOS;

  final MobileScannerController? _controller = _canScan
      ? MobileScannerController(
          // 只认二维码，避免把条形码也当配对码
          formats: const [BarcodeFormat.qrCode],
          detectionSpeed: DetectionSpeed.noDuplicates,
        )
      : null;

  /// 命中一次就停：连续回调会让 Navigator.pop 触发多次
  bool _handled = false;
  String? _hint;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final payload = SyncPairPayload.decode(raw);
      if (payload == null) {
        // 扫到别的二维码：给出可理解的提示，而不是静默无反应
        if (mounted) {
          setState(() => _hint = '这不是NatsumeQuizMaster的配对二维码');
        }
        return;
      }
      _handled = true;
      Navigator.pop(context, payload);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    // 桌面端没有摄像头：给出说明 + 返回按钮，而不是黑屏或插件异常
    if (!_canScan) return _noCamera(ac);
    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(title: const Text('扫码配对')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller!,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) => Center(
              child: Padding(
                padding: const EdgeInsets.all(NatsumeSpace.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.no_photography_outlined,
                        size: 40, color: ac.textTertiary),
                    const SizedBox(height: NatsumeSpace.sm),
                    Text('无法使用相机：$error',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: NatsumeType.body, color: ac.textSecondary)),
                    const SizedBox(height: NatsumeSpace.xs),
                    Text('可以在设置页手动输入对方的识别码',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: NatsumeType.caption, color: ac.textTertiary)),
                  ],
                ),
              ),
            ),
          ),
          // 取景框
          Center(
            child: Container(
              width: 230,
              height: 230,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.all(NatsumeSpace.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('对准对方「数据库/识别码」里的配对二维码',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                  if (_hint != null) ...[
                    const SizedBox(height: 6),
                    Text(_hint!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.orangeAccent, fontSize: 13)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 桌面端兜底页：说明为什么不能扫、以及该怎么做。
  ///
  /// 电脑没有摄像头，硬进这个页面只会看到黑框和 `MissingPluginException`，
  /// 所以直接把「该怎么做」讲清楚：用手机扫电脑，或回设置页手输识别码。
  Widget _noCamera(AppThemeColors ac) => Scaffold(
        backgroundColor: ac.background,
        appBar: AppBar(title: const Text('扫码配对')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(NatsumeSpace.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.desktop_windows_outlined,
                    size: 44, color: ac.textTertiary),
                const SizedBox(height: NatsumeSpace.md),
                Text('电脑端没有摄像头，无法扫码',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: NatsumeType.h3, color: ac.textPrimary)),
                const SizedBox(height: NatsumeSpace.sm),
                Text(
                  '请用手机扫描电脑上显示的配对二维码；\n'
                  '或回到设置页，把手机上的本机识别码填进「对端识别码」输入框。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: NatsumeType.body,
                      color: ac.textSecondary,
                      height: 1.5),
                ),
                const SizedBox(height: NatsumeSpace.lg),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回设置'),
                ),
              ],
            ),
          ),
        ),
      );
}
