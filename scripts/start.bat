@echo off
setlocal enabledelayedexpansion
:: =============================================================================
:: start.bat -- Full E2E startup for the DemoClaw stack (llama.cpp + OpenClaw)
::
:: This single script handles the entire lifecycle:
::   1. Clean up old containers/network (idempotent destroy-recreate)
::   2. Acquire images (pull from Docker Hub first; local build fallback)
::   3. Create network
::   4. Start llama.cpp, wait for /health + /v1/models
::   5. Start OpenClaw, wait for dashboard
::   6. Print tokenized dashboard URL
::
:: Usage:
::   scripts\start.bat
::
:: Environment overrides:
::   set DEMOCLAW_LLAMACPP_IMAGE=myrepo/llamacpp:dev
::   set DEMOCLAW_OPENCLAW_IMAGE=myrepo/openclaw:dev
::   set HF_CACHE_DIR=D:\models
::   set CONTAINER_RUNTIME=podman
:: =============================================================================

:: ---------------------------------------------------------------------------
:: Configuration (pinned versions)
:: ---------------------------------------------------------------------------
if defined DEMOCLAW_LLAMACPP_IMAGE (
    set "LLAMACPP_IMAGE=%DEMOCLAW_LLAMACPP_IMAGE%"
) else (
    set "LLAMACPP_IMAGE=jinwangmok/democlaw-llamacpp:v1.0.0"
)

if defined DEMOCLAW_OPENCLAW_IMAGE (
    set "OPENCLAW_IMAGE=%DEMOCLAW_OPENCLAW_IMAGE%"
) else (
    set "OPENCLAW_IMAGE=jinwangmok/democlaw-openclaw:v1.0.0"
)

set "NETWORK=democlaw-net"
set "LLAMACPP_CONTAINER=democlaw-llamacpp"
set "OPENCLAW_CONTAINER=democlaw-openclaw"
set "MODEL_NAME=Qwen/Qwen3-4B-AWQ"

:: llama.cpp tuning for 8GB VRAM
set "MAX_MODEL_LEN=16384"
set "QUANTIZATION=awq_marlin"
set "DTYPE=float16"
set "GPU_MEMORY_UTILIZATION=0.95"

:: Ports
set "LLAMACPP_PORT=8000"
set "OPENCLAW_PORT=18789"

:: Timeouts (seconds)
set "LLAMACPP_HEALTH_TIMEOUT=300"
set "OPENCLAW_HEALTH_TIMEOUT=120"
set "MODELS_TIMEOUT=120"

:: HuggingFace cache
if defined HF_CACHE_DIR (
    set "HF_CACHE=%HF_CACHE_DIR%"
) else (
    set "HF_CACHE=%USERPROFILE%\.cache\huggingface"
)

:: Project root (parent of scripts directory)
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "PROJECT_ROOT=%%~fI"

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
if "%RUNTIME%"=="podman" set "GPU_FLAGS=--device nvidia.com/gpu=all"

echo [start] ========================================================
echo [start]   DemoClaw Stack -- Full E2E Startup
echo [start] ========================================================
echo [start] Runtime: %RUNTIME%

:: ---------------------------------------------------------------------------
:: Prerequisite checks
:: ---------------------------------------------------------------------------
echo [start] Checking prerequisites ...

:: Check for curl (needed for health-checks)
where curl >nul 2>&1
if !errorlevel! neq 0 (
    echo [start] ERROR: curl not found. Install curl or use Windows 10+ which includes it. >&2
    exit /b 1
)

:: Check NVIDIA GPU
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
:: Phase 0: Clean up old containers and network (idempotent destroy-recreate)
:: ===========================================================================
echo.
echo [start] --- Phase 0: Cleanup ---

:: Remove OpenClaw container if it exists
%RUNTIME% container inspect %OPENCLAW_CONTAINER% >nul 2>&1
if !errorlevel! equ 0 (
    echo [start] Removing old container '%OPENCLAW_CONTAINER%' ...
    %RUNTIME% rm -f %OPENCLAW_CONTAINER% >nul 2>&1
)

