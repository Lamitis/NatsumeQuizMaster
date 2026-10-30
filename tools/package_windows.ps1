# NatsumeQuizMaster Windows 桌面版打包脚本
# 前置：flutter build windows --release 已成功
# 产物：dist\NatsumeQuizMaster-Windows-<日期>\（绿色版目录） + dist\NatsumeQuizMaster-Windows-<日期>.zip
#
# 参数：
#   -PkgDir <路径>  指定绿色版输出目录（默认 dist\NatsumeQuizMaster-Windows-<yyyyMMdd>）。
#                   publish_release.ps1 会显式传入，好让安装包脚本（.iss）的
#                   SrcDir 与实际产物目录**由构造保证一致**——此前 .iss 里的
#                   SrcDir 写死了一个日期，且没人更新它，存在打包进旧内容的风险。
param(
    [string]$PkgDir = ''
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$buildDir = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path $buildDir)) {
    Write-Host '未找到构建产物，请先执行：flutter build windows --release' -ForegroundColor Red
    exit 1
}

$distRoot = Join-Path $root 'dist'
$stamp = Get-Date -Format 'yyyyMMdd'
$pkgName = "NatsumeQuizMaster-Windows-$stamp"
$pkgDir = if ($PkgDir) { $PkgDir } else { Join-Path $distRoot $pkgName }
# 旧目录可能被杀软 / 资源管理器 / 上一次未退出的进程占着句柄：删不干净不该让打包失败，
# 下面 Copy-Item 会覆盖同名文件。删不掉的残留由「产物校验」兜底（只看 zip 是否真的生成）。
if (Test-Path $pkgDir) {
    Remove-Item $pkgDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null

Copy-Item "$buildDir\*" $pkgDir -Recurse

# 剔除非必要文件（一）：Flutter 不会清理上一次构建留在 Release 目录里的旧 DLL。
# 插件被移除后（例如 share_plus → 导出改「另存为」），它的 *_plugin.dll 仍躺在那里，
# 会被原样打进绿色版和安装包，白占体积、还会让人以为功能还在。
# 判据取 pubspec.lock：DLL 名去掉 _plugin（或 _windows_plugin）后缀后，
# 在 lock 里找不到同名包 → 视为陈旧，删除。
# 不带 _plugin 后缀的（pdfium.dll / pdfrx.dll / flutter_windows.dll）一律不动——
# 它们不是插件产物，删了应用就起不来。
$lockText = Get-Content (Join-Path $root 'pubspec.lock') -Raw
$staleDlls = @()
foreach ($dll in @(Get-ChildItem -LiteralPath $pkgDir -Filter '*_plugin.dll' -File)) {
    $baseName = $dll.BaseName
    $candidates = @($baseName -replace '_plugin$', '')
    if ($baseName -like '*_windows_plugin') {
        $candidates += ($baseName -replace '_windows_plugin$', '')
    }
    $stillUsed = @($candidates | Where-Object {
        $lockText -match ('(?m)^  ' + [regex]::Escape($_) + ':\s*$')
    }).Count -gt 0
    if (-not $stillUsed) {
        # 删不掉（被占用）就让它留着：多一个旧 DLL 不该让发版失败
        Remove-Item -LiteralPath $dll.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $dll.FullName)) { $staleDlls += $dll.Name }
    }
}
if ($staleDlls.Count -gt 0) {
    Write-Host "  剔除陈旧插件 DLL（pubspec.lock 已无对应包）：$($staleDlls -join ', ')" -ForegroundColor Yellow
}

# 剔除非必要文件（二）：调试符号与链接中间产物不随包分发
# （Release 正常没有，历史 Debug 产物残留时兜底）。
# 注意：这里**不能**用 Get-ChildItem -Include '*.pdb','*.ilk' —— PowerShell 5.1 在
# 「目录路径 + -Recurse + -Include」这个组合下会退化成「匹配目录下所有文件」，
# 把 dll / exe / assets 一起删掉（实测会把整个包删空）。按扩展名逐项过滤才可靠。
$junkExt = @('.pdb', '.ilk', '.exp', '.lib')
$junk = @(Get-ChildItem -LiteralPath $pkgDir -Recurse -File |
    Where-Object { $junkExt -contains $_.Extension.ToLowerInvariant() })
if ($junk.Count -gt 0) {
    $junkNames = @($junk | ForEach-Object { $_.Name })
    $junk | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "  剔除非分发文件：$($junkNames -join ', ')" -ForegroundColor Yellow
}

# 额外生成中文名启动器（同目录依赖不受影响）
Copy-Item "$pkgDir\natsume_quiz_master.exe" "$pkgDir\NatsumeQuizMaster.exe"

# AGPL-3.0 要求随二进制分发协议文本（命名为 .txt 便于 Windows 用户直接打开）
Copy-Item (Join-Path $root 'LICENSE') "$pkgDir\LICENSE.txt"

# 使用说明
@'
NatsumeQuizMaster · Windows 桌面版
====================

运行：双击 NatsumeQuizMaster.exe（或 natsume_quiz_master.exe）即可，无需安装。

说明：
- 数据保存在 %LOCALAPPDATA%\natsume_quiz_master\flashcard.db（SQLite 数据库）
- 运行需要 Microsoft Visual C++ 2015-2022 Redistributable (x64)
  https://aka.ms/vs/17/release/vc_redist.x64.exe
  （缺失时启动会提示找不到 VCRUNTIME140.dll / MSVCP140.dll）
- 首次启动若被 SmartScreen 提示"未识别的应用"，点「更多信息 → 仍要运行」即可（未做代码签名）
- 手写批注：刷题页右上角画笔按钮进入；鼠标按住左键即可书写
'@ | Out-File "$pkgDir\使用说明.txt" -Encoding UTF8

$zipPath = Join-Path $distRoot "$(Split-Path $pkgDir -Leaf).zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }

# Compress-Archive 在 Windows PowerShell 5.1 上偶尔会因为杀软 / 索引器临时占用目标文件
# 而抛「另一个程序正在使用此文件」，这不是致命的：删掉半成品重试即可。
$zipped = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        Compress-Archive -Path "$pkgDir\*" -DestinationPath $zipPath `
            -CompressionLevel Optimal -ErrorAction Stop
        $zipped = $true
        break
    } catch {
        Write-Host "  压缩第 $attempt 次失败：$($_.Exception.Message)" -ForegroundColor Yellow
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    }
}
if (-not $zipped) {
    Write-Host '压缩连续失败三次，放弃' -ForegroundColor Red
}

# ── 成功判据只看产物 ────────────────────────────────────────────────
# 调用方（CI / 本地发布脚本）通常写成 `& package_windows.ps1 ...` 再用 $LASTEXITCODE
# 判断成败，但 **$LASTEXITCODE 只反映原生 exe 的退出码**，调用 .ps1 不会更新它——
# 曾因此在 zip 已经生成的情况下误报失败。所以这里显式 exit 0/1，并且「成功」的
# 定义就是「zip 真的存在且非空」，而不是某条命令有没有吐过警告。
if (-not (Test-Path -LiteralPath $zipPath)) {
    Write-Host "打包失败：没有生成 $zipPath" -ForegroundColor Red
    exit 1
}
$zipLen = (Get-Item -LiteralPath $zipPath).Length
if ($zipLen -le 0) {
    Write-Host "打包失败：$zipPath 是空文件" -ForegroundColor Red
    exit 1
}

Write-Output "打包完成："
Write-Output "  目录：$pkgDir"
Write-Output "  压缩：$zipPath ($([math]::Round($zipLen/1MB,1)) MB)"
exit 0
