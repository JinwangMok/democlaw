@echo off
:: =============================================================================
:: download-models.bat — Windows batch wrapper for model pre-download
::
:: Delegates to download-models.ps1 for actual processing. This wrapper lets
:: users invoke the download from cmd.exe or double-click without needing to
:: remember PowerShell execution policy flags.
::
:: Downloads the model and verifies integrity using SHA256 checksums:
::   1. Pre-download: checks cached files against stored .sha256 sidecars
::   2. Post-download: verifies downloaded files for corruption
::   3. Stores checksums: writes .sha256 sidecars for future verification
::
:: Usage:
::   scripts\download-models.bat
::   scripts\download-models.bat Qwen/Qwen3-4B-AWQ
::
:: All arguments are forwarded to download-models.ps1 as-is.
:: See download-models.ps1 for the full parameter list.
:: =============================================================================

setlocal

echo [download-models] Starting model download with SHA256 checksum verification ...
echo [download-models] Delegating to PowerShell for cross-platform checksum support.
echo.

:: Verify PowerShell is available
where powershell.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [download-models] ERROR: PowerShell is not available on this system.
    echo [download-models] PowerShell is required for SHA256 checksum verification.
    echo [download-models] Install PowerShell 5.1+ or use WSL2 with download-models.sh
    exit /b 1
)

:: Verify the PowerShell script exists
if not exist "%~dp0download-models.ps1" (
    echo [download-models] ERROR: download-models.ps1 not found in %~dp0
    echo [download-models] Ensure the DemoClaw scripts directory is intact.
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-models.ps1" %*
set "PS_EXIT=%ERRORLEVEL%"

if %PS_EXIT% equ 0 (
    echo.
    echo [download-models] Model download and checksum verification completed successfully.
) else (
    echo.
    echo [download-models] ERROR: Model download or verification failed (exit code: %PS_EXIT%).
    echo [download-models] Check the output above for details.
    echo [download-models] Common fixes:
    echo [download-models]   - Ensure you have internet connectivity
    echo [download-models]   - Check disk space in the cache directory
    echo [download-models]   - Try deleting the cache and re-running
)

exit /b %PS_EXIT%