:: Remove llama.cpp container if it exists
%RUNTIME% container inspect %LLAMACPP_CONTAINER% >nul 2>&1
if !errorlevel! equ 0 (
    echo [start] Removing old container '%LLAMACPP_CONTAINER%' ...
    %RUNTIME% rm -f %LLAMACPP_CONTAINER% >nul 2>&1
)

:: Remove network if it exists
%RUNTIME% network inspect %NETWORK% >nul 2>&1
if !errorlevel! equ 0 (
    echo [start] Removing old network '%NETWORK%' ...
    %RUNTIME% network rm %NETWORK% >nul 2>&1
)

:: ===========================================================================
:: Phase 1: Acquire images (pull from Docker Hub first; local build fallback)
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

:: Ensure HuggingFace cache directory exists
if not exist "%HF_CACHE%" mkdir "%HF_CACHE%"

echo [start] Starting llama.cpp container ...
echo [start]   Model        : %MODEL_NAME%
echo [start]   Quantization : %QUANTIZATION%
echo [start]   Context      : %MAX_MODEL_LEN%
echo [start]   GPU mem util : %GPU_MEMORY_UTILIZATION%

%RUNTIME% run -d ^
    --name %LLAMACPP_CONTAINER% ^
    --network %NETWORK% ^
    --hostname llamacpp ^
    --network-alias llamacpp ^
    %GPU_FLAGS% ^
    --restart unless-stopped ^
    --shm-size 1g ^
    -p %LLAMACPP_PORT%:%LLAMACPP_PORT% ^
    -v "%HF_CACHE%:/root/.cache/huggingface:rw" ^
    -e "MODEL_NAME=%MODEL_NAME%" ^
    -e "MAX_MODEL_LEN=%MAX_MODEL_LEN%" ^
    -e "GPU_MEMORY_UTILIZATION=%GPU_MEMORY_UTILIZATION%" ^
    -e "QUANTIZATION=%QUANTIZATION%" ^
    -e "DTYPE=%DTYPE%" ^
    %LLAMACPP_IMAGE%

if !errorlevel! neq 0 (
    echo [start] ERROR: Failed to start llama.cpp container. >&2
    exit /b 1
)

echo [start] llama.cpp container started. Waiting for health ...

:: ---------------------------------------------------------------------------
:: Wait for llama.cpp /health (with container-died detection)
:: ---------------------------------------------------------------------------
set "ELAPSED=0"
set "LLAMACPP_HEALTHY=0"

:llamacpp_health_loop
if %ELAPSED% geq %LLAMACPP_HEALTH_TIMEOUT% goto llamacpp_health_done

:: Check if container died
for /f "tokens=*" %%S in ('%RUNTIME% container inspect --format "{{.State.Status}}" %LLAMACPP_CONTAINER% 2^>nul') do set "CSTATE=%%S"
if "!CSTATE!"=="exited" goto llamacpp_container_died
if "!CSTATE!"=="dead" goto llamacpp_container_died

:: Check /health endpoint
curl -sf "http://localhost:%LLAMACPP_PORT%/health" >nul 2>&1
if !errorlevel! equ 0 (
    set "LLAMACPP_HEALTHY=1"
    goto llamacpp_health_done
)

timeout /t 5 /nobreak >nul
set /a "ELAPSED+=5"
set /a "MOD30=ELAPSED %% 30"
if !MOD30! equ 0 (
    echo [start]   ... llama.cpp loading ^(!ELAPSED!/%LLAMACPP_HEALTH_TIMEOUT%s^)
)
goto llamacpp_health_loop

:llamacpp_container_died
echo [start] ERROR: llama.cpp container exited unexpectedly. >&2
%RUNTIME% logs --tail 20 %LLAMACPP_CONTAINER% 2>&1
exit /b 1

:llamacpp_health_done
if %LLAMACPP_HEALTHY% equ 0 (
    echo [start] ERROR: llama.cpp did not become healthy within %LLAMACPP_HEALTH_TIMEOUT%s. >&2
    echo [start] Check logs: %RUNTIME% logs %LLAMACPP_CONTAINER% >&2
    exit /b 1
)
echo [start] llama.cpp /health OK.

