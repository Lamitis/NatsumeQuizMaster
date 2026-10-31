import '../services/key_crypto.dart';
import 'app_settings.dart';
import 'companion_avatar.dart';

/// 陪伴插件的人格语气（v1.33 可配置人设）。
///
/// 为什么是枚举而不是纯自由文本：语气要能**落到提示词**上做确定性断言
/// （测试直接比字符串），同时保证「严格」也不会越过安全边界——四条语气
/// 都只描述表达方式，不放开数据真实性与医疗建议两条硬约束。
enum CompanionTone {
  /// 温柔（默认）：先接住情绪
  gentle,

  /// 元气：学姐式带节奏
  energetic,

  /// 教练：冷静给下一步
  coach,

  /// 严格：直接指出问题
  strict;

  String get label => switch (this) {
        CompanionTone.gentle => '温柔',
        CompanionTone.energetic => '元气',
        CompanionTone.coach => '教练',
        CompanionTone.strict => '严格',
      };

  /// 设置页里的一句话说明（用户不必猜「教练」是什么味道）
  String get hint => switch (this) {
        CompanionTone.gentle => '先接住情绪再给建议，像陪着你自习的同桌',
        CompanionTone.energetic => '短句、有精神，像学姐把节奏带起来',
        CompanionTone.coach => '冷静、有条理，先判断再给下一步',
        CompanionTone.strict => '有话直说、有要求，但不对人做评价',
      };

  /// 注入系统提示词的语气条款
  String get promptClause => switch (this) {
        CompanionTone.gentle =>
          '语气：温和、耐心，先接住对方的情绪再给建议；可以有一点点撒娇，但不油腔滑调、不堆感叹号。',
        CompanionTone.energetic =>
          '语气：活泼、有精神，多用短句；像学姐一样把节奏带起来，但不催促、不指责。',
        CompanionTone.coach =>
          '语气：冷静、条理清楚，像学习教练；先给判断，再给一条可执行的下一步。',
        CompanionTone.strict =>
          '语气：直接、克制、有要求；指出问题不绕弯子，但只评价行为不评价人，'
              '不使用羞辱、贬低或激将式表达。',
      };
}

/// AI 接口来源：跟随软件设置 / 独立配置。
///
/// 默认 [followApp]：装好 App 的人不用再填第二遍 Key（也可选独立填写模型与
/// API），插件也不会偷偷多烧一份额度。
enum CompanionApiMode {
  /// 跟随「设置 → AI 接口」，与解析/追问共用同一份配置
  followApp,

  /// 独立配置：陪伴对话走自己的地址 / 模型 / Key（例如便宜的小模型）
  custom;

  String get label => switch (this) {
        CompanionApiMode.followApp => '跟随软件',
        CompanionApiMode.custom => '独立配置',
      };
}

/// 陪伴插件设置（v1.33）。
///
/// 存放方式与 v1.32 的 [CompanionState] 一致：settings 表一行 JSON
/// （`companion_settings_v1`），**不涨 schema**。API Key 在 JSON 里用
/// `KeyCrypto` 加密（字段 `api_key_enc`），与 `AppSettings.toMap` 同口径：
/// 备份文件里也不应该出现明文 Key。
class CompanionSettings {
  const CompanionSettings({
    this.overlayEnabled = true,
    this.bubbleMinutes = 10,
    this.avatar = CompanionAvatarOption.defaultId,
    this.tone = CompanionTone.gentle,
    this.botName = defaultBotName,
    this.customPersona = '',
    this.memoryEnabled = true,
    this.apiMode = CompanionApiMode.followApp,
    this.providerKind = AiProviderKind.openaiCompat,
    this.endpoint = '',
    this.model = '',
    this.apiKey = '',
    this.kbEnabled = true,
    this.kbId,
    this.overlayX,
    this.overlayY,
    this.hiddenDay,
  });

  /// 默认角色名（v1.32 的固定人设名，改名字后界面全部跟着变）
  static const String defaultBotName = '小鲸';

  /// 气泡频率选项（分钟，0 = 关闭）。20/30 分钟是「别太吵」的那档。
  static const List<int> bubbleMinuteOptions = [0, 10, 20, 30];

  /// 自定义人设文本上限（防止有人把整本教材贴进提示词）
  static const int maxPersonaChars = 1200;

  /// 角色名上限
  static const int maxNameChars = 12;

  /// 是否显示应用内悬浮头像
  final bool overlayEnabled;

