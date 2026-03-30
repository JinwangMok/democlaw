@echo off
:: =============================================================================
:: start-llamacpp.bat -- Launch the llama.cpp container with GPU passthrough
::
:: Supports Docker and Podman on Windows (Docker Desktop or Podman Desktop).
:: GPU passthrough uses --gpus all (Docker) or --device nvidia.com/gpu=all
:: (Podman 4+).
::
:: Usage:
::   scripts\windows\start-llamacpp.bat
::   set CONTAINER_RUNTIME=podman && scripts\windows\start-llamacpp.bat
::   set SKIP_MODEL_PULL=true && scripts\windows\start-llamacpp.bat
:: =============================================================================
setlocal EnableDelayedExpansion

:: ---------------------------------------------------------------------------
:: Resolve project root (two levels up from this script)
:: ---------------------------------------------------------------------------
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%i in ("%SCRIPT_DIR%\..\..") do set "PROJECT_ROOT=%%~fi"

:: ---------------------------------------------------------------------------
:: Load .env file if present
:: ---------------------------------------------------------------------------
set "ENV_FILE=%PROJECT_ROOT%\.env"
if exist "%ENV_FILE%" (
    echo [start-llamacpp] Loading environment from %ENV_FILE%
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
if not defined LLAMACPP_CONTAINER_NAME   set "LLAMACPP_CONTAINER_NAME=democlaw-llamacpp"
if not defined DEMOCLAW_NETWORK      set "DEMOCLAW_NETWORK=democlaw-net"
if not defined LLAMACPP_IMAGE_TAG        set "LLAMACPP_IMAGE_TAG=jinwangmok/democlaw-llamacpp:v1.0.0"
if not defined MODEL_NAME            set "MODEL_NAME=Qwen/Qwen3-4B-AWQ"
if not defined LLAMACPP_HOST             set "LLAMACPP_HOST=0.0.0.0"
if not defined LLAMACPP_PORT             set "LLAMACPP_PORT=8000"
if not defined LLAMACPP_HOST_PORT        set "LLAMACPP_HOST_PORT=8000"
if not defined MAX_MODEL_LEN         set "MAX_MODEL_LEN=16384"
if not defined GPU_MEMORY_UTILIZATION set "GPU_MEMORY_UTILIZATION=0.95"
if not defined QUANTIZATION          set "QUANTIZATION=awq_marlin"
if not defined DTYPE                 set "DTYPE=float16"
if not defined SKIP_MODEL_PULL       set "SKIP_MODEL_PULL=false"
if not defined LLAMACPP_HEALTH_TIMEOUT   set "LLAMACPP_HEALTH_TIMEOUT=300"

:: HuggingFace cache on Windows host
if not defined HF_CACHE_DIR (
    set "HF_CACHE_DIR=%USERPROFILE%\.cache\huggingface"
)

set "CONTAINER_NAME=%LLAMACPP_CONTAINER_NAME%"
set "NETWORK_NAME=%DEMOCLAW_NETWORK%"
set "IMAGE_TAG=%LLAMACPP_IMAGE_TAG%"

:: ---------------------------------------------------------------------------
:: Detect container runtime
:: ---------------------------------------------------------------------------
call :detect_runtime
if errorlevel 1 goto :error_no_runtime

:: ---------------------------------------------------------------------------
:: Validate NVIDIA GPU
:: ---------------------------------------------------------------------------
call :validate_gpu
if errorlevel 1 goto :end

:: ---------------------------------------------------------------------------
:: Ensure shared network exists
:: ---------------------------------------------------------------------------
call :ensure_network "%NETWORK_NAME%"

:: ---------------------------------------------------------------------------
:: Handle existing container
:: ---------------------------------------------------------------------------
call :handle_existing_container "%CONTAINER_NAME%"
if errorlevel 1 goto :end

:: ---------------------------------------------------------------------------
:: Build image if not present
:: ---------------------------------------------------------------------------
call :build_image "%IMAGE_TAG%" "%PROJECT_ROOT%\llamacpp"

:: ---------------------------------------------------------------------------
:: Prepare HuggingFace cache directory
:: ---------------------------------------------------------------------------
if not exist "%HF_CACHE_DIR%" (
    mkdir "%HF_CACHE_DIR%" 2>nul
)

:: ---------------------------------------------------------------------------
:: Pull model weights (unless SKIP_MODEL_PULL=true)
:: ---------------------------------------------------------------------------
if /i "%SKIP_MODEL_PULL%"=="true" (
    echo [start-llamacpp] SKIP_MODEL_PULL=true -- skipping model pre-pull.
) else (
    call :pull_model_weights
    if errorlevel 1 (
        echo [start-llamacpp] WARNING: Model pre-pull returned non-zero. llama.cpp will attempt download on start.
    )
)

:: ---------------------------------------------------------------------------
:: Build GPU flags
:: ---------------------------------------------------------------------------
call :get_gpu_flags
set "GPU_FLAGS=!_GPU_FLAGS!"

:: ---------------------------------------------------------------------------
:: Launch llama.cpp container
:: ---------------------------------------------------------------------------
echo [start-llamacpp] =======================================================
echo [start-llamacpp]   Step: Launch llama.cpp server container
echo [start-llamacpp] =======================================================
echo [start-llamacpp] Starting llama.cpp container '%CONTAINER_NAME%' ...
echo [start-llamacpp]   Model           : %MODEL_NAME%
echo [start-llamacpp]   Quantization    : %QUANTIZATION%
echo [start-llamacpp]   Max model len   : %MAX_MODEL_LEN%
echo [start-llamacpp]   GPU mem util    : %GPU_MEMORY_UTILIZATION%
echo [start-llamacpp]   Bind address    : %LLAMACPP_HOST%:%LLAMACPP_PORT%
echo [start-llamacpp]   Host port       : %LLAMACPP_HOST_PORT% -^> container %LLAMACPP_PORT%
echo [start-llamacpp]   HF cache        : %HF_CACHE_DIR%

set "HF_TOKEN_FLAG="
if defined HF_TOKEN (
    set "HF_TOKEN_FLAG=-e HF_TOKEN=%HF_TOKEN% -e HUGGING_FACE_HUB_TOKEN=%HF_TOKEN%"
)

%RUNTIME% run -d ^
    --name "%CONTAINER_NAME%" ^
    --network "%NETWORK_NAME%" ^
    --hostname llamacpp ^
    --network-alias llamacpp ^
    !GPU_FLAGS! ^
    --restart unless-stopped ^
    --shm-size 1g ^
    -p "%LLAMACPP_HOST_PORT%:%LLAMACPP_PORT%" ^
    -v "%HF_CACHE_DIR%:/root/.cache/huggingface:rw" ^
    -e "MODEL_NAME=%MODEL_NAME%" ^
    -e "LLAMACPP_HOST=%LLAMACPP_HOST%" ^
    -e "LLAMACPP_PORT=%LLAMACPP_PORT%" ^
    -e "MAX_MODEL_LEN=%MAX_MODEL_LEN%" ^
    -e "GPU_MEMORY_UTILIZATION=%GPU_MEMORY_UTILIZATION%" ^
    -e "QUANTIZATION=%QUANTIZATION%" ^
    -e "DTYPE=%DTYPE%" ^
    !HF_TOKEN_FLAG! ^
    --cap-drop ALL ^
    --security-opt no-new-privileges ^
    "%IMAGE_TAG%"

if errorlevel 1 (
    echo [start-llamacpp] ERROR: Failed to start container '%CONTAINER_NAME%'.
    exit /b 1
)

echo [start-llamacpp] Container '%CONTAINER_NAME%' started successfully.

:: ---------------------------------------------------------------------------
:: Wait for llama.cpp /health endpoint
:: ---------------------------------------------------------------------------
set "HEALTH_URL=http://localhost:%LLAMACPP_HOST_PORT%/health"
set "MODELS_URL=http://localhost:%LLAMACPP_HOST_PORT%/v1/models"
echo [start-llamacpp] Waiting for llama.cpp to become healthy (timeout: %LLAMACPP_HEALTH_TIMEOUT%s) ...
echo [start-llamacpp] Phase 1/2: Waiting for /health endpoint at %HEALTH_URL% ...

set /a "elapsed=0"
set /a "interval=5"

:wait_health_loop
if %elapsed% geq %LLAMACPP_HEALTH_TIMEOUT% goto :health_timeout

:: Check container still running
for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" "%CONTAINER_NAME%" 2^>nul') do set "CSTATE=%%s"
if "!CSTATE!"=="exited" goto :container_died
if "!CSTATE!"=="dead"   goto :container_died

curl -sf "%HEALTH_URL%" >nul 2>&1
if not errorlevel 1 (
    echo [start-llamacpp] /health endpoint is responding.
    goto :wait_models
)

timeout /t %interval% >nul 2>&1
set /a "elapsed=elapsed+interval"
echo [start-llamacpp]   ... waiting for /health (%elapsed%/%LLAMACPP_HEALTH_TIMEOUT%s)
goto :wait_health_loop

:container_died
echo [start-llamacpp] ERROR: Container '%CONTAINER_NAME%' exited unexpectedly (state: !CSTATE!).
echo [start-llamacpp] Check logs with: %RUNTIME% logs %CONTAINER_NAME%
%RUNTIME% logs --tail 30 "%CONTAINER_NAME%" 2>&1
exit /b 1

:health_timeout
echo [start-llamacpp] WARNING: llama.cpp /health did not respond within %LLAMACPP_HEALTH_TIMEOUT%s.
echo [start-llamacpp] The container is still running -- the model may still be loading.
echo [start-llamacpp] Check progress with: %RUNTIME% logs -f %CONTAINER_NAME%
exit /b 1

:wait_models
echo [start-llamacpp] Phase 2/2: Verifying /v1/models endpoint lists '%MODEL_NAME%' ...
set /a "models_elapsed=0"
set /a "models_timeout=60"

:wait_models_loop
if %models_elapsed% geq %models_timeout% goto :models_timeout

curl -sf --max-time 10 "%MODELS_URL%" >nul 2>&1
if not errorlevel 1 (
    echo [start-llamacpp] /v1/models endpoint is responding.
    echo [start-llamacpp]
    echo [start-llamacpp] llama.cpp server is healthy and ready to serve requests.
    echo [start-llamacpp]   API endpoint: http://localhost:%LLAMACPP_HOST_PORT%/v1
    echo [start-llamacpp]   Models API  : %MODELS_URL%
    echo [start-llamacpp]   Health check: %HEALTH_URL%
    exit /b 0
)

timeout /t %interval% >nul 2>&1
set /a "models_elapsed=models_elapsed+interval"
echo [start-llamacpp]   ... waiting for /v1/models (%models_elapsed%/%models_timeout%s)
goto :wait_models_loop

:models_timeout
echo [start-llamacpp] WARNING: /v1/models did not respond within %models_timeout%s after /health.
echo [start-llamacpp] The server is running but the model may still be loading.
echo [start-llamacpp] Check with: curl %MODELS_URL%
echo [start-llamacpp] Check logs: %RUNTIME% logs -f %CONTAINER_NAME%
exit /b 1

goto :end

:: ===========================================================================
:: Subroutines
:: ===========================================================================

:detect_runtime
if defined CONTAINER_RUNTIME (
    where "%CONTAINER_RUNTIME%" >nul 2>&1
    if errorlevel 1 (
        echo [start-llamacpp] ERROR: CONTAINER_RUNTIME='%CONTAINER_RUNTIME%' is set but not found in PATH.
        exit /b 1
    )
    set "RUNTIME=%CONTAINER_RUNTIME%"
    echo [start-llamacpp] Using container runtime: %RUNTIME%
    exit /b 0
)
where docker >nul 2>&1
if not errorlevel 1 (
    set "RUNTIME=docker"
    echo [start-llamacpp] Detected container runtime: docker
    exit /b 0
)
where podman >nul 2>&1
if not errorlevel 1 (
    set "RUNTIME=podman"
    echo [start-llamacpp] Detected container runtime: podman
    exit /b 0
)
exit /b 1

:error_no_runtime
echo [start-llamacpp] ERROR: No container runtime found. Install Docker Desktop or Podman Desktop.
exit /b 1

:validate_gpu
echo [start-llamacpp] Checking for nvidia-smi ...
where nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo [start-llamacpp] ERROR: nvidia-smi not found in PATH.
    echo [start-llamacpp]   Install NVIDIA drivers and ensure nvidia-smi is in PATH.
    echo [start-llamacpp]   Download: https://www.nvidia.com/Download/index.aspx
    exit /b 1
)
nvidia-smi >nul 2>&1
if errorlevel 1 (
    echo [start-llamacpp] ERROR: nvidia-smi is installed but failed to communicate with the NVIDIA driver.
    exit /b 1
)
echo [start-llamacpp] nvidia-smi is available and functional.

