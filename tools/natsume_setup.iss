; NatsumeQuizMaster Windows 安装包脚本（Inno Setup 6）
;
; 编译（推荐 —— 版本号与源目录都由发布脚本传入）：
;   ISCC.exe /DMyAppVersion=1.28.1 /DSrcDir="...\dist\NatsumeQuizMaster-Windows-20260914" tools\natsume_setup.iss
;
; 直接双击编译也可以，但 MyAppVersion 会退化成 0.0.0 —— 这是刻意的：
; 宁可版本号明显是错的，也不要静默沿用上一次的版本。
;
; 关于 SrcDir：以前这里写死了一个带日期的目录（dist\NatsumeQuizMaster-Windows-20260911），
; 而发布脚本只替换版本号、从不更新它 —— 于是打包可能装进旧日期的绿色版内容。
; 现在改为由 publish_release.ps1 显式传入，与实际产物目录由构造保证一致。
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
; 项目根目录 = 本文件所在目录的上级。默认用 SourcePath 推导（本地直接编译即可）；
; CI（.github/workflows/release.yml）会显式传 /DProjectRoot=<绝对路径> 覆盖，
; 这样脚本不依赖 ScriptDir 的推导，日志里的路径也一目了然。
#ifndef ProjectRoot
  #define ProjectRoot SourcePath + ".."
#endif
#ifndef SrcDir
  #define SrcDir ProjectRoot + "\dist\NatsumeQuizMaster-Windows-未指定"
#endif
; 源目录缺失时给出可读提示。ISCC 原本只会回一句 Win32 的
; "The system cannot find the file specified."，看不出到底是哪个目录没了。
; 提示只写固定文案：实际路径见 workflow 打印的 ISCC 参数行（/DSrcDir=...）。
#if !DirExists(SrcDir)
  #pragma message "警告：绿色版目录 SrcDir 不存在——请确认打包脚本已生成该目录，或改用 /DSrcDir=<绝对路径> 传入"
#endif
#ifndef OutDir
  #define OutDir ProjectRoot + "\dist"
#endif
#define MyAppName "NatsumeQuizMaster"
#define MyAppPublisher "Natsume An-An"
#define MyAppExeName "natsume_quiz_master.exe"

[Setup]
; 固定 AppId：升级安装时识别为同一应用（不随版本变化）
AppId={{8E9B7A32-5C4D-4E6F-9A1B-2C3D4E5F6A70}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\NatsumeQuizMaster
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutDir}
OutputBaseFilename=NatsumeQuizMaster-Setup-{#MyAppVersion}-Windows-x64
; 图标 / 许可文本缺了就跳过（并打印原因）：一个装饰性文件不该让整个安装包编不出来，
; 而 ISCC 对此只会回一句 Win32 的 "The system cannot find the file specified."。
#if FileExists(ProjectRoot + "\windows\runner\resources\app_icon.ico")
SetupIconFile={#ProjectRoot}\windows\runner\resources\app_icon.ico
#else
  #pragma message "警告：缺少 windows\runner\resources\app_icon.ico，安装包将使用 Inno Setup 默认图标"
#endif
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
; 支持「为所有用户安装 / 仅当前用户」二选一
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
; 安装前关闭正在运行的NatsumeQuizMaster（防文件占用）
CloseApplications=yes
RestartApplications=no
; 数据目录提示：卸载保留 %LOCALAPPDATA%\natsume_quiz_master 的题库数据
VersionInfoVersion={#MyAppVersion}
VersionInfoProductName={#MyAppName}
; 许可文本：默认用精简版 tools\setup_license.txt；CI 通过
; /DLicenseTextFile=<绝对路径> 传入，缺精简版时退回仓库根的 LICENSE（AGPL 全文）。
#ifndef LicenseTextFile
  #define LicenseTextFile ProjectRoot + "\tools\setup_license.txt"
#endif
#if FileExists(LicenseTextFile)
LicenseFile={#LicenseTextFile}
#else
  #pragma message "警告：许可文本不存在（缺 tools\setup_license.txt，且未通过 /DLicenseTextFile 指定），安装向导将不显示许可协议页"
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
; 绿色版全部文件（exe + 插件 DLL + data 资源），含使用说明
Source: "{#SrcDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 卸载不清理用户数据（题库/记录在 %LOCALAPPDATA%\natsume_quiz_master），如需彻底清除由用户手动删除
