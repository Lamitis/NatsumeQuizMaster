import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/plugin.dart';
import 'package:natsume_quiz_master/screens/plugin_detail_screen.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/export_storage.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_registry.dart';
import 'package:natsume_quiz_master/services/plugins/plugin_stats_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';
import 'package:natsume_quiz_master/widgets/kit/natsume_kit.dart';
import 'package:natsume_quiz_master/widgets/plugin_install_flow.dart';

/// 插件详情页（v1.36）的界面契约。
///
/// 这一页要回答「装之前想知道的事」，所以逐条验：
/// ① 名字 / 版本 / 作者 / 分类 / 快捷链接 / 信息表都在；
/// ② 统计拿不到时显示「—」，不编数字，也不挡安装；
/// ③ 讨论区参数没配 / 没有 WebView 时给外链出口，不白屏；
/// ④ 安装入口与市场卡片**同一套流程**（来源说明 → 清单确认 → 失败兜底）。
final String _sha = List.filled(64, 'a').join();

RegistryPlugin _entry({
  String id = 'weekly-stats',
  String name = '每周统计',
  String version = '1.0.0',
  String? category = '题库工具',
  String? repoUrl,
  String? changelogUrl,
}) =>
    RegistryPlugin.tryParse({
      'id': id,
      'name': name,
      'author': 'someone',
      'version': version,
      'description': '$name 的说明',
      'download_url':
          'https://github.com/someone/$id/releases/download/v$version/$id.zip',
      'sha256': _sha,
      if (category != null) 'category': category,
      if (repoUrl != null) 'repo_url': repoUrl,
      if (changelogUrl != null) 'changelog_url': changelogUrl,
    })!;

/// 一份「有数字」的统计：1234 次下载 / 812 KB / 两个版本
PluginStats _stats() => PluginStats(
      downloadCount: 1234,
      exact: true,
      assetSizeBytes: 831488,
      latestReleaseAt: DateTime(2026, 10, 20),
      releases: [
        PluginRelease(
          tag: 'v1.0.0',
          publishedAt: DateTime(2026, 10, 20),
          downloadCount: 1234,
        ),
        PluginRelease(
          tag: 'v0.9.0',
          publishedAt: DateTime(2026, 9, 1),
          downloadCount: 12,
        ),
      ],
    );

