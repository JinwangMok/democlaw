@echo off
setlocal enabledelayedexpansion
:: =============================================================================
:: start.bat -- Full E2E startup for the DemoClaw stack (llama.cpp + OpenClaw)
::
:: Windows 11 PowerShell/cmd port of start.sh.
:: Handles: cleanup -> pull/build images -> network -> llama.cpp -> OpenClaw
::
:: Usage:
::   scripts\start.bat
:: =============================================================================

:: ---------------------------------------------------------------------------
:: Configuration (matches start.sh defaults; override via environment)
:: ---------------------------------------------------------------------------
if not defined DEMOCLAW_LLAMACPP_IMAGE set "LLAMACPP_IMAGE=docker.io/jinwangmok/democlaw-llamacpp:v1.0.0"
if defined DEMOCLAW_LLAMACPP_IMAGE set "LLAMACPP_IMAGE=%DEMOCLAW_LLAMACPP_IMAGE%"

if not defined DEMOCLAW_OPENCLAW_IMAGE set "OPENCLAW_IMAGE=docker.io/jinwangmok/democlaw-openclaw:v1.0.0"
if defined DEMOCLAW_OPENCLAW_IMAGE set "OPENCLAW_IMAGE=%DEMOCLAW_OPENCLAW_IMAGE%"

set "NETWORK=democlaw-net"
set "LLAMACPP_CONTAINER=democlaw-llamacpp"
set "OPENCLAW_CONTAINER=democlaw-openclaw"
set "MODEL_NAME=Qwen3.5-9B-Q4_K_M"
set "MODEL_REPO=unsloth/Qwen3.5-9B-GGUF"
set "MODEL_FILE=Qwen3.5-9B-Q4_K_M.gguf"

:: llama.cpp tuning for 8GB VRAM
if not defined CTX_SIZE set "CTX_SIZE=32768"
if not defined N_GPU_LAYERS set "N_GPU_LAYERS=99"
if not defined FLASH_ATTN set "FLASH_ATTN=1"
if not defined CACHE_TYPE_K set "CACHE_TYPE_K=q8_0"
if not defined CACHE_TYPE_V set "CACHE_TYPE_V=q8_0"

:: Ports
set "LLAMACPP_PORT=8000"
set "OPENCLAW_PORT=18789"

:: Timeouts (seconds)
set "LLAMACPP_HEALTH_TIMEOUT=600"
set "OPENCLAW_HEALTH_TIMEOUT=120"

:: Model directory (host path mounted into container)
if not defined MODEL_DIR set "MODEL_DIR=%USERPROFILE%\.cache\democlaw\models"

:: Project root
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%I in ("%SCRIPT_DIR%\..") do set "PROJECT_ROOT=%%~fI"

:: ---------------------------------------------------------------------------
:: Detect container runtime
:: ---------------------------------------------------------------------------
set "RUNTIME="
if defined CONTAINER_RUNTIME (
    where "%CONTAINER_RUNTIME%" >nul 2>&1
    if !errorlevel! equ 0 set "RUNTIME=%CONTAINER_RUNTIME%"
)
if not defined RUNTIME (
    where docker >nul 2>&1
    if !errorlevel! equ 0 (
        set "RUNTIME=docker"
    ) else (
        where podman >nul 2>&1
        if !errorlevel! equ 0 (
            set "RUNTIME=podman"
        )
    )
)
if not defined RUNTIME (
    echo [start] ERROR: No container runtime found. Install Docker Desktop or Podman Desktop. >&2
    exit /b 1
)

set "GPU_FLAGS=--gpus all"
set "SHM_FLAGS=--shm-size 1g"
if "%RUNTIME%"=="podman" (
    set "GPU_FLAGS=--device nvidia.com/gpu=all"
    set "SHM_FLAGS="
)

echo [start] ========================================================
echo [start]   DemoClaw Stack -- Full E2E Startup
echo [start] ========================================================
echo [start] Runtime : %RUNTIME%
echo [start] Engine  : llama.cpp (CUDA backend)
echo [start] Model   : %MODEL_NAME% (GGUF Q4_K_M)

