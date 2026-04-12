@echo off
setlocal enabledelayedexpansion
:: =============================================================================
:: apply-profile.bat — Model/config selection logic for DemoClaw (Windows)
::
:: Maps a hardware profile (detected or explicit) to the appropriate Gemma 4
:: model variant and runtime parameters. This is the bridge between hardware
:: detection and container configuration.
::
:: Profile mapping:
::   consumer_gpu / 8gb       -> Gemma 4 E4B Q4_K_M   (~3 GB, 8 GB VRAM)
::   dgx_spark    / dgx-spark -> Gemma 4 26B A4B MoE   (~16 GB, 128 GB unified)
::
:: Precedence (highest to lowest):
::   1. Explicitly set environment variables (from .env or shell)
::   2. Profile-derived defaults (set by this script)
::   3. Hardcoded fallbacks (E4B / 8GB VRAM scenario)
::
:: Usage:
::   call scripts\apply-profile.bat
::
:: Outputs (only sets variables that are not already defined):
::   MODEL_REPO, MODEL_FILE, MODEL_NAME, CTX_SIZE, N_GPU_LAYERS,
::   FLASH_ATTN, CACHE_TYPE_K, CACHE_TYPE_V, MIN_VRAM_MIB, MIN_DRIVER_VERSION,
::   LLAMACPP_MODEL_NAME, LLAMACPP_MAX_TOKENS, LLAMACPP_HEALTH_TIMEOUT
:: =============================================================================

set "AP_SCRIPT_DIR=%~dp0"
set "AP_SCRIPT_DIR=%AP_SCRIPT_DIR:~0,-1%"

:: ---------------------------------------------------------------------------
:: Step 1: Determine HARDWARE_PROFILE
:: ---------------------------------------------------------------------------
:: Normalize user-friendly aliases to canonical values
if defined HARDWARE_PROFILE (
    if "!HARDWARE_PROFILE!"=="8gb" (
        set "HARDWARE_PROFILE=consumer_gpu"
        echo [apply-profile] Hardware profile: consumer_gpu ^(from .env / environment^)
        goto :apply_profile
    )
    if "!HARDWARE_PROFILE!"=="consumer_gpu" (
        echo [apply-profile] Hardware profile: consumer_gpu ^(from .env / environment^)
        goto :apply_profile
    )
    if "!HARDWARE_PROFILE!"=="consumer-gpu" (
        set "HARDWARE_PROFILE=consumer_gpu"
        echo [apply-profile] Hardware profile: consumer_gpu ^(from .env / environment^)
        goto :apply_profile
    )
    if "!HARDWARE_PROFILE!"=="dgx-spark" (
        set "HARDWARE_PROFILE=dgx_spark"
        echo [apply-profile] Hardware profile: dgx_spark ^(from .env / environment^)
        goto :apply_profile
    )
    if "!HARDWARE_PROFILE!"=="dgx_spark" (
        echo [apply-profile] Hardware profile: dgx_spark ^(from .env / environment^)
        goto :apply_profile
    )
    if "!HARDWARE_PROFILE!"=="dgx" (
        set "HARDWARE_PROFILE=dgx_spark"
        echo [apply-profile] Hardware profile: dgx_spark ^(from .env / environment^)
        goto :apply_profile
    )
    :: Unrecognized value — fall through to auto-detection
    echo [apply-profile] WARNING: Unrecognized HARDWARE_PROFILE='!HARDWARE_PROFILE!' >&2
    echo [apply-profile]   Valid values: 8gb, consumer_gpu, dgx-spark, dgx_spark >&2
    echo [apply-profile]   Falling back to auto-detection ... >&2
    set "HARDWARE_PROFILE="
)

:: Auto-detect if not set
echo [apply-profile] Running hardware auto-detection ...
if exist "%AP_SCRIPT_DIR%\detect-hardware.bat" (
    call "%AP_SCRIPT_DIR%\detect-hardware.bat"
) else (
    echo [apply-profile] WARNING: detect-hardware.bat not found. Defaulting to consumer_gpu.
    set "HARDWARE_PROFILE=consumer_gpu"
)

