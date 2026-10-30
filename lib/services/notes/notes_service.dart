import '../../models/note.dart';
import '../database_service.dart';

/// 笔记服务（v1.31 · 笔记插件）。
///
/// 职责：笔记 CRUD + 双链索引重建 + 按题库分组 + 图谱数据。
/// 数据落在 `notes` / `note_links`（DB v14）。
///
/// **同步边界（重要）**：`SyncRepository` 的导出清单只含
/// 题库 / 题目 / 配图 / 会话 / 作答记录 / 错题 / 批注；笔记属于插件数据，
/// 不参与局域网同步——[syncable] 恒为 false，界面必须据此显示「无法同步」。
class NotesService {
  NotesService._();
  static final NotesService instance = NotesService._();

  static final DatabaseService _db = DatabaseService.instance;

  /// 笔记当前是否参与局域网同步（false = 换设备看不到，界面要明说）
  static const bool syncable = false;

  /// 界面统一复用的同步提示文案（插件区与笔记页共用一个说法）
  static const String syncNotice = '笔记保存在本机，不参与局域网同步';

  /// 未归类 / 题库已删除时的分组标题
  static const String ungroupedName = '未分类';

  Future<List<Note>> list({int? bankId, int? questionId}) =>
      _db.getNotes(bankId: bankId, questionId: questionId);

  Future<Note?> byId(int id) => _db.getNote(id);

  /// 某道题上的笔记（题库页 / 刷题页入口用）
  Future<List<Note>> forQuestion(int questionId) =>
      _db.getNotes(questionId: questionId);

  Future<Note?> latestForQuestion(int questionId) async {
    final list = await forQuestion(questionId);
    return list.isEmpty ? null : list.first;
  }

  /// 新建笔记。[title] 为空时按正文首行推断，仍为空则给「未命名笔记」。
  Future<int> create({
    int? bankId,
    int? questionId,
    String? title,
    String content = '',
  }) async {
    final now = DateTime.now().toIso8601String();
    final resolved = _resolveTitle(title: title, content: content);
    final id = await _db.insertNote(Note(
      bankId: bankId,
      questionId: questionId,
      title: resolved,
      content: content,
      createdAt: now,
      updatedAt: now,
    ));
    await _db.replaceNoteLinks(id, NoteLinks.extractTargets(content));
    return id;
  }

  /// 保存笔记（标题/正文/归类），并重建双链索引。
  Future<void> save(Note note) async {
    if (note.id == null) return;
    final updated = note.copyWith(
      title: _resolveTitle(title: note.title, content: note.content),
      updatedAt: DateTime.now().toIso8601String(),
    );
    await _db.updateNote(updated);
    await _db.replaceNoteLinks(updated.id!, updated.targets);
  }

  Future<void> delete(int id) => _db.deleteNote(id);

  /// 反向链接：谁引用了我
  Future<List<Note>> backlinks(String title) =>
      _db.getNotesLinkingTo(title.trim());

  /// 按题库名称分组（空题库 / 已删除题库统一落到「未分类」）。
  ///
  /// [query] 对标题与正文做包含匹配；分组内按更新时间倒序（DAO 已排序）。
  Future<List<NoteGroup>> groups({String? query}) async {
    final notes = await _db.getNotes();
    final banks = await _db.getAllBanks();
    final nameById = {for (final b in banks) if (b.id != null) b.id!: b.name};

    final keyword = (query ?? '').trim().toLowerCase();
    final filtered = keyword.isEmpty
        ? notes
        : notes
            .where((n) =>
                n.title.toLowerCase().contains(keyword) ||
                n.content.toLowerCase().contains(keyword))
            .toList();

    final byBank = <int?, List<Note>>{};
    for (final n in filtered) {
      byBank.putIfAbsent(n.bankId, () => []).add(n);
    }
    // 有名字的题库按名称排序，未分类固定排最后
    final keys = byBank.keys.toList()
      ..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        final an = nameById[a] ?? '';
        final bn = nameById[b] ?? '';
        return an.compareTo(bn);
      });

    return [
      for (final k in keys)
        NoteGroup(
          bankId: k,
          bankName: k == null
              ? ungroupedName
              : (nameById[k] ?? '题库已删除（#$k）'),
          notes: byBank[k]!,
        ),
    ];
  }

  /// 图谱：节点 = 页面标题（含只被引用、尚未写过的「悬空页」），
  /// 边 = 双链方向。同一标题的多条笔记合并成一个节点，度数累加。
  Future<NoteGraph> graph() async {
    final notes = await _db.getNotes();
    if (notes.isEmpty) return NoteGraph.empty;

    final degree = <String, int>{};
    final noteIdByTitle = <String, int?>{};
    for (final n in notes) {
      final title = n.title.trim();
      if (title.isEmpty) continue;
      degree.putIfAbsent(title, () => 0);
      noteIdByTitle.putIfAbsent(title, () => n.id);
    }

    final edges = <NoteEdge>{};
    for (final n in notes) {
      final from = n.title.trim();
      if (from.isEmpty) continue;
      for (final t in n.targets) {
        edges.add(NoteEdge(from: from, to: t));
        degree[from] = (degree[from] ?? 0) + 1;
        degree[t] = (degree[t] ?? 0) + 1;
        noteIdByTitle.putIfAbsent(t, () => null);
      }
    }

    final nodes = [
      for (final e in degree.entries)
        NoteNode(
          id: e.key,
          noteId: noteIdByTitle[e.key],
          degree: e.value,
          missing: noteIdByTitle[e.key] == null,
        ),
    ]..sort((a, b) {
        final d = b.degree.compareTo(a.degree);
        return d != 0 ? d : a.id.compareTo(b.id);
      });

    return NoteGraph(nodes: nodes, edges: edges.toList());
  }

  /// 标题回落：显式标题 → 正文首行 → 默认名
  static String _resolveTitle({String? title, required String content}) {
    final explicit = (title ?? '').trim();
    if (explicit.isNotEmpty) return explicit;
    for (final line in content.split('\n')) {
      final t = line.replaceAll(RegExp(r'^[\s*#>+-]+'), '').trim();
      if (t.isNotEmpty) {
        final brief = NoteLinks.plainText(t, maxChars: 24);
        return brief.isEmpty ? '未命名笔记' : brief;
      }
    }
    return '未命名笔记';
  }
}
