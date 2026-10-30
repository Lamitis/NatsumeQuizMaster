import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/kb_document.dart';
import '../models/knowledge_base.dart';
import '../services/knowledge_base/kb_file_service.dart';
import '../services/knowledge_base/kb_service.dart';
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

  @override
  void initState() {
    super.initState();
    _motto = NatsumePersonality.randomMotto();
    _reload();
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
    return Scaffold(
      appBar: AppBar(title: const Text('知识库')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ResponsivePage(
              child: ListView(
                padding: const EdgeInsets.all(NatsumeSpace.md),
                children: [
                  NatsumeSectionHeader(
                    title: '知识库',
                    subtitle: '导入资料后，AI 出题只依据这些资料（防幻觉）',
                    trailing: NatsumeButton(
                      label: '新建',
                      dense: true,
                      icon: Icons.add,
                      onPressed: _create,
                    ),
                  ),
                  const SizedBox(height: NatsumeSpace.sm),
                  if (_bases.isEmpty)
                    NatsumeEmptyState(
                      icon: Icons.menu_book_outlined,
                      title: '还没有知识库',
                      description:
                          '点「新建」创建，或「导入」一个知识库文件\n\n「$_motto」',
                    )
                  else
                    for (final kb in _bases) ...[
                      _kbCard(kb, ac),
                      const SizedBox(height: NatsumeSpace.xs),
                    ],
                  const SizedBox(height: NatsumeSpace.md),
                  if (_selectedKbId != null) ...[
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
    );
  }

  Widget _kbCard(KnowledgeBase kb, AppThemeColors ac) {
    final selected = kb.id == _selectedKbId;
    return NatsumeSurface(
      accentEdge: selected,
      onTap: () => setState(() {
        _selectedKbId = kb.id;
        _reload();
      }),
      padding: const EdgeInsets.all(NatsumeSpace.sm),
      child: Row(
        children: [
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
                      style:
                          NatsumeType.captionStyle.copyWith(color: ac.textSecondary)),
                ],
              ],
            ),
          ),
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
                Text('${d.content.length} 字 · ${(d.fileExt ?? '').toUpperCase()}',
                    style: NatsumeType.microStyle.copyWith(color: ac.textTertiary)),
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
              PopupMenuItem(
                  value: _DocAction.move, child: Text('移动到其他知识库')),
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

  /// 编辑知识库名称 + 描述（v1.30.2：原来只能改名，描述建完就锁死了）
  Future<void> _editMeta(KnowledgeBase kb) async {
    final nameCtrl = TextEditingController(text: kb.name);
    final descCtrl = TextEditingController(text: kb.description ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
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
    );
    final name = nameCtrl.text.trim();
    final desc = descCtrl.text.trim();
    nameCtrl.dispose();
    descCtrl.dispose();
    if (saved != true || name.isEmpty) return;
    await _kb.renameKnowledgeBase(kb.id!, name, desc.isEmpty ? null : desc);
    _reload();
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
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('导入失败：${e.toString()}')));
        }
      }
    }
    _reload();
  }

  Future<void> _editDoc(KbDocument d) async {
    final content = await _promptText(
        title: '编辑文档', initial: d.content, multiline: true);
    if (content == null) return;
    // 用文档自己的 kbId，不依赖「当前选中的知识库」——移动过文档后两者可能不同
    await _kb.updateDocumentContent(d.kbId, d.id!, content);
    _reload();
  }

  /// 重命名文档（v1.30.2）：导入时名字取自文件名，扫描件常是一串无意义编号
  Future<void> _renameDoc(KbDocument d) async {
    final name = await _promptText(
        title: '重命名文档', initial: d.name, hint: '文档名称');
    if (name == null || name.trim().isEmpty) return;
    await _kb.renameDocument(d.id!, name.trim());
    _reload();
  }

  /// 把文档移动到另一个知识库（v1.30.2）：分块随文档一起改归属
  Future<void> _moveDoc(KbDocument d) async {
    final targets = _bases.where((b) => b.id != d.kbId).toList();
    if (targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('只有一个知识库，先新建一个再移动')));
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
    final dest =
        '${dir.path}${Platform.pathSeparator}${kb.name}_知识库.json';
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

  Future<void> _importKb() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = picked?.path;
    if (path == null) return;
    final (id, err) = await KbFileService.importKbFile(path);
    if (id > 0) {
      _reload();
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err ?? '导入失败')));
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
}
