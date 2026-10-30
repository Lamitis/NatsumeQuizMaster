import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// 导出文件落在哪里。
///
/// 为什么要专门挑目录：错题导出是给用户**拿出去用**的（打印纸质题、发同学、
/// 存档），所以要放在用户自己能翻到的位置，而不是应用私有缓存——
/// Android 的 `Directory.systemTemp` 是 `/data/user/0/<包名>/cache`，
/// 普通文件管理器根本进不去，导完就找不着了。
///
///   · Android：应用外部私有目录 `<外部存储>/Android/data/<包名>/files/NatsumeQuizMaster导出`
///     （不需要任何存储权限；Android 10 的文件管理器可直接进入，11+ 部分机型
///     需要在文件管理器里开启「显示系统/Android 目录」，也能通过数据线在电脑上看到）
///   · Windows/macOS/Linux：`<文档目录>/NatsumeQuizMaster导出`（资源管理器里直接可见）
///   · 插件不可用 / 取不到（单元测试、无外部存储）：回落到系统临时目录
class ExportStorage {
  ExportStorage._();

  /// 单元测试注入：给定则直接用它作为导出目录。
  /// 与 `DatabaseService.overrideDbPath` 同一套路，避免测试依赖 path_provider 插件。
  static String? overrideDirForTest;

  /// 导出目录名（用户可见，给个能认出来的名字）
  static const folderName = 'NatsumeQuizMaster导出';

  /// 取（必要时创建）导出目录
  static Future<Directory> resolve() async {
    final override = overrideDirForTest;
    if (override != null) return _ensure(Directory(override));
    try {
      final base = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getApplicationDocumentsDirectory();
      if (base != null) {
        return _ensure(Directory('${base.path}${Platform.pathSeparator}$folderName'));
      }
    } catch (_) {
      // path_provider 在单元测试里没有平台实现；真实设备上也可能取不到
      // （例如外部存储被卸载），这时候不能让导出整个失败。
    }
    return Directory.systemTemp;
  }

