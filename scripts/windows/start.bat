@echo off
:: =============================================================================
:: start.bat -- Full E2E startup for the DemoClaw stack (vLLM + OpenClaw)
::
:: This single script handles the entire lifecycle:
::   1. Clean up old containers/network
::   2. Build images (always rebuild to pick up Dockerfile changes)
::   3. Create network
::   4. Start vLLM, wait for /health + /v1/models
::   5. Start OpenClaw, wait for dashboard
::   6. Print tokenized dashboard URL
::
:: Usage:
::   scripts\windows\start.bat
:: =============================================================================
setlocal EnableDelayedExpansion

echo [start] ========================================================
echo [start]   DemoClaw Stack -- Full E2E Startup
echo [start] ========================================================

:: ---------------------------------------------------------------------------
:: Resolve paths
:: ---------------------------------------------------------------------------
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%i in ("%SCRIPT_DIR%\..\..") do set "PROJECT_ROOT=%%~fi"

:: ---------------------------------------------------------------------------
:: Configuration
:: ---------------------------------------------------------------------------
if not defined DEMOCLAW_VLLM_IMAGE    set "DEMOCLAW_VLLM_IMAGE=jinwangmok/democlaw-vllm:v1.0.0"
if not defined DEMOCLAW_OPENCLAW_IMAGE set "DEMOCLAW_OPENCLAW_IMAGE=jinwangmok/democlaw-openclaw:v1.0.0"
set "VLLM_IMAGE=%DEMOCLAW_VLLM_IMAGE%"
set "OPENCLAW_IMAGE=%DEMOCLAW_OPENCLAW_IMAGE%"
set "NETWORK=democlaw-net"
set "VLLM_CONTAINER=democlaw-vllm"
set "OPENCLAW_CONTAINER=democlaw-openclaw"
set "MODEL_NAME=Qwen/Qwen3-4B-AWQ"

:: vLLM tuning for 8GB VRAM
set "MAX_MODEL_LEN=16384"
set "QUANTIZATION=awq_marlin"
set "DTYPE=float16"
set "GPU_MEMORY_UTILIZATION=0.95"

:: Ports
set "VLLM_PORT=8000"
set "OPENCLAW_PORT=18789"

:: Timeouts (seconds)
set "VLLM_HEALTH_TIMEOUT=300"
set "OPENCLAW_HEALTH_TIMEOUT=120"

:: HuggingFace cache
if not defined HF_CACHE_DIR set "HF_CACHE_DIR=%USERPROFILE%\.cache\huggingface"

:: ---------------------------------------------------------------------------
:: Detect container runtime
:: ---------------------------------------------------------------------------
set "RUNTIME="
if defined CONTAINER_RUNTIME (
    where "%CONTAINER_RUNTIME%" >nul 2>&1
    if not errorlevel 1 set "RUNTIME=%CONTAINER_RUNTIME%"
)
if not defined RUNTIME (
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

set "GPU_FLAGS=--gpus all"
if "%RUNTIME%"=="podman" set "GPU_FLAGS=--device nvidia.com/gpu=all"

echo [start] Runtime: %RUNTIME%

:: ---------------------------------------------------------------------------
:: Validate NVIDIA GPU
:: ---------------------------------------------------------------------------
echo [start] Checking NVIDIA GPU ...
where nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo [start] ERROR: nvidia-smi not found. Install NVIDIA drivers.
    exit /b 1
)
nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo [start] ERROR: nvidia-smi failed. Check NVIDIA driver installation.
    exit /b 1
)
echo [start] NVIDIA GPU OK.

:: ===========================================================================
:: Phase 0: Clean up old containers and network
:: ===========================================================================
echo [start]
echo [start] --- Phase 0: Cleanup ---

for %%c in (%OPENCLAW_CONTAINER% %VLLM_CONTAINER%) do (
    %RUNTIME% container inspect "%%c" >nul 2>&1
    if not errorlevel 1 (
        echo [start] Removing old container '%%c' ...
        %RUNTIME% rm -f "%%c" >nul 2>&1
    )
)

%RUNTIME% network inspect %NETWORK% >nul 2>&1
if not errorlevel 1 (
    echo [start] Removing old network '%NETWORK%' ...
    %RUNTIME% network rm %NETWORK% >nul 2>&1
)

:: ===========================================================================
:: Phase 1: Acquire images (pull from Docker Hub first; local build fallback)
:: ===========================================================================
echo [start]
echo [start] --- Phase 1: Acquire images ---

