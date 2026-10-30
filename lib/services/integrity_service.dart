import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 防伪与签名校验（NatsumeQuizMaster 自研，替代早期实现）。
///
/// 与早期实现的关键区别：**不硬性阻断启动**。早期实现在签名不匹配时直接显示
/// 红页退出，换包名/换证书重新打包就会「误伤闪退」；当前实现只把结果记录成
/// [IntegrityStatus]，供业务层「静默限制部分高级功能」，不挡用户进入。
enum IntegrityStatus { genuine, tampered, unknown }

class IntegrityService {
  IntegrityService._();

  static const MethodChannel _channel =
      MethodChannel('com.natsume.quiz/integrity');

  /// 桌面端指纹盐（签名校验用）
  static const String _hikamiSalt = 'hikami';

  /// 我的专属签名 SHA-256（hex，64 位）。
  ///
  /// 打包发布前用下面命令取得并替换（全零 = 未配置，此时不会误锁）：
  ///   keytool -printcert -jarfile <your-app.apk>  # 看「SHA256:」那一串
  /// 或从运行日志里 MainActivity.getSignatureSha256 的返回值复制。
  static const String mySignatureSha256 =
      '0000000000000000000000000000000000000000000000000000000000000000';

  static IntegrityStatus status = IntegrityStatus.unknown;

  /// 最近一次检测到的本机签名（诊断用；桌面端为可执行文件指纹）。
  static String? detectedSignature;

  /// 是否已配置专属签名（全零/空 = 未配置）。
  static bool get isConfigured =>
      mySignatureSha256.isNotEmpty &&
      mySignatureSha256.replaceAll('0', '').isNotEmpty;

  /// 检测到二次打包 → 限制高级功能（AI 出题、世界导出等）。
  static bool get advancedFeaturesLocked => status == IntegrityStatus.tampered;

  /// 纯函数：由「检测到的签名 + 期望签名」判定完整性。
  /// 抽出来是为了可单测（无需 mock MethodChannel）。
  static IntegrityStatus classify(String? detected, String expected) {
    final sha = detected?.trim().toLowerCase();
    if (sha == null || sha.isEmpty) return IntegrityStatus.unknown;
    final exp = expected.trim().toLowerCase();
    final configured = exp.isNotEmpty && exp.replaceAll('0', '').isNotEmpty;
    if (!configured) return IntegrityStatus.unknown; // 未配置 → 不误锁
    if (sha == exp) return IntegrityStatus.genuine;
    return IntegrityStatus.tampered;
  }

  static Future<IntegrityStatus> verify() async {
    try {
      if (kDebugMode) {
        // 本地开发（debug 签名）放行，避免误锁
        status = IntegrityStatus.genuine;
        return status;
      }
      if (Platform.isAndroid) {
        final sha = await _channel.invokeMethod<String>('getSignatureSha256');
        detectedSignature = sha;
        status = classify(sha, mySignatureSha256);
      } else if (Platform.isWindows ||
          Platform.isLinux ||
          Platform.isMacOS) {
        // 桌面端：可执行文件指纹（文件完整性/环境自检）。
        // 未配置期望指纹时不硬锁，仅记录指纹供诊断。
        status = IntegrityStatus.unknown;
        try {
          detectedSignature = _sha256Hex([
            ...File(Platform.resolvedExecutable).readAsBytesSync(),
            ..._hikamiSalt.codeUnits,
          ]);
        } catch (_) {}
      }
    } catch (_) {
      status = IntegrityStatus.unknown;
    }
    return status;
  }

  static String _sha256Hex(List<int> bytes) =>
      sha256.convert(bytes).toString();
}
