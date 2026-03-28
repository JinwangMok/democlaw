@echo off
:: =============================================================================
:: download-models.bat — Windows batch wrapper for model pre-download
::
:: Delegates to download-models.ps1 for actual processing. This wrapper lets
:: users invoke the download from cmd.exe or double-click without needing to
:: remember PowerShell execution policy flags.
::
:: Usage:
::   scripts\download-models.bat
::   scripts\download-models.bat Qwen/Qwen3-4B-AWQ
::
:: All arguments are forwarded to download-models.ps1 as-is.
:: See download-models.ps1 for the full parameter list.
:: =============================================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-models.ps1" %*
exit /b %ERRORLEVEL%
