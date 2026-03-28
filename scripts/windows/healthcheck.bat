@echo off
:: =============================================================================
:: healthcheck.bat -- Verify vLLM and OpenClaw containers are healthy
::
:: Checks:
::   1. Container runtime (docker or podman) is available
::   2. Container network democlaw-net exists
::   3. vLLM container is running
::   4. vLLM /health endpoint responds HTTP 200
::   5. vLLM /v1/models endpoint lists at least one model
::   6. OpenClaw container is running (unless --vllm-only)
::   7. OpenClaw dashboard responds HTTP 2xx (unless --vllm-only)
::
:: Exit codes:
::   0 -- All checks passed (or only warnings)
::   1 -- One or more checks failed
::
:: Usage:
::   scripts\windows\healthcheck.bat
::   scripts\windows\healthcheck.bat --vllm-only
::   set CONTAINER_RUNTIME=podman && scripts\windows\healthcheck.bat
:: =============================================================================
setlocal EnableDelayedExpansion

:: ---------------------------------------------------------------------------
:: ANSI color helpers
:: ---------------------------------------------------------------------------
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "RED=%ESC%[31m"
set "GREEN=%ESC%[32m"
set "YELLOW=%ESC%[33m"
set "CYAN=%ESC%[36m"
set "NC=%ESC%[0m"

:: ---------------------------------------------------------------------------
:: Parse arguments
:: ---------------------------------------------------------------------------
set "VLLM_ONLY=false"
for %%a in (%*) do (
    if "%%a"=="--vllm-only" set "VLLM_ONLY=true"
    if "%%a"=="--help"      goto :show_help
    if "%%a"=="-h"          goto :show_help
)

:: ---------------------------------------------------------------------------
:: Resolve project root
:: ---------------------------------------------------------------------------
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%i in ("%SCRIPT_DIR%\..\..") do set "PROJECT_ROOT=%%~fi"

:: ---------------------------------------------------------------------------
:: Load .env file if present
:: ---------------------------------------------------------------------------
set "ENV_FILE=%PROJECT_ROOT%\.env"
if exist "%ENV_FILE%" (
    for /f "usebackq tokens=1,* delims==" %%a in ("%ENV_FILE%") do (
        set "line=%%a"
        if not "!line:~0,1!"=="#" (
            if not "%%a"=="" (
                if not "%%b"=="" (
                    set "%%a=%%b"
                )
            )
        )
    )
)

:: ---------------------------------------------------------------------------
:: Defaults
:: ---------------------------------------------------------------------------
if not defined VLLM_CONTAINER_NAME    set "VLLM_CONTAINER_NAME=democlaw-vllm"
if not defined OPENCLAW_CONTAINER_NAME set "OPENCLAW_CONTAINER_NAME=democlaw-openclaw"
if not defined DEMOCLAW_NETWORK        set "DEMOCLAW_NETWORK=democlaw-net"
if not defined VLLM_HOST_PORT          set "VLLM_HOST_PORT=8000"
if not defined OPENCLAW_HOST_PORT      set "OPENCLAW_HOST_PORT=18789"
if not defined MODEL_NAME              set "MODEL_NAME=Qwen/Qwen3.5-9B-AWQ"
if not defined HEALTHCHECK_CURL_TIMEOUT set "HEALTHCHECK_CURL_TIMEOUT=10"

set "VLLM_BASE_URL=http://localhost:%VLLM_HOST_PORT%"
set "OPENCLAW_URL=http://localhost:%OPENCLAW_HOST_PORT%"

:: ---------------------------------------------------------------------------
:: Result counters
:: ---------------------------------------------------------------------------
set /a "CHECKS_TOTAL=0"
set /a "CHECKS_PASSED=0"
set /a "CHECKS_FAILED=0"
set /a "CHECKS_WARNED=0"

echo.
echo ======================================
echo   DemoClaw Health Check
echo ======================================
echo.

:: ---------------------------------------------------------------------------
:: 1. Container runtime
:: ---------------------------------------------------------------------------
echo %CYAN%[healthcheck] Checking container runtime ...%NC%
call :detect_runtime
if errorlevel 1 (
    call :record_fail "Container runtime" "No container runtime found (docker or podman)"
    goto :print_summary
)
for /f "tokens=*" %%v in ('%RUNTIME% --version 2^>nul') do (
    set "RT_VER=%%v"
    goto :got_rt_ver
)
:got_rt_ver
call :record_pass "Container runtime" "%RUNTIME% available (!RT_VER!)"

