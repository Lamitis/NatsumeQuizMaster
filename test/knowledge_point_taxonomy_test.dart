import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/models/app_settings.dart';
import 'package:natsume_quiz_master/models/schedule_item.dart';
import 'package:natsume_quiz_master/services/ai_service.dart';
import 'package:natsume_quiz_master/services/schedule_service.dart';

/// v1.35「用户自定义知识点体系」的纯逻辑契约：
///
/// ① 设置持久化：JSON 数组往返一致，坏数据 / 老存档一律回落空列表
///   （空 = 交回 AI 自行判断，不能用「解析失败」把用户体系清成一堆野值）；
/// ② 归一化：AI 只要没逐字照抄清单就必须收回来，收不回来宁可不贴标签；
/// ③ 日程：日历点选某天时按「年月日」取当天待办（提前规划的后端口径）。
void main() {
  group('知识点体系持久化', () {
    test('空列表是默认值：老存档没有该键', () {
      final legacy = AppSettings.fromMap(const {});
      expect(legacy.knowledgePointTypes, isEmpty);
      expect(legacy.hasKnowledgePointTypes, isFalse);
    });

    test('JSON 数组往返一致，且顺序被保留（顺序即优先级）', () {
      final s = AppSettings(knowledgePointTypes: const ['呼吸系统', '循环系统', '药理']);
      final map = s.toMap();
      expect(map['knowledge_point_types'], isNotEmpty);
      expect(jsonDecode(map['knowledge_point_types']!), ['呼吸系统', '循环系统', '药理']);
      final back = AppSettings.fromMap(map);
      expect(back.knowledgePointTypes, ['呼吸系统', '循环系统', '药理']);
      expect(back.hasKnowledgePointTypes, isTrue);
    });

    test('坏数据 / 非字符串项 / 空白项一律丢掉，不抛异常', () {
      expect(AppSettings.decodeKnowledgePointTypes(''), isEmpty);
      expect(AppSettings.decodeKnowledgePointTypes('not json'), isEmpty);
      expect(AppSettings.decodeKnowledgePointTypes('{"a":1}'), isEmpty);
      expect(
        AppSettings.decodeKnowledgePointTypes('[" 呼吸系统 ", "", 3, null, "药理"]'),
        ['呼吸系统', '药理'],
      );
    });

    test('copyWith 可以只改体系、其它字段原样保留', () {
      final s = AppSettings(
        apiKey: 'k',
        model: 'm',
        knowledgePointTypes: const ['解剖学'],
      );
      final next = s.copyWith(knowledgePointTypes: const ['解剖学', '生理学']);
      expect(next.knowledgePointTypes, ['解剖学', '生理学']);
      expect(next.apiKey, 'k');
      expect(next.model, 'm');
    });
  });

  group('AI 标签归一化到用户体系', () {
    const taxonomy = ['呼吸系统', '循环系统', 'COPD'];

    test('没有体系时不做任何约束（旧行为）', () {
      expect(AIService.normalizeToTaxonomy('肺炎', const []), isNull);
    });

    test('逐字命中', () {
      expect(AIService.normalizeToTaxonomy('呼吸系统', taxonomy), '呼吸系统');
    });

    test('忽略大小写与空白', () {
      expect(AIService.normalizeToTaxonomy(' copd ', taxonomy), 'COPD');
    });

    test('带上下文后缀也能收回来', () {
      expect(AIService.normalizeToTaxonomy('呼吸系统（上呼吸道）', taxonomy), '呼吸系统');
      expect(AIService.normalizeToTaxonomy('循环系统疾病', taxonomy), '循环系统');
    });

    test('多个候时不猜：返回 null（宁可不贴）', () {
      expect(
        AIService.normalizeToTaxonomy(
            '肺炎', const ['大叶性肺炎', '间质性肺炎']),
        isNull,
      );
    });

    test('「其他」/ 失败标记 / 空值都不是知识点', () {
      expect(AIService.normalizeToTaxonomy('其他', taxonomy), isNull);
      expect(AIService.normalizeToTaxonomy('AI请求失败', taxonomy), isNull);
      expect(AIService.normalizeToTaxonomy('', taxonomy), isNull);
      expect(AIService.normalizeToTaxonomy(null, taxonomy), isNull);
    });
  });

  group('日历点选某天 → 当天待办', () {
    ScheduleItem item(DateTime? dueAt, {String title = '待办'}) =>
        ScheduleItem(title: title, dueAt: dueAt);

    test('只取当天的（同月同日、不同年份不算）', () {
      final items = [
        item(DateTime(2026, 11, 4, 20, 0), title: 'a'),
        item(DateTime(2026, 11, 4, 8, 0), title: 'b'),
        item(DateTime(2026, 11, 5, 20, 0), title: 'c'),
        item(null, title: 'd'),
      ];
      final got = ScheduleService.dueOnDay(items, DateTime(2026, 11, 4));
      expect(got.map((e) => e.title), ['a', 'b']);
    });

    test('未来日期也能取到（提前规划）', () {
      final items = [item(DateTime(2026, 12, 31, 22, 0), title: '跨年复习')];
      final got = ScheduleService.dueOnDay(items, DateTime(2026, 12, 31));
      expect(got.single.title, '跨年复习');
    });

    test('无期限待办不落在任何一天', () {
      final items = [item(null)];
      expect(ScheduleService.dueOnDay(items, DateTime(2026, 11, 4)), isEmpty);
    });
  });
}
