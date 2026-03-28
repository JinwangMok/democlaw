@echo off
:: =============================================================================
:: start-openclaw.bat -- Launch the OpenClaw container with web dashboard
::
:: The OpenClaw dashboard is published to the host on port 18789 (configurable
:: via OPENCLAW_HOST_PORT).
::
:: Usage:
::   scripts\windows\start-openclaw.bat
::   set CONTAINER_RUNTIME=podman && scripts\windows\start-openclaw.bat
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
    echo [start-openclaw] Loading environment from %ENV_FILE%
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
:: Configurable defaults
:: ---------------------------------------------------------------------------
if not defined OPENCLAW_CONTAINER_NAME set "OPENCLAW_CONTAINER_NAME=democlaw-openclaw"
if not defined DEMOCLAW_NETWORK        set "DEMOCLAW_NETWORK=democlaw-net"
if not defined OPENCLAW_IMAGE_TAG      set "OPENCLAW_IMAGE_TAG=democlaw/openclaw:latest"
if not defined OPENCLAW_PORT           set "OPENCLAW_PORT=18789"
if not defined OPENCLAW_HOST_PORT      set "OPENCLAW_HOST_PORT=18789"
if not defined VLLM_BASE_URL           set "VLLM_BASE_URL=http://vllm:8000/v1"
if not defined VLLM_API_KEY            set "VLLM_API_KEY=EMPTY"
if not defined VLLM_MODEL_NAME         set "VLLM_MODEL_NAME=Qwen/Qwen3.5-9B-AWQ"
if not defined VLLM_CONTAINER_NAME     set "VLLM_CONTAINER_NAME=democlaw-vllm"
if not defined OPENCLAW_HEALTH_TIMEOUT set "OPENCLAW_HEALTH_TIMEOUT=120"
if not defined VLLM_HEALTH_RETRIES     set "VLLM_HEALTH_RETRIES=60"
if not defined VLLM_HEALTH_INTERVAL    set "VLLM_HEALTH_INTERVAL=5"

set "CONTAINER_NAME=%OPENCLAW_CONTAINER_NAME%"
set "NETWORK_NAME=%DEMOCLAW_NETWORK%"
set "IMAGE_TAG=%OPENCLAW_IMAGE_TAG%"

