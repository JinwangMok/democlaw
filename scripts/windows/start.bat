@echo off
:: =============================================================================
:: start.bat -- Main orchestrator for the DemoClaw stack on Windows
::
:: Launches both the vLLM server and OpenClaw containers using whichever
:: container runtime (docker or podman) is available on the host.
::
:: Auto-detection priority:
::   1. %CONTAINER_RUNTIME% env var  (explicit override)
::   2. docker                       (if in PATH)
::   3. podman                       (if in PATH)
::
:: Usage:
::   scripts\windows\start.bat
::   set CONTAINER_RUNTIME=podman && scripts\windows\start.bat
::
:: Requires: Windows 10+, NVIDIA GPU with CUDA drivers, Docker Desktop or
::           Podman Desktop with GPU support enabled.
:: =============================================================================
setlocal EnableDelayedExpansion

:: ---------------------------------------------------------------------------
:: ANSI color helpers (Windows 10 1511+ with VT processing)
:: ---------------------------------------------------------------------------
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "RED=%ESC%[31m"
set "GREEN=%ESC%[32m"
set "YELLOW=%ESC%[33m"
set "CYAN=%ESC%[36m"
set "NC=%ESC%[0m"

:: ---------------------------------------------------------------------------
:: Resolve paths
:: ---------------------------------------------------------------------------
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%i in ("%SCRIPT_DIR%\..\..") do set "PROJECT_ROOT=%%~fi"

:: ---------------------------------------------------------------------------
:: Load .env file if present
:: ---------------------------------------------------------------------------
set "ENV_FILE=%PROJECT_ROOT%\.env"
if exist "%ENV_FILE%" (
    echo %CYAN%[start] Loading environment from %ENV_FILE%%NC%
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
:: Detect container runtime
:: ---------------------------------------------------------------------------
if defined CONTAINER_RUNTIME (
    where "%CONTAINER_RUNTIME%" >nul 2>&1
    if errorlevel 1 (
        echo %RED%[start] ERROR: CONTAINER_RUNTIME='%CONTAINER_RUNTIME%' is set but not found in PATH.%NC%
        exit /b 1
    )
    set "RUNTIME=%CONTAINER_RUNTIME%"
) else (
    where docker >nul 2>&1
    if not errorlevel 1 (
        set "RUNTIME=docker"
    ) else (
        where podman >nul 2>&1
        if not errorlevel 1 (
            set "RUNTIME=podman"
        ) else (
            echo %RED%[start] ERROR: No container runtime found. Install Docker Desktop or Podman Desktop.%NC%
            exit /b 1
        )
    )
)

set "RUNTIME_IS_PODMAN=false"
if "%RUNTIME%"=="podman" set "RUNTIME_IS_PODMAN=true"

echo %CYAN%[start] ========================================================%NC%
echo %CYAN%[start]   DemoClaw Stack -- Container Runtime: %RUNTIME%%NC%
echo %CYAN%[start]   Podman mode: %RUNTIME_IS_PODMAN%%NC%
echo %CYAN%[start] ========================================================%NC%

:: ---------------------------------------------------------------------------
:: Validate NVIDIA GPU
:: ---------------------------------------------------------------------------
echo %CYAN%[start] Validating NVIDIA GPU ...%NC%
where nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo %RED%[start] ERROR: nvidia-smi not found in PATH.%NC%
    echo %RED%[start]   Install NVIDIA drivers and ensure nvidia-smi is in PATH.%NC%
    echo %RED%[start]   Download: https://www.nvidia.com/Download/index.aspx%NC%
    exit /b 1
)
nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo %RED%[start] ERROR: nvidia-smi failed. Check that NVIDIA drivers are correctly installed.%NC%
    exit /b 1
)
echo %GREEN%[start] NVIDIA GPU validated.%NC%

:: ---------------------------------------------------------------------------
:: Phase 1: Start vLLM
:: ---------------------------------------------------------------------------
echo %CYAN%[start]%NC%
echo %CYAN%[start] --- Phase 1: Starting vLLM server ----%NC%

start "DemoClaw-vLLM" /b cmd /c ""%SCRIPT_DIR%\start-vllm.bat" > "%TEMP%\democlaw-vllm.log" 2>&1"
set "VLLM_EXIT=0"

echo %CYAN%[start] vLLM start launched in background. Waiting 5 seconds before starting OpenClaw ...%NC%
timeout /t 5 >nul 2>&1

:: ---------------------------------------------------------------------------
:: Phase 2: Start OpenClaw
:: ---------------------------------------------------------------------------
echo %CYAN%[start]%NC%
echo %CYAN%[start] --- Phase 2: Starting OpenClaw ----%NC%

start "DemoClaw-OpenClaw" /b cmd /c ""%SCRIPT_DIR%\start-openclaw.bat" > "%TEMP%\democlaw-openclaw.log" 2>&1"
set "OPENCLAW_EXIT=0"

:: ---------------------------------------------------------------------------
:: Wait for background processes to settle (poll container states)
:: ---------------------------------------------------------------------------
echo %CYAN%[start] Waiting for both containers to become ready ...%NC%

set /a "wait_elapsed=0"
set /a "wait_max=360"
set /a "wait_interval=10"

