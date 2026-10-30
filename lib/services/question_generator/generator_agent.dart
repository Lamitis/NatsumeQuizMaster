import 'dart:convert';
import 'dart:io';

import '../ai_service.dart';
import '../knowledge_base/kb_service.dart';

/// 出题结果：写入题库的 JSON 文件路径 + 题数 + 过程日志。
class GeneratorResult {
  final String? bankFilePath;
  final int questionCount;
  final List<String> log;

  const GeneratorResult(this.bankFilePath, this.questionCount, this.log);
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
3. 用 write_question_bank 把**完整**的题目集一次性写入 JSON。

题目 JSON 结构（写入 write_question_bank 的 json 参数）：
{"questions":[{"title":"题干","options":["选项A","选项B"],"correct_answer":"A","question_type":"single_choice","analysis":"解析","knowledge_point":"知识点"}]}
- question_type 取值：single_choice / multi_choice / true_false / fill_blank / ming_jie / jian_da / jie_da
- 单选/多选需 options 非空；多选 correct_answer 用逗号分隔（如 "A,C"）
- 判断 true_false 的 correct_answer 为 "对" 或 "错"
- 每个知识点出题数量应均衡，避免集中在同一处
- analysis 应简要说明答案依据，便于复习
''';

    final userPrompt =
        '请基于知识库（kbId=$kbId）生成 $targetCount 道题，题库名为「$bankName」。完成后用 write_question_bank 写入 JSON。';

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ];

    for (var i = 0; i < maxIterations; i++) {
      final (content, toolCalls) = await aiService.callWithTools(
        messages: messages,
        tools: _tools,
        maxTokens: 8192,
      );
      if (content.startsWith('AI') && content.contains('错误')) {
        emit(content);
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

    // 读回沙箱里的题库文件，统计题数
    if (await bankFile.exists()) {
      final raw = await bankFile.readAsString();
      final parsed = _parseQuestionCount(raw);
      if (parsed > 0) {
        return GeneratorResult(bankFile.path, parsed, log);
      }
      return GeneratorResult(bankFile.path, 0, log);
    }
    return GeneratorResult(null, 0, log);
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
        'description': '将生成的完整题目集写入题库 JSON 文件。json 参数必须是合法 JSON 字符串，'
            '结构为 {"questions":[{"title","options","correct_answer","question_type","analysis","knowledge_point"}]}。',
        'parameters': {
          'type': 'object',
          'properties': {
            'json': {'type': 'string', 'description': '完整 JSON 字符串'},
          },
          'required': ['json'],
        },
      },
    },
  ];

  Future<String> _executeTool(String name, String? arguments,
      {required int kbId,
      required File bankFile,
      required Directory sandbox}) async {
    Map<String, dynamic> args = {};
    if (arguments != null && arguments.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(arguments);
        if (decoded is Map) args = Map<String, dynamic>.from(decoded);
      } catch (_) {
        // 参数不是 JSON 时按原样字符串处理
      }
    }

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
        final json = (args['json'] ?? '').toString();
        if (json.trim().isEmpty) return 'json 为空，请提供题目 JSON';
        // 校验可解析（避免写入非法 JSON）
        final decoded = jsonDecode(json);
        if (decoded is! Map && decoded is! List) {
          return 'json 结构不合法，应为 {"questions":[...]}';
        }
        await bankFile.writeAsString(json, flush: true);
        final count = _parseQuestionCount(json);
        return '已写入 $count 道题';
      default:
        return '未知工具: $name';
    }
  }
}
