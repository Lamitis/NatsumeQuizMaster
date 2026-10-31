import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../database_service.dart';
import '../debug_log_service.dart';
import '../device_service.dart';
import '../companion/companion_service.dart';
import '../../models/companion_avatar.dart';
import '../../models/companion_memory.dart';
import '../../models/companion_settings.dart';
import '../../models/plugin_sync_scope.dart';
import 'sync_models.dart';

/// 局域网同步：快照导出与合并入库
///
/// 合并规则：
/// - 题库/题目/会话/作答记录：按全局 `uid` upsert（新则插、已有按时间取新）
/// - 批注：按 `(题目, 设备)` 隔离，他端批注存其 `device_id` 下，绝不覆盖本机批注
/// - 错题：按 `(题目, 来源设备)` 共存，两端同一题错题互不覆盖
/// - 本地外键（bank_id/question_id/session_id）导入时按 uid 映射为本地自增 id；
///   孤儿引用（对应实体未同步到）跳过，不产生悬空记录
class SyncRepository {
  static const int protocolVersion = 1;

  /// 增量游标的安全重叠窗口（2026-10-30）。
  ///
  /// 用「上次同步时刻」当游标有两个现实风险：两端时钟不完全一致、同步途中
  /// 本机仍有写入落在游标之后。回退一段时间再取增量，代价只是多传少量未变更
  /// 的行（合并是按 uid upsert 的幂等操作），换来的是**不会漏数据**。
  static const Duration cursorOverlap = Duration(minutes: 10);

  final DatabaseService _db = DatabaseService.instance;