:: Check VRAM (requires nvidia-smi)
for /f "tokens=*" %%v in ('nvidia-smi --query-gpu^=memory.total --format^=csv^,noheader^,nounits 2^>nul') do (
    set "VRAM_MIB=%%v"
    set "VRAM_MIB=!VRAM_MIB: =!"
)
if not defined VRAM_MIB (
    echo [start-llamacpp] WARNING: Could not determine GPU VRAM. Proceeding anyway.
    exit /b 0
)
echo [start-llamacpp] Detected GPU VRAM: %VRAM_MIB% MiB
if %VRAM_MIB% lss 7500 (
    echo [start-llamacpp] ERROR: Insufficient GPU VRAM: %VRAM_MIB% MiB detected, 7500 MiB required.
    echo [start-llamacpp]   Qwen3-4B AWQ 4-bit requires ~8 GB VRAM.
    exit /b 1
)
exit /b 0

:ensure_network
set "_NET=%~1"
%RUNTIME% network inspect "%_NET%" >nul 2>&1
if errorlevel 1 (
    echo [start-llamacpp] Creating network '%_NET%' ...
    %RUNTIME% network create "%_NET%"
    if errorlevel 1 (
        echo [start-llamacpp] ERROR: Failed to create network '%_NET%'.
        exit /b 1
    )
) else (
    echo [start-llamacpp] Network '%_NET%' already exists.
)
exit /b 0