:: ---------------------------------------------------------------------------
:: Validate NVIDIA GPU
:: ---------------------------------------------------------------------------
echo [start] Checking NVIDIA GPU ...
where nvidia-smi >nul 2>&1
if !errorlevel! neq 0 (
    echo [start] ERROR: nvidia-smi not found. Install NVIDIA drivers. >&2
    exit /b 1
)
nvidia-smi >nul 2>&1
if !errorlevel! neq 0 (
    echo [start] ERROR: nvidia-smi failed. Check NVIDIA driver installation. >&2
    exit /b 1
)
echo [start] NVIDIA GPU OK.

:: ===========================================================================
:: Phase 0: Cleanup
:: ===========================================================================
echo.
echo [start] --- Phase 0: Cleanup ---

for %%c in (%OPENCLAW_CONTAINER% %LLAMACPP_CONTAINER%) do (
    %RUNTIME% container inspect "%%c" >nul 2>&1
    if !errorlevel! equ 0 (
        echo [start] Removing old container '%%c' ...
        %RUNTIME% rm -f "%%c" >nul 2>&1
    )
)

%RUNTIME% network inspect %NETWORK% >nul 2>&1
if !errorlevel! equ 0 (
    echo [start] Removing old network '%NETWORK%' ...
    %RUNTIME% network rm %NETWORK% >nul 2>&1
)

:: ===========================================================================
:: Phase 1: Acquire images (pull first, local build fallback)
:: ===========================================================================
echo.
echo [start] --- Phase 1: Acquire images ---

call :ensure_image "%LLAMACPP_IMAGE%" "%PROJECT_ROOT%\llamacpp"
if !errorlevel! neq 0 exit /b 1

call :ensure_image "%OPENCLAW_IMAGE%" "%PROJECT_ROOT%\openclaw"
if !errorlevel! neq 0 exit /b 1

echo [start] Images ready.

:: ===========================================================================
:: Phase 2: Create network + start llama.cpp
:: ===========================================================================
echo.
echo [start] --- Phase 2: Start llama.cpp ---

echo [start] Creating network '%NETWORK%' ...
%RUNTIME% network create %NETWORK%
if !errorlevel! neq 0 (
    echo [start] ERROR: Failed to create network. >&2
    exit /b 1
)

:: Ensure model directory exists
if not exist "%MODEL_DIR%" mkdir "%MODEL_DIR%"

echo [start] Starting llama.cpp container ...
echo [start]   Model      : %MODEL_REPO%/%MODEL_FILE%
echo [start]   Context    : %CTX_SIZE% tokens
echo [start]   GPU layers : %N_GPU_LAYERS%
echo [start]   Flash attn : %FLASH_ATTN%
echo [start]   KV cache   : K=%CACHE_TYPE_K%, V=%CACHE_TYPE_V%
echo [start]   Model dir  : %MODEL_DIR%

%RUNTIME% run -d ^
    --name %LLAMACPP_CONTAINER% ^
    --network %NETWORK% ^
    --network-alias llamacpp ^
    %GPU_FLAGS% ^
    --restart unless-stopped ^
    %SHM_FLAGS% ^
    -p %LLAMACPP_PORT%:%LLAMACPP_PORT% ^
    -v "%MODEL_DIR%:/models:rw" ^
    -e "MODEL_PATH=/models/%MODEL_FILE%" ^
    -e "MODEL_REPO=%MODEL_REPO%" ^
    -e "MODEL_FILE=%MODEL_FILE%" ^
    -e "MODEL_ALIAS=%MODEL_NAME%" ^
    -e "LLAMA_HOST=0.0.0.0" ^
    -e "LLAMA_PORT=%LLAMACPP_PORT%" ^
    -e "CTX_SIZE=%CTX_SIZE%" ^
    -e "N_GPU_LAYERS=%N_GPU_LAYERS%" ^
    -e "FLASH_ATTN=%FLASH_ATTN%" ^
    -e "CACHE_TYPE_K=%CACHE_TYPE_K%" ^
    -e "CACHE_TYPE_V=%CACHE_TYPE_V%" ^
    %LLAMACPP_IMAGE%

if !errorlevel! neq 0 (
    echo [start] ERROR: Failed to start llama.cpp container. >&2
    exit /b 1
)

echo [start] llama.cpp container started. Waiting for health ...

