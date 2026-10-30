import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:natsume_quiz_master/screens/backup_screen.dart';
import 'package:natsume_quiz_master/services/app_state.dart';
import 'package:natsume_quiz_master/services/theme_service.dart';

/// file_picker 13.x 的假文件：`path` 由基类按 [uri] 推导
/// （`file://` 才有本地路径，`content://` 则为 null）。
/// 注意 [Uri.file] 收到**相对路径**时生成的是不带 scheme 的 URI，基类会判定为
/// 「没有本地路径」，所以默认按当前目录补成绝对路径（与真实桌面端一致）。
base class _PickedFile extends PlatformFile {
  _PickedFile({required this.name, Uri? uri})
      : uri = uri ?? Uri.file(File(name).absolute.path);

  @override
  final String name;

  @override
  final Uri uri;

  @override
  XFile get xFile => XFile(path ?? name);

  @override
  int? lengthSync() => 1;

  @override
  Future<int?> length() async => 1;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(0);

  @override
  Stream<Uint8List> readAsByteStream() => const Stream.empty();
}

/// 13.x 起 `FilePicker` 是 `abstract final class` 且方法都是静态的，
/// 只能通过平台实现注入：替换 `FilePickerPlatform.instance`。
/// 注意 `_Picker` 直接继承 `FilePickerPlatform`（构造时带同一 token），
/// 所以 [FilePickerPlatform.instance] 的 verifyToken 能通过，不需要 Mock 混入。
class _Picker extends FilePickerPlatform {
  _Picker(this.files, {this.error});
  final List<PlatformFile> files;
  final Object? error;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (error != null) throw error!;
    return files;
  }
}

void main() {
  late FilePickerPlatform original;

  setUp(() => original = FilePickerPlatform.instance);
  tearDown(() => FilePickerPlatform.instance = original);

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppState()),
          ChangeNotifierProvider(create: (_) => ThemeService()),
        ],
        // 2026-10-08：数据库导入/导出已从开发者选项移入普通设置，
        // 现在是独立页面 BackupScreen（设置 → 同步与提醒 → 数据库备份），
        // 因此这里不再需要开发者密码解锁。
        child: const MaterialApp(home: BackupScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapImport(WidgetTester tester) async {
    await tester.tap(find.text('导入数据库备份'));
    await tester.pump();
  }

  testWidgets('picker exception is visible and does not leave busy guard',
      (tester) async {
    FilePickerPlatform.instance =
        _Picker(const [], error: StateError('picker failed'));
    await pumpScreen(tester);
    await tapImport(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('打开文件选择器失败'), findsOneWidget);
    // A second attempt is allowed after the failure.
    expect(find.text('导入数据库备份'), findsOneWidget);
  });

  testWidgets('picker cancellation is visible', (tester) async {
    FilePickerPlatform.instance = _Picker(const []);
    await pumpScreen(tester);
    await tapImport(tester);
    await tester.pumpAndSettle();
    expect(find.text('已取消选择备份文件'), findsOneWidget);
  });

  testWidgets('picker result without local path is visible', (tester) async {
    // Android 云端 Provider 给的是 content:// ，没有本地路径
    FilePickerPlatform.instance = _Picker([
      _PickedFile(name: 'cloud.db', uri: Uri.parse('content://cloud/cloud.db')),
    ]);
    await pumpScreen(tester);
    await tapImport(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('无法获取文件的本地路径'), findsOneWidget);
  });

  testWidgets('valid path reaches destructive confirmation without importing',
      (tester) async {
    FilePickerPlatform.instance = _Picker([_PickedFile(name: 'backup.db')]);
    await pumpScreen(tester);
    await tapImport(tester);
    await tester.pumpAndSettle();
    expect(find.text('导入数据库备份'), findsNWidgets(2));
    expect(find.textContaining('覆盖当前所有数据'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
    // Leave the destructive confirmation untouched: no database replacement occurs.
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('已取消导入备份'), findsOneWidget);
  });
}
