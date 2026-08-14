@echo off
rem Build DSH Launcher.exe for Windows (single file, .NET Framework 4.8)
rem Uses the csc.exe that ships with .NET Framework 4.8 (built into Win10/11) - no SDK needed.
setlocal
cd /d "%~dp0"

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo [ERROR] csc.exe not found. .NET Framework 4.8 is required (built into Windows 10/11).
    exit /b 1
)

if not exist dist mkdir dist

echo == Compiling DSH Launcher.exe ==
"%CSC%" /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 ^
    /out:"dist\DSH Launcher.exe" ^
    /win32icon:"Resources\AppIcon.ico" ^
    /win32manifest:"Resources\app.manifest" ^
    /resource:"Resources\favicon.svg",DSHLauncher.favicon.svg ^
    /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll ^
    "Sources\DSHLauncher.cs"

if errorlevel 1 (
    echo [ERROR] build failed
    exit /b 1
)

echo == Done ==
echo exe: %CD%\dist\DSH Launcher.exe