  /// 导出本机同步快照。
  ///
  /// [banksOnly] = true 时**只导出题库与题目（含配图）**，不带刷题会话、
  /// 作答记录、错题本与批注——这是 2026-10-08 用户要的「只同步题库」模式，
  /// 设计目标是用户之间互相分享题库，不该把自己的学习记录一并交出去。
  ///
  /// [banksOnly] = false 时是整库快照（局域网数据量小，全量合并；
  /// 模拟数据与未完成会话不参与同步）。
  Future<Map<String, dynamic>> exportSnapshot({
    bool banksOnly = false,
    DateTime? since,
  }) async {
    final total = Stopwatch()..start();
    final exportedAt = DateTime.now();
    // 增量导出的实际起点：游标回退一个重叠窗口（见 [cursorOverlap]）
    final cutoff = since?.subtract(cursorOverlap);
    final db = await _db.database;
    final deviceId = await DeviceService.instance.deviceId;
    final deviceName = await DeviceService.instance.deviceName;

    // 题库行**始终全带**：体量小，而且题目要靠 bank_uid → 本地 id 映射，
    // 只发题目不发题库会让对端把题挂到 null 上（旧实现在这里踩过坑）。
    final banks = await db.rawQuery('''
      SELECT uid, name, file_source, question_count, created_at,
             COALESCE(updated_at, created_at) AS updated_at
      FROM question_banks
    ''');

    final allQuestions = await db.rawQuery('''
      SELECT q.uid AS uid, qb.uid AS bank_uid, q.title, q.options,
             q.correct_answer, q.analysis, q.question_type, q.source,
             q.knowledge_point, q.created_at,
             COALESCE(q.updated_at, q.created_at) AS updated_at
      FROM questions q
      JOIN question_banks qb ON qb.id = q.bank_id
    ''');
    // 增量：只留 cutoff 之后动过的题目（按 updated_at 比对）
    final questions = cutoff == null
        ? allQuestions
        : allQuestions
            .where((r) => _changedSince(r['updated_at'], cutoff))
            .toList();
    final includedQuestionUids = cutoff == null
        ? null
        : {for (final r in questions) (r['uid'] ?? '').toString()};

    // v12 配图随题同步（图片是题目的一部分）：BLOB 转 base64 走 JSON。
    // 增量时按题目 uid 预过滤——**base64 是同步里最贵的一步**（几 MB 图片
    // 编码 + JSON 里膨胀 33%），未变更题目的配图一张都不编。
    final imageRows = includedQuestionUids == null
        ? await db.rawQuery('''
            SELECT q.uid AS question_uid, qi.position, qi.mime, qi.width,
                   qi.height, qi.anchor, qi.content
            FROM question_images qi
            JOIN questions q ON q.id = qi.question_id
            ORDER BY q.uid, qi.position
          ''')
        : includedQuestionUids.isEmpty
            ? const <Map<String, Object?>>[]
            : await db.rawQuery(
                '''
            SELECT q.uid AS question_uid, qi.position, qi.mime, qi.width,
                   qi.height, qi.anchor, qi.content
            FROM question_images qi
            JOIN questions q ON q.id = qi.question_id
            WHERE q.uid IN
              (${List.filled(includedQuestionUids.length, '?').join(',')})
            ORDER BY q.uid, qi.position
          ''',
                includedQuestionUids.toList(),
              );
    final images = imageRows.map((r) {
      final m = Map<String, dynamic>.from(r);
      final content = m['content'];
      m['content'] = content is List<int> ? base64Encode(content) : '';
      return m;
    }).toList();

    final incremental = cutoff != null;
    DebugLogService.instance.log('SYNC',
        '快照导出：题库 ${banks.length} / 题目 ${questions.length}'
        '（共 ${allQuestions.length}）/ 配图 ${images.length}，'
        '${incremental ? '增量自 ${cutoff.toIso8601String()}' : '全量'}，'
        '耗时 ${total.elapsedMilliseconds}ms');
    debugPrint('[SYNC] exportSnapshot ${incremental ? 'incremental' : 'full'} '
        'banks=${banks.length} questions=${questions.length}/${allQuestions.length} '
        'images=${images.length} ${total.elapsedMilliseconds}ms');

    // 仅题库：到这里就结束，记录类数据一律不出门
    if (banksOnly) {
      return {
        'protocol': protocolVersion,
        'device_id': deviceId,
        'device_name': deviceName,
        'scope': 'banks',
        // 增量协议：对端据此推进游标；老客户端忽略这两个字段即可
        'exported_at': exportedAt.toIso8601String(),
        'incremental': incremental,
        'banks': banks,
        'questions': questions,
        'question_images': images,
        'sessions': const [],
        'answer_records': const [],
        'error_book': const [],
        'annotations': const [],
        // 仅题库模式：插件内容同样不出门（分享题库不该带笔记/待办/人设）
        'plugins': const <String, dynamic>{},
      };
    }

    // 本地题库 id → uid（会话的 bank_ids 文本导出时按 uid 对应）
    final bankRows = await db.rawQuery('SELECT id, uid FROM question_banks');
    final bankUidById = <int, String>{
      for (final r in bankRows)
        if (r['uid'] != null) r['id'] as int: r['uid'] as String,
    };

    // 只同步已完成（有 end_time）的真实会话；模拟数据不跨设备
    final sessionRows = await db.rawQuery('''
      SELECT uid, bank_ids, mode, total_questions, correct_count, wrong_count,
             start_time, end_time, duration_seconds, source
      FROM quiz_sessions
      WHERE source = 'real' AND end_time IS NOT NULL AND end_time != ''
    ''');
    final sessions = sessionRows
        .where((r) => cutoff == null || _changedSince(r['start_time'], cutoff))
        .map((r) {
      final m = Map<String, dynamic>.from(r);
      m['bank_ids'] =
          _mapBankIdsToUids(m['bank_ids'] as String? ?? '', bankUidById);
      return m;
    }).toList();

    final recordRows = await db.rawQuery('''
      SELECT ar.uid AS uid, q.uid AS question_uid, qs.uid AS session_uid,
             ar.user_answer, ar.is_correct, ar.ai_analysis, ar.answered_at,
             ar.hidden, ar.source, ar.origin_device
      FROM answer_records ar
      JOIN questions q ON q.id = ar.question_id
      LEFT JOIN quiz_sessions qs ON qs.id = ar.session_id
      WHERE ar.source = 'real'
    ''');
    final records = cutoff == null
        ? recordRows
        : recordRows
            .where((r) => _changedSince(r['answered_at'], cutoff))
            .toList();

    final errorRows = await db.rawQuery('''
      SELECT eb.uid AS uid, q.uid AS question_uid, eb.origin_device, eb.added_at
      FROM error_book eb
      JOIN questions q ON q.id = eb.question_id
    ''');
    final errors = cutoff == null
        ? errorRows
        : errorRows.where((r) => _changedSince(r['added_at'], cutoff)).toList();

    final annotationRows = await db.rawQuery('''
      SELECT qa.device_id, q.uid AS question_uid, qa.data, qa.updated_at
      FROM question_annotations qa
      JOIN questions q ON q.id = qa.question_id
    ''');
    final annotations = cutoff == null
        ? annotationRows
        : annotationRows
            .where((r) => _changedSince(r['updated_at'], cutoff))
            .toList();

    return {
      'protocol': protocolVersion,
      'device_id': deviceId,
      'device_name': deviceName,
      'exported_at': exportedAt.toIso8601String(),
      'incremental': incremental,
      'banks': banks,
      'questions': questions,
      'question_images': images,
      'sessions': sessions,
      'answer_records': records,
      'error_book': errors,
      'annotations': annotations,
      // v1.35 插件内容（笔记 / 助教 / 待办），按本机开关逐项决定
      'plugins': await _exportPlugins(db, cutoff: cutoff),
    };
  }

  /// 增量判定：`stamp` 是否晚于 [cutoff]。
  ///
  /// 时间戳缺失或解析失败时**照发**——宁可多传一条，也不因为一行脏数据
  /// 让对端永远收不到它（漏传是数据错误，多传只是流量）。
  static bool _changedSince(Object? stamp, DateTime cutoff) {
    final parsed = _parseStamp(stamp);
    if (parsed == null) return true;
    return parsed.isAfter(cutoff);
  }

  /// 解析 ISO8601 时间戳（脏值返回 null）
  static DateTime? _parseStamp(Object? raw) {
    if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
    return null;
  }

