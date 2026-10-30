import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/question.dart';
import '../models/question_bank.dart';
import '../models/question_edit.dart';
import '../services/app_state.dart';
import '../services/quiz_launcher.dart';
import '../services/theme_service.dart';
import '../utils/app_constants.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';
import '../widgets/question_edit_dialog.dart';

/// 题库内题目管理（v1.30.2）。
///
/// 用户反馈原文：「编辑不只是在导入过程中可以编辑，是导入完毕之后也能进入
/// 管理题库中去编辑已经导入的题目，可以移动删改之类的操作」。
/// 此前题库管理页只有「选中 / 导出 / 删库」三件事，题目一旦落库就只能靠
/// 重新导入覆盖——本页补齐单题维度的 改 / 删 / 移（并支持批量）。
///
/// v1.31（2026-10-29）用户要求：从管理题库点进题库后，第一眼要看到
/// 「题号方块网格」（像日历），先选模式（正常刷题 / 练习 / 背题）再点题号
/// 直接开始刷题——所以本页有两个视图：
/// - [BankQuestionView.grid]（默认）：题号网格 + 模式选择，点方块即开刷；
/// - [BankQuestionView.list]：原有的搜索/筛选/改/删/移管理列表。
class BankQuestionsScreen extends StatefulWidget {
  const BankQuestionsScreen({super.key, required this.bank});

  final QuestionBank bank;

  @override
  State<BankQuestionsScreen> createState() => _BankQuestionsScreenState();
}

/// 题库页的两个视图：题号网格（刷题入口）/ 管理列表（编辑入口）
enum BankQuestionView { grid, list }

/// 单题操作菜单
enum _QuestionAction { edit, move, delete }

