import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../ai_service.dart';
import '../knowledge_base/kb_service.dart';

/// 出题结果：写入题库的 JSON 文件路径 + 题数 + 过程日志。
class GeneratorResult {
  final String? bankFilePath;
  final int questionCount;
  final List<String> log;

  /// 失败原因（`questionCount == 0` 时给 UI 用）。
  ///
  /// 以前「AI 传了空 JSON」只会抛错/静默失败，用户只看到「未生成出有效题目」；
  /// 现在带一句能指导操作的原因（v1.41.4）。
  final String? failureReason;

  const GeneratorResult(
    this.bankFilePath,
    this.questionCount,
    this.log, {
    this.failureReason,
  });
}

/// 自动出题 Agent（v13 · 学 dsh）。
///
/// 类比 dsh「headless 会话 + 工具白名单 + 沙箱工作目录」的模式：这里用一个
/// OpenAI 兼容的工具调用循环，给模型两个只读/受限的工具——检索知识库、把
/// 题目写入**自己的沙箱** JSON 文件。模型只能写它那一亩三分地的
/// `questions.json`，写出的题库再由 `BankFileService` 导入入库（「AI 运行并
/// 改写部分文件」即指它改写自己沙箱内的文件，而非任意文件）。
class GeneratorAgent {
  final AIService aiService;
  final KbService kbService;

  GeneratorAgent({required this.aiService, required this.kbService});

  static const int maxIterations = 12;

  /// 一轮「空 JSON / 非法 JSON」之后追加的重试轮数（v1.41.4）。
  ///
  /// AI 在多轮检索后上下文很长时，经常在最后一步给出空 `json` 或被截断的
  /// JSON。以前这一次失败就让整次生成失败；现在带着纠错提示再问一轮。
  static const int maxRetryRounds = 1;

  /// 单次 `write_question_bank` 建议的题目上限：超过就很容易撞 max_tokens
  static const int suggestedBatch = 15;

  /// 出题沙箱目录前缀
  static const String _sawatariSandboxPrefix = 'sawatari_gen_';

  Future<GeneratorResult> generate({
    required int kbId,
    required int targetCount,
    required String bankName,
    void Function(String message)? onLog,
    Directory? sandboxDir,
  }) async {
    final log = <String>[];
    void emit(String m) {
      log.add(m);
      onLog?.call(m);
    }

    // 沙箱目录：App 侧调用时传用户可见的目录（「导出/AI生成题库/<时间戳>」），
    // 让生成的题库文件能留得住、翻得到；未传时退回系统临时目录
    // （单元测试里没有 path_provider 平台实现）。
    // 注意用 if/else 而不是三元表达式：`createSync` 返回 void，写成三元会让
    // 整个表达式的推断类型变成 void（随后 sandbox.path 直接报错）。
    final Directory sandbox;
    if (sandboxDir == null) {
      sandbox = Directory.systemTemp.createTempSync(_sawatariSandboxPrefix);
    } else {
      if (!sandboxDir.existsSync()) sandboxDir.createSync(recursive: true);
      sandbox = sandboxDir;
    }
    final bankFile = File('${sandbox.path}/questions.json');

    final systemPrompt = '''
你是一个严谨的题库生成助手。你的任务是基于用户的知识库，生成 $targetCount 道高质量的题目，题库名为「$bankName」。

工作流程：
1. 先用 search_knowledge_base 检索知识库中与目标知识点相关的资料，确保题目内容准确、有据可查；
2. 依据检索到的资料出题，只出资料覆盖的内容，不得编造资料中没有的知识；
3. 用 write_question_bank 把**完整**的题目集写入 JSON。

调用 write_question_bank 之前，**必须**确保参数 json 是严格合法的 JSON（能被直接解析）：
- 绝不可以使用空 JSON（`{}`、`[]`、`{"questions":[]}`）、省略号占位或任何非 JSON 文本；
- 不要加 Markdown 围栏、不要写解释，参数里只放 JSON 本体；
- 题目多或资料很长时**分批生成**：每次调用不超过 $suggestedBatch 道题，可多次调用
  write_question_bank（工具会按题干去重后追加合并）；
- 输出过长会被截断，宁可多分几批，也不要一次性塞进一个超长 JSON。

题目 JSON 结构（写入 write_question_bank 的 json 参数）：
{"questions":[{"title":"题干","options":["选项A","选项B"],"correct_answer":"A","question_type":"single_choice","analysis":"解析","knowledge_point":"知识点"}]}
- question_type 取值：single_choice / multi_choice / true_false / fill_blank / ming_jie / jian_da / jie_da
- 单选/多选需 options 非空；多选 correct_answer 用逗号分隔（如 "A,C"）
- 判断 true_false 的 correct_answer 为 "对" 或 "错"
- 每个知识点出题数量应均衡，避免集中在同一处
- analysis 应简要说明答案依据，便于复习
''';

    final userPrompt =
        '请基于知识库（kbId=$kbId）生成 $targetCount 道题，题库名为「$bankName」。'
        '完成后用 write_question_bank 分批写入 JSON（每次不超过 $suggestedBatch 道）。';

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ];

