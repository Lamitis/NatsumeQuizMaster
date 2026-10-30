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
if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force }
New-Item -ItemType Directory -Path $pkgDir | Out-Null

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
        Remove-Item -LiteralPath $dll.FullName -Force
        $staleDlls += $dll.Name
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
    $junk | Remove-Item -Force
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
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$pkgDir\*" -DestinationPath $zipPath -CompressionLevel Optimal

Write-Output "打包完成："
Write-Output "  目录：$pkgDir"
Write-Output "  压缩：$zipPath ($([math]::Round((Get-Item $zipPath).Length/1MB,1)) MB)"
