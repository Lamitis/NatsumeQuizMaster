/// 助教形象（v1.35）。
///
/// 素材归属：这些是**官方插件** `natsume.companion` 自带的资产，放在
/// `assets/plugins/official/companion/avatars/`。同目录的 `masters/` 里留着
/// 原始 `.ico` 母版（4 套尺寸、单张 ~420KB）：母版不进 App 包体，只在仓库里
/// 存档，避免为了三张头像平白多背 1.3MB。
///
/// 为什么不直接让 `Image.asset` 读 `.ico`：Flutter 只保证 PNG / JPEG / WebP /
/// GIF 的解码，ICO 在 Android / iOS 上没有解码器，桌面上也依赖 Skia 的
/// 可选解码路径。统一转成 256px PNG，三端观感才一致。
class CompanionAvatarOption {
  const CompanionAvatarOption({
    required this.id,
    required this.label,
    required this.asset,
    this.hint = '',
  });

  /// 存进 settings 的稳定 id（改 id = 老用户选择丢失，勿改）
  final String id;

  /// 设置页显示的名字
  final String label;

  /// Flutter 资产路径（256px PNG）
  final String asset;

  /// 一句话说明长相（设置页里让用户不必逐个点开猜）
  final String hint;

  /// 「跟 App 图标一致」的默认项（v1.32 起的行为）
  static const String defaultId = 'default';
  static const String defaultAsset = 'assets/app_logo.png';

  static const CompanionAvatarOption fallback = CompanionAvatarOption(
    id: defaultId,
    label: 'App 图标',
    asset: defaultAsset,
    hint: '与桌面 / 任务栏图标同一张，最省事',
  );

  /// 可选项顺序即设置页展示顺序：默认项排第一，避免「换回去找不到」
  static const List<CompanionAvatarOption> all = [
    fallback,
    CompanionAvatarOption(
      id: 'rainbow',
      label: '彩虹发',
      asset: 'assets/plugins/official/companion/avatars/rainbow.png',
      hint: '彩发 + 水手帽，配色最跳',
    ),
    CompanionAvatarOption(
      id: 'navy',
      label: '蓝发',
      asset: 'assets/plugins/official/companion/avatars/navy.png',
      hint: '蓝发 + 航海帽，冷色系',
    ),
    CompanionAvatarOption(
      id: 'amber',
      label: '橙发',
      asset: 'assets/plugins/official/companion/avatars/amber.png',
      hint: '橙发 + 花饰，暖色系',
    ),
  ];

  /// 按 id 取选项；未知 id（手改 JSON / 老版本被删的选项）回落默认项，
  /// 绝不让「头像读不出来」把整个浮层打成空白。
  static CompanionAvatarOption byId(String? id) {
    if (id == null || id.isEmpty) return fallback;
    for (final o in all) {
      if (o.id == id) return o;
    }
    return fallback;
  }

  /// id 是否合法（落盘前校验用）
  static bool isValidId(String? id) => id != null && all.any((o) => o.id == id);
}
