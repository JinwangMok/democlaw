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
:: Phase 0: Build images (synchronous — must complete before containers start)
:: ---------------------------------------------------------------------------
echo %CYAN%[start]%NC%
echo %CYAN%[start] --- Phase 0: Building container images ----%NC%

if not defined VLLM_IMAGE_TAG    set "VLLM_IMAGE_TAG=democlaw/vllm:latest"
if not defined OPENCLAW_IMAGE_TAG set "OPENCLAW_IMAGE_TAG=democlaw/openclaw:latest"

%RUNTIME% image inspect "%VLLM_IMAGE_TAG%" >nul 2>&1
if errorlevel 1 (
    echo %CYAN%[start] Building vLLM image ...%NC%
    %RUNTIME% build -t "%VLLM_IMAGE_TAG%" "%PROJECT_ROOT%\vllm"
    if errorlevel 1 (
        echo %RED%[start] ERROR: Failed to build vLLM image.%NC%
        exit /b 1
    )
) else (
    echo %CYAN%[start] vLLM image already exists.%NC%
)

%RUNTIME% image inspect "%OPENCLAW_IMAGE_TAG%" >nul 2>&1
if errorlevel 1 (
    echo %CYAN%[start] Building OpenClaw image ...%NC%
    %RUNTIME% build -t "%OPENCLAW_IMAGE_TAG%" "%PROJECT_ROOT%\openclaw"
    if errorlevel 1 (
        echo %RED%[start] ERROR: Failed to build OpenClaw image.%NC%
        exit /b 1
    )
) else (
    echo %CYAN%[start] OpenClaw image already exists.%NC%
)

echo %GREEN%[start] Images ready.%NC%

:: ---------------------------------------------------------------------------
:: Phase 1: Start vLLM
:: ---------------------------------------------------------------------------
echo %CYAN%[start]%NC%
echo %CYAN%[start] --- Phase 1: Starting vLLM server ----%NC%

call "%SCRIPT_DIR%\start-vllm.bat"
set "VLLM_EXIT=!errorlevel!"

if !VLLM_EXIT! neq 0 (
    echo %RED%[start] ERROR: vLLM failed to start (exit code !VLLM_EXIT!).%NC%
    goto :final_summary
)

echo %CYAN%[start] Waiting 5 seconds before starting OpenClaw ...%NC%
timeout /t 5 >nul 2>&1

:: ---------------------------------------------------------------------------
:: Phase 2: Start OpenClaw
:: ---------------------------------------------------------------------------
echo %CYAN%[start]%NC%
echo %CYAN%[start] --- Phase 2: Starting OpenClaw ----%NC%

call "%SCRIPT_DIR%\start-openclaw.bat"
set "OPENCLAW_EXIT=!errorlevel!"

:: (Containers started synchronously above — no polling needed)

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