:: ---------------------------------------------------------------------------
:: Step 2: Apply profile-specific defaults
:: ---------------------------------------------------------------------------
:apply_profile
echo.
echo [apply-profile] ========================================
echo [apply-profile]   Model/Config Selection
echo [apply-profile] ========================================

if "!HARDWARE_PROFILE!"=="dgx_spark" (
    goto :apply_dgx_spark
) else (
    goto :apply_consumer_gpu
)

:: --- Gemma 4 E4B (consumer GPU, 8GB VRAM) --------------------------------
:apply_consumer_gpu
echo [apply-profile] Applying profile: Gemma 4 E4B ^(consumer GPU / 8GB VRAM^)

if not defined LLM_ENGINE             set "LLM_ENGINE=llamacpp"
if not defined MODEL_REPO              set "MODEL_REPO=unsloth/gemma-4-E4B-it-GGUF"
if not defined MODEL_FILE              set "MODEL_FILE=gemma-4-E4B-it-Q4_K_M.gguf"
if not defined MODEL_NAME              set "MODEL_NAME=gemma-4-E4B-it"
if not defined CTX_SIZE                set "CTX_SIZE=131072"
if not defined N_GPU_LAYERS            set "N_GPU_LAYERS=99"
if not defined FLASH_ATTN              set "FLASH_ATTN=1"
if not defined CACHE_TYPE_K            set "CACHE_TYPE_K=q4_0"
if not defined CACHE_TYPE_V            set "CACHE_TYPE_V=q4_0"
if not defined MIN_VRAM_MIB            set "MIN_VRAM_MIB=7000"
if not defined MIN_DRIVER_VERSION      set "MIN_DRIVER_VERSION=525.0"
if not defined LLAMACPP_MODEL_NAME     set "LLAMACPP_MODEL_NAME=gemma-4-E4B-it"
if not defined LLAMACPP_MAX_TOKENS     set "LLAMACPP_MAX_TOKENS=4096"
if not defined LLAMACPP_HEALTH_TIMEOUT set "LLAMACPP_HEALTH_TIMEOUT=600"
if not defined LLAMACPP_TEMPERATURE    set "LLAMACPP_TEMPERATURE=0.7"

goto :print_summary

:: --- Gemma 4 26B A4B MoE (DGX Spark, 128GB unified memory) ---------------
:apply_dgx_spark
echo [apply-profile] Applying profile: Gemma 4 26B A4B MoE ^(DGX Spark / 128GB^)

if not defined LLM_ENGINE             set "LLM_ENGINE=vllm"
if not defined VLLM_IMAGE             set "VLLM_IMAGE=vllm/vllm-openai:gemma4-cu130"
if not defined VLLM_MODEL_ID          set "VLLM_MODEL_ID=google/gemma-4-26B-A4B-it"
if not defined VLLM_PORT              set "VLLM_PORT=8000"
if not defined VLLM_GPU_MEM_UTIL      set "VLLM_GPU_MEM_UTIL=0.70"
if not defined VLLM_QUANTIZATION      set "VLLM_QUANTIZATION=fp8"
if not defined VLLM_EXTRA_ARGS        set "VLLM_EXTRA_ARGS=--kv-cache-dtype fp8 --load-format safetensors --enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4 --enable-prefix-caching --enable-chunked-prefill --max-num-seqs 4 --max-num-batched-tokens 8192"
if not defined VLLM_MAX_MODEL_LEN     set "VLLM_MAX_MODEL_LEN=262144"
if not defined VLLM_HEALTH_TIMEOUT    set "VLLM_HEALTH_TIMEOUT=3600"
if not defined MODEL_NAME              set "MODEL_NAME=gemma-4-26B-A4B-it"
if not defined MIN_VRAM_MIB            set "MIN_VRAM_MIB=16000"
if not defined MIN_DRIVER_VERSION      set "MIN_DRIVER_VERSION=550.0"
if not defined LLAMACPP_MODEL_NAME     set "LLAMACPP_MODEL_NAME=gemma-4-26B-A4B-it"
if not defined LLAMACPP_MAX_TOKENS     set "LLAMACPP_MAX_TOKENS=8192"
if not defined LLAMACPP_TEMPERATURE    set "LLAMACPP_TEMPERATURE=0.7"
if not defined MODEL_REPO              set "MODEL_REPO=unsloth/gemma-4-26B-A4B-it-GGUF"
if not defined MODEL_FILE              set "MODEL_FILE=gemma-4-26B-A4B-it-Q8_0.gguf"
if not defined CTX_SIZE                set "CTX_SIZE=262144"
if not defined N_GPU_LAYERS            set "N_GPU_LAYERS=99"
if not defined FLASH_ATTN              set "FLASH_ATTN=1"
if not defined CACHE_TYPE_K            set "CACHE_TYPE_K=q8_0"
if not defined CACHE_TYPE_V            set "CACHE_TYPE_V=q8_0"
if not defined LLAMACPP_HEALTH_TIMEOUT set "LLAMACPP_HEALTH_TIMEOUT=1800"

