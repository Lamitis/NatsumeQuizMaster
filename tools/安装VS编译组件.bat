@echo off
rem Self-elevate to admin if needed
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)
powershell -ExecutionPolicy Bypass -File "%~dp0install_vs_buildtools.ps1"
echo.
echo ==========================================
echo Done. Close this window.
pause
