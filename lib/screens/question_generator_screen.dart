import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/knowledge_base.dart';
import '../services/app_state.dart';
import '../services/bank_file_service.dart';
import '../services/export_storage.dart';
import '../services/integrity_service.dart';
import '../services/knowledge_base/kb_service.dart';
import '../services/question_generator/generator_agent.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';

/// 自动出题（v13 · 学 dsh）。
///
/// 选一个知识库 → 定题数与题库名 → 跑 Agent：AI 只依据知识库检索资料出题，
/// 把结果写入自己的沙箱 JSON，再导入成题库。
class QuestionGeneratorScreen extends StatefulWidget {
  const QuestionGeneratorScreen({super.key});

  @override
  State<QuestionGeneratorScreen> createState() =>
      _QuestionGeneratorScreenState();
}

class _QuestionGeneratorScreenState extends State<QuestionGeneratorScreen> {
  final KbService _kb = KbService.instance;

  /// AI 出题产物的落盘目录名（在 [ExportStorage] 的导出目录下，用户可见）
  static const String _aiGenFolder = 'AI生成题库';

  List<KnowledgeBase> _bases = [];
  int? _kbId;
  int _targetCount = 10;
  bool _running = false;
  final List<String> _log = [];
  final TextEditingController _nameController =
      TextEditingController(text: 'AI 生成题库');

  @override
  void initState() {
    super.initState();
    _loadBases();
  }

  Future<void> _loadBases() async {
    final bases = await _kb.listKnowledgeBases();
    if (!mounted) return;
    setState(() {
      _bases = bases;
      if (_kbId == null && bases.isNotEmpty) _kbId = bases.first.id;
    });
  }