goto :print_summary

:: ---------------------------------------------------------------------------
:: Print summary
:: ---------------------------------------------------------------------------
:print_summary
if "!LLM_ENGINE!"=="vllm" (
    echo [apply-profile]   Engine    : vLLM ^(FP8 online quantization^)
    echo [apply-profile]   Image     : !VLLM_IMAGE!
    echo [apply-profile]   Model     : !VLLM_MODEL_ID!
    echo [apply-profile]   Context   : !VLLM_MAX_MODEL_LEN! tokens
) else (
    echo [apply-profile]   Model     : !MODEL_REPO!/!MODEL_FILE!
    echo [apply-profile]   Context   : !CTX_SIZE! tokens
    echo [apply-profile]   KV cache  : K=!CACHE_TYPE_K!, V=!CACHE_TYPE_V!
)
echo [apply-profile]   Min VRAM  : !MIN_VRAM_MIB! MiB
echo [apply-profile] ========================================

:: ---------------------------------------------------------------------------
:: Export results to caller's environment via endlocal trick
:: ---------------------------------------------------------------------------
endlocal & (
    set "HARDWARE_PROFILE=%HARDWARE_PROFILE%"
    set "LLM_ENGINE=%LLM_ENGINE%"
    set "VLLM_IMAGE=%VLLM_IMAGE%"
    set "VLLM_MODEL_ID=%VLLM_MODEL_ID%"
    set "VLLM_PORT=%VLLM_PORT%"
    set "VLLM_GPU_MEM_UTIL=%VLLM_GPU_MEM_UTIL%"
    set "VLLM_QUANTIZATION=%VLLM_QUANTIZATION%"
    set "VLLM_EXTRA_ARGS=%VLLM_EXTRA_ARGS%"
    set "VLLM_MAX_MODEL_LEN=%VLLM_MAX_MODEL_LEN%"
    set "VLLM_HEALTH_TIMEOUT=%VLLM_HEALTH_TIMEOUT%"
    set "MODEL_REPO=%MODEL_REPO%"
    set "MODEL_FILE=%MODEL_FILE%"
    set "MODEL_NAME=%MODEL_NAME%"
    set "CTX_SIZE=%CTX_SIZE%"
    set "N_GPU_LAYERS=%N_GPU_LAYERS%"
    set "FLASH_ATTN=%FLASH_ATTN%"
    set "CACHE_TYPE_K=%CACHE_TYPE_K%"
    set "CACHE_TYPE_V=%CACHE_TYPE_V%"
    set "MIN_VRAM_MIB=%MIN_VRAM_MIB%"
    set "MIN_DRIVER_VERSION=%MIN_DRIVER_VERSION%"
    set "LLAMACPP_MODEL_NAME=%LLAMACPP_MODEL_NAME%"
    set "LLAMACPP_MAX_TOKENS=%LLAMACPP_MAX_TOKENS%"
    set "LLAMACPP_HEALTH_TIMEOUT=%LLAMACPP_HEALTH_TIMEOUT%"
    set "LLAMACPP_TEMPERATURE=%LLAMACPP_TEMPERATURE%"
)
exit /b 0