:: ---------------------------------------------------------------------------
:: 2. Network
:: ---------------------------------------------------------------------------
echo %CYAN%[healthcheck] Checking container network ...%NC%
%RUNTIME% network inspect "%DEMOCLAW_NETWORK%" >nul 2>&1
if errorlevel 1 (
    call :record_fail "Container network" "'%DEMOCLAW_NETWORK%' not found"
) else (
    call :record_pass "Container network" "'%DEMOCLAW_NETWORK%' exists"
)

:: ---------------------------------------------------------------------------
:: 3. vLLM container state
:: ---------------------------------------------------------------------------
echo %CYAN%[healthcheck] Checking vLLM service ...%NC%
call :check_container_running "%VLLM_CONTAINER_NAME%" "vLLM"
set "VLLM_CONTAINER_OK=!_CONTAINER_OK!"

:: ---------------------------------------------------------------------------
:: 4. vLLM /health endpoint
:: ---------------------------------------------------------------------------
echo %CYAN%[healthcheck] Checking vLLM health endpoint ...%NC%
set "VLLM_HEALTHY=false"
set "HTTP_CODE=000"
for /f "tokens=*" %%c in ('curl -sf -o nul -w "%%%%{http_code}" --max-time %HEALTHCHECK_CURL_TIMEOUT% "%VLLM_BASE_URL%/health" 2^>nul') do set "HTTP_CODE=%%c"
if "!HTTP_CODE!"=="200" (
    call :record_pass "vLLM /health endpoint" "HTTP 200"
    set "VLLM_HEALTHY=true"
) else (
    call :record_fail "vLLM /health endpoint" "HTTP !HTTP_CODE! (expected 200) at %VLLM_BASE_URL%/health"
)

:: ---------------------------------------------------------------------------
:: 5. vLLM /v1/models endpoint
:: ---------------------------------------------------------------------------
if "!VLLM_HEALTHY!"=="true" (
    echo %CYAN%[healthcheck] Checking vLLM /v1/models endpoint ...%NC%
    set "TMPFILE=%TEMP%\democlaw-models-%RANDOM%.json"
    set "HTTP_CODE=000"
    for /f "tokens=*" %%c in ('curl -sf -o "!TMPFILE!" -w "%%%%{http_code}" --max-time %HEALTHCHECK_CURL_TIMEOUT% "%VLLM_BASE_URL%/v1/models" 2^>nul') do set "HTTP_CODE=%%c"

    if "!HTTP_CODE!"=="200" (
        call :record_pass "vLLM /v1/models endpoint" "HTTP 200"
        :: Check if model name appears in response
        findstr /i "%MODEL_NAME%" "!TMPFILE!" >nul 2>&1
        if not errorlevel 1 (
            call :record_pass "vLLM model loaded" "'%MODEL_NAME%' found in /v1/models"
        ) else (
            call :record_warn "vLLM model loaded" "'%MODEL_NAME%' not confirmed in /v1/models response"
        )
    ) else (
        call :record_fail "vLLM /v1/models endpoint" "HTTP !HTTP_CODE! (expected 200)"
    )
    if exist "!TMPFILE!" del /f /q "!TMPFILE!" >nul 2>&1
)

if "%VLLM_ONLY%"=="true" goto :print_summary

:: ---------------------------------------------------------------------------
:: 6. OpenClaw container state
:: ---------------------------------------------------------------------------
echo %CYAN%[healthcheck] Checking OpenClaw service ...%NC%
call :check_container_running "%OPENCLAW_CONTAINER_NAME%" "OpenClaw"

:: ---------------------------------------------------------------------------
:: 7. OpenClaw dashboard
:: ---------------------------------------------------------------------------
echo %CYAN%[healthcheck] Checking OpenClaw dashboard on port %OPENCLAW_HOST_PORT% ...%NC%
set "TMPFILE=%TEMP%\democlaw-openclaw-%RANDOM%.html"
set "HTTP_CODE=000"
for /f "tokens=*" %%c in ('curl -sf -o "!TMPFILE!" -w "%%%%{http_code}" --max-time %HEALTHCHECK_CURL_TIMEOUT% "%OPENCLAW_URL%/" 2^>nul') do set "HTTP_CODE=%%c"