  /// 气泡提醒间隔（分钟）；0 = 不再主动冒泡，只能点开头像对话
  final int bubbleMinutes;

  /// 助教形象 id（见 [CompanionAvatarOption]；默认 = 跟 App 图标一致）
  final String avatar;

  /// 人格语气
  final CompanionTone tone;

  /// 角色名（默认「小鲸」）
  final String botName;

  /// 用户自定义人设补充（追加进系统提示词）
  final String customPersona;

  /// 是否记住之前的对话（关掉后每次都从开场白开始）
  final bool memoryEnabled;

  /// 接口来源
  final CompanionApiMode apiMode;

  /// 独立配置时的提供方
  final AiProviderKind providerKind;

  /// 独立配置时的接口地址（空 = 用默认地址）
  final String endpoint;

  /// 独立配置时的模型名（空 = 用默认模型）
  final String model;

  /// 独立配置时的 API Key（明文仅存在于内存，落盘加密）
  final String apiKey;

  /// 是否允许回答时引用知识库
  final bool kbEnabled;

  /// 引用哪个知识库；null = 全部
  final int? kbId;

  /// 悬浮头像的位置（屏幕宽/高的比例 0..1）；null = 默认右下角
  final double? overlayX;
  final double? overlayY;

  /// 「今天别出现」的日期键（yyyy-MM-dd）；当天的气泡与头像都不显示
  final String? hiddenDay;

  static const CompanionSettings defaults = CompanionSettings();

  /// 独立配置且真的填了 Key 才算「自带接口」
  bool get hasOwnApi =>
      apiMode == CompanionApiMode.custom && apiKey.trim().isNotEmpty;

  /// 今天是否被用户「请走」了
  bool hiddenOn(String day) => hiddenDay != null && hiddenDay == day;

  /// 当天是不是该冒泡
  bool get bubblesEnabled => bubbleMinutes > 0;

  /// 界面显示用的角色名（空名字回落默认，避免出现「」）
  String get displayName {
    final raw = botName.trim();
    if (raw.isEmpty) return defaultBotName;
    return raw.length > maxNameChars ? raw.substring(0, maxNameChars) : raw;
  }

  /// 当前形象选项（未知 id 已由 [CompanionAvatarOption.byId] 兜底）
  CompanionAvatarOption get avatarOption => CompanionAvatarOption.byId(avatar);

  /// 当前形象资产路径（浮层、对话页、气泡共用同一张）
  String get avatarAsset => avatarOption.asset;

  /// 把「陪伴用的接口配置」套到 App 设置上。
  ///
  /// 关键点：以用户的 App 设置为底做 copyWith，而不是从零新建 AppSettings——
  /// 解析详细度、关键词高亮、MinerU 等字段必须保持原值，否则为了聊天
  /// 顺手把全局设置冲回默认值。
  AppSettings resolve(AppSettings app) {
    if (!hasOwnApi) return app;
    return app.copyWith(
      apiKey: apiKey.trim(),
      apiEndpoint: endpoint.trim().isEmpty
          ? AppSettings.defaultApiEndpoint
          : endpoint.trim(),
      model: model.trim().isEmpty ? AppSettings.defaultModel : model.trim(),
      providerKind: providerKind,
    );
  }

  CompanionSettings copyWith({
    bool? overlayEnabled,
    int? bubbleMinutes,
    String? avatar,
    CompanionTone? tone,
    String? botName,
    String? customPersona,
    bool? memoryEnabled,
    CompanionApiMode? apiMode,
    AiProviderKind? providerKind,
    String? endpoint,
    String? model,
    String? apiKey,
    bool? kbEnabled,
    int? Function()? kbId,
    double? Function()? overlayX,
    double? Function()? overlayY,
    String? Function()? hiddenDay,
  }) {
    return CompanionSettings(
      overlayEnabled: overlayEnabled ?? this.overlayEnabled,
      bubbleMinutes: bubbleMinutes ?? this.bubbleMinutes,
      avatar: avatar ?? this.avatar,
      tone: tone ?? this.tone,
      botName: botName ?? this.botName,
      customPersona: customPersona ?? this.customPersona,
      memoryEnabled: memoryEnabled ?? this.memoryEnabled,
      apiMode: apiMode ?? this.apiMode,
      providerKind: providerKind ?? this.providerKind,
      endpoint: endpoint ?? this.endpoint,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      kbEnabled: kbEnabled ?? this.kbEnabled,
      // 可空字段用「取值函数」而不是裸值：裸 null 分不清「不改」和「清空」
      kbId: kbId == null ? this.kbId : kbId(),
      overlayX: overlayX == null ? this.overlayX : overlayX(),
      overlayY: overlayY == null ? this.overlayY : overlayY(),
      hiddenDay: hiddenDay == null ? this.hiddenDay : hiddenDay(),
    );
  }

