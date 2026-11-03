import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/services/import_ocr_policy.dart';
import 'package:natsume_quiz_master/services/mineru_service.dart';
import 'package:natsume_quiz_master/utils/platform_support.dart';

/// MinerU 的移动端硬门禁（v1.41）。
///
/// 设置页/导入页已经隐藏入口，但**服务层必须再挡一次**：备份恢复、旧设置
/// 残值都可能把 `mineru_enabled` 带成 true。门禁必须在任何数据库/网络访问
/// 之前生效，否则「不支持的设备上触发崩溃」还会从别的入口回来。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('natsume_mineru_gate_');
  });

  tearDown(() {
    debugMobileOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('移动端：parseFile 直接返回 null，并给出降级文案', () async {
    final file = File('${tmp.path}/scan.pdf')
      ..writeAsBytesSync(const [0x25, 0x50, 0x44, 0x46]);
    debugMobileOverride = true;

    String? status;
    final result = await MineruService.instance
        .parseFile(file.path, onStatus: (s) => status = s);

    expect(result, isNull);
    expect(status, ImportOcrPolicy.mobileFallback);
  });
}
