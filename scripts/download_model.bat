@echo off
:: =============================================================================
:: download_model.bat -- Windows batch wrapper for download_model.ps1
::
:: Invokes the PowerShell model download script with proper execution policy
:: handling. Users can double-click this file or run it from cmd.exe without
:: needing to remember PowerShell execution policy flags.
::
:: Downloads the HuggingFace model with full SHA256 checksum verification:
::   1. Pre-download: checks cached files against stored .sha256 sidecars
::   2. Download: huggingface-cli with Python fallback, resume support
::   3. Post-download: verifies downloaded files for corruption
::   4. Stores checksums: writes .sha256 sidecars for future verification
::
:: Idempotency: safe to run repeatedly. If all cached model files pass SHA256
:: verification, the download is skipped entirely.
::
:: Usage:
::   scripts\download_model.bat
::   scripts\download_model.bat -ModelName "Qwen/Qwen3-4B-AWQ"
::   scripts\download_model.bat -CacheDir "D:\models"
::   scripts\download_model.bat -ForceDownload
::   scripts\download_model.bat -HfToken "hf_xxx"
::
:: Environment overrides:
::   set MODEL_NAME=Qwen/Qwen3-4B-AWQ
::   set HF_CACHE_DIR=D:\models
::   set HF_TOKEN=hf_xxx
::   set FORCE_DOWNLOAD=1
::   set MAX_RETRIES=5
::
:: All arguments are forwarded to download_model.ps1 as-is.
:: See download_model.ps1 for the full parameter list.
:: =============================================================================

setlocal

echo [download_model] ========================================================
echo [download_model]   DemoClaw - Model Download (Windows Batch Wrapper)
echo [download_model] ========================================================
echo.
echo [download_model] Delegating to PowerShell for download and SHA256
echo [download_model] checksum verification ...
echo.

:: ---------------------------------------------------------------------------
:: Verify PowerShell is available
:: ---------------------------------------------------------------------------
where powershell.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [download_model] ERROR: PowerShell is not available on this system. >&2
    echo [download_model] PowerShell 5.1+ is required for model download and >&2
    echo [download_model] SHA256 checksum verification. >&2
    echo. >&2
    echo [download_model] Options: >&2
    echo [download_model]   - Install PowerShell 5.1+ ^(included in Windows 10+^) >&2
    echo [download_model]   - Use WSL2 with: ./scripts/download_model.sh >&2
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Verify the PowerShell script exists
:: ---------------------------------------------------------------------------
if not exist "%~dp0download_model.ps1" (
    echo [download_model] ERROR: download_model.ps1 not found in %~dp0 >&2
    echo [download_model] Ensure the DemoClaw scripts directory is intact. >&2
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Invoke the PowerShell script with Bypass execution policy
::
:: -NoProfile     : skip user profile for clean environment
:: -ExecutionPolicy Bypass : allow script execution without requiring
::                           system-wide policy changes
:: %*             : forward all arguments to the PowerShell script
:: ---------------------------------------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0download_model.ps1" %*
set "PS_EXIT=%ERRORLEVEL%"

:: ---------------------------------------------------------------------------
:: Report outcome
:: ---------------------------------------------------------------------------
if %PS_EXIT% equ 0 (
    echo.
    echo [download_model] Model download and checksum verification completed successfully.
    echo [download_model] Start the stack with: scripts\start.bat
) else (
    echo.
    echo [download_model] ERROR: Model download or verification failed (exit code: %PS_EXIT%). >&2
    echo [download_model] Check the output above for details. >&2
    echo. >&2
    echo [download_model] Common fixes: >&2
    echo [download_model]   - Ensure you have internet connectivity >&2
    echo [download_model]   - Check disk space in the cache directory >&2
    echo [download_model]   - Install huggingface-cli: pip install huggingface-cli >&2
    echo [download_model]   - Or install huggingface_hub: pip install huggingface_hub >&2
    echo [download_model]   - Try with -ForceDownload to re-download from scratch >&2
    echo [download_model]   - Use WSL2 alternative: ./scripts/download_model.sh >&2
)

:: ---------------------------------------------------------------------------
:: Pause if launched by double-click (interactive window)
::
:: When a user double-clicks the .bat file, the window closes immediately
:: after execution. This pause lets them read the output. When run from an
:: existing cmd.exe session, cmdcmdline contains the command typed, which
:: won't match the pattern below, so the pause is skipped.
:: ---------------------------------------------------------------------------
echo %cmdcmdline% | findstr /i /c:"/c" >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo.
    echo [download_model] Press any key to close this window ...
    pause >nul
)

exit /b %PS_EXIT%
