import 'dart:async';
import 'dart:io';

import 'package:natsume_quiz_master/services/database_service.dart';

Directory? _dbDir;

/// 全量测试的全局闸门：**每个测试文件一个独立数据库**。
///
/// 不加这一步时，没显式指定 `DatabaseService.overrideDbPath` 的测试文件会全部
/// 落到真实应用库（`%LOCALAPPDATA%/natsume_quiz_master/natsume.db` /
/// `~/.local/share/...`）：`flutter test` 默认并行跑多个文件，多个进程同时读写
/// 同一个 SQLite 文件 → 控制台刷 “database has been locked”，随后整批卡死或
/// 随机失败（CI 上的「Failed to load …」与 +N -M 抖动即此）。
///
/// 这里给每个测试进程分配一个临时库，文件之间彻底隔离；测试自己用
/// `overrideDbPath` 指定路径的（多数数据库用例）不受影响。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _dbDir = Directory.systemTemp.createTempSync('natsume_test_db_');
  DatabaseService.overrideDbPath = '${_dbDir!.path}/natsume.db';

  // 注意：**不能**在 testMain() 返回后清理 overrideDbPath / 删目录。
  // `testExecutable` 只负责「注册用例」，用例体在它返回之后才真正执行；
  // 提前清理会让所有用例又落回真实应用库（并发写同一文件 → 锁死）。
  // 临时目录留给系统清理。
  await testMain();
}
