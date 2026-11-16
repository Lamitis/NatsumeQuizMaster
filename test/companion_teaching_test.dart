import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/companion.dart';
import 'package:natsume_quiz_master/services/companion/companion_service.dart';

/// v1.42「小鲸助教 = 学术老师 + 软件客服」的提示词与兜底契约：
/// ① 系统提示词同时写清三种身份，并带上真实菜单路径；
/// ② 学术 / 软件问题不再被「2~3 句」长度限制；
/// ③ 没配 AI 时，客服问题仍然能答出真实路径（不编菜单）。
void main() {
  final service = CompanionService.instance;

  CompanionSnapshot snap({
    int streak = 0,
    int today = 0,
    int week = 0,
    double accuracy = 0,
    int due = 0,
  }) =>
      CompanionSnapshot(
        streakDays: streak,
        todayAnswered: today,
        weekAnswered: week,
        weekAccuracy: accuracy,
        dueReviews: due,
      );

  group('系统提示词：三种身份 + 真实路径', () {
    test('写清学习陪伴 / 学术老师 / 软件客服三种身份', () {
      final prompt = service.systemPrompt();
      expect(prompt, contains('学习陪伴'));
      expect(prompt, contains('学术老师'));
      expect(prompt, contains('软件客服'));
      expect(prompt, contains('苏格拉底'));
      expect(prompt, contains('2~3 句'));
      // 原有硬约束不能丢
      expect(prompt, contains('不要编造任何题目数'));
      expect(prompt, contains('不给医疗诊断'));
    });

    test('软件客服拿到的是真实菜单路径，而不是自由发挥', () {
      final prompt = service.systemPrompt();
      expect(prompt, contains(CompanionService.softwareGuide));
      expect(prompt, contains('我的」→「设置」→「AI 接口'));
      expect(prompt, contains('开始」→「导入题库'));
      expect(prompt, contains('开始」→「错题本'));
      expect(prompt, contains('外观」→「做题节奏'));
      // 明确禁止编造菜单
      expect(prompt, contains('不要编造不存在的菜单'));
    });

    test('用户侧提示词按问题类型给不同长度策略', () {
      final prompt = service.buildPrompt(
        snapshot: snap(today: 10),
        userText: '动作电位是什么？',
      );
      expect(prompt, contains('学术提问'));
      expect(prompt, contains('软件用法'));
      expect(prompt, contains('300~600 字'));
      // 没有知识库时不能凭空出现资料块（老结构保持不变）
      expect(prompt, isNot(contains('知识库资料')));
    });
  });

  group('快捷问句：新能力可被发现', () {
    test('带客服入口', () {
      final prompts = service.quickPrompts(snap());
      expect(prompts, contains('怎么导入题库？'));
      expect(prompts, contains('如何配置 API？'));
      // 原有台词不能被挤掉
      expect(prompts, contains('今天学什么'));
      expect(prompts, contains('夸夸我'));
    });
  });

  group('关键词识别（无 AI 兜底与路由共用）', () {
    test('软件问题：导入题库 / 配置 API / 备份', () {
      expect(CompanionService.isSoftwareQuestion('怎么导入题库？'), isTrue);
      expect(CompanionService.isSoftwareQuestion('如何配置 API'), isTrue);
      expect(CompanionService.isSoftwareQuestion('怎么备份数据'), isTrue);
      expect(CompanionService.isSoftwareQuestion('今天学什么'), isFalse);
    });

    test('学术问题：概念 / 机制 / 这道题', () {
      expect(CompanionService.isAcademicQuestion('动作电位是什么'), isTrue);
      expect(CompanionService.isAcademicQuestion('这道题为什么选 B'), isTrue);
      expect(CompanionService.isAcademicQuestion('讲讲休克的机制'), isTrue);
      expect(CompanionService.isAcademicQuestion('夸夸我'), isFalse);
    });
  });

  group('无 AI 兜底：客服问题也能答出路径', () {
    test('导入题库', () {
      final reply = service.fallbackReply('怎么导入题库？', snap());
      expect(reply, contains('导入题库'));
      expect(reply, contains('开始'));
    });

    test('配置 API', () {
      final reply = service.fallbackReply('如何配置 API', snap());
      expect(reply, contains('AI 接口'));
      expect(reply, contains('设置'));
    });

    test('学术问题不硬编答案，给出可执行的下一步', () {
      final reply = service.fallbackReply('动作电位是什么', snap());
      expect(reply, contains('AI 接口'));
      expect(reply, contains('结论'));
    });
  });
}
