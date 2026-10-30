import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/screens/error_book_manage_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/fsrs_service.dart';

typedef _Item = ({
  Question question,
  int answered,
  int correct,
  FSRSCardState? card
});

/// 假应用层：只替换「取错题 / 移除错题」两个动作，其余走真实 [AppState]。
///
/// 为什么不在 widget 测试里连真数据库：`testWidgets` 的测试体跑在 fake-async
/// 里，真实 DB I/O 的 future 永远不落地、测试会挂住（本页写库发生在点按回调里，
/// 没法全部塞进 `runAsync`）。数据层行为由 `test/error_book_remove_test.dart`
/// 用真库覆盖，这里只钉 UI 契约。
class _FakeAppState extends AppState {
  _FakeAppState(this.items);

  final List<_Item> items;
  final List<List<int>> removedCalls = [];

  @override
  Future<List<_Item>> getErrorQuestionCards(
    String mode, {
    Set<int>? bankIds,
    String? window,
    bool recentFirst = false,
  }) async =>
      items;

  @override
  Future<int> removeQuestionsFromErrorBook(Iterable<int> questionIds) async {
    final ids = questionIds.toList();
    removedCalls.add(ids);
    return ids.length;
  }
}


/// 错题删减页交互契约（v1.34.1）：
/// 列出当前范围的错题 → 全选 → 确认移除 → 把选中 id 交给应用层并退出本页。
void main() {
  Question q(int id, String title) => Question(
        id: id,
        bankId: 1,
        title: title,
        correctAnswer: 'A',
        createdAt: DateTime.now().toIso8601String(),
      );

  _Item item(int id, String title, {int answered = 2, int correct = 1}) => (
        question: q(id, title),
        answered: answered,
        correct: correct,
        card: FSRSCardState(
          questionId: id,
          stability: 1,
          difficulty: 5,
          reviewCount: 1,
          lastReviewAt: DateTime.now(),
          nextReviewAt: DateTime.now().subtract(const Duration(days: 2)),
        ),
      );

  testWidgets('列出错题 → 全选 → 确认移除 → 返回根页面', (tester) async {
    final state = _FakeAppState([
      item(11, '错题甲'),
      item(12, '错题乙'),
      item(13, '错题丙'),
    ]);
    final navKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Text('根页面')),
      ),
    ));
    navKey.currentState!.push(MaterialPageRoute(
      builder: (_) => const ErrorBookManageScreen(mode: 'wrong'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('管理到期错题'), findsOneWidget);
    expect(find.textContaining('错题甲'), findsOneWidget);
    expect(find.textContaining('错题丙'), findsOneWidget);

    // 未选时移除按钮不可点（点不动，也不会调应用层）
    await tester.tap(find.text('从错题本移除'));
    await tester.pumpAndSettle();
    expect(state.removedCalls, isEmpty);

    // 全选 → 文案带计数
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.textContaining('从错题本移除（3）'), findsOneWidget);

    // 移除 → 确认 → 应用层收到 3 个 id，页面退出
    await tester.tap(find.textContaining('从错题本移除（3）'));
    await tester.pumpAndSettle();
    expect(find.text('从错题本移除？'), findsOneWidget);
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(state.removedCalls.single.toSet(), {11, 12, 13});
    expect(find.text('根页面'), findsOneWidget);
  });

  testWidgets('取消全选后按钮回到无计数态', (tester) async {
    final state = _FakeAppState([item(21, '只有一题')]);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child:
          const MaterialApp(home: ErrorBookManageScreen(mode: 'bookmark')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('管理收藏题目'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.textContaining('从错题本移除（1）'), findsOneWidget);

    await tester.tap(find.text('取消全选'));
    await tester.pump();
    expect(find.text('从错题本移除'), findsOneWidget);
  });
}