:wait_containers_loop
if %wait_elapsed% geq %wait_max% goto :wait_timeout

:: Check vLLM container state
set "VLLM_STATE=missing"
for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" "democlaw-vllm" 2^>nul') do set "VLLM_STATE=%%s"

:: Check OpenClaw container state
set "OPENCLAW_STATE=missing"
for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" "democlaw-openclaw" 2^>nul') do set "OPENCLAW_STATE=%%s"

echo %CYAN%[start]   vLLM: !VLLM_STATE!  OpenClaw: !OPENCLAW_STATE!  (%wait_elapsed%/%wait_max%s)%NC%

:: Exit early if either container has died
if "!VLLM_STATE!"=="exited" (
    set "VLLM_EXIT=1"
    goto :after_wait
)
if "!VLLM_STATE!"=="dead" (
    set "VLLM_EXIT=1"
    goto :after_wait
)
if "!OPENCLAW_STATE!"=="exited" (
    set "OPENCLAW_EXIT=1"
    goto :after_wait
)
if "!OPENCLAW_STATE!"=="dead" (
    set "OPENCLAW_EXIT=1"
    goto :after_wait
)

:: Both running -- quick health check to see if APIs are up
if "!VLLM_STATE!"=="running" if "!OPENCLAW_STATE!"=="running" (
    curl -sf "http://localhost:%VLLM_HOST_PORT:-8000%/health" >nul 2>&1
    if not errorlevel 1 (
        curl -sf -o nul "http://localhost:%OPENCLAW_HOST_PORT:-18789%" >nul 2>&1
        if not errorlevel 1 goto :after_wait
    )
)

timeout /t %wait_interval% >nul 2>&1
set /a "wait_elapsed=wait_elapsed+wait_interval"
goto :wait_containers_loop

:wait_timeout
echo %YELLOW%[start] Wait timeout reached (%wait_max%s). Proceeding to healthcheck.%NC%

:after_wait

:: ---------------------------------------------------------------------------
:: Phase 3: Comprehensive healthcheck
:: ---------------------------------------------------------------------------
echo %CYAN%[start]%NC%
echo %CYAN%[start] --- Phase 3: Comprehensive healthcheck ----%NC%

set "HEALTHCHECK_EXIT=0"

if %VLLM_EXIT% neq 0 (
    set "HEALTHCHECK_EXIT=1"
    echo %YELLOW%[start] HEALTHCHECK SKIP: vLLM failed to start (exit code %VLLM_EXIT%).%NC%
    echo %YELLOW%[start] vLLM log: %TEMP%\democlaw-vllm.log%NC%
    type "%TEMP%\democlaw-vllm.log" 2>nul
    goto :final_summary
)
if %OPENCLAW_EXIT% neq 0 (
    set "HEALTHCHECK_EXIT=1"
    echo %YELLOW%[start] HEALTHCHECK SKIP: OpenClaw failed to start (exit code %OPENCLAW_EXIT%).%NC%
    echo %YELLOW%[start] OpenClaw log: %TEMP%\democlaw-openclaw.log%NC%
    type "%TEMP%\democlaw-openclaw.log" 2>nul
    goto :final_summary
)

echo %CYAN%[start] Both containers running; running comprehensive healthcheck ...%NC%
call "%SCRIPT_DIR%\healthcheck.bat"
set "HEALTHCHECK_EXIT=!errorlevel!"

if %HEALTHCHECK_EXIT% equ 0 (
    echo %GREEN%[start] HEALTHCHECK PASS: All services are healthy.%NC%
) else (
    echo %YELLOW%[start] HEALTHCHECK FAIL: One or more checks did not pass.%NC%
    echo %YELLOW%[start]   Re-run at any time with: scripts\windows\healthcheck.bat%NC%
)

:final_summary
echo %CYAN%[start]%NC%
echo %CYAN%[start] ========================================================%NC%

if not defined VLLM_HOST_PORT   set "VLLM_HOST_PORT=8000"
if not defined OPENCLAW_HOST_PORT set "OPENCLAW_HOST_PORT=18789"

if %VLLM_EXIT% equ 0 if %OPENCLAW_EXIT% equ 0 if %HEALTHCHECK_EXIT% equ 0 (
    echo %GREEN%[start]   Both services started successfully!%NC%
    echo %GREEN%[start]   vLLM API     : http://localhost:%VLLM_HOST_PORT%/v1%NC%
    echo %GREEN%[start]   OpenClaw UI  : http://localhost:%OPENCLAW_HOST_PORT%%NC%
    echo %GREEN%[start]   Runtime      : %RUNTIME%%NC%
    echo %GREEN%[start] ========================================================%NC%
    exit /b 0
) else (
    if %VLLM_EXIT% neq 0    echo %YELLOW%[start] WARNING: vLLM start script exited with code %VLLM_EXIT%%NC%
    if %OPENCLAW_EXIT% neq 0 echo %YELLOW%[start] WARNING: OpenClaw start script exited with code %OPENCLAW_EXIT%%NC%
    if %HEALTHCHECK_EXIT% neq 0 echo %YELLOW%[start] WARNING: Healthcheck exited with code %HEALTHCHECK_EXIT%%NC%
    echo %RED%[start] ========================================================%NC%
    exit /b 1
)

endlocal
