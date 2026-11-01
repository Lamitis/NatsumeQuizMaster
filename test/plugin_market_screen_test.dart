import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/screens/plugin_market_screen.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/export_storage.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_registry.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';
import 'package:natsume_quiz_master/widgets/kit/natsume_kit.dart';

/// 插件市场页（v1.36）的界面契约。
///
/// 三项都要靠 UI 兜住，所以逐条验：
/// ① 拉表失败**不清空**已有列表，只在顶部提示「本次没拉到」；
/// ② 安装前必须有来源说明 + 清单确认（不让「点一下就连网写盘」）；
/// ③ 全部镜像失败时把**原始**下载地址交给用户（复制 / 浏览器下载 → 本地安装），
///    而不是只弹一句「安装失败」。
///
/// 测试一律注入 fetcher / installer：页面本身不该真的联网。
final String _sha = List.filled(64, 'a').join();

RegistryPlugin _entry({
  String id = 'weekly-stats',
  String name = '每周统计',
  String version = '1.0.0',
  String? category = '题库工具',
  List<String> tags = const [],
  List<String> permissions = const [],
  String? repoUrl,
}) {
  final parsed = RegistryPlugin.tryParse({
    'id': id,
    'name': name,
    'author': 'someone',
    'version': version,
    'description': '$name 的说明',
    'download_url':
        'https://github.com/someone/$id/releases/download/v$version/$id.zip',
    'sha256': _sha,
    if (category != null) 'category': category,
    if (tags.isNotEmpty) 'tags': tags,
    if (permissions.isNotEmpty) 'permissions': permissions,
    if (repoUrl != null) 'repo_url': repoUrl,
  });
  return parsed!;
}