  Future<void> _run() async {
    // 防伪：检测到二次打包时静默限制 AI 出题（高级功能）
    if (IntegrityService.advancedFeaturesLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('检测到应用被二次打包，AI 出题已受限')));
      return;
    }
    final appState = context.read<AppState>();
    final ai = appState.aiService;
    if (ai == null || _kbId == null) return;
    setState(() {
      _running = true;
      _log.clear();
    });

    final sandbox = await _sandboxDir();
    final agent = GeneratorAgent(aiService: ai, kbService: _kb);
    final result = await agent.generate(
      kbId: _kbId!,
      targetCount: _targetCount,
      bankName: _nameController.text.trim().isEmpty
          ? 'AI 生成题库'
          : _nameController.text.trim(),
      sandboxDir: sandbox,
      onLog: (m) {
        if (mounted) setState(() => _log.add(m));
      },
    );

    var imported = 0;
    if (result.bankFilePath != null && result.questionCount > 0) {
      imported = await _importResult(result.bankFilePath!, appState);
      if (mounted && imported > 0) {
        setState(() => _log
            .add('题库文件：${ExportStorage.folderOf(result.bankFilePath!)}'));
      }
    }

    if (!mounted) return;
    setState(() => _running = false);
    final msg = imported > 0
        ? '已生成并导入 $imported 道题'
        : '未生成出有效题目（可查看过程日志）';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 出题沙箱目录：落在用户可见的「导出目录/AI生成题库/<时间戳>」下。
  ///
  /// 此前用 `Directory.systemTemp`（手机上是应用私有缓存），用户既看不见也
  /// 留不住，反馈「生成的题库文件扔在系统临时目录里」。换成导出目录后，
  /// `questions.json` 可以直接在文件管理器/资源管理器里找到并再次导入。
  Future<Directory> _sandboxDir() async {
    final base = await ExportStorage.resolve();
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(RegExp(r'[:.]'), '-');
    final dir = Directory('${base.path}${Platform.pathSeparator}'
        '$_aiGenFolder${Platform.pathSeparator}$stamp');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 把 Agent 写出的 `{"questions":[...]}` 包装成 `BankFileService` 可导入的
  /// 格式标记文件，再走既有导入闭环。
  ///
  /// 落库后必须回调 [AppState.refreshBanks]：这条路径绕过 AppState 的导入
  /// 流程直接写库，不刷新的话题库管理页/开始页仍是旧列表——真机反馈的
  /// 「AI 生成完题库但列表里没有，要手动刷新」就是这个。
  Future<int> _importResult(String path, AppState appState) async {
    File? tmp;
    try {
      final raw = await File(path).readAsString();
      final data = jsonDecode(raw);
      final questions = data is Map
          ? (data['questions'] ?? const [])
          : (data is List ? data : const []);
      if (questions is! List || questions.isEmpty) return 0;
      tmp = File('$path.import.json');
      await tmp.writeAsString(jsonEncode({
        'format': BankFileService.formatMarker,
        'name': _nameController.text.trim().isEmpty
            ? 'AI 生成题库'
            : _nameController.text.trim(),
        'questions': questions,
      }));
      // 同名题库自动加后缀，避免反复生成堆出多个「AI 生成题库」
      final result = await BankFileService.importJsonFile(tmp.path,
          existingNames: appState.banks.map((b) => b.name).toSet());
      if (result.$2 > 0) await appState.refreshBanks();
      return result.$2;
    } catch (_) {
      return 0;
    } finally {
      // 包装文件只是导入用的临时中转，导入即删；questions.json 本体保留
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('自动出题')),
      body: ResponsivePage(
        child: ListView(
          padding: const EdgeInsets.all(NatsumeSpace.md),
          children: [
            NatsumeSurface(
              accentEdge: true,
              padding: const EdgeInsets.all(NatsumeSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('基于知识库生成题目',
                      style: NatsumeType.h2Style.copyWith(color: ac.textPrimary)),
                  const SizedBox(height: NatsumeSpace.xxs),
                  Text('AI 只依据所选知识库的资料出题，资料未覆盖的内容不会编造。',
                      style:
                          NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
                  const SizedBox(height: NatsumeSpace.md),
                  Text('知识库', style: NatsumeType.captionStyle.copyWith(color: ac.textTertiary)),
                  const SizedBox(height: NatsumeSpace.xs),
                  if (_bases.isEmpty)
                    Text('尚无知识库，请先到「知识库」导入资料。',
                        style:
                            NatsumeType.captionStyle.copyWith(color: ac.textSecondary))
                  else
                    DropdownButtonFormField<int>(
                      value: _kbId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                          isDense: true, contentPadding: EdgeInsets.all(NatsumeSpace.sm)),
                      items: [
                        for (final b in _bases)
                          DropdownMenuItem(
                            value: b.id!,
                            child: Text(b.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) => setState(() => _kbId = v),
                    ),
                  const SizedBox(height: NatsumeSpace.sm),
                  Text('题库名', style: NatsumeType.captionStyle.copyWith(color: ac.textTertiary)),
                  const SizedBox(height: NatsumeSpace.xs),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(isDense: true),
                  ),
                  const SizedBox(height: NatsumeSpace.sm),
                  Text('题目数量', style: NatsumeType.captionStyle.copyWith(color: ac.textTertiary)),
                  const SizedBox(height: NatsumeSpace.xs),
                  NatsumeSegmentedControl<int>(
                    segments: const [
                      (5, '5'),
                      (10, '10'),
                      (20, '20'),
                      (50, '50'),
                    ],
                    value: _targetCount,
                    onChanged: (v) => setState(() => _targetCount = v),
                  ),
                  const SizedBox(height: NatsumeSpace.md),
                  NatsumeButton(
                    label: _running ? '生成中…' : '开始生成',
                    expand: true,
                    icon: Icons.auto_awesome,
                    onPressed: _running || _kbId == null ? null : _run,
                  ),
                ],
              ),
            ),
            if (_log.isNotEmpty) ...[
              const SizedBox(height: NatsumeSpace.md),
              NatsumeSectionHeader(title: '过程日志'),
              const SizedBox(height: NatsumeSpace.sm),
              NatsumeSurface(
                tone: NatsumeTone.alt,
                padding: const EdgeInsets.all(NatsumeSpace.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final l in _log)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: NatsumeSpace.xxs),
                        child: Text(l,
                            style: NatsumeType.microStyle
                                .copyWith(color: ac.textSecondary)),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
