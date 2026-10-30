import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:natsume_quiz_master/models/companion_avatar.dart';
import 'package:natsume_quiz_master/models/companion_settings.dart';

/// 助教形象（v1.35）：官方插件资产目录 + 设置落盘 + 脏数据回落。
///
/// 用户原话：「可替换 AI 助教角色头像的设置没有在 AI 设置里看见，
/// 那几张 ico 图片应该放在官方插件文件夹里」——所以这里连**文件位置**一起断言：
/// 素材在 `assets/plugins/official/companion/avatars/`（进包体的 PNG），
/// 原始 `.ico` 母版在 `masters/`（只存档，不注册进 pubspec）。
void main() {
  group('形象选项', () {
    test('默认项排第一，id 唯一，资产路径都在官方插件目录', () {
      expect(CompanionAvatarOption.all.length, 4);
      expect(
          CompanionAvatarOption.all.first.id, CompanionAvatarOption.defaultId);
      final ids = CompanionAvatarOption.all.map((o) => o.id).toSet();
      expect(ids.length, CompanionAvatarOption.all.length);
      for (final o in CompanionAvatarOption.all.skip(1)) {
        expect(
            o.asset, startsWith('assets/plugins/official/companion/avatars/'));
        expect(o.label, isNotEmpty);
      }
    });

    test('未知 / 空 id 回落默认项（不把浮层打成空白）', () {
      for (final raw in [null, '', 'deleted-avatar', '彩虹']) {
        expect(CompanionAvatarOption.byId(raw).id,
            CompanionAvatarOption.defaultId);
        expect(CompanionAvatarOption.isValidId(raw), isFalse);
      }
      expect(CompanionAvatarOption.isValidId('navy'), isTrue);
    });
  });

  group('设置落盘', () {
    test('avatar 往返保留；未知 id 读回时回落默认', () {
      const settings = CompanionSettings(avatar: 'navy', botName: '小鲸');
      final json = settings.toJson();
      expect(json['avatar'], 'navy');
      expect(CompanionSettings.fromJson(json).avatar, 'navy');
      expect(CompanionSettings.fromJson(json).avatarAsset,
          CompanionAvatarOption.byId('navy').asset);

      final dirty = Map<String, dynamic>.from(json)..['avatar'] = 'gone';
      expect(CompanionSettings.fromJson(dirty).avatar,
          CompanionAvatarOption.defaultId);
    });

    test('老备份没有 avatar 字段 → 默认项（App 图标）', () {
      final legacy = CompanionSettings.fromJson({
        'overlay': true,
        'bubble_minutes': 20,
        'tone': 'gentle',
        'bot_name': '小鲸',
      });
      expect(legacy.avatar, CompanionAvatarOption.defaultId);
      expect(legacy.avatarAsset, CompanionAvatarOption.defaultAsset);
      expect(legacy.bubbleMinutes, 20);
    });
  });

  group('素材位置（官方插件文件夹）', () {
    test('三张 PNG 与三份 ico 母版都在 assets/plugins/official/companion', () {
      for (final name in ['rainbow', 'navy', 'amber']) {
        expect(
          File('assets/plugins/official/companion/avatars/$name.png')
              .existsSync(),
          isTrue,
          reason: '$name.png 应随包发布（256px）',
        );
        expect(
          File('assets/plugins/official/companion/masters/$name.ico')
              .existsSync(),
          isTrue,
          reason: '$name.ico 母版留在仓库里',
        );
      }
    });

    test('pubspec 只注册 avatars/，不把 1.3MB 的 ico 母版打进包体', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/plugins/official/companion/avatars/'));
      expect(pubspec.contains('companion/masters'), isFalse);
    });
  });
}