:: --- vLLM image: pull first, build on failure ---
echo [start] Pulling vLLM image '%VLLM_IMAGE%' from registry ...
%RUNTIME% pull %VLLM_IMAGE% >nul 2>&1
if errorlevel 1 (
    echo [start] WARNING: Pull failed for '%VLLM_IMAGE%'. Falling back to local build ...
    %RUNTIME% build -t %VLLM_IMAGE% "%PROJECT_ROOT%\vllm"
    if errorlevel 1 (
        echo [start] ERROR: Both pull and local build failed for vLLM image.
        exit /b 1
    )
    echo [start] vLLM image built locally.
) else (
    echo [start] vLLM image pulled from registry.
)

:: --- OpenClaw image: pull first, build on failure ---
echo [start] Pulling OpenClaw image '%OPENCLAW_IMAGE%' from registry ...
%RUNTIME% pull %OPENCLAW_IMAGE% >nul 2>&1
if errorlevel 1 (
    echo [start] WARNING: Pull failed for '%OPENCLAW_IMAGE%'. Falling back to local build ...
    %RUNTIME% build -t %OPENCLAW_IMAGE% "%PROJECT_ROOT%\openclaw"
    if errorlevel 1 (
        echo [start] ERROR: Both pull and local build failed for OpenClaw image.
        exit /b 1
    )
    echo [start] OpenClaw image built locally.
) else (
    echo [start] OpenClaw image pulled from registry.
)

echo [start] Images ready.

:: ===========================================================================
:: Phase 2: Create network + start vLLM
:: ===========================================================================
echo [start]
echo [start] --- Phase 2: Start vLLM ---

echo [start] Creating network '%NETWORK%' ...
%RUNTIME% network create %NETWORK%
if errorlevel 1 (
    echo [start] ERROR: Failed to create network.
    exit /b 1
)

:: Ensure HF cache dir exists
if not exist "%HF_CACHE_DIR%" mkdir "%HF_CACHE_DIR%" 2>nul

echo [start] Starting vLLM container ...
echo [start]   Model        : %MODEL_NAME%
echo [start]   Quantization : %QUANTIZATION%
echo [start]   Context      : %MAX_MODEL_LEN%
echo [start]   GPU mem util : %GPU_MEMORY_UTILIZATION%

%RUNTIME% run -d ^
    --name %VLLM_CONTAINER% ^
    --network %NETWORK% ^
    --hostname vllm ^
    --network-alias vllm ^
    %GPU_FLAGS% ^
    --restart unless-stopped ^
    --shm-size 1g ^
    -p %VLLM_PORT%:%VLLM_PORT% ^
    -v "%HF_CACHE_DIR%:/root/.cache/huggingface:rw" ^
    -e "MODEL_NAME=%MODEL_NAME%" ^
    -e "MAX_MODEL_LEN=%MAX_MODEL_LEN%" ^
    -e "GPU_MEMORY_UTILIZATION=%GPU_MEMORY_UTILIZATION%" ^
    -e "QUANTIZATION=%QUANTIZATION%" ^
    -e "DTYPE=%DTYPE%" ^
    -e "VLLM_ATTENTION_BACKEND=FLASHINFER" ^
    %VLLM_IMAGE%

if errorlevel 1 (
    echo [start] ERROR: Failed to start vLLM container.
    exit /b 1
)

echo [start] vLLM container started. Waiting for health ...

:: ---------------------------------------------------------------------------
:: Wait for vLLM /health
:: ---------------------------------------------------------------------------
set /a "elapsed=0"

:vllm_health_loop
if %elapsed% geq %VLLM_HEALTH_TIMEOUT% (
    echo [start] ERROR: vLLM did not become healthy within %VLLM_HEALTH_TIMEOUT%s.
    echo [start] Check logs: %RUNTIME% logs %VLLM_CONTAINER%
    exit /b 1
)

:: Check container still alive
for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" %VLLM_CONTAINER% 2^>nul') do set "CSTATE=%%s"
if "!CSTATE!"=="exited" (
    echo [start] ERROR: vLLM container exited unexpectedly.
    %RUNTIME% logs --tail 20 %VLLM_CONTAINER% 2>&1
    exit /b 1
)

curl -sf http://localhost:%VLLM_PORT%/health >nul 2>&1
if not errorlevel 1 (
    echo [start] vLLM /health OK.
    goto :vllm_models_check
)

timeout /t 5 >nul 2>&1
set /a "elapsed=elapsed+5"
if !elapsed! geq 10 (
    set /a "mod=elapsed %% 30"
    if !mod! equ 0 echo [start]   ... vLLM loading (%elapsed%/%VLLM_HEALTH_TIMEOUT%s)
)
goto :vllm_health_loop

