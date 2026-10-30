// Natsume - 修补 pub 缓存里的第三方源码（幂等，可重复执行）
//
// 为什么需要这个脚本：
//   pub.dev 上的原版依赖，在「干净环境 + 新版工具链」下编不过。本地缓存常被手工
//   补过，于是「本地全绿 / CI 全红」，且 CI 侧表现为编译器先挂、后面没编完的套件
//   全部连带失败（一堆 `loading ... [E]`），极易被误判成测试基础设施问题。
//   这里把补丁固化成一条命令，CI 每次都会跑。
//
// 覆盖的补丁（新增补丁请加进下面的 _targets，并在这里写清原因）：
//
//   ① pdfrx 1.3.5  lib/src/pdfium/pdf_file_cache.dart
//      上游把 cache 参数声明成可空的 `PdfFileCache?`，`cache ??= ...` 之后再在
//      **闭包内部**读它时 Dart 不做类型提升（可变参数 + 被闭包捕获 + 中间隔着
//      await），于是漏了两处 `!`：
//        Error: Property 'blockSize' cannot be accessed on 'PdfFileCache?'
//               because it is potentially null.
//      2.0.0 重写才修，而 2.x 是破坏性 API 变更，不能为了一次发布硬升级。
//      处理：补两个 `!`。
//
//   ② flutter_local_notifications_windows 3.1.1  src/plugin.cpp
//      （flutter_local_notifications 22.3.3 的 Windows 实现，pub 上最新稳定版）
//      它虽然标着 ffiPlugin，但仍会编译一小段 C++（点击通知的激活回调），里面用
//      ATL 的隐式转换：
//        const std::string key = CW2A(item.Key, CP_UTF8);
//      旧 MSVC 的宽松模式能过，但新版 ATL 把 CW2A 的转换运算符改成显式后，
//      `CW2A` → `LPSTR` → `std::string` 属于两次用户自定义转换，直接报：
//        error C2440: 'initializing': cannot convert from 'ATL::CW2A' to
//                      'std::basic_string<...>'
//      这跟 runner 镜像无关：windows-2022（VS 17.14 起）与 windows-latest 一样报，
//      换镜像解决不了；pub 上也没有已修复的稳定版（只有 4.0.0-dev.x）。
//      处理：显式 static_cast<LPCSTR>(...) 后再构造 std::string（语义完全不变）。
//      注意：别用「把 CMake 标准降回 C++17」来绕。这是 ATL 转换运算符的隐式性
//      问题，跟语言标准无关；反而会让该插件的 C++/WinRT 协程（需要 C++20 的
//      <coroutine>）报 C2338 —— 见 windows/CMakeLists.txt 里的说明。
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
//   1  找不到目标文件 / 待替换文本对不上（多半是依赖版本变了，需人工核对上游）

import 'dart:io';

/// 一处补丁：包 + 版本 + 文件 + 若干「原文 → 补丁后」替换对。
///
/// 版本号必须写死、并与 `pubspec.lock` 校验：不同版本的源码布局可能变了，
/// 硬套会写出半截补丁。
class _PatchTarget {
  const _PatchTarget({
    required this.package,
    required this.version,
    required this.relativeFile,
    required this.broken,
    required this.fixed,
  });

  final String package;
  final String version;

  /// 相对包根目录的路径，一律用 `/` 分隔，落到磁盘时再按平台拼。
  final String relativeFile;

  /// 上游原版片段（必须逐字匹配，含缩进）。
  final List<String> broken;

  /// 补丁后片段，与 [broken] 一一对应。
  final List<String> fixed;
}

