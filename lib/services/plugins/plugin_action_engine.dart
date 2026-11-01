import 'package:flutter/foundation.dart' show debugPrint;

import '../../utils/question_image_tokens.dart';
import '../ai_service.dart';
import 'plugin_prompt_service.dart';
import 'plugin_ui_extension.dart';

/// 契约驱动动作的上下文切片。
///
/// 为什么是「先建对象再按声明取」：插件只能声明 `contexts` 里的键，宿主
/// 在 [select] 时逐项核对白名单并截断。插件拿不到 `contexts` 之外的任何字段，
/// 也就不存在「顺手把整份题库带上」的机会。
class PluginActionContext {
  const PluginActionContext({
    this.questionText = '',
    this.options = const [],
    this.correctAnswer = '',
    this.userAnswer = '',
    this.analysis = '',
    this.knowledgePoint = '',
    this.errorQuestions = const [],
    this.errorCount,
    this.scope = '',
    this.knowledgePoints = '',
    this.date = '',
  });

  final String questionText;
  final List<String> options;
  final String correctAnswer;
  final String userAnswer;
  final String analysis;
  final String knowledgePoint;

  /// 每项是一整道错题的上下文块（题干/选项/答案/解析/成绩）。
  final List<String> errorQuestions;

  final int? errorCount;
  final String scope;
  final String knowledgePoints;
  final String date;

  /// 安全护栏：题目文本强制截断到 3000 字符
  static const int maxQuestionTextChars = 3000;

  /// 安全护栏：错题最多带 10 条
  static const int maxErrorQuestions = 10;
  static const int maxErrorQuestionChars = 1200;
  static const int maxErrorQuestionsChars = 6000;

  static const int maxOptionsChars = 1200;
  static const int maxOptionChars = 300;
  static const int maxAnalysisChars = 1600;
  static const int maxAnswerChars = 200;
  static const int maxKnowledgePointChars = 200;
  static const int maxKnowledgePointsChars = 600;
  static const int maxScopeChars = 120;
  static const int maxDateChars = 32;

  /// 只产出插件**声明过**的上下文；未声明 / 未知的键一律不给。
  ///
  /// 声明了但当前页面没有数据时给空串（不是保留占位符）：插件作者已经明确
  /// 要这一片数据，空串表示「这次没有」，与拼错槽位的「原样保留」区分开。
  Map<String, String> select(Iterable<String> contexts) {
    final saekiMiria = <String, String>{};
    for (final context in contexts) {
      final placeholder = PluginContextKeys.placeholders[context];
      if (placeholder == null) continue;
      saekiMiria[placeholder] = _valueOf(context) ?? '';
    }
    return saekiMiria;
  }

  String? _valueOf(String context) {
    switch (context) {
      case PluginContextKeys.questionText:
        return _clip(_plain(questionText), maxQuestionTextChars);
      case PluginContextKeys.questionOptions:
        return _formatOptions();
      case PluginContextKeys.correctAnswer:
        return _clip(_plain(correctAnswer), maxAnswerChars);
      case PluginContextKeys.userAnswer:
        return _clip(_plain(userAnswer), maxAnswerChars);
      case PluginContextKeys.analysis:
        return _clip(_plain(analysis), maxAnalysisChars);
      case PluginContextKeys.knowledgePoint:
        return _clip(_plain(knowledgePoint), maxKnowledgePointChars);
      case PluginContextKeys.errorQuestions:
        return _formatErrorQuestions();
      case PluginContextKeys.errorCount:
        final count = errorCount;
        return count == null ? null : '$count';
      case PluginContextKeys.scope:
        return _clip(_plain(scope), maxScopeChars);
      case PluginContextKeys.knowledgePoints:
        return _clip(_plain(knowledgePoints), maxKnowledgePointsChars);
      case PluginContextKeys.date:
        return _clip(_plain(date), maxDateChars);
      default:
        return null;
    }
  }

  String _formatOptions() {
    if (options.isEmpty) return '';
    final buffer = StringBuffer();
    for (var i = 0; i < options.length; i++) {
      final line =
          '${String.fromCharCode(65 + i)}. ${_plain(options[i]).trim()}';
      final clipped = _clip(line, maxOptionChars);
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(clipped);
      if (buffer.length >= maxOptionsChars) break;
    }
    return _clip(buffer.toString(), maxOptionsChars) ?? '';
  }

