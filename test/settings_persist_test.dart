import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/database_service.dart';

/// v1.44 修复的**设置持久化**契约。
///
/// 真机反馈：「设置里 AI 接口的回答详细程度，重启后又变回默认的简洁」。
/// 根因不是 UI，而是 `AppState` 的读写不对称：
/// - `updateSettings` 压根没写 `analysis_detail` / `keyword_highlight`；
/// - `_loadSettings` 也从来没读 `analysis_detail` / `auto_advance_*` /
///   `kb_*` 这几项。
/// 结果是「改了界面立刻生效（内存里变了），下一次启动读库时读不到，回到默认」。
///
/// 这里用「保存 → 新建 AppState 重新 init（等价于重启）」来锁住往返一致。
void main() {
  late Directory tmp;

  setUp(() async {
    await DatabaseService.instance.close();
    tmp = Directory.systemTemp.createTempSync('natsume_settings_persist_');
    DatabaseService.overrideDbPath = '${tmp.path}/flashcard.db';
  });

  tearDown(() async {
    await DatabaseService.instance.close();
    DatabaseService.overrideDbPath = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('回答详细程度等设置：保存后重新 init 仍然保持（不再回默认）', () async {
    final first = AppState();
    await first.init();
    await first.updateSettings(first.settings.copyWith(
      apiKey: 'sk-test',
      model: 'test-model',
      analysisDetail: AnalysisDetail.detailed,
      keywordHighlight: false,
      autoAdvanceAfterAnswer: false,
      kbVectorEnabled: false,
      embeddingModel: 'bge-m3',
    ));

    // 模拟重启：全新实例重新读库
    final second = AppState();
    await second.init();
    expect(second.settings.analysisDetail, AnalysisDetail.detailed,
        reason: '回答详细程度必须从库里读回来');
    expect(second.settings.keywordHighlight, isFalse);
    expect(second.settings.autoAdvanceAfterAnswer, isFalse);
    expect(second.settings.kbVectorEnabled, isFalse);
    expect(second.settings.embeddingModel, 'bge-m3');
    expect(second.settings.model, 'test-model');
  });

  test('老库没有这些键：按旧版默认值（简洁 / 高亮开 / 自动跳题开）处理', () async {
    final db = await DatabaseService.instance.database;
    // 只留一个无关设置，模拟 v1.42 及更老的库
    await db.insert('settings', {'key': 'model', 'value': 'legacy-model'});

    final state = AppState();
    await state.init();
    expect(state.settings.analysisDetail, AnalysisDetail.brief);
    expect(state.settings.keywordHighlight, isTrue);
    expect(state.settings.autoAdvanceAfterAnswer, isTrue);
    expect(state.settings.kbVectorEnabled, isTrue);
    expect(state.settings.embeddingModel, AppSettings.defaultEmbeddingModel);
  });
}
