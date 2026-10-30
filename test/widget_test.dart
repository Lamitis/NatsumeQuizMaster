import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:natsume_quiz_master/main.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/guide_service.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

void main() {
  Widget app() => MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: AppState()),
          ChangeNotifierProvider<ThemeService>.value(value: ThemeService()),
        ],
        child: const FlashcardApp(),
      );

  testWidgets('App smoke test（启动闪屏 → 主界面）', (WidgetTester tester) async {
    // 老用户路径：引导已看过 → 闪屏之后直接进主界面
    SharedPreferences.setMockInitialValues({GuideService.keyGuideSeenV2: true});
    GuideService.instance.resetCacheForTest();

    await tester.pumpWidget(app());
    await tester.pump();

    // 启动闪屏页：软件名字 + 今日一言（v1.0.2 启动页设计）。
    expect(find.text('NatsumeQuizMaster'), findsOneWidget);
    expect(find.text('今日一言'), findsOneWidget);
    // v1.27 PC 加载修复：一言首帧直接显示本地一言库，
    // 永不再出现「正在加载一言...」占位（网络不可用时也如此）。
    await tester.pump();
    expect(find.text('正在加载一言...'), findsNothing);

    // 1.4 秒后自动进入下一步（闪屏页 CircularProgressIndicator 为无限动画，
    // pumpAndSettle 永不收敛，改用显式 pump 推进过渡动画）
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // 主界面：AppBar 标题 + 首页顶部 hero 卡片软件名字。
    expect(find.text('NatsumeQuizMaster'), findsNWidgets(2));
    // 老用户不该看到引导
    expect(find.text('一分钟上手NatsumeQuizMaster'), findsNothing);
    // 首页顶部一言（v1.27）：同样不再出现加载占位，直接显示本地一言库。
    expect(find.text('正在加载一言...'), findsNothing);
  });

  testWidgets('首启路径：进主界面后插播互动式引导，跳过即记住', (WidgetTester tester) async {
    // 全新安装：没有已看标记 → 首次启动必须看到引导
    SharedPreferences.setMockInitialValues({});
    GuideService.instance.resetCacheForTest();

    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text('今日一言'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // 引导覆盖在主界面之上：欢迎步是居中气泡，主界面已在下面
    expect(find.text('一分钟上手NatsumeQuizMaster'), findsOneWidget,
        reason: '首启应在主界面上插播互动式引导');
    expect(find.text('第 1 步 / 共 13 步'), findsOneWidget);
    expect(find.text('跳过'), findsOneWidget);

    // 跳过 → 引导消失，并落「已看过」标记（下次启动不再插播）
    await tester.tap(find.text('跳过'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('一分钟上手NatsumeQuizMaster'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(GuideService.keyGuideSeenV2), isTrue);

    // 收尾：摘掉页面以停掉主界面/引导留下的定时器与动画
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
