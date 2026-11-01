import 'package:flutter/foundation.dart';

/// 插件平台白名单（v1.39）。
///
/// 清单里的 `platforms` 只允许这四个值；缺省 / 空数组表示「所有平台」。
/// 宿主在渲染动态 UI 之前按当前平台过滤，不匹配就静默跳过（不报错、不提示）。
abstract final class PluginPlatforms {
  static const String windows = 'windows';
  static const String android = 'android';
  static const String macos = 'macos';
  static const String linux = 'linux';

  static const Set<String> all = {windows, android, macos, linux};

  /// 当前运行平台；白名单之外的系统返回 `unknown`，声明了 `platforms` 的
  /// 插件在未知平台上按「不支持」处理（保守）。
  static String get current => switch (defaultTargetPlatform) {
        TargetPlatform.windows => windows,
        TargetPlatform.android => android,
        TargetPlatform.macOS => macos,
        TargetPlatform.linux => linux,
        _ => 'unknown',
      };

  /// 解析清单里的 `platforms`：去空白、小写、去重、只留白名单值。
  ///
  /// 非法值不会让整条插件失效——只意味着那个平台不会被声明；空结果 = 所有平台。
  static List<String> normalize(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final item in raw) {
      final value = item.toString().trim().toLowerCase();
      if (!all.contains(value) || out.contains(value)) continue;
      out.add(value);
    }
    return List<String>.unmodifiable(out);
  }

  /// 声明为空 = 所有平台；否则必须显式包含当前平台。
  static bool supports(Iterable<String> declared, {String? platform}) {
    if (declared.isEmpty) return true;
    final current = platform ?? PluginPlatforms.current;
    return declared.contains(current);
  }
}