:: ---------------------------------------------------------------------------
:: Detect container runtime
:: ---------------------------------------------------------------------------
call :detect_runtime
if errorlevel 1 (
    echo [start-openclaw] ERROR: No container runtime found. Install Docker Desktop or Podman Desktop.
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Ensure shared network exists
:: ---------------------------------------------------------------------------
call :ensure_network "%NETWORK_NAME%"

:: ---------------------------------------------------------------------------
:: Verify vLLM container membership (warning only, not fatal)
:: ---------------------------------------------------------------------------
call :verify_vllm_network_membership

:: ---------------------------------------------------------------------------
:: Handle existing container
:: ---------------------------------------------------------------------------
call :handle_existing_container "%CONTAINER_NAME%"
if errorlevel 1 goto :end

:: ---------------------------------------------------------------------------
:: Build image if not present
:: ---------------------------------------------------------------------------
call :build_image "%IMAGE_TAG%" "%PROJECT_ROOT%\openclaw"
if errorlevel 1 (
    echo [start-openclaw] ERROR: Failed to build image '%IMAGE_TAG%'.
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Launch OpenClaw container
:: ---------------------------------------------------------------------------
echo [start-openclaw] Starting OpenClaw container '%CONTAINER_NAME%' ...
echo [start-openclaw]   Dashboard port  : localhost:%OPENCLAW_HOST_PORT% -^> container:%OPENCLAW_PORT%
echo [start-openclaw]   vLLM endpoint   : %VLLM_BASE_URL%
echo [start-openclaw]   Model           : %VLLM_MODEL_NAME%
echo [start-openclaw]   Network         : %NETWORK_NAME%

%RUNTIME% run -d ^
    --name "%CONTAINER_NAME%" ^
    --network "%NETWORK_NAME%" ^
    --hostname openclaw ^
    --network-alias openclaw ^
    --restart unless-stopped ^
    -p "%OPENCLAW_HOST_PORT%:%OPENCLAW_PORT%" ^
    -e "VLLM_BASE_URL=%VLLM_BASE_URL%" ^
    -e "VLLM_API_KEY=%VLLM_API_KEY%" ^
    -e "VLLM_MODEL_NAME=%VLLM_MODEL_NAME%" ^
    -e "OPENCLAW_PORT=%OPENCLAW_PORT%" ^
    -e "OPENAI_API_BASE=%VLLM_BASE_URL%" ^
    -e "OPENAI_BASE_URL=%VLLM_BASE_URL%" ^
    -e "OPENAI_API_KEY=%VLLM_API_KEY%" ^
    -e "OPENAI_MODEL=%VLLM_MODEL_NAME%" ^
    -e "OPENCLAW_LLM_PROVIDER=openai-compatible" ^
    -e "OPENCLAW_LLM_BASE_URL=%VLLM_BASE_URL%" ^
    -e "OPENCLAW_LLM_API_KEY=%VLLM_API_KEY%" ^
    -e "OPENCLAW_LLM_MODEL=%VLLM_MODEL_NAME%" ^
    -e "VLLM_HEALTH_RETRIES=%VLLM_HEALTH_RETRIES%" ^
    -e "VLLM_HEALTH_INTERVAL=%VLLM_HEALTH_INTERVAL%" ^
    --cap-drop ALL ^
    --security-opt no-new-privileges ^
    --read-only ^
    --tmpfs /tmp:rw,noexec,nosuid ^
    --tmpfs /app/config:rw,noexec,nosuid ^
    "%IMAGE_TAG%"

if errorlevel 1 (
    echo [start-openclaw] ERROR: Failed to start container '%CONTAINER_NAME%'.
    exit /b 1
)

echo [start-openclaw] Container '%CONTAINER_NAME%' started successfully.

:: ---------------------------------------------------------------------------
:: Wait for OpenClaw dashboard
:: ---------------------------------------------------------------------------
set "DASHBOARD_URL=http://localhost:%OPENCLAW_HOST_PORT%"
echo [start-openclaw] Waiting for OpenClaw dashboard at %DASHBOARD_URL% (timeout: %OPENCLAW_HEALTH_TIMEOUT%s) ...

set /a "elapsed=0"
set /a "interval=3"

:wait_dashboard_loop
if %elapsed% geq %OPENCLAW_HEALTH_TIMEOUT% goto :dashboard_timeout

:: Check container hasn't crashed
for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" "%CONTAINER_NAME%" 2^>nul') do set "CSTATE=%%s"
if "!CSTATE!"=="exited" (
    echo [start-openclaw] ERROR: Container '%CONTAINER_NAME%' has stopped. Check logs:
    echo [start-openclaw]   %RUNTIME% logs %CONTAINER_NAME%
    exit /b 1
)
if "!CSTATE!"=="dead" (
    echo [start-openclaw] ERROR: Container '%CONTAINER_NAME%' is dead. Check logs:
    echo [start-openclaw]   %RUNTIME% logs %CONTAINER_NAME%
    exit /b 1
)

curl -sf -o nul "%DASHBOARD_URL%" 2>nul
if not errorlevel 1 (
    echo.
    echo [start-openclaw] =============================================
    echo [start-openclaw]   OpenClaw dashboard is ready!
    echo [start-openclaw]   URL: %DASHBOARD_URL%
    echo [start-openclaw] =============================================
    exit /b 0
)

timeout /t %interval% >nul 2>&1
set /a "elapsed=elapsed+interval"
echo [start-openclaw]   ... waiting (%elapsed%/%OPENCLAW_HEALTH_TIMEOUT%s)
goto :wait_dashboard_loop

:dashboard_timeout
echo [start-openclaw] WARNING: OpenClaw dashboard did not respond within %OPENCLAW_HEALTH_TIMEOUT%s.
echo [start-openclaw] The container is still running -- it may be waiting for vLLM.
echo [start-openclaw]   Dashboard URL : %DASHBOARD_URL%
echo [start-openclaw]   Check logs    : %RUNTIME% logs -f %CONTAINER_NAME%
exit /b 1

goto :end

:: ===========================================================================
:: Subroutines
:: ===========================================================================

:detect_runtime
if defined CONTAINER_RUNTIME (
    where "%CONTAINER_RUNTIME%" >nul 2>&1
    if errorlevel 1 (
        echo [start-openclaw] ERROR: CONTAINER_RUNTIME='%CONTAINER_RUNTIME%' not found in PATH.
        exit /b 1
    )
    set "RUNTIME=%CONTAINER_RUNTIME%"
    echo [start-openclaw] Using container runtime: %RUNTIME%
    exit /b 0
)
where docker >nul 2>&1
if not errorlevel 1 (
    set "RUNTIME=docker"
    echo [start-openclaw] Detected container runtime: docker
    exit /b 0
)
where podman >nul 2>&1
if not errorlevel 1 (
    set "RUNTIME=podman"
    echo [start-openclaw] Detected container runtime: podman
    exit /b 0
)
exit /b 1

:ensure_network
set "_NET=%~1"
%RUNTIME% network inspect "%_NET%" >nul 2>&1
if errorlevel 1 (
    echo [start-openclaw] Creating network '%_NET%' ...
    %RUNTIME% network create "%_NET%"
    if errorlevel 1 (
        echo [start-openclaw] ERROR: Failed to create network '%_NET%'.
        exit /b 1
    )
) else (
    echo [start-openclaw] Network '%_NET%' already exists.
)
exit /b 0

:verify_vllm_network_membership
echo [start-openclaw] Verifying vLLM endpoint reachability on network '%NETWORK_NAME%' ...
echo [start-openclaw]   vLLM container : %VLLM_CONTAINER_NAME%
echo [start-openclaw]   vLLM endpoint  : %VLLM_BASE_URL%

%RUNTIME% container inspect "%VLLM_CONTAINER_NAME%" >nul 2>&1
if errorlevel 1 (
    echo [start-openclaw] WARNING: vLLM container '%VLLM_CONTAINER_NAME%' does not exist.
    echo [start-openclaw] OpenClaw will start but wait for vLLM to become available.
    echo [start-openclaw] Start vLLM with: scripts\windows\start-vllm.bat
    exit /b 0
)

for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" "%VLLM_CONTAINER_NAME%" 2^>nul') do set "_VSTATE=%%s"
if not "!_VSTATE!"=="running" (
    echo [start-openclaw] WARNING: vLLM container exists but is not running (state: !_VSTATE!).
    echo [start-openclaw] OpenClaw will start and wait for vLLM at: %VLLM_BASE_URL%
    exit /b 0
)

echo [start-openclaw] vLLM container '%VLLM_CONTAINER_NAME%' is running.
echo [start-openclaw] OpenClaw will reach vLLM via: %VLLM_BASE_URL%
exit /b 0

:handle_existing_container
set "_CNAME=%~1"
%RUNTIME% container inspect "%_CNAME%" >nul 2>&1
if errorlevel 1 exit /b 0

for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" "%_CNAME%" 2^>nul') do set "_CSTATE=%%s"
if "!_CSTATE!"=="running" (
    echo [start-openclaw] Container '%_CNAME%' is already running.
    echo [start-openclaw] Dashboard: http://localhost:%OPENCLAW_HOST_PORT%
    echo [start-openclaw] To restart: %RUNTIME% rm -f %_CNAME% ^&^& %~f0
    exit /b 1
)
echo [start-openclaw] Removing stopped container '%_CNAME%' ...
%RUNTIME% rm -f "%_CNAME%" >nul 2>&1
exit /b 0

:build_image
set "_TAG=%~1"
set "_CTX=%~2"
%RUNTIME% image inspect "%_TAG%" >nul 2>&1
if errorlevel 1 (
    echo [start-openclaw] Building image '%_TAG%' from %_CTX% ...
    %RUNTIME% build -t "%_TAG%" "%_CTX%"
    if errorlevel 1 exit /b 1
) else (
    echo [start-openclaw] Image '%_TAG%' already exists. Use '%RUNTIME% rmi %_TAG%' to rebuild.
)
exit /b 0

:end
endlocal
