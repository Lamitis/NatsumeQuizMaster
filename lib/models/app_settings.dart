import 'dart:convert';

import '../services/key_crypto.dart';

/// 预设供应商（v1.28）：一键填入端点 + 模型，降低第三方接入门槛。
/// 所有条目均为 OpenAI 兼容协议；用户也可手动填任意官方/第三方地址。
class ApiPreset {
  final String name;
  final String endpoint;
  final String model;
  final String hint;

  /// 自定义项：不自动填端点/模型，仅把焦点交给输入框（用户手填任意地址）
  final bool isCustom;

  const ApiPreset(this.name, this.endpoint, this.model, this.hint,
      {this.isCustom = false});
}

/// 常见供应商预设（端点写基址即可，运行时会自动补全 /chat/completions）
const List<ApiPreset> kApiPresets = [
  ApiPreset('DeepSeek 官方', 'https://api.deepseek.com/v1', 'deepseek-chat',
      '国内直连，性价比高'),
  ApiPreset('阿里云百炼（通义）', 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'qwen-plus', '阿里云百炼，OpenAI 兼容模式'),
  ApiPreset('硅基流动', 'https://api.siliconflow.cn/v1', 'deepseek-ai/DeepSeek-V3',
      '聚合多家开源模型'),
  ApiPreset('智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4-flash',
      '清华智谱，有免费额度'),
  ApiPreset(
      '月之暗面 Kimi', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k', '长文本见长'),
  ApiPreset('OpenAI 官方', 'https://api.openai.com/v1', 'gpt-4o-mini', '需自备网络环境'),
  ApiPreset('OpenRouter', 'https://openrouter.ai/api/v1',
      'deepseek/deepseek-chat', '聚合全球模型（含免费额度）'),
  ApiPreset('OpenCode Go', 'https://opencode.ai/zen/go/v1', 'glm-5.3-flash',
      'Go 订阅（\$10/月），点「选择模型」可列出全部'),
  ApiPreset(
      '本地 Ollama', 'http://localhost:11434/v1', 'llama3.1', '本地部署，需自行启动服务'),
  // 自定义：不自动填端点/模型，用户手填任意官方或第三方地址
  ApiPreset('自定义', '', '', '手动填写接口地址', isCustom: true),
];

/// AI 提供方（v13：多接口抽象）。
///
/// 除 [openaiCompat] 外，各提供方在 `lib/services/ai/` 下有独立 Provider；
/// [ollama] 走本机 Ollama。已放弃 llama.cpp 本地大模型（改走轻量级 HTTP
/// 通义等极速模型 + 本地关键词分类，见 `SubjectClassifierService`）。
enum AiProviderKind {
  openaiCompat,
  anthropic,
  gemini,
  ollama;

  String get label => switch (this) {
        AiProviderKind.openaiCompat => 'OpenAI 兼容',
        AiProviderKind.anthropic => 'Anthropic',
        AiProviderKind.gemini => 'Gemini',
        AiProviderKind.ollama => 'Ollama',
      };
}

/// AI 解析/追问的回答详细程度（v1.28）
enum AnalysisDetail {
  /// 简洁：总字数 ≤150，每项 ≤2 句（默认）
  brief,

  /// 标准：总字数 ≤300
  standard,

  /// 详细：不设上限（原行为）
  detailed;

  String get label => switch (this) {
        AnalysisDetail.brief => '简洁',
        AnalysisDetail.standard => '标准',
        AnalysisDetail.detailed => '详细',
      };

  String get hint => switch (this) {
        AnalysisDetail.brief => '约 150 字，只讲最易混的点',
        AnalysisDetail.standard => '约 300 字，讲主要干扰项',
        AnalysisDetail.detailed => '不限制，逐个讲透',
      };
}

class AppSettings {
  static const String defaultApiEndpoint =
      'https://api.deepseek.com/v1/chat/completions';
  static const String defaultModel = 'deepseek-chat';

  String apiKey;
  String apiEndpoint;
  String model;
  bool soundEnabled;
  String nickname; // v1.0.2 对齐里程碑：昵称（首页专属问候）
  bool autoSync; // 局域网同步：自动同步开关（开启后广播信标并自动与发现的设备同步）
  String deviceName; // 局域网同步：本机设备名（缺省由 DeviceService 生成「NatsumeQuizMaster-平台」）
  AnalysisDetail analysisDetail; // AI 回答详细程度（默认简洁）
  bool keywordHighlight; // AI 回答关键词高亮（默认开启）

  /// AI 提供方（v13 多接口抽象）。默认 OpenAI 兼容（与旧版行为一致）。
  AiProviderKind providerKind;

  /// 扫描件识别增强（v1.30.2 · MinerU）：扫描版 PDF/图片先做版面识别
  /// 再交给 AI 切题。默认关闭——它会把文件上传到第三方服务，得用户自己开。
  bool mineruEnabled;

  /// MinerU API Token（可空：留空走官方免 Token 轻量通道）
  String mineruToken;

  /// 解析 / 追问是否引用已导入的知识库（v1.34）。
  ///
  /// 默认开启，但**只是软约束**：命中资料优先、未覆盖部分仍允许 AI 用自身
  /// 知识作答（见 `GroundingService.buildSoftBlock`）。没有导入任何知识库、
  /// 或检索没命中时不会注入，行为与旧版完全一致。
  bool analysisGrounding;

  /// v1.35：用户自定义的「知识点体系」。空列表 = 交给 AI 自行判断（旧行为）；
  /// 非空时打标签 / 导入解析都只在这个清单里选，保证全库标签口径统一。
  List<String> knowledgePointTypes;

  AppSettings({
    this.apiKey = '',
    this.apiEndpoint = defaultApiEndpoint,
    this.model = defaultModel,
    this.soundEnabled = true,
    this.nickname = '',
    this.autoSync = false,
    this.deviceName = '',
    this.analysisDetail = AnalysisDetail.brief,
    this.keywordHighlight = true,
    this.providerKind = AiProviderKind.openaiCompat,
    this.mineruEnabled = false,
    this.mineruToken = '',
    this.analysisGrounding = true,
    this.knowledgePointTypes = const [],
  });

  bool get isConfigured => apiKey.isNotEmpty;

  Map<String, String> toMap() {
    return {
      'api_key': KeyCrypto.encrypt(apiKey),
      'api_endpoint': apiEndpoint,
      'model': model,
      'sound_enabled': soundEnabled ? '1' : '0',
      'nickname': nickname,
      'auto_sync': autoSync ? '1' : '0',
      'device_name': deviceName,
      'analysis_detail': analysisDetail.name,
      'keyword_highlight': keywordHighlight ? '1' : '0',
      'provider_kind': providerKind.name,
      'mineru_enabled': mineruEnabled ? '1' : '0',
      // 与 api_key 同口径加密：Token 也是凭据，不能明文躺在备份里
      'mineru_token': KeyCrypto.encrypt(mineruToken),
      'analysis_grounding': analysisGrounding ? '1' : '0',
      // 知识点体系：JSON 数组（不是凭据，明文存，备份可携带）
      'knowledge_point_types': jsonEncode(knowledgePointTypes),
    };
  }

  factory AppSettings.fromMap(Map<String, String> map) {
    return AppSettings(
      apiKey: KeyCrypto.decrypt(map['api_key'] ?? ''),
      apiEndpoint: map['api_endpoint'] ?? defaultApiEndpoint,
      model: map['model'] ?? defaultModel,
      soundEnabled: map['sound_enabled'] != '0',
      nickname: map['nickname'] ?? '',
      autoSync: map['auto_sync'] == '1',
      deviceName: map['device_name'] ?? '',
      // 老用户无该字段 → 默认简洁；keyword_highlight 缺省为开
      analysisDetail: AnalysisDetail.values
              .where((d) => d.name == (map['analysis_detail'] ?? ''))
              .firstOrNull ??
          AnalysisDetail.brief,
      keywordHighlight: map['keyword_highlight'] != '0',
      // 老用户无 provider_kind → 默认 OpenAI 兼容（旧行为不变）
      providerKind: AiProviderKind.values
              .where((k) => k.name == (map['provider_kind'] ?? ''))
              .firstOrNull ??
          AiProviderKind.openaiCompat,
      mineruEnabled: map['mineru_enabled'] == '1',
      mineruToken: KeyCrypto.decrypt(map['mineru_token'] ?? ''),
      // 老用户 / 老备份没有这个键：默认开启（软约束，命中不到就不注入）
      analysisGrounding: map['analysis_grounding'] != '0',
      // 老用户没有知识点体系：空列表 = 沿用 AI 自行判断
      knowledgePointTypes: decodeKnowledgePointTypes(map['knowledge_point_types']),
    );
  }

  /// 解析「知识点体系」JSON；坏数据一律当空列表（老备份 / 手改过的值）。
  static List<String> decodeKnowledgePointTypes(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is String && e.trim().isNotEmpty) e.trim(),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 是否有用户自定义的知识点体系
  bool get hasKnowledgePointTypes => knowledgePointTypes.isNotEmpty;

  AppSettings copyWith({
    String? apiKey,
    String? apiEndpoint,
    String? model,
    bool? soundEnabled,
    String? nickname,
    bool? autoSync,
    String? deviceName,
    AnalysisDetail? analysisDetail,
    bool? keywordHighlight,
    AiProviderKind? providerKind,
    bool? mineruEnabled,
    String? mineruToken,
    bool? analysisGrounding,
    List<String>? knowledgePointTypes,
  }) {
    return AppSettings(
      apiKey: apiKey ?? this.apiKey,
      apiEndpoint: apiEndpoint ?? this.apiEndpoint,
      model: model ?? this.model,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      nickname: nickname ?? this.nickname,
      autoSync: autoSync ?? this.autoSync,
      deviceName: deviceName ?? this.deviceName,
      analysisDetail: analysisDetail ?? this.analysisDetail,
      keywordHighlight: keywordHighlight ?? this.keywordHighlight,
      providerKind: providerKind ?? this.providerKind,
      mineruEnabled: mineruEnabled ?? this.mineruEnabled,
      mineruToken: mineruToken ?? this.mineruToken,
      analysisGrounding: analysisGrounding ?? this.analysisGrounding,
      knowledgePointTypes: knowledgePointTypes ?? this.knowledgePointTypes,
    );
  }
}