  static Directory _ensure(Directory dir) {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 从导出的文件路径里取出「所在文件夹」，用于导出后展示给用户。
  ///
  /// 直接按最后一个分隔符截断，**不重新拼接**：路径里可能是 `/` 也可能是 `\`
  /// （取决于平台与拼接处），重组会把另一种分隔符改掉，展示出来就不是真实路径了。
  static String folderOf(String filePath) {
    final i = filePath.lastIndexOf(RegExp(r'[\\/]'));
    if (i < 0) return filePath; // 只有文件名，没有目录
    if (i == 0) return filePath.substring(0, 1); // 根目录下的文件
    return filePath.substring(0, i);
  }

  /// 从导出的文件路径里取出文件名
  static String fileNameOf(String filePath) =>
      filePath.split(RegExp(r'[\\/]')).last;

  /// 单元测试注入：替代系统「另存为」对话框。
  /// 返回目标路径 ⇒ 视为用户选了位置；返回 null ⇒ 视为用户取消。
  static Future<String?> Function(String fileName, Uint8List bytes)?
      overrideSavePickerForTest;

  /// 「另存为」：把导出的字节写到用户自己选的位置（v1.34 起取代系统分享面板）。
  ///
  /// 为什么不再用分享面板：分享面板要用户再选一次「保存到文件」，多一步，
  /// 而且 Android 11+ 上部分文件管理器/网盘接管后拿到的是一份副本而不是那个
  /// 文件本身；用户要的是「我自己挑个文件夹存下来」。
  ///
  /// 平台差异（file_picker 6.x 的真实能力，别想当然）：
  ///   · Windows/macOS/Linux：`saveFile()` 有原生另存为对话框，**只返回路径**，
  ///     文件由本方法自己写（6.x 的 saveFile 没有 bytes 参数）。
  ///   · Android/iOS：`saveFile()` 未实现（会抛 `UnimplementedError`），
  ///     退回「选一个文件夹」（`getDirectoryPath()`，SAF 目录选择器）+ 写入。
  ///   · 都不可用（测试环境 / 插件缺失）：落 [resolve] 的导出目录，保证导出
  ///     不会因为「弹不出对话框」而整个失败。
  static Future<ExportSaveResult> saveAsBytes(
    Uint8List bytes, {
    required String fileName,
    String? dialogTitle,
  }) async {
    final hook = overrideSavePickerForTest;
    if (hook != null) {
      final picked = await hook(fileName, bytes);
      if (picked == null) return const ExportSaveResult(path: null);
      await File(picked).writeAsBytes(bytes, flush: true);
      return ExportSaveResult(path: picked);
    }

    final extensions = _extensionsOf(fileName);

    // ① 桌面端原生「另存为」
    try {
      final picked = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle ?? '保存导出文件',
        fileName: fileName,
        type: extensions.isEmpty ? FileType.any : FileType.custom,
        allowedExtensions: extensions.isEmpty ? null : extensions,
        lockParentWindow: true,
      );
      if (picked == null) return const ExportSaveResult(path: null);
      // 部分对话框不带扩展名返回（用户手输文件名），补回真实后缀
      final target = _ensureExtension(picked, fileName);
      await File(target).writeAsBytes(bytes, flush: true);
      return ExportSaveResult(path: target);
    } on UnimplementedError {
      // Android/iOS：saveFile 没有实现，走下面的目录选择
    } catch (_) {
      // 对话框实例化失败（极少数 Windows 环境）同样退化到目录选择
    }

    // ② 选文件夹 + 写入（Android SAF 目录选择器）
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: dialogTitle ?? '选择保存位置',
      );
      if (dirPath == null) return const ExportSaveResult(path: null); // 用户取消
      if (dirPath.isNotEmpty) {
        final target = '$dirPath${Platform.pathSeparator}$fileName';
        await File(target).writeAsBytes(bytes, flush: true);
        return ExportSaveResult(path: target);
      }
    } on UnimplementedError {
      // 目录选择也没实现：继续兜底
    } catch (_) {}

    // ③ 兜底：直接写进导出目录（用户仍能在文件管理器里找到）
    final dir = await resolve();
    final target = '${dir.path}${Platform.pathSeparator}$fileName';
    await File(target).writeAsBytes(bytes, flush: true);
    return ExportSaveResult(path: target, pickedByUser: false);
  }

  /// 「另存为」一个已经生成好的导出文件（各导出流程的主入口）。
  ///
  /// 源文件通常是导出服务写在 [resolve] 目录里的工作文件；另存后它没有被删掉
  /// ——用户取消对话框时还能从那个目录里找到，删了反而丢数据。
  static Future<ExportSaveResult> saveFileAs(
    String sourcePath, {
    String? dialogTitle,
    String? fileName,
  }) async {
    final file = File(sourcePath);
    if (!file.existsSync()) return const ExportSaveResult(path: null);
    final bytes = await file.readAsBytes();
    return saveAsBytes(
      bytes,
      fileName: fileName ?? fileNameOf(sourcePath),
      dialogTitle: dialogTitle,
    );
  }

  /// 用户没改扩展名就按源文件名补上（Windows 对话框的过滤器不强制后缀）
  static String _ensureExtension(String path, String sourceName) {
    final dot = sourceName.lastIndexOf('.');
    if (dot < 0 || dot == sourceName.length - 1) return path;
    final ext = sourceName.substring(dot + 1).toLowerCase();
    if (path.toLowerCase().endsWith('.$ext')) return path;
    return '$path.$ext';
  }

  /// 文件名里的扩展名（供对话框过滤器用；没有扩展名返回空列表）
  static List<String> _extensionsOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return const [];
    return [fileName.substring(dot + 1).toLowerCase()];
  }
}

/// 另存为的结果。
///
/// [path] 为 null ⇒ 用户取消了对话框（调用方**不要**弹成功提示）；
/// [pickedByUser] 为 false ⇒ 没能弹对话框，落到了默认导出目录（提示里要
/// 说明实际路径，否则用户以为文件在别处）。
class ExportSaveResult {
  final String? path;
  final bool pickedByUser;

  const ExportSaveResult({required this.path, this.pickedByUser = true});

  /// 是否真的写出了文件
  bool get saved => path != null;
}