RegistrySnapshot _snapshot(List<RegistryPlugin> plugins) => RegistrySnapshot(
      schema: 1,
      generatedAt: '2026-10-31T00:00:00Z',
      disclaimer: '登记不等于审核，装不装由你决定。',
      plugins: plugins,
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('natsume_market_ui_');
    ExportStorage.overrideDirForTest = tmp.path;
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = '${tmp.path}/natsume.db';
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

  /// 有上限的等待：sqflite 写入要过独立 isolate，固定帧数不等它。
  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var r = 0; r < rounds; r++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 等到某段 UI 真的出现。
  ///
  /// 两个坑叠在一起：
  /// · sqflite 走独立 isolate，**真实**异步要 `runAsync` 才跑得完（`pump` 只推进
  ///   帧与微任务）；首次开库 / 写设置都在这条路上；
  /// · 别用固定帧数赌耗时，轮询到目标出现为止。
  Future<void> waitFor(WidgetTester tester, Finder finder,
      {int rounds = 60}) async {
    for (var i = 0; i < rounds; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
      if (finder.evaluate().isNotEmpty) return;
    }
  }

  Widget host({
    required RegistryFetcher fetcher,
    RegistryInstaller? installer,
  }) =>
      MaterialApp(
        theme: ThemeService().themeData,
        home: PluginMarketScreen(fetcher: fetcher, installer: installer),
      );

  void setSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('卡片展示分类 / 标签 / 声明能力 / 仓库链接', (tester) async {
    setSurface(tester);
    await tester.pumpWidget(host(
      fetcher: () async => _snapshot([
        _entry(
          tags: ['anki', '导出'],
          permissions: ['stats.weekly'],
          repoUrl: 'https://github.com/someone/weekly-stats',
        ),
      ]),
    ));
    await settle(tester);

    expect(find.text('每周统计'), findsOneWidget);
    expect(find.text('v1.0.0'), findsOneWidget);
    expect(find.text('by someone'), findsOneWidget);
    // 分类同时出现在分类条与卡片标签上
    expect(find.text('题库工具'), findsWidgets);
    expect(find.text('#anki'), findsOneWidget);
    expect(find.text('声明能力：stats.weekly'), findsOneWidget);
    expect(find.widgetWithText(NatsumeButton, '仓库'), findsOneWidget);
    expect(find.byTooltip('复制下载地址'), findsOneWidget);
    expect(find.widgetWithText(NatsumeButton, '安装'), findsOneWidget);
  });

  testWidgets('搜索筛不到时给「没有匹配的插件」，清除筛选后恢复列表',
      (tester) async {
    setSurface(tester);
    await tester.pumpWidget(host(
      fetcher: () async => _snapshot([_entry()]),
    ));
    await settle(tester);
    expect(find.text('每周统计'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'zzz');
    await settle(tester, rounds: 2);
    expect(find.text('没有匹配的插件'), findsOneWidget);
    expect(find.text('每周统计'), findsNothing, reason: '筛掉就是筛掉，不能留在下面');

    await tester.tap(find.widgetWithText(NatsumeButton, '清除筛选'));
    await settle(tester, rounds: 2);
    expect(find.text('没有匹配的插件'), findsNothing);
    expect(find.text('每周统计'), findsOneWidget);
  });

  testWidgets('状态筛选「已安装」在没装插件时为空，且不显示安装按钮',
      (tester) async {
    setSurface(tester);
    await tester.pumpWidget(host(
      fetcher: () async => _snapshot([_entry()]),
    ));
    await settle(tester);

    await tester.tap(find.widgetWithText(NatsumeChip, '已安装'));
    await settle(tester, rounds: 2);
    expect(find.text('没有匹配的插件'), findsOneWidget);
    expect(find.widgetWithText(NatsumeButton, '安装'), findsNothing,
        reason: '「已安装」筛选下不能还留着安装入口');
  });

  testWidgets('拉表失败不清空已有列表，只加一条顶栏提示', (tester) async {
    setSurface(tester);
    var calls = 0;
    await tester.pumpWidget(host(
      fetcher: () async {
        calls++;
        if (calls == 1) return _snapshot([_entry()]);
        throw const PluginRegistryException('网络不通');
      },
    ));
    await settle(tester);
    expect(find.text('每周统计'), findsOneWidget);

    await tester.tap(find.byTooltip('刷新插件表'));
    await settle(tester);

    expect(find.text('本次没拉到'), findsOneWidget);
    expect(find.textContaining('网络不通'), findsOneWidget);
    expect(find.textContaining('下面是上次的结果'), findsOneWidget);
    expect(find.text('每周统计'), findsOneWidget,
        reason: '刷新失败必须保留上一次的列表');
  });

  testWidgets('安装失败：原始下载地址可见，并给出「从本地安装」出口',
      (tester) async {
    setSurface(tester);
    const url =
        'https://github.com/someone/weekly-stats/releases/download/v1.0.0/weekly-stats.zip';
    String? installedId;
    await tester.pumpWidget(host(
      fetcher: () async => _snapshot([_entry()]),
      installer: (entry) async {
        installedId = entry.id;
        throw const PluginRegistryException('全部下载源都失败',
            downloadUrl: url);
      },
    ));
    await settle(tester);

    // 第一次安装：来源说明（登记 ≠ 审核）
    await tester.tap(find.widgetWithText(NatsumeButton, '安装'));
    await waitFor(tester, find.text('插件来源说明'));
    expect(find.text('插件来源说明'), findsOneWidget);
    await tester.tap(find.text('我已经了解'));
    await waitFor(tester, find.text('安装插件「每周统计」？'));

    // 然后是逐条清单确认：确认前不能开始下载
    expect(find.text('安装插件「每周统计」？'), findsOneWidget);
    expect(installedId, isNull, reason: '确认前不能开始安装');
    await tester.tap(find.widgetWithText(TextButton, '安装'));
    await waitFor(tester, find.text('安装没有完成'));
    expect(installedId, 'weekly-stats');

    // 失败兜底：人话错误 + 可复制的原始地址 + 本地安装入口
    expect(find.text('安装没有完成'), findsOneWidget);
    expect(find.text('全部下载源都失败'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is SelectableText && w.data == url),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, '复制下载地址'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '从本地安装'), findsOneWidget);
  });
}
