import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/utils/app_constants.dart';

/// 版本号单一来源闸门（v1.35.5 起拆成「主版本 + 构建号」两段）。
///
/// **为什么需要这个测试**：v1.28.0 曾发生「APK 的 versionName 误标为 1.27.0」
/// 的事故——根因是版本号散落在多处（pubspec、kAppVersion、README、推广页、
/// installer 脚本），改一处漏一处。现在约定 `pubspec.yaml` 是唯一来源，
/// 构建时由 `--dart-define=APP_VERSION` / `APP_BUILD` 注入到
/// [kAppVersion] / [kAppBuildNumber]；两者的 defaultValue（本地 debug 用）
/// 必须分别与 pubspec 的「版本名」「构建号」对齐。
///
/// v1.35.5 起界面只展示主版本（`v1.35.5`），构建号（`33`）降级为「关于」里的
/// 小字——两个常量因此必须**分开**校验，避免有人图省事把构建号又塞回
/// [kAppVersion]。
void main() {
  group('版本号单一来源（pubspec ↔ kAppVersion / kAppBuildNumber）', () {
    late String pubspecVersion;
    late String versionName;
    late String buildNumber;

    setUpAll(() {
      final f = File('pubspec.yaml');
      expect(f.existsSync(), isTrue,
          reason: '测试需在包根目录运行（找不到 pubspec.yaml）');
      final line = f.readAsLinesSync().firstWhere(
          (l) => l.startsWith('version:'),
          orElse: () => '');
      expect(line, isNotEmpty, reason: 'pubspec.yaml 缺少 version: 字段');
      pubspecVersion = line.split(':').last.trim();
      final parts = pubspecVersion.split('+');
      versionName = parts.first.trim();
      buildNumber = parts.length > 1 ? parts[1].trim() : '';
    });

    test('pubspec 版本格式合法（<版本名>+<构建号>）', () {
      expect(pubspecVersion, matches(RegExp(r'^\d+\.\d+\.\d+\+\d+$')),
          reason: '当前值「$pubspecVersion」不符合 versionName+versionCode 格式，'
              '例如 1.35.5+33');
    });

    test('kAppVersion 默认值 = v + pubspec 的主版本（不含构建号）', () {
      // pubspec: 1.35.5+33  →  kAppVersion: v1.35.5
      expect(kAppVersion, 'v$versionName',
          reason: 'kAppVersion（$kAppVersion）与 pubspec.yaml（$pubspecVersion）的主版本不一致。\n'
              '修法：把 pubspec.yaml 的 version 改成新版本后，同步更新 '
              'lib/utils/app_constants.dart 里 kAppVersion 的 defaultValue。\n'
              '（发布/CI 构建会通过 --dart-define=APP_VERSION 覆盖它，'
              '这里校验的是本地 debug 的默认值。）');
      expect(kAppVersion.contains('+'), isFalse,
          reason: 'kAppVersion 只装主版本，构建号归 kAppBuildNumber，别拼回去');
      expect(kAppVersion.split('.').length, 3,
          reason: '主版本必须是三段（vX.Y.Z）；四段式 v1.35.4.32 已不再展示');
    });

    test('kAppBuildNumber 默认值 = pubspec 的构建号', () {
      expect(buildNumber, isNotEmpty, reason: 'pubspec 缺少 +<构建号>');
      expect(kAppBuildNumber, buildNumber,
          reason: 'kAppBuildNumber（$kAppBuildNumber）与 pubspec.yaml 的构建号'
              '（$buildNumber）不一致。\n'
              '修法：同步更新 lib/utils/app_constants.dart 里 kAppBuildNumber 的 '
              'defaultValue（CI 会用 --dart-define=APP_BUILD 覆盖它）。');
      expect(kAppBuildNumber, matches(RegExp(r'^\d+$')),
          reason: '构建号应是纯数字（对应 Android versionCode）');
    });

    test('kAppVersion 带 v 前缀，与关于页/页脚展示格式一致', () {
      expect(kAppVersion.startsWith('v'), isTrue,
          reason: '关于页与页脚直接拼接 kAppVersion 展示，需自带 v 前缀');
    });
  });
}
