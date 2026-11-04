import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/screens/settings_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/sync/lan_address.dart';
import 'package:natsume_quiz_master/services/sync/sync_discovery.dart';
import 'package:natsume_quiz_master/services/sync/sync_engine.dart';
import 'package:natsume_quiz_master/services/sync/sync_models.dart';
import 'package:natsume_quiz_master/services/sync/sync_pair_payload.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';
import 'package:natsume_quiz_master/utils/platform_support.dart';

class FakeSettingsState extends AppState {
  AppSettings current = AppSettings(autoSync: false);
  bool reminder = false;
  DateTime? time;
  @override
  AppSettings get settings => current;
  @override
  Future<void> updateSettings(AppSettings settings) async {
    current = settings;
    notifyListeners();
  }

  @override
  bool get reminderEnabled => reminder;
  @override
  DateTime? get reminderTime => time;
  @override
  Future<void> setReminderSettings(
      {required bool enabled, DateTime? time}) async {
    reminder = enabled;
    this.time = time ?? this.time;
    notifyListeners();
  }

  @override
  Future<double?> fetchAIBalance() async => null;
  @override
  Future<int> getUntaggedErrorCount() async => 0;
}

class FailingSync extends ChangeNotifier implements SyncEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  bool get syncing => false;
  @override
  String get statusMessage => '';
  @override
  DateTime? get lastSyncAt => null;
  @override
  List<DiscoveredPeer> get peers => [];
  bool running = false;
  bool fail = true;
  @override
  bool get started => running;
  @override
  Future<void> start({required bool autoSync}) async {
    if (fail) throw StateError('service unavailable');
    running = true;
  }

  @override
  Future<void> applyAutoSync(bool enabled) async {
    if (fail && enabled) throw StateError('apply unavailable');
  }

  // ── 识别码与同步范围（假引擎必须提供这些 API）──
  // mock 必须显式实现，否则 noSuchMethod 抛错会让整个同步区块渲染失败
  @override
  String get deviceCode => 'TESTCODE0000AAAA';
  @override
  String get peerCode => '';
  @override
  bool get paired => false;
  @override
  String get tempCode => '';
  @override
  DateTime? get tempExpiry => null;
  @override
  bool get tempCodeAlive => false;
  @override
  bool get banksOnly => false;
  @override
  void applyPeerCode(String raw, {bool autoVerify = true}) {}
  @override
  void generateTempCode() {}
  @override
  void clearTempCode() {}
  @override
  void applyBanksOnly(bool banksOnly) {}

  // ── 配对状态机与网络诊断（假引擎必须提供这些 getter）──
  // 设置页无条件读取这些 getter（配对状态行 + 「网络诊断」标题摘要），
  // 若不显式实现，noSuchMethod 会抛错使整个同步区块渲染失败。
  @override
  SyncPairState get pairState => SyncPairState.none;
  @override
  String get pairDetail => '';
  @override
  String get confirmedPeerName => '';
  @override
  Future<void> verifyPairing() async {}
  @override
  int get httpPort => 0;
  @override
  SyncDiscoveryStats get discoveryStats => const SyncDiscoveryStats(
        sent: 0,
        sendFailures: 0,
        received: 0,
        ignored: 0,
        lastSentAt: null,
        lastReceivedAt: null,
        lastError: null,
        boundPort: 0,
        heals: 0,
        interfaces: <String>[],
      );
  @override
  Future<List<LanInterface>> localInterfaces() async => const <LanInterface>[];
  @override
  Future<SyncPairPayload> buildPairPayload() async =>
      const SyncPairPayload(code: 'TESTCODE0000AAAA');
  @override
  Future<bool> pairFromScan(SyncPairPayload payload) async => false;

  // ── 双向配对 / 取消 / 增量重置（假引擎必须提供这些成员）──
  // 设置页会读 peerConfirmed（同步按钮门禁）与 lastSyncCancelled，
  // 并取 cancelSync / resetSyncProgress 的方法引用——mock 不实现就会抛。
  @override
  bool get peerConfirmed => false;
  @override
  bool get lastSyncCancelled => false;
  @override
  void cancelSync() {}
  @override
  Future<void> resetSyncProgress({bool quiet = false}) async {}
}

