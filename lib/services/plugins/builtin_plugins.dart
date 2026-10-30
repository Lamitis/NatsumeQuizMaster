import 'dart:convert';

import '../../models/plugin.dart';
import '../database_service.dart';

/// 内置插件声明（v1.31）。
///
/// 插件机制的红线是「声明式包、不执行任意第三方代码」（见 `plugin_loader.dart`），
/// 内置插件同样遵守：清单只声明能力与元信息，真正的实现是 App 内的固定代码。
/// 区别只在于**随 App 一起出厂**，用户不需要装 zip。
class BuiltinPlugin {
  final String id;
  final String name;
  final String version;
  final String? author;
  final String description;

  /// 声明的能力（展示给用户看，界面据此决定入口是否出现）
  final List<String> capabilities;

  /// 插件数据是否参与局域网同步。false ⇒ 界面必须显示「无法同步」
  final bool syncable;

  /// 许可与上游出处（AGPL 合规：注明取形来源）
  final String license;
  final String? upstream;

  const BuiltinPlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.capabilities,
    required this.syncable,
    this.author = 'NatsumeQuizMaster',
    this.license = 'AGPL-3.0',
    this.upstream,
  });

  Map<String, dynamic> get manifestMap => {
        'id': id,
        'name': name,
        'version': version,
        if (author != null) 'author': author,
        'description': description,
        'capabilities': capabilities,
        'license': license,
        'syncable': syncable,
        if (upstream != null) 'upstream': upstream,
      };

  String get manifest => jsonEncode(manifestMap);
}

/// 内置插件注册表 + 引擎登记。
///
/// [ensureRegistered] 在 `AppState.init()` 里调用一次：缺则插入，已存在则
/// 刷新清单（升级后能力/说明能跟上），但**保留用户改过的启停状态与安装时间**。
class BuiltinPlugins {
  const BuiltinPlugins._();

  /// 笔记插件 id（库表主键，勿改：改了会变成"新插件"，用户启停状态丢失）
  static const String notesId = 'natsume.notes';

  /// 笔记插件（Logseq 风格双链笔记）。
  ///
  /// 取形来源：Logseq 的 `[[页面]]` 双链与 Graph 视图；仅复用格式与交互习惯，
  /// 未引入上游代码。Logseq 与本工程同为 AGPL-3.0，署名见 THIRD_PARTY_NOTICES.md。
  static const BuiltinPlugin notes = BuiltinPlugin(
    id: notesId,
    name: '双链笔记',
    version: '1.0.0',
    description: '刷题时随手记：[[双链]]、反向链接、Graph 图谱，按题库分类',
    capabilities: ['notes', 'backlinks', 'graph'],
    // 同步导出清单（sync_repository.dart）不含插件数据 ⇒ 本插件不可同步
    syncable: false,
    upstream: 'Logseq（AGPL-3.0）双链笔记格式与 Graph 交互',
  );

  /// 陪伴插件 id（库表主键，勿改：改了会变成"新插件"，用户启停状态丢失）
  static const String companionId = 'natsume.companion';

  /// 陪伴插件（「小鲸助教」AI bot）。
  ///
  /// 取形来源：Coopanion（`Pal-AI-Lab/Coopanion`，**AGPL-3.0-or-later**）
  /// 的桌宠角色 / 好感度 / 情绪气泡交互，以及它组装所用的 Cortico 框架
  /// （MIT）。本插件只复用**交互结构与状态划分**，代码与界面全部自行编写；
  /// 上游 `web/whale/` 的鲸鱼娘贴图不在 AGPL 授权范围内，因此未使用任何
  /// 上游图像（头像为 `CompanionAvatar` 自绘），详见 THIRD_PARTY_NOTICES.md。
  static const BuiltinPlugin companion = BuiltinPlugin(
    id: companionId,
    name: '小鲸助教',
    version: '1.0.0',
    description: '鲸鱼娘学习陪伴：结合连胜、本周正确率与错题到期给打气和建议（AI 可选）',
    capabilities: ['companion', 'chat', 'encouragement'],
    // 好感度与聊天记录存 settings，同样不在同步导出清单里
    syncable: false,
    upstream: 'Coopanion（AGPL-3.0-or-later）好感度 / 情绪气泡 · Cortico（MIT）框架思路',
  );

  static const List<BuiltinPlugin> all = [notes, companion];


  /// 启动登记（幂等）
  static Future<void> ensureRegistered() async {
    final db = DatabaseService.instance;
    final now = DateTime.now().toIso8601String();
    for (final p in all) {
      final existing = await db.getPlugin(p.id);
      await db.upsertPlugin(PluginInfo(
        id: p.id,
        name: p.name,
        version: p.version,
        author: p.author,
        description: p.description,
        manifest: p.manifest,
        // 用户停用过就继续停用；没有记录时默认启用
        enabled: existing?.enabled ?? true,
        installedAt: existing?.installedAt ?? now,
      ));
    }
  }

  static Future<bool> isEnabled(String id) async {
    final info = await DatabaseService.instance.getPlugin(id);
    return info?.enabled ?? true;
  }

  static Future<void> setEnabled(String id, bool enabled) =>
      DatabaseService.instance.setPluginEnabled(id, enabled);

  /// 清单里的同步声明：只有显式 `"syncable": true` 才算可同步。
  ///
  /// 默认 false 是刻意的保守取值——同步引擎目前不带任何插件数据，
  /// 若把未知插件标成「可同步」，用户换机后会发现笔记/插件状态全没了。
  static bool isSyncable(PluginInfo info) {
    try {
      final m = jsonDecode(info.manifest);
      return m is Map && m['syncable'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 内置插件按 id 查定义（世界总览页用来展示许可 / 上游署名）
  static BuiltinPlugin? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}
