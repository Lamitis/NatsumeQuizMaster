import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'api_endpoint.dart';
import 'database_service.dart';
import 'debug_log_service.dart';
import 'key_crypto.dart';

/// MinerU 解析结果
class MineruResult {
  const MineruResult({required this.markdown, required this.precise});

  /// 版面识别后的 Markdown 全文（表格/公式已转成文本，可直接喂给切题 AI）
  final String markdown;

  /// true = 走精准解析（填了 Token）；false = 走官方轻量通道（免 Token）
  final bool precise;
}

/// MinerU 文档解析（v1.30.2）。
///
/// ## 为什么接它
/// 题库里扫描版 PDF 很常见：字是画进图里的，本地抽不出文字层。
/// 端上 ML Kit OCR（见 [OcrService]）只能认「一行行字」，遇到双栏、表格、
/// 公式版面就散架；MinerU 是版面级识别，输出 Markdown，正好是切题 AI 要的
/// 输入形态。
///
/// ## 许可（MinerU 3.1.0 起）
/// 上游从 AGPLv3 切到自定义「MinerU Open Source License」（Apache-2.0 +
/// 附加条款）。本 App 只调用其**官方在线 API**（不内嵌其代码与模型权重），
/// 仍需遵守两条附加条款：
/// 1. 规模门槛：月活 < 1 亿 且 月收入 < 2000 万美元免费用；超过需单独商业许可；
/// 2. 署名义务：若把本 App 作为在线服务（SaaS）提供给第三方，必须在界面或
///    公开文档显著位置标明使用了 MinerU —— 对应 [attribution]，已展示在
///    「设置 → AI 接口 → 扫描件识别增强」。
///
/// ## 两条通道
/// - 轻量（默认，免 Token）：`/api/v1/agent/parse/file`，≤10MB、≤20 页，
///   只返回 Markdown 的 CDN 链接（异步：提交 → PUT 上传 → 轮询）；
/// - 精准（填 Token）：`/api/v4/file-urls/batch`，≤200MB、≤200 页，
///   结果是一个 zip（内含 Markdown/JSON）。
///
/// 所有失败都返回 null（并在调用方状态栏留一句原因）：解析增强是加分项，
/// 不该让导入流程硬失败——本地抽取与视觉切题的退路仍然在。
class MineruService {
  MineruService._();
  static final MineruService instance = MineruService._();

  /// 署名（许可证附加条款要求；SaaS 场景必须在界面/文档显著位置可见）
  static const String attribution = 'PDF 版面解析由 MinerU（OpenDataLab）提供技术支持';

  static const String _agentBase = 'https://mineru.net/api/v1/agent';
  static const String _preciseBase = 'https://mineru.net/api/v4';

  /// 轻量通道的体积上限（官方限制 10MB；超了只能填 Token 走精准解析）
  static const int _agentMaxBytes = 10 * 1024 * 1024;

  final DatabaseService _db = DatabaseService.instance;

  /// 用户在设置里是否开启了 MinerU 增强
  Future<bool> isEnabled() async =>
      (await _db.getSetting('mineru_enabled') ?? '0') == '1';

  /// 读取用户填的 Token（DB 里存 KeyCrypto 密文，与 API Key 同一口径）
  Future<String> readToken() async {
    final stored = await _db.getSetting('mineru_token') ?? '';
    return stored.isEmpty ? '' : KeyCrypto.decrypt(stored);
  }

  /// 解析一份本地文件，返回 Markdown；未启用/失败返回 null。
  ///
  /// [onStatus] 用于把「排队中/解析中」这类阶段进度显示给用户。
  Future<MineruResult?> parseFile(String path,
      {void Function(String status)? onStatus}) async {
    if (!await isEnabled()) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    final fileName = path.split(RegExp(r'[\\/]')).last;
    final token = await readToken();
    try {
      final bytes = await file.readAsBytes();
      if (token.isEmpty && bytes.length > _agentMaxBytes) {
        onStatus?.call('文件超过 10MB，轻量通道不支持；可在设置里填 MinerU Token 走精准解析');
        return null;
      }
      final markdown = token.isEmpty
          ? await _parseWithAgent(fileName, bytes, onStatus: onStatus)
          : await _parseWithPreciseApi(token, fileName, bytes,
              onStatus: onStatus);
      if (markdown.trim().isEmpty) return null;
      return MineruResult(markdown: markdown, precise: token.isNotEmpty);
    } catch (e) {
      DebugLogService.instance.log('MINERU', '解析失败（$fileName）：$e');
      onStatus?.call('MinerU 解析失败：$e');
      return null;
    }
  }
  // ======================== 轻量通道（免 Token） ========================