:: ---------------------------------------------------------------------------
:: Verify /v1/models returns HTTP 200 with expected model
:: ---------------------------------------------------------------------------
echo [start] Checking /v1/models for model '%MODEL_NAME%' ...
set "MODELS_ELAPSED=0"
set "MODELS_VERIFIED=0"
set "MODELS_HTTP=000"

:models_loop
if %MODELS_ELAPSED% geq %MODELS_TIMEOUT% goto models_done

curl -sf -o nul -w "%%{http_code}" --max-time 10 "http://localhost:%LLAMACPP_PORT%/v1/models" >"%TEMP%\democlaw_http.txt" 2>nul
if exist "%TEMP%\democlaw_http.txt" (
    set /p MODELS_HTTP=<"%TEMP%\democlaw_http.txt"
    del "%TEMP%\democlaw_http.txt" >nul 2>&1
)

if "!MODELS_HTTP!"=="200" (
    echo [start] llama.cpp /v1/models returned HTTP 200.
    set "MODELS_VERIFIED=1"
    goto models_done
)

timeout /t 5 /nobreak >nul
set /a "MODELS_ELAPSED+=5"
set /a "MOD15=MODELS_ELAPSED %% 15"
if !MOD15! equ 0 (
    echo [start]   ... waiting for /v1/models ^(!MODELS_ELAPSED!/%MODELS_TIMEOUT%s, HTTP !MODELS_HTTP!^)
)
goto models_loop

:models_done
if %MODELS_VERIFIED% equ 0 (
    echo [start] WARNING: /v1/models did not confirm model readiness within %MODELS_TIMEOUT%s.
    echo [start]   Last HTTP status: !MODELS_HTTP!
    echo [start]   The model may still be loading. Check: curl http://localhost:%LLAMACPP_PORT%/v1/models
    echo [start]   Container logs: %RUNTIME% logs -f %LLAMACPP_CONTAINER%
) else (
    echo [start]   Confirmed: model endpoint is serving.
)

:: ===========================================================================
:: Phase 3: Start OpenClaw
:: ===========================================================================
echo.
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
:: Wait for OpenClaw dashboard (HTTP 200 health-check)
:: ---------------------------------------------------------------------------
set "OC_ELAPSED=0"
set "OC_HEALTHY=0"
set "OC_HTTP=000"

:oc_health_loop
if %OC_ELAPSED% geq %OPENCLAW_HEALTH_TIMEOUT% goto oc_health_done

:: Check if container died
for /f "tokens=*" %%S in ('%RUNTIME% container inspect --format "{{.State.Status}}" %OPENCLAW_CONTAINER% 2^>nul') do set "OC_STATE=%%S"
if "!OC_STATE!"=="exited" goto oc_container_died
if "!OC_STATE!"=="dead" goto oc_container_died

:: Check dashboard endpoint
curl -sf -o nul -w "%%{http_code}" --max-time 5 "http://localhost:%OPENCLAW_PORT%/" >"%TEMP%\democlaw_oc_http.txt" 2>nul
if exist "%TEMP%\democlaw_oc_http.txt" (
    set /p OC_HTTP=<"%TEMP%\democlaw_oc_http.txt"
    del "%TEMP%\democlaw_oc_http.txt" >nul 2>&1
)

if "!OC_HTTP!"=="200" (
    set "OC_HEALTHY=1"
    goto oc_health_done
)

timeout /t 3 /nobreak >nul
set /a "OC_ELAPSED+=3"
set /a "OC_MOD15=OC_ELAPSED %% 15"
if !OC_MOD15! equ 0 (
    echo [start]   ... waiting for OpenClaw ^(!OC_ELAPSED!/%OPENCLAW_HEALTH_TIMEOUT%s, HTTP !OC_HTTP!^)
)
goto oc_health_loop

:oc_container_died
echo [start] ERROR: OpenClaw container exited unexpectedly. >&2
%RUNTIME% logs --tail 20 %OPENCLAW_CONTAINER% 2>&1
exit /b 1

