@echo off
REM =============================================================================
REM benchmark.bat — Alias for benchmark-tps.bat
REM
REM Delegates to benchmark-tps.bat which calls the Python benchmark driver.
REM =============================================================================
call "%~dp0benchmark-tps.bat" %*
exit /b %ERRORLEVEL%
