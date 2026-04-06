@echo off
setlocal enabledelayedexpansion
REM =============================================================================
REM benchmark-tps.bat — Token generation throughput benchmark for DemoClaw LLM
REM
REM Windows wrapper that delegates to the Python benchmark driver at
REM scripts/benchmark_tps.py. All configuration is via environment variables
REM (see benchmark_tps.py for full documentation).
REM
REM Usage:
REM   scripts\benchmark-tps.bat
REM   set BENCH_MIN_TPS=20 && scripts\benchmark-tps.bat
REM   set HARDWARE_PROFILE=dgx_spark && scripts\benchmark-tps.bat
REM   set BENCH_OUTPUT_FORMAT=json && scripts\benchmark-tps.bat
REM
REM Requires: curl, python3 (both on PATH)
REM =============================================================================

REM ---------------------------------------------------------------------------
REM Locate python
REM ---------------------------------------------------------------------------
set "PY=python3"
where python3 >nul 2>&1 || (
    where python >nul 2>&1 && set "PY=python" || (
        echo [benchmark] ERROR: python3 is required but not found on PATH. >&2
        exit /b 1
    )
)

where curl >nul 2>&1 || (
    echo [benchmark] ERROR: curl is required but not found on PATH. >&2
    exit /b 1
)

REM ---------------------------------------------------------------------------
REM Resolve script directory (handles being called from any cwd)
REM ---------------------------------------------------------------------------
set "SCRIPT_DIR=%~dp0"

REM ---------------------------------------------------------------------------
REM Delegate to the canonical Python benchmark driver
REM ---------------------------------------------------------------------------
%PY% "%SCRIPT_DIR%benchmark_tps.py" %*
exit /b %ERRORLEVEL%