:handle_existing_container
set "_CNAME=%~1"
%RUNTIME% container inspect "%_CNAME%" >nul 2>&1
if errorlevel 1 exit /b 0

REM Idempotent: ALWAYS destroy and recreate — never skip running containers
for /f "tokens=*" %%s in ('%RUNTIME% container inspect --format "{{.State.Status}}" "%_CNAME%" 2^>nul') do set "_CSTATE=%%s"
echo [start-llamacpp] Removing existing container '%_CNAME%' (state: !_CSTATE!) for fresh recreation ...
%RUNTIME% rm -f "%_CNAME%" >nul 2>&1
exit /b 0

:build_image
set "_TAG=%~1"
set "_CTX=%~2"
echo [start-llamacpp] Acquiring image '%_TAG%' ...
echo [start-llamacpp]   Strategy: pull from registry first, local build fallback
echo [start-llamacpp]   Pulling '%_TAG%' from registry ...
%RUNTIME% pull "%_TAG%" >nul 2>&1
if errorlevel 1 (
    echo [start-llamacpp] WARNING: Pull failed for '%_TAG%'. Falling back to local build ...
    echo [start-llamacpp]   Building '%_TAG%' from %_CTX% ...
    %RUNTIME% build -t "%_TAG%" "%_CTX%"
    if errorlevel 1 (
        echo [start-llamacpp] ERROR: Both pull and local build failed for '%_TAG%'.
        exit /b 1
    )
    echo [start-llamacpp]   Local build succeeded.
) else (
    echo [start-llamacpp]   Pull succeeded. Using registry image '%_TAG%'.
)
exit /b 0

