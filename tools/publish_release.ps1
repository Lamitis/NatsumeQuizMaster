# NatsumeQuizMaster 一键发版（本地一条龙）
#
# 用法（在仓库根目录）：
#   powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1
#   powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1 -SkipBuild        # 复用已有构建产物，只重打包
#   powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1 -SkipAndroid      # 只发 Windows
#   powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1 -SkipWindows      # 只发 Android
#   powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1 -PortableOnly     # 不编安装包
#   powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1 -NoPublish        # 只备产物，不碰 GitHub
#   powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1 -Draft            # Release 先存草稿
#   powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1 -NotesFile dist\notes.md
#
# 流程：版本校验 → 环境检查 → Android（通用 + arm64）→ Windows（绿色版 + 安装包）
#       → SHA256SUMS.txt → gh release create（没装 gh 就只把产物留在 dist 并提示手工上传）
#
# 版本号唯一来源是 pubspec.yaml 的 version 字段（形如 1.35.4+32）：
#   安装包 / Release 标题 / 产物文件名用版本名 1.35.4；应用内展示用 v1.35.4.32
#   （--dart-define=APP_VERSION，与 CI 完全一致）。第 1 步会核对 kAppVersion 的
#   defaultValue 是否对齐，不一致直接中止，避免把版本号标错的包发出去。
#
# 前置：Flutter SDK；Inno Setup 6（可选，-PortableOnly 可跳过）；
#       gh CLI（可选，仅用于自动创建 Release；没装则产物留在 dist\ 由手工上传）。
#
# 产物（全部落在 dist\）：
#   NatsumeQuizMaster-v1.35.4.32-android-universal.apk
#   NatsumeQuizMaster-v1.35.4.32-android-arm64.apk
#   NatsumeQuizMaster-Windows-<yyyyMMdd>\   （绿色版目录）
#   NatsumeQuizMaster-Windows-<yyyyMMdd>.zip
#   NatsumeQuizMaster-Setup-1.35.4-Windows-x64.exe
#   SHA256SUMS.txt / release_notes_v1.35.4.32.md / publish_release.log
param(
    [switch]$SkipBuild,      # 复用 build\ 下已有产物，跳过两条 flutter build
    [switch]$SkipAndroid,
    [switch]$SkipWindows,
    [switch]$PortableOnly,   # 只出绿色版 zip，不编 Inno Setup 安装包
    [switch]$NoPublish,      # 不创建 tag、不调 gh
    [switch]$Draft,          # gh release create --draft
    [switch]$Prerelease,     # gh release create --prerelease
    [string]$NotesFile = '', # 自定义 Release 说明；不给就从 CHANGELOG 抽对应版本小节
    [string]$IsccPath = ''   # Inno Setup 装在自定义目录（如 D:\Tools\Inno Setup 6）时指定
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dist = Join-Path $root 'dist'
$logPath = Join-Path $dist 'publish_release.log'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# PS 5.1 的 Start-Transcript 只有 -Path（没有 -LiteralPath）；已有会话在录制时不要因此中断发版
try { Start-Transcript -Path $logPath -Force | Out-Null } catch { }

function Step([string]$text) {
    Write-Host ''
    Write-Host "=== $text ===" -ForegroundColor Cyan
}
function Info([string]$text) { Write-Host "  $text" }
function Warn([string]$text) { Write-Host "  ! $text" -ForegroundColor Yellow }

# 所有致命错误都从这里出：统一收尾（停录制）并 exit 1，避免半截发版
function Fail([string]$text) {
    Write-Host ''
    Write-Host "✗ $text" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

function Get-Sha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# APK 签名核验：用 apksigner 读证书。找不到工具就跳过（Warn），不让它挡住发版。
function Find-Apksigner {
    $onPath = Get-Command apksigner -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
    if ($env:LOCALAPPDATA) { $sdkRoots += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
    foreach ($sdk in $sdkRoots) {
        if (-not $sdk) { continue }
        $bt = Join-Path $sdk 'build-tools'
        if (-not (Test-Path -LiteralPath $bt)) { continue }
        # build-tools 按版本号排目录，取最新的那一版
        $cand = @(Get-ChildItem -LiteralPath $bt -Directory | Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'apksigner.bat' } |
            Where-Object { Test-Path -LiteralPath $_ })
        if ($cand.Count -gt 0) { return $cand[0] }
    }
    return ''
}

function Test-ApkSignature([string]$apk, [string]$apksigner) {
    if (-not $apksigner) { return }
    $out = & "$apksigner" verify --print-certs $apk 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | Out-Host
        Fail "$(Split-Path $apk -Leaf) 签名校验失败（未签名或签名损坏）——检查 android\key.properties 与 release.jks"
    }
    $text = ($out | Out-String)
    if ($text -match 'CN=Android Debug') {
        Fail "$(Split-Path $apk -Leaf) 用的是 debug 证书，装到用户机上无法覆盖升级——发版必须用 release 密钥签名"
    }
    $dn = ([regex]::Match($text, '(?m)^Signer #1 certificate DN:\s*(.+)$')).Groups[1].Value.Trim()
    Info "签名证书：$dn"
}

# PS 5.1 会把原生命令的 stderr 包装成 NativeCommandError，在 $ErrorActionPreference='Stop'
# 下直接中断脚本；而 flutter 每次都会往 stderr 刷插件警告（file_picker 的
# "default plugin" 等，见 docs/Windows构建说明.md）。所以交给 cmd 做重定向，
# 脚本只看退出码与日志尾巴。
function Invoke-Flutter([string]$argsLine, [string]$logName) {
    $log = Join-Path $dist $logName
    & cmd.exe /c "flutter $argsLine > `"$log`" 2>&1"
    $code = $LASTEXITCODE
    Get-Content -LiteralPath $log -Tail 6 -ErrorAction SilentlyContinue | Write-Host
    if ($code -ne 0) {
        Write-Host "--- $logName 最后 40 行 ---" -ForegroundColor Red
        Get-Content -LiteralPath $log -Tail 40 -ErrorAction SilentlyContinue | Write-Host
        Fail "flutter $argsLine 失败（exit $code），完整日志：$log"
    }
}

# ─────────────────────────────────────────────────────────── 1. 版本号
Step '[1/6] 解析并校验版本号（pubspec.yaml 是唯一来源）'

$pubspecPath = Join-Path $root 'pubspec.yaml'
if (-not (Test-Path -LiteralPath $pubspecPath)) { Fail '找不到 pubspec.yaml——请在仓库内运行本脚本' }
# 用 .NET 的 ReadAllText 而不是 Get-Content -Raw：PS 5.1 的 Get-Content 按 ANSI（GBK）
# 读无 BOM 的 UTF-8 文件，中文注释会整段变乱码，正则也跟着失配
$pubspec = [IO.File]::ReadAllText($pubspecPath)
if (-not ($pubspec -match '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)')) {
    Fail 'pubspec.yaml 里没有形如 1.35.4+32 的 version 字段'
}
$verName = $Matches[1]
$buildNo = $Matches[2]
$appVersion = "v$verName.$buildNo"   # 应用内展示（--dart-define=APP_VERSION）

$constPath = Join-Path $root 'lib\utils\app_constants.dart'
if (-not (Test-Path -LiteralPath $constPath)) { Fail "找不到 $constPath" }
$constText = [IO.File]::ReadAllText($constPath)
# defaultValue 在源码里跨了两行，\s* 要能吃换行
$constPattern = "kAppVersion\s*=\s*String\.fromEnvironment\(\s*'APP_VERSION'\s*,\s*defaultValue:\s*'([^']*)'"
if (-not ($constText -match $constPattern)) {
    Fail 'app_constants.dart 里没解析到 kAppVersion 的 defaultValue（写法应保持 String.fromEnvironment(...)）'
}
$constVersion = $Matches[1]

Info "pubspec.yaml       : $verName+$buildNo"
Info "app_constants.dart : $constVersion"
if ($constVersion -ne $appVersion) {
    Fail ("版本号不一致：pubspec.yaml 推导出 $appVersion，而 kAppVersion 的 defaultValue 是 $constVersion。`n" +
          "    修法：把 pubspec.yaml 的 version 与 lib/utils/app_constants.dart 的 defaultValue 统一成同一版本后重跑。`n" +
          "    （test/version_single_source_test.dart 就是拦这件事的，别绕过它。）")
}
Info "版本校验通过：$appVersion（安装包版本 $verName，构建号 $buildNo）"

