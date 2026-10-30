// Natsume - 修补 pub 缓存里 pdfrx 1.3.5 的空安全编译错误（幂等，可重复执行）
//
// 为什么需要这个脚本：
//   pub.dev 上发布的 pdfrx 1.3.5，其 lib/src/pdfium/pdf_file_cache.dart 里把
//   `pdfDocumentFromUri` 的 cache 参数声明成可空的 `PdfFileCache?`，`cache ??= ...`
//   之后再在**闭包内部**读它时 Dart 不做类型提升（可变参数 + 被闭包捕获 + 中间隔着
//   await），于是漏了两处 `!`：
//     lib/src/pdfium/pdf_file_cache.dart:351  (blockId + 1) * cache.blockSize
//     lib/src/pdfium/pdf_file_cache.dart:353  await cache.read(...)
//   同一个文件里 346 / 366 行上游是补了 `!` 的，这两处一直没补；直到 2.0.0 整体重写
//   才消失，而 2.x 是破坏性 API 变更，不能为了一次发布硬升级。
//
//   后果：任何**干净环境**（新克隆、CI、`flutter pub cache repair` 之后）跑
//   `flutter pub get` 拿到的都是这份原版，编译 pdfrx 时直接失败：
//     Error: Property 'blockSize' cannot be accessed on 'PdfFileCache?'
//            because it is potentially null.
//   而在本地却一直是绿的——因为缓存里那份曾被手工补过 `!`，pub 缓存又不进版本控制，
//   于是「本地全绿 / CI 全红」，且 CI 侧表现为一堆套件 `loading ... [E]`
//   （编译器在编 pdfrx 时先挂掉，后面没编完的套件全部连带失败），极易被误判成
//   测试基础设施问题。这个脚本把那两个字符的补丁固化成一条命令。
//
// 何时需要重跑：首次克隆后、`flutter pub cache repair`、`flutter clean` 后重新
// `flutter pub get`，以及任何会重新解包依赖的操作之后。CI 每次都会跑。
//
// 用法：
//   dart tools/patch_pub_cache.dart                            # 就地修补
//   dart tools/patch_pub_cache.dart --check                    # 只检查，不写文件
//   dart tools/patch_pub_cache.dart --pub-cache "D:\pub_cache"  # 指定缓存根目录
//
// 退出码：
//   0  已就绪（本次修好，或本来就是修好的）
//   1  找不到目标文件 / 待替换文本对不上（多半是 pdfrx 版本变了，需人工核对上游）

import 'dart:io';

/// 本脚本唯一覆盖的版本；`pubspec.yaml` / `pubspec.lock` 里锁的就是它。
const _targetPackage = 'pdfrx';
const _targetVersion = '1.3.5';
const _relativeFile = 'lib/src/pdfium/pdf_file_cache.dart';

/// 上游原版 → 补丁后：只多两个 `!`，语义完全相同（这两个位置 cache 一定非空，
/// 因为进闭包前已经 `cache ??= await PdfFileCache.fromUri(uri)`）。
const _broken = <String>[
  'final readEnd = min(p + size, (blockId + 1) * cache.blockSize);',
  'await cache.read(buffer, bufferPosition, p, sizeToRead);',
];
const _fixed = <String>[
  'final readEnd = min(p + size, (blockId + 1) * cache!.blockSize);',
  'await cache!.read(buffer, bufferPosition, p, sizeToRead);',
];