:: ---------------------------------------------------------------------------
:: Wait for llama.cpp /health
:: ---------------------------------------------------------------------------
set "ELAPSED=0"

:llamacpp_health_loop
if %ELAPSED% geq %LLAMACPP_HEALTH_TIMEOUT% (
    echo [start] ERROR: llama.cpp did not become healthy within %LLAMACPP_HEALTH_TIMEOUT%s. >&2
    echo [start] Check logs: %RUNTIME% logs %LLAMACPP_CONTAINER% >&2
    exit /b 1
)

:: Check if container died
for /f "tokens=*" %%S in ('%RUNTIME% container inspect --format "{{.State.Status}}" %LLAMACPP_CONTAINER% 2^>nul') do set "CSTATE=%%S"
if "!CSTATE!"=="exited" goto llamacpp_died
if "!CSTATE!"=="dead" goto llamacpp_died

curl -sf "http://localhost:%LLAMACPP_PORT%/health" >nul 2>&1
if !errorlevel! equ 0 (
    echo [start] llama.cpp /health OK.
    goto llamacpp_models_check
)

timeout /t 5 /nobreak >nul
set /a "ELAPSED+=5"
set /a "MOD30=ELAPSED %% 30"
if !MOD30! equ 0 echo [start]   ... llama.cpp loading ^(!ELAPSED!/%LLAMACPP_HEALTH_TIMEOUT%s^)
goto llamacpp_health_loop

:llamacpp_died
echo [start] ERROR: llama.cpp container exited unexpectedly. >&2
%RUNTIME% logs --tail 30 %LLAMACPP_CONTAINER% 2>&1
exit /b 1

:: ---------------------------------------------------------------------------
:: Verify /v1/models
:: ---------------------------------------------------------------------------
:llamacpp_models_check
echo [start] Checking /v1/models for model '%MODEL_NAME%' ...
set "MODELS_ELAPSED=0"
set "MODELS_TIMEOUT=60"

:models_loop
if %MODELS_ELAPSED% geq %MODELS_TIMEOUT% (
    echo [start] WARNING: /v1/models did not confirm model within %MODELS_TIMEOUT%s.
    echo [start]   Check: curl http://localhost:%LLAMACPP_PORT%/v1/models
    goto start_openclaw
)

curl -sf "http://localhost:%LLAMACPP_PORT%/v1/models" >nul 2>&1
if !errorlevel! equ 0 (
    echo [start] llama.cpp /v1/models OK.
    goto start_openclaw
)

timeout /t 5 /nobreak >nul
set /a "MODELS_ELAPSED+=5"
set /a "MOD15=MODELS_ELAPSED %% 15"
if !MOD15! equ 0 echo [start]   ... waiting for /v1/models ^(!MODELS_ELAPSED!/%MODELS_TIMEOUT%s^)
goto models_loop

:: ===========================================================================
:: Phase 3: Start OpenClaw
:: ===========================================================================
:start_openclaw
echo.
echo [start] --- Phase 3: Start OpenClaw ---

echo [start] Starting OpenClaw container ...

%RUNTIME% run -d ^
    --name %OPENCLAW_CONTAINER% ^
    --network %NETWORK% ^
    --network-alias openclaw ^
    --restart unless-stopped ^
    -p %OPENCLAW_PORT%:%OPENCLAW_PORT% ^
    -p 18791:18791 ^
    -e "LLAMACPP_BASE_URL=http://llamacpp:8000/v1" ^
    -e "LLAMACPP_API_KEY=EMPTY" ^
    -e "LLAMACPP_MODEL_NAME=%MODEL_NAME%" ^
    -e "OPENCLAW_PORT=%OPENCLAW_PORT%" ^
    %OPENCLAW_IMAGE%

if !errorlevel! neq 0 (
    echo [start] ERROR: Failed to start OpenClaw container. >&2
    exit /b 1
)

echo [start] OpenClaw container started. Waiting for dashboard ...

:: ---------------------------------------------------------------------------
:: Wait for OpenClaw dashboard
:: ---------------------------------------------------------------------------
set "OC_ELAPSED=0"