if "!HTTP_CODE!"=="000" (
    call :record_fail "OpenClaw dashboard reachable" "No response at %OPENCLAW_URL% (port %OPENCLAW_HOST_PORT%)"
) else (
    set /a "CODE_NUM=!HTTP_CODE!"
    if !CODE_NUM! geq 200 if !CODE_NUM! lss 400 (
        call :record_pass "OpenClaw dashboard reachable" "HTTP !HTTP_CODE! at %OPENCLAW_URL%"
        :: Check for HTML content
        if exist "!TMPFILE!" (
            findstr /i /c:"<html" /c:"<!doctype" /c:"<head" /c:"<body" /c:"<div" "!TMPFILE!" >nul 2>&1
            if not errorlevel 1 (
                call :record_pass "OpenClaw dashboard content" "HTML content verified"
            ) else (
                call :record_pass "OpenClaw dashboard content" "Non-empty response received"
            )
        )
    ) else (
        call :record_fail "OpenClaw dashboard reachable" "HTTP !HTTP_CODE! (expected 2xx/3xx) at %OPENCLAW_URL%"
    )
)
if exist "!TMPFILE!" del /f /q "!TMPFILE!" >nul 2>&1

:print_summary
echo.
echo --------------------------------------
echo   Results: %CHECKS_PASSED% passed, %CHECKS_FAILED% failed, %CHECKS_WARNED% warnings (%CHECKS_TOTAL% total)
echo --------------------------------------

if %CHECKS_FAILED% gtr 0 (
    echo %RED%  Overall: UNHEALTHY%NC%
    echo.
    exit /b 1
) else if %CHECKS_WARNED% gtr 0 (
    echo %YELLOW%  Overall: DEGRADED%NC%
    echo.
    exit /b 0
) else (
    echo %GREEN%  Overall: HEALTHY%NC%
    echo.
    exit /b 0
)

:show_help
echo Usage: %~nx0 [--vllm-only] [--help]
echo.
echo Options:
echo   --vllm-only   Only check the vLLM service (skip OpenClaw)
echo   --help        Show this help message
exit /b 0

:: ===========================================================================
:: Subroutines
:: ===========================================================================

:detect_runtime
if defined CONTAINER_RUNTIME (
    where "%CONTAINER_RUNTIME%" >nul 2>&1
    if errorlevel 1 exit /b 1
    set "RUNTIME=%CONTAINER_RUNTIME%"
    exit /b 0
)
where docker >nul 2>&1
if not errorlevel 1 ( set "RUNTIME=docker" & exit /b 0 )
where podman >nul 2>&1
if not errorlevel 1 ( set "RUNTIME=podman" & exit /b 0 )
exit /b 1

:check_container_running
set "_CNAME=%~1"
set "_LABEL=%~2"
set "_CONTAINER_OK=false"
%RUNTIME% container inspect "%_CNAME%" >nul 2>&1
if errorlevel 1 (
    call :record_fail "%_LABEL% container" "Container '%_CNAME%' does not exist"
    exit /b 0
)
for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" "%_CNAME%" 2^>nul') do set "_CSTATE=%%s"
if "!_CSTATE!"=="running" (
    call :record_pass "%_LABEL% container" "'%_CNAME%' is running"
    set "_CONTAINER_OK=true"
) else (
    call :record_fail "%_LABEL% container" "'%_CNAME%' state is '!_CSTATE!' (expected: running)"
)
exit /b 0

:record_pass
set /a "CHECKS_TOTAL=CHECKS_TOTAL+1"
set /a "CHECKS_PASSED=CHECKS_PASSED+1"
echo %GREEN%  [PASS]%NC% %~1 -- %~2
exit /b 0

:record_fail
set /a "CHECKS_TOTAL=CHECKS_TOTAL+1"
set /a "CHECKS_FAILED=CHECKS_FAILED+1"
echo %RED%  [FAIL]%NC% %~1 -- %~2
exit /b 0

:record_warn
set /a "CHECKS_TOTAL=CHECKS_TOTAL+1"
set /a "CHECKS_WARNED=CHECKS_WARNED+1"
echo %YELLOW%  [WARN]%NC% %~1 -- %~2
exit /b 0

endlocal