/// 全部补丁；`pubspec.yaml` / `pubspec.lock` 里锁的就是这些版本。
const _targets = <_PatchTarget>[
  // ① pdfrx 1.3.5：只多两个 `!`，语义完全相同（这两个位置 cache 一定非空，
  //    因为进闭包前已经 `cache ??= await PdfFileCache.fromUri(uri)`）。
  _PatchTarget(
    package: 'pdfrx',
    version: '1.3.5',
    relativeFile: 'lib/src/pdfium/pdf_file_cache.dart',
    broken: [
      'final readEnd = min(p + size, (blockId + 1) * cache.blockSize);',
      'await cache.read(buffer, bufferPosition, p, sizeToRead);',
    ],
    fixed: [
      'final readEnd = min(p + size, (blockId + 1) * cache!.blockSize);',
      'await cache!.read(buffer, bufferPosition, p, sizeToRead);',
    ],
  ),
  // ② flutter_local_notifications_windows 3.1.1：ATL::CW2A → std::string 的隐式
  //    转换在新版 MSVC 下报 C2440，改成显式取 LPSTR（即 CW2A 自己管理的缓冲区）。
  _PatchTarget(
    package: 'flutter_local_notifications_windows',
    version: '3.1.1',
    relativeFile: 'src/plugin.cpp',
    broken: [
      'const std::string key = CW2A(item.Key, CP_UTF8);',
      'const std::string value = CW2A(item.Value, CP_UTF8);',
      'const auto payload = string(CW2A(args, CP_UTF8));',
    ],
    fixed: [
      'const std::string key = static_cast<LPCSTR>(CW2A(item.Key, CP_UTF8));',
      'const std::string value = static_cast<LPCSTR>(CW2A(item.Value, CP_UTF8));',
      'const auto payload = string(static_cast<LPCSTR>(CW2A(args, CP_UTF8)));',
    ],
  ),
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
  for (final target in _targets) {
    _verifyLockedVersion(repoRoot, target);
  }

  final cacheRoot = cacheRootArg ?? _defaultPubCacheRoot();
  final hosted = Directory('$cacheRoot${Platform.pathSeparator}hosted');
  if (!hosted.existsSync()) {
    _fail('找不到 pub 缓存目录：${hosted.path}（先跑 flutter pub get，或用 --pub-cache 指定）');
  }

  var needsPatch = false;
  final mismatched = <String>[];
  final absent = <String>[];

  for (final target in _targets) {
    stdout.writeln(
      '== ${target.package}-${target.version}（${target.relativeFile}）',
    );

    // 缓存里可能有多个 package host（pub.dev / 镜像站），逐个查。
    final files = <File>[];
    for (final host in hosted.listSync().whereType<Directory>()) {
      final file = File(
        [
          host.path,
          '${target.package}-${target.version}',
          ...target.relativeFile.split('/'),
        ].join(Platform.pathSeparator),
      );
      if (file.existsSync()) files.add(file);
    }
    if (files.isEmpty) {
      absent.add('${target.package}-${target.version}');
      continue;
    }

    for (final file in files) {
      final text = file.readAsStringSync();
      final missing = <int>[
        for (var i = 0; i < target.broken.length; i++)
          if (!text.contains(target.fixed[i])) i,
      ];
      if (missing.isEmpty) {
        stdout.writeln('[已就绪] ${file.path}');
        continue;
      }

      // 一半已替换、一半找不到原文：说明文件被改成本脚本不认识的样子，
      // 宁可报错也别乱写。
      final unmatched = [
        for (final i in missing)
          if (!text.contains(target.broken[i])) i,
      ];
      if (unmatched.isNotEmpty) {
        mismatched.add(file.path);
        stderr.writeln('[未匹配] ${file.path}');
        for (final i in unmatched) {
          stderr.writeln('  期望找到：${target.broken[i]}');
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
        patched = patched.replaceFirst(target.broken[i], target.fixed[i]);
      }
      file.writeAsStringSync(patched);

      // 写完立刻回读校验，避免「以为改了其实没落地」。
      final after = file.readAsStringSync();
      final notApplied =
          target.fixed.asMap().keys.where((i) => !after.contains(target.fixed[i]));
      if (notApplied.isNotEmpty) {
        _fail('写入后校验失败：${file.path}');
      }
      stdout.writeln('[已修补] ${file.path}');
    }
  }

  if (absent.isNotEmpty) {
    _fail('pub 缓存里没有 ${absent.join('、')}（先跑 flutter pub get）\n'
        '已查找：${hosted.path}');
  }

  if (mismatched.isNotEmpty) {
    _fail('${mismatched.length} 个文件的内容与预期对不上，'
        '多半是依赖版本变了：请先核对上游是否已修好，'
        '再决定是否删掉对应补丁。');
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
void _verifyLockedVersion(Directory repoRoot, _PatchTarget target) {
  final lock = File('${repoRoot.path}${Platform.pathSeparator}pubspec.lock');
  if (!lock.existsSync()) return;
  final lines = lock.readAsLinesSync();
  final start = lines.indexWhere(
    (l) => RegExp(r'^\s{2}' + RegExp.escape(target.package) + r':\s*$').hasMatch(l),
  );
  if (start < 0) return;
  for (var i = start + 1; i < lines.length && i < start + 12; i++) {
    final line = lines[i];
    if (RegExp(r'^\s{2}\S').hasMatch(line)) break; // 到下一个包了，收工
    final m = RegExp(r'^\s+version:\s*"?([^"\s]+)"?\s*$').firstMatch(line);
    if (m == null) continue;
    final locked = m.group(1)!;
    if (locked != target.version) {
      _fail('pubspec.lock 里 ${target.package} 是 $locked，本脚本只覆盖 '
          '${target.version}。\n'
          '请先核对新版本是否已修好对应问题，再更新 tools/patch_pub_cache.dart '
          '里的 _targets。');
    }
    return;
  }
}

Never _fail(String message) {
  stderr.writeln('[失败] $message');
  exit(1);
}
