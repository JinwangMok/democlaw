@echo off
REM =============================================================================
REM checksum.bat — Windows batch wrapper for SHA256 checksum operations
REM
REM Delegates to checksum.ps1 for actual processing. This wrapper exists so
REM users can invoke checksum operations from cmd.exe without remembering
REM PowerShell execution policy flags.
REM
REM Usage:
REM   checksum.bat compute  <file>
REM   checksum.bat store    <file>
REM   checksum.bat verify   <file>
REM   checksum.bat verify-dir  <directory>
REM   checksum.bat store-dir   <directory>
REM   checksum.bat verify-model-cache [model-name] [cache-dir]
REM =============================================================================

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"

REM Validate arguments
if "%~1"=="" (
    echo [checksum] ERROR: No action specified.
    echo.
    echo Usage:
    echo   %~nx0 compute  ^<file^>
    echo   %~nx0 store    ^<file^>
    echo   %~nx0 verify   ^<file^>
    echo   %~nx0 verify-dir  ^<directory^>
    echo   %~nx0 store-dir   ^<directory^>
    echo   %~nx0 verify-model-cache [model-name] [cache-dir]
    exit /b 1
)

set "ACTION=%~1"

REM Handle model-related actions specially (optional args with model name)
if /i "%ACTION%"=="verify-model-cache" goto :model_action
if /i "%ACTION%"=="needs-download" goto :model_action
if /i "%ACTION%"=="store-model-cache" goto :model_action
goto :non_model_action

:model_action
set "MODEL_NAME=%~2"
set "CACHE_DIR=%~3"
if "!MODEL_NAME!"=="" set "MODEL_NAME=Qwen/Qwen3-4B-AWQ"
if "!CACHE_DIR!"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%checksum.ps1" -Action "%ACTION%" -ModelName "!MODEL_NAME!"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%checksum.ps1" -Action "%ACTION%" -ModelName "!MODEL_NAME!" -CacheDir "!CACHE_DIR!"
)
exit /b !ERRORLEVEL!

:non_model_action

REM All other actions require a path
if "%~2"=="" (
    echo [checksum] ERROR: Path argument is required for action '%ACTION%'.
    exit /b 1
)

set "TARGET_PATH=%~2"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%checksum.ps1" -Action "%ACTION%" -Path "%TARGET_PATH%"
exit /b %ERRORLEVEL%
