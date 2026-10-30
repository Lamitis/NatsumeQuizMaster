import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_loader.dart';

/// 插件加载器（v13 · world-overview）。
///
/// 插件是声明式包：清单 + 提示词 + 资产。这里验证清单解析、资产读取，
/// 以及路径穿越防护（恶意条目必须被拒绝，不能写出安装目录）。
List<int> _zip(Map<String, String> files) {
  final encoder = ZipEncoder();
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return encoder.encode(archive)!;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('natsume_plugin_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('从 zip 加载插件：清单 + 提示词 + 资产文本', () async {
    final zipPath = '${tmp.path}/p.zip';
    File(zipPath).writeAsBytesSync(_zip({
      'plugin.json': jsonEncode({
        'id': 'com.example.kb',
        'name': '知识库助教',
        'version': '1.0.0',
        'author': 'tester',
        'description': '测试插件',
        'capabilities': ['kb.search', 'question.generate'],
      }),
      'prompt.md': '# 你是病理学助教',
      'kb/note.md': '这是一段内置资料',
      'sample_bank.json': '{"format":"natsume-quiz-questions","questions":[]}',
    }));

    final loaded =
        await PluginLoader.loadFromZip(zipPath, '${tmp.path}/installed');
    expect(loaded.manifest.id, 'com.example.kb');
    expect(loaded.manifest.name, '知识库助教');
    expect(loaded.manifest.capabilities, contains('kb.search'));
    expect(loaded.prompt, contains('病理学助教'));
    expect(loaded.assets['kb/note.md'], contains('内置资料'));
    expect(loaded.assets['sample_bank.json'], contains('questions'));
  });

  test('缺少 plugin.json 时抛异常', () async {
    final zipPath = '${tmp.path}/bad.zip';
    File(zipPath).writeAsBytesSync(_zip({'readme.md': 'no manifest'}));
    expect(
      () => PluginLoader.loadFromZip(zipPath, '${tmp.path}/x'),
      throwsA(isA<Exception>()),
    );
  });

  test('路径穿越条目被拒绝（不写出安装目录）', () async {
    final zipPath = '${tmp.path}/evil.zip';
    File(zipPath).writeAsBytesSync(_zip({
      'plugin.json':
          jsonEncode({'id': 'x', 'name': 'x', 'version': '1', 'capabilities': []}),
      '../evil.txt': 'should not be written',
    }));

    final loaded =
        await PluginLoader.loadFromZip(zipPath, '${tmp.path}/installed');
    expect(loaded.assets.containsKey('../evil.txt'), isFalse);
    expect(File('${tmp.path}/evil.txt').existsSync(), isFalse);
  });
}