Future<PluginStatsSnapshot> _noStats(
  List<RegistryPlugin> entries, {
  bool forceRefresh = false,
}) async =>
    const PluginStatsSnapshot();

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('natsume_detail_ui_');
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

  /// 有上限的等待：sqflite 走独立 isolate，固定帧数赌不起
  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var r = 0; r < rounds; r++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> waitFor(WidgetTester tester, Finder finder,
      {int rounds = 60}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
      if (finder.evaluate().isNotEmpty) return;
    }
  }

  void setSurface(WidgetTester tester, {Size size = const Size(420, 1600)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget host({
    RegistryPlugin? entry,
    PluginInfo? installed,
    PluginStats? stats,
    PluginStatsBatchLoader? statsLoader,
    RepoMetaLoader? metaLoader,
    PluginInstallCall? installer,
    Future<void> Function(String url)? onOpenLink,
    Future<void> Function()? onInstallFromFile,
  }) =>
      MaterialApp(
        theme: ThemeService().themeData,
        home: PluginDetailScreen(
          entry: entry ?? _entry(),
          installed: installed,
          installer: installer,
          stats: stats,
          statsLoader: statsLoader ?? _noStats,
          // 默认不联网：仓库元信息一律注入「没有」
          repoMetaLoader: metaLoader ??
              (ref, {bool forceRefresh = false}) async => null,
          onOpenLink: onOpenLink ?? (url) async {},
          onInstallFromFile: onInstallFromFile,
          // 测试环境没有 WebView 实现，直接走外链兜底
          webViewAvailable: false,
        ),
      );

  testWidgets('头部 / 快捷链接 / 信息表把装之前要知道的都摆出来', (tester) async {
    setSurface(tester);
    await tester.pumpWidget(host(
      entry: _entry(
        repoUrl: 'https://github.com/someone/weekly-stats',
        changelogUrl: 'https://github.com/someone/weekly-stats/releases',
      ),
      stats: _stats(),
    ));
    await settle(tester);

    expect(find.text('插件详情'), findsOneWidget);
    expect(find.text('每周统计'), findsOneWidget);
    expect(find.text('v1.0.0'), findsOneWidget);
    expect(find.text('by someone'), findsOneWidget);

    // 快捷链接：仓库 / 更新日志 / 问题反馈都走浏览器
    expect(find.widgetWithText(NatsumeButton, '源码仓库'), findsOneWidget);
    expect(find.widgetWithText(NatsumeButton, '更新日志'), findsOneWidget);
    expect(find.widgetWithText(NatsumeButton, '问题反馈'), findsOneWidget);

    // 信息表：作者 / 版本 / 分类 / 大小 / 更新时间 / 下载量
    expect(find.text('插件信息'), findsOneWidget);
    expect(find.text('812 KB'), findsOneWidget);
    expect(find.text('2026-10-20'), findsOneWidget);
    expect(find.text('1,234 次下载'), findsWidgets);

    // 版本历史只从 GitHub 统计里来
    expect(find.text('版本历史'), findsOneWidget);
    await tester.tap(find.text('版本历史'));
    await settle(tester, rounds: 2);
    expect(find.text('v0.9.0'), findsOneWidget);
  });

  testWidgets('统计拿不到时信息表显示「—」，不编数字也不挡安装', (tester) async {
    setSurface(tester);
    await tester.pumpWidget(host(entry: _entry()));
    await settle(tester);

    expect(find.text('—'), findsWidgets, reason: '大小/更新时间/下载量都该是「—」');
    expect(find.text('未标注'), findsOneWidget, reason: 'License 拿不到就写未标注');
    expect(find.widgetWithText(NatsumeButton, '安装插件'), findsOneWidget,
        reason: '没有统计不影响安装');
    expect(find.text('版本历史'), findsNothing, reason: '没有发布记录就别摆下拉');
  });

  testWidgets('讨论区参数没配 / 没有 WebView：给外链出口，不白屏', (tester) async {
    setSurface(tester);
    String? opened;
    await tester.pumpWidget(host(
      onOpenLink: (url) async => opened = url,
    ));
    await settle(tester);

    expect(find.text('讨论区'), findsOneWidget);
    expect(find.text('评论在这里看不了'), findsOneWidget);
    await tester.tap(find.widgetWithText(NatsumeButton, '前往 GitHub 讨论区'));
    await settle(tester, rounds: 2);
    expect(opened, 'https://github.com/someone/weekly-stats/discussions');
  });

  testWidgets('安装走与市场卡片同一套流程：来源说明 → 清单确认 → 失败兜底',
      (tester) async {
    setSurface(tester);
    var called = 0;
    const url =
        'https://github.com/someone/weekly-stats/releases/download/v1.0.0/weekly-stats.zip';
    await tester.pumpWidget(host(
      installer: (entry) async {
        called++;
        throw const PluginRegistryException('全部下载源都失败', downloadUrl: url);
      },
    ));
    await settle(tester);

    await tester.tap(find.widgetWithText(NatsumeButton, '安装插件'));
    await waitFor(tester, find.text('插件来源说明'));
    expect(find.text('插件来源说明'), findsOneWidget);
    await tester.tap(find.text('我已经了解'));

    await waitFor(tester, find.text('安装插件「每周统计」？'));
    expect(called, 0, reason: '确认前不能开始下载');
    await tester.tap(find.widgetWithText(TextButton, '安装'));

    await waitFor(tester, find.text('安装没有完成'));
    expect(called, 1);
    expect(find.text('全部下载源都失败'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is SelectableText && w.data == url),
      findsOneWidget,
      reason: '全部下载源失败时要把原始地址交出来',
    );
    // 详情页没有选文件入口时不摆「从本地安装」死按钮
    expect(find.widgetWithText(TextButton, '从本地安装'), findsNothing);
  });

  testWidgets('本机已装旧版本：按钮变「更新到 vX」，License 取清单里写的',
      (tester) async {
    setSurface(tester);
    await tester.pumpWidget(host(
      installed: PluginInfo(
        id: 'weekly-stats',
        name: '每周统计',
        version: '0.9.0',
        installedAt: '2026-09-01T00:00:00Z',
        manifest: '{"license":"MIT"}',
      ),
    ));
    await settle(tester);

    expect(find.widgetWithText(NatsumeButton, '更新到 v1.0.0'), findsOneWidget);
    expect(find.text('登记 v1.0.0 · 本机 v0.9.0'), findsOneWidget);
    expect(find.text('MIT'), findsOneWidget);
  });
}
