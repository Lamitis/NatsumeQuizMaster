import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/bank_category.dart';
import '../models/question_bank.dart';
import '../services/app_state.dart';
import '../services/bank_file_service.dart';
import '../services/export_storage.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';
import 'bank_questions_screen.dart';
import 'import_screen.dart';

/// 题库管理页：**分类树 + 题库卡**。
///
/// v15 起题库可以挂到用户自建的分类树下（任意层级、可折叠、整支可移动）。
/// 渲染上把「树」摊平成行列表：分类行 + 其下的题库卡，靠 `depth` 缩进表达
/// 层级——比嵌套 ListView 好写，滚动与展开状态也不会互相打架。
class BankManageScreen extends StatefulWidget {
  const BankManageScreen({super.key});

  @override
  State<BankManageScreen> createState() => _BankManageScreenState();
}

/// 摊平后的行（树 → 线性列表）
sealed class _Row {
  const _Row();
}

class _CategoryRow extends _Row {
  const _CategoryRow(this.category, this.depth, this.bankCount,
      this.questionCount, this.expanded);
  final BankCategory category;
  final int depth;
  final int bankCount;
  final int questionCount;
  final bool expanded;
}

class _BankRow extends _Row {
  const _BankRow(this.bank, this.depth);
  final QuestionBank bank;
  final int depth;
}

/// 「未分类」分组标题（只有存在分类时才出现）
class _GroupRow extends _Row {
  const _GroupRow(this.label);
  final String label;
}

/// 选分类对话框的返回值：`null`（对话框被取消）与 `id == null`（选根/未分类）
/// 必须区分开，所以包一层。
class _CategoryChoice {
  const _CategoryChoice(this.id);
  final int? id;
}

