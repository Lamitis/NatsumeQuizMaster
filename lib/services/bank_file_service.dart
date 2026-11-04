import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../models/question.dart';
import '../models/question_bank.dart';
import '../models/question_image.dart';
import 'database_service.dart';

/// 一个待导入的题库组（v1.41.2 去重链路用）。
class BankImportGroup {
  const BankImportGroup({
    required this.name,
    this.uid,
    required this.questions,
  });

  final String name;
  final String? uid;
  final List<Question> questions;
}

/// 题库文件导入结果。
///
/// [skippedCount] 是「uid 命中 / 同名且内容完全一致」而跳过的组数——
/// 世界包重复导入、更新后再次导入同一份题库都靠它把重复挡在门外。
class BankImportOutcome {
  const BankImportOutcome({
    this.bankCount = 0,
    this.questionCount = 0,
    this.renamedCount = 0,
    this.skippedCount = 0,
    this.error,
  });

  final int bankCount;
  final int questionCount;
  final int renamedCount;
  final int skippedCount;
  final String? error;
}

/// JSON 题库文件导入导出（v1.0.2）
///
/// 导入格式支持两种：
/// 1. 单题库：JSON 数组（题目列表）→ 建一个以文件名命名的题库
/// 2. 多题库分组：JSON 对象 { "题库名": [题目...], ... } → 分组建库
///
/// 题目字段（宽松兼容）：title/题干、options/选项（字符串数组或 "A. xxx" 带标签）、
/// correct_answer/answer/correctAnswer、analysis/解析、question_type/type、
/// knowledge_point/knowledgePoint/知识点
class BankFileService {
  static final DatabaseService _db = DatabaseService.instance;

  /// NatsumeQuizMaster 导出文件格式标记。
  static const String formatMarker = 'natsume-quiz-questions';

  /// 一个待导入的题库组：名字 +（可选的）题库 uid + 题目。
  ///
  /// [uid] 来自新版导出文件；再次导入同一份文件时按它直接跳过，
  /// 避免「更新/重复导入 → 题库变成 X(2)」的老问题（v1.41.2）。
  static Future<(List<BankImportGroup>, String?)> parseJsonGroups(
      String filePath) async {
    final (map, err) = await parseJsonFile(filePath);
    if (map.isEmpty) return (const <BankImportGroup>[], err);
    String? uid;
    try {
      final data = jsonDecode(await File(filePath).readAsString());
      if (data is Map && data['format'] == formatMarker) {
        final raw = data['uid']?.toString().trim();
        if (raw != null && raw.isNotEmpty) uid = raw;
      }
    } catch (_) {
      // 读不出 uid 就当旧格式：走内容签名兜底
    }
    final entries = map.entries.toList();
    return ([
      for (var i = 0; i < entries.length; i++)
        BankImportGroup(
          name: entries[i].key,
          uid: i == 0 ? uid : null,
          questions: entries[i].value,
        ),
    ], err);
  }

  /// 题库内容签名：同名 + 题目集合完全一致 → 视为同一份题库。
  ///
  /// 旧版导出文件没有 uid，只能靠内容判断重复；题目顺序、选项/答案/解析
  /// 任何一处不同都会得到不同签名（同名不同内容仍按老逻辑改名导入）。
  static String contentSignature(String bankName, List<Question> questions) {
    final parts = questions
        .map((q) => [
              q.title.trim(),
              q.options.map((o) => o.trim()).join('\u0001'),
              q.correctAnswer.trim().toUpperCase(),
              (q.analysis ?? '').trim(),
              q.questionType,
            ].join('\u0002'))
        .toList()
      ..sort();
    return sha1
        .convert(utf8.encode('$bankName\u0000${parts.join('\u0003')}'))
        .toString();
  }

  /// 解析 JSON 文件 → 返回 (组名 → 题目列表, 错误信息)。
  /// v1.0.2 设计审查修复：错误信息随返回值传递
  /// （此前用静态 lastError 全局变量，并发/重入会被覆盖）
  static Future<(Map<String, List<Question>>, String?)> parseJsonFile(
      String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return (<String, List<Question>>{}, '文件不存在: $filePath');
    }
    final String raw;
    try {
      raw = await file.readAsString();
    } catch (e) {
      return (<String, List<Question>>{}, '读取文件失败: $e');
    }

