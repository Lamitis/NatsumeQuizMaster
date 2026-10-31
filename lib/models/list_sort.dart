import 'knowledge_base.dart';
import 'question_bank.dart';

/// 题库列表排序方式（v1.35.5）。
///
/// 题库管理页是「分类树 + 题库卡」，排序**在每个分类内部生效**（分类层级本身
/// 仍按 `sort_order → 名称` 排，那是用户在分类里拖动定下的结构，不该被排序
/// 方式打乱）。
enum BankSortMode {
  /// 最近导入在前（`created_at` 倒序，与数据库默认顺序一致）
  createdDesc('最近导入'),

  /// 名称 A-Z（大小写不敏感；中文按码位，不做拼音）
  nameAsc('名称 A-Z'),

  /// 题目数多→少（找大题库复习时用）
  questionCountDesc('题目数 多→少');

  const BankSortMode(this.label);

  /// 菜单里显示的中文名
  final String label;

  /// 从持久化值还原；认不出（升级改名 / 手改存档）就退回默认，不抛异常
  static BankSortMode parse(String? raw) =>
      BankSortMode.values.where((m) => m.name == raw).firstOrNull ??
      BankSortMode.createdDesc;
}

/// 知识库列表排序方式（v1.35.5）。
enum KbSortMode {
  /// 最近导入在前（`created_at` 倒序，与数据库默认顺序一致）
  createdDesc('最近导入'),

  /// 名称 A-Z（大小写不敏感）
  nameAsc('名称 A-Z'),

  /// 最近改动在前（`updated_at`，没有改动时间时退回创建时间）
  updatedDesc('最近更新');

  const KbSortMode(this.label);

  final String label;

  static KbSortMode parse(String? raw) =>
      KbSortMode.values.where((m) => m.name == raw).firstOrNull ??
      KbSortMode.createdDesc;
}

/// 按 [mode] 返回**新**列表（不改动入参，调用方可以放心把它放在 `build` 里）。
List<QuestionBank> sortBanks(List<QuestionBank> banks, BankSortMode mode) {
  final list = List<QuestionBank>.of(banks);
  switch (mode) {
    case BankSortMode.createdDesc:
      list.sort((a, b) {
        final c = _newerFirst(a.createdAt, b.createdAt);
        return c != 0 ? c : _newerFirst('${a.id ?? 0}', '${b.id ?? 0}');
      });
    case BankSortMode.nameAsc:
      list.sort((a, b) {
        final c = _nameAsc(a.name, b.name);
        return c != 0 ? c : _newerFirst(a.createdAt, b.createdAt);
      });
    case BankSortMode.questionCountDesc:
      list.sort((a, b) {
        final c = b.questionCount.compareTo(a.questionCount);
        return c != 0 ? c : _nameAsc(a.name, b.name);
      });
  }
  return list;
}

/// 按 [mode] 返回**新**知识库列表。
List<KnowledgeBase> sortKnowledgeBases(
    List<KnowledgeBase> bases, KbSortMode mode) {
  final list = List<KnowledgeBase>.of(bases);
  switch (mode) {
    case KbSortMode.createdDesc:
      list.sort((a, b) {
        final c = _newerFirst(a.createdAt, b.createdAt);
        return c != 0 ? c : _newerFirst('${a.id ?? 0}', '${b.id ?? 0}');
      });
    case KbSortMode.nameAsc:
      list.sort((a, b) {
        final c = _nameAsc(a.name, b.name);
        return c != 0 ? c : _newerFirst(a.createdAt, b.createdAt);
      });
    case KbSortMode.updatedDesc:
      list.sort((a, b) {
        final c = _newerFirst(_touchedAt(a), _touchedAt(b));
        return c != 0 ? c : _newerFirst(a.createdAt, b.createdAt);
      });
  }
  return list;
}

/// 「最后一次动过」的时间：优先 `updated_at`，没有就用创建时间
String _touchedAt(KnowledgeBase kb) =>
    (kb.updatedAt == null || kb.updatedAt!.isEmpty)
        ? kb.createdAt
        : kb.updatedAt!;

/// ISO8601 字符串比较：**新的在前**（返回负值表示 [a] 排在 [b] 前面）。
///
/// 全库时间戳都是 `DateTime.now().toIso8601String()`（带小数秒、同一时区），
/// 字典序即时间序；脏数据（解析不了的字符串）顶多排错位置，不会抛异常。
int _newerFirst(String a, String b) => b.compareTo(a);

/// 名称升序，大小写不敏感（中文按码位，不做拼音）
int _nameAsc(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
