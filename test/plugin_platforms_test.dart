import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/plugin.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_loader.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_platforms.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_prompt_service.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_ui_extension.dart';

/// 插件 `platforms`（v1.39）：清单解析 + 动态按钮按平台过滤。
void main() {
  late Directory tmp;

  PluginInfo installed(String id) => PluginInfo(
        id: id,
        name: id,
        version: '1.0.0',
        enabled: true,
        installedAt: DateTime.now().toIso8601String(),
      );

  Map<String, dynamic> extensionJson({String label = '跨平台按钮'}) => {
        'slot': PluginSlots.quizAnalysisActions,
        'label': label,
        'icon': 'psychology',
        'action': {
          'type': PluginActionTypes.aiPrompt,
          'contexts': [PluginContextKeys.questionText],
          'prompt_template': '解析：{{QUESTION_TEXT}}',
        },
      };

  void writePlugin(
    String id, {
    required String name,
    List<String>? platforms,
    String label = '跨平台按钮',
  }) {
    final dir = Directory('${tmp.path}/$id')..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({
      'id': id,
      'name': name,
      'version': '1.0.0',
      if (platforms != null) 'platforms': platforms,
      'ui_extensions': [extensionJson(label: label)],
    }));
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('natsume_plugin_platform_');
    PluginPromptService.instance.clear();
  });

  tearDown(() {
    PluginPromptService.instance.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('normalize：小写、去空白、去重，只保留四个白名单平台', () {
    expect(
      PluginPlatforms.normalize(
          ['Windows', ' android ', 'ios', 'ANDROID', 'linux', 'web', 42]),
      ['windows', 'android', 'linux'],
    );
    expect(PluginPlatforms.normalize(null), isEmpty);
    expect(PluginPlatforms.normalize('windows'), isEmpty);
  });

  test('supports：空声明 = 所有平台，否则必须显式包含', () {
    expect(PluginPlatforms.supports(const []), isTrue);
    expect(PluginPlatforms.supports(const [], platform: 'unknown'), isTrue);
    expect(PluginPlatforms.supports(const ['android'], platform: 'android'),
        isTrue);
    expect(PluginPlatforms.supports(const ['android'], platform: 'windows'),
        isFalse);
  });

  test('PluginManifest：platforms 被解析并随 toJson 落库', () {
    final manifest = PluginManifest.fromJson({
      'id': 'com.example.sakuraba',
      'name': 'Sakuraba_Ema_Plugin',
      'version': '1.0.0',
      'platforms': ['Windows', 'ios', 'android'],
    });
    expect(manifest.platforms, ['windows', 'android']);
    expect(manifest.toJson()['platforms'], ['windows', 'android']);
  });

  test('refresh + extensionsFor：不支持当前平台的按钮静默跳过', () async {
    writePlugin('com.example.win',
        name: 'Nikaido_Hiro_Plugin', platforms: ['windows']);
    writePlugin('com.example.all', name: 'Hasumi_Leia_Plugin', label: '全平台按钮');

    await PluginPromptService.instance.refresh(
      root: tmp,
      installed: [
        installed('com.example.win'),
        installed('com.example.all'),
      ],
    );

    final onWindows = PluginPromptService.instance.extensionsFor(
      PluginSlots.quizAnalysisActions,
      platform: 'windows',
    );
    expect(onWindows.map((e) => e.label), contains('跨平台按钮'));
    expect(onWindows.map((e) => e.label), contains('全平台按钮'));

    final onAndroid = PluginPromptService.instance.extensionsFor(
      PluginSlots.quizAnalysisActions,
      platform: 'android',
    );
    expect(onAndroid.map((e) => e.label), ['全平台按钮'],
        reason: '只支持 windows 的插件在 Android 上不渲染');
  });

  test('extensionsFor：平台过滤发生在 limit 之前', () async {
    writePlugin('com.example.a',
        name: 'Saeki_Miria_Plugin', platforms: ['windows'], label: '仅Win');
    writePlugin('com.example.b', name: 'Tono_Hanna_Plugin', label: '全平台');

    await PluginPromptService.instance.refresh(
      root: tmp,
      installed: [
        installed('com.example.a'),
        installed('com.example.b'),
      ],
    );

    final result = PluginPromptService.instance.extensionsFor(
      PluginSlots.quizAnalysisActions,
      limit: 1,
      platform: 'android',
    );
    expect(result.map((e) => e.label), ['全平台'],
        reason: '被平台过滤掉的扩展不能占用 limit 名额');
  });
}