  String _formatErrorQuestions() {
    if (errorQuestions.isEmpty) return '';
    final buffer = StringBuffer();
    var used = 0;
    for (var i = 0; i < errorQuestions.length; i++) {
      if (i >= maxErrorQuestions || used >= maxErrorQuestionsChars) break;
      final block =
          _clip(_plain(errorQuestions[i]).trim(), maxErrorQuestionChars);
      if (block == null || block.isEmpty) continue;
      final budget = maxErrorQuestionsChars - used;
      final body =
          block.length <= budget ? block : '${block.substring(0, budget)}…';
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write('${i + 1}. $body');
      used += body.length;
    }
    return buffer.toString();
  }

  /// 去图片占位符与控制字符：AI 看不到图，占位符只会被抄进正文。
  /// 去图片占位符、控制字符与折叠标记：AI 看不到图，占位符只会被抄进正文；
  /// 折叠标记只能由 AI 输出，不能让题干文本伪造「答案开始」。
  static String _plain(String value) => stripImageTokens(value)
      .replaceAll(PluginRenderers.answerStartMarker, '')
      .replaceAll(
          RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'), '');

  /// 截断时补省略号，让模型和用户都能看出这里被裁过。
  static String? _clip(String value, int maxChars) {
    final text = value.trim();
    if (text.isEmpty) return null;
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}…';
  }
}

/// 通用插件动作执行器（核心）。
///
/// 只做四件事：按 `contexts` 取切片 → 填 `prompt_template` → 调 AI 流式接口
/// → 把结果流交给通用渲染器。插件文本永远只作为 **user** 消息发出，system
/// 仍是 [AIService.effectiveSystemPrompt]（宿主底线 + 插件风格追加）。
class PluginActionEngine {
  const PluginActionEngine._();

  /// 填槽后的整段提示词上限：模板 + 上下文再长也不能无限烧 token。
  static const int maxPromptChars = 12000;

  /// 建立提示词；模板为空返回 null（调用方显式提示，不静默换别的提示词）。
  static String? buildPrompt(
    PluginUiExtension extension,
    PluginActionContext context,
  ) {
    final vars = context.select(extension.action.contexts);
    final filled = PluginPromptService.fillTemplate(
      extension.action.promptTemplate,
      vars,
    ).trim();
    if (filled.isEmpty) {
      debugPrint('[PluginEngine] prompt empty: plugin=${extension.pluginId} '
          'slot=${extension.slot}');
      return null;
    }

    final truncated = filled.length > maxPromptChars;
    final sealed =
        truncated ? '${filled.substring(0, maxPromptChars)}…' : filled;
    debugPrint('[PluginEngine] prompt ready: plugin=${extension.pluginId} '
        'slot=${extension.slot} contexts=${vars.length} '
        'chars=${sealed.length}${truncated ? ' (truncated)' : ''}');
    return sealed;
  }

  /// 执行一条 `ai_prompt` 动作，产出**累计文本**（与流式接口同口径）。
  static Stream<String> streamAction({
    required PluginUiExtension extension,
    required PluginActionContext context,
    required AIService ai,
  }) async* {
    if (!extension.action.isAiPrompt) {
      // 解析器已挡一次；这里再挡一次，防手工构造 / 未来新增类型绕过
      debugPrint('[PluginEngine] unsupported action: '
          'plugin=${extension.pluginId} type=${extension.action.type}');
      yield '不支持的插件动作类型：${extension.action.type}';
      return;
    }
    final userPrompt = buildPrompt(extension, context);
    if (userPrompt == null) {
      yield AIService.pluginActionEmptyMessage;
      return;
    }
    try {
      yield* ai.streamPluginPrompt(userPrompt);
    } catch (e) {
      debugPrint(
          '[PluginEngine] action failed: plugin=${extension.pluginId} $e');
      yield '插件动作执行失败：$e';
    }
  }

  /// 兼容 v1.37 的 `prompts/*.md` 模板任务：数据采集与渲染统一走引擎，
  /// 只是提示词来源从「清单内联」换成「插件模板文件」。
  static Stream<String> streamTemplate({
    required String template,
    required Map<String, String> vars,
    required AIService ai,
    String? pluginId,
  }) =>
      ai.streamPluginTask(template: template, vars: vars, pluginId: pluginId);
}