    var hardError = false;
    for (var round = 0; round <= maxRetryRounds && !hardError; round++) {
      // 第一轮给完整预算；重试轮只留几轮工具循环，够模型重新写一次即可
      final budget = round == 0 ? maxIterations : 4;
      for (var i = 0; i < budget; i++) {
        final (content, toolCalls) = await aiService.callWithTools(
          messages: messages,
          tools: _tools,
          maxTokens: 8192,
        );
        if (_isAiError(content)) {
          emit(content);
          hardError = true;
          break;
        }

        if (toolCalls.isEmpty) {
          emit('生成完成（第 ${i + 1} 轮）');
          break;
        }

        // 助手消息（含工具调用）入列
        messages.add({
          'role': 'assistant',
          'content': content.isEmpty ? null : content,
          'tool_calls': [
            for (final c in toolCalls)
              {
                'id': c['id'],
                'type': 'function',
                'function': {'name': c['name'], 'arguments': c['arguments']},
              },
          ],
        });

        // 逐个执行工具，结果作为 tool 消息回填
        for (final c in toolCalls) {
          final name = c['name']?.toString() ?? '';
          final result = await _executeTool(name, c['arguments']?.toString(),
              kbId: kbId, bankFile: bankFile, sandbox: sandbox);
          emit('调用工具 $name → ${result.length > 60 ? '${result.substring(0, 60)}…' : result}');
          messages.add({
            'role': 'tool',
            'tool_call_id': c['id'],
            'content': result,
          });
        }
      }

      // 已经有题目落盘就不用重试
      if (await _questionCountInFile(bankFile) > 0) break;
      if (hardError || round >= maxRetryRounds) break;
      // 空 JSON / 非法 JSON 不再直接判死：带着纠错提示让 AI 再写一次
      emit('没有拿到有效题目 JSON，带着纠错提示重试一次…');
      messages.add({'role': 'user', 'content': retryPrompt(targetCount)});
    }

