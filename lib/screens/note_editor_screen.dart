import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../services/app_state.dart';
import '../services/database_service.dart';
import '../services/notes/notes_service.dart';
import '../services/theme_service.dart';
import '../utils/design_tokens.dart';
import '../utils/responsive.dart';
import '../widgets/kit/natsume_kit.dart';
import '../widgets/note_body_view.dart';

/// 笔记编辑页（v1.31 · 笔记插件）。
///
/// 三种进入方式：
/// 1. 笔记列表里点开一条 → [note] 非空（可改可删，并显示反向链接）；
/// 2. 刷题页解析卡「写笔记」→ [questionId] + [bankId]（自动归类到该题库/该题）；
/// 3. 图谱里点悬空页 → [initialTitle] 预填（等价于 Logseq 的「新建这一页」）。
///
/// 手机与桌面同一套代码：正文是多行 [TextField]（桌面可用键盘、手机可用输入法），
/// 布局靠 [ResponsivePage] 限宽，小屏不挤、宽屏不散。
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({
    super.key,
    this.note,
    this.bankId,
    this.questionId,
    this.initialTitle,
    this.initialContent,
  });

  final Note? note;
  final int? bankId;
  final int? questionId;
  final String? initialTitle;
  final String? initialContent;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;

  /// 正文输入焦点：工具栏插入标记后要保住焦点，否则手机键盘一收一弹，
  /// 连续加粗/高亮就变成「点一下、再点一下输入框」的折磨。
  final FocusNode _bodyFocus = FocusNode();

  /// 快捷工具栏的配色盘（红 / 蓝 / 绿 …）：插入的是
  /// `<span style="color: #HEX">…</span>`，渲染引擎据此上色。
  static const List<({String label, String hex, Color color})> _palette = [
    (label: '红', hex: '#E5484D', color: Color(0xFFE5484D)),
    (label: '蓝', hex: '#2F6FEB', color: Color(0xFF2F6FEB)),
    (label: '绿', hex: '#2E9E5B', color: Color(0xFF2E9E5B)),
    (label: '橙', hex: '#F0821E', color: Color(0xFFF0821E)),
    (label: '紫', hex: '#8E4EC6', color: Color(0xFF8E4EC6)),
    (label: '粉', hex: '#E93D82', color: Color(0xFFE93D82)),
    (label: '黄', hex: '#D6A400', color: Color(0xFFD6A400)),
    (label: '灰', hex: '#6B7280', color: Color(0xFF6B7280)),
  ];

  List<Note> _backlinks = const [];

  String _bankName = NotesService.ungroupedName;
  String? _questionPreview;
  bool _preview = false;
  bool _saving = false;

  bool get _isNew => widget.note == null;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(
        text: widget.note?.title ?? widget.initialTitle ?? '');
    _bodyCtrl = TextEditingController(
        text: widget.note?.content ?? widget.initialContent ?? '');
    _loadContext();
  }

  Future<void> _loadContext() async {
    final db = DatabaseService.instance;
    final bankId = widget.note?.bankId ?? widget.bankId;
    final questionId = widget.note?.questionId ?? widget.questionId;
    var bankName = NotesService.ungroupedName;
    String? questionPreview;
    if (bankId != null) {
      final banks = await db.getAllBanks();
      for (final b in banks) {
        if (b.id == bankId) bankName = b.name;
      }
    }
    if (questionId != null && bankId != null) {
      final questions = await db.getQuestionsByBank(bankId);
      for (final q in questions) {
        if (q.id == questionId) questionPreview = q.title;
      }
    }
    final backlinks = widget.note == null
        ? const <Note>[]
        : await NotesService.instance.backlinks(widget.note!.title);
    if (!mounted) return;
    setState(() {
      _bankName = bankName;
      _questionPreview = questionPreview;
      _backlinks = backlinks;
    });
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text;
    if (title.isEmpty && body.trim().isEmpty) {
      _toast('先写点什么再保存');
      return;
    }
    setState(() => _saving = true);
    final service = NotesService.instance;
    if (_isNew) {
      await service.create(
        bankId: widget.bankId,
        questionId: widget.questionId,
        title: title,
        content: body,
      );
    } else {
      await service.save(widget.note!.copyWith(title: title, content: body));
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final note = widget.note;
    if (note?.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条笔记？'),
        content: const Text('删除后无法恢复；其他笔记里指向它的双链会变成悬空页。'),
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
    if (ok != true) return;
    await NotesService.instance.delete(note!.id!);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 插入 `[[]]` 并把光标放到中间：双链在手机上打全角括号很烦
  void _insertLink() {
    final selection = _bodyCtrl.selection;
    final text = _bodyCtrl.text;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final inserted = '[[${text.substring(start, end)}]]';
    _bodyCtrl.value = TextEditingValue(
      text: text.replaceRange(start, end, inserted),
      // 光标落在 `[[` 与 `]]` 之间
      selection: TextSelection.collapsed(offset: start + 2),
    );
    setState(() {});
  }

  /// 富文本工具栏（v1.40）：把选区包进 [prefix] … [suffix]。
  ///
  /// - **选中文字**：自动包裹选中内容（`高亮` → `<mark>高亮</mark>`）；
  /// - **未选中**：插入一对空标签，光标落在中间，直接开打就是标签内的字。
  void _wrapSelection(String prefix, String suffix) {
    final text = _bodyCtrl.text;
    final selection = _bodyCtrl.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final selected = start <= end ? text.substring(start, end) : '';
    final inserted = '$prefix$selected$suffix';
    _bodyCtrl.value = TextEditingValue(
      text: text.replaceRange(start, end, inserted),
      selection: TextSelection.collapsed(
          offset: start + prefix.length + selected.length),
      composing: TextRange.empty,
    );
    _afterToolbarEdit();
  }

  /// 行级标记：给选区覆盖的每一行加前缀；没选区就加在当前行。
  ///
  /// [ordered] 为 true 时按 `1. 2. 3.` 递增编号（否则统一 `- ` 无序）。
  void _prefixLines(String prefix, {bool ordered = false}) {
    final text = _bodyCtrl.text;
    final selection = _bodyCtrl.selection;
    final selStart = selection.start < 0 ? text.length : selection.start;
    final selEnd = selection.end < 0 ? text.length : selection.end;

    // 扩到整行：列表标记必须落在行首
    var start = selStart;
    while (start > 0 && text[start - 1] != '\n') {
      start--;
    }
    var end = selEnd;
    while (end < text.length && text[end] != '\n') {
      end++;
    }

    final block = text.substring(start, end);
    final lines = block.split('\n');
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final already = RegExp(r'^\s*(?:[-*+]\s+|\d+\.\s+)').firstMatch(line);
      final body = already == null ? line : line.substring(already.end);
      out.add('${ordered ? '${i + 1}. ' : prefix}$body');
    }
    final inserted = out.join('\n');
    _bodyCtrl.value = TextEditingValue(
      text: text.replaceRange(start, end, inserted),
      selection: TextSelection(
          baseOffset: start, extentOffset: start + inserted.length),
      composing: TextRange.empty,
    );
    _afterToolbarEdit();
  }

  /// 插入代码块：选中内容进围栏，未选中时光标落在围栏中间
  void _insertCodeBlock() {
    final selected = _selectedBodyText();
    if (selected.isEmpty) {
      _wrapSelection('```\n', '\n```');
      return;
    }
    final needsNewline = !selected.endsWith('\n');
    _wrapSelection('```\n', needsNewline ? '\n```' : '```');
  }

  String _selectedBodyText() {
    final text = _bodyCtrl.text;
    final selection = _bodyCtrl.selection;
    if (!selection.isValid || selection.isCollapsed) return '';
    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(0, text.length);
    return start < end ? text.substring(start, end) : '';
  }

  /// 插入 / 包裹后统一收尾：重绘 + 把焦点还给正文，方便连续排版
  void _afterToolbarEdit() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bodyFocus.requestFocus();
    });
  }

  /// 颜色选择：红 / 蓝 / 绿 … → `<span style="color: #HEX">`
  Future<void> _pickColor() async {
    final ac = AppThemeColors.of(context);
    final picked = await showModalBottomSheet<({String label, String hex})>(
      context: context,
      backgroundColor: ac.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(NatsumeSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('选择文字颜色',
                  style: NatsumeType.h3Style.copyWith(
                      fontWeight: FontWeight.w600, color: ac.textPrimary)),
              const SizedBox(height: NatsumeSpace.xs),
              Text('选中文字后点颜色即可上色；没选中会插入彩色标签。',
                  style: NatsumeType.captionStyle
                      .copyWith(color: ac.textTertiary)),
              const SizedBox(height: NatsumeSpace.sm),
              Wrap(
                spacing: NatsumeSpace.sm,
                runSpacing: NatsumeSpace.xs,
                children: [
                  for (final p in _palette)
                    Semantics(
                      button: true,
                      label: '${p.label}色',
                      child: InkWell(
                        key: ValueKey('noteColor${p.label}'),
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => Navigator.pop(
                            ctx, (label: p.label, hex: p.hex)),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: p.color,
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: ac.border, width: 1),
                          ),
                          child: Center(
                            child: Text(p.label,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _wrapSelection(
        '<span style="color: ${picked.hex}">', '</span>');
  }

  Future<void> _openTarget(String target) async {
    final notes = await NotesService.instance.list();
    Note? hit;
    for (final n in notes) {
      if (n.title.trim() == target.trim()) {
        hit = n;
        break;
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => hit != null
            ? NoteEditorScreen(note: hit)
            : NoteEditorScreen(initialTitle: target),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 富文本快捷工具栏（v1.40）：加粗 / 斜体 / 列表 / 代码块 / 行内公式 /
  /// 高亮 / 颜色。窄屏可横向滚动，不挤成两行按钮。
  Widget _noteToolbar(AppThemeColors ac) {
    return Container(
      decoration: BoxDecoration(
        color: ac.surfaceAlt,
        borderRadius: NatsumeRadius.cardBorder,
        border: Border.all(color: ac.border, width: NatsumeLine.width),
      ),
      padding:
          const EdgeInsets.symmetric(horizontal: NatsumeSpace.xxs, vertical: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _toolButton(ac, Icons.format_bold, '加粗',
                () => _wrapSelection('**', '**')),
            _toolButton(ac, Icons.format_italic, '斜体',
                () => _wrapSelection('*', '*')),
            _toolButton(
                ac, Icons.format_list_bulleted, '无序列表', () => _prefixLines('- ')),
            _toolButton(ac, Icons.format_list_numbered, '有序列表',
                () => _prefixLines('1. ', ordered: true)),
            _toolButton(ac, Icons.code, '代码块', _insertCodeBlock),
            _toolButton(ac, Icons.functions, '行内公式',
                () => _wrapSelection('\$', '\$')),
            _toolButton(ac, Icons.highlight_alt, '高亮',
                () => _wrapSelection('<mark>', '</mark>')),
            _toolButton(ac, Icons.palette_outlined, '文字颜色', _pickColor),
          ],
        ),
      ),
    );
  }

  Widget _toolButton(
    AppThemeColors ac,
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) {
    return IconButton(
      icon: Icon(icon, size: 18),
      color: ac.textSecondary,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: NatsumeSpace.xs),
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      // 预览态工具栏不出现（整块都在 else 分支里），这里再挡一层防止误触
      onPressed: _preview ? null : onTap,
    );
  }

  static String _short(String s) =>
      s.length <= 14 ? s : '${s.substring(0, 14)}…';

  @override
  Widget build(BuildContext context) {
    final ac = AppThemeColors.of(context);
    final app = context.watch<AppState>();
    final hasQuestion = (widget.note?.questionId ?? widget.questionId) != null;
    return Scaffold(
      backgroundColor: ac.background,
      appBar: AppBar(
        title: Text(_isNew ? '新建笔记' : '编辑笔记'),
        actions: [
          NatsumeIconButton(
            icon: _preview ? Icons.edit_outlined : Icons.visibility_outlined,
            tooltip: _preview ? '回到编辑' : '预览（双链可点）',
            onPressed: () => setState(() => _preview = !_preview),
          ),
          if (!_isNew)
            NatsumeIconButton(
              icon: Icons.delete_outline,
              tooltip: '删除',
              onPressed: _delete,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NatsumeSpace.xxs),
            child: NatsumeButton(
              label: '保存',
              dense: true,
              icon: Icons.check,
              onPressed: _saving ? null : _save,
            ),
          ),
        ],
      ),
      body: ResponsivePage(
        child: ListView(
          padding: const EdgeInsets.all(NatsumeSpace.md),
          children: [
            // 归类线索：题库 + 题目 + 插件/同步状态（插件数据不参与同步，必须明说）
            Wrap(
              spacing: NatsumeSpace.xs,
              runSpacing: NatsumeSpace.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                NatsumeTag(_bankName, tone: NatsumeTagTone.accent),
                if (hasQuestion)
                  NatsumeTag(
                    _questionPreview == null
                        ? '关联题目'
                        : '题目：${_short(_questionPreview!)}',
                  ),
                if (!app.notesPluginEnabled)
                  const NatsumeTag('插件已停用', tone: NatsumeTagTone.warning),
                const NatsumeTag('本机保存 · 无法同步'),
              ],
            ),
            const SizedBox(height: NatsumeSpace.sm),
            TextField(
              controller: _titleCtrl,
              enabled: !_preview,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                hintText: '标题（留空则取正文首行）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: NatsumeType.h3Style
                  .copyWith(color: ac.textPrimary, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: NatsumeSpace.sm),
            if (_preview)
              NatsumeSurface(
                padding: const EdgeInsets.all(NatsumeSpace.md),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 200),
                  child: NoteBodyView(
                    content: _bodyCtrl.text,
                    onOpenLink: _openTarget,
                  ),
                ),
              )
            else ...[
              _noteToolbar(ac),
              const SizedBox(height: NatsumeSpace.xxs),
              TextField(
                controller: _bodyCtrl,
                focusNode: _bodyFocus,
                maxLines: null,
                minLines: 12,
                keyboardType: TextInputType.multiline,
                onChanged: (_) => setState(() {}),
                style: NatsumeType.bodyStyle
                    .copyWith(color: ac.textPrimary, height: 1.6),
                decoration: const InputDecoration(
                  hintText: '写点什么…… 用 [[页面名]] 建立双链，#标签 也会进入图谱',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ],
            const SizedBox(height: NatsumeSpace.xs),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('插入双链'),
                  onPressed: _preview ? null : _insertLink,
                ),
                const Spacer(),
                Text('双链 ${NoteLinks.extractTargets(_bodyCtrl.text).length}',
                    style: NatsumeType.microStyle
                        .copyWith(color: ac.textTertiary)),
              ],
            ),
            if (_backlinks.isNotEmpty) ...[
              const SizedBox(height: NatsumeSpace.md),
              const NatsumeSectionHeader(
                title: '反向链接',
                subtitle: '这些笔记引用了本页',
              ),
              const SizedBox(height: NatsumeSpace.xs),
              for (final n in _backlinks)
                Padding(
                  padding: const EdgeInsets.only(bottom: NatsumeSpace.xxs),
                  child: NatsumeSurface(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => NoteEditorScreen(note: n)),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: NatsumeSpace.sm, vertical: NatsumeSpace.xs),
                    child: Row(
                      children: [
                        Icon(Icons.subdirectory_arrow_right,
                            size: 14, color: ac.textTertiary),
                        const SizedBox(width: NatsumeSpace.xxs),
                        Expanded(
                          child: Text(n.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NatsumeType.bodyStyle
                                  .copyWith(color: ac.accent)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            const SizedBox(height: NatsumeSpace.md),
            Text(
              '提示：${NotesService.syncNotice}；换设备请用「备份与恢复」导出整库。',
              style: NatsumeType.microStyle.copyWith(color: ac.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