:get_gpu_flags
set "_GPU_FLAGS=--gpus all"
if "%RUNTIME%"=="podman" (
    set "_GPU_FLAGS=--device nvidia.com/gpu=all"
)
exit /b 0

:pull_model_weights
echo [start-llamacpp] =======================================================
echo [start-llamacpp]   Step: Pull model weights from HuggingFace
echo [start-llamacpp]   Model     : %MODEL_NAME%
echo [start-llamacpp]   Cache dir : %HF_CACHE_DIR%
echo [start-llamacpp] =======================================================
echo [start-llamacpp] This may take several minutes on first run (~5 GB download).

call :get_gpu_flags
set "_HF_ENV="
if defined HF_TOKEN (
    set "_HF_ENV=-e HF_TOKEN=%HF_TOKEN% -e HUGGING_FACE_HUB_TOKEN=%HF_TOKEN%"
)

%RUNTIME% run --rm ^
    --name "democlaw-llamacpp-pull" ^
    !_GPU_FLAGS! ^
    --shm-size 1g ^
    -v "%HF_CACHE_DIR%:/root/.cache/huggingface:rw" ^
    -e "HF_HUB_DISABLE_PROGRESS_BARS=0" ^
    !_HF_ENV! ^
    "%IMAGE_TAG%" ^
    python3 -c "import sys, os; cache=os.environ.get('HF_HOME', os.path.expanduser('~/.cache/huggingface')); print(f'[pull] HuggingFace cache: {cache}'); model_name='%MODEL_NAME%'; print(f'[pull] Downloading model: {model_name}'); [__import__('huggingface_hub').snapshot_download(repo_id=model_name, ignore_patterns=['*.pt','*.bin'])]"

exit /b %errorlevel%

:end
endlocal
