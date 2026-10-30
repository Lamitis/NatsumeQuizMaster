import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/quiz_session.dart';
import '../services/app_state.dart';
import '../services/quiz_launcher.dart';
import '../services/theme_service.dart';
import '../utils/app_constants.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/command_palette.dart';
import '../widgets/guide/guide_anchor.dart';
import '../widgets/guide/guide_steps.dart';
import '../widgets/kit/natsume_kit.dart';
import '../widgets/quiz_setup_sheet.dart';
import 'bank_manage_screen.dart';
import 'error_book_screen.dart';
import 'import_preview_screen.dart';
import 'import_screen.dart';
import 'quiz_screen.dart';

/// 快速开始（独立导航项 · Natsume Des 2.0）
///
/// 从首页拆出来的「动作区」：首页只负责「看」（战绩与数据），
/// 这里只负责「做」（开始刷题 / 题库 / 错题 / 导入）。
/// 同时承接后台导入的任务状态（进行中进度、待确认预览）。
class QuickStartScreen extends StatefulWidget {
  const QuickStartScreen({super.key});

  @override
  State<QuickStartScreen> createState() => _QuickStartScreenState();
}

class _QuickStartScreenState extends State<QuickStartScreen> {
  /// 断点续刷：最新未完成会话 + 已答题数（续刷是「做」的动作，故在开始页）
  (QuizSession, int)? _unfinished;

  /// 「发起刷题」弹层是否已打开：连点入口时防止叠出多层弹层。
  bool _sheetOpen = false;