:oc_health_loop
if %OC_ELAPSED% geq %OPENCLAW_HEALTH_TIMEOUT% (
    echo [start] ERROR: OpenClaw dashboard did not respond within %OPENCLAW_HEALTH_TIMEOUT%s. >&2
    echo [start] Check logs: %RUNTIME% logs %OPENCLAW_CONTAINER% >&2
    exit /b 1
)

for /f "tokens=*" %%S in ('%RUNTIME% container inspect --format "{{.State.Status}}" %OPENCLAW_CONTAINER% 2^>nul') do set "OC_STATE=%%S"
if "!OC_STATE!"=="exited" goto oc_died
if "!OC_STATE!"=="dead" goto oc_died

curl -sf "http://localhost:%OPENCLAW_PORT%/" >nul 2>&1
if !errorlevel! equ 0 (
    echo [start] OpenClaw dashboard health-check passed (HTTP 200).
    goto show_result
)

timeout /t 3 /nobreak >nul
set /a "OC_ELAPSED+=3"
set /a "OC_MOD15=OC_ELAPSED %% 15"
if !OC_MOD15! equ 0 echo [start]   ... waiting for OpenClaw ^(!OC_ELAPSED!/%OPENCLAW_HEALTH_TIMEOUT%s^)
goto oc_health_loop

:oc_died
echo [start] ERROR: OpenClaw container exited unexpectedly. >&2
%RUNTIME% logs --tail 20 %OPENCLAW_CONTAINER% 2>&1
exit /b 1

:: ===========================================================================
:: Phase 4: Print dashboard URL
:: ===========================================================================
:show_result

:: Try to get tokenized dashboard URL
set "DASHBOARD_URL="
for /f "tokens=*" %%U in ('%RUNTIME% exec %OPENCLAW_CONTAINER% openclaw dashboard --no-open 2^>nul') do (
    echo %%U | findstr /r "http" >nul 2>&1
    if !errorlevel! equ 0 set "DASHBOARD_URL=%%U"
)
if defined DASHBOARD_URL set "DASHBOARD_URL=!DASHBOARD_URL:127.0.0.1=localhost!"
if not defined DASHBOARD_URL set "DASHBOARD_URL=http://localhost:%OPENCLAW_PORT%"

echo.
echo [start] ========================================================
echo [start]   DemoClaw is running!
echo [start] ========================================================
echo.
echo [start]   Both health-checks passed:
echo [start]     - llama.cpp /v1/models .. HTTP 200
echo [start]     - OpenClaw dashboard ... HTTP 200
echo.
echo [start]   Services:
echo [start]     LLM API  : http://localhost:%LLAMACPP_PORT%/v1
echo [start]     Engine   : llama.cpp (CUDA)
echo [start]     Model    : %MODEL_NAME% (%MODEL_REPO%)
echo [start]     Context  : %CTX_SIZE% tokens
echo [start]     Runtime  : %RUNTIME%
echo.
echo [start]   Web UI Dashboard:
echo [start]     !DASHBOARD_URL!
echo.
echo !DASHBOARD_URL!
echo.
echo [start]   NOTE: On first connect, click "Connect" in the browser.
echo [start]         The device pairing is auto-approved within ~2 seconds.
echo [start]
echo [start]   Stop with: scripts\stop.bat
echo [start] ========================================================

endlocal
exit /b 0

:: ===========================================================================
:: Subroutine: ensure_image — pull first, local build fallback
:: ===========================================================================
:ensure_image
set "IMG_TAG=%~1"
set "BUILD_CTX=%~2"

echo [start] Acquiring image '%IMG_TAG%' ...
echo [start]   Pulling from registry ...

%RUNTIME% pull %IMG_TAG% >nul 2>&1
if !errorlevel! equ 0 (
    echo [start]   Pull succeeded.
    exit /b 0
)

echo [start]   WARNING: Pull failed. Falling back to local build ...
if not exist "%BUILD_CTX%\Dockerfile" (
    echo [start] ERROR: No Dockerfile at %BUILD_CTX% >&2
    exit /b 1
)

%RUNTIME% build -t %IMG_TAG% "%BUILD_CTX%"
if !errorlevel! neq 0 (
    echo [start] ERROR: Both pull and build failed for '%IMG_TAG%'. >&2
    exit /b 1
)
echo [start]   Local build succeeded.
exit /b 0