  /// 导出插件内容（v1.35）。
  ///
  /// 开关取自本机 settings（[PluginSyncScope]），**不写进快照**：同步过来的是
  /// 数据，不是「你该不该同步」的决定。三项都关时返回空 Map，快照形状不变。
  ///
  /// [cutoff] 非空时按 `updated_at` 过滤笔记与待办（增量同步）；助教只有
  /// 一份人设与记忆（几 KB），始终全带。
  Future<Map<String, dynamic>> _exportPlugins(
    Database db, {
    DateTime? cutoff,
  }) async {
    final scope = PluginSyncScope.decode(
        await _db.getSetting(PluginSyncScope.settingsKey));
    final out = <String, dynamic>{};
    if (scope.notes) {
      final noteRows = await db.rawQuery('''
          SELECT n.uid, n.title, n.content, n.created_at, n.updated_at,
                 n.origin_device, b.uid AS bank_uid, q.uid AS question_uid
          FROM notes n
          LEFT JOIN question_banks b ON b.id = n.bank_id
          LEFT JOIN questions q ON q.id = n.question_id
          WHERE n.uid IS NOT NULL AND n.uid != ''
        ''');
      final notes = cutoff == null
          ? noteRows
          : noteRows
              .where((r) =>
                  _changedSince(r['updated_at'] ?? r['created_at'], cutoff))
              .toList();
      // 出链只增不删：只要笔记带了，链路就全带上（不是增量点）
      final noteUids = {for (final r in notes) (r['uid'] ?? '').toString()};
      final linkRows = await db.rawQuery('''
          SELECT n.uid AS note_uid, l.target
          FROM note_links l JOIN notes n ON n.id = l.note_id
          WHERE n.uid IS NOT NULL AND n.uid != ''
        ''');
      out['notes'] = {
        'notes': notes,
        'links': cutoff == null
            ? linkRows
            : linkRows
                .where((r) => noteUids.contains((r['note_uid'] ?? '').toString()))
                .toList(),
      };
    }
    if (scope.schedule) {
      final itemRows = await db.rawQuery('''
          SELECT uid, title, detail, due_at, done, created_at, updated_at,
                 origin_device
          FROM schedule_items WHERE uid IS NOT NULL AND uid != ''
        ''');
      out['schedule'] = {
        'items': cutoff == null
            ? itemRows
            : itemRows
                .where((r) =>
                    _changedSince(r['updated_at'] ?? r['created_at'], cutoff))
                .toList(),
      };
    }
    if (scope.companion) {
      out['companion'] = await _exportCompanion();
    }
    return out;
  }

  /// 助教只同步「人设 + 记忆」。
  ///
  /// **不同步**：API Key（加密是按本机密钥做的，换机也解不开）、接口地址 /
  /// 模型（可能指向本机 Ollama）、知识库 id（库是另一台设备的自增 id）、
  /// 悬浮位置与好感度（那是这台设备上的相处记录）。
  Future<Map<String, dynamic>> _exportCompanion() async {
    final settings = <String, dynamic>{};
    try {
      final raw = await _db.getSetting(CompanionService.settingsKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          final s =
              CompanionSettings.fromJson(Map<String, dynamic>.from(parsed));
          settings.addAll({
            'bot_name': s.displayName,
            'avatar': s.avatarOption.id,
            'tone': s.tone.name,
            'custom_persona': s.customPersona,
            'memory': s.memoryEnabled,
            'bubble_minutes': s.bubbleMinutes,
          });
        }
      }
    } catch (e) {
      DebugLogService.instance.log('SYNC', '助教设置导出失败: $e');
    }

