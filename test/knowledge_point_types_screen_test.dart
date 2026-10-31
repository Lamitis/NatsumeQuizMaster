import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:natsume_quiz_master/screens/knowledge_point_types_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

/// 「知识点体系」编辑页（v1.35）的界面契约：
/// ① 默认空体系 = AI 自行判断，页面必须说清楚（不能让用户以为坏了）；
/// ② 新增 → 列表立刻出现、计数跟着变；
/// ③ 保存后落到设置里（空列表也能保存 = 恢复默认）。
///
/// v1.35.2 修 CI 红灯，两件事与 `companion_settings_screen_test.dart` 同源：
///
/// · **网络**：本页只读写本地设置，不该有任何请求。但 `AppState.init()` 会走
///   `_loadSettings() → _initAIService()`，其中 `AIService(...)` 默认
///   `client ?? http.Client()` 就是 `IOClient(HttpClient())`，于是 flutter_test
///   打出「At least one test in this suite creates an HttpClient … status code
///   400」。那句警告说的是**构造**客户端（一句请求都没发），不是真的联网；
///   这里仍然显式注入 MockClient，让「测试绝不联网」成为构造上成立的事，
///   顺便把那句噪声警告消掉。
///
/// · **时序**：保存走 `setKnowledgePointTypes → updateSettings`，是一串
///   十几次 await 的 sqflite 写（每次都要过一遍独立 isolate）。原来点完保存
///   只给固定帧数就断言、随即 `teardownTree()` 关库——本机跑得快，写早做完了；
///   慢速 runner 上写还在飞，`close()` 一关库就让写抛 "database_closed"，
///   而 `_save()` 的 Future 没人 await，异常变成未处理异步错误 → 用例直接 [E]。
///   现在点完保存等「保存成功」提示真的出现（= 整串写完成），再收尾。
void main() {
  /// 有没有人真的想联网（正常应始终为 0）。
  var aiRequests = 0;
  late http.Client aiClient;

  setUp(() async {
    aiRequests = 0;
    aiClient = MockClient((_) async {
      aiRequests++;
      // 万一哪天真有代码在这里发请求：立刻失败并留下痕迹，而不是等 CI 超时
      return http.Response('{"error":"UI 测试不联网"}', 400);
    });
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    // CI（Linux）上没有 %LOCALAPPDATA%，会退到系统临时目录；而
    // <tmp>/natsume_quiz_master 这个子目录可能从没被建过，sqflite 届时只回
    // 一句 "unable to open database file"。先建好，本地 / CI 同一套写法。
    await Directory('${dir.path}/natsume_quiz_master').create(recursive: true);
    final dbPath = '${dir.path}/natsume_quiz_master/'
        'test_kp_types_ui_${DateTime.now().microsecondsSinceEpoch}.db';
    DatabaseService.overrideDbPath = dbPath;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  tearDown(() async {
    aiClient.close();
    DatabaseService.overrideDbPath = null;
  });

  Widget host(AppState appState) => MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: appState),
          ChangeNotifierProvider<ThemeService>.value(value: ThemeService()),
        ],
        child: MaterialApp(
          theme: ThemeService().themeData,
          home: const KnowledgePointTypesScreen(),
        ),
      );

  void setSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> settleFrames(WidgetTester tester, {int rounds = 6}) async {
    for (var r = 0; r < rounds; r++) {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 等一个**异步副作用**真正落地（落库 → setState → 弹提示）。
  ///
  /// 为什么不直接用固定帧数或 `pumpAndSettle()`：
  /// - `setKnowledgePointTypes → updateSettings` 是十几次 await 的 sqflite 写，
  ///   跑在独立 isolate 上，只有 `runAsync` 给的真实时间才会推进；`settleFrames`
  ///   那点固定帧数在本机能过，在慢速 runner（CI）上不够——本用例就是这么挂的；
  /// - `pumpAndSettle()` 按 100ms 步进推进**假时钟**，会把 SnackBar 的 4s 自动
  ///   关闭一起推掉，反而让 `findsOneWidget` 失败。
  ///
  /// 所以用「真实时间轮询 + 小步假时钟」：真实异步（sqflite 的 isolate）能推进，
  /// `Future.delayed` 这类**假定时器**也能推进；每轮只走 10ms，远小于 SnackBar
  /// 的 4s 自动关闭，弹出来的提示不会被时钟推走。
  /// 超时前顺带把 `tester.takeException()` 捞出来——比只报「没等到」好查。
  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() done, {
    Duration timeout = const Duration(seconds: 20),
    String? reason,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        final err = tester.takeException();
        fail('等待超时（${timeout.inSeconds}s）：${reason ?? '目标状态未出现'}'
            '${err == null ? '' : '\n期间捕获到的异常：$err'}');
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// 点「保存知识点体系」，并等到保存成功的 SnackBar 真的出现。
  ///
  /// 提示出现 == `_save()` 里那个 `await setKnowledgePointTypes(...)` 已经返回
  /// == 十几次 sqflite 写全部落地，随后才 `teardownTree()` 关库。
  /// [expectToast] 传提示文案的核心片段：页面按是否为空给两种文案。
  Future<void> tapSaveAndWait(WidgetTester tester, String expectToast) async {
    final save = find.text('保存知识点体系');
    expect(save, findsOneWidget,
        reason: '有未保存改动时，按钮文案应仍是「保存知识点体系」'
            '（若已是「保存中…」说明上一次保存还没收尾）');
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    // 先渲染 _saving = true 那一帧（按钮变「保存中…」），再等落库
    await tester.pump();
    await waitUntil(
      tester,
      () => find.textContaining(expectToast).evaluate().isNotEmpty,
      reason: '点「保存知识点体系」后始终没出现「$expectToast」提示'
          '（落库未完成，或异步链抛异常）',
    );
    // 提示已挂上树，再走完入场动画（350ms 远小于 4s 自动关闭，不会把提示推走）
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 12));
      await settleFrames(tester);
    }
    await tester.runAsync(() => DatabaseService.instance.close());
  }

  Future<AppState> seed(WidgetTester tester) async {
    // 注入 MockClient：AppState 构造 AIService 时不再 new 一个真 HttpClient
    // （那句 "creates an HttpClient" 警告的来源），也保证这里绝不联网。
    final appState = AppState(aiClient: aiClient);
    await tester.runAsync(() async {
      await appState.init();
    });
    return appState;
  }

  testWidgets('空体系有明确说明；新增两条后保存进设置', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.pumpWidget(host(appState));
    await settleFrames(tester);

    expect(appState.settings.knowledgePointTypes, isEmpty);
    expect(find.text('还没有条目：AI 会自行判断知识点。'), findsOneWidget);
    expect(find.text('0 类'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '呼吸系统');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '循环系统');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump();

    expect(find.text('2 类'), findsOneWidget);
    // 还没保存：设置里仍是空的
    expect(appState.settings.knowledgePointTypes, isEmpty);

    await tapSaveAndWait(tester, '知识点体系已保存');

    expect(appState.settings.knowledgePointTypes, ['呼吸系统', '循环系统']);
    // 真落库了（不只是内存里改了）：重新从 settings 表读一遍。
    // updateSettings 存的是 jsonEncode(list)，见 AppState.updateSettings。
    final stored = await tester.runAsync(
        () => DatabaseService.instance.getSetting('knowledge_point_types'));
    expect(stored, jsonEncode(['呼吸系统', '循环系统']));
    // 整个过程一句请求都没发（AppState 只是构造了 AI 服务，没有探测）
    expect(aiRequests, 0, reason: '编辑知识点体系不该发起任何网络请求');

    await teardownTree(tester);
  });

  testWidgets('清空后保存 = 交回 AI 判断（空列表是合法状态）', (tester) async {
    setSurface(tester);
    final appState = await seed(tester);
    await tester.runAsync(
        () => appState.setKnowledgePointTypes(['解剖学', '生理学']));

    await tester.pumpWidget(host(appState));
    await settleFrames(tester);
    expect(find.text('2 类'), findsOneWidget);

    final clear = find.text('清空（交回 AI 判断）');
    await tester.ensureVisible(clear);
    await tester.pump();
    await tester.tap(clear);
    await tester.pump();
    expect(find.text('0 类'), findsOneWidget);

    await tapSaveAndWait(tester, '已清空知识点体系');

    expect(appState.settings.knowledgePointTypes, isEmpty);
    // 空列表同样要落库（jsonEncode([]) == '[]'），否则重启后又变回旧体系
    final stored = await tester.runAsync(
        () => DatabaseService.instance.getSetting('knowledge_point_types'));
    expect(stored, jsonEncode(<String>[]));
    expect(aiRequests, 0, reason: '编辑知识点体系不该发起任何网络请求');

    await teardownTree(tester);
  });
}
