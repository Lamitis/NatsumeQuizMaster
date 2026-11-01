import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/export_storage.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_registry.dart';

/// 本地安装（v1.36）：用户在浏览器里手动下好 zip 之后走的那条路。
///
/// 这条路**没有登记表把关**，所以服务层必须自己兜住三件事：
/// ① 清单 id 能当目录名（`../` 一律拒绝）；② 覆盖安装保留用户的启停状态；
/// ③ 至少把包的本机 sha256 记进清单，日后能对上「装的到底是哪个包」。
List<int> _zip(Map<String, String> files) {
  final encoder = ZipEncoder();
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return encoder.encode(archive)!;
}

Map<String, dynamic> _manifest({String id = 'weekly-stats', String version = '1.0.0'}) => {
      'id': id,
      'name': '每周统计',
      'version': version,
      'author': 'tester',
      'description': '一句话说明',
      'capabilities': ['stats.weekly'],
    };

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('natsume_plugin_local_');
    ExportStorage.overrideDirForTest = '${tmp.path}${Platform.pathSeparator}导出';
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath =
        '${tmp.path}${Platform.pathSeparator}natsume.db';
  });

  tearDown(() async {
    ExportStorage.overrideDirForTest = null;
    DatabaseService.overrideDbPath = null;
    try {
      await DatabaseService.instance.close();
    } catch (_) {}
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String writeZip(String fileName, Map<String, dynamic> manifest) {
    final path = '${tmp.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsBytesSync(_zip({
      'plugin.json': jsonEncode(manifest),
      'prompt.md': '# 每周统计',
    }));
    return path;
  }

  test('inspectZip 只读清单，不往插件目录里落任何东西', () async {
    final zip = writeZip('inspect.zip', _manifest());

    final manifest = await PluginRegistryService.instance.inspectZip(zip);

    expect(manifest.id, 'weekly-stats');
    expect(manifest.version, '1.0.0');
    expect(manifest.capabilities, contains('stats.weekly'));
    final pluginsDir = Directory(
        '${tmp.path}${Platform.pathSeparator}导出${Platform.pathSeparator}plugins');
    expect(pluginsDir.existsSync(), isFalse,
        reason: '只读清单不能顺手装进去');
  });

  test('本地安装：解包到 plugins/<id>、入库并记下本机 sha256', () async {
    final zip = writeZip('weekly.zip', _manifest());

    final result =
        await PluginRegistryService.instance.installFromZip(zip, sourceLabel: 'manual-test');

    expect(result.updated, isFalse);
    expect(result.sourcePath, zip);
    expect(result.sha256Hex, PluginRegistryService.sha256Hex(
        File(zip).readAsBytesSync()));
    expect(result.installedDir.endsWith('weekly-stats'), isTrue);

    final installed = Directory(result.installedDir);
    expect(installed.existsSync(), isTrue);
    expect(File('${installed.path}${Platform.pathSeparator}plugin.json').existsSync(),
        isTrue);
    expect(File('${installed.path}${Platform.pathSeparator}prompt.md').existsSync(),
        isTrue);

    final row = await DatabaseService.instance.getPlugin('weekly-stats');
    expect(row, isNotNull);
    expect(row!.name, '每周统计');
    expect(row.version, '1.0.0');
    expect(row.enabled, isTrue);
    final manifest = jsonDecode(row.manifest) as Map<String, dynamic>;
    final local = manifest['local'] as Map<String, dynamic>;
    expect(local['sha256'], result.sha256Hex);
    expect(local['source'], 'manual-test');
    expect(local['file'], 'weekly.zip');
  });

  test('覆盖安装：版本以包内清单为准，启停状态保留用户的选择', () async {
    final first = writeZip('v1.zip', _manifest());
    await PluginRegistryService.instance.installFromZip(first);
    // 用户手动关掉这个插件
    await DatabaseService.instance.setPluginEnabled('weekly-stats', false);

    final second = writeZip('v2.zip', _manifest(version: '1.1.0'));
    final result = await PluginRegistryService.instance.installFromZip(second);

    expect(result.updated, isTrue);
    final row = await DatabaseService.instance.getPlugin('weekly-stats');
    expect(row!.version, '1.1.0');
    expect(row.enabled, isFalse, reason: '升级不能把用户关掉的插件偷偷打开');
    expect(await DatabaseService.instance.getAllPlugins(), hasLength(1));
  });

  test('id 不能当目录名时拒绝安装（zip-slip 防线）', () async {
    final zip = writeZip('evil.zip', _manifest(id: '../evil'));

    await expectLater(
      PluginRegistryService.instance.installFromZip(zip),
      throwsA(isA<PluginRegistryException>().having(
          (e) => e.message, 'message', contains('目录名'))),
    );
    // 拒绝之后不能留下任何一条插件记录
    expect(await DatabaseService.instance.getAllPlugins(), isEmpty);
  });

  test('包不存在 / 不是 zip：给人话错误，而不是抛底层异常', () async {
    await expectLater(
      PluginRegistryService.instance
          .installFromZip('${tmp.path}${Platform.pathSeparator}never.zip'),
      throwsA(isA<PluginRegistryException>()),
    );

    final broken = '${tmp.path}${Platform.pathSeparator}broken.zip';
    File(broken).writeAsBytesSync([1, 2, 3, 4]);
    await expectLater(
      PluginRegistryService.instance.inspectZip(broken),
      throwsA(isA<PluginRegistryException>()),
    );
  });
}
