import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/kb_document.dart';
import '../models/knowledge_base.dart';
import '../models/bank_category.dart';
import '../models/list_sort.dart';
import '../services/database_service.dart';
import '../services/knowledge_base/kb_file_service.dart';
import '../services/knowledge_base/kb_health.dart';
import '../services/knowledge_base/kb_service.dart';
import '../services/list_sort_service.dart';
import '../services/plugins/world_service.dart';
import '../services/theme_service.dart';
import '../services/export_storage.dart';
import '../utils/design_tokens.dart';
import '../utils/natsume_personality.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';

/// 知识库管理（v13）。
///
/// 知识库 = 约束 AI 的资料源：用户自导入课件/笔记/教材，可改名、增删文档、
/// 编辑文档全文、整体导出/导入（`.json`）。选中某个知识库后下方展示其文档，
/// 可逐篇编辑与删除。
/// 文档行「更多」菜单动作（v1.30.2）
enum _DocAction { rename, move, delete }

class KnowledgeBaseScreen extends StatefulWidget {
  const KnowledgeBaseScreen({super.key});

  @override
  State<KnowledgeBaseScreen> createState() => _KnowledgeBaseScreenState();
}

class _KnowledgeBaseScreenState extends State<KnowledgeBaseScreen> {
  final KbService _kb = KbService.instance;

  List<KnowledgeBase> _bases = [];
  int? _selectedKbId;
  List<KbDocument> _docs = [];
  bool _loading = true;
  String _motto = '';

  /// 知识库排序方式（v1.35.5）：存档在 SharedPreferences，跨启动记住
  KbSortMode _sort = KbSortMode.createdDesc;

  /// v1.39.3 多选批量操作（知识库模型暂无分类字段，只提供删除/导出）
  bool _batchMode = false;
  final Set<int> _batchSelected = {};

  @override
  void initState() {
    super.initState();
    _motto = NatsumePersonality.randomMotto();
    ListSortService.instance.loadKbSort().then((mode) {
      if (!mounted || mode == _sort) return;
      setState(() => _sort = mode);
    });
    _reload();
  }