:: ---------------------------------------------------------------------------
:: Verify /v1/models
:: ---------------------------------------------------------------------------
:vllm_models_check
echo [start] Checking /v1/models ...
set /a "models_elapsed=0"

:vllm_models_loop
if %models_elapsed% geq 60 (
    echo [start] WARNING: /v1/models not responding. Proceeding anyway.
    goto :start_openclaw
)

curl -sf http://localhost:%VLLM_PORT%/v1/models >nul 2>&1
if not errorlevel 1 (
    echo [start] vLLM /v1/models OK. Model ready.
    goto :start_openclaw
)

timeout /t 5 >nul 2>&1
set /a "models_elapsed=models_elapsed+5"
goto :vllm_models_loop

:: ===========================================================================
:: Phase 3: Start OpenClaw
:: ===========================================================================
:start_openclaw
echo [start]
echo [start] --- Phase 3: Start OpenClaw ---

echo [start] Starting OpenClaw container ...

%RUNTIME% run -d ^
    --name %OPENCLAW_CONTAINER% ^
    --network %NETWORK% ^
    --hostname openclaw ^
    --network-alias openclaw ^
    --restart unless-stopped ^
    -p %OPENCLAW_PORT%:%OPENCLAW_PORT% ^
    -p 18791:18791 ^
    -e "VLLM_BASE_URL=http://vllm:8000/v1" ^
    -e "VLLM_API_KEY=EMPTY" ^
    -e "VLLM_MODEL_NAME=%MODEL_NAME%" ^
    -e "OPENCLAW_PORT=%OPENCLAW_PORT%" ^
    %OPENCLAW_IMAGE%

if errorlevel 1 (
    echo [start] ERROR: Failed to start OpenClaw container.
    exit /b 1
)

echo [start] OpenClaw container started. Waiting for dashboard ...

:: ---------------------------------------------------------------------------
:: Wait for OpenClaw dashboard
:: ---------------------------------------------------------------------------
set /a "oc_elapsed=0"

:openclaw_health_loop
if %oc_elapsed% geq %OPENCLAW_HEALTH_TIMEOUT% (
    echo [start] ERROR: OpenClaw dashboard did not respond within %OPENCLAW_HEALTH_TIMEOUT%s.
    echo [start] Check logs: %RUNTIME% logs %OPENCLAW_CONTAINER%
    exit /b 1
)

for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" %OPENCLAW_CONTAINER% 2^>nul') do set "OC_STATE=%%s"
if "!OC_STATE!"=="exited" (
    echo [start] ERROR: OpenClaw container exited unexpectedly.
    %RUNTIME% logs --tail 20 %OPENCLAW_CONTAINER% 2>&1
    exit /b 1
)

curl -sf http://localhost:%OPENCLAW_PORT%/ >nul 2>&1
if not errorlevel 1 (
    echo [start] OpenClaw dashboard responding.
    goto :show_result
)

timeout /t 3 >nul 2>&1
set /a "oc_elapsed=oc_elapsed+3"
if !oc_elapsed! geq 9 (
    set /a "mod=oc_elapsed %% 15"
    if !mod! equ 0 echo [start]   ... waiting for OpenClaw (%oc_elapsed%/%OPENCLAW_HEALTH_TIMEOUT%s)
)
goto :openclaw_health_loop

:: ===========================================================================
:: Phase 4: Show result
:: ===========================================================================
:show_result
echo [start]
echo [start] ========================================================
echo [start]   DemoClaw is running!
echo [start] ========================================================
echo [start]
echo [start]   vLLM API : http://localhost:%VLLM_PORT%/v1
echo [start]   Model    : %MODEL_NAME%
echo [start]   Runtime  : %RUNTIME%
echo [start]

:: Try to get tokenized dashboard URL
:: Output format: "Dashboard URL: http://127.0.0.1:18789/#token=abc..."
set "DASHBOARD_URL="
for /f "tokens=3 delims= " %%u in ('%RUNTIME% exec %OPENCLAW_CONTAINER% openclaw dashboard --no-open 2^>nul ^| findstr /i "http"') do (
    set "DASHBOARD_URL=%%u"
)

if defined DASHBOARD_URL (
    set "DASHBOARD_URL=!DASHBOARD_URL:127.0.0.1=localhost!"
    echo [start]   Dashboard: !DASHBOARD_URL!
) else (
    echo [start]   Dashboard: http://localhost:%OPENCLAW_PORT%
)

echo [start]
echo [start]   NOTE: On first connect, click "Connect" in the browser.
echo [start]         The device pairing is auto-approved within ~2 seconds.
echo [start]         If needed, click "Connect" again after approval.
echo [start]
echo [start]   Stop with: scripts\windows\stop.bat
echo [start] ========================================================

endlocal
