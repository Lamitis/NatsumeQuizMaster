import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:natsume_quiz_master/widgets/kit/natsume_logo.dart';

void main() {
  testWidgets('NatsumeLogo 使用新的角色图标资源', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: NatsumeLogo(size: 42))),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect((image.image as AssetImage).assetName, 'assets/app_logo.png',
        reason: '应用内标记应与安装包图标使用同一份美术资源');
    expect(tester.getSize(find.byType(NatsumeLogo)), const Size(42, 42));
  });

  testWidgets('NatsumeLogoBadge 尺寸即 box，且不再带底色框', (tester) async {
    for (final box in <double>[34, 42, 104]) {
      await tester.pumpWidget(
        MaterialApp(home: Center(child: NatsumeLogoBadge(box: box))),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(NatsumeLogo)),
          Size.square(box));
      expect(
        find.descendant(
          of: find.byType(NatsumeLogoBadge),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
        reason: '品牌标记不应再有底色方块或描边',
      );
    }
  });

  testWidgets('零尺寸也不会抛异常', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: NatsumeLogo(size: 0))),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
