@echo off
setlocal enabledelayedexpansion
:: =============================================================================
:: detect-hardware.bat — DGX Spark / consumer GPU hardware detection utility
::
:: Windows port of detect-hardware.sh. Identifies the deployment hardware by
:: querying nvidia-smi for GPU device name and total memory, then returns a
:: hardware profile used to select the appropriate Gemma 4 model variant:
::
::   HARDWARE_PROFILE=dgx_spark    -> Gemma 4 26B A4B MoE (128GB unified memory)
::   HARDWARE_PROFILE=consumer_gpu -> Gemma 4 E4B          (8GB VRAM)
::
:: Usage:
::   call scripts\detect-hardware.bat
::   echo %HARDWARE_PROFILE%
::
:: Outputs (set as environment variables in caller's scope via endlocal trick):
::   HARDWARE_PROFILE       — "dgx_spark" or "consumer_gpu"
::   GPU_NAME               — GPU device name from nvidia-smi
::   GPU_TOTAL_VRAM_MIB     — Total GPU memory in MiB
::   HARDWARE_DETECT_METHOD — How the profile was determined
:: =============================================================================

:: ---------------------------------------------------------------------------
:: Constants
:: ---------------------------------------------------------------------------
set "PROFILE_DGX_SPARK=dgx_spark"
set "PROFILE_CONSUMER_GPU=consumer_gpu"
set "DGX_MEMORY_THRESHOLD_MIB=65536"

:: ---------------------------------------------------------------------------
:: Initialize output variables
:: ---------------------------------------------------------------------------
set "HW_PROFILE="
set "HW_GPU_NAME="
set "HW_GPU_VRAM=0"
set "HW_DETECT_METHOD="

:: ---------------------------------------------------------------------------
:: Gather GPU info from nvidia-smi (always, for diagnostics)
:: ---------------------------------------------------------------------------
set "HW_NVIDIA_OK=0"
where nvidia-smi >nul 2>&1
if !errorlevel! neq 0 (
    echo [detect-hardware] WARNING: nvidia-smi not found. Cannot detect GPU hardware. >&2
    goto :check_env_override
)
set "HW_NVIDIA_OK=1"

:: Query GPU name (use skip=1 to skip CSV header — avoids noheader parsing issues on Windows)
for /f "skip=1 tokens=*" %%G in ('nvidia-smi --query-gpu=gpu_name --format=csv 2^>nul') do (
    if not defined HW_GPU_NAME set "HW_GPU_NAME=%%G"
)

:: Query GPU memory (MiB)
:: Try with nounits first (returns plain number), fall back to parsing "8192 MiB"
set "HW_GPU_VRAM=0"
for /f "skip=1 tokens=1 delims= " %%M in ('nvidia-smi --query-gpu=memory.total --format=csv 2^>nul') do (
    if "!HW_GPU_VRAM!"=="0" (
        set "HW_GPU_VRAM_RAW=%%M"
        :: Strip non-numeric characters (handles "8192" or "8192 MiB")
        for /f "delims=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ " %%N in ("%%M") do (
            set "HW_GPU_VRAM=%%N"
        )
    )
)

:: Final numeric validation — if still not a number, default to 0
set /a "HW_GPU_VRAM=HW_GPU_VRAM+0" 2>nul

echo [detect-hardware] GPU name   : !HW_GPU_NAME!
echo [detect-hardware] GPU memory : !HW_GPU_VRAM! MiB

:: ---------------------------------------------------------------------------
:: Priority 1: Explicit override via HARDWARE_PROFILE env var
:: ---------------------------------------------------------------------------
:check_env_override
if defined HARDWARE_PROFILE (
    if "!HARDWARE_PROFILE!"=="dgx_spark" (
        set "HW_PROFILE=dgx_spark"
        set "HW_DETECT_METHOD=env_override"
        echo [detect-hardware] Using explicit HARDWARE_PROFILE=dgx_spark ^(env override^)
        goto :print_summary
    )
    if "!HARDWARE_PROFILE!"=="consumer_gpu" (
        set "HW_PROFILE=consumer_gpu"
        set "HW_DETECT_METHOD=env_override"
        echo [detect-hardware] Using explicit HARDWARE_PROFILE=consumer_gpu ^(env override^)
        goto :print_summary
    )
    echo [detect-hardware] WARNING: Invalid HARDWARE_PROFILE='!HARDWARE_PROFILE!'. Falling back to auto-detection. >&2
    set "HARDWARE_PROFILE="
)

:: If nvidia-smi not available, fall back
if "!HW_NVIDIA_OK!"=="0" (
    set "HW_PROFILE=consumer_gpu"
    set "HW_DETECT_METHOD=fallback"
    goto :print_summary
)

:: ---------------------------------------------------------------------------
:: Priority 2: GPU device name matching
:: ---------------------------------------------------------------------------
if defined HW_GPU_NAME (
    echo !HW_GPU_NAME! | findstr /i "GH200" >nul 2>&1
    if !errorlevel! equ 0 (
        set "HW_PROFILE=dgx_spark"
        set "HW_DETECT_METHOD=gpu_name"
        echo [detect-hardware] Detected DGX Spark via GPU name: '!HW_GPU_NAME!'
        goto :print_summary
    )

    echo !HW_GPU_NAME! | findstr /i "Grace Hopper" >nul 2>&1
    if !errorlevel! equ 0 (
        set "HW_PROFILE=dgx_spark"
        set "HW_DETECT_METHOD=gpu_name"
        echo [detect-hardware] Detected DGX Spark via GPU name: '!HW_GPU_NAME!'
        goto :print_summary
    )

    echo !HW_GPU_NAME! | findstr /i "DGX" >nul 2>&1
    if !errorlevel! equ 0 (
        set "HW_PROFILE=dgx_spark"
        set "HW_DETECT_METHOD=gpu_name"
        echo [detect-hardware] Detected DGX Spark via GPU name: '!HW_GPU_NAME!'
        goto :print_summary
    )

    echo !HW_GPU_NAME! | findstr /i "GB10" >nul 2>&1
    if !errorlevel! equ 0 (
        set "HW_PROFILE=dgx_spark"
        set "HW_DETECT_METHOD=gpu_name"
        echo [detect-hardware] Detected DGX Spark via GPU name: '!HW_GPU_NAME!'
        goto :print_summary
    )

    echo !HW_GPU_NAME! | findstr /i "Blackwell" >nul 2>&1
    if !errorlevel! equ 0 (
        set "HW_PROFILE=dgx_spark"
        set "HW_DETECT_METHOD=gpu_name"
        echo [detect-hardware] Detected DGX Spark via GPU name: '!HW_GPU_NAME!'
        goto :print_summary
    )

    echo !HW_GPU_NAME! | findstr /i "Spark" >nul 2>&1
    if !errorlevel! equ 0 (
        set "HW_PROFILE=dgx_spark"
        set "HW_DETECT_METHOD=gpu_name"
        echo [detect-hardware] Detected DGX Spark via GPU name: '!HW_GPU_NAME!'
        goto :print_summary
    )
)

:: ---------------------------------------------------------------------------
:: Priority 3: System identifiers (Windows — check WMI for DGX product name)
:: ---------------------------------------------------------------------------
for /f "tokens=*" %%P in ('wmic computersystem get model 2^>nul ^| findstr /i "DGX Grace GH200 GB10 Blackwell Spark"') do (
    set "HW_PROFILE=dgx_spark"
    set "HW_DETECT_METHOD=system_id"
    echo [detect-hardware] Detected DGX Spark via system identifier: %%P
    goto :print_summary
)

:: ---------------------------------------------------------------------------
:: Priority 4: GPU memory threshold (>= 65536 MiB = 64 GB)
:: ---------------------------------------------------------------------------
if !HW_GPU_VRAM! geq %DGX_MEMORY_THRESHOLD_MIB% (
    set "HW_PROFILE=dgx_spark"
    set "HW_DETECT_METHOD=gpu_memory"
    echo [detect-hardware] Detected DGX Spark via GPU memory: !HW_GPU_VRAM! MiB ^>= %DGX_MEMORY_THRESHOLD_MIB% MiB threshold
    goto :print_summary
)

:: ---------------------------------------------------------------------------
:: Priority 5: Fallback to consumer GPU
:: ---------------------------------------------------------------------------
set "HW_PROFILE=consumer_gpu"
set "HW_DETECT_METHOD=fallback"
echo [detect-hardware] No DGX Spark detected. Using consumer GPU profile.

:: ---------------------------------------------------------------------------
:: Print summary
:: ---------------------------------------------------------------------------
:print_summary
echo.
echo [detect-hardware] ========================================
echo [detect-hardware]   Hardware Detection Results
echo [detect-hardware] ========================================
echo [detect-hardware]   Profile   : !HW_PROFILE!
echo [detect-hardware]   GPU       : !HW_GPU_NAME!
echo [detect-hardware]   VRAM      : !HW_GPU_VRAM! MiB
echo [detect-hardware]   Method    : !HW_DETECT_METHOD!
echo [detect-hardware] ========================================

:: ---------------------------------------------------------------------------
:: Export results to caller's environment via endlocal trick
:: ---------------------------------------------------------------------------
endlocal & (
    set "HARDWARE_PROFILE=%HW_PROFILE%"
    set "GPU_NAME=%HW_GPU_NAME%"
    set "GPU_TOTAL_VRAM_MIB=%HW_GPU_VRAM%"
    set "HARDWARE_DETECT_METHOD=%HW_DETECT_METHOD%"
)
exit /b 0
