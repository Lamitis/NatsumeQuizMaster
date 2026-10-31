import '../utils/design_tokens.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../services/app_state.dart';
import '../services/theme_service.dart';
import '../utils/import_source_filter.dart';
import '../widgets/import_drop_zone.dart';
import '../widgets/kit/natsume_kit.dart';
import '../utils/responsive.dart';
import '../widgets/guide/guide_anchor.dart';
import '../widgets/guide/guide_steps.dart';
import 'settings_screen.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  /// 已选文件（入口层临时列表：多选 / 拖拽都往这里并，点「开始 AI 导入」
  /// 后交给应用层，随后清空）
  final List<String> _selectedFiles = [];

  /// v1.27 后台导入：示例题库任务交给应用层，立即回首页（进度在首页展示，
  /// 完成后弹提示），不再阻塞在导入页。
  void _importSample() {
    final appState = context.read<AppState>();
    // 后台导入互斥在应用层是静默 return——UI 层提前明示，别让用户干等
    if (appState.importTaskActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已有导入任务进行中')),
      );
      return;
    }
    NatsumeImportTask.discarded = false;
    unawaited(appState.startBackgroundSampleImport());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已开始导入示例题库，进度见开始页顶部卡片')),
    );
    Navigator.pop(context);
  }

  /// 取消导入：后台任务不可中止（边界见 [NatsumeImportTask]），
  /// 「取消」= 不再展示进度、结果与解析结果直接丢弃。
  void _cancelImport(AppState appState) {
    NatsumeImportTask.discarded = true;
    // 丢弃当前预览与全部排队批次，并借通知让各页立即隐藏任务卡
    appState.discardAllPreviews();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已取消导入，解析结果将丢弃')),
    );
  }

  /// 系统文件选择器（多选）。
  ///
  /// file_picker 13.x 的 [FilePicker.pickFiles] **本身就是多选**：13.x 是 API
  /// 重写版，`allowMultiple` 参数随 `FilePickerResult` 一起去掉了，桌面端
  /// （资源管理器）与移动端（系统文档选择器）都支持一次选多个，返回
  /// `List<PlatformFile>`，取消即空列表。选中后逐个过滤并入已选列表，
  /// 点「开始 AI 导入」时由 [AppState.startBackgroundImport] 依次解析、
  /// 逐个排队预览——队列逻辑沿用既有实现。
  Future<void> _pickFiles() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择题库文件（可多选）',
      type: FileType.custom,
      // v1.35.4：入口统一口径 —— 只放 JSON / DOCX / PDF
      allowedExtensions: ImportSourceFilter.supportedExtensions,
    );
    if (picked.isEmpty || !mounted) return;
    final result = await ImportSourceFilter.collect(
        picked.map((f) => f.path).whereType<String>());
    if (!mounted) return;
    _addFiles(result);
  }

  /// 把过滤后的文件并入已选列表（去重、保序），并提示被跳过的格式。
  /// 返回 false 表示一个能导入的文件都没有。
  bool _addFiles(ImportSourceCollectResult result) {
    _showSkippedHint(result);
    if (result.files.isEmpty) {
      _snack('没有可导入的文件（支持 JSON / DOCX / PDF）');
      return false;
    }
    setState(() {
      final seen = _selectedFiles.map((f) => f.toLowerCase()).toSet();
      for (final file in result.files) {
        if (seen.add(file.toLowerCase())) _selectedFiles.add(file);
      }
    });
    return true;
  }

  /// 桌面端拖拽落地：文件 / 文件夹一次性塞进导入流程。
  ///
  /// 「松开」即视为用户已经决定导入，所以直接走 [_startImport]：
  /// DOCX/PDF 由应用层逐个解析并排队预览（预览队列逻辑一行没改），
  /// JSON 直接入库。
  void _onDroppedFiles(ImportSourceCollectResult result) {
    if (!mounted) return;
    if (!_addFiles(result)) return;
    final appState = context.read<AppState>();
    if (appState.importTaskActive) {
      _snack('已有导入任务进行中，文件已加入已选列表');
      return;
    }
    unawaited(_startImport(appState));
  }

  /// 被跳过的格式 / 文件夹：一次说清，别让用户以为文件丢了
  void _showSkippedHint(ImportSourceCollectResult result) {
    final lines = <String>[];
    if (result.rejected.isNotEmpty) {
      final names = result.rejected.take(3).map(p.basename).join('、');
      final more =
          result.rejected.length > 3 ? ' 等 ${result.rejected.length} 个' : '';
      final hasLegacyDoc =
          result.rejected.any((f) => f.toLowerCase().endsWith('.doc'));
      lines.add('已跳过不支持的文件：$names$more'
          '${hasLegacyDoc ? '（旧版 .doc 请先用 Word 另存为 .docx）' : ''}');
    }
    if (result.skippedDirectories.isNotEmpty) {
      lines.add('${result.skippedDirectories.length} 个文件夹无法读取，已跳过');
    }
    if (lines.isNotEmpty) _snack(lines.join('\n'));
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// DOC/DOCX/PDF 走 AI 解析；JSON 直接入库（与应用层同一口径）。
  ///
  /// v1.35.4 起入口只放行 docx/pdf/json，`.doc` 保留判定只为兼容历史调用
  /// （拖入 .doc 会在入口被拦下并提示另存为 .docx）。
  bool _isAiDoc(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.docx') ||
        lower.endsWith('.doc') ||
        lower.endsWith('.pdf');
  }

  /// 开始导入（页底按钮与桌面拖拽共用同一入口）。
  ///
  /// 顺序与既有页面逻辑一致：无 Key 先拦（直达设置）→ JSON 直接入库 →
  /// DOCX/PDF 交给应用层后台解析并逐个排队预览。
  Future<void> _startImport(AppState appState) async {
    if (_selectedFiles.isEmpty) {
      _snack('请先选择文件');
      return;
    }
    // 后台导入互斥在应用层是静默 return——UI 层提前明示
    if (appState.importTaskActive) {
      _snack('已有导入任务进行中');
      return;
    }
    // v1.28.1 新生引导：DOCX/PDF 依赖 AI 解析，无 Key 时前置拦截并直达设置页，
    // 不再让后台任务失败后只弹一个"知道了"
    final aiFiles = _selectedFiles.where(_isAiDoc).toList();
    if (aiFiles.isNotEmpty && !appState.settings.isConfigured) {
      await showDialog<void>(
        context: context,
        builder: (dlgCtx) => AlertDialog(
          title: const Text('需要 API Key'),
          content: const Text(
              'DOCX/PDF 导入使用 AI 解析题目，需要先配置 API Key。\n\n'
              '没有 Key？可以先点「一键导入示例题库」离线体验；'
              'JSON 题库文件也无需 Key。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dlgCtx),
              child: const Text('知道了'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.settings, size: 16),
              label: const Text('去设置'),
              onPressed: () {
                Navigator.pop(dlgCtx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const SettingsScreen(group: SettingsGroup.ai)),
                );
              },
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    // v1.27 后台导入：JSON 直接入库 + DOCX 走 AI 解析，全部在应用层执行；
    // 立即回首页（进度在首页展示、完成弹提示），导入期间可随时离开本页。
    final jsonFiles =
        _selectedFiles.where((f) => f.toLowerCase().endsWith('.json')).toList();
    NatsumeImportTask.discarded = false;
    unawaited(appState.startBackgroundImport(
      jsonFiles: jsonFiles,
      aiFiles: aiFiles,
    ));
    setState(() => _selectedFiles.clear());
    _snack('导入任务已开始，进度见开始页顶部卡片，可先浏览其他页面');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    // v1.0.2 设计审查修复：整页蓝白硬编码 → 主题色（此前切换任意主题都不变）
    final ac = AppThemeColors.of(context);
    // v1.35.4 入口优化：桌面端整页可接收文件拖拽（移动端/测试环境为透明包装）。
    // 这里只 select 一个 bool，避免导入进度的高频 notifyListeners 触发整页重建。
    final isProcessing =
        context.select<AppState, bool>((s) => s.importTaskActive);
    final page = Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: const Text('导入题库'),
        elevation: 0,
        backgroundColor: ac.navBar,
        foregroundColor: Theme.of(context).appBarTheme.foregroundColor,
      ),
      body: Consumer<AppState>(
        builder: (context, appState, _) {
          // v1.27 后台导入：任务状态改用应用层标志（进度精确展示，离开页面不中断）
          final isProcessing = appState.importTaskActive;

          // 平板适配：内容限宽居中（手机无影响）。
          // v1.27 修复：整页改单滚动结构——此前文件列表被压在 Column 的
          // Expanded 里，上方固定内容占满小窗口/手机屏时列表区几乎为 0，
          // 无法滚动查看已选文件名；现在整页可滚动，操作按钮固定在页底。
          return ResponsivePage(
            child: SingleChildScrollView(
            padding: const EdgeInsets.all(NatsumeSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 流程说明：发丝面板 + 左强调条（精密风格不用大色块）
                NatsumeSurface(
                  accentEdge: true,
                  padding: const EdgeInsets.all(NatsumeSpace.sm),
                  child: Row(
                    children: [
                      Icon(Icons.auto_awesome, color: ac.accent, size: 18),
                      const SizedBox(width: NatsumeSpace.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('AI 智能解析',
                                style: NatsumeType.h3Style.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: ac.textPrimary)),
                            const SizedBox(height: 2),
                            Text(
                              '自动提取题干、选项、答案，兼容各种 DOCX/PDF 格式',
                              style: NatsumeType.captionStyle
                                  .copyWith(color: ac.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // 格式说明
                NatsumeSurface(
                  tone: NatsumeTone.alt,
                  padding: const EdgeInsets.all(NatsumeSpace.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 15, color: ac.warning),
                      const SizedBox(width: NatsumeSpace.xs),
                      Expanded(
                        child: Text(
                          '支持 DOCX / PDF / JSON。DOCX/PDF 解析后先预览题目，可编辑、删除后再确认入库；PDF 自动抽图，插图随题保留。\n旧版 .doc 文件请先用 Word 另存为 .docx。\n扫描版 PDF 也能导入；识别不准时可在「设置 → AI 接口」开启 MinerU 版面识别。',
                          style: NatsumeType.captionStyle
                              .copyWith(color: ac.textSecondary, height: 1.6),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // 一键导入内置示例题库（新用户/演示：无需文件立即体验刷题）
                // 首启引导的第 9 步就落在这块上——它是导入页里唯一
                // 无条件存在、点了立刻有题可刷、还不依赖 API Key 的入口
                GuideAnchor(
                  id: GuideAnchorIds.importSample,
                  child: GestureDetector(
                    onTap: isProcessing ? null : _importSample,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: NatsumeSpace.md, vertical: NatsumeSpace.sm),
                      decoration: BoxDecoration(
                        color: ac.accent.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(NatsumeRadius.control),
                        border:
                            Border.all(color: ac.accent.withOpacity(0.4)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.rocket_launch_outlined,
                              color: ac.accent, size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('一键导入示例题库',
                                    style: TextStyle(
                                        fontSize: NatsumeType.h3,
                                        fontWeight: FontWeight.w600,
                                        color: ac.accent)),
                                const SizedBox(height: 2),
                                Text(
                                    '内置 10 道医学示例题（单选/多选/判断），无需文件立即体验',
                                    style: TextStyle(
                                        fontSize: NatsumeType.body,
                                        color: ac.textSecondary)),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: ac.accent),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // 文件选择
                GestureDetector(
                  onTap: isProcessing ? null : _pickFiles,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(NatsumeSpace.xxl),
                    decoration: BoxDecoration(
                      color: ac.card,
                      borderRadius: BorderRadius.circular(NatsumeRadius.control),
                      border: Border.all(
                          color: ac.accent.withOpacity(0.3), width: 2),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.cloud_upload_outlined,
                            size: 48, color: ac.textSecondary),
                        const SizedBox(height: 12),
                        Text('选择文件（DOCX / PDF / JSON，可多选）',
                            style: TextStyle(
                                fontSize: NatsumeType.h3, color: ac.accent)),
                        const SizedBox(height: 4),
                        Text('AI 将自动识别题目、选项和答案',
                            style: TextStyle(
                                fontSize: NatsumeType.body, color: ac.textSecondary)),
                        const SizedBox(height: 4),
                        Text('PDF 自动抽图，插图随题保留',
                            style: TextStyle(
                                fontSize: NatsumeType.body, color: ac.textSecondary)),
                        const SizedBox(height: 4),
                        // v1.0.2 对齐里程碑：JSON 直导入库提示
                        Text(
                            '导入 .json 题库文件（可多选），无需 AI 解析，题目答案直接入库，完成后显示导入报告',
                            style: TextStyle(
                                fontSize: NatsumeType.body, color: ac.textSecondary)),
                        // v1.35.4 入口优化：桌面端支持拖拽（拖文件夹会递归展开）
                        if (ImportDropZone.isDesktopPlatform) ...[
                          const SizedBox(height: 4),
                          Text('桌面端还可以直接把文件或文件夹拖到这里，松开即批量导入',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: NatsumeType.body,
                                  color: ac.textSecondary)),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // 已选文件（v1.27：随整页滚动，不再被压在 Expanded 小区域）
                if (_selectedFiles.isNotEmpty) ...[
                  Text('已选文件',
                      style: TextStyle(
                          fontSize: NatsumeType.body,
                          fontWeight: FontWeight.w600,
                          color: ac.textPrimary)),
                  // 多选文档会逐个解析、逐个排队预览——不再只解析第一个，
                  // 也不会把上一份还没确认的解析结果顶掉
                  if (_selectedFiles.where((f) => _isAiDoc(f)).length > 1) ...[
                    const SizedBox(height: 4),
                    Text(
                        '多选文档将逐个解析：每份各成一个题库，确认完一份自动接下一份预览',
                        style: TextStyle(
                            fontSize: NatsumeType.body, color: ac.textSecondary)),
                  ],
                  const SizedBox(height: 8),
                  for (var index = 0; index < _selectedFiles.length; index++)
                    Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.description_outlined,
                            color: ac.accent),
                        // v1.0.2 设计审查修复：取文件名用 path 包 basename
                        title: Text(p.basename(_selectedFiles[index]),
                            style: const TextStyle(fontSize: NatsumeType.body)),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: isProcessing
                              ? null
                              : () => setState(
                                  () => _selectedFiles.removeAt(index)),
                        ),
                      ),
                    ),
                ],
              ],
            ),
            ),
          );
        },
      ),
      
      // v1.27 修复：余额/开始导入/进度固定在页底——文件再多也能滚动查看，
      // 操作按钮始终可见（小窗口不再被挤出屏幕）。
      bottomNavigationBar: Consumer<AppState>(
        builder: (context, appState, _) {
          final isProcessing = appState.importTaskActive;
          if (_selectedFiles.isEmpty && !isProcessing) {
            return const SizedBox.shrink();
          }
          return SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(
                  NatsumeSpace.md, NatsumeSpace.sm, NatsumeSpace.md, NatsumeSpace.md),
              decoration: BoxDecoration(
                color: ac.background,
                border: Border(
                    top: BorderSide(
                        color: ac.border.withOpacity(0.6))),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 余额提示（选了文件且余额已加载时显示）
                  if (_selectedFiles.isNotEmpty &&
                      appState.aiService?.cachedBalance != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Builder(
                        // v1.0.2 设计审查修复：getEstimatedRemainingQuestions
                        // 只调用一次（此前同一 build 调用两次）
                        builder: (ctx) {
                          final remaining =
                              appState.getEstimatedRemainingQuestions();
                          return Text(
                            '余额 ¥${appState.aiService!.cachedBalance!.toStringAsFixed(2)}，预估可再导入 ${remaining > 0 ? "~$remaining 题" : "..."}',
                            style: TextStyle(
                                fontSize: NatsumeType.body, color: ac.textSecondary),
                          );
                        },
                      ),
                    ),

                  // 开始导入（仅选了文件时显示；导入中展示进度）
                  if (_selectedFiles.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: isProcessing
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: ac.onAccent),
                            )
                          : const Icon(Icons.auto_awesome, size: 20),
                      label: Text(
                        isProcessing ? 'AI 解析中...' : '开始 AI 导入',
                        style: const TextStyle(fontSize: NatsumeType.h3),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ac.accent,
                        foregroundColor: ac.onAccent,
                        padding:
                            const EdgeInsets.symmetric(vertical: NatsumeSpace.sm),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(NatsumeRadius.small)),
                      ),
                      onPressed: isProcessing
                          ? null
                          : () => _startImport(appState),
                    ),
                  ),

                  // v1.27 进度展示：与首页/开始页同一张任务卡（任务在应用层继续，
                  // 离开本页后开始页顶部卡片同步展示）
                  if (isProcessing && !NatsumeImportTask.discarded)
                    Padding(
                      padding: const EdgeInsets.only(top: NatsumeSpace.sm),
                      child: NatsumeTaskCard(
                        progress: appState.importProgress,
                        status: appState.importStatus,
                        onCancel: () => _cancelImport(appState),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );

    return ImportDropZone(
      enabled: !isProcessing,
      onFiles: _onDroppedFiles,
      child: page,
    );
  }
}
