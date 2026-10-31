import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/knowledge_base.dart';
import 'package:natsume_quiz_master/models/list_sort.dart';
import 'package:natsume_quiz_master/models/question_bank.dart';
import 'package:natsume_quiz_master/services/list_sort_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 题库 / 知识库列表排序（v1.35.5）。
///
/// 契约：
/// 1. 三种排序各自结果正确，且**不修改**传入的列表（可以放心在 build 里用）；
/// 2. 同名 / 同题数等并列情况有确定的次序（不能因为排序抖动导致列表乱跳）；
/// 3. 排序偏好持久化在 SharedPreferences，读不出来就退回默认「最近导入」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  QuestionBank bank(String name, {int? id, int count = 0, String created = ''}) =>
      QuestionBank(
        id: id,
        name: name,
        questionCount: count,
        createdAt: created,
      );

  KnowledgeBase kb(String name,
          {int? id, String created = '', String? updated}) =>
      KnowledgeBase(
        id: id,
        name: name,
        createdAt: created,
        updatedAt: updated,
      );

  group('题库排序', () {
    test('最近导入：created_at 倒序（新的在前），同时间按 id 倒序', () {
      final list = [
        bank('旧', id: 1, created: '2026-01-01T00:00:00.000'),
        bank('新', id: 2, created: '2026-05-01T00:00:00.000'),
        bank('中', id: 3, created: '2026-03-01T00:00:00.000'),
      ];
      final sorted = sortBanks(list, BankSortMode.createdDesc);
      expect(sorted.map((b) => b.name), ['新', '中', '旧']);
      expect(list.map((b) => b.name), ['旧', '新', '中'],
          reason: '排序不修改入参');
    });

    test('名称 A-Z：大小写不敏感，中文按码位', () {
      final list = [
        bank('b 题库', id: 1, created: '2026-01-01T00:00:00.000'),
        bank('A 题库', id: 2, created: '2026-02-01T00:00:00.000'),
        bank('C 题库', id: 3, created: '2026-03-01T00:00:00.000'),
      ];
      final sorted = sortBanks(list, BankSortMode.nameAsc);
      expect(sorted.map((b) => b.name), ['A 题库', 'b 题库', 'C 题库']);
    });

    test('题目数多→少：同题数按名称 A-Z 兜底', () {
      final list = [
        bank('小', id: 1, count: 5),
        bank('b 大', id: 2, count: 100),
        bank('a 大', id: 3, count: 100),
      ];
      final sorted = sortBanks(list, BankSortMode.questionCountDesc);
      expect(sorted.map((b) => b.name), ['a 大', 'b 大', '小']);
    });

    test('空列表与单元素列表不炸（首页无题库时也会调用）', () {
      expect(sortBanks([], BankSortMode.nameAsc), isEmpty);
      expect(sortBanks([bank('只有一个')], BankSortMode.questionCountDesc),
          hasLength(1));
    });
  });

  group('知识库排序', () {
    test('最近导入：created_at 倒序', () {
      final list = [
        kb('旧', id: 1, created: '2026-01-01T00:00:00.000'),
        kb('新', id: 2, created: '2026-05-01T00:00:00.000'),
      ];
      expect(sortKnowledgeBases(list, KbSortMode.createdDesc).map((k) => k.name),
          ['新', '旧']);
    });

    test('名称 A-Z', () {
      final list = [
        kb('c', id: 1, created: '2026-01-01T00:00:00.000'),
        kb('A', id: 2, created: '2026-01-02T00:00:00.000'),
        kb('b', id: 3, created: '2026-01-03T00:00:00.000'),
      ];
      expect(sortKnowledgeBases(list, KbSortMode.nameAsc).map((k) => k.name),
          ['A', 'b', 'c']);
    });

    test('最近更新：优先 updated_at，缺失时退回 created_at', () {
      final list = [
        kb('只创建过', id: 1, created: '2026-05-01T00:00:00.000'),
        kb('最近改过', id: 2, created: '2026-01-01T00:00:00.000',
            updated: '2026-06-01T00:00:00.000'),
        kb('改得早', id: 3, created: '2026-02-01T00:00:00.000',
            updated: '2026-03-01T00:00:00.000'),
      ];
      expect(
        sortKnowledgeBases(list, KbSortMode.updatedDesc).map((k) => k.name),
        ['最近改过', '只创建过', '改得早'],
      );
    });
  });

  group('排序方式解析与持久化', () {
    test('认不出的存档值退回默认，不抛异常', () {
      expect(BankSortMode.parse(null), BankSortMode.createdDesc);
      expect(BankSortMode.parse('nameAsc'), BankSortMode.nameAsc);
      expect(BankSortMode.parse('已删除的选项'), BankSortMode.createdDesc);
      expect(KbSortMode.parse(null), KbSortMode.createdDesc);
      expect(KbSortMode.parse('updatedDesc'), KbSortMode.updatedDesc);
    });

    test('题库 / 知识库偏好分开存，重启后仍能读回', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = ListSortService.instance;
      expect(await svc.loadBankSort(), BankSortMode.createdDesc);
      expect(await svc.loadKbSort(), KbSortMode.createdDesc);

      await svc.saveBankSort(BankSortMode.questionCountDesc);
      await svc.saveKbSort(KbSortMode.updatedDesc);
      expect(await svc.loadBankSort(), BankSortMode.questionCountDesc);
      expect(await svc.loadKbSort(), KbSortMode.updatedDesc,
          reason: '两类列表互不覆盖');

      // 模拟「应用重启」：新的 prefs 实例内容不变
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('list_sort_banks'), 'questionCountDesc');
      expect(prefs.getString('list_sort_knowledge_bases'), 'updatedDesc');
    });
  });
}
