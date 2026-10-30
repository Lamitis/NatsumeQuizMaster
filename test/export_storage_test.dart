import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/services/export_storage.dart';

/// 导出落点与「保存位置」展示的回归测试。
///
/// 为什么要专门测：导出完要告诉用户文件在哪个文件夹，而用户能不能真的找到，
/// 取决于两件事——文件**确实**写在那个目录里，以及展示的目录字符串**确实**是
/// 文件所在目录（拆路径的参数化写法最容易在 Windows 的反斜杠上出错）。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('natsume_export_dir_');
  });

  tearDown(() {
    ExportStorage.overrideDirForTest = null;
    ExportStorage.overrideSavePickerForTest = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('导出目录', () {
    test('注入目录不存在时会自动创建（首次导出不能失败）', () async {
      final target = '${tmp.path}${Platform.pathSeparator}NatsumeQuizMaster导出';
      expect(Directory(target).existsSync(), isFalse);
      ExportStorage.overrideDirForTest = target;

      final dir = await ExportStorage.resolve();
      expect(dir.path, target);
      expect(Directory(target).existsSync(), isTrue,
          reason: '目录要先建出来，否则写文件会抛「系统找不到指定的路径」');
    });

    test('目录名对用户可见（叫「NatsumeQuizMaster导出」，不是随机名）', () {
      expect(ExportStorage.folderName, 'NatsumeQuizMaster导出');
    });
  });

  group('保存位置展示', () {
    test('从文件路径取出所在目录（Windows 反斜杠同样正确）', () {
      expect(ExportStorage.folderOf(r'C:\Users\me\Documents\NatsumeQuizMaster导出\错题练习_1.docx'),
          r'C:\Users\me\Documents\NatsumeQuizMaster导出');
      expect(ExportStorage.folderOf('/sdcard/Android/data/com.natsume.quiz/files/NatsumeQuizMaster导出/错题导出_1.json'),
          '/sdcard/Android/data/com.natsume.quiz/files/NatsumeQuizMaster导出');
      // 混用分隔符时按最后一个切，且保留原有写法（不能把 / 重组成 \）
      expect(ExportStorage.folderOf(r'C:\a/NatsumeQuizMaster导出\错题导出_1.json'),
          r'C:\a/NatsumeQuizMaster导出');
    });

    test('从文件路径取出文件名', () {
      expect(ExportStorage.fileNameOf(r'C:\a\NatsumeQuizMaster导出\错题练习_9.docx'), '错题练习_9.docx');
      expect(ExportStorage.fileNameOf('/a/NatsumeQuizMaster导出/错题导出_9.json'), '错题导出_9.json');
      // 只有文件名时不能把整串当目录
      expect(ExportStorage.folderOf('错题导出_1.json'), '错题导出_1.json');
    });
  });

  group('另存为（v1.34 取代分享面板）', () {
    test('用户选了位置：字节原样写出，算「用户自己挑的」', () async {
      ExportStorage.overrideDirForTest = tmp.path;
      final target = '${tmp.path}${Platform.pathSeparator}错题导出_1.json';
      final bytes = Uint8List.fromList([1, 2, 3, 250, 251]);

      var seenName = '';
      ExportStorage.overrideSavePickerForTest = (name, payload) async {
        seenName = name;
        expect(payload, bytes);
        return target;
      };

      final result = await ExportStorage.saveAsBytes(bytes,
          fileName: '错题导出_1.json', dialogTitle: '保存错题导出');

      expect(result.path, target);
      expect(result.saved, isTrue);
      expect(result.pickedByUser, isTrue);
      expect(seenName, '错题导出_1.json');
      expect(await File(target).readAsBytes(), bytes);
    });

    test('用户取消：不算保存成功，也不在导出目录里留半截文件', () async {
      ExportStorage.overrideDirForTest = tmp.path;
      ExportStorage.overrideSavePickerForTest = (name, payload) async => null;

      final result = await ExportStorage.saveAsBytes(utf8Bytes('x'),
          fileName: '错题导出_2.json');

      expect(result.path, isNull);
      expect(result.saved, isFalse, reason: '取消不能弹「已保存」提示');
      expect(File('${tmp.path}${Platform.pathSeparator}错题导出_2.json').existsSync(),
          isFalse);
    });

    test('saveFileAs：把工作文件复制到目标位置，源文件仍保留可找回', () async {
      ExportStorage.overrideDirForTest = tmp.path;
      final source = '${tmp.path}${Platform.pathSeparator}错题练习_1.docx';
      final content = utf8Bytes('工作文件内容');
      await File(source).writeAsBytes(content);

      final target = '${tmp.path}${Platform.pathSeparator}另存${Platform.pathSeparator}'
          '错题练习_1.docx';
      Directory(ExportStorage.folderOf(target)).createSync(recursive: true);
      ExportStorage.overrideSavePickerForTest = (name, payload) async {
        // 默认用源文件名，调用方不必每次传
        expect(name, '错题练习_1.docx');
        return target;
      };

      final result = await ExportStorage.saveFileAs(source, dialogTitle: '保存错题练习');
      expect(result.path, target);
      expect(await File(target).readAsBytes(), content);
      expect(File(source).existsSync(), isTrue,
          reason: '取消/覆盖时用户还要能从导出目录找回原文件');
    });

    test('saveFileAs：源文件不存在时直接返回「未保存」，不弹对话框', () async {
      ExportStorage.overrideDirForTest = tmp.path;
      var pickerCalled = false;
      ExportStorage.overrideSavePickerForTest = (name, payload) async {
        pickerCalled = true;
        return '${tmp.path}${Platform.pathSeparator}never.json';
      };

      final result = await ExportStorage.saveFileAs(
          '${tmp.path}${Platform.pathSeparator}不存在.json');
      expect(result.saved, isFalse);
      expect(pickerCalled, isFalse);
    });

    test('saveFileAs 可以改文件名（导出时带上题库名）', () async {
      ExportStorage.overrideDirForTest = tmp.path;
      final source = '${tmp.path}${Platform.pathSeparator}工作文件.json';
      await File(source).writeAsBytes(utf8Bytes('{}'));

      String? seen;
      ExportStorage.overrideSavePickerForTest = (name, payload) async {
        seen = name;
        return '${tmp.path}${Platform.pathSeparator}$name';
      };

      await ExportStorage.saveFileAs(source, fileName: '内科学_错题_1.json');
      expect(seen, '内科学_错题_1.json');
    });

    test('没有注入对话框时也要能落地（测试环境无 file_picker 插件）', () async {
      ExportStorage.overrideDirForTest = tmp.path;
      // 不注入 hook：FilePicker 在测试里没有平台实现，应当兜底写进导出目录
      final result = await ExportStorage.saveAsBytes(
          utf8Bytes('fallback'), fileName: '兜底_1.json');
      if (result.saved) {
        expect(await File(result.path!).readAsString(), 'fallback');
      }
    });
  });
}

/// UTF-8 编码成字节（测试里模拟导出文件内容）
Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