class _BankManageScreenState extends State<BankManageScreen> {
  /// 收起的分类 id（默认全展开）。纯 UI 状态，不落库。
  final Set<int> _collapsed = {};

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: const Text('题库管理'),
        actions: [
          IconButton(
            tooltip: '新建分类',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () => _createCategory(context.read<AppState>(), null),
          ),
          IconButton(
            tooltip: '导入题库',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ImportScreen()),
            ),
          ),
        ],
      ),
      body: ResponsivePage(
        child: Consumer<AppState>(
          builder: (context, appState, _) {
            if (appState.banks.isEmpty && appState.categories.isEmpty) {
              return _buildEmptyState(appState, ac);
            }
            final rows = _buildRows(appState);
            return Column(
              children: [
                _buildQuizSettings(appState, ac),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: rows.length,
                    itemBuilder: (context, index) =>
                        _buildRow(appState, rows[index], ac),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ======================== 树 → 行 ========================

  List<_Row> _buildRows(AppState appState) {
    final childrenOf = <int?, List<BankCategory>>{};
    for (final c in appState.categories) {
      childrenOf.putIfAbsent(c.parentId, () => []).add(c);
    }
    final banksOf = <int?, List<QuestionBank>>{};
    for (final b in appState.banks) {
      banksOf.putIfAbsent(b.categoryId, () => []).add(b);
    }

    /// 分类（含子分类）下的题库数 / 题目数——父分类行要给出「整支」口径
    ({int banks, int questions}) tally(int categoryId) {
      var bankCount = 0;
      var questionCount = 0;
      for (final bank in banksOf[categoryId] ?? const <QuestionBank>[]) {
        bankCount++;
        questionCount += bank.questionCount;
      }
      for (final child in childrenOf[categoryId] ?? const <BankCategory>[]) {
        final t = tally(child.id!);
        bankCount += t.banks;
        questionCount += t.questions;
      }
      return (banks: bankCount, questions: questionCount);
    }

    final rows = <_Row>[];
    void addCategory(int? parentId, int depth) {
      for (final c in childrenOf[parentId] ?? const <BankCategory>[]) {
        final t = tally(c.id!);
        final expanded = !_collapsed.contains(c.id);
        rows.add(_CategoryRow(c, depth, t.banks, t.questions, expanded));
        if (!expanded) continue;
        for (final bank in banksOf[c.id] ?? const <QuestionBank>[]) {
          rows.add(_BankRow(bank, depth + 1));
        }
        addCategory(c.id, depth + 1);
      }
    }

    addCategory(null, 0);

    final loose = banksOf[null] ?? const <QuestionBank>[];
    if (loose.isNotEmpty) {
      // 有分类时才需要「未分类」这层标签；完全没建分类就是原来的平铺列表
      if (appState.categories.isNotEmpty) rows.add(const _GroupRow('未分类'));
      for (final bank in loose) {
        rows.add(_BankRow(bank, 0));
      }
    }
    return rows;
  }

  Widget _buildRow(AppState appState, _Row row, AppThemeColors ac) {
    switch (row) {
      case _GroupRow():
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Text(row.label,
              style: TextStyle(
                  fontSize: NatsumeType.body,
                  fontWeight: FontWeight.w600,
                  color: ac.textSecondary)),
        );
      case _CategoryRow():
        final category = row.category;
        return _CategoryTile(
          category: category,
          depth: row.depth,
          bankCount: row.bankCount,
          questionCount: row.questionCount,
          expanded: row.expanded,
          onToggle: () => setState(() {
            final id = category.id!;
            if (!_collapsed.remove(id)) _collapsed.add(id);
          }),
          onNewChild: () => _createCategory(appState, category.id),
          onRename: () => _renameCategory(appState, category),
          onMove: () => _moveCategory(appState, category),
          onDelete: () => _deleteCategory(appState, category),
        );
      case _BankRow():
        final bank = row.bank;
        final isSelected = appState.selectedBankIds.contains(bank.id);
        return Padding(
          padding: EdgeInsets.only(left: row.depth * 18.0),
          child: _BankCard(
            bank: bank,
            isSelected: isSelected,
            onTap: () => appState.toggleBankSelection(bank.id!),
            onMove: () => _moveBankToCategory(appState, bank),
            onDelete: () => _confirmDelete(context, appState, bank),
            onExport: () => _exportBank(bank),
            onOpenQuestions: () => _openQuestions(appState, bank),
          ),
        );
    }
  }
  // ======================== 空态 / 顶部设置 ========================

  Widget _buildEmptyState(AppState appState, AppThemeColors ac) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.library_books_outlined, size: 64, color: ac.border),
          const SizedBox(height: 16),
          Text('还没有题库',
              style: TextStyle(fontSize: NatsumeType.h3, color: ac.textSecondary)),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.upload_file),
            label: const Text('导入题库'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ImportScreen()),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('先建一个分类'),
            onPressed: () => _createCategory(appState, null),
          ),
        ],
      ),
    );
  }

  Widget _buildQuizSettings(AppState appState, AppThemeColors ac) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: ac.surfaceAlt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune, size: 18, color: ac.accent),
              const SizedBox(width: 6),
              Text('刷题设置',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: NatsumeType.h3,
                      color: ac.textPrimary)),
              const Spacer(),
              Text(
                appState.selectedBankIds.isEmpty
                    ? '点击题目前方选择框'
                    : '已选 ${appState.selectedBankIds.length} 个题库',
                style:
                    TextStyle(fontSize: NatsumeType.body, color: ac.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('刷题模式: ',
                  style: TextStyle(
                      fontSize: NatsumeType.body, color: ac.textSecondary)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (appState.selectedBankIds.length > 1
                          ? ac.textSecondary
                          : ac.accent)
                      .withOpacity(0.12),
                  borderRadius: BorderRadius.circular(NatsumeRadius.chip),
                ),
                child: Text(
                  appState.selectedBankIds.length > 1 ? '混合刷题' : '单题库刷题',
                  style: TextStyle(
                    fontSize: NatsumeType.body,
                    color: appState.selectedBankIds.length > 1
                        ? ac.textSecondary
                        : ac.accent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  // ======================== 分类操作 ========================

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _promptCategoryName({
    required String title,
    String initial = '',
  }) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(
            labelText: '分类名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    ctrl.dispose();
    return (result == null || result.isEmpty) ? null : result;
  }

  Future<void> _createCategory(AppState appState, int? parentId) async {
    final name = await _promptCategoryName(
        title: parentId == null ? '新建分类' : '新建子分类');
    if (name == null) return;
    await appState.createBankCategory(name, parentId: parentId);
    // 新建子分类后把父分类展开，否则用户看不到刚建出来的东西
    if (parentId != null) setState(() => _collapsed.remove(parentId));
  }

  Future<void> _renameCategory(AppState appState, BankCategory category) async {
    final name =
        await _promptCategoryName(title: '重命名分类', initial: category.name);
    if (name == null) return;
    await appState.renameBankCategory(category.id!, name);
  }

  Future<void> _deleteCategory(AppState appState, BankCategory category) async {
    final ac = AppThemeColors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('确定删除分类「${category.name}」吗？\n'
            '里面的题库与子分类会「上移一级」，不会被删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: ac.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await appState.deleteBankCategory(category.id!);
  }

  Future<void> _moveCategory(AppState appState, BankCategory category) async {
    // 自己与所有后代都不可选：挂到后代下面会让树成环
    final pick = await _pickCategory(
      appState,
      title: '把「${category.name}」移动到',
      rootLabel: '移到根目录（顶层分类）',
      disabled: appState.categoryWithDescendants(category.id!),
    );
    if (pick == null) return;
    final moved = await appState.moveBankCategory(category.id!, pick.id);
    if (!moved) _snack('不能移动到它自己或它的子分类下');
  }

  Future<void> _moveBankToCategory(
      AppState appState, QuestionBank bank) async {
    final pick = await _pickCategory(
      appState,
      title: '把「${bank.name}」放进',
      rootLabel: '移出分类（未分类）',
    );
    if (pick == null) return;
    await appState.setBankCategory(bank.id!, pick.id);
  }
  /// 选分类弹窗（树形缩进）。取消返回 null；选根/未分类返回 `id == null`。
  Future<_CategoryChoice?> _pickCategory(
    AppState appState, {
    required String title,
    required String rootLabel,
    Set<int> disabled = const {},
  }) {
    final ac = AppThemeColors.of(context);
    final childrenOf = <int?, List<BankCategory>>{};
    for (final c in appState.categories) {
      childrenOf.putIfAbsent(c.parentId, () => []).add(c);
    }
    return showDialog<_CategoryChoice>(
      context: context,
      builder: (ctx) {
        final tiles = <Widget>[];
        void add(int? parentId, int depth) {
          for (final c in childrenOf[parentId] ?? const <BankCategory>[]) {
            final blocked = disabled.contains(c.id);
            tiles.add(InkWell(
              onTap: blocked
                  ? null
                  : () => Navigator.pop(ctx, _CategoryChoice(c.id)),
              child: Padding(
                padding: EdgeInsets.fromLTRB(16 + depth * 16.0, 12, 16, 12),
                child: Row(children: [
                  Icon(
                    blocked ? Icons.folder_off_outlined : Icons.folder_outlined,
                    size: 18,
                    color: blocked ? ac.border : ac.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(c.name,
                        style: TextStyle(
                            fontSize: NatsumeType.body,
                            color:
                                blocked ? ac.textTertiary : ac.textPrimary)),
                  ),
                ]),
              ),
            ));
            add(c.id, depth + 1);
          }
        }

        add(null, 0);

        return AlertDialog(
          title: Text(title),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: SizedBox(
            // 窄屏（360dp 手机）不能写死 360：左右还有对话框内边距，会横向溢出
            width: dialogContentWidth(ctx, max: 360),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: () =>
                        Navigator.pop(ctx, const _CategoryChoice(null)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Row(children: [
                        Icon(Icons.home_outlined,
                            size: 18, color: ac.textSecondary),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(rootLabel,
                                style: TextStyle(
                                    fontSize: NatsumeType.body,
                                    color: ac.textPrimary))),
                      ]),
                    ),
                  ),
                  const Divider(height: 1),
                  ...tiles,
                  if (tiles.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('还没有分类，先用右上角「新建分类」建一个',
                          style: TextStyle(
                              fontSize: NatsumeType.body,
                              color: ac.textTertiary)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ],
        );
      },
    );
  }
  // ======================== 题库操作 ========================

  void _confirmDelete(
      BuildContext context, AppState appState, QuestionBank bank) {
    final ac = AppThemeColors.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除题库"${bank.name}"吗？\n该题库下的所有题目也将被删除，此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              appState.deleteBank(bank.id!);
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: ac.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// v1.30.2：进入题库内部的题目管理（改 / 删 / 移动 / 新建）。
  ///
  /// 用户反馈「导入完毕之后也要能进管理题库编辑已导入的题目」。返回时
  /// 刷新一次题库列表，避免卡片上的题数还是进页面前的旧值。
  Future<void> _openQuestions(AppState appState, QuestionBank bank) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BankQuestionsScreen(bank: bank)),
    );
    if (!mounted) return;
    await appState.refreshBanks();
  }

  /// v1.0.2 扩展：导出题库（含打标签/解析的整理后字段）为 .json 并另存
  Future<void> _exportBank(QuestionBank bank) async {
    // 工作文件落在导出目录（而不是系统临时目录）：用户取消另存为时，
    // 还能自己按目录翻出来；Android 的临时目录普通文件管理器进不去。
    final dir = await ExportStorage.resolve();
    final path =
        '${dir.path}${Platform.pathSeparator}${bank.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.json';
    final result = await BankFileService.exportBank(bank.id!, bank.name, path);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (result == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('该题库没有题目，无法导出')),
      );
      return;
    }
    // v1.34：生成后直接「另存为」，由用户自己挑位置（不再走系统分享面板）
    final saved = await ExportStorage.saveFileAs(
      result,
      dialogTitle: '保存题库导出文件',
    );
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        // 取消（path == null）不报成功，也不报错：文件还在导出目录里
        content: Text(saved.saved
            ? '已导出 ${bank.questionCount} 道题目到 ${saved.path}'
            : '已取消保存。文件仍可在此找到：${ExportStorage.folderOf(result)}'),
        duration: const Duration(seconds: 5),
      ),
    );
  }
}
/// 分类行：折叠箭头 + 文件夹 + 名称 + 整支统计 + 改名/子分类/移动/删除
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.depth,
    required this.bankCount,
    required this.questionCount,
    required this.expanded,
    required this.onToggle,
    required this.onNewChild,
    required this.onRename,
    required this.onMove,
    required this.onDelete,
  });

  final BankCategory category;
  final int depth;
  final int bankCount;
  final int questionCount;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onNewChild;
  final VoidCallback onRename;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, bottom: NatsumeSpace.xs),
      child: Semantics(
        button: true,
        label: '分类 ${category.name}，$bankCount 个题库，$questionCount 道题目'
            '${expanded ? '，已展开' : '，已收起'}',
        child: NatsumeSurface(
          onTap: onToggle,
          padding: const EdgeInsets.symmetric(horizontal: NatsumeSpace.sm),
          child: Row(
            children: [
              Icon(expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 20, color: ac.textSecondary),
              const SizedBox(width: 2),
              Icon(Icons.folder_outlined, size: 20, color: ac.accent),
              const SizedBox(width: NatsumeSpace.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(category.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: NatsumeType.h3,
                            fontWeight: FontWeight.w600,
                            color: ac.textPrimary)),
                    Text(
                      bankCount == 0
                          ? '空分类'
                          : '$bankCount 个题库 · $questionCount 道题',
                      style: TextStyle(
                          fontSize: NatsumeType.caption,
                          color: ac.textSecondary),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '分类操作',
                icon: Icon(Icons.more_vert, size: 20, color: ac.textSecondary),
                onSelected: (value) {
                  switch (value) {
                    case 'child':
                      onNewChild();
                    case 'rename':
                      onRename();
                    case 'move':
                      onMove();
                    case 'delete':
                      onDelete();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'child', child: Text('新建子分类')),
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'move', child: Text('移动到…')),
                  PopupMenuItem(value: 'delete', child: Text('删除分类')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
class _BankCard extends StatelessWidget {
  final QuestionBank bank;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onMove;
  final VoidCallback onDelete;
  final VoidCallback onExport;
  final VoidCallback onOpenQuestions;

  const _BankCard({
    required this.bank,
    required this.isSelected,
    required this.onTap,
    required this.onMove,
    required this.onDelete,
    required this.onExport,
    required this.onOpenQuestions,
  });

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    return Semantics(
      button: true,
      selected: isSelected,
      label:
          '${bank.name}，${bank.questionCount} 道题目${isSelected ? '，已选中' : '，未选中'}',
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(bottom: NatsumeSpace.xs),
          child: NatsumeSurface(
            onTap: onTap,
            padding: const EdgeInsets.all(NatsumeSpace.sm),
            child: Row(
              children: [
                // Linear 式小方块选择器（与答题页选项一致）
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: isSelected ? ac.accent : Colors.transparent,
                    border: Border.all(
                      color: isSelected ? ac.accent : ac.border,
                      width: 1.2,
                    ),
                    borderRadius: NatsumeRadius.chipBorder,
                  ),
                  child: isSelected
                      ? Icon(Icons.check, size: 12, color: ac.onAccent)
                      : null,
                ),
                const SizedBox(width: NatsumeSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(bank.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: NatsumeType.h3,
                              fontWeight: FontWeight.w600,
                              color: ac.textPrimary)),
                      const SizedBox(height: 4),
                      Text('${bank.questionCount} 道题目',
                          style: TextStyle(
                              fontSize: NatsumeType.body, color: ac.textSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '移动到分类',
                  icon: Icon(Icons.drive_file_move_outline,
                      color: ac.textSecondary, size: 20),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  onPressed: onMove,
                ),
                IconButton(
                  tooltip: '查看 / 编辑题目',
                  icon: Icon(Icons.edit_note, color: ac.textSecondary, size: 20),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  onPressed: onOpenQuestions,
                ),
                IconButton(
                  tooltip: '导出题库',
                  icon: Icon(Icons.file_download_outlined,
                      color: ac.textSecondary, size: 20),
                  padding: EdgeInsets.zero,
                  // 触达目标 ≥40×40（与预览页同一图标按钮口径）
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  onPressed: onExport,
                ),
                IconButton(
                  tooltip: '删除题库',
                  icon: Icon(Icons.delete_outline,
                      color: ac.textSecondary, size: 20),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
