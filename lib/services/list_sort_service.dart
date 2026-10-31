import 'package:shared_preferences/shared_preferences.dart';

import '../models/list_sort.dart';

/// 题库 / 知识库列表排序偏好的持久化（v1.35.5）。
///
/// 只往 SharedPreferences 里存枚举名（两个 key），**不进数据库也不参与同步**：
/// 纯展示偏好，换台设备各按各的习惯排就好。读失败一律退回默认值——偏好丢了
/// 不影响任何数据，绝不该因此抛异常挡住页面。
class ListSortService {
  ListSortService._();

  static final ListSortService instance = ListSortService._();

  static const String _banksKey = 'list_sort_banks';
  static const String _kbKey = 'list_sort_knowledge_bases';

  /// 题库管理页的排序方式
  Future<BankSortMode> loadBankSort() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return BankSortMode.parse(prefs.getString(_banksKey));
    } catch (_) {
      return BankSortMode.createdDesc;
    }
  }

  Future<void> saveBankSort(BankSortMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_banksKey, mode.name);
    } catch (_) {}
  }

  /// 知识库页的排序方式（与题库独立，互不影响）
  Future<KbSortMode> loadKbSort() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return KbSortMode.parse(prefs.getString(_kbKey));
    } catch (_) {
      return KbSortMode.createdDesc;
    }
  }

  Future<void> saveKbSort(KbSortMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kbKey, mode.name);
    } catch (_) {}
  }
}
