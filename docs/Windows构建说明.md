# Windows 构建说明

## 推荐环境

| 组件 | 版本 / 要求 |
|---|---|
| Flutter | **3.47.8**（Dart 3.13.7），仓库内 `.fvmrc` 已锁定为标准版本；也兼容 3.24.5（Dart 3.5.4） |
| Visual Studio | 2022/2026 Build Tools，含 MSVC、Windows 10/11 SDK、**ATL** 组件、Windows 10 SDK ≥ 10.0.17763 |
| Windows | 开启「开发者模式」（Flutter 插件和 pdfrx 都使用符号链接） |

已验证可用的组合（本仓库最后一次成功构建）：

```
Flutter 3.47.8 (stable, Dart 3.13.7)
VS 2026 Build Tools 18.10.12210.168 / MSVC 14.51.36231 / Windows SDK 10.0.26100.0
flutter build windows --debug     -> 42.3s  -> build\windows\x64\runner\Debug\natsume_quiz_master.exe
flutter build windows --release   -> 168.6s -> build\windows\x64\runner\Release\natsume_quiz_master.exe
```

两个产物都已实际启动验证（进程可正常驻留）。Release 版把 MSVC 运行时按 `/MD`
动态链接，分发时必须让目标机器装有 **Microsoft Visual C++ 2015-2022
Redistributable (x64)**，或改用 `windows/CMakeLists.txt` 里的
`set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")` 静态链接。

使用 FVM 时：

```powershell
fvm install
fvm use
fvm flutter pub get
fvm flutter build windows --debug
```

不用 FVM 时直接 `flutter build windows --debug` 即可（本机即如此）。

## 已知问题与处理

### 1. pdfrx 的空安全漏补（1.3.5 原版也中招）

症状：编译 pdfrx 时报

```
pdf_file_cache.dart:351:63: Error: Property 'blockSize' cannot be accessed on
    'PdfFileCache?' because it is potentially null.
pdf_file_cache.dart:353:23: Error: Method 'read' cannot be called on 'PdfFileCache?' ...
```

原因：`pdfDocumentFromUri` 的 `cache` 是**可空参数**（`PdfFileCache?`），
`cache ??= await PdfFileCache.fromUri(uri)` 之后在 `openCustom(read: …)` 的闭包里读它
——可变参数 + 被闭包捕获 + 中间隔着 `await`，Dart 的类型提升在闭包内失效。
上游只给 346 / 366 行补了 `!`，351 / 353 这两处漏了；1.0.x 的空安全更不完整，
直到 2.0.0 整体重写才消失（那已是破坏性 API 变更，不能为发一次版本随手升）。

处理：`pubspec.lock` 固定在 **pdfrx 1.3.5**，并用幂等脚本补上这两个 `!`：

```powershell
dart tools\patch_pub_cache.dart
# 只检查是否已就绪、不写文件：加 --check
```

干净环境（新克隆 / CI / `flutter pub cache repair` 之后）**必须先跑这一步**，
否则编译 pdfrx 必然失败；在 CI 上它还会伪装成「一批测试套件 `loading … [E]`」
——编译器在编 pdfrx 时先挂掉，后面没编完的套件全部连带失败，看起来像测试基础设施坏了。
`pubspec.yaml` 的 SDK 约束为 `>=3.2.0 <4.0.0`，Dart 3.5 与 3.13 都满足；
实测 Dart 3.13.7（Flutter 3.47.8）打好补丁后编译正常，无需降 Dart 版本。

### 2. flutter_local_notifications_windows 需要 C++20

症状：`error C2338: static assertion failed`（`<experimental/coroutine>`）。
处理：`windows/CMakeLists.txt` 已在 `generated_plugins.cmake` 之前设置：

```cmake
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
```

注意这必须**全局**设置，不能只给某个插件目标开 C++20：`audioplayers_windows`
同样会间接包含 `<experimental/coroutine>`，一旦编译标准退回 C++17，它就会触发
同一个 C2338（`MSVC 14.51` 起该头文件是硬错误，不再是警告）。

### 3. 缺少 atlbase.h

症状：`error C1083: Cannot open include file: 'atlbase.h'`。
处理：在 Visual Studio Installer 中为 Build Tools 勾选 **ATL** 组件。

### 4. pdfrx 的 pdfium 预编译包下载失败

`pdfrx` 的 `windows/CMakeLists.txt` 在配置阶段用 CMake 自带的
`file(DOWNLOAD ...)` 去拉 pdfium 预编译包。这个调用不检查返回状态，
本机实测会静默失败并生成 0 字节的 tgz，随后配置阶段报：

