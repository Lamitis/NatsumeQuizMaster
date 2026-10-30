import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/utils/developer_easter_egg.dart';

/// 开发者侧彩蛋的完整性检查（不涉及任何用户界面）。
void main() {
  test('角色表完整，且中/日/罗马音均非空', () {
    expect(DeveloperEasterEgg.cast, hasLength(13));
    for (final member in DeveloperEasterEgg.cast) {
      expect(member.nameZh.trim(), isNotEmpty);
      expect(member.nameJa.trim(), isNotEmpty);
      expect(member.romaji.trim(), isNotEmpty);
    }
  });

  test('角色名不重复', () {
    final names = DeveloperEasterEgg.cast.map((m) => m.nameJa).toList();
    expect(names.toSet(), hasLength(names.length));
  });

  test('memberAt 对越界索引安全回绕', () {
    expect(DeveloperEasterEgg.memberAt(0), DeveloperEasterEgg.cast.first);
    expect(DeveloperEasterEgg.memberAt(-1), DeveloperEasterEgg.cast.last);
    expect(DeveloperEasterEgg.memberAt(13), DeveloperEasterEgg.cast.first);
  });
}
