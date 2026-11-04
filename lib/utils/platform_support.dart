import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// 平台判定（v1.41）。
///
/// 需求要求用 `Platform.isAndroid / Platform.isIOS` 判断移动端；这里把它收成
/// 一处，避免 settings / import / service 各写一份（漏一处就会出现「设置里
/// 藏了、导入时仍然上传」的不一致）。
///
/// [debugMobileOverride] 只给测试用：`flutter test` 跑在 Windows 桌面 VM 上，
/// 没有真机就无法覆盖「移动端隐藏 MinerU」这类分支；测试里设成 true/false
/// 即可模拟两端，生产代码永远读 [Platform]。
bool get isMobilePlatform {
  final override = debugMobileOverride;
  if (override != null) return override;
  if (kIsWeb) return false;
  // 注意：dart:io 的 Platform 在 web 上不可用；本工程没有 web 目标，
  // kIsWeb 只是防御性判断（将来加 web 时这里需改成 defaultTargetPlatform）。
  return Platform.isAndroid || Platform.isIOS;
}

/// 桌面端（Windows / macOS / Linux）。MinerU 只在 Windows 桌面端生效。
bool get isDesktopPlatform => !kIsWeb && !isMobilePlatform;

/// 当前是否 Windows（MinerU 版面识别唯一支持的平台）。
///
/// 需求指定用 `Platform.isWindows` 判定：Android/iOS 必须隐藏 MinerU；
/// 测试可用 [debugWindowsOverride] 模拟 Windows / 非 Windows 宿主，
/// [debugMobileOverride] 为 true 时也按非 Windows 处理（移动端看不到 MinerU）。
bool get isWindowsPlatform {
  final override = debugWindowsOverride;
  if (override != null) return override;
  if (kIsWeb) return false;
  if (debugMobileOverride == true) return false;
  return Platform.isWindows;
}

/// 测试注入点：null = 按真实平台判断。
@visibleForTesting
bool? debugMobileOverride;

/// 测试注入点：模拟 Windows / 非 Windows 宿主（CI 在 Ubuntu 上跑，
/// 专门用来验证「非 Windows 不显示 MinerU」这条契约）。
@visibleForTesting
bool? debugWindowsOverride;