    final dynamic data;
    try {
      data = jsonDecode(raw);
    } catch (e) {
      // v1.0.2 对齐里程碑：不是有效的 JSON 文件
      return (<String, List<Question>>{}, '不是有效的 JSON 文件: $e');
    }

    final now = DateTime.now().toIso8601String();
    final groups = <String, List<Question>>{};

    if (data is List) {
      // 单题库：数组
      final questions = _parseQuestions(data, now);
      if (questions.isEmpty) {
        return (<String, List<Question>>{}, '文件中没有有效题目');
      }
      final baseName = filePath.split(RegExp(r'[\\/]')).last
          .replaceAll(RegExp(r'\.json$', caseSensitive: false), '');
      groups[baseName] = questions;
    } else if (data is Map) {
      // v1.0.2 对齐里程碑：本软件导出的 .json（format 标记 + questions 数组）→ 单题库；
      // 有 questions 键但缺 format 标记 → 提示缺少 format 标记
      if (data.containsKey('questions')) {
        final marker = data['format'];
        if (marker != formatMarker) {
          return (<String, List<Question>>{}, '不是NatsumeQuizMaster题库文件（缺少 format 标记）');
        }
        if (data['questions'] is List) {
          final questions = _parseQuestions(data['questions'] as List, now);
          if (questions.isNotEmpty) {
            groups[data['name']?.toString() ?? '错题导出'] = questions;
          }
        }
      }
      // 分组：{ 组名: [...] }
      if (groups.isEmpty) {
        for (final entry in data.entries) {
          if (entry.value is! List) continue;
          final questions = _parseQuestions(entry.value as List, now);
          if (questions.isEmpty) continue;
          groups['${entry.key}'] = questions;
        }
      }
      if (groups.isEmpty) {
        return (<String, List<Question>>{}, '文件中没有有效题目分组');
      }
    } else {
      return (<String, List<Question>>{}, 'JSON 顶层应为数组或对象');
    }
    return (groups, null);
  }

  static List<Question> _parseQuestions(List list, String now) {
    final questions = <Question>[];
    for (final item in list) {
      if (item is! Map) continue;
      final q = _parseQuestion(Map<String, dynamic>.from(item), now);
      if (q != null) questions.add(q);
    }
    return questions;
  }

  static Question? _parseQuestion(Map<String, dynamic> m, String now) {
    final title = _first(m, ['title', '题干', 'question']);
    if (title == null || (title as String).trim().isEmpty) return null;

    final rawOptions = m['options'] ?? m['选项'] ?? m['choices'];
    var options = <String>[];
    if (rawOptions is List) {
      options =
          rawOptions.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    } else if (rawOptions is String && rawOptions.trim().isNotEmpty) {
      // "A. xxx\nB. yyy" 或 "A.xxx B.yyy"（同行）拆段：在前缀 "X." 前断开
      options = rawOptions
          .split(RegExp(r'\n'))
          .expand((line) => line.split(RegExp(r'(?=[A-Z][\.、．]\s)')))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    // 逐项剥选项前缀（"A. xxx" → "xxx"；首个无前缀、后续带前缀的情况也处理）
    options = options
        .map((o) => o.replaceFirst(RegExp(r'^[A-Z][\.、．]\s*'), '').trim())
        .where((o) => o.isNotEmpty)
        .toList();

    var correctAnswer =
        (_first(m, ['correct_answer', 'answer', 'correctAnswer', '答案']) ?? '')
            .toString()
            .trim()
            .toUpperCase()
        // 多选归一：A、C → A,C
        .replaceAll(RegExp(r'[、，,;；/\s]+'), ',');
    // 连续字母串归一（外部导出的 "AC"）：仅当纯大写字母且长度>1 时拆为 A,C。
    // 中文/数字答案（填空、判断）不受影响
    if (RegExp(r'^[A-Z]{2,}$').hasMatch(correctAnswer)) {
      correctAnswer = correctAnswer.split('').join(',');
    }

    final typeRaw =
        (_first(m, ['question_type', 'type', '题型']) ?? '').toString().toLowerCase();
    String questionType = 'single_choice';
    if (typeRaw.contains('multi') || typeRaw.contains('多选')) {
      questionType = 'multi_choice';
    } else if (typeRaw.contains('true') || typeRaw.contains('判断')) {
      questionType = 'true_false';
    } else if (typeRaw.contains('fill') || typeRaw.contains('填空')) {
      questionType = 'fill_blank';
    } else if (typeRaw.contains('ming') || typeRaw.contains('名解')) {
      questionType = 'ming_jie';
    } else if (typeRaw.contains('jian') || typeRaw.contains('简答')) {
      questionType = 'jian_da';
    } else if (typeRaw.contains('jie') || typeRaw.contains('问答')) {
      questionType = 'jie_da';
    } else if (correctAnswer.contains(',')) {
      questionType = 'multi_choice';
    }

    final analysis = (_first(m, ['analysis', '解析']) ?? '').toString();
    final kp = (_first(m, ['knowledge_point', 'knowledgePoint', '知识点']) ?? '')
        .toString();

    return Question(
      bankId: 0, // 导入时由调用方设置
      title: title.toString().trim(),
      options: options,
      correctAnswer: correctAnswer,
      analysis: analysis.isEmpty ? null : analysis,
      questionType: questionType,
      knowledgePoint: kp.isEmpty ? null : kp,
      createdAt: now,
      // v12 配图：图片是题目的一部分，随 JSON 往返（无此键的旧文件照常）
      images: _parseImages(m['images']),
    );
  }

  /// v12 配图解析：`images: [{position, mime, width, height, data_b64}]`。
  /// 未知/损坏条目跳过（不整题报废）；data_b64 亦兼容 data
  static List<QuestionImage> _parseImages(dynamic raw) {
    if (raw is! List) return const [];
    final out = <QuestionImage>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final data = item['data_b64'] ?? item['data'];
      if (data is! String || data.isEmpty) continue;
      final Uint8List bytes;
      try {
        bytes = base64Decode(data);
      } catch (_) {
        continue;
      }
      out.add(QuestionImage(
        position: (item['position'] as num?)?.toInt() ?? out.length,
        mime: item['mime'] as String? ?? 'image/webp',
        width: (item['width'] as num?)?.toInt() ?? 0,
        height: (item['height'] as num?)?.toInt() ?? 0,
        anchor: item['anchor'] as String?,
        content: bytes,
      ));
    }
    return out;
  }

  static dynamic _first(Map m, List<String> keys) {
    for (final k in keys) {
      if (m.containsKey(k) && m[k] != null) return m[k];
    }
    return null;
  }

  /// 导入 JSON 文件（分组建库）：返回 (成功组数, 导入题目数, 错误信息, 改名组数)。
  /// [existingNames] 非空时同名组自动加后缀（防重复导入建重复题库）
  static Future<(int, int, String?, int)> importJsonFile(String filePath,
      {Set<String>? existingNames, int? categoryId}) async {
    final o = await importBankFile(filePath,
        existingNames: existingNames, categoryId: categoryId);
    return (o.bankCount, o.questionCount, o.error, o.renamedCount);
  }

  /// 导入题库 JSON（v1.41.2：uid / 内容签名去重）。
  ///
  /// 规则：
  /// 1. 文件带题库 `uid` 且本机已有同 uid 的题库 → **跳过**（不追加、不改名）；
  /// 2. 老文件没有 uid → 同名且题目集合完全一致（[contentSignature]）→ 跳过；
  /// 3. 同名但内容不同 → 仍按老逻辑改成 `X(2)` 导入（这是两份不同题库）。
  static Future<BankImportOutcome> importBankFile(String filePath,
      {Set<String>? existingNames, int? categoryId}) async {
    final (groups, err) = await parseJsonGroups(filePath);
    if (groups.isEmpty) return BankImportOutcome(error: err);
    final now = DateTime.now().toIso8601String();
    final taken = existingNames ?? <String>{};

    // 本机已有题库：按名字索引，供「无 uid」的内容签名兜底
    final byName = <String, List<QuestionBank>>{};
    for (final b in await _db.getAllBanks()) {
      byName.putIfAbsent(b.name, () => []).add(b);
      taken.add(b.name);
    }
    final sigCache = <int, String>{};
    Future<String> signatureOf(QuestionBank bank) async {
      final id = bank.id;
      if (id == null) return '';
      final cached = sigCache[id];
      if (cached != null) return cached;
      final qs = await _db.getQuestionsByBank(id);
      final sig = contentSignature(bank.name, qs);
      sigCache[id] = sig;
      return sig;
    }

    var bankCount = 0;
    var questionCount = 0;
    var renamedCount = 0;
    var skippedCount = 0;

    for (final group in groups) {
      final uid = group.uid?.trim();
      final hasUid = uid != null && uid.isNotEmpty;

      // 1) uid 命中：同一份题库再次导入 → 跳过
      if (hasUid) {
        final row = await _db.bankRowByUid(await _db.database, uid);
        if (row != null) {
          skippedCount++;
          continue;
        }
      } else {
        // 2) 旧文件无 uid：同名 + 内容签名一致 → 跳过
        final sig = contentSignature(group.name, group.questions);
        var duplicated = false;
        for (final bank in byName[group.name] ?? const <QuestionBank>[]) {
          if (await signatureOf(bank) == sig) {
            duplicated = true;
            break;
          }
        }
        if (duplicated) {
          skippedCount++;
          continue;
        }
      }

      var name = group.name;
      // 同名但内容不同：保留旧的「自动改名」语义（两份不同题库）
      if (taken.contains(name)) {
        var i = 2;
        while (taken.contains('$name($i)')) {
          i++;
        }
        name = '$name($i)';
        renamedCount++;
      }
      taken.add(name);

      final bankId = await _db.insertBank(QuestionBank(
        name: name,
        fileSource: 'json',
        createdAt: now,
        uid: hasUid ? uid : null,
        categoryId: categoryId,
      ));
      final questions =
          group.questions.map((q) => q.copyWith(bankId: bankId)).toList();
      await _db.insertQuestions(questions);
      await _db.updateBankQuestionCount(bankId, questions.length);
      bankCount++;
      questionCount += questions.length;

      // 同一文件里重复出现的同 uid / 同内容组也要跳过
      final inserted = QuestionBank(
        id: bankId,
        name: name,
        fileSource: 'json',
        createdAt: now,
        uid: hasUid ? uid : null,
        categoryId: categoryId,
      );
      byName.putIfAbsent(name, () => []).add(inserted);
      sigCache[bankId] = contentSignature(group.name, group.questions);
    }

    return BankImportOutcome(
      bankCount: bankCount,
      questionCount: questionCount,
      renamedCount: renamedCount,
      skippedCount: skippedCount,
    );
  }

  /// 导出题库为 JSON 文件（v1.0.2 扩展：带 format 标记 + 题库名，
  /// 保留打标签后的 knowledge_point / analysis 等整理后字段，可被导入直接入库）。
  /// 返回文件路径；失败返回 null。
  static Future<String?> exportBank(int bankId, String bankName, String destPath) async {
    final questions = await _db.getQuestionsByBank(bankId);
    if (questions.isEmpty) return null;
    // v1.41.2：导出题库 uid —— 再导入同一份文件时按 uid 跳过，避免库重复
    final bank =
        (await _db.getAllBanks()).where((b) => b.id == bankId).firstOrNull;
    final bankUid = bank?.uid;
    // v12：配图随题导出（图片是题目的一部分，分享/再导入都不丢图）
    final imageMap = await _db
        .getImagesForQuestions(questions.map((q) => q.id ?? -1).toList());
    final list = questions.map((q) {
      final images = imageMap[q.id] ?? const <QuestionImage>[];
      return {
        'title': q.title,
        'options': q.options,
        'correct_answer': q.correctAnswer,
        'analysis': q.analysis,
        'question_type': q.questionType,
        'knowledge_point': q.knowledgePoint,
        if (images.isNotEmpty)
          'images': [
            for (final img in images)
              {
                'position': img.position,
                'mime': img.mime,
                'width': img.width,
                'height': img.height,
                'data_b64': base64Encode(img.content),
              },
          ],
      };
    }).toList();
    final json = const JsonEncoder.withIndent('  ').convert({
      'format': formatMarker,
      'name': bankName,
      if (bankUid != null && bankUid.isNotEmpty) 'uid': bankUid,
      'count': list.length,
      'questions': list,
    });
    final file = File(destPath);
    await file.writeAsString(json);
    return file.path;
  }
}
