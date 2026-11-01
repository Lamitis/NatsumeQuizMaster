import '../services/plugins/plugin_registry.dart';
import '../services/plugins/plugin_stats_service.dart';

/// 插件市场排序方式（v1.36）。
///
/// 「最新更新 / 下载最多」依赖 GitHub 统计（[PluginStats]），统计没拉到时**不隐藏
/// 插件**，只是把这些条目排到后面——拿不到数字不该等于「不存在」。
enum PluginSortMode {
  /// 按登记表顺序（作者提交的顺序，最稳）
  registry('登记表顺序'),

  /// 最近发布在前（`published_at`；没有正式发布时用预发布的时间）
  latest('最新更新'),

  /// 下载量降序（口径见 [PluginStats.fromReleases]）
  downloads('下载最多');

  const PluginSortMode(this.label);

  /// 下拉菜单里显示的中文名
  final String label;

  /// 从持久化值还原；认不出就退回默认（[latest]），不抛异常
  static PluginSortMode parse(String? raw) =>
      PluginSortMode.values.where((m) => m.name == raw).firstOrNull ??
      PluginSortMode.latest;
}

/// 按 [mode] 返回**新**列表（不改动入参，调用方可以放心把它放在 `build` 里）。
List<RegistryPlugin> sortRegistryPlugins(
  List<RegistryPlugin> entries,
  PluginSortMode mode,
  Map<String, PluginStats> stats,
) {
  final list = List<RegistryPlugin>.of(entries);
  switch (mode) {
    case PluginSortMode.registry:
      break;
    case PluginSortMode.latest:
      list.sort((a, b) {
        final c = _newerFirst(
          stats[a.id]?.latestReleaseAt,
          stats[b.id]?.latestReleaseAt,
        );
        return c != 0 ? c : _nameAsc(a, b);
      });
    case PluginSortMode.downloads:
      list.sort((a, b) {
        final c = (stats[b.id]?.downloadCount ?? -1)
            .compareTo(stats[a.id]?.downloadCount ?? -1);
        return c != 0 ? c : _nameAsc(a, b);
      });
  }
  return list;
}

/// 新的在前；时间未知的排到最后（未知不该顶到「最新」第一行）
int _newerFirst(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

/// 名称升序，大小写不敏感（中文按码位，不做拼音——与题库列表保持一致）
int _nameAsc(RegistryPlugin a, RegistryPlugin b) =>
    a.name.toLowerCase().compareTo(b.name.toLowerCase());