# CHANGELOG 必须有本版本小节：Release 说明默认就从这里抽，缺了等于发一个没有说明的版本
$clPath = Join-Path $root 'CHANGELOG.md'
if (-not (Test-Path -LiteralPath $clPath)) { Fail '找不到 CHANGELOG.md' }
$changelogText = [IO.File]::ReadAllText($clPath)
if ($changelogText.IndexOf("## [$verName]") -lt 0) {
    Fail "CHANGELOG.md 里没有 ## [$verName] 小节——发版前先把本版本的改动按「新增 / 修复 / 重构」写进去"
}
Info "CHANGELOG.md 已有 [$verName] 小节"

# ─────────────────────────────────────────────────────────── 2. 环境
Step '[2/6] 检查构建环境'

foreach ($exe in @('flutter', 'dart')) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        Fail "找不到 $exe——请把 Flutter SDK 加进 PATH 后重开终端"
    }
}
Info 'flutter / dart 就绪'

$hasGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
if ($NoPublish) {
    Info '已指定 -NoPublish：跳过 tag 与 GitHub Release'
} elseif ($hasGh) {
    Info '检测到 gh CLI：最后会自动创建 GitHub Release'
} else {
    Warn '未安装 gh CLI：最后只把产物与 SHA256SUMS.txt 留在 dist\，需手工上传 GitHub Releases'
    Warn '如需自动发布：winget install --id GitHub.cli -e（装完重开终端）'
}