:oc_health_done
if %OC_HEALTHY% equ 0 (
    echo [start] ERROR: OpenClaw dashboard did not return HTTP 200 within %OPENCLAW_HEALTH_TIMEOUT%s. >&2
    echo [start] Check logs: %RUNTIME% logs %OPENCLAW_CONTAINER% >&2
    exit /b 1
)
echo [start] OpenClaw dashboard health-check passed (HTTP 200).

:: ===========================================================================
:: Phase 4: Both health-checks passed -- print dashboard URL
:: ===========================================================================

:: Try to get tokenized dashboard URL from openclaw binary
set "DASHBOARD_URL="
for /f "tokens=*" %%U in ('%RUNTIME% exec %OPENCLAW_CONTAINER% openclaw dashboard --no-open 2^>nul') do (
    echo %%U | findstr /r "http[s]*://" >nul 2>&1
    if !errorlevel! equ 0 (
        set "DASHBOARD_URL=%%U"
    )
)

:: Fall back to localhost URL if tokenized URL not available
if not defined DASHBOARD_URL set "DASHBOARD_URL=http://localhost:%OPENCLAW_PORT%"

set "LLAMACPP_API_URL=http://localhost:%LLAMACPP_PORT%/v1"

echo.
echo [start] ========================================================
echo [start]   DemoClaw is running!
echo [start] ========================================================
echo.
echo [start]   Both health-checks passed:
echo [start]     * llama.cpp /v1/models .... HTTP 200
echo [start]     * OpenClaw dashboard . HTTP 200
echo.
echo [start]   Services:
echo [start]     llama.cpp API  : %LLAMACPP_API_URL%
echo [start]     Model     : %MODEL_NAME%
echo [start]     Runtime   : %RUNTIME%
echo.
echo [start]   Web UI Dashboard:
echo [start]     !DASHBOARD_URL!
echo.

:: Print bare dashboard URL to stdout for easy parsing by scripts/tools
echo !DASHBOARD_URL!

echo.
echo [start]   NOTE: On first connect, click "Connect" in the browser.
echo [start]         The device pairing is auto-approved within ~2 seconds.
echo [start]         If needed, click "Connect" again after approval.
echo.
echo [start]   Stop with: scripts\stop.bat  (or docker rm -f democlaw-llamacpp democlaw-openclaw)
echo [start] ========================================================

endlocal
exit /b 0

:: ===========================================================================
:: Subroutine: ensure_image
:: Pull image from Docker Hub first; fall back to local build on failure.
::
:: Arguments:
::   %~1  Image tag (e.g., jinwangmok/democlaw-llamacpp:v1.0.0)
::   %~2  Build context directory (e.g., C:\...\democlaw\llamacpp)
:: ===========================================================================
:ensure_image
set "IMG_TAG=%~1"
set "BUILD_CTX=%~2"

echo [start] Acquiring image '%IMG_TAG%' ...
echo [start]   Strategy: pull from registry first, local build fallback
echo [start]   Pulling '%IMG_TAG%' from registry ...

%RUNTIME% pull %IMG_TAG% >nul 2>&1
if !errorlevel! equ 0 (
    echo [start]   Pull succeeded. Using registry image '%IMG_TAG%'.
    exit /b 0
)

echo [start]   WARNING: Pull failed for '%IMG_TAG%'. Falling back to local build ...
echo [start]   Building '%IMG_TAG%' from %BUILD_CTX% ...

if not exist "%BUILD_CTX%" (
    echo [start] ERROR: Build context directory does not exist: %BUILD_CTX% >&2
    exit /b 1
)
if not exist "%BUILD_CTX%\Dockerfile" (
    echo [start] ERROR: No Dockerfile found in build context: %BUILD_CTX% >&2
    exit /b 1
)

%RUNTIME% build -t %IMG_TAG% "%BUILD_CTX%"
if !errorlevel! neq 0 (
    echo [start] ERROR: Both pull and local build failed for '%IMG_TAG%'. Cannot proceed. >&2
    exit /b 1
)
echo [start]   Local build succeeded. Image '%IMG_TAG%' is ready.
exit /b 0
