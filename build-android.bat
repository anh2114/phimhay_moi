@echo off
setlocal enabledelayedexpansion
echo.
echo ========================================
echo   Xiao Phim - Build Android (APK)
echo ========================================
echo.

if "%~1"=="" (
    set /p "VERSION=Enter version (e.g. 3.4.5): "
    if "!VERSION!"=="" (
        echo Version cannot be empty!
        pause
        exit /b 1
    )
) else (
    set "VERSION=%~1"
)

echo Version: !VERSION!
echo.

REM Get current version from pubspec.yaml
for /f "tokens=2" %%a in ('findstr "version:" pubspec.yaml') do set "OLD_VER=%%a"
echo Current version: !OLD_VER!

REM Extract build number
for /f "tokens=2 delims=+" %%a in ("!OLD_VER!") do set "BUILD=%%a"
set /a NEWBUILD=!BUILD!+1
set "NEW_VER=!VERSION!+!NEWBUILD!"

REM Update pubspec.yaml
echo Updating pubspec.yaml: !NEW_VER!
powershell -Command "((Get-Content pubspec.yaml) -replace '^version:.*$', 'version: !NEW_VER!') | Set-Content pubspec.yaml"
echo Done
echo.

REM Build APK with obfuscation
echo Building APK (obfuscated)...
call flutter build apk --release --obfuscate --split-debug-info=build/debug-info
if errorlevel 1 (
    echo Build failed!
    pause
    exit /b 1
)

REM Copy to Downloads
set "DOWNLOADS=C:\xampp\htdocs\Downloads"
if not exist "!DOWNLOADS!" mkdir "!DOWNLOADS!"

REM Delete old files
echo Deleting old APK...
del /q "!DOWNLOADS!\xiaophim-*.apk" 2>nul
echo Done

copy "build\app\outputs\flutter-apk\app-release.apk" "!DOWNLOADS!\xiaophim-!VERSION!.apk"

echo.
echo ========================================
echo   BUILD APK COMPLETE!
echo ========================================
echo.
echo File: !DOWNLOADS!\xiaophim-!VERSION!.apk
echo.
pause
