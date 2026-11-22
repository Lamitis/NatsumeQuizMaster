import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/kb_document.dart';
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

/// 自动出题（v13 · 学 dsh；v1.44 重构出题范围）。
///
/// 选一个知识库 → **可再限定到其中某几篇文档** → 题型与数量都可自定义 →
/// 跑 Agent：AI 只依据范围内的资料出题，把结果写入自己的沙箱 JSON，
/// 再导入成题库。
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

  /// 题目数量允许区间。上限压到 200：再多必然要跑很多批工具循环，
  /// 中途断一次整批就白跑，体验上不如分开生成。
  static const int _minCount = 1;
  static const int _maxCount = 200;

  List<KnowledgeBase> _bases = [];

  /// 当前知识库下的文档（v1.44：可从中勾选「只出这几篇」）
  List<KbDocument> _docs = [];
  bool _loadingDocs = false;

  int? _kbId;

  /// 勾选的文档 id；**空集 = 整个知识库**（与旧行为一致）
  final Set<int> _selectedDocIds = {};

  /// 勾选的题型 id；**空集 = 交给 AI 自行搭配**（与旧行为一致）
  final Set<String> _types = {};

  bool _running = false;
  final List<String> _log = [];
  final TextEditingController _nameController =
      TextEditingController(text: 'AI 生成题库');
  final TextEditingController _countController = TextEditingController(text: '10');

  @override
  void initState() {
    super.initState();
    _loadBases();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _countController.dispose();
    super.dispose();
  }

  Future<void> _loadBases() async {
    final bases = await _kb.listKnowledgeBases();
    if (!mounted) return;
    setState(() {
      _bases = bases;
      if (_kbId == null && bases.isNotEmpty) _kbId = bases.first.id;
    });
    await _loadDocs();
  }

  /// 切知识库 / 首次进入时加载文档列表，并清掉上一份选择。
  Future<void> _loadDocs() async {
    final kbId = _kbId;
    if (kbId == null) {
      if (mounted) setState(() => _docs = []);
      return;
    }
    setState(() => _loadingDocs = true);
    List<KbDocument> docs;
    try {
      docs = await _kb.listDocuments(kbId);
    } catch (_) {
      docs = const [];
    }
    if (!mounted) return;
    setState(() {
      _docs = docs;
      _selectedDocIds.clear();
      _loadingDocs = false;
    });
  }

  int get _count {
    final v = int.tryParse(_countController.text.trim()) ?? 0;
    return v;
  }

  bool get _countValid => _count >= _minCount && _count <= _maxCount;

  Future<void> _run() async {
    // 防伪：检测到二次打包时静默限制 AI 出题（高级功能）
    if (IntegrityService.advancedFeaturesLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('检测到应用被二次打包，AI 出题已受限')));
      return;
    }
    if (!_countValid) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('题目数量请填 $_minCount~$_maxCount 之间的整数')));
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
    // 选中的文档名（提示词里要写清楚范围，避免模型串台）
    final selectedNames = [
      for (final d in _docs)
        if (d.id != null && _selectedDocIds.contains(d.id)) d.name,
    ];
    final orderedTypes = [
      for (final t in kGeneratorQuestionTypes)
        if (_types.contains(t.id)) t.id,
    ];
    GeneratorResult result;
    try {
      result = await agent.generate(
        kbId: _kbId!,
        targetCount: _count,
        bankName: _nameController.text.trim().isEmpty
            ? 'AI 生成题库'
            : _nameController.text.trim(),
        documentIds: _selectedDocIds.toList(),
        documentNames: selectedNames,
        questionTypes: orderedTypes,
        sandboxDir: sandbox,
        onLog: (m) {
          if (mounted) setState(() => _log.add(m));
        },
      );
    } catch (e) {
      // 兜底：工具执行/JSON 解析再出意外也不让整次生成炸掉，给可操作的提示
      if (!mounted) return;
      setState(() {
        _running = false;
        _log.add('生成失败：$e');
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('AI 出题遇到格式问题，请缩小出题范围或减少题目数量后重试'),
        duration: Duration(seconds: 5),
      ));
      return;
    }

    var imported = 0;
    var skipped = 0;
    if (result.bankFilePath != null && result.questionCount > 0) {
      final outcome = await _importResult(result.bankFilePath!, appState);
      imported = outcome.imported;
      skipped = outcome.skipped;
      if (mounted && imported > 0) {
        setState(() => _log
            .add('题库文件：${ExportStorage.folderOf(result.bankFilePath!)}'));
      }
    }

    if (!mounted) return;
    setState(() => _running = false);
    final String msg;
    if (imported > 0) {
      msg = '已生成并导入 $imported 道题';
    } else if (skipped > 0) {
      // 内容与已有题库完全一致：这不是故障，别报「格式错误」吓用户
      msg = '题库内容与已有题库重复，已跳过导入';
    } else {
      final reason = result.failureReason ?? '未生成出有效题目';
      msg = '$reason\n请缩小出题范围或减少题目数量后重试（过程日志里可看到每次工具调用）';
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 6),
    ));
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
  /// 返回 (导入题数, 因内容重复被跳过的题库数)（v1.41.4）：后者用于把
  /// 「内容与已有题库一致」和「真的一道题都没生成」区分开。
  Future<({int imported, int skipped})> _importResult(
      String path, AppState appState) async {
    File? tmp;
    try {
      final raw = await File(path).readAsString();
      final data = jsonDecode(raw);
      final questions = data is Map
          ? (data['questions'] ?? const [])
          : (data is List ? data : const []);
      if (questions is! List || questions.isEmpty) {
        return (imported: 0, skipped: 0);
      }
      tmp = File('$path.import.json');
      await tmp.writeAsString(jsonEncode({
        'format': BankFileService.formatMarker,
        'name': _nameController.text.trim().isEmpty
            ? 'AI 生成题库'
            : _nameController.text.trim(),
        'questions': questions,
      }));
      // 同名自动加后缀；内容完全一致的题库会被去重跳过（不再堆出重复题库）
      final outcome = await BankFileService.importBankFile(tmp.path,
          existingNames: appState.banks.map((b) => b.name).toSet());
      if (outcome.bankCount > 0) await appState.refreshBanks();
      return (imported: outcome.questionCount, skipped: outcome.skippedCount);
    } catch (_) {
      return (imported: 0, skipped: 0);
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
                  Text('AI 只依据所选范围内的资料出题，资料未覆盖的内容不会编造。',
                      style:
                          NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
                  const SizedBox(height: NatsumeSpace.md),

                  // ── 知识库 ──────────────────────────────────────────
                  _label('知识库', ac),
                  if (_bases.isEmpty)
                    Text('尚无知识库，请先到「知识库」导入资料。',
                        style:
                            NatsumeType.captionStyle.copyWith(color: ac.textSecondary))
                  else
                    DropdownButtonFormField<int>(
                      value: _kbId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.all(NatsumeSpace.sm)),
                      items: [
                        for (final b in _bases)
                          DropdownMenuItem(
                            value: b.id!,
                            child: Text(b.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: _running
                          ? null
                          : (v) {
                              if (v == _kbId) return;
                              setState(() => _kbId = v);
                              _loadDocs();
                            },
                    ),
                  const SizedBox(height: NatsumeSpace.sm),

                  // ── 出题范围（v1.44）───────────────────────────────
                  Row(
                    children: [
                      _label('出题范围', ac),
                      const Spacer(),
                      if (_docs.isNotEmpty)
                        Text(
                          _selectedDocIds.isEmpty
                              ? '全部 ${_docs.length} 篇'
                              : '已选 ${_selectedDocIds.length} 篇',
                          style: NatsumeType.captionStyle
                              .copyWith(color: ac.textTertiary),
                        ),
                    ],
                  ),
                  if (_loadingDocs)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: NatsumeSpace.sm),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (_docs.isEmpty)
                    Text('这个知识库还没有文档，出题将无法引用资料。',
                        style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary))
                  else ...[
                    Wrap(
                      spacing: NatsumeSpace.xs,
                      runSpacing: NatsumeSpace.xxs,
                      children: [
                        NatsumeChip(
                          label: '整个知识库',
                          dense: true,
                          selected: _selectedDocIds.isEmpty,
                          onTap: _running
                              ? null
                              : () => setState(_selectedDocIds.clear),
                        ),
                        for (final d in _docs)
                          NatsumeChip(
                            // 文档名可能很长（扫描件带日期），截断到 12 字保持一行
                            label: d.name.length > 12
                                ? '${d.name.substring(0, 12)}…'
                                : d.name,
                            dense: true,
                            selected: d.id != null &&
                                _selectedDocIds.contains(d.id),
                            onTap: _running || d.id == null
                                ? null
                                : () => setState(() {
                                      if (!_selectedDocIds.remove(d.id)) {
                                        _selectedDocIds.add(d.id!);
                                      }
                                    }),
                          ),
                      ],
                    ),
                    const SizedBox(height: NatsumeSpace.xxs),
                    Text(
                      _selectedDocIds.isEmpty
                          ? '不选具体文件 = 用整个知识库的资料出题。'
                          : '只在这 ${_selectedDocIds.length} 篇文档里检索与出题，范围外的资料不会被使用。',
                      style: NatsumeType.captionStyle
                          .copyWith(color: ac.textTertiary, height: 1.4),
                    ),
                  ],
                  const SizedBox(height: NatsumeSpace.md),

                  // ── 题型（v1.44）───────────────────────────────────
                  _label('题型', ac),
                  Wrap(
                    spacing: NatsumeSpace.xs,
                    runSpacing: NatsumeSpace.xxs,
                    children: [
                      for (final t in kGeneratorQuestionTypes)
                        NatsumeChip(
                          label: t.label,
                          dense: true,
                          selected: _types.contains(t.id),
                          onTap: _running
                              ? null
                              : () => setState(() {
                                    if (!_types.remove(t.id)) _types.add(t.id);
                                  }),
                        ),
                    ],
                  ),
                  const SizedBox(height: NatsumeSpace.xxs),
                  Text(
                    _types.isEmpty
                        ? '不选题型 = 交给 AI 自行搭配（以单选为主，可含多选/判断/填空）。'
                        : '只出 ${_types.map(generatorTypeLabel).join('、')}，数量在各题型间尽量均衡。',
                    style: NatsumeType.captionStyle
                        .copyWith(color: ac.textTertiary, height: 1.4),
                  ),
                  const SizedBox(height: NatsumeSpace.md),

                  // ── 题目数量（v1.44：可选预设，也可手填）─────────────
                  _label('题目数量', ac),
                  Row(
                    children: [
                      SizedBox(
                        width: 96,
                        child: TextField(
                          controller: _countController,
                          enabled: !_running,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(3),
                          ],
                          decoration: const InputDecoration(
                            isDense: true,
                            suffixText: '题',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: NatsumeSpace.sm),
                      Expanded(
                        child: Wrap(
                          spacing: NatsumeSpace.xxs,
                          children: [
                            for (final n in const [5, 10, 20, 50])
                              NatsumeChip(
                                label: '$n',
                                dense: true,
                                selected: _count == n,
                                onTap: _running
                                    ? null
                                    : () => setState(() {
                                          _countController.text = '$n';
                                        }),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (!_countValid)
                    Padding(
                      padding: const EdgeInsets.only(top: NatsumeSpace.xxs),
                      child: Text('请填 $_minCount~$_maxCount 之间的整数',
                          style: NatsumeType.captionStyle
                              .copyWith(color: ac.danger)),
                    ),
                  const SizedBox(height: NatsumeSpace.md),

                  // ── 题库名 ─────────────────────────────────────────
                  _label('题库名', ac),
                  TextField(
                    controller: _nameController,
                    enabled: !_running,
                    decoration: const InputDecoration(isDense: true),
                  ),
                  const SizedBox(height: NatsumeSpace.md),
                  NatsumeButton(
                    label: _running ? '生成中…' : '开始生成',
                    expand: true,
                    icon: Icons.auto_awesome,
                    onPressed:
                        _running || _kbId == null || !_countValid ? null : _run,
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

  Widget _label(String text, AppThemeColors ac) => Padding(
        padding: const EdgeInsets.only(bottom: NatsumeSpace.xs),
        child: Text(text,
            style: NatsumeType.captionStyle.copyWith(
                color: ac.textTertiary, fontWeight: FontWeight.w600)),
      );
}