class _BankQuestionsScreenState extends State<BankQuestionsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  List<Question> _questions = const [];
  bool _loading = true;
  String _query = '';
  String? _typeFilter;
  bool _selectMode = false;

  /// 当前视图：默认题号网格（用户要求「点进题库就能看见题号方块」）
  BankQuestionView _viewMode = BankQuestionView.grid;

  /// 题号格子里点一下要用哪种模式开刷（与自由选题面板共用 [QuizLaunchMode]）
  QuizLaunchMode _launchMode = QuizLaunchMode.quiz;

  /// 批量操作选中的题目 id（选中态只存 id：编辑/删除后要按 id 对齐）
  final Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 重新拉取题库内容（编辑/删除/移动/AI 补写后都要重载）
  Future<void> _load() async {
    final app = context.read<AppState>();
    setState(() => _loading = true);
    final list = await app.getBankQuestions(widget.bank.id!);
    if (!mounted) return;
    setState(() {
      _questions = list;
      _loading = false;
      // 已删掉的题不能留在选中集合里，否则批量操作会对着空气发指令
      final ids = {for (final q in list) q.id ?? -1};
      _selectedIds.removeWhere((id) => !ids.contains(id));
    });
  }

  /// 题型筛选项（只列当前题库真实存在的题型，避免一排空筛选项）
  List<String> get _typeOptions {
    final seen = <String>{};
    for (final q in _questions) {
      seen.add(q.questionType);
    }
    return seen.toList()..sort();
  }

  /// 搜索（题干 / 知识点 / 答案）+ 题型过滤
  List<Question> get _filtered {
    final keyword = _query.trim().toLowerCase();
    return _questions.where((q) {
      if (_typeFilter != null && q.questionType != _typeFilter) return false;
      if (keyword.isEmpty) return true;
      return q.title.toLowerCase().contains(keyword) ||
          (q.knowledgePoint ?? '').toLowerCase().contains(keyword) ||
          q.correctAnswer.toLowerCase().contains(keyword);
    }).toList();
  }

  bool get _allVisibleSelected {
    final visible = _filtered;
    return visible.isNotEmpty &&
        visible.every((q) => _selectedIds.contains(q.id));
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
  // ======================== 单题动作 ========================

  Future<void> _edit(Question q) async {
    final app = context.read<AppState>();
    QuestionEditResult? result;
    await showDialog<void>(
      context: context,
      builder: (_) => QuestionEditDialog(
        question: q,
        onSave: (r) => result = r,
      ),
    );
    if (result == null) return;
    await app.updateQuestionById(q, result!);
    await _load();
    _toast('已保存修改');
  }

  Future<void> _create() async {
    final app = context.read<AppState>();
    QuestionEditResult? result;
    // 空壳题目：选择题先给两个空槽，用户直接填 A/B 即可
    final draft = Question(
      bankId: widget.bank.id!,
      title: '',
      options: const ['', ''],
      correctAnswer: '',
      createdAt: DateTime.now().toIso8601String(),
    );
    await showDialog<void>(
      context: context,
      builder: (_) => QuestionEditDialog(
        question: draft,
        title: '新建题目',
        onSave: (r) => result = r,
      ),
    );
    if (result == null) return;
    await app.createQuestion(widget.bank.id!, result!);
    await _load();
    _toast('已添加 1 道题目');
  }

  Future<void> _delete(List<int> ids) async {
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ids.length == 1 ? '删除这道题？' : '删除 ${ids.length} 道题目？'),
        content:
            const Text('题目的作答记录、错题本条目与复习计划会一并删除，且无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final app = context.read<AppState>();
    await app.deleteQuestions(ids);
    if (mounted) {
      setState(() {
        _selectedIds.clear();
        _selectMode = false;
      });
    }
    await _load();
    _toast('已删除 ${ids.length} 道题目');
  }

  /// 移动题目：目标题库从 AppState 现取（排除当前库，同库移动无意义）
  Future<void> _move(List<int> ids) async {
    if (ids.isEmpty) return;
    final app = context.read<AppState>();
    final targets = app.banks.where((b) => b.id != widget.bank.id).toList();
    if (targets.isEmpty) {
      _toast('只有一个题库，先新建一个题库才能移动');
      return;
    }
    final targetId = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) {
        final ac = AppThemeColors.of(ctx);
        return SafeArea(
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kSheetMaxWidth),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: NatsumeSpace.sm),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: NatsumeSpace.md,
                        vertical: NatsumeSpace.xs),
                    child: Text(
                      '移动 ${ids.length} 道题目到…',
                      style: NatsumeType.h3Style.copyWith(
                          fontWeight: FontWeight.w600,
                          color: ac.textPrimary),
                    ),
                  ),
                  for (final b in targets)
                    ListTile(
                      leading: Icon(Icons.library_books_outlined,
                          color: ac.accent, size: 20),
                      title: Text(b.name,
                          style: TextStyle(
                              fontSize: NatsumeType.body,
                              color: ac.textPrimary)),
                      subtitle: Text('${b.questionCount} 道题目',
                          style: NatsumeType.captionStyle
                              .copyWith(color: ac.textSecondary)),
                      onTap: () => Navigator.pop(ctx, b.id),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (targetId == null) return;
    final moved = await app.moveQuestions(ids, targetId);
    if (mounted) {
      setState(() {
        _selectedIds.clear();
        _selectMode = false;
      });
    }
    await _load();
    _toast('已移动 $moved 道题目');
  }

  void _toggleSelect(Question q) {
    final id = q.id;
    if (id == null) return;
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  void _toggleSelectAll() {
    final visible = _filtered.map((q) => q.id).whereType<int>().toSet();
    setState(() {
      if (_allVisibleSelected) {
        _selectedIds.removeAll(visible);
      } else {
        _selectedIds.addAll(visible);
      }
    });
  }

  void _enterSelectMode([Question? q]) {
    setState(() {
      _selectMode = true;
      final id = q?.id;
      if (id != null) _selectedIds.add(id);
    });
  }

  void _exitSelectMode() => setState(() {
        _selectMode = false;
        _selectedIds.clear();
      });
  // ======================== 界面 ========================

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    // 题库名 / 题数取 AppState 最新值（本页增删改后计数会变）
    final bank = context.watch<AppState>().banks.firstWhere(
          (b) => b.id == widget.bank.id,
          orElse: () => widget.bank,
        );
    return Scaffold(
      backgroundColor: ac.background,
      appBar: _selectMode ? _buildSelectionAppBar() : _buildAppBar(ac, bank),
      body: ResponsivePage(
        child: Column(
          children: [
            if (_viewMode == BankQuestionView.list) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    NatsumeSpace.md, NatsumeSpace.sm, NatsumeSpace.md, 0),
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索题干 / 知识点 / 答案',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空搜索',
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                          ),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              if (_typeOptions.length > 1) _buildTypeFilter(ac),
              Expanded(child: _buildBody(ac, _filtered)),
            ] else
              Expanded(child: _buildGridBody(ac)),
          ],
        ),
      ),
      floatingActionButton: _loading || _viewMode == BankQuestionView.grid
          ? null
          : FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('新建题目'),
            ),
    );
  }

  // ════════════════════ 题号网格（刷题入口） ════════════════════

  /// 题号网格：像日历一样一方块一个题号，方块里只有题号。
  ///
  /// 点方块 = 用当前选定模式「只刷这个题库、从这道题开始」。
  /// 题号与题目一一对应靠的是 `noShuffle: true`：抽题顺序 == 题库原始顺序，
  /// 否则随机抽题时「第 7 个方块」未必是第 7 题。
  Widget _buildGridBody(AppThemeColors ac) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_questions.isEmpty) {
      return NatsumeEmptyState(
        icon: Icons.playlist_add,
        title: '这个题库还没有题目',
        description: '导入题目或手动新建一道，之后这里会出现可点的题号方块',
        action:
            NatsumeButton(label: '新建题目', icon: Icons.add, onPressed: _create),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              NatsumeSpace.md, NatsumeSpace.sm, NatsumeSpace.md, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('刷题模式',
                  style: NatsumeType.captionStyle
                      .copyWith(color: ac.textSecondary)),
              const SizedBox(height: NatsumeSpace.xs),
              Wrap(
                spacing: NatsumeSpace.xs,
                runSpacing: NatsumeSpace.xs,
                children: [
                  for (final mode in QuizLaunchMode.values)
                    NatsumeChip(
                      label: mode.label,
                      dense: true,
                      selected: _launchMode == mode,
                      onTap: () => setState(() => _launchMode = mode),
                    ),
                ],
              ),
              const SizedBox(height: NatsumeSpace.xxs),
              Text(_launchMode.description,
                  style: NatsumeType.microStyle
                      .copyWith(color: ac.textTertiary)),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(
                NatsumeSpace.md, NatsumeSpace.sm, NatsumeSpace.md, NatsumeSpace.md),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 54,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 1,
            ),
            itemCount: _questions.length,
            itemBuilder: (context, index) => _buildNumberCell(ac, index),
          ),
        ),
      ],
    );
  }

  /// 单个题号方块（Material 承载底/水波，避免调试期的「水波不可见」断言）
  Widget _buildNumberCell(AppThemeColors ac, int index) {
    return Material(
      color: ac.surface,
      borderRadius: NatsumeRadius.smallBorder,
      child: InkWell(
        borderRadius: NatsumeRadius.smallBorder,
        onTap: () => _startAt(index),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: NatsumeRadius.smallBorder,
            border: Border.all(color: ac.border, width: NatsumeLine.width),
          ),
          child: Text(
            '${index + 1}',
            style: NatsumeType.bodyStyle.copyWith(
              color: ac.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  /// 点题号开刷：题库范围固定为当前库，题量「全部」，从该题开始。
  Future<void> _startAt(int index) async {
    final app = context.read<AppState>();
    final bankId = widget.bank.id;
    if (bankId == null) return;
    final error = await QuizLauncher.launch(
      context,
      app,
      mode: _launchMode,
      bankIds: {bankId},
      count: kQuestionCountAll,
      startIndex: index,
      noShuffle: true,
    );
    if (error != null) _toast(error);
  }

  PreferredSizeWidget _buildAppBar(AppThemeColors ac, QuestionBank bank) {
    final grid = _viewMode == BankQuestionView.grid;
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(bank.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            grid
                ? '${_questions.length} 道题目 · 点题号开始刷题'
                : '${_questions.length} 道题目 · 点题目即可编辑',
            style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: grid ? '切换到列表（编辑题目）' : '切换到题号网格',
          icon: Icon(grid ? Icons.view_list_rounded : Icons.grid_view_rounded),
          onPressed: () => setState(() {
            _viewMode =
                grid ? BankQuestionView.list : BankQuestionView.grid;
          }),
        ),
        if (!grid)
          IconButton(
            tooltip: '批量选择',
            icon: const Icon(Icons.checklist),
            onPressed: _questions.isEmpty ? null : () => _enterSelectMode(),
          ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    final ids = _selectedIds.toList();
    final has = ids.isNotEmpty;
    return AppBar(
      leading: IconButton(
        tooltip: '退出多选',
        icon: const Icon(Icons.close),
        onPressed: _exitSelectMode,
      ),
      title: Text('已选 ${ids.length} 道'),
      actions: [
        IconButton(
          tooltip: _allVisibleSelected ? '取消全选' : '全选当前筛选结果',
          icon: Icon(_allVisibleSelected ? Icons.deselect : Icons.select_all),
          onPressed: _filtered.isEmpty ? null : _toggleSelectAll,
        ),
        IconButton(
          tooltip: '移动到其他题库',
          icon: const Icon(Icons.drive_file_move_outline),
          onPressed: has ? () => _move(ids) : null,
        ),
        IconButton(
          tooltip: '删除所选',
          icon: const Icon(Icons.delete_outline),
          onPressed: has ? () => _delete(ids) : null,
        ),
      ],
    );
  }

  Widget _buildTypeFilter(AppThemeColors ac) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: NatsumeSpace.md, vertical: 6),
        children: [
          _typeChip(ac, label: '全部', value: null),
          for (final t in _typeOptions)
            _typeChip(ac, label: Question.labelOfType(t), value: t),
        ],
      ),
    );
  }

  Widget _typeChip(AppThemeColors ac,
      {required String label, required String? value}) {
    final selected = _typeFilter == value;
    return Padding(
      padding: const EdgeInsets.only(right: NatsumeSpace.xs),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _typeFilter = value),
        labelStyle: NatsumeType.captionStyle.copyWith(
            color: selected ? ac.onAccent : ac.textSecondary),
        selectedColor: ac.accent,
        backgroundColor: ac.surfaceAlt,
        side: BorderSide(color: selected ? ac.accent : ac.border),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
  Widget _buildBody(AppThemeColors ac, List<Question> filtered) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_questions.isEmpty) {
      return NatsumeEmptyState(
        icon: Icons.playlist_add,
        title: '这个题库还没有题目',
        description: '导入题目或手动新建一道，之后随时能在这里改 / 删 / 移动',
        action:
            NatsumeButton(label: '新建题目', icon: Icons.add, onPressed: _create),
      );
    }
    if (filtered.isEmpty) {
      return NatsumeEmptyState(
        icon: Icons.search_off,
        title: '没有匹配的题目',
        description: '换个关键词，或点「全部」清掉题型筛选',
        action: NatsumeButton(
          label: '清空筛选',
          icon: Icons.filter_alt_off,
          onPressed: () {
            _searchCtrl.clear();
            setState(() {
              _query = '';
              _typeFilter = null;
            });
          },
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          NatsumeSpace.md, NatsumeSpace.sm, NatsumeSpace.md, 96),
      itemCount: filtered.length,
      itemBuilder: (context, i) => _buildTile(ac, filtered[i], i),
    );
  }

  Widget _buildTile(AppThemeColors ac, Question q, int index) {
    final id = q.id;
    if (id == null) return const SizedBox.shrink();
    final selected = _selectedIds.contains(id);
    final answer = q.correctAnswer.trim();
    final knowledgePoint = (q.knowledgePoint ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: NatsumeSpace.xs),
      child: GestureDetector(
        // 长按进多选：单题删除/移动之外，常见诉求是「把这一批挪走」
        onLongPress: _selectMode ? null : () => _enterSelectMode(q),
        child: NatsumeSurface(
          accentEdge: selected,
          padding: const EdgeInsets.all(NatsumeSpace.sm),
          onTap: _selectMode ? () => _toggleSelect(q) : () => _edit(q),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_selectMode)
                Padding(
                  padding: const EdgeInsets.only(right: NatsumeSpace.sm, top: 2),
                  child: _selectBox(ac, selected),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('${index + 1}.',
                            style: NatsumeType.microStyle
                                .copyWith(color: ac.textTertiary)),
                        NatsumeTag(q.typeLabel, tone: NatsumeTagTone.accent),
                        if (knowledgePoint.isNotEmpty)
                          NatsumeTag(knowledgePoint),
                        if (q.images.isNotEmpty)
                          Icon(Icons.image_outlined,
                              size: 14, color: ac.textTertiary),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      // 题干里的配图占位符在列表里显示成「［图］」，免得一串花括号
                      q.title.replaceAll(RegExp(r'\{\{img:\d+\}\}'), '［图］'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: NatsumeType.body, color: ac.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '答案 ${answer.isEmpty ? '（未填写）' : answer}'
                      '${q.options.isNotEmpty ? ' · ${q.options.length} 个选项' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NatsumeType.captionStyle
                          .copyWith(color: ac.textSecondary),
                    ),
                  ],
                ),
              ),
              if (!_selectMode)
                PopupMenuButton<_QuestionAction>(
                  tooltip: '更多操作',
                  icon:
                      Icon(Icons.more_horiz, color: ac.textSecondary, size: 20),
                  onSelected: (action) {
                    switch (action) {
                      case _QuestionAction.edit:
                        _edit(q);
                      case _QuestionAction.move:
                        _move([id]);
                      case _QuestionAction.delete:
                        _delete([id]);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: _QuestionAction.edit, child: Text('编辑')),
                    PopupMenuItem(
                        value: _QuestionAction.move, child: Text('移动到…')),
                    PopupMenuItem(
                        value: _QuestionAction.delete, child: Text('删除')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectBox(AppThemeColors ac, bool selected) => Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: selected ? ac.accent : Colors.transparent,
          border:
              Border.all(color: selected ? ac.accent : ac.border, width: 1.2),
          borderRadius: NatsumeRadius.chipBorder,
        ),
        child:
            selected ? Icon(Icons.check, size: 12, color: ac.onAccent) : null,
      );
}