    final memory = <String, dynamic>{};
    try {
      final raw = await _db.getSetting(CompanionService.memoryKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          final m = CompanionMemory.fromJson(Map<String, dynamic>.from(parsed));
          memory.addAll({
            'summary': m.summary,
            'turns': [for (final t in m.turns) t.toJson()],
          });
        }
      }
    } catch (e) {
      DebugLogService.instance.log('SYNC', '助教记忆导出失败: $e');
    }

    return {'settings': settings, 'memory': memory};
  }

  /// bank_ids 文本中的本地数字 id 替换为题库 uid；非数字标记
  /// （'simulation'/'all' 等）原样保留
  String _mapBankIdsToUids(String bankIds, Map<int, String> bankUidById) {
    if (bankIds.isEmpty) return bankIds;
    return bankIds.split(',').map((token) {
      final id = int.tryParse(token);
      if (id == null) return token;
      return bankUidById[id] ?? token;
    }).join(',');
  }

  /// 反向：bank_ids 文本中的题库 uid 还原为本地数字 id
  String _mapUidsToBankIds(String bankIds, Map<String, int> bankLocalByUid) {
    if (bankIds.isEmpty) return bankIds;
    return bankIds.split(',').map((token) {
      final id = bankLocalByUid[token];
      return id != null ? '$id' : token;
    }).join(',');
  }

  /// 本机某题库的**题目内容指纹**集合（用于同名题库比对）。
  ///
  /// 指纹只取「题目本身的内容」——题干、选项、答案、题型、知识点，
  /// 外加配图的槽位与内容摘要；不含 uid、时间戳这类每端都会不同的字段，
  /// 否则同名题库永远判为「不一样」。
  Future<Set<String>> _questionFingerprints(
      DatabaseExecutor txn, int bankId) async {
    final rows = await txn.rawQuery('''
      SELECT q.uid AS uid, q.title, q.options, q.correct_answer, q.analysis,
             q.question_type, q.knowledge_point
      FROM questions q WHERE q.bank_id = ?
    ''', [bankId]);
    final imagesByQuestion = <String, List<String>>{};
    final imgRows = await txn.rawQuery('''
      SELECT q.uid AS q_uid, qi.position, qi.mime, qi.anchor, qi.content
      FROM question_images qi
      JOIN questions q ON q.id = qi.question_id
      WHERE q.bank_id = ?
    ''', [bankId]);
    for (final r in imgRows) {
      final qUid = r['q_uid'] as String? ?? '';
      imagesByQuestion.putIfAbsent(qUid, () => []).add(
          _imageSignature(r['position'], r['mime'], r['anchor'], r['content']));
    }
    return {
      for (final r in rows)
        _questionSignature(r, imagesByQuestion[r['uid'] as String? ?? '']),
    };
  }

  /// 对端快照里某题库的题目内容指纹集合
  Set<String> _fingerprintsOf(
    List<Map<String, dynamic>> questions,
    Map<String, List<Map<String, dynamic>>> imagesByQuestion,
  ) {
    return {
      for (final q in questions)
        _questionSignature(
          q,
          (imagesByQuestion[q['uid']] ?? const [])
              .map((i) => _imageSignature(
                  i['position'], i['mime'], i['anchor'], i['content']))
              .toList(),
        ),
    };
  }

  static String _questionSignature(
      Map<String, dynamic> q, List<String>? imageSigs) {
    final parts = [
      (q['title'] ?? '').toString(),
      (q['options'] ?? '').toString(),
      (q['correct_answer'] ?? '').toString(),
      (q['question_type'] ?? '').toString(),
      (q['knowledge_point'] ?? '').toString(),
    ];
    final imgs = [...?imageSigs]..sort();
    return sha1
        .convert(
            utf8.encode('${parts.join('\u0001')}\u0002${imgs.join('\u0001')}'))
        .toString();
  }

  static String _imageSignature(
      Object? position, Object? mime, Object? anchor, Object? content) {
    // 本机是 BLOB，对端快照是 base64 —— 统一成字节再取摘要
    List<int> bytes;
    if (content is List<int>) {
      bytes = content;
    } else if (content is String) {
      bytes = _tryBase64(content);
    } else {
      bytes = const [];
    }
    final digest = sha1.convert(bytes).toString();
    return '${position ?? ''}|${mime ?? ''}|${anchor ?? ''}|$digest';
  }

  static List<int> _tryBase64(String s) {
    try {
      return base64Decode(s);
    } catch (_) {
      return utf8.encode(s);
    }
  }

  /// 落地一条同名题库冲突（用户在首页做的决定）。
  ///
  /// [overwrite] = true → 用对端题库整行替换本机同名题库（题目/配图全换）；
  /// false → 「增添」：只把**对端多出来**的题目并进本机该题库
  /// （按内容指纹去重，本机已有的题不动）。
  /// 返回受影响的题目数。
  Future<int> resolveBankConflict(SyncBankConflict conflict,
      {required bool overwrite}) async {
    final db = await _db.database;
    final now = DateTime.now().toIso8601String();
    var affected = 0;

    await db.transaction((txn) async {
      final localBankId = conflict.localBankId;
      if (overwrite) {
        // 覆盖：清掉本机该题库的题目与配图，再把对端的整套写进来
        await txn.delete('question_images',
            where:
                'question_id IN (SELECT id FROM questions WHERE bank_id = ?)',
            whereArgs: [localBankId]);
        await txn.delete('questions',
            where: 'bank_id = ?', whereArgs: [localBankId]);
        // 题库行本身更新为对端的名称/来源等
        await txn.update(
          'question_banks',
          {
            'name': conflict.peerBank['name'] ?? conflict.name,
            'file_source': conflict.peerBank['file_source'],
            'question_count': conflict.peerBank['question_count'] ?? 0,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [localBankId],
        );
      }

      // 现有指纹（覆盖模式下此时为空集）
      final existing = await _questionFingerprints(txn, localBankId);
      final imagesByQuestion = <String, List<Map<String, dynamic>>>{};
      for (final img in conflict.peerImages) {
        final qUid = img['question_uid'] as String?;
        if (qUid == null || qUid.isEmpty) continue;
        imagesByQuestion.putIfAbsent(qUid, () => []).add(img);
      }

      for (final q in conflict.peerQuestions) {
        final fp = _questionSignature(
          q,
          (imagesByQuestion[q['uid']] ?? const [])
              .map((i) => _imageSignature(
                  i['position'], i['mime'], i['anchor'], i['content']))
              .toList(),
        );
        if (!overwrite && existing.contains(fp)) continue; // 增添：本机已有则跳过
        final qid = await _db.upsertQuestionByUid(txn, {
          'uid': q['uid'],
          'bank_id': localBankId,
          'title': q['title'] ?? '',
          'options': q['options'] ?? '[]',
          'correct_answer': q['correct_answer'] ?? '',
          'analysis': q['analysis'],
          'question_type': q['question_type'] ?? 'single_choice',
          'source': q['source'],
          'knowledge_point': q['knowledge_point'],
          'created_at': q['created_at'] ?? now,
          'updated_at': q['updated_at'],
        });
        affected++;
        // 配图随题：首写槽位生效，不覆盖本机已有槽位
        for (final img in imagesByQuestion[q['uid']] ?? const []) {
          final raw = img['content'];
          final bytes = raw is String ? _tryBase64(raw) : <int>[];
          if (bytes.isEmpty) continue;
          // 事务内直接写（mergeQuestionImages 用的是全局 batch，不能嵌事务）
          await txn.insert(
            'question_images',
            {
              'question_id': qid,
              'position': (img['position'] as num?)?.toInt() ?? 0,
              'mime': (img['mime'] ?? 'image/jpeg').toString(),
              'width': (img['width'] as num?)?.toInt() ?? 0,
              'height': (img['height'] as num?)?.toInt() ?? 0,
              'anchor': img['anchor'],
              'content': Uint8List.fromList(bytes),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }

      // 题目数变了，题库行的计数跟着更新
      final countRows = await txn.rawQuery(
          'SELECT COUNT(*) AS c FROM questions WHERE bank_id = ?',
          [localBankId]);
      final count = (countRows.first['c'] as int?) ?? 0;
      await txn.update('question_banks', {'question_count': count},
          where: 'id = ?', whereArgs: [localBankId]);
    });

    DebugLogService.instance.log('SYNC',
        '同名题库「${conflict.name}」已${overwrite ? '覆盖' : '增添'}，影响 $affected 题');
    return affected;
  }

  /// 合并对端快照入库（单事务）。返回处理的实体数；
  /// 快照来自本机（device_id 相同）时直接跳过。
  ///
  /// [conflictSink] 非空时，遇到**同名但内容不同**的题库会把冲突收集进去
  /// （一样就不更新，不一样就挂起等用户选覆盖或增添）。
  /// 冲突题库及其题目在本批中**不合并**，等用户决策后走
  /// [resolveBankConflict] 落地。
  ///
  /// 增量快照（`incremental == true`）时**跳过同名内容比对**：增量里对端只带
  /// 了部分题目，拿部分列表去算指纹会把「本机 30 题 / 对端 3 题」误判成
  /// 「内容不同」，凭空造出一堆假冲突。同名比对只在首次全量同步时做一次，
  /// 增量轮次按 uid 直接 upsert 即可。
  Future<int> importSnapshot(
    Map<String, dynamic> snapshot, {
    List<SyncBankConflict>? conflictSink,
  }) async {
    final deviceId = await DeviceService.instance.deviceId;
    if (snapshot['device_id'] == deviceId) return 0; // 不合并自己的快照
    final total = Stopwatch()..start();
    final db = await _db.database;
    final now = DateTime.now().toIso8601String();
    final incremental = snapshot['incremental'] == true;
    var merged = 0;

    // 对端题库按 uid 归档，便于同名比对时取到它名下的题目与配图
    final peerQuestionsByBank = <String, List<Map<String, dynamic>>>{};
    for (final raw in (snapshot['questions'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      final bankUid = m['bank_uid'] as String?;
      if (bankUid == null || bankUid.isEmpty) continue;
      peerQuestionsByBank.putIfAbsent(bankUid, () => []).add(m);
    }
    final peerImagesByQuestion = <String, List<Map<String, dynamic>>>{};
    for (final raw in (snapshot['question_images'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      final qUid = m['question_uid'] as String?;
      if (qUid == null || qUid.isEmpty) continue;
      peerImagesByQuestion.putIfAbsent(qUid, () => []).add(m);
    }

    await db.transaction((txn) async {
      // 0. 本地「题目 uid → 本地 id」一次性读进内存。
      //    旧实现对**每一张配图、每一条作答记录**都单独查一次 questions，
      //    几百条就是几百次 SQL 往返（每次都要过一遍 sqflite 的 channel）。
      //    这是「几十道题同步十几分钟」的一半原因，另一半见 2b 的嵌套 db 死锁。
      final questionLocalByUid = <String, int>{};
      final localQuestionRows =
          await txn.query('questions', columns: ['id', 'uid']);
      for (final r in localQuestionRows) {
        final u = r['uid'] as String?;
        if (u != null && u.isNotEmpty) questionLocalByUid[u] = r['id'] as int;
      }

      // 1. 题库
      final bankLocalByUid = <String, int>{};
      // 同名冲突 / 内容一致的题库：本批跳过它们的题库行与题目
      final deferredBankUids = <String>{};
      for (final raw in (snapshot['banks'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final uid = m['uid'] as String?;
        if (uid == null || uid.isEmpty) continue;
        final name = (m['name'] ?? '').toString();

        // 同名检测：uid 不同但题库名相同 → 先比内容（增量轮次不做：
        // 增量只带部分题目，比对必然失真，见方法头注释）
        final sameName = await txn.query(
          'question_banks',
          columns: ['id', 'uid'],
          where: 'name = ?',
          whereArgs: [name],
          limit: 1,
        );
        final hasNameClash =
            sameName.isNotEmpty && sameName.first['uid'] != uid;
        if (hasNameClash && !incremental) {
          final localBankId = sameName.first['id'] as int;
          final peerQuestions = peerQuestionsByBank[uid] ?? const [];
          final localFp = await _questionFingerprints(txn, localBankId);
          final peerFp = _fingerprintsOf(
            peerQuestions,
            peerImagesByQuestion,
          );
          if (localFp.length == peerFp.length && localFp.containsAll(peerFp)) {
            // ① 内容完全一致 → 不更新（一样就不重复导入）
            deferredBankUids.add(uid);
            DebugLogService.instance.log('SYNC', '同名题库「$name」内容一致，跳过');
            continue;
          }
          // ② 内容不同 → 挂起冲突，等用户在首页选择覆盖或增添
          deferredBankUids.add(uid);
          final addition = peerFp.difference(localFp).length;
          conflictSink?.add(SyncBankConflict(
            name: name,
            peerBankUid: uid,
            peerBank: m,
            peerQuestions:
                peerQuestions.map((e) => Map<String, dynamic>.from(e)).toList(),
            peerImages: [
              for (final q in peerQuestions)
                ...(peerImagesByQuestion[q['uid']] ?? const []),
            ],
            localBankId: localBankId,
            localCount: localFp.length,
            peerCount: peerFp.length,
            additionCount: addition,
            peerDeviceName: (snapshot['device_name'] ?? '').toString(),
          ));
          DebugLogService.instance.log('SYNC',
              '同名题库「$name」内容不同（本机 ${localFp.length} / 对端 ${peerFp.length}），已挂起待决策');
          continue;
        }

        bankLocalByUid[uid] = await _db.upsertBankByUid(txn, {
          'uid': uid,
          'name': name,
          'file_source': m['file_source'],
          'question_count': m['question_count'] ?? 0,
          'created_at': m['created_at'] ?? now,
          'updated_at': m['updated_at'],
        });
        merged++;
      }

      // 2. 题目（bank_uid 映射为本地 bank_id；未知题库的题跳过）
      for (final raw in (snapshot['questions'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final uid = m['uid'] as String?;
        if (uid == null || uid.isEmpty) continue;
        final bankUid = m['bank_uid'] as String?;
        // 同名冲突/内容一致题库的题目本批不落库
        if (bankUid != null && deferredBankUids.contains(bankUid)) continue;
        final id = await _db.upsertQuestionByUid(txn, {
          'uid': uid,
          'bank_id': bankUid != null ? bankLocalByUid[bankUid] : null,
          'title': m['title'] ?? '',
          'options': m['options'] ?? '[]',
          'correct_answer': m['correct_answer'] ?? '',
          'analysis': m['analysis'],
          'question_type': m['question_type'] ?? 'single_choice',
          'source': m['source'],
          'knowledge_point': m['knowledge_point'],
          'created_at': m['created_at'] ?? now,
          'updated_at': m['updated_at'],
        });
        if (id > 0) questionLocalByUid[uid] = id;
        merged++;
      }

      // 兜底：对端引用了更早同步过的实体（本批未重发）时按库内 uid 查。
      // 命中 0 步里预读的映射就不查库了。
      Future<int?> questionIdByUid(String? uid) async {
        if (uid == null || uid.isEmpty) return null;
        final cached = questionLocalByUid[uid];
        if (cached != null) return cached;
        final row = await _db.questionRowByUid(txn, uid);
        if (row == null) return null;
        questionLocalByUid[uid] = row['id'] as int;
        return questionLocalByUid[uid];
      }

      // 2b. 题目配图（图片是题目的一部分，随题合并）。
      //     首写槽位生效、不覆盖本机已有——本地题目文本的占位符与本地
      //     图片槽位是对齐的，覆盖会错位；删除型差异不跨设备传播。
      //
      //     **必须用 txn 写**：旧实现调的是 `DatabaseService.mergeQuestionImages`，
      //     它内部走全局 `db.batch()`——在事务里访问同一个 db 会排队等事务结束，
      //     而事务又在等这次 batch，于是**永久卡死**（真机表现：界面一直转圈，
      //     日志里只剩「接收异常」，十几分钟走不完一批几十道题的同步）。
      for (final entry in peerImagesByQuestion.entries) {
        final questionId = await questionIdByUid(entry.key);
        if (questionId == null) continue;
        for (final m in entry.value) {
          final data = m['content'];
          Uint8List bytes;
          try {
            bytes = data is String ? base64Decode(data) : Uint8List(0);
          } catch (_) {
            continue;
          }
          if (bytes.isEmpty) continue;
          await txn.insert(
            'question_images',
            {
              'question_id': questionId,
              'position': (m['position'] as num?)?.toInt() ?? 0,
              'mime': m['mime'] as String? ?? 'image/jpeg',
              'width': (m['width'] as num?)?.toInt() ?? 0,
              'height': (m['height'] as num?)?.toInt() ?? 0,
              'anchor': m['anchor'],
              'content': bytes,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          merged++;
        }
      }

      // 3. 会话（bank_ids 的 uid 还原为本地 id）
      final sessionLocalByUid = <String, int>{};
      for (final raw in (snapshot['sessions'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final uid = m['uid'] as String?;
        if (uid == null || uid.isEmpty) continue;
        sessionLocalByUid[uid] = await _db.upsertSessionByUid(txn, {
          'uid': uid,
          'bank_ids':
              _mapUidsToBankIds(m['bank_ids'] as String? ?? '', bankLocalByUid),
          'mode': m['mode'] ?? 'single',
          'total_questions': m['total_questions'] ?? 0,
          'correct_count': m['correct_count'] ?? 0,
          'wrong_count': m['wrong_count'] ?? 0,
          'start_time': m['start_time'] ?? now,
          'end_time': m['end_time'],
          'duration_seconds': m['duration_seconds'] ?? 0,
          'source': m['source'] ?? 'real',
        });
        merged++;
      }

      // 4. 作答记录（题目/会话 uid 映射；孤儿记录跳过）
      for (final raw in (snapshot['answer_records'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final uid = m['uid'] as String?;
        if (uid == null || uid.isEmpty) continue;
        final questionId = await questionIdByUid(m['question_uid'] as String?);
        if (questionId == null) continue;
        final sessionUid = m['session_uid'] as String?;
        int? sessionId =
            sessionUid != null ? sessionLocalByUid[sessionUid] : null;
        if (sessionId == null && sessionUid != null && sessionUid.isNotEmpty) {
          final row = await _db.sessionRowByUid(txn, sessionUid);
          sessionId = row?['id'] as int?;
        }
        await _db.upsertAnswerRecordByUid(txn, {
          'uid': uid,
          'question_id': questionId,
          'session_id': sessionId,
          'user_answer': m['user_answer'],
          'is_correct': m['is_correct'] ?? 0,
          'ai_analysis': m['ai_analysis'],
          'answered_at': m['answered_at'] ?? now,
          'hidden': m['hidden'] ?? 0,
          'source': m['source'] ?? 'real',
          'origin_device': m['origin_device'] ?? snapshot['device_id'],
        });
        merged++;
      }

      // 5. 错题（按 题+来源设备 共存，两端各自保留）
      for (final raw in (snapshot['error_book'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final questionId = await questionIdByUid(m['question_uid'] as String?);
        if (questionId == null) continue;
        await _db.upsertErrorBookEntry(txn, {
          'question_id': questionId,
          'uid': m['uid'],
          'origin_device': (m['origin_device'] as String?)?.isNotEmpty == true
              ? m['origin_device']
              : snapshot['device_id'],
          'added_at': m['added_at'] ?? now,
        });
        merged++;
      }

      // 6. 批注（按 题+设备 隔离：他端批注存其 device_id 下，
      //    绝不覆盖本机批注）
      for (final raw in (snapshot['annotations'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final questionId = await questionIdByUid(m['question_uid'] as String?);
        if (questionId == null) continue;
        final owner = m['device_id'] as String?;
        if (owner == null || owner.isEmpty) continue;
        await _db.upsertAnnotationByDevice(txn, {
          'question_id': questionId,
          'device_id': owner,
          'data': m['data'] ?? '',
          'updated_at': m['updated_at'] ?? now,
        });
        merged++;
      }
      // 7. 插件内容（v1.35）：笔记 / 待办 / 助教人设与记忆
      final pluginPayload = snapshot['plugins'];
      if (pluginPayload is Map) {
        merged += await _importPlugins(
          txn,
          Map<String, dynamic>.from(pluginPayload),
          now,
        );
      }
    });
    DebugLogService.instance.log('SYNC',
        '快照合并完成：$merged 项，${incremental ? '增量' : '全量'}，'
        '耗时 ${total.elapsedMilliseconds}ms');
    debugPrint('[SYNC] importSnapshot ${incremental ? 'incremental' : 'full'} '
        'merged=$merged ${total.elapsedMilliseconds}ms');
    return merged;
  }

  /// 合并插件内容（事务内）。
  ///
  /// 冲突口径与题库一致：**按 uid 认同一行，`updated_at` 新的赢**；
  /// 对端没带 uid 的脏数据直接跳过（宁可少合并，也不制造重复）。
  Future<int> _importPlugins(
    DatabaseExecutor txn,
    Map<String, dynamic> payload,
    String now,
  ) async {
    var merged = 0;

    final bankRows = await txn.query('question_banks', columns: ['id', 'uid']);
    final bankIdByUid = <String, int>{
      for (final r in bankRows)
        if (r['uid'] != null && (r['uid'] as String).isNotEmpty)
          r['uid'] as String: r['id'] as int,
    };

    Future<int?> questionIdByUid(String? uid) async {
      if (uid == null || uid.isEmpty) return null;
      final rows = await txn.query('questions',
          columns: ['id'], where: 'uid = ?', whereArgs: [uid]);
      return rows.isEmpty ? null : rows.first['id'] as int;
    }

    // ── 笔记 ──
    final notesBlock = payload['notes'];
    if (notesBlock is Map) {
      final localIds = <String, int>{};
      final noteRows = notesBlock['notes'];
      if (noteRows is List) {
        for (final raw in noteRows) {
          if (raw is! Map) continue;
          final m = Map<String, dynamic>.from(raw);
          final uid = (m['uid'] ?? '').toString();
          if (uid.isEmpty) continue;
          final updatedAt =
              (m['updated_at'] ?? m['created_at'] ?? now).toString();
          final values = <String, Object?>{
            'bank_id': bankIdByUid[(m['bank_uid'] ?? '').toString()],
            'question_id':
                await questionIdByUid((m['question_uid'] ?? '').toString()),
            'title': (m['title'] ?? '').toString(),
            'content': (m['content'] ?? '').toString(),
            'created_at': m['created_at'] ?? now,
            'updated_at': updatedAt,
            'origin_device': m['origin_device'],
          };
          final existing = await txn.query('notes',
              columns: ['id', 'updated_at'],
              where: 'uid = ?',
              whereArgs: [uid]);
          if (existing.isEmpty) {
            final id = await txn.insert('notes', {...values, 'uid': uid});
            localIds[uid] = id;
            merged++;
          } else {
            final localId = existing.first['id'] as int;
            localIds[uid] = localId;
            final localUpdated =
                (existing.first['updated_at'] ?? '').toString();
            if (updatedAt.compareTo(localUpdated) > 0) {
              await txn.update('notes', values,
                  where: 'id = ?', whereArgs: [localId]);
              merged++;
            }
          }
        }
      }

      // 出链：按 (note, target) 幂等插入；不删本机已有链（删除型差异不传播）
      final linkRows = notesBlock['links'];
      if (linkRows is List) {
        for (final raw in linkRows) {
          if (raw is! Map) continue;
          final m = Map<String, dynamic>.from(raw);
          final noteUid = (m['note_uid'] ?? '').toString();
          final target = (m['target'] ?? '').toString().trim();
          if (noteUid.isEmpty || target.isEmpty) continue;
          var noteId = localIds[noteUid];
          if (noteId == null) {
            final rows = await txn.query('notes',
                columns: ['id'], where: 'uid = ?', whereArgs: [noteUid]);
            if (rows.isEmpty) continue;
            noteId = rows.first['id'] as int;
            localIds[noteUid] = noteId;
          }
          await txn.insert(
            'note_links',
            {'note_id': noteId, 'target': target},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
    }

    // ── 日程待办 ──
    final scheduleBlock = payload['schedule'];
    if (scheduleBlock is Map && scheduleBlock['items'] is List) {
      for (final raw in (scheduleBlock['items'] as List)) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final uid = (m['uid'] ?? '').toString();
        if (uid.isEmpty) continue;
        final updatedAt =
            (m['updated_at'] ?? m['created_at'] ?? now).toString();
        final values = <String, Object?>{
          'title': (m['title'] ?? '').toString(),
          'detail': (m['detail'] ?? '').toString(),
          'due_at': m['due_at'],
          'done': m['done'] is bool
              ? ((m['done'] as bool) ? 1 : 0)
              : (m['done'] ?? 0),
          'created_at': m['created_at'] ?? now,
          'updated_at': updatedAt,
          'origin_device': m['origin_device'],
        };
        final existing = await txn.query('schedule_items',
            columns: ['id', 'updated_at'],
            where: 'uid = ?',
            whereArgs: [uid]);
        if (existing.isEmpty) {
          await txn.insert('schedule_items', {...values, 'uid': uid});
          merged++;
        } else {
          final localUpdated = (existing.first['updated_at'] ?? '').toString();
          if (updatedAt.compareTo(localUpdated) > 0) {
            await txn.update('schedule_items', values,
                where: 'id = ?', whereArgs: [existing.first['id']]);
            merged++;
          }
        }
      }
    }

    // ── 助教：人设 + 记忆（不含 Key / 接口 / 知识库 / 好感度） ──
    final companionBlock = payload['companion'];
    if (companionBlock is Map) {
      merged += await _importCompanion(
          txn, Map<String, dynamic>.from(companionBlock));
    }

    return merged;
  }

  /// 合并助教人设与记忆：对端有值的字段覆盖本机，本机独有的接口配置保持不动。
  Future<int> _importCompanion(
      DatabaseExecutor txn, Map<String, dynamic> block) async {
    var merged = 0;
    final remoteSettings = block['settings'];
    if (remoteSettings is Map && remoteSettings.isNotEmpty) {
      final rows = await txn.query('settings',
          where: 'key = ?', whereArgs: [CompanionService.settingsKey]);
      CompanionSettings local = CompanionSettings.defaults;
      if (rows.isNotEmpty) {
        try {
          final parsed = jsonDecode((rows.first['value'] ?? '').toString());
          if (parsed is Map) {
            local =
                CompanionSettings.fromJson(Map<String, dynamic>.from(parsed));
          }
        } catch (_) {}
      }
      final avatar = (remoteSettings['avatar'] ?? '').toString();
      final toneName = (remoteSettings['tone'] ?? '').toString();
      final minutes = int.tryParse('${remoteSettings['bubble_minutes']}');
      final remoteName = (remoteSettings['bot_name'] ?? '').toString().trim();
      final next = local.copyWith(
        botName: remoteName.isEmpty ? local.botName : remoteName,
        avatar: CompanionAvatarOption.isValidId(avatar) ? avatar : local.avatar,
        tone: CompanionTone.values.where((t) => t.name == toneName).firstOrNull ??
            local.tone,
        customPersona: (remoteSettings['custom_persona'] ?? '').toString(),
        memoryEnabled: remoteSettings['memory'] is bool
            ? remoteSettings['memory'] as bool
            : local.memoryEnabled,
        bubbleMinutes: CompanionSettings.bubbleMinuteOptions.contains(minutes)
            ? minutes!
            : local.bubbleMinutes,
      );
      await txn.insert(
        'settings',
        {
          'key': CompanionService.settingsKey,
          'value': jsonEncode(next.toJson()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      merged++;
    }

    final remoteMemory = block['memory'];
    if (remoteMemory is Map && remoteMemory.isNotEmpty) {
      final rows = await txn.query('settings',
          where: 'key = ?', whereArgs: [CompanionService.memoryKey]);
      var local = CompanionMemory();
      if (rows.isNotEmpty) {
        try {
          final parsed = jsonDecode((rows.first['value'] ?? '').toString());
          if (parsed is Map) {
            local = CompanionMemory.fromJson(Map<String, dynamic>.from(parsed));
          }
        } catch (_) {}
      }
      final turns = <CompanionTurn>[...local.turns];
      final seen = {
        for (final t in turns) '${t.role}|${t.day}|${t.text}',
      };
      final incoming = remoteMemory['turns'];
      if (incoming is List) {
        for (final raw in incoming) {
          final turn = CompanionTurn.tryFromJson(raw);
          if (turn == null) continue;
          if (!seen.add('${turn.role}|${turn.day}|${turn.text}')) continue;
          turns.add(turn);
        }
      }
      // 超出上限就丢最早的（与 CompanionMemory.add 的口径一致）
      final trimmed = turns.length > CompanionMemory.maxTurns
          ? turns.sublist(turns.length - CompanionMemory.maxTurns)
          : turns;
      final summary = (remoteMemory['summary'] ?? '').toString().trim();
      final mergedMemory = CompanionMemory(
        turns: trimmed,
        // 摘要两边都有时取更长的：那是信息更多的那份「长期记忆」
        summary:
            summary.length > local.summary.length ? summary : local.summary,
      );
      await txn.insert(
        'settings',
        {
          'key': CompanionService.memoryKey,
          'value': jsonEncode(mergedMemory.toJson()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      merged++;
    }
    return merged;
  }
}