$stamp = Get-Date -Format 'yyyyMMdd'
$pkgDir = Join-Path $dist "NatsumeQuizMaster-Windows-$stamp"
$zipPath = "$pkgDir.zip"
$setupPath = Join-Path $dist "NatsumeQuizMaster-Setup-$verName-Windows-x64.exe"
$apks = @()
$dartDefine = "--dart-define=APP_VERSION=$appVersion"

# ─────────────────────────────────────────────────────────── 3. Android
if ($SkipAndroid) {
    Step '[3/6] 跳过 Android 构建（-SkipAndroid）'
} else {
    Step '[3/6] 构建 Android APK（通用版 + arm64，开启混淆）'
    $universalApk = Join-Path $dist "NatsumeQuizMaster-$appVersion-android-universal.apk"
    $arm64Apk = Join-Path $dist "NatsumeQuizMaster-$appVersion-android-arm64.apk"
    $builtApk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'

    if ($SkipBuild) {
        Warn '已指定 -SkipBuild：复用 dist\ 里已有的 APK'
        foreach ($a in @($universalApk, $arm64Apk)) {
            if (Test-Path -LiteralPath $a) { $apks += $a; Info "沿用 $(Split-Path $a -Leaf)" }
        }
        if ($apks.Count -eq 0) { Warn 'dist\ 里没有可用的 APK，本次不发 Android 产物' }
    } else {
        # 通用版先出场：紧接着的 arm64 构建会覆盖同名 app-release.apk，必须马上改名取走
        Invoke-Flutter "build apk --release --obfuscate --split-debug-info=build/symbols $dartDefine" 'build_android_universal.log'
        if (-not (Test-Path -LiteralPath $builtApk)) { Fail "构建结束但没找到 $builtApk" }
        Copy-Item -LiteralPath $builtApk -Destination $universalApk -Force
        $apks += $universalApk

        Invoke-Flutter "build apk --release --obfuscate --split-debug-info=build/symbols --target-platform android-arm64 $dartDefine" 'build_android_arm64.log'
        if (-not (Test-Path -LiteralPath $builtApk)) { Fail "构建结束但没找到 $builtApk" }
        Copy-Item -LiteralPath $builtApk -Destination $arm64Apk -Force
        $apks += $arm64Apk

        foreach ($a in $apks) { Info ("{0}  {1:N1} MB" -f (Split-Path $a -Leaf), ((Get-Item -LiteralPath $a).Length / 1MB)) }
        Info '混淆符号在 build\symbols（只用于定位崩溃堆栈，不随发布上传）'
    }

    # 签名核验放在两条路径之外：-SkipBuild 复用的 APK 也要过一遍
    if ($apks.Count -gt 0) {
        $apksigner = Find-Apksigner
        if (-not $apksigner) { Warn '没找到 apksigner（Android SDK build-tools），跳过 APK 签名核验' }
        foreach ($a in $apks) { Test-ApkSignature $a $apksigner }
    }
}

# ─────────────────────────────────────────────────────────── 4. Windows
# 与 tools\make_windows_setup.ps1 同一套查找顺序：显式指定 > 环境变量 ISCC > PATH > 常见位置
function Find-Iscc {
    if ($IsccPath) {
        if (Test-Path -LiteralPath $IsccPath) { return (Resolve-Path -LiteralPath $IsccPath).Path }
        Fail "指定的 -IsccPath 不存在：$IsccPath"
    }
    if ($env:ISCC -and (Test-Path -LiteralPath $env:ISCC)) { return (Resolve-Path -LiteralPath $env:ISCC).Path }
    $onPath = Get-Command iscc -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Path }

    $candidates = @()
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe') }
    $candidates += 'D:\Tools\Inno Setup 6\ISCC.exe'
    $candidates += 'D:\Program Files\Inno Setup 6\ISCC.exe'
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe') }
    return ($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
}

