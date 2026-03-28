@echo off
:: =============================================================================
:: stop.bat -- Stop and remove DemoClaw containers and optionally the network
::
:: Usage:
::   scripts\windows\stop.bat
::   set REMOVE_NETWORK=true && scripts\windows\stop.bat
::   set CONTAINER_RUNTIME=podman && scripts\windows\stop.bat
:: =============================================================================
setlocal EnableDelayedExpansion

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
if not defined REMOVE_NETWORK          set "REMOVE_NETWORK=false"

:: ---------------------------------------------------------------------------
:: Detect container runtime
:: ---------------------------------------------------------------------------
call :detect_runtime
if errorlevel 1 (
    echo [stop] ERROR: No container runtime found. Install Docker Desktop or Podman Desktop.
    exit /b 1
)

echo [stop] Stopping DemoClaw containers ...

:: ---------------------------------------------------------------------------
:: Stop OpenClaw first, then vLLM
:: ---------------------------------------------------------------------------
call :stop_container "%OPENCLAW_CONTAINER_NAME%"
call :stop_container "%VLLM_CONTAINER_NAME%"

:: ---------------------------------------------------------------------------
:: Optionally remove the shared network
:: ---------------------------------------------------------------------------
if /i "%REMOVE_NETWORK%"=="true" (
    %RUNTIME% network inspect "%DEMOCLAW_NETWORK%" >nul 2>&1
    if not errorlevel 1 (
        echo [stop] Removing network '%DEMOCLAW_NETWORK%' ...
        %RUNTIME% network rm "%DEMOCLAW_NETWORK%" >nul 2>&1
        if errorlevel 1 (
            echo [stop] WARNING: Could not remove network '%DEMOCLAW_NETWORK%' -- it may still have connected containers.
        ) else (
            echo [stop] Network '%DEMOCLAW_NETWORK%' removed.
        )
    ) else (
        echo [stop] Network '%DEMOCLAW_NETWORK%' does not exist -- skipping.
    )
)

echo [stop] Done.
exit /b 0

:: ===========================================================================
:: Subroutines
:: ===========================================================================

:detect_runtime
if defined CONTAINER_RUNTIME (
    where "%CONTAINER_RUNTIME%" >nul 2>&1
    if errorlevel 1 (
        echo [stop] ERROR: CONTAINER_RUNTIME='%CONTAINER_RUNTIME%' not found in PATH.
        exit /b 1
    )
    set "RUNTIME=%CONTAINER_RUNTIME%"
    exit /b 0
)
where docker >nul 2>&1
if not errorlevel 1 (
    set "RUNTIME=docker"
    exit /b 0
)
where podman >nul 2>&1
if not errorlevel 1 (
    set "RUNTIME=podman"
    exit /b 0
)
exit /b 1

:stop_container
set "_CNAME=%~1"
%RUNTIME% container inspect "%_CNAME%" >nul 2>&1
if errorlevel 1 (
    echo [stop] Container '%_CNAME%' does not exist -- skipping.
    exit /b 0
)
echo [stop] Stopping and removing container '%_CNAME%' ...
%RUNTIME% rm -f "%_CNAME%" >nul 2>&1
if errorlevel 1 (
    echo [stop] WARNING: Could not remove container '%_CNAME%'.
) else (
    echo [stop] Container '%_CNAME%' removed.
)
exit /b 0

endlocal
