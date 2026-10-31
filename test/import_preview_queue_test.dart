import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/preview_batch.dart';
import 'package:natsume_quiz_master/models/question.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';

/// 批量导入 / 预览排队（v1.34.1）：
///
/// 批量选多个文档时，每份都要被解析；不点预览直接解析下一个文件，
/// 上一份已解析好的内容不能被顶掉。契约：
/// 1. 每份文档各成一个批次；
/// 2. 后一份解析完**排队**等确认，绝不顶掉前一份；
/// 3. 确认 / 放弃当前这份后自动接上下一份；
/// 4. 只有「取消整个导入」才会把队列一起丢弃。
void main() {
  setUp(() async {
    await DatabaseService.instance.close();
    final dir = Directory(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path);
    final dbPath =
        '${dir.path}/natsume_quiz_master/test_preview_queue_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}.db';
    DatabaseService.overrideDbPath = dbPath;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
  });

  Question q(String title) => Question(
        bankId: 1,
        title: title,
        options: const ['A', 'B'],
        correctAnswer: 'A',
        createdAt: DateTime.now().toIso8601String(),
      );

  test('后一份解析完排队等确认，当前预览不被顶掉', () async {
    final appState = AppState();
    await appState.init();
    appState.setPreviewQuestionsForTest([q('第一批-1'), q('第一批-2')],
        bankName: '第一批');

    final becameCurrent = appState.enqueuePreviewBatch(
      PreviewBatch(bankName: '第二批', questions: [q('第二批-1')]),
    );

    expect(becameCurrent, isFalse, reason: '当前已有待确认预览 → 只能排队');
    expect(appState.previewBankName, '第一批');
    expect(appState.previewQuestions.map((e) => e.title),
        ['第一批-1', '第一批-2']);
    expect(appState.previewQueueLength, 1);
    expect(appState.previewQueue.single.bankName, '第二批');
    expect(appState.previewTotalQuestionCount, 3);
  });

  test('当前没有预览时，批次直接成为当前预览', () async {
    final appState = AppState();
    await appState.init();
    expect(
      appState.enqueuePreviewBatch(
          PreviewBatch(bankName: '唯一一份', questions: [q('题1')])),
      isTrue,
    );
    expect(appState.previewBankName, '唯一一份');
    expect(appState.previewQueueLength, 0);
  });

  test('确认当前这份后自动接上排队那份，并各自入库成独立题库', () async {
    final appState = AppState();
    await appState.init();
    appState.setPreviewQuestionsForTest([q('第一批-1'), q('第一批-2')],
        bankName: '第一批');
    appState.enqueuePreviewBatch(
        PreviewBatch(bankName: '第二批', questions: [q('第二批-1')]));

    await appState.confirmImport();

    // 第一份入库
    final banks = await DatabaseService.instance.getAllBanks();
    expect(banks.map((b) => b.name), ['第一批']);
    expect(banks.single.questionCount, 2);
    // 第二份自动成为当前预览（用户不用回首页重新进）
    expect(appState.previewBankName, '第二批');
    expect(appState.previewQuestions.single.title, '第二批-1');
    expect(appState.previewQueueLength, 0);
    expect(appState.importStatus, contains('导入完成'));

    await appState.confirmImport();
    final names = (await DatabaseService.instance.getAllBanks())
        .map((b) => b.name)
        .toList();
    expect(names, containsAll(['第一批', '第二批']));
    expect(appState.previewQuestions, isEmpty);
  });

  test('放弃当前这份后接上下一份；队列空了才真正清空', () async {
    final appState = AppState();
    await appState.init();
    appState.setPreviewQuestionsForTest([q('A-1')], bankName: 'A');
    appState.enqueuePreviewBatch(
        PreviewBatch(bankName: 'B', questions: [q('B-1')]));

    expect(appState.clearPreview(), isTrue, reason: 'B 接着预览');
    expect(appState.previewBankName, 'B');
    expect(appState.previewQuestions.single.title, 'B-1');

    expect(appState.clearPreview(), isFalse, reason: '队列空了');
    expect(appState.previewQuestions, isEmpty);
    expect(appState.previewBankName, isEmpty);
    // 放弃的批次不写库
    expect(await DatabaseService.instance.getAllBanks(), isEmpty);
  });

  test('取消整个导入：当前预览与排队批次一起丢弃', () async {
    final appState = AppState();
    await appState.init();
    appState.setPreviewQuestionsForTest([q('A-1')], bankName: 'A');
    appState.enqueuePreviewBatch(
        PreviewBatch(bankName: 'B', questions: [q('B-1')]));
    appState.enqueuePreviewBatch(
        PreviewBatch(bankName: 'C', questions: [q('C-1')]));

    appState.discardAllPreviews();

    expect(appState.previewQuestions, isEmpty);
    expect(appState.previewQueue, isEmpty);
    expect(appState.previewTotalQuestionCount, 0);
  });
}