$windowsOk = $false
if ($SkipWindows) {
    Step '[4/6] 跳过 Windows 构建（-SkipWindows）'
    $windowsOk = Test-Path -LiteralPath $zipPath
} else {
    Step '[4/6] 构建 Windows 并打包（绿色版 zip + Inno Setup 安装包）'
    if ($SkipBuild) {
        Warn '已指定 -SkipBuild：复用 build\windows\x64\runner\Release'
    } else {
        # 两个第三方源码补丁（pdfrx 空安全、flutter_local_notifications_windows 的 CW2A）。
        # 与 CI 同一条命令；不先打补丁，新版 MSVC 下 Windows 构建直接报 C2440。
        & dart tools/patch_pub_cache.dart
        if ($LASTEXITCODE -ne 0) { Fail 'dart tools/patch_pub_cache.dart 失败（原因见该脚本头部说明）' }
        Invoke-Flutter "build windows --release $dartDefine" 'build_windows.log'
    }

    # 绿色版目录名显式传入：安装包 .iss 的 SrcDir 由它决定，避免打进上一次残留的旧目录
    & (Join-Path $PSScriptRoot 'package_windows.ps1') -PkgDir $pkgDir
    $pkgExit = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $zipPath)) { Fail "package_windows.ps1 没有产出 $zipPath（exit $pkgExit）" }
    $zipLen = (Get-Item -LiteralPath $zipPath).Length
    if ($zipLen -le 0) { Fail "$zipPath 是空文件" }
    Info ("{0}  {1:N1} MB" -f (Split-Path $zipPath -Leaf), ($zipLen / 1MB))
    $windowsOk = $true

    if ($PortableOnly) {
        Warn '已指定 -PortableOnly：跳过安装包（绿色版 zip 已就绪）'
    } else {
        $iscc = Find-Iscc
        if (-not $iscc) {
            Fail ("没找到 Inno Setup 6 的编译器 ISCC.exe，安装包未生成。`n" +
                  "    装好后重跑本脚本（加 -SkipBuild 可复用已构建的产物）：`n" +
                  "      winget install --id JRSoftware.InnoSetup -e`n" +
                  "      https://jrsoftware.org/isdl.php （无管理员权限时安装器加 /CURRENTUSER）`n" +
                  "      已装在自定义目录：加 -IsccPath `"D:\Tools\Inno Setup 6\ISCC.exe`"`n" +
                  "    只要免安装版：加 -PortableOnly")
        }
        Info "ISCC：$iscc"
        & "$iscc" "/DMyAppVersion=$verName" "/DSrcDir=$pkgDir" "/DOutDir=$dist" `
            (Join-Path $PSScriptRoot 'natsume_setup.iss') 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail "Inno Setup 编译失败（exit $LASTEXITCODE）" }
        if (-not (Test-Path -LiteralPath $setupPath)) {
            Fail "未找到安装包产物：$setupPath（检查 natsume_setup.iss 的 OutputBaseFilename）"
        }
        Info ("{0}  {1:N1} MB" -f (Split-Path $setupPath -Leaf), ((Get-Item -LiteralPath $setupPath).Length / 1MB))
    }
}

# ─────────────────────────────────────────────────────────── 5. 校验和
Step '[5/6] 计算 SHA256'

$artifacts = @()
foreach ($f in $apks) { if ($f -and (Test-Path -LiteralPath $f)) { $artifacts += $f } }
if ($windowsOk) {
    foreach ($f in @($zipPath, $setupPath)) { if (Test-Path -LiteralPath $f) { $artifacts += $f } }
}

$sumsPath = Join-Path $dist 'SHA256SUMS.txt'
if ($artifacts.Count -eq 0) {
    Warn '没有可发布的产物，不生成 SHA256SUMS.txt'
} else {
    $lines = @()
    foreach ($f in $artifacts) {
        $hash = Get-Sha256 $f
        $lines += ("{0}  {1}" -f $hash, (Split-Path $f -Leaf))
        Info ((Split-Path $f -Leaf) + "`n    " + $hash)
    }
    # 与 sha256sum 同格式（hash + 两空格 + 文件名），Linux/macOS 上可直接
    # `sha256sum -c SHA256SUMS.txt` 校验；Windows 上用 certutil -hashfile 人工比对
    Set-Content -LiteralPath $sumsPath -Value $lines -Encoding ASCII
    Info "已写出 $sumsPath"
}