void main(List<String> args) {
  var checkOnly = false;
  String? cacheRootArg;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--check':
        checkOnly = true;
      case '--pub-cache':
        if (i + 1 >= args.length) {
          stderr.writeln('[错误] --pub-cache 后面要跟目录');
          exit(1);
        }
        cacheRootArg = args[++i];
      case '-h':
      case '--help':
        stdout.writeln(
          '用法: dart tools/patch_pub_cache.dart [--check] [--pub-cache <dir>]\n'
          '见文件头部注释了解为什么需要这个补丁。',
        );
        exit(0);
      default:
        stderr.writeln('[错误] 未知参数：${args[i]}（用 --help 看用法）');
        exit(1);
    }
  }

  final repoRoot = File.fromUri(Platform.script).parent.parent;
  _verifyLockedVersion(repoRoot);

  final cacheRoot = cacheRootArg ?? _defaultPubCacheRoot();
  final hosted = Directory('$cacheRoot${Platform.pathSeparator}hosted');
  if (!hosted.existsSync()) {
    _fail('找不到 pub 缓存目录：${hosted.path}（先跑 flutter pub get，或用 --pub-cache 指定）');
  }

  // 缓存里可能有多个 package host（pub.dev / 镜像站），逐个查。
  final targets = <File>[];
  for (final host in hosted.listSync().whereType<Directory>()) {
    final file = File(
      [
        host.path,
        '$_targetPackage-$_targetVersion',
        ..._relativeFile.split('/'),
      ].join(Platform.pathSeparator),
    );
    if (file.existsSync()) targets.add(file);
  }
  if (targets.isEmpty) {
    _fail('pub 缓存里没有 $_targetPackage-$_targetVersion（先跑 flutter pub get）\n'
        '已查找：${hosted.path}');
  }

  var needsPatch = false;
  final mismatched = <String>[];
  for (final file in targets) {
    final text = file.readAsStringSync();
    final missing = <int>[
      for (var i = 0; i < _broken.length; i++)
        if (!text.contains(_fixed[i])) i,
    ];
    if (missing.isEmpty) {
      stdout.writeln('[已就绪] ${file.path}');
      continue;
    }

    // 一半已替换、一半找不到原文：说明文件被改成本脚本不认识的样子，
    // 宁可报错也别乱写。
    final unmatched = [for (final i in missing) if (!text.contains(_broken[i])) i];
    if (unmatched.isNotEmpty) {
      mismatched.add(file.path);
      stderr.writeln('[未匹配] ${file.path}');
      for (final i in unmatched) {
        stderr.writeln('  期望找到：${_broken[i]}');
      }
      continue;
    }

    needsPatch = true;
    if (checkOnly) {
      stdout.writeln('[需修补] ${file.path}');
      continue;
    }

    var patched = text;
    for (final i in missing) {
      patched = patched.replaceFirst(_broken[i], _fixed[i]);
    }
    file.writeAsStringSync(patched);

    // 写完立刻回读校验，避免「以为改了其实没落地」。
    final after = file.readAsStringSync();
    if (_broken.asMap().keys.any((i) => !after.contains(_fixed[i]))) {
      _fail('写入后校验失败：${file.path}');
    }
    stdout.writeln('[已修补] ${file.path}');
  }

  if (mismatched.isNotEmpty) {
    _fail('${mismatched.length} 个文件的内容与预期对不上，'
        '多半是 $_targetPackage 版本变了：请先核对上游是否已修好，'
        '再决定是否删掉本脚本。');
  }

  if (checkOnly && needsPatch) {
    stderr.writeln('[失败] 还有文件没打补丁（去掉 --check 再跑一次即可）');
    exit(1);
  }

  stdout.writeln(checkOnly ? 'OK: 补丁已就绪' : 'OK: 补丁已就绪（可重复执行）');
  exit(0);
}

/// pub 缓存根目录：PUB_CACHE 优先，其次各平台默认位置。
String _defaultPubCacheRoot() {
  final fromEnv = Platform.environment['PUB_CACHE'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return '$localAppData\\Pub\\Cache';
    }
    return '${Platform.environment['USERPROFILE']}\\AppData\\Local\\Pub\\Cache';
  }
  final home = Platform.environment['HOME'] ?? '.';
  return '$home/.pub-cache';
}

/// 版本对不上就直接停：不同版本的源码布局可能变了，硬套会写出半截补丁。
void _verifyLockedVersion(Directory repoRoot) {
  final lock = File('${repoRoot.path}${Platform.pathSeparator}pubspec.lock');
  if (!lock.existsSync()) return;
  final lines = lock.readAsLinesSync();
  final start = lines.indexWhere(
    (l) => RegExp(r'^\s{2}' + _targetPackage + r':\s*$').hasMatch(l),
  );
  if (start < 0) return;
  for (var i = start + 1; i < lines.length && i < start + 12; i++) {
    final line = lines[i];
    if (RegExp(r'^\s{2}\S').hasMatch(line)) break; // 到下一个包了，收工
    final m = RegExp(r'^\s+version:\s*"?([^"\s]+)"?\s*$').firstMatch(line);
    if (m == null) continue;
    final locked = m.group(1)!;
    if (locked != _targetVersion) {
      _fail('pubspec.lock 里 $_targetPackage 是 $locked，本脚本只覆盖 $_targetVersion。\n'
          '请先核对新版本是否已修好空安全问题，再更新本脚本。');
    }
    return;
  }
}

Never _fail(String message) {
  stderr.writeln('[失败] $message');
  exit(1);
}