  /// 提交任务 → PUT 上传 → 轮询 → 取 Markdown
  Future<String> _parseWithAgent(String fileName, Uint8List bytes,
      {void Function(String)? onStatus}) async {
    final created = await _createAgentTask(fileName);
    final taskId = '${created['task_id'] ?? ''}';
    final uploadUrl = '${created['file_url'] ?? ''}';
    if (taskId.isEmpty || uploadUrl.isEmpty) {
      throw Exception('MinerU 未返回任务或上传地址');
    }
    onStatus?.call('MinerU：上传文件…');
    await _upload(uploadUrl, bytes);

    final deadline = DateTime.now().add(const Duration(minutes: 8));
    var lastState = '';
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final resp = await http.get(Uri.parse('$_agentBase/parse/$taskId'));
      final data = _unwrap(resp);
      final state = '${data['state'] ?? ''}';
      if (state != lastState) {
        lastState = state;
        onStatus?.call('MinerU：${_stateLabel(state)}');
      }
      if (state == 'done') {
        final url = data['markdown_url'];
        if (url is! String || url.isEmpty) {
          throw Exception('解析完成但没有 Markdown 链接');
        }
        final md = await http.get(Uri.parse(url));
        if (md.statusCode != 200) {
          throw Exception('下载 Markdown 失败（HTTP ${md.statusCode}）');
        }
        return utf8.decode(md.bodyBytes, allowMalformed: true);
      }
      if (state == 'failed') {
        throw Exception('${data['err_msg'] ?? 'MinerU 解析失败'}');
      }
    }
    throw Exception('MinerU 解析超时，请稍后重试');
  }

  /// 创建轻量任务。
  ///
  /// 官方文档对 `/parse/file` 的必填字段只明确到「必须有文件名」，其余
  /// （language / is_ocr / enable_table / enable_formula）都是可选增强。
  /// 因此先按「全字段」提交，被拒（参数错误）时退到最小字段再试一次——
  /// 这样上游字段改名也只丢增强项，不会整条通道失效。
  Future<Map<String, dynamic>> _createAgentTask(String fileName) async {
    final bodies = <Map<String, dynamic>>[
      {
        'file_name': fileName,
        'language': 'ch',
        'is_ocr': true,
        'enable_table': true,
        'enable_formula': true,
      },
      {'file_name': fileName},
    ];
    Object? lastError;
    for (final body in bodies) {
      try {
        final resp = await http.post(
          Uri.parse('$_agentBase/parse/file'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        );
        return _unwrap(resp);
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('$lastError');
  }
  // ======================== 精准解析（Token） ========================

  Future<String> _parseWithPreciseApi(
      String token, String fileName, Uint8List bytes,
      {void Function(String)? onStatus}) async {
    final auth = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final resp = await http.post(
      Uri.parse('$_preciseBase/file-urls/batch'),
      headers: auth,
      body: jsonEncode({
        'enable_formula': true,
        'language': 'ch',
        'enable_table': true,
        // vlm 模型对扫描件/复杂版式更稳（官方推荐）
        'model_version': 'vlm',
        'files': [
          {'name': fileName, 'is_ocr': true},
        ],
      }),
    );
    final created = _unwrap(resp);
    final batchId = '${created['batch_id'] ?? ''}';
    final urls = created['file_urls'];
    if (batchId.isEmpty || urls is! List || urls.isEmpty) {
      throw Exception('MinerU 未返回批次或上传地址');
    }
    onStatus?.call('MinerU：上传文件…');
    await _upload('${urls.first}', bytes);

    final deadline = DateTime.now().add(const Duration(minutes: 20));
    var lastState = '';
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final r = await http.get(
        Uri.parse('$_preciseBase/extract-results/batch/$batchId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = _unwrap(r);
      final results = data['extract_result'];
      if (results is! List || results.isEmpty) continue;
      final item = results.first;
      if (item is! Map) continue;
      final state = '${item['state'] ?? ''}';
      if (state != lastState) {
        lastState = state;
        onStatus?.call('MinerU：${_stateLabel(state)}');
      }
      if (state == 'done') {
        final zipUrl = item['full_zip_url'];
        if (zipUrl is! String || zipUrl.isEmpty) {
          throw Exception('解析完成但没有结果包地址');
        }
        return _markdownFromZip(zipUrl, token: token);
      }
      if (state == 'failed') {
        throw Exception('${item['err_msg'] ?? 'MinerU 解析失败'}');
      }
    }
    throw Exception('MinerU 解析超时，请稍后重试');
  }

  /// 从结果 zip 里取正文 Markdown（包里同时有 md/json，取最长的那份 md）
  Future<String> _markdownFromZip(String url, {required String token}) async {
    final resp = await http
        .get(Uri.parse(url), headers: {'Authorization': 'Bearer $token'});
    if (resp.statusCode != 200) {
      throw Exception('下载解析结果失败（HTTP ${resp.statusCode}）');
    }
    final archive = ZipDecoder().decodeBytes(resp.bodyBytes);
    ArchiveFile? best;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      if (!f.name.toLowerCase().endsWith('.md')) continue;
      if (best == null || f.size > best.size) best = f;
    }
    if (best == null) throw Exception('MinerU 结果包里没有 Markdown');
    final raw = best.content;
    final bytes = raw is List<int>
        ? Uint8List.fromList(raw)
        : (raw as InputStream).toUint8List();
    return utf8.decode(bytes, allowMalformed: true);
  }
  // ======================== 公共小工具 ========================

  Future<void> _upload(String url, Uint8List bytes) async {
    final resp = await http.put(
      Uri.parse(url),
      headers: const {'Content-Type': 'application/octet-stream'},
      body: bytes,
    );
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw Exception('文件上传失败（HTTP ${resp.statusCode}）');
    }
  }

  /// 解包统一响应体：`{code, msg, data}`；code 非 0 / HTTP 错误都转成可读异常
  Map<String, dynamic> _unwrap(http.Response resp) {
    Map<String, dynamic>? body;
    try {
      final decoded =
          jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // 非 JSON：下面统一报错
    }
    if (body == null) {
      throw Exception('MinerU 返回内容无法解析（HTTP ${resp.statusCode}）');
    }
    final code = body['code'];
    if (code != null && code != 0) {
      throw Exception('${body['msg'] ?? 'MinerU 接口返回错误（code=$code）'}');
    }
    if (resp.statusCode >= 400) {
      throw Exception(ApiEndpoint.explainStatus(resp.statusCode, resp.body));
    }
    final data = body['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return body;
  }

  static String _stateLabel(String state) => switch (state) {
        'waiting-file' => '等待文件上传…',
        'pending' => '排队中…',
        'running' => '解析中…',
        'converting' => '转换中…',
        'done' => '解析完成',
        'failed' => '解析失败',
        _ => '处理中（$state）…',
      };
}