# ─────────────────────────────────────────────────────────── 6. 发布
Step '[6/6] 发布'

$notesPath = Join-Path $dist "release_notes_$appVersion.md"
if ($NotesFile) {
    if (-not (Test-Path -LiteralPath $NotesFile)) { Fail "指定的 -NotesFile 不存在：$NotesFile" }
    Copy-Item -LiteralPath $NotesFile -Destination $notesPath -Force
    Info "Release 说明取自 $NotesFile"
} else {
    # 默认从 CHANGELOG 抽本节（第 1 步已确认该小节存在）；要写面向用户的生动文案，用 -NotesFile 覆盖
    $head = "## [$verName]"
    $idx = $changelogText.IndexOf($head)
    if ($idx -ge 0) {
        $rest = $changelogText.Substring($idx)
        $nl = $rest.IndexOf("`n")
        $body = ''
        if ($nl -ge 0) { $body = $rest.Substring($nl + 1) }
        $nextHead = [regex]::Match($body, '(?m)^## ')
        if ($nextHead.Success) { $body = $body.Substring(0, $nextHead.Index) }
        $body = ($body -replace '(?m)^---\s*$', '').Trim()
        if ($body) {
            # 无 BOM 写出：带 BOM 的 .md 在 GitHub Release 页首会多出一个零宽字符
            $notesText = "# NatsumeQuizMaster $appVersion`r`n`r`n" + $body + "`r`n"
            [IO.File]::WriteAllText($notesPath, $notesText, (New-Object System.Text.UTF8Encoding($false)))
            Info "Release 说明取自 CHANGELOG 的 [$verName] 小节"
        }
    }
    if (-not (Test-Path -LiteralPath $notesPath)) { Warn "CHANGELOG 里没有 [$verName] 小节，Release 说明交给 gh --generate-notes" }
}

$tag = "v$verName"
if ($NoPublish) {
    Warn '已指定 -NoPublish：跳过 tag 与 GitHub Release'
} elseif (-not $hasGh) {
    Warn '未检测到 gh CLI，未创建 GitHub Release。产物已备好，可手工上传到 Releases：'
    foreach ($f in $artifacts) { Info (Split-Path $f -Leaf) }
    if (Test-Path -LiteralPath $sumsPath) { Info 'SHA256SUMS.txt' }
    Info "Release 说明草稿：$notesPath"
    Info '装好 gh 后（winget install --id GitHub.cli -e）加 -SkipBuild 重跑本脚本即可自动发布'
    Info ("或手工执行：gh release create $tag --title `"NatsumeQuizMaster $appVersion`" --notes-file `"$notesPath`" dist\*")
} else {
    # gh release create 需要 tag：本地没有就建附注 tag 并推送；已存在则复用，绝不覆盖
    git -C $root rev-parse -q --verify "refs/tags/$tag" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Info "本地没有 $tag，创建附注 tag 并推送"
        git -C $root tag -a $tag -m "NatsumeQuizMaster $tag"
        if ($LASTEXITCODE -ne 0) { Fail "创建 tag $tag 失败（可能远端已存在：先 git fetch --tags 查看）" }
        git -C $root push origin $tag
        if ($LASTEXITCODE -ne 0) { Fail "推送 tag $tag 失败" }
    } else {
        Info "tag $tag 已存在，直接复用"
    }

    $ghArgs = @('release', 'create', $tag, '--title', "NatsumeQuizMaster $appVersion", '--verify-tag')
    if (Test-Path -LiteralPath $notesPath) { $ghArgs += @('--notes-file', $notesPath) }
    else { $ghArgs += '--generate-notes' }
    if ($Draft) { $ghArgs += '--draft' }
    if ($Prerelease) { $ghArgs += '--prerelease' }
    $ghArgs += $artifacts
    if (Test-Path -LiteralPath $sumsPath) { $ghArgs += $sumsPath }

    Info ("gh " + ($ghArgs -join ' '))
    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) {
        Fail ("gh release create 失败（exit $LASTEXITCODE）。常见原因：同名 Release 已存在——`n" +
              "    先 gh release delete $tag --yes，或改用 gh release upload $tag <文件>。")
    }
    Info "Release 已创建：$tag"
}

# ─────────────────────────────────────────────────────────── 汇总
Step '完成'
foreach ($f in $artifacts) {
    Info ("{0}  {1:N1} MB" -f (Split-Path $f -Leaf), ((Get-Item -LiteralPath $f).Length / 1MB))
}
Info "产物目录：$dist"
Info "日志：$logPath"
try { Stop-Transcript | Out-Null } catch { }
exit 0



