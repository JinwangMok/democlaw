@echo off
:: =============================================================================
:: download-model.bat -- Pre-download GGUF model weights (Windows)
::
:: Downloads Qwen3.5-9B-Q4_K_M.gguf from HuggingFace so llama.cpp startup
:: is fast. Delegates to reference\download-model.ps1 for actual processing.
::
:: Usage:
::   scripts\download-model.bat
::   scripts\download-model.bat -ModelDir "D:\models"
::   scripts\download-model.bat -HfToken "hf_xxx"
::
:: All arguments are forwarded to download-model.ps1 as-is.
:: =============================================================================
setlocal

echo [download-model] ========================================================
echo [download-model]   DemoClaw - Model Pre-Download (GGUF)
echo [download-model] ========================================================
echo.

:: Verify PowerShell is available
where powershell.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [download-model] ERROR: PowerShell is not available. >&2
    echo [download-model] Use WSL2 with: ./scripts/download-model.sh >&2
    exit /b 1
)

:: Verify the PowerShell script exists
if not exist "%~dp0reference\download-model.ps1" (
    echo [download-model] ERROR: reference\download-model.ps1 not found in %~dp0 >&2
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0reference\download-model.ps1" %*
set "PS_EXIT=%ERRORLEVEL%"

if %PS_EXIT% equ 0 (
    echo.
    echo [download-model] Download and verification completed successfully.
    echo [download-model] Start the stack with: scripts\start.bat
) else (
    echo.
    echo [download-model] ERROR: Download failed (exit code: %PS_EXIT%). >&2
)

exit /b %PS_EXIT%
