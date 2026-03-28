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
    echo [start] Loading environment from %ENV_FILE%
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
        echo [start] ERROR: CONTAINER_RUNTIME='%CONTAINER_RUNTIME%' is set but not found in PATH.
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
            echo [start] ERROR: No container runtime found. Install Docker Desktop or Podman Desktop.
            exit /b 1
        )
    )
)

set "RUNTIME_IS_PODMAN=false"
if "%RUNTIME%"=="podman" set "RUNTIME_IS_PODMAN=true"

echo [start] ========================================================
echo [start]   DemoClaw Stack -- Container Runtime: %RUNTIME%
echo [start]   Podman mode: %RUNTIME_IS_PODMAN%
echo [start] ========================================================

:: ---------------------------------------------------------------------------
:: Validate NVIDIA GPU
:: ---------------------------------------------------------------------------
echo [start] Validating NVIDIA GPU ...
where nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo [start] ERROR: nvidia-smi not found in PATH.
    echo [start]   Install NVIDIA drivers and ensure nvidia-smi is in PATH.
    echo [start]   Download: https://www.nvidia.com/Download/index.aspx
    exit /b 1
)
nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo [start] ERROR: nvidia-smi failed. Check that NVIDIA drivers are correctly installed.
    exit /b 1
)
echo [start] NVIDIA GPU validated.

:: ---------------------------------------------------------------------------
:: Phase 0: Build images (synchronous -- must complete before containers start)
:: ---------------------------------------------------------------------------
echo [start]
set "VLLM_EXIT=0"
set "OPENCLAW_EXIT=0"
set "HEALTHCHECK_EXIT=0"

echo [start] --- Phase 0: Building container images ----

if not defined VLLM_IMAGE_TAG    set "VLLM_IMAGE_TAG=democlaw/vllm:latest"
if not defined OPENCLAW_IMAGE_TAG set "OPENCLAW_IMAGE_TAG=democlaw/openclaw:latest"

%RUNTIME% image inspect "%VLLM_IMAGE_TAG%" >nul 2>&1
if errorlevel 1 (
    echo [start] Building vLLM image ...
    %RUNTIME% build -t "%VLLM_IMAGE_TAG%" "%PROJECT_ROOT%\vllm"
    if errorlevel 1 (
        echo [start] ERROR: Failed to build vLLM image.
        exit /b 1
    )
) else (
    echo [start] vLLM image already exists.
)

%RUNTIME% image inspect "%OPENCLAW_IMAGE_TAG%" >nul 2>&1
if errorlevel 1 (
    echo [start] Building OpenClaw image ...
    %RUNTIME% build -t "%OPENCLAW_IMAGE_TAG%" "%PROJECT_ROOT%\openclaw"
    if errorlevel 1 (
        echo [start] ERROR: Failed to build OpenClaw image.
        exit /b 1
    )
) else (
    echo [start] OpenClaw image already exists.
)

echo [start] Images ready.

:: ---------------------------------------------------------------------------
:: Phase 1: Start vLLM
:: ---------------------------------------------------------------------------
echo [start]
echo [start] --- Phase 1: Starting vLLM server ----

call "%SCRIPT_DIR%\start-vllm.bat"
set "VLLM_EXIT=!errorlevel!"

if !VLLM_EXIT! neq 0 (
    echo [start] ERROR: vLLM failed to start (exit code !VLLM_EXIT!).
    goto :final_summary
)

echo [start] Waiting 5 seconds before starting OpenClaw ...
timeout /t 5 >nul 2>&1

:: ---------------------------------------------------------------------------
:: Phase 2: Start OpenClaw
:: ---------------------------------------------------------------------------
echo [start]
echo [start] --- Phase 2: Starting OpenClaw ----

call "%SCRIPT_DIR%\start-openclaw.bat"
set "OPENCLAW_EXIT=!errorlevel!"

:: ---------------------------------------------------------------------------
:: Phase 3: Comprehensive healthcheck
:: ---------------------------------------------------------------------------
echo [start]
echo [start] --- Phase 3: Comprehensive healthcheck ----

set "HEALTHCHECK_EXIT=0"

if %VLLM_EXIT% neq 0 (
    set "HEALTHCHECK_EXIT=1"
    echo [start] HEALTHCHECK SKIP: vLLM failed to start (exit code %VLLM_EXIT%).
    goto :final_summary
)
if %OPENCLAW_EXIT% neq 0 (
    set "HEALTHCHECK_EXIT=1"
    echo [start] HEALTHCHECK SKIP: OpenClaw failed to start (exit code %OPENCLAW_EXIT%).
    goto :final_summary
)

echo [start] Both containers running; running comprehensive healthcheck ...
call "%SCRIPT_DIR%\healthcheck.bat"
set "HEALTHCHECK_EXIT=!errorlevel!"

if %HEALTHCHECK_EXIT% equ 0 (
    echo [start] HEALTHCHECK PASS: All services are healthy.
) else (
    echo [start] HEALTHCHECK FAIL: One or more checks did not pass.
    echo [start]   Re-run at any time with: scripts\windows\healthcheck.bat
)

:final_summary
echo [start]
echo [start] ========================================================

if not defined VLLM_HOST_PORT    set "VLLM_HOST_PORT=8000"
if not defined OPENCLAW_HOST_PORT set "OPENCLAW_HOST_PORT=18789"

if %VLLM_EXIT% equ 0 if %OPENCLAW_EXIT% equ 0 if %HEALTHCHECK_EXIT% equ 0 (
    echo [start]   Both services started successfully!
    echo [start]   vLLM API     : http://localhost:%VLLM_HOST_PORT%/v1
    echo [start]   OpenClaw UI  : http://localhost:%OPENCLAW_HOST_PORT%
    echo [start]   Runtime      : %RUNTIME%
    echo [start] ========================================================
    exit /b 0
) else (
    if %VLLM_EXIT% neq 0    echo [start] WARNING: vLLM start script exited with code %VLLM_EXIT%
    if %OPENCLAW_EXIT% neq 0 echo [start] WARNING: OpenClaw start script exited with code %OPENCLAW_EXIT%
    if %HEALTHCHECK_EXIT% neq 0 echo [start] WARNING: Healthcheck exited with code %HEALTHCHECK_EXIT%
    echo [start] ========================================================
    exit /b 1
)

endlocal