class FakeReminderActions extends SettingsReminderActions {
  bool granted = false;
  bool failSchedule = false;
  int schedules = 0;
  @override
  Future<bool> hasPermission() async => granted;
  @override
  Future<bool> requestPermission() async => granted;
  @override
  Future<void> syncSchedule() async {
    schedules++;
    if (failSchedule) throw StateError('schedule unavailable');
  }
}

void main() {
  Future<void> showSettings(WidgetTester tester, FakeSettingsState app,
      FailingSync sync, FakeReminderActions reminder,
      {SettingsGroup group = SettingsGroup.sync,
      Size surface = const Size(1000, 2200)}) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<SyncEngine>.value(value: sync),
        ChangeNotifierProvider<ThemeService>(create: (_) => ThemeService()),
      ],
      child: MaterialApp(
          home: SettingsScreen(
        group: group,
        reminderActions: reminder,
      )),
    ));
    await tester.pumpAndSettle();
  }

  // ── 分组内容回归 ──────────────────────────────────────────
  // v1.41.1：分组不再用「sections 下标表」，而是每个区块自带 group/order。
  // 这里给每组钉标志性标题，防止再次出现「调试日志跑到外观 / 网络加速跑到同步
  // / 音效消失」这类串位；下面的移动端用例再验证隐藏 MinerU 后不会错位。
  // CI 在 Ubuntu 上跑：高级组是否包含 MinerU 取决于宿主是否 Windows。
  // 不写死「有 MinerU」，否则 Linux CI 必然红（这正是上一次 CI 失败的原因）。
  final hostIsWindows = isWindowsPlatform;
  final groupMarkers = <SettingsGroup, List<String>>{
    SettingsGroup.appearance: ['主题外观', '深色模式', '音效'],
    SettingsGroup.ai: ['AI 接口配置', 'AI 回答风格', 'AI 提供方', '使用说明'],
    SettingsGroup.knowledge: ['为剩余题目打标签'],
    SettingsGroup.sync: ['局域网同步', '寒暑假模式', '提醒与复习', '插件内容同步'],
    SettingsGroup.advanced: [
      if (hostIsWindows) '扫描件识别增强（MinerU）',
      '数据库备份',
      '网络加速',
      '调试日志',
    ],
  };

  for (final entry in groupMarkers.entries) {
    testWidgets('${entry.key.label}组只显示自己的区块（分组未串位）',
        (tester) async {
      await showSettings(tester, FakeSettingsState(), FailingSync(),
          FakeReminderActions(),
          group: entry.key);
      for (final text in entry.value) {
        expect(find.text(text), findsOneWidget, reason: '缺少「$text」区块');
      }
      // 别的组独有标题不该串进来（组标签/顺序错乱时会串组）
      for (final other in groupMarkers.entries) {
        if (other.key == entry.key) continue;
        final marker = other.value.first;
        expect(find.text(marker), findsNothing,
            reason: '「${entry.key.label}」组里不该出现「$marker」');
      }
    });
  }

  for (final started in [false, true]) {
    testWidgets(
        'auto sync ${started ? 'application' : 'startup'} failure keeps off and allows retry',
        (tester) async {
      final app = FakeSettingsState();
      final sync = FailingSync()..running = started;
      await showSettings(tester, app, sync, FakeReminderActions());
      await tester.tap(find.text('自动同步已关闭'));
      await tester.pumpAndSettle();
      expect(app.settings.autoSync, isFalse);
      expect(find.textContaining('自动同步设置失败'), findsOneWidget);
      sync.fail = false;
      await tester.tap(find.text('自动同步已关闭'));
      await tester.pumpAndSettle();
      expect(app.settings.autoSync, isTrue);
      expect(find.text('自动同步已开启'), findsOneWidget);
      expect(find.textContaining('自动同步设置失败'), findsNothing);
    });
  }

  testWidgets('denied permission never enables reminder; granting allows retry',
      (tester) async {
    final app = FakeSettingsState();
    final actions = FakeReminderActions();
    await showSettings(tester, app, FailingSync(), actions);
    final toggle = find.byKey(const ValueKey('settings-reminder-switch'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.reminderEnabled, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.textContaining('提醒未开启'), findsOneWidget);
    actions.granted = true;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.reminderEnabled, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  testWidgets('reminder schedule failure rolls back and displays failure',
      (tester) async {
    final app = FakeSettingsState();
    final actions = FakeReminderActions()
      ..granted = true
      ..failSchedule = true;
    await showSettings(tester, app, FailingSync(), actions);
    final toggle = find.byKey(const ValueKey('settings-reminder-switch'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.reminderEnabled, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.textContaining('提醒设置失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stored reminder is not shown enabled without permission',
      (tester) async {
    final app = FakeSettingsState()..reminder = true;
    await showSettings(tester, app, FailingSync(), FakeReminderActions());
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('settings-reminder-switch')))
            .value,
        isFalse);
    expect(find.textContaining('提醒不可用'), findsOneWidget);
  });

  testWidgets('网络加速：自定义镜像保存后补全尾斜杠并即时生效', (tester) async {
    final app = FakeSettingsState();
    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.advanced);
    final field = find.byKey(const ValueKey('settings-custom-mirror'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'https://my.proxy');
    final save = find.byKey(const ValueKey('settings-custom-mirror-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(app.settings.customMirror, 'https://my.proxy/');
    expect(find.textContaining('已保存自定义镜像'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网络加速：非法镜像不写设置并提示', (tester) async {
    final app = FakeSettingsState();
    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.advanced);
    final field = find.byKey(const ValueKey('settings-custom-mirror'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'ghfast.top');
    final save = find.byKey(const ValueKey('settings-custom-mirror-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(app.settings.customMirror, isEmpty);
    expect(find.textContaining('镜像地址需以'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MinerU 显隐：移动端隐藏 / Windows 显示 / 非 Windows 隐藏',
      (tester) async {
    addTearDown(() {
      debugMobileOverride = null;
      debugWindowsOverride = null;
    });
    final app = FakeSettingsState();

    // ① 移动端：必须完全隐藏
    debugMobileOverride = true;
    debugWindowsOverride = null;
    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.advanced);
    expect(find.text('扫描件识别增强（MinerU）'), findsNothing,
        reason: '移动端必须完全隐藏 MinerU 卡片');
    expect(find.text('允许扫描件使用 MinerU（桌面端自动判断）'), findsNothing);
    expect(find.textContaining('MinerU Token'), findsNothing);
    // 高级组本身仍要正常：隐藏一张卡不能把整组带崩
    expect(find.text('电池优化'), findsOneWidget);
    expect(find.text('网络加速'), findsOneWidget);

    // ② Windows 桌面端：显式模拟，保证在 Ubuntu CI 上也能断言
    debugMobileOverride = null;
    debugWindowsOverride = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.advanced);
    expect(find.text('扫描件识别增强（MinerU）'), findsOneWidget);
    expect(find.text('电池优化'), findsNothing,
        reason: '电池优化只在移动端显示');

    // ③ 非 Windows 桌面端（Ubuntu CI 的真实宿主）：MinerU 也必须隐藏
    debugWindowsOverride = false;
    await tester.pumpWidget(const SizedBox.shrink());
    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.advanced);
    expect(find.text('扫描件识别增强（MinerU）'), findsNothing,
        reason: '非 Windows 平台不提供 MinerU');
    expect(find.text('数据库备份'), findsOneWidget);
    expect(find.text('电池优化'), findsNothing,
        reason: '电池优化只在移动端显示');

    // ④ 真实宿主分支（不加 override）：按宿主平台断言，Windows/Ubuntu 都过
    debugWindowsOverride = null;
    debugMobileOverride = null;
    final hostWindows = isWindowsPlatform;
    await tester.pumpWidget(const SizedBox.shrink());
    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.advanced);
    expect(find.text('扫描件识别增强（MinerU）'),
        hostWindows ? findsOneWidget : findsNothing);
  });

  testWidgets('移动端隐藏 MinerU 后分组不串位（v1.41.2 回归）', (tester) async {
    debugMobileOverride = true;
    addTearDown(() => debugMobileOverride = null);
    final app = FakeSettingsState();

    Future<void> show(SettingsGroup group) async {
      await showSettings(tester, app, FailingSync(), FakeReminderActions(),
          group: group);
      expect(tester.takeException(), isNull,
          reason: '${group.label} 组不应因下标错位抛异常');
    }

    // 高级：能打开，电池优化（移动端）/备份/网络加速/调试日志都在
    await show(SettingsGroup.advanced);
    for (final text in ['电池优化', '数据库备份', '网络加速', '调试日志']) {
      expect(find.text(text), findsOneWidget, reason: '高级组缺少「$text」');
    }
    expect(find.text('扫描件识别增强（MinerU）'), findsNothing,
        reason: '移动端隐藏 MinerU 后，后面区块不能整体前移');

    // 外观：音效回来了，调试日志不在这里
    await show(SettingsGroup.appearance);
    expect(find.text('音效'), findsOneWidget);
    expect(find.text('调试日志'), findsNothing,
        reason: '调试日志属于高级组，不能被挤到外观');

    // AI：接口 / 风格 / 提供方 / 使用说明，标签体系移出去
    await show(SettingsGroup.ai);
    for (final text in ['AI 接口配置', 'AI 回答风格', 'AI 提供方', '使用说明']) {
      expect(find.text(text), findsOneWidget, reason: 'AI 组缺少「$text」');
    }
    expect(find.text('为剩余题目打标签'), findsNothing,
        reason: '标签体系属于「题库与标签」，不能塞进 AI 组');

    // 同步：网络加速不在这里
    await show(SettingsGroup.sync);
    expect(find.text('局域网同步'), findsOneWidget);
    expect(find.text('网络加速'), findsNothing,
        reason: '网络加速属于高级组，不能被挤到同步组');

    // 题库与标签：标签卡片在这里
    await show(SettingsGroup.knowledge);
    expect(find.text('为剩余题目打标签'), findsOneWidget);
  });

  testWidgets('分组渲染顺序与最终结构完全一致（桌面 / 移动）', (tester) async {
    void expectOrder(List<String> labels) {
      var prev = double.negativeInfinity;
      for (final label in labels) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: '缺少「$label」');
        final y = tester.getTopLeft(finder).dy;
        expect(y, greaterThan(prev), reason: '「$label」的渲染顺序不对');
        prev = y;
      }
    }

    final app = FakeSettingsState();
    // 窄屏（<840）走单列，才能用 y 坐标验证顺序
    const narrow = Size(520, 4200);
    addTearDown(() {
      debugMobileOverride = null;
      debugWindowsOverride = null;
    });

    // ① Windows 桌面端：MinerU 首位；电池优化不显示
    debugWindowsOverride = true;
    debugMobileOverride = null;
    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.advanced, surface: narrow);
    expectOrder(
        ['扫描件识别增强（MinerU）', '数据库备份', '网络加速', '调试日志']);

    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.ai, surface: narrow);
    expectOrder(['AI 接口配置', 'AI 回答风格', 'AI 提供方', '使用说明']);

    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.appearance, surface: narrow);
    expectOrder(['主题外观', '深色模式', '音效']);

    // ② 非 Windows 桌面端（Ubuntu CI 的真实宿主）：MinerU 不出现，其余顺序不变
    debugWindowsOverride = false;
    await tester.pumpWidget(const SizedBox.shrink());
    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.advanced, surface: narrow);
    expect(find.text('扫描件识别增强（MinerU）'), findsNothing);
    expectOrder(['数据库备份', '网络加速', '调试日志']);

    // ③ 移动端：MinerU 消失，电池优化补位到高级组首位
    debugWindowsOverride = null;
    debugMobileOverride = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await showSettings(tester, app, FailingSync(), FakeReminderActions(),
        group: SettingsGroup.advanced, surface: narrow);
    expectOrder(['电池优化', '数据库备份', '网络加速', '调试日志']);
  });
}