  void _changeSort(KbSortMode mode) {
    if (mode == _sort) return;
    setState(() => _sort = mode);
    ListSortService.instance.saveKbSort(mode);
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final bases = await _kb.listKnowledgeBases();
    final docs = _selectedKbId == null
        ? <KbDocument>[]
        : await _kb.listDocuments(_selectedKbId!);
    if (!mounted) return;
    setState(() {
      _bases = bases;
      _docs = docs;
      if (_selectedKbId == null && bases.isNotEmpty) {
        _selectedKbId = bases.first.id;
      }
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    // 排序在 build 里算：`_bases` 保持数据库顺序，切换排序方式只是换个视图
    final bases = sortKnowledgeBases(_bases, _sort);
    final allIds = _bases.map((b) => b.id).whereType<int>().toSet();
    final allSelected =
        allIds.isNotEmpty && _batchSelected.length == allIds.length;
    return PopScope(
      canPop: !_batchMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _batchMode) _exitBatch();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !_batchMode,
          leading: _batchMode
              ? IconButton(
                  tooltip: '退出多选',
                  icon: const Icon(Icons.close),
                  onPressed: _exitBatch,
                )
              : null,
          title: Text(_batchMode ? '已选 ${_batchSelected.length} 项' : '知识库'),
          actions: _batchMode
              ? [
                  TextButton(
                    onPressed: () => setState(() {
                      if (allSelected) {
                        _batchSelected.clear();
                      } else {
                        _batchSelected
                          ..clear()
                          ..addAll(allIds);
                      }
                    }),
                    child: Text(allSelected ? '取消全选' : '全选'),
                  ),
                  TextButton(
                    onPressed: _exitBatch,
                    child: const Text('取消'),
                  ),
                ]
              : [
                  IconButton(
                    tooltip: '导出分类',
                    icon: const Icon(Icons.folder_zip_outlined),
                    onPressed: _exportCategory,
                  ),
                  // v1.44 检索自检：把「向量检索靠不靠得住」摊成可测的数字
                  IconButton(
                    tooltip: '检索自检',
                    icon: const Icon(Icons.health_and_safety_outlined),
                    onPressed: _openDiagnostics,
                  ),
                  // 排序（v1.35.5）
                  PopupMenuButton<KbSortMode>(
                    tooltip: '排序方式：${_sort.label}',
                    icon: const Icon(Icons.sort),
                    initialValue: _sort,
                    onSelected: _changeSort,
                    itemBuilder: (context) => [
                      for (final mode in KbSortMode.values)
                        CheckedPopupMenuItem<KbSortMode>(
                          value: mode,
                          checked: mode == _sort,
                          child: Text(mode.label),
                        ),
                    ],
                  ),
                ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ResponsivePage(
                child: ListView(
                  padding: const EdgeInsets.all(NatsumeSpace.md),
                  children: [
                    NatsumeSectionHeader(
                      title: '知识库',
                      subtitle: '导入资料后，AI 出题只依据这些资料（防幻觉）',
                      trailing: _batchMode
                          ? null
                          : NatsumeButton(
                              label: '新建',
                              dense: true,
                              icon: Icons.add,
                              onPressed: _create,
                            ),
                    ),
                    const SizedBox(height: NatsumeSpace.sm),
                    if (bases.isEmpty)
                      NatsumeEmptyState(
                        icon: Icons.menu_book_outlined,
                        title: '还没有知识库',
                        description: '点「新建」创建，或「导入」一个知识库文件\n\n「$_motto」',
                      )
                    else
                      for (final kb in bases) ...[
                        _kbCard(
                          kb,
                          ac,
                          batchMode: _batchMode,
                          batchSelected: _batchSelected.contains(kb.id),
                          onLongPress:
                              _batchMode ? null : () => _enterBatch(kb.id!),
                          onBatchToggle: () => _toggleBatch(kb.id!),
                        ),
                        const SizedBox(height: NatsumeSpace.xs),
                      ],
                    const SizedBox(height: NatsumeSpace.md),
                    if (!_batchMode && _selectedKbId != null) ...[
                      NatsumeSectionHeader(
                        title: '文档',
                        trailing: NatsumeButton(
                          label: '导入文档',
                          dense: true,
                          icon: Icons.upload_file_outlined,
                          onPressed: _importDocument,
                        ),
                      ),
                      const SizedBox(height: NatsumeSpace.sm),
                      if (_docs.isEmpty)
                        NatsumeSurface(
                          tone: NatsumeTone.alt,
                          padding: const EdgeInsets.all(NatsumeSpace.md),
                          child: Text('暂无文档，点「导入文档」添加 txt/md/docx/pdf',
                              style: NatsumeType.captionStyle
                                  .copyWith(color: ac.textSecondary)),
                        )
                      else
                        for (final d in _docs) ...[
                          _docTile(d, ac),
                          const SizedBox(height: NatsumeSpace.xs),
                        ],
                      const SizedBox(height: NatsumeSpace.sm),
                      Row(
                        children: [
                          Expanded(
                            child: NatsumeButton(
                              label: '导出知识库',
                              kind: NatsumeButtonKind.secondary,
                              icon: Icons.ios_share_outlined,
                              onPressed: _exportSelected,
                            ),
                          ),
                          const SizedBox(width: NatsumeSpace.sm),
                          NatsumeButton(
                            label: '导入知识库',
                            kind: NatsumeButtonKind.ghost,
                            icon: Icons.download_outlined,
                            onPressed: _importKb,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
        bottomNavigationBar: _batchMode ? _buildBatchBar(ac) : null,
      ),
    );
  }
  // ======================== 批量操作（v1.39.3） ========================

  List<KnowledgeBase> _selectedBases() => _bases
      .where((b) => b.id != null && _batchSelected.contains(b.id))
      .toList();

  void _enterBatch(int kbId) {
    setState(() {
      _batchMode = true;
      _batchSelected
        ..clear()
        ..add(kbId);
    });
  }

  void _exitBatch() {
    if (!mounted) return;
    setState(() {
      _batchMode = false;
      _batchSelected.clear();
    });
  }

  void _toggleBatch(int kbId) {
    setState(() {
      if (!_batchSelected.remove(kbId)) _batchSelected.add(kbId);
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  Widget _buildBatchBar(AppThemeColors ac) {
    final hasSelection = _batchSelected.isNotEmpty;
    Widget action(
      IconData icon,
      String label,
      Color color,
      VoidCallback? onPressed,
    ) =>
        Expanded(
          child: TextButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: TextButton.styleFrom(
              foregroundColor: color,
              visualDensity: VisualDensity.compact,
            ),
          ),
        );

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: ac.surface,
          border: Border(top: BorderSide(color: ac.border, width: 0.5)),
        ),
        padding: const EdgeInsets.symmetric(
            horizontal: NatsumeSpace.xs, vertical: NatsumeSpace.xxs),
        child: Row(
          children: [
            action(
              Icons.delete_outline,
              '删除',
              ac.danger,
              hasSelection ? _batchDelete : null,
            ),
            action(
              Icons.ios_share_outlined,
              '导出',
              ac.accent,
              hasSelection ? _batchExport : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _batchDelete() async {
    final bases = _selectedBases();
    if (bases.isEmpty) return;
    final ac = AppThemeColors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量删除知识库'),
        content: Text('确定删除选中的 ${bases.length} 个知识库吗？\n'
            '其下所有文档与切块会一并删除，此操作不可恢复。'),
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
    if (ok != true || !mounted) return;
    final ids = bases.map((b) => b.id!).toSet();
    await _kb.deleteKnowledgeBases(ids);
    if (_selectedKbId != null && ids.contains(_selectedKbId)) {
      _selectedKbId = null;
    }
    if (!mounted) return;
    _exitBatch();
    await _reload();
    if (!mounted) return;
    _snack('已删除 ${bases.length} 个知识库');
  }

  /// 批量导出：把勾选的知识库打成一个 `.zip` 分享包（v1.43）。
  ///
  /// 以前「批量导出」只能一条一条落 `.json`（或者按分类整包走世界包），用户
  /// 没法像导出题库那样自由勾选。现在落成一个包：包内每个成员仍是标准知识库
  /// JSON，「导入知识库」直接选中这个包就能一次性还原。
  Future<void> _batchExport() async {
    final bases = _selectedBases();
    if (bases.isEmpty) return;
    final dir = await ExportStorage.resolve();
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(RegExp(r'[:.]'), '-');
    final dest = '${dir.path}${Platform.pathSeparator}'
        '知识库合集_${bases.length}项_$stamp${KbFileService.bundleExtension}';
    final result = await KbFileService.exportBundle(
      kbIds: bases.map((b) => b.id!).toList(),
      destPath: dest,
    );
    if (!mounted) return;
    if (!result.saved) {
      _exitBatch();
      _snack('选中的知识库都没有可导出的文档');
      return;
    }
    final saved = await ExportStorage.saveFileAs(dest, dialogTitle: '保存知识库包');
    if (!mounted) return;
    _exitBatch();
    final notes = [
      if (result.skippedCount > 0) '${result.skippedCount} 个没有文档已跳过',
      '可用「导入知识库」选中该包一次性还原',
    ].join('；');
    _snack(saved.saved
        ? '已导出 ${result.kbCount} 个知识库到 ${saved.path}\n$notes'
        : '已取消保存。文件仍可在此找到：${ExportStorage.folderOf(dest)}\n$notes');
  }

  Widget _kbCard(
    KnowledgeBase kb,
    AppThemeColors ac, {
    required bool batchMode,
    required bool batchSelected,
    required VoidCallback? onLongPress,
    required VoidCallback onBatchToggle,
  }) {
    final selected = kb.id == _selectedKbId;
    return GestureDetector(
      onLongPress: onLongPress,
      child: NatsumeSurface(
        accentEdge: !batchMode && selected,
        onTap: () {
          if (batchMode) {
            onBatchToggle();
            return;
          }
          setState(() {
            _selectedKbId = kb.id;
            _reload();
          });
        },
        padding: const EdgeInsets.all(NatsumeSpace.sm),
        child: Row(
          children: [
            if (batchMode)
              Checkbox(
                value: batchSelected,
                onChanged: (_) => onBatchToggle(),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kb.name,
                      style: NatsumeType.h3Style.copyWith(
                          fontWeight: FontWeight.w600, color: ac.textPrimary)),
                  if (kb.description != null && kb.description!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(kb.description!,
                        style: NatsumeType.captionStyle
                            .copyWith(color: ac.textSecondary)),
                  ],
                ],
              ),
            ),
            if (!batchMode) ...[
              NatsumeIconButton(
                icon: Icons.edit_outlined,
                tooltip: '编辑名称 / 描述',
                onPressed: () => _editMeta(kb),
              ),
              NatsumeIconButton(
                icon: Icons.delete_outline,
                tooltip: '删除',
                onPressed: () => _delete(kb),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _docTile(KbDocument d, AppThemeColors ac) {
    return NatsumeSurface(
      tone: NatsumeTone.alt,
      padding: const EdgeInsets.symmetric(
          horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
      child: Row(
        children: [
          Icon(Icons.description_outlined, size: 16, color: ac.accent),
          const SizedBox(width: NatsumeSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
                Text(
                    '${d.content.length} 字 · ${(d.fileExt ?? '').toUpperCase()}',
                    style: NatsumeType.microStyle
                        .copyWith(color: ac.textTertiary)),
              ],
            ),
          ),
          NatsumeIconButton(
            icon: Icons.edit_outlined,
            tooltip: '编辑全文',
            onPressed: () => _editDoc(d),
          ),
          // 重命名 / 移动 / 删除收进菜单（v1.30.2）：文档行已有「编辑全文」，
          // 再并排三个图标在手机上会挤成一排难点的小点；菜单同时把
          // 「导入后不能改」这一条补上——名称、归属现在都能改
          PopupMenuButton<_DocAction>(
            tooltip: '更多操作',
            icon: Icon(Icons.more_horiz, size: 18, color: ac.textTertiary),
            padding: EdgeInsets.zero,
            onSelected: (action) {
              switch (action) {
                case _DocAction.rename:
                  _renameDoc(d);
                case _DocAction.move:
                  _moveDoc(d);
                case _DocAction.delete:
                  _deleteDoc(d);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: _DocAction.rename, child: Text('重命名')),
              PopupMenuItem(value: _DocAction.move, child: Text('移动到其他知识库')),
              PopupMenuItem(value: _DocAction.delete, child: Text('删除文档')),
            ],
          ),
        ],
      ),
    );
  }

  // ======================== 动作 ========================

  Future<void> _create() async {
    final name = await _promptText(title: '新建知识库', hint: '知识库名称');
    if (name == null || name.trim().isEmpty) return;
    await _kb.createKnowledgeBase(name.trim());
    _reload();
  }

  /// 编辑知识库名称 + 描述 + 分类（v18：知识库复用题库分类树）
  Future<void> _editMeta(KnowledgeBase kb) async {
    final nameCtrl = TextEditingController(text: kb.name);
    final descCtrl = TextEditingController(text: kb.description ?? '');
    final categories = await DatabaseService.instance.getAllBankCategories();
    final options = _flattenCategories(categories);
    var chosenCategory = kb.categoryId;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('编辑知识库'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '名称',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '描述（可留空）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                value: options.any((o) => o.id == chosenCategory)
                    ? chosenCategory
                    : null,
                decoration: const InputDecoration(
                  labelText: '分类',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('未分类'),
                  ),
                  for (final option in options)
                    DropdownMenuItem<int?>(
                      value: option.id,
                      child: Text(option.label,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) => setLocal(() => chosenCategory = value),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    final name = nameCtrl.text.trim();
    final desc = descCtrl.text.trim();
    nameCtrl.dispose();
    descCtrl.dispose();
    if (saved != true || name.isEmpty) return;
    await _kb.renameKnowledgeBase(kb.id!, name, desc.isEmpty ? null : desc);
    if (chosenCategory != kb.categoryId) {
      await _kb.setKnowledgeBaseCategory(kb.id!, chosenCategory);
    }
    _reload();
  }

  /// 分类树摊平成「缩进名称」列表，供下拉与导出选择使用。
  List<({int id, String label})> _flattenCategories(
      List<BankCategory> categories) {
    final childrenOf = <int?, List<BankCategory>>{};
    for (final c in categories) {
      childrenOf.putIfAbsent(c.parentId, () => []).add(c);
    }
    final out = <({int id, String label})>[];
    void add(int? parentId, int depth) {
      for (final c in childrenOf[parentId] ?? const <BankCategory>[]) {
        if (c.id == null) continue;
        out.add((id: c.id!, label: '${'　' * depth}${c.name}'));
        add(c.id, depth + 1);
      }
    }

    add(null, 0);
    return out;
  }

  Future<void> _delete(KnowledgeBase kb) async {
    final ok = await _confirm('删除知识库「${kb.name}」？其下所有文档将一并删除。');
    if (ok != true) return;
    await _kb.deleteKnowledgeBase(kb.id!);
    if (_selectedKbId == kb.id) _selectedKbId = null;
    _reload();
  }

  Future<void> _importDocument() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'md', 'markdown', 'docx', 'pdf'],
    );
    if (_selectedKbId == null) return;
    final paths = files.map((f) => f.path).whereType<String>().toList();
    for (final p in paths) {
      try {
        await _kb.importDocument(_selectedKbId!, p);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('导入失败：${e.toString()}')));
        }
      }
    }
    _reload();
  }

  Future<void> _editDoc(KbDocument d) async {
    final content =
        await _promptText(title: '编辑文档', initial: d.content, multiline: true);
    if (content == null) return;
    // 用文档自己的 kbId，不依赖「当前选中的知识库」——移动过文档后两者可能不同
    await _kb.updateDocumentContent(d.kbId, d.id!, content);
    _reload();
  }

  /// 重命名文档（v1.30.2）：导入时名字取自文件名，扫描件常是一串无意义编号
  Future<void> _renameDoc(KbDocument d) async {
    final name =
        await _promptText(title: '重命名文档', initial: d.name, hint: '文档名称');
    if (name == null || name.trim().isEmpty) return;
    await _kb.renameDocument(d.id!, name.trim());
    _reload();
  }

  /// 把文档移动到另一个知识库（v1.30.2）：分块随文档一起改归属
  Future<void> _moveDoc(KbDocument d) async {
    final targets = _bases.where((b) => b.id != d.kbId).toList();
    if (targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('只有一个知识库，先新建一个再移动')));
      }
      return;
    }
    final targetId = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('移动「${d.name}」到…'),
        children: [
          for (final b in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, b.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(b.name),
              ),
            ),
        ],
      ),
    );
    if (targetId == null) return;
    await _kb.moveDocument(d.id!, d.kbId, targetId);
    _reload();
  }

  Future<void> _deleteDoc(KbDocument d) async {
    final ok = await _confirm('删除文档「${d.name}」？');
    if (ok != true) return;
    await _kb.deleteDocument(d.id!);
    _reload();
  }

  Future<void> _exportSelected() async {
    final kb = _bases.where((b) => b.id == _selectedKbId).firstOrNull;
    if (kb == null) return;
    final dir = await ExportStorage.resolve();
    // v1.42：文件名清掉 `/ : * ? " < > |` 等非法字符并强制 `.json`，
    // 否则 Windows 写入会失败（名字带斜杠时），生成的文件也认不出类型。
    final dest = '${dir.path}${Platform.pathSeparator}'
        '${KbFileService.singleExportFileName('${kb.name}_知识库')}';
    final path = await KbFileService.exportKnowledgeBase(kb.id!, dest);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (path == null) {
      messenger.showSnackBar(const SnackBar(content: Text('该知识库没有可导出的文档')));
      return;
    }
    // v1.34：导出后直接「另存为」，不再弹系统分享面板
    final saved =
        await ExportStorage.saveFileAs(path, dialogTitle: '保存知识库导出文件');
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(saved.saved
          ? '已导出到 ${saved.path}'
          : '已取消保存。文件仍可在此找到：${ExportStorage.folderOf(path)}'),
      duration: const Duration(seconds: 5),
    ));
  }

  /// 导出某个分类下的知识库（含子分类）：分类树由 WorldService 序列化。
  Future<void> _exportCategory() async {
    final categories = await DatabaseService.instance.getAllBankCategories();
    final counts = <int, int>{};
    for (final kb in _bases) {
      final id = kb.categoryId;
      if (id != null) counts[id] = (counts[id] ?? 0) + 1;
    }
    final available = categories
        .where((c) => c.id != null && (counts[c.id] ?? 0) > 0)
        .toList();
    if (available.isEmpty) {
      _snack('还没有挂到分类下的知识库；可先在「编辑名称 / 描述」里选择分类。');
      return;
    }
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出知识库分类'),
        content: SizedBox(
          width: dialogContentWidth(ctx, max: 360),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final category in available)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(category.name),
                    subtitle: Text('${counts[category.id] ?? 0} 个知识库'),
                    onTap: () => Navigator.pop(ctx, category.id),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final category = available.firstWhere((c) => c.id == chosen,
        orElse: () => available.first);
    final dir = await ExportStorage.resolve();
    final safe = category.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final dest =
        '${dir.path}${Platform.pathSeparator}分类_${safe.isEmpty ? chosen : safe}_知识库.natsume-world.zip';
    final path = await WorldService.exportCategory(
      categoryId: chosen,
      destPath: dest,
      includeBanks: false,
      includeKbs: true,
    );
    if (!mounted) return;
    if (path == null) {
      _snack('分类不存在或导出失败');
      return;
    }
    final saved = await ExportStorage.saveFileAs(path, dialogTitle: '保存分类导出文件');
    if (!mounted) return;
    if (saved.saved) {
      _snack('已导出分类「${category.name}」到 ${saved.path}');
    } else {
      _snack('已取消保存。文件仍可在此找到：${ExportStorage.folderOf(path)}');
    }
  }

  Future<void> _importKb() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      // 单文件 JSON 和「知识库包」（.zip，可含多个知识库；旧版 .natsume-kb 也接受）都能导
      allowedExtensions: ['json', 'zip', 'natsume-kb'],
    );
    final path = picked?.path;
    if (path == null) return;

    // v1.42：「导出分类」产物是 world 包（.natsume-world.zip），这里也接住，
    // 让「导出 → 导入」形成闭环，而不是报「缺少 kb.json 清单」。
    // v1.43：包后缀统一为 .zip，类型只能靠包内清单判断，因此先认 world 再认 kb。
    if (await KbFileService.isWorldFile(path)) {
      try {
        final r = await WorldService.importWorld(path);
        if (!mounted) return;
        await _reload();
        if (!mounted) return;
        _snack('已从分类 / 世界包导入 ${r.kbCount} 个知识库'
            '${r.skippedCount > 0 ? '；${r.skippedCount} 个已存在已跳过' : ''}');
      } catch (e) {
        if (mounted) _snack('导入失败：$e');
      }
      return;
    }

    // 批量导出的 `.zip` 知识库包：靠包内 kb.json 的 format 标记识别
    if (await KbFileService.isBundleFile(path)) {
      final r = await KbFileService.importBundle(path);
      if (!mounted) return;
      if (r.kbCount > 0) {
        await _reload();
        if (!mounted) return;
        _snack('已从知识库包导入 ${r.kbCount} 个知识库'
            '${r.skippedCount > 0 ? '；${r.skippedCount} 个已存在已跳过' : ''}');
      } else if (r.skippedCount > 0) {
        _snack('包里的 ${r.skippedCount} 个知识库本机都已存在，已跳过');
      } else {
        _snack(r.error ?? '导入失败');
      }
      return;
    }

    // 普通 zip：没有 kb.json / world.json 清单，明确告诉用户而不是抛 JSON 解析错误
    if (await KbFileService.isZipFile(path)) {
      _snack('这个压缩包里没有知识库清单（kb.json），无法导入。');
      return;
    }

    final (id, err) = await KbFileService.importKbFile(path);
    if (id > 0) {
      await _reload();
      if (mounted) _snack('已导入知识库');
    } else if (mounted) {
      _snack(err ?? '导入失败');
    }
  }

  Future<String?> _promptText({
    required String title,
    String initial = '',
    String? hint,
    bool multiline = false,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: multiline ? 12 : 1,
          minLines: multiline ? 6 : 1,
          decoration: InputDecoration(hintText: hint),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<bool?> _confirm(String message) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
  }

  /// 检索自检（v1.44）：把「向量检索到底靠不靠得住」变成可测的数字。
  ///
  /// 用户问的是「已经加了向量搜索，但它可靠吗」，这个问题不能靠猜测回答：
  /// 面板里给出文档数/块数/向量覆盖率/平均块长/检索耗时，并且可以对任意一句话
  /// 做一次试检索，把「靠语义命中」和「靠关键词命中」分开列出来。
  Future<void> _openDiagnostics() async {
    final kbId = _selectedKbId;
    if (kbId == null) {
      _snack('先在上面选中一个知识库，再点检索自检');
      return;
    }
    var kbName = '知识库';
    for (final b in _bases) {
      if (b.id == kbId) {
        kbName = b.name;
        break;
      }
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _KbDiagnosticsSheet(kbId: kbId, kbName: kbName),
    );
  }
}

/// 检索自检面板（v1.44）。
class _KbDiagnosticsSheet extends StatefulWidget {
  const _KbDiagnosticsSheet({required this.kbId, required this.kbName});

  final int kbId;
  final String kbName;

  @override
  State<_KbDiagnosticsSheet> createState() => _KbDiagnosticsSheetState();
}

class _KbDiagnosticsSheetState extends State<_KbDiagnosticsSheet> {
  final TextEditingController _probe = TextEditingController();
  KbHealthReport? _report;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _probe.dispose();
    super.dispose();
  }

  Future<void> _load({bool withProbe = false}) async {
    setState(() => _loading = true);
    KbHealthReport report;
    try {
      report = await KbService.instance.diagnose(
        widget.kbId,
        sampleQuery: withProbe ? _probe.text.trim() : null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('自检失败：$e')));
      return;
    }
    if (!mounted) return;
    setState(() {
      _report = report;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final r = _report;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: NatsumeSpace.md,
          right: NatsumeSpace.md,
          top: NatsumeSpace.sm,
          bottom: MediaQuery.of(context).viewInsets.bottom + NatsumeSpace.md,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('检索自检 · ${widget.kbName}',
                  style: NatsumeType.h2Style.copyWith(color: ac.textPrimary)),
              const SizedBox(height: NatsumeSpace.xxs),
              Text('看的是「检索能不能命中、命中靠不靠谱」，不改动任何数据。',
                  style: NatsumeType.captionStyle
                      .copyWith(color: ac.textSecondary)),
              const SizedBox(height: NatsumeSpace.md),
              if (_loading)
                const Center(child: Padding(
                  padding: EdgeInsets.all(NatsumeSpace.md),
                  child: CircularProgressIndicator(),
                ))
              else if (r != null) ...[
                _statGrid(r, ac),
                const SizedBox(height: NatsumeSpace.md),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _probe,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '输入一句话做试检索，例如「休克 血压下降」',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _load(withProbe: true),
                      ),
                    ),
                    const SizedBox(width: NatsumeSpace.xs),
                    NatsumeButton(
                      label: '试检索',
                      dense: true,
                      kind: NatsumeButtonKind.secondary,
                      onPressed: () => _load(withProbe: true),
                    ),
                  ],
                ),
                if (r.probeQuery != null) ...[
                  const SizedBox(height: NatsumeSpace.sm),
                  _probeResult(r, ac),
                ],
                const SizedBox(height: NatsumeSpace.md),
                Text('建议', style: NatsumeType.h3Style.copyWith(color: ac.textPrimary)),
                const SizedBox(height: NatsumeSpace.xs),
                for (final line in r.advice)
                  Padding(
                    padding: const EdgeInsets.only(bottom: NatsumeSpace.xxs),
                    child: Text('· $line',
                        style: NatsumeType.captionStyle
                            .copyWith(color: ac.textSecondary, height: 1.5)),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statGrid(KbHealthReport r, AppThemeColors ac) {
    final items = <(String, String)>[
      ('文档', '${r.documentCount} 篇'),
      ('文本块', '${r.chunkCount} 块'),
      ('向量覆盖', '${(r.embeddingCoverage * 100).toStringAsFixed(0)}%'
          '（${r.embeddedChunkCount}/${r.chunkCount}）'),
      ('平均块长', '${r.averageChunkChars.toStringAsFixed(0)} 字'),
      ('检索方式', r.vectorEnabled && r.hasAnyVector ? '向量 + 关键词混合' : '仅关键词'),
      if (r.probeMilliseconds != null) ('试检索耗时', '${r.probeMilliseconds} ms'),
    ];
    return NatsumeSurface(
      tone: NatsumeTone.alt,
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      child: Column(
        children: [
          for (final (label, value) in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(label,
                        style: NatsumeType.captionStyle
                            .copyWith(color: ac.textTertiary)),
                  ),
                  Text(value,
                      style: NatsumeType.captionStyle.copyWith(
                          color: ac.textPrimary,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _probeResult(KbHealthReport r, AppThemeColors ac) {
    if (r.hybridHits.isEmpty) {
      return Text('没有命中任何资料。',
          style: NatsumeType.captionStyle.copyWith(color: ac.danger));
    }
    return NatsumeSurface(
      tone: NatsumeTone.alt,
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('命中 ${r.hybridHits.length} 条'
              '（语义 ${r.hybridVectorMatched} / 关键词 ${r.hybridKeywordMatched}）',
              style: NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
          const SizedBox(height: NatsumeSpace.xxs),
          for (final h in r.hybridHits.take(3))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${h.score.toStringAsFixed(2)} · '
                    '${h.matchedByVector && h.matchedByKeyword ? '语义+关键词' : h.matchedByVector ? '语义' : '关键词'}',
                    style: NatsumeType.microStyle.copyWith(color: ac.accent),
                  ),
                  Text(
                    h.chunk.text.length > 80
                        ? '${h.chunk.text.substring(0, 80)}…'
                        : h.chunk.text,
                    style: NatsumeType.captionStyle
                        .copyWith(color: ac.textSecondary, height: 1.4),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