  /// 落盘 JSON：API Key 加密，其余按语义存
  Map<String, dynamic> toJson() {
    final key = apiKey.trim();
    return {
      'overlay': overlayEnabled,
      'bubble_minutes': bubbleMinutes,
      'avatar': avatarOption.id,
      'tone': tone.name,
      'bot_name': displayName,
      'custom_persona': customPersona,
      'memory': memoryEnabled,
      'api_mode': apiMode.name,
      'provider': providerKind.name,
      'endpoint': endpoint,
      'model': model,
      'api_key_enc': KeyCrypto.encrypt(key),
      'kb': kbEnabled,
      if (kbId != null) 'kb_id': kbId,
      if (overlayX != null) 'overlay_x': overlayX,
      if (overlayY != null) 'overlay_y': overlayY,
      if (hiddenDay != null) 'hidden_day': hiddenDay,
    };
  }

  /// 容错解析：任何脏字段都回落默认值，绝不让设置把陪伴功能打不开
  factory CompanionSettings.fromJson(Map<String, dynamic> json) {
    T pick<T extends Enum>(List<T> values, Object? raw, T fallback) {
      final name = raw?.toString() ?? '';
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    bool flag(Object? raw, bool fallback) {
      if (raw is bool) return raw;
      if (raw == null) return fallback;
      final s = raw.toString().toLowerCase();
      if (s == '1' || s == 'true') return true;
      if (s == '0' || s == 'false') return false;
      return fallback;
    }

    int asInt(Object? raw, int fallback) {
      if (raw is int) return raw;
      if (raw is num) return raw.round();
      return int.tryParse('${raw ?? ''}') ?? fallback;
    }

    double? asFraction(Object? raw) {
      if (raw == null) return null;
      final v = raw is num ? raw.toDouble() : double.tryParse('$raw');
      if (v == null || v.isNaN || v.isInfinite) return null;
      return v.clamp(0.0, 1.0).toDouble();
    }

    String str(Object? raw) => raw?.toString() ?? '';

    final minutes = asInt(json['bubble_minutes'], 10);
    final persona = str(json['custom_persona']);
    final name = str(json['bot_name']).trim();
    final day = str(json['hidden_day']).trim();
    final kbId = json['kb_id'] == null ? null : asInt(json['kb_id'], 0);

    return CompanionSettings(
      overlayEnabled: flag(json['overlay'], true),
      // 频率只允许白名单值：手改 JSON 写个 0.5 分钟会把气泡刷成弹幕
      bubbleMinutes: bubbleMinuteOptions.contains(minutes) ? minutes : 10,
      // 形象同样只认白名单：被删掉的选项静默回落默认项，不挡住整页设置
      avatar: CompanionAvatarOption.isValidId(str(json['avatar']))
          ? str(json['avatar'])
          : CompanionAvatarOption.defaultId,
      tone: pick(CompanionTone.values, json['tone'], CompanionTone.gentle),
      botName: name.isEmpty
          ? defaultBotName
          : (name.length > maxNameChars
              ? name.substring(0, maxNameChars)
              : name),
      customPersona: persona.length > maxPersonaChars
          ? persona.substring(0, maxPersonaChars)
          : persona,
      memoryEnabled: flag(json['memory'], true),
      apiMode: pick(
          CompanionApiMode.values, json['api_mode'], CompanionApiMode.followApp),
      providerKind: pick(
          AiProviderKind.values, json['provider'], AiProviderKind.openaiCompat),
      endpoint: str(json['endpoint']).trim(),
      model: str(json['model']).trim(),
      apiKey: KeyCrypto.decrypt(str(json['api_key_enc'])),
      kbEnabled: flag(json['kb'], true),
      kbId: (kbId == null || kbId <= 0) ? null : kbId,
      overlayX: asFraction(json['overlay_x']),
      overlayY: asFraction(json['overlay_y']),
      hiddenDay: day.isEmpty ? null : day,
    );
  }
}