    // 读回沙箱里的题库文件，统计题数
    if (await bankFile.exists()) {
      final raw = await bankFile.readAsString();
      final parsed = _parseQuestionCount(raw);
      if (parsed > 0) {
        return GeneratorResult(bankFile.path, parsed, log);
      }
      return GeneratorResult(
        bankFile.path,
        0,
        log,
        failureReason: 'AI 写入的题目 JSON 为空或格式不合法（多为输出过长被截断）',
      );
    }
    return GeneratorResult(
      null,
      0,
      log,
      failureReason: 'AI 没有调用 write_question_bank 写入题目',
    );
  }

  /// 模型请求本身失败（网络 / 401 / 500）——重试没有意义，直接收尾。
  static bool _isAiError(String content) =>
      content.startsWith('AI') &&
      (content.contains('错误') || content.contains('失败'));

  /// 空 JSON / 非法 JSON 之后塞回对话的纠错提示。
  @visibleForTesting
  static String retryPrompt(int targetCount) =>
      '你上一次的 write_question_bank 调用没有提供有效的题目 JSON'
      '（空内容，或不是合法 JSON，通常是输出过长被截断）。\n'
      '请重新生成 $targetCount 道题：每次调用最多 $suggestedBatch 道，分多次调用 '
      'write_question_bank；每次的 json 参数都必须是完整、可直接解析的 JSON，'
      '绝不允许空 JSON、省略号占位或非 JSON 文本。';

  Future<int> _questionCountInFile(File bankFile) async {
    if (!await bankFile.exists()) return 0;
    try {
      return _parseQuestionCount(await bankFile.readAsString());
    } catch (_) {
      return 0;
    }
  }

  int _parseQuestionCount(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is Map && data['questions'] is List) {
        return (data['questions'] as List).length;
      }
      if (data is List) return data.length;
    } catch (_) {}
    return 0;
  }

  static const List<Map<String, dynamic>> _tools = [
    {
      'type': 'function',
      'function': {
        'name': 'search_knowledge_base',
        'description': '在用户知识库中检索与某个知识点相关的资料片段，用于确保题目内容准确。',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '检索关键词或知识点'},
          },
          'required': ['query'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'write_question_bank',
        'description': '将生成的题目写入题库 JSON 文件。json 参数必须是**完整、合法、非空**的'
            'JSON 字符串，结构为 {"questions":[{"title","options","correct_answer",'
            '"question_type","analysis","knowledge_point"}]}；不允许空字符串、空数组、'
            '省略号占位或 Markdown 围栏。题目多时请分批调用（每次建议不超过 15 道），'
            '本工具会把各批按题干去重后**追加合并**，不会覆盖前一批。',
        'parameters': {
          'type': 'object',
          'properties': {
            'json': {
              'type': 'string',
              'description': '完整、合法的 JSON 字符串（不要围栏，不要省略号占位）',
            },
          },
          'required': ['json'],
        },
      },
    },
  ];

  /// 工具返回给模型的重试提示（非致命）：让模型重新调用一次，而不是直接失败。
  static const String _jsonRetryHint = '请重新调用 write_question_bank 并给出完整合法的 JSON'
      '（每次不超过 $suggestedBatch 道题，可分多次调用；不允许空 JSON 或省略号占位）。';

  /// 解析工具参数（v1.41.4）。
  ///
  /// 模型给的 `arguments` 是个 JSON 字符串；上下文很长时经常缺尾括号被截断，
  /// 旧实现 `jsonDecode` 抛错后把参数当成空 map，于是 `json` 取到空串并抛出
  /// 「json 为空，请提供题目 JSON」，把整次生成打断。现在逐级兜底：
  /// 1. 正常 JSON 解析；
  /// 2. 截断抢修（[AIService.repairJsonPayload]）；
  /// 3. 正则抠 `"json": "..."` 里的字符串字面量。
  @visibleForTesting
  static Map<String, dynamic> decodeToolArguments(String? arguments) {
    final raw = arguments?.trim() ?? '';
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      // 个别实现会把整个 payload 再套一层字符串
      if (decoded is String && decoded.trim().isNotEmpty) {
        final inner = jsonDecode(decoded);
        if (inner is Map) return Map<String, dynamic>.from(inner);
      }
    } catch (_) {
      // 落到下面的抢修
    }
    final repaired = AIService.repairJsonPayload(raw);
    if (repaired != null) return repaired;
    final m = RegExp(r'"json"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(raw);
    if (m != null) {
      try {
        final str = jsonDecode('"${m.group(1)}"');
        if (str is String) return {'json': str};
      } catch (_) {}
    }
    return const {};
  }

  /// 解析模型给的题目 JSON（剥围栏 + 截断抢修）。无法解析返回 null。
  @visibleForTesting
  static dynamic parsePayload(String json) {
    var s = json.trim();
    if (s.isEmpty) return null;
    final fence =
        RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$', caseSensitive: false);
    final fenced = fence.firstMatch(s);
    if (fenced != null) s = fenced.group(1)!.trim();
    try {
      return jsonDecode(s);
    } catch (_) {
      // 撞 max_tokens 被截断：抢救前部完整题目
      return AIService.repairJsonPayload(s);
    }
  }

  /// 从解析结果里取出题目列表（只要题干非空的 Map）
  static List<Map<String, dynamic>> questionsOf(dynamic payload) {
    final List raw;
    if (payload is Map && payload['questions'] is List) {
      raw = payload['questions'] as List;
    } else if (payload is List) {
      raw = payload;
    } else {
      return const [];
    }
    return [
      for (final e in raw)
        if (e is Map && (e['title'] ?? '').toString().trim().isNotEmpty)
          Map<String, dynamic>.from(e),
    ];
  }

  /// 分批写入的核心：**追加合并**而不是整文件覆盖。
  ///
  /// 以前每次调用都 `writeAsString` 覆盖整个文件，模型按提示分批写入时前几批
  /// 会被悄悄冲掉；现在按题干+选项+答案去重后合并，重复写入的同一批只留一份。
  static Future<List<Map<String, dynamic>>> mergeIntoBankFile(
      File bankFile, List<Map<String, dynamic>> incoming) async {
    final merged = <Map<String, dynamic>>[];
    if (await bankFile.exists()) {
      try {
        merged.addAll(questionsOf(parsePayload(await bankFile.readAsString())));
      } catch (_) {
        // 旧文件坏掉就当没有，从头写
      }
    }
    final seen = <String>{for (final q in merged) _questionKey(q)};
    for (final q in incoming) {
      if (seen.add(_questionKey(q))) merged.add(q);
    }
    await bankFile.writeAsString(
      jsonEncode({'questions': merged}),
      flush: true,
    );
    return merged;
  }

  static String _questionKey(Map<String, dynamic> q) {
    final options = q['options'];
    return [
      (q['title'] ?? '').toString().trim(),
      options is List ? options.map((e) => e.toString().trim()).join('\u0001') : '',
      (q['correct_answer'] ?? '').toString().trim().toUpperCase(),
    ].join('\u0002');
  }

  Future<String> _executeTool(String name, String? arguments,
      {required int kbId,
      required File bankFile,
      required Directory sandbox}) async {
    final args = decodeToolArguments(arguments);

    switch (name) {
      case 'search_knowledge_base':
        final query = (args['query'] ?? '').toString();
        if (query.isEmpty) return '查询为空，请提供检索关键词';
        final hits = await kbService.search(kbId, query, topK: 4);
        if (hits.isEmpty) return '未检索到相关资料，请更换关键词';
        return hits
            .asMap()
            .entries
            .map((e) => '【资料${e.key + 1}】${e.value.chunk.text}')
            .join('\n\n');
      case 'write_question_bank':
        final json = (args['json'] ?? '').toString().trim();
        // 空内容不再抛错：把它当成「模型这一步没给对」，让它在同一轮里重试
        if (json.isEmpty) return 'json 为空。$_jsonRetryHint';
        final payload = parsePayload(json);
        if (payload == null) {
          return 'json 不是合法 JSON（可能被截断）。$_jsonRetryHint';
        }
        final incoming = questionsOf(payload);
        if (incoming.isEmpty) {
          return 'json 里没有可用题目（questions 为空或缺少 title）。$_jsonRetryHint';
        }
        final merged = await mergeIntoBankFile(bankFile, incoming);
        return '已写入 ${incoming.length} 道题（累计 ${merged.length} 道）';
      default:
        return '未知工具: $name';
    }
  }
}
