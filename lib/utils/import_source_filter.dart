import 'dart:io';

import 'package:path/path.dart' as p;

/// 导入入口的格式过滤与目录展开（系统多选 / 桌面拖拽共用）。
///
/// 只做文件系统层面的筛选：真正解析与入队仍走 `AppState.startBackgroundImport`
/// → `parseForPreview` 那条既有路径，这里只保证交给它的每个路径都是
/// JSON / DOCX / PDF，并且顺序稳定、不重复。
class ImportSourceFilter {
  ImportSourceFilter._();

  /// 入口允许的扩展名（小写、不含点）。顺序即文件选择器里的呈现顺序。
  static const List<String> supportedExtensions = ['docx', 'pdf', 'json'];

  /// 静默忽略的噪声文件前缀：Word 的 `~$` 锁文件、macOS 的 `._` 资源叉文件。
  /// 它们扩展名可能是 .docx，但内容是垃圾，交给解析只会换来一条失败提示。
  static const List<String> _noisePrefixes = [r'~$', '._'];

  static bool isSupported(String path) {
    final ext = p.extension(path);
    if (ext.isEmpty) return false;
    return supportedExtensions.contains(ext.substring(1).toLowerCase());
  }

  static bool isNoise(String path) {
    final name = p.basename(path);
    return _noisePrefixes.any(name.startsWith);
  }

  /// 把 [paths]（文件或文件夹）展开成可导入文件列表。
  ///
  /// 文件夹递归展开（拖入整个题库目录时一份不落）；不支持的格式进
  /// [ImportSourceCollectResult.rejected]，读不了的文件夹进
  /// [ImportSourceCollectResult.skippedDirectories]，由界面给友好提示。
  static Future<ImportSourceCollectResult> collect(
      Iterable<String> paths) async {
    final files = <String>[];
    final rejected = <String>[];
    final skippedDirs = <String>[];
    final seen = <String>{};

    void addFile(String path) {
      if (isNoise(path)) return;
      if (!isSupported(path)) {
        rejected.add(path);
        return;
      }
      // Windows 路径大小写不敏感：同一个文件被选两次（一次夹在大文件夹里、
      // 一次单独拖入）只保留一份
      if (seen.add(path.toLowerCase())) files.add(path);
    }

    for (final path in paths) {
      if (path.isEmpty) continue;
      final type = await FileSystemEntity.type(path, followLinks: true);
      if (type != FileSystemEntityType.directory) {
        // 文件，以及拿不到类型（content:// 之类）的路径：一律交给扩展名判定，
        // 免得非纯文件系统路径在多选入口被误杀
        addFile(path);
        continue;
      }
      try {
        final children = await Directory(path)
            .list(recursive: true, followLinks: false)
            .where((e) => e is File)
            .toList();
        // Directory.list 的返回顺序不保证稳定 → 排序，让「拖同一个文件夹」
        // 每次得到同样的顺序，预览队列的顺序也就可预期
        children.sort((a, b) => a.path.compareTo(b.path));
        for (final child in children) {
          addFile(child.path);
        }
      } on FileSystemException {
        skippedDirs.add(path);
      }
    }

    return ImportSourceCollectResult(
      files: files,
      rejected: rejected,
      skippedDirectories: skippedDirs,
    );
  }
}

/// [ImportSourceFilter.collect] 的结果。
class ImportSourceCollectResult {
  const ImportSourceCollectResult({
    this.files = const [],
    this.rejected = const [],
    this.skippedDirectories = const [],
  });

  /// 可导入文件（已过滤、去重、顺序稳定）
  final List<String> files;

  /// 被跳过的文件（格式不支持）
  final List<String> rejected;

  /// 被跳过的文件夹（无读取权限等）
  final List<String> skippedDirectories;

  bool get isEmpty =>
      files.isEmpty && rejected.isEmpty && skippedDirectories.isEmpty;
}