```
CMake Error at flutter/ephemeral/.plugin_symlinks/pdfrx/windows/CMakeLists.txt:69 (file):
  file COPY cannot find ".../build/windows/x64/pdfium/chromium%2F7202/bin/pdfium.dll"
```

手动补下载（PowerShell / curl 走系统代理，比 CMake 下载可靠）：

```powershell
$ver = 'chromium%2F7202'   # 对应 pdfrx-1.3.5 的 PDFIUM_RELEASE
$dir = "build\windows\x64\pdfium\$ver"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
curl.exe -L -o "$dir\pdfium-win-x64.tgz" `
  "https://github.com/bblanchon/pdfium-binaries/releases/download/$ver/pdfium-win-x64.tgz"
tar.exe -xzf "$dir\pdfium-win-x64.tgz" -C $dir
```

解压后该目录下应有 `bin/pdfium.dll`、`include/`、`lib/`。随后重新执行
`flutter build windows` 即可（配置阶段会打印 `Use existing precompiled PDFium.`）。

注意：`flutter clean` 或手动删除 `build/` 之后需要重新补一次；本仓库的
`build/` 是构建产物，不随源码提交。

### 5. 修改 pubspec.yaml 时保持 UTF-8

PowerShell 的 `Set-Content` 默认可能使用 ANSI，导致中文注释乱码、依赖行被吞。
请用 UTF-8 写入：

```powershell
[IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
```

### 6. flutter_local_notifications_windows 3.1.1 的 `ATL::CW2A` 隐式转换（C2440）

症状：

```
error C2440: 'initializing': cannot convert from 'ATL::CW2A' to 'std::basic_string<...>'
```

`flutter_local_notifications` 22.3.3 的 Windows 实现虽然已经是 ffiPlugin，但仍会编译
一小段 C++（点击通知的激活回调，`src/plugin.cpp`），里面写的是：

```cpp
const std::string key = CW2A(item.Key, CP_UTF8);
```

新版 ATL 把 `CW2A` 的转换运算符改成显式之后，`CW2A → LPSTR → std::string` 属于两次
用户自定义转换，直接报 C2440。**这与 runner 镜像无关**：`windows-latest` 与
`windows-2022`（VS 17.14 起）一样报；pub 上也没有已修复的稳定版（只有 4.0.0-dev.x），
所以只能就地改。处理脚本受版本控制，和 pdfrx 的补丁是同一条命令：

```powershell
dart tools\patch_pub_cache.dart
# 只检查是否已就绪、不写文件：加 --check
```

改动是把三处（`item.Key` / `item.Value` / `args`）写成
`static_cast<LPCSTR>(CW2A(...))` 再构造 `std::string`，语义完全不变。

> 不要用「把 `CMAKE_CXX_STANDARD` 降回 17 / 加 `CXXFLAGS=/std:c++17`」来绕：这个报错是
> 转换运算符的隐式性问题，跟语言标准无关；反而会触发上面第 2 条的 C2338
> （C++/WinRT 协程需要 C++20）。

补充：`share_plus 10.1.4`（旧 C++/WinRT 头）与 `flutter_secure_storage_windows 3.1.2`
（`GetValueKey` 漏类名限定、`CW2A` 隐式转换）当年也要打补丁，v1.35.1 已经把依赖升到
不再有这些写法的版本（前者已移除、后者 4.x 重写），无需再处理。

### 7. share_plus 的 Windows 插件要单独退回 C++17（历史，当前依赖里没有）

> v1.34 导出改「另存为」后 `share_plus` 已从依赖里移除，本节只在将来重新引入
> `share_plus 10.x` 时才需要；`windows/CMakeLists.txt` 里的
> `if(TARGET share_plus_plugin)` 仍保留，重新引入后会自动继续生效。

`windows/CMakeLists.txt` 在 `include(flutter/generated_plugins.cmake)` 之后加了：

```cmake
foreach(_cxx17_target share_plus_plugin)
  if(TARGET ${_cxx17_target})
    set_target_properties(${_cxx17_target} PROPERTIES
      CXX_STANDARD 17
      CXX_STANDARD_REQUIRED ON)
  endif()
endforeach()
```

> 注意目标名是插件自己 CMakeLists 里的 `PLUGIN_NAME`，即
> `share_plus_plugin`，**不是**包名 `share_plus`。写错名字时 `if(TARGET ...)`
> 静默不成立，编译仍然用 C++20，报错和没改一样。

原因：全局 C++20 会让 MSVC 自动启用 `/permissive-`（两阶段名字查找），
而 share_plus 10.1.4 自带的 C++/WinRT 辅助头 `vector.h` 是早期版本，
大量依赖宽松查找（`RuntimeClass::IVector::T_complex`、从依赖基类继承的
`ElementType` 等），C++20 下会成一个上百条错误的连锁反应：

```
vector.h(289,3): error C2065: 'RuntimeClass': undeclared identifier
vector.h(290,7): error C2065: 'T_complex': undeclared identifier
vector.h(343,7): error C2065: 'item': undeclared identifier
```

只给该目标降回 C++17（等价 `/std:c++17`，不带 `/permissive-`）即可，
其他插件（`audioplayers_windows`、`flutter_local_notifications_windows` 等）
继续使用 C++20。

### 8. 排查用的经验

- 错误数量超过 100 条时 MSVC 会截断（`error C1003: error count exceeds 100`），
  先修最靠前的「第一个」错误，后面的多半是连锁反应。
- 插件源码在 `windows/flutter/ephemeral/.plugin_symlinks/<plugin>`（符号链接，
  指向 pub 缓存），改 pub 缓存里的文件会立即生效，但 `flutter clean` 或
  `pub cache repair` 之后需要重新跑第 6 节的脚本。
- 插件的编译选项是 `/W4 /WX`：任何警告都会变成错误。往插件源码里加注释时
  请只用 ASCII，中文注释会触发 `error C2220 + warning C4819`
  （源文件字符无法用当前代码页 936 表示）。

### 9. 没有管理员权限时装 Inno Setup 6（只影响安装包，不影响构建）

`tools\make_windows_setup.ps1` 的第 4 步要调 `ISCC.exe` 把绿色版目录压成安装包。
没有管理员权限、也没装 Inno Setup 时，可以用官方安装包的 `/CURRENTUSER` 参数装到
当前用户目录 —— 不需要 UAC：

```powershell
# 官方下载页 download.php 只返回一个 ~11 KB 的 HTML 落地页，不是安装包本体；
# 真正的二进制在 GitHub release（jrsoftware/issrc）上。
$url = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe'
$exe = Join-Path $env:TEMP 'innosetup-6.7.4.exe'
curl.exe -L --retry 2 --max-time 300 -o $exe $url
Start-Process $exe -ArgumentList '/VERYSILENT','/CURRENTUSER','/SUPPRESSMSGBOXES','/NORESTART' -Wait
Test-Path "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"   # 应为 True
```

装好后 `Find-Iscc` 会自动找到它（候选路径里已包含 `%LOCALAPPDATA%\Programs\Inno Setup 6`），
直接重跑脚本即可：

```powershell
powershell -ExecutionPolicy Bypass -File tools\make_windows_setup.ps1 -SkipBuild
```

脚本的 `-InstallInnoSetup` 开关做的就是这件事（先试 winget，失败再走上面的 release 下载 +
`/CURRENTUSER`）。**绿色版 / zip 这一步完全不需要 Inno Setup**，急着发版时用
`-PortableOnly` 只出免安装版即可。

### 10. Inno Setup 装在自定义目录（例如 D 盘）

Inno Setup 是绿色的：**整个安装目录**挪到任何位置都能用（`ISCC.exe` 依赖同目录的
`ISCmplr.dll`、`islzma*.exe` 等，不能只拷 `ISCC.exe`）。挪完/装完后让脚本知道位置即可，
`Find-Iscc` 的查找顺序是：`-IsccPath` → 环境变量 `ISCC` → `PATH` 里的 `iscc` →
常见位置（`C:\Program Files (x86)`、`%LOCALAPPDATA%\Programs`、`D:\Tools` 等）。

```powershell
# 方式 A：装/挪到 D 盘后设一次环境变量（新开终端生效，之后脚本自动用）
Start-Process (Join-Path $env:TEMP 'innosetup-6.7.4.exe') `
  -ArgumentList '/VERYSILENT','/CURRENTUSER','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/DIR=D:\Tools\Inno Setup 6' -Wait
setx ISCC 'D:\Tools\Inno Setup 6\ISCC.exe'

# 方式 B：每次显式指定（不改环境变量）
powershell -ExecutionPolicy Bypass -File tools\make_windows_setup.ps1 -SkipBuild -IsccPath 'D:\Tools\Inno Setup 6\ISCC.exe'
```

> 注意：如果只是把某个目录「复制/解压」到桌面（例如 `C:\Users\Public\Desktop\Inno Setup 6`），
> 那只是一份**重复副本**，不带 `unins000.exe`，也不进「应用和功能」列表，可直接删掉；
> 正式安装在 `%LOCALAPPDATA%\Programs\Inno Setup 6`（带卸载器）。