  /// 轻提示的兜底定时器：无障碍导航开启时框架会忽略 SnackBar 的 duration，
  /// 必须自己按时清掉（见 [_toast]）。
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final info = await context.read<AppState>().getUnfinishedSessionInfo();
      if (mounted) setState(() => _unfinished = info);
    });
  }

  /// 统一的轻提示：**先收起上一条再显示**。
  ///
  /// 2026-10-08 真机反馈：连点「自由选题」会连弹多条提示叠在一起。
  /// ScaffoldMessenger 默认把 SnackBar 排队逐条播，快速连点就会叠成一片；
  /// 这里统一收敛入口，保证同一时刻只有一条提示。
  ///
  /// 2026-10-09 用户要求：「提示需要在 2s 内消散」。
  /// 只传 `duration` **在这台真机上不够**——设备开着无障碍服务
  /// （accessibility_enabled=1），此时 Flutter 会让 SnackBar 常驻、忽略 duration
  /// （实测点击后 3.8 秒仍在，只有切页才消失）。所以这里再挂一个定时器兜底，
  /// 保证「2 秒内消散」与系统无障碍设置无关。
  ///
  /// 兜底只收**当前这一条**（`hideCurrentSnackBar`，它自带 isEmpty/isDismissed
  /// 守卫，对已自动消失的条目是空操作），不要用 `clearSnackBars`——那是全局清空，
  /// 会把别处（或用户已经切过去的下一个页面）刚弹出的提示一起清掉。
  /// 离开本页时定时器会被 [_navigateAndRefresh] / dispose 取消，提示不跟着走。
  void _toast(String message, {SnackBarAction? action}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: action,
        duration: NatsumeMotion.toast,
      ));
    _toastTimer?.cancel();
    _toastTimer = Timer(NatsumeMotion.toast, () {
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    });
  }

  bool _vacationBlocked(AppState appState) {
    if (!appState.vacationModeEnabled) return false;
    _toast('寒暑假模式中，答题功能已暂停');
    return true;
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  /// 一键导入内置示例题库（免 Key、免文件，转后台执行）
  void _importSampleBank(AppState appState) {
    // 后台导入互斥在应用层是静默 return——UI 层提前明示，别让用户干等
    if (appState.importTaskActive) {
      _toast('已有导入任务进行中');
      return;
    }
    NatsumeImportTask.discarded = false;
    unawaited(appState.startBackgroundSampleImport());
    _toast('已开始导入示例题库，进度见开始页顶部卡片');
  }

  /// 取消导入：后台任务不可中止（边界见 [NatsumeImportTask]），
  /// 「取消」= 不再展示进度、结果与解析结果直接丢弃。
  void _cancelImport(AppState appState) {
    NatsumeImportTask.discarded = true;
    // 丢弃解析结果，并借 clearPreview 的通知让各页立即隐藏任务卡
    appState.clearPreview();
    _toast('已取消导入，解析结果将丢弃');
  }

  Future<void> _navigateAndRefresh(
      BuildContext context, AppState appState, Widget page) async {
    // 2026-10-09 用户要求：「切入其他页面的时候就不要显示这个提示了」。
    // 点提示里的「去选择 / 去导入」会进二级页，提示不该跟着过去。
    // 同时要把兜底定时器一起取消：否则它会在 1.5s 时触发，去清掉**新页面**上
    // 刚弹出的提示（提示没跟过去，但清提示的定时器跟过去了）。
    _toastTimer?.cancel();
    ScaffoldMessenger.of(context).clearSnackBars();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: const Text('快速开始'),
        actions: [
          // 触屏入口：窄屏没有物理键盘，这里打开同一个命令面板
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: '搜索命令',
            onPressed: () => CommandPalette.open(context),
          ),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, appState, _) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(NatsumeSpace.md),
            child: ResponsivePage(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 后台导入：进行中进度卡
                  if (appState.importTaskActive && !NatsumeImportTask.discarded) ...[
                    NatsumeTaskCard(
                      progress: appState.importProgress,
                      status: appState.importStatus,
                      onCancel: () => _cancelImport(appState),
                    ),
                    const SizedBox(height: NatsumeSpace.sm),
                  ],
                  // 后台导入：AI 解析完成、待预览确认
                  if (!appState.importTaskActive &&
                      appState.previewQuestions.isNotEmpty) ...[
                    _PreviewConfirmCard(
                      appState: appState,
                      onOpen: () => _navigateAndRefresh(
                          context, appState, const ImportPreviewScreen()),
                    ),
                    const SizedBox(height: NatsumeSpace.sm),
                  ],

                  // 新生引导卡：零题库时置顶
                  if (appState.banks.isEmpty) ...[
                    NatsumeSurface(
                      accentEdge: true,
                      padding: const EdgeInsets.all(NatsumeSpace.sm),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: ac.accentSoft,
                              borderRadius: NatsumeRadius.smallBorder,
                              border: Border.all(
                                  color: ac.border, width: NatsumeLine.width),
                            ),
                            child: Icon(Icons.school_rounded,
                                color: ac.accent, size: 18),
                          ),
                          const SizedBox(width: NatsumeSpace.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('新生第一步',
                                    style: NatsumeType.h3Style.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: ac.textPrimary)),
                                const SizedBox(height: 2),
                                Text('导入示例题库（10 道医学题），无需任何配置立即体验',
                                    style: NatsumeType.captionStyle.copyWith(
                                        color: ac.textSecondary, height: 1.35)),
                              ],
                            ),
                          ),
                          const SizedBox(width: NatsumeSpace.xs),
                          FilledButton(
                            onPressed: () => _importSampleBank(appState),
                            style: FilledButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              minimumSize: const Size(0, 36),
                            ),
                            child: Text('导入',
                                style: NatsumeType.captionStyle.copyWith(
                                    color: ac.onAccent,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: NatsumeSpace.md),
                  ],

                  // 断点续刷：有未完成会话时置顶
                  if (_unfinished != null) ...[
                    NatsumeResumeCard(
                      session: _unfinished!.$1,
                      answered: _unfinished!.$2,
                      onTap: () async {
                        // 先取 navigator 再跨异步：context 不能再用
                        final nav = Navigator.of(context);
                        final ok = await appState.resumeUnfinishedSession();
                        if (!ok || !mounted) return;
                        await nav.push(
                          MaterialPageRoute(builder: (_) => const QuizScreen()),
                        );
                      },
                    ),
                    const SizedBox(height: NatsumeSpace.md),
                  ],
                  const NatsumeSectionHeader(
                    title: '开始刷题',
                    subtitle: '先选题库，再开始一轮练习；「自由选题」就是按所选题库集中刷题',
                  ),
                  const SizedBox(height: NatsumeSpace.sm),
                  GuideAnchor(
                    // 引导锚点：首启引导「开始刷题」那步
                    id: GuideAnchorIds.quickPrimary,
                    child: _QuickActionTile(
                      icon: Icons.tune_rounded,
                      // 2026-10-29 用户要求：功能改名「自由选题」，图标就是
                      // 「框里一个『自』字」。卡片自带描边方框，这里只放字，
                      // 不再挂 assets/burst_icon_ui.png 那张「爆」字素材。
                      iconWidget: Center(
                        child: Text(
                          '自',
                          style: TextStyle(
                            fontSize: 15,
                            height: 1,
                            fontWeight: FontWeight.w600,
                            color: ac.accent,
                          ),
                        ),
                      ),
                      label: '自由选题',
                      // 面板里能选题库范围与知识点，因此这里不再要求「先去管理题库勾选」；
                      // 只有一道题都没有时才拦一下（引导去导入）
                      subtitle: appState.banks.isEmpty
                          ? '尚未导入题库'
                          : (appState.selectedBankIds.isEmpty
                              ? '选题库与知识点后开刷'
                              : '已选${appState.selectedBankIds.length}个题库，${appState.selectedQuestionCount >= kQuestionCountAll ? '全部' : '${appState.selectedQuestionCount}题'}'),
                      iconColor: ac.accent,
                      onTap: () {
                        if (appState.banks.isEmpty) {
                          _toast(
                            '尚未导入题库，请先导入一份题库',
                            action: SnackBarAction(
                              label: '去导入',
                              onPressed: () => _navigateAndRefresh(
                                context,
                                appState,
                                const ImportScreen(),
                              ),
                            ),
                          );
                          return;
                        }
                        if (_vacationBlocked(appState)) return;
                        _showStartQuizSheet(context, appState);
                      },
                    ),
                  ),
                  _QuickActionTile(
                    icon: Icons.library_books_rounded,
                    label: '管理题库',
                    subtitle: appState.banks.isEmpty
                        ? '尚未导入题库，请先导入'
                        : '${appState.banks.length} 个题库',
                    iconColor: ac.accent,
                    onTap: () => _navigateAndRefresh(
                        context, appState, const BankManageScreen()),
                  ),
                  GuideAnchor(
                    // 引导锚点：首启引导「错题本」那步
                    id: GuideAnchorIds.quickErrorBook,
                    child: _QuickActionTile(
                      icon: Icons.replay_rounded,
                      label: '错题本',
                      subtitle: '智能排期，只显示应复习的错题',
                      iconColor: ac.danger,
                      onTap: () => _navigateAndRefresh(
                          context, appState, const ErrorBookScreen()),
                    ),
                  ),
                  GuideAnchor(
                    // 引导锚点：首启引导「导入题库」那步
                    id: GuideAnchorIds.quickImport,
                    child: _QuickActionTile(
                      icon: Icons.upload_file_rounded,
                      label: '导入题库',
                      subtitle: 'AI 解析 DOCX/PDF（需 Key），JSON 直接入库',
                      iconColor: ac.accent,
                      onTap: () => _navigateAndRefresh(
                          context, appState, const ImportScreen()),
                    ),
                  ),
                  const SizedBox(height: NatsumeSpace.md),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '© 2026 夏目安安（Natsume An-An）· $kAppVersion',
                      style:
                          NatsumeType.microStyle.copyWith(color: ac.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ══════════ 自由选题（题库范围 / 知识点 / 题量 / 模式一张面板一次确认） ══════════

  /// 唤起「自由选题」面板。
  ///
  /// 2026-10-29 用户反馈：题库范围此前只能回「管理题库」提前勾好。现在面板里
  /// 可改范围与知识点（见 [QuizSetupSheet]），勾选结果只作用于本次抽题，
  /// 不写回 [AppState.selectedBankIds]。
  void _showStartQuizSheet(BuildContext context, AppState appState) {
    // 连点防护：底部弹层是异步路由，第二次点击若在弹层出现前到达就会再压一层
    // （真机表现为叠层 / 半透明穿插）。这里用状态位保证同一时刻只有一层。
    if (_sheetOpen) return;
    _sheetOpen = true;
    QuizSetupSheet.show(context, appState).then((result) async {
      if (result == null || !mounted) return;
      await _launch(appState, result: result);
    }).whenComplete(() => _sheetOpen = false);
  }

  /// 发起一轮答题。
  ///
  /// 三种模式的抽题与落页差异全部收口在 [QuizLauncher]（题库题号网格复用同一份），
  /// 本页只负责「把失败原因提示出来」。
  Future<void> _launch(AppState appState,
      {required QuizSetupResult result}) async {
    appState.setQuestionCount(result.count);
    final error = await QuizLauncher.launch(
      context,
      appState,
      mode: result.mode,
      bankIds: result.bankIds,
      count: result.count,
      noShuffle: result.noShuffle,
      knowledgePoints: result.knowledgePoints,
      questionTypes: result.questionTypes,
    );
    if (error != null && mounted) _toast(error);
  }
}

