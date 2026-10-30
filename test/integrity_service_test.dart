import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/services/integrity_service.dart';

/// 个人防伪校验（IntegrityService.classify）——纯函数，可单测。
///
/// 关键语义：检测不到签名或未配置期望签名时一律「unknown」（不误锁），
/// 只有「配置了期望值且不匹配」才是 tampered。这保证换包名重打包不会闪退。
void main() {
  group('防伪校验（IntegrityService.classify）', () {
    const expected = 'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234';

    test('签名匹配 → genuine', () {
      expect(IntegrityService.classify(expected, expected),
          IntegrityStatus.genuine);
    });

    test('签名不匹配 → tampered', () {
      expect(IntegrityService.classify('deadbeef', expected),
          IntegrityStatus.tampered);
    });

    test('检测不到签名 → unknown（不误锁）', () {
      expect(IntegrityService.classify(null, expected), IntegrityStatus.unknown);
      expect(IntegrityService.classify('', expected), IntegrityStatus.unknown);
    });

    test('未配置期望签名（全零/空）→ unknown（不误锁）', () {
      expect(IntegrityService.classify(expected, '00000000'),
          IntegrityStatus.unknown);
      expect(IntegrityService.classify(expected, ''), IntegrityStatus.unknown);
    });

    test('大小写不敏感', () {
      expect(IntegrityService.classify(expected.toUpperCase(), expected),
          IntegrityStatus.genuine);
    });
  });
}
