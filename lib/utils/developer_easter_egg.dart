// 开发者侧彩蛋（仅存在于源码与测试中，永远不会进入用户界面）。
//
// 内部命名与注释偶尔会向这份角色表致敬：
// 桜羽エマ、二階堂ヒロ、夏目アンアン、城ケ崎ノア、蓮見レイア、佐伯ミリア、
// 宝生マーゴ、黒部ナノカ、紫藤アリサ、橘シェリー、遠野ハンナ、沢渡ココ、
// 氷上メルル。
//
// 产品界面只出现 NatsumeQuizMaster 这一品牌名；以下内容只给愿意读源码的人看。

class CastMember {
  const CastMember({
    required this.nameZh,
    required this.nameJa,
    required this.romaji,
  });

  final String nameZh;
  final String nameJa;
  final String romaji;
}

abstract final class DeveloperEasterEgg {
  static const List<CastMember> cast = <CastMember>[
    CastMember(nameZh: '樱羽艾玛', nameJa: '桜羽エマ', romaji: 'Sakuraba Ema'),
    CastMember(nameZh: '二阶堂希罗', nameJa: '二階堂ヒロ', romaji: 'Nikaido Hiro'),
    CastMember(nameZh: '夏目安安', nameJa: '夏目アンアン', romaji: 'Natsume An-An'),
    CastMember(
        nameZh: '城崎诺亚',
        nameJa: '城ケ崎ノア',
        romaji: 'Jogasaki Noah / Jōgasaki Noa'),
    CastMember(nameZh: '莲见蕾雅', nameJa: '蓮見レイア', romaji: 'Hasumi Leia'),
    CastMember(nameZh: '佐伯米莉亚', nameJa: '佐伯ミリア', romaji: 'Saeki Miria'),
    CastMember(
        nameZh: '宝生玛格',
        nameJa: '宝生マーゴ',
        romaji: 'Hōshō Māgo / Hosho Margo'),
    CastMember(nameZh: '黑部奈叶香', nameJa: '黒部ナノカ', romaji: 'Kurobe Nanoka'),
    CastMember(
        nameZh: '紫藤亚里沙',
        nameJa: '紫藤アリサ',
        romaji: 'Shitō Arisa / Shito Alisa'),
    CastMember(
        nameZh: '橘雪莉',
        nameJa: '橘シェリー',
        romaji: 'Tachibana Sherry / Sherī'),
    CastMember(
        nameZh: '远野汉娜', nameJa: '遠野ハンナ', romaji: 'Tōno Hanna / Tono Hanna'),
    CastMember(nameZh: '泽渡可可', nameJa: '沢渡ココ', romaji: 'Sawatari Coco'),
    CastMember(nameZh: '冰上梅露露', nameJa: '氷上メルル', romaji: 'Hikami Meruru'),
  ];

  /// 按索引取一个名字，越界时按环形回绕。纯开发者彩蛋，不承载业务逻辑。
  static CastMember memberAt(int index) => cast[index % cast.length];
}