// ════════════════════════════════════════════════════════════
// 局部组件
// ════════════════════════════════════════════════════════════

/// 动作条目：单色描边小图标 + 标题/副标题 + 细箭头。
class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.iconColor,
    required this.onTap,
    this.iconWidget,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final Color iconColor;
  final VoidCallback onTap;

  /// 自定义图标（覆盖 [icon]）。用于非 Material 图形的表达，
  /// 例如「自由选题」用「框里一个『自』字」（方块本身由卡片描边提供）。
  final Widget? iconWidget;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: NatsumeSpace.xs),
      child: NatsumeSurface(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(
            horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.sm),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: ac.surfaceAlt,
                borderRadius: NatsumeRadius.smallBorder,
                border: Border.all(color: ac.border, width: NatsumeLine.width),
              ),
              child: iconWidget ?? Icon(icon, color: iconColor, size: 16),
            ),
            const SizedBox(width: NatsumeSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: NatsumeType.h3Style.copyWith(
                          color: ac.textPrimary, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 1),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NatsumeType.captionStyle
                          .copyWith(color: ac.textSecondary)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: ac.textTertiary, size: 16),
          ],
        ),
      ),
    );
  }
}

/// 待确认预览入口
class _PreviewConfirmCard extends StatelessWidget {
  const _PreviewConfirmCard({required this.appState, required this.onOpen});

  final AppState appState;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return NatsumeSurface(
      onTap: onOpen,
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      child: Row(
        children: [
          Icon(Icons.fact_check_rounded, color: ac.accent, size: 18),
          const SizedBox(width: NatsumeSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('已解析 ${appState.previewQuestions.length} 道题，待确认',
                    style: NatsumeType.h3Style.copyWith(
                        fontWeight: FontWeight.w600, color: ac.accent)),
                const SizedBox(height: 2),
                Text('点击查看预览，确认后入库',
                    style:
                        NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: ac.accent, size: 16),
        ],
      ),
    );
  }
}
