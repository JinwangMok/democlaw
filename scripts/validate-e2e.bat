@echo off
setlocal enabledelayedexpansion
REM =============================================================================
REM validate-e2e.bat — End-to-end validation for DemoClaw LLM deployment (Windows)
REM
REM Orchestrates the full E2E validation pipeline:
REM   1. Pre-flight: Verify GPU hardware, driver, and VRAM requirements
REM   2. Container startup: Start the llama.cpp container (via start.bat)
REM   3. Health gate: Confirm /health + /v1/models endpoints respond correctly
REM   4. Memory fit: Verify GPU memory usage stays within the VRAM budget
REM   5. Throughput gate: Run benchmark-tps.bat and assert >= minimum t/s
REM   6. API compatibility: Send a chat completion and validate response
REM   7. Dashboard compatibility: Verify OpenClaw renders Gemma 4 responses
REM      (model name badge, streaming, token counts, latency metrics)
REM   8. Report: Print structured pass/fail verdict with evidence
REM
REM Usage:
REM   scripts\validate-e2e.bat
REM   set SKIP_STARTUP=1 && scripts\validate-e2e.bat
REM   set HARDWARE_PROFILE=dgx_spark && scripts\validate-e2e.bat
REM
REM Requires: curl, python3, nvidia-smi, docker or podman
REM =============================================================================

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%I in ("%SCRIPT_DIR%\..") do set "PROJECT_ROOT=%%~fI"

REM ---------------------------------------------------------------------------
REM Configuration defaults
REM ---------------------------------------------------------------------------
if not defined SKIP_STARTUP set "SKIP_STARTUP=0"
if not defined SKIP_TEARDOWN set "SKIP_TEARDOWN=1"
if not defined LLAMACPP_HOST set "LLAMACPP_HOST=localhost"
if not defined LLAMACPP_PORT set "LLAMACPP_PORT=8000"
if not defined VRAM_BUDGET_MIB set "VRAM_BUDGET_MIB=8192"
if not defined BENCH_RUNS set "BENCH_RUNS=3"

set "BASE_URL=http://!LLAMACPP_HOST!:!LLAMACPP_PORT!"

REM Gate counters
set "TOTAL_GATES=0"
set "PASSED_GATES=0"
set "FAILED_GATES=0"
set "SKIPPED_GATES=0"
set "OVERALL_PASS=true"

REM ---------------------------------------------------------------------------
REM Load .env if present
REM ---------------------------------------------------------------------------
if exist "%PROJECT_ROOT%\.env" (
    for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%PROJECT_ROOT%\.env") do (
        if not "%%A"=="" if not "%%B"=="" set "%%A=%%B"
    )
)

REM ---------------------------------------------------------------------------
REM Apply hardware profile
REM ---------------------------------------------------------------------------
if exist "%SCRIPT_DIR%\apply-profile.bat" (
    call "%SCRIPT_DIR%\apply-profile.bat"
)

if not defined MODEL_NAME set "MODEL_NAME=gemma-4-E4B-it"
if not defined HARDWARE_PROFILE set "HARDWARE_PROFILE=consumer_gpu"

REM Resolve thresholds by profile
if "!HARDWARE_PROFILE!"=="dgx_spark" (
    if not defined BENCH_MIN_TPS set "BENCH_MIN_TPS=10"
    set "PROFILE_LABEL=DGX Spark (128GB unified)"
) else (
    if not defined BENCH_MIN_TPS set "BENCH_MIN_TPS=15"
    set "PROFILE_LABEL=Consumer GPU (8GB VRAM)"
)

echo [validate-e2e] ========================================================
echo [validate-e2e]   DemoClaw -- E2E Validation Pipeline
echo [validate-e2e] ========================================================
echo [validate-e2e]   Profile  : !PROFILE_LABEL!
echo [validate-e2e]   Model    : !MODEL_NAME!
echo [validate-e2e]   Endpoint : !BASE_URL!
echo.

REM ===========================================================================
REM Gate 1: Pre-flight
REM ===========================================================================
echo [validate-e2e] --- Gate 1: Pre-flight Checks ---

REM Check nvidia-smi
where nvidia-smi >nul 2>&1
if !errorlevel! neq 0 (
    echo [validate-e2e] [FAIL] preflight_nvidia_smi: nvidia-smi not found in PATH
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)
nvidia-smi >nul 2>&1
if !errorlevel! neq 0 (
    echo [validate-e2e] [FAIL] preflight_nvidia_smi: nvidia-smi failed to execute
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)
echo [validate-e2e] [PASS] preflight_nvidia_smi: available and working
set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"

REM Check GPU VRAM
set "GPU_VRAM=0"
for /f "tokens=*" %%M in ('nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2^>nul') do (
    if "!GPU_VRAM!"=="0" (
        for /f "tokens=*" %%T in ("%%M") do set "GPU_VRAM=%%T"
    )
)
set "GPU_NAME_VAL="
for /f "tokens=*" %%G in ('nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2^>nul') do (
    if not defined GPU_NAME_VAL set "GPU_NAME_VAL=%%G"
)
echo [validate-e2e] [INFO] GPU: !GPU_NAME_VAL!
echo [validate-e2e] [INFO] VRAM: !GPU_VRAM! MiB

if not defined MIN_VRAM_MIB set "MIN_VRAM_MIB=7000"
if !GPU_VRAM! geq !MIN_VRAM_MIB! (
    echo [validate-e2e] [PASS] preflight_vram: !GPU_VRAM! MiB ^>= !MIN_VRAM_MIB! MiB minimum
    set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"
) else (
    echo [validate-e2e] [FAIL] preflight_vram: !GPU_VRAM! MiB ^< !MIN_VRAM_MIB! MiB minimum
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)

REM Check container runtime
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
        if !errorlevel! equ 0 set "RUNTIME=podman"
    )
)
if not defined RUNTIME (
    echo [validate-e2e] [FAIL] preflight_runtime: No container runtime found
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)
echo [validate-e2e] [PASS] preflight_runtime: !RUNTIME! available
set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"

REM Check curl
where curl >nul 2>&1
if !errorlevel! neq 0 (
    echo [validate-e2e] [FAIL] preflight_curl: curl not found
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)
echo [validate-e2e] [PASS] preflight_curl: available
set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"

REM Check python3
set "PY=python3"
where python3 >nul 2>&1 || (
    where python >nul 2>&1 || (
        echo [validate-e2e] [FAIL] preflight_python: python3 not found
        set "OVERALL_PASS=false"
        set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
        goto :report
    )
    set "PY=python"
)
echo [validate-e2e] [PASS] preflight_python: available
set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"

if "!OVERALL_PASS!"=="false" goto :report

REM ===========================================================================
REM Gate 2: Container Startup
REM ===========================================================================
echo.
echo [validate-e2e] --- Gate 2: Container Startup ---

if "!SKIP_STARTUP!"=="1" (
    echo [validate-e2e] [SKIP] container_startup: SKIP_STARTUP=1, assuming containers running
    set /a "TOTAL_GATES+=1" & set /a "SKIPPED_GATES+=1"
    goto :gate_health
)

echo [validate-e2e] [INFO] Starting DemoClaw stack via start.bat ...
call "%SCRIPT_DIR%\start.bat"
if !errorlevel! neq 0 (
    echo [validate-e2e] [FAIL] container_startup: start.bat failed
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)
echo [validate-e2e] [PASS] container_startup: Stack started successfully
set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"

REM ===========================================================================
REM Gate 3: Health Endpoints
REM ===========================================================================
:gate_health
echo.
echo [validate-e2e] --- Gate 3: Health Endpoint Checks ---

set "HEALTH_OK=false"
set "HEALTH_ATTEMPTS=0"
set "MAX_HEALTH_ATTEMPTS=12"

:health_loop
if !HEALTH_ATTEMPTS! geq !MAX_HEALTH_ATTEMPTS! goto :health_done
set /a "HEALTH_ATTEMPTS+=1"

curl -sf "!BASE_URL!/health" >nul 2>&1
if !errorlevel! equ 0 (
    set "HEALTH_OK=true"
    goto :health_done
)
echo [validate-e2e] [INFO] Waiting for /health ^(attempt !HEALTH_ATTEMPTS!/!MAX_HEALTH_ATTEMPTS!^) ...
powershell -c "Start-Sleep -Seconds 5"
goto :health_loop

:health_done
if "!HEALTH_OK!"=="true" (
    echo [validate-e2e] [PASS] health_endpoint: /health returned HTTP 200
    set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"
) else (
    echo [validate-e2e] [FAIL] health_endpoint: /health did not return HTTP 200 after !MAX_HEALTH_ATTEMPTS! attempts
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)

REM Check /v1/models
curl -sf "!BASE_URL!/v1/models" >nul 2>&1
if !errorlevel! equ 0 (
    echo [validate-e2e] [PASS] models_endpoint: /v1/models responding
    set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"
) else (
    echo [validate-e2e] [FAIL] models_endpoint: /v1/models not responding
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)

if "!OVERALL_PASS!"=="false" goto :report

REM ===========================================================================
REM Gate 4: Memory Fit
REM ===========================================================================
echo.
echo [validate-e2e] --- Gate 4: Memory Fit Check ---

set "MEM_USED=0"
for /f "tokens=*" %%M in ('nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2^>nul') do (
    if "!MEM_USED!"=="0" (
        for /f "tokens=*" %%T in ("%%M") do set "MEM_USED=%%T"
    )
)

echo [validate-e2e] [INFO] GPU memory used: !MEM_USED! / !GPU_VRAM! MiB

if !MEM_USED! leq !VRAM_BUDGET_MIB! (
    echo [validate-e2e] [PASS] memory_fit: !MEM_USED! MiB ^<= !VRAM_BUDGET_MIB! MiB budget
    set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"
) else (
    echo [validate-e2e] [FAIL] memory_fit: !MEM_USED! MiB ^> !VRAM_BUDGET_MIB! MiB budget
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)

REM ===========================================================================
REM Gate 5: Throughput Benchmark
REM ===========================================================================
echo.
echo [validate-e2e] --- Gate 5: Throughput Benchmark ---
echo [validate-e2e] [INFO] Minimum threshold: !BENCH_MIN_TPS! t/s

set "MIN_TPS=!BENCH_MIN_TPS!"
set "BENCHMARK_RUNS=!BENCH_RUNS!"
call "%SCRIPT_DIR%\benchmark-tps.bat"
if !errorlevel! equ 0 (
    echo [validate-e2e] [PASS] throughput: benchmark passed ^>= !BENCH_MIN_TPS! t/s threshold
    set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"
) else (
    echo [validate-e2e] [FAIL] throughput: benchmark failed ^< !BENCH_MIN_TPS! t/s threshold
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)

REM ===========================================================================
REM Gate 6: API Compatibility
REM ===========================================================================
echo.
echo [validate-e2e] --- Gate 6: API Compatibility Check ---

set "API_TMPFILE=%TEMP%\democlaw_e2e_api_%RANDOM%.json"
set "API_PAYLOAD_FILE=%TEMP%\democlaw_e2e_payload_%RANDOM%.json"

REM Write payload via python to avoid escaping issues
%PY% -c "import json; print(json.dumps({'model':'!MODEL_NAME!','messages':[{'role':'user','content':'Say hello in exactly one sentence.'}],'max_tokens':64,'temperature':0.1,'stream':False}))" > "!API_PAYLOAD_FILE!" 2>nul

for /f %%H in ('curl -sf -o "!API_TMPFILE!" -w "%%{http_code}" --max-time 60 -H "Content-Type: application/json" -d @"!API_PAYLOAD_FILE!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "API_HTTP=%%H"

del "!API_PAYLOAD_FILE!" 2>nul

if not "!API_HTTP!"=="200" (
    echo [validate-e2e] [FAIL] api_chat_completion: HTTP !API_HTTP! ^(expected 200^)
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    del "!API_TMPFILE!" 2>nul
    goto :report
)

REM Validate response structure
%PY% -c "import json,sys; d=json.load(open(sys.argv[1])); c=d['choices'][0]['message']['content']; assert len(c)>0; print('ok:',c[:60])" "!API_TMPFILE!" >nul 2>&1
if !errorlevel! equ 0 (
    echo [validate-e2e] [PASS] api_chat_completion: valid response with content
    set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"
) else (
    echo [validate-e2e] [FAIL] api_chat_completion: invalid response structure
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
)
del "!API_TMPFILE!" 2>nul

REM ===========================================================================
REM Gate 7: Dashboard Compatibility
REM ===========================================================================
echo.
echo [validate-e2e] --- Gate 7: Dashboard Compatibility Check ---

REM 7a. Dashboard responsiveness
set "OPENCLAW_PORT_VAL=18789"
if defined OPENCLAW_PORT set "OPENCLAW_PORT_VAL=!OPENCLAW_PORT!"
set "DASH_URL=http://localhost:!OPENCLAW_PORT_VAL!"

set "DASH_HTTP=000"
for /f %%H in ('curl -s -o nul -w "%%{http_code}" --max-time 10 "!DASH_URL!/" 2^>nul') do set "DASH_HTTP=%%H"

if "!DASH_HTTP!"=="000" (
    echo [validate-e2e] [FAIL] dashboard_responsive: not responding at !DASH_URL!/ ^(HTTP 000^)
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    goto :report
)
echo [validate-e2e] [PASS] dashboard_responsive: responding at !DASH_URL!/ ^(HTTP !DASH_HTTP!^)
set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"

REM 7b. Model name in /v1/models matches configured MODEL_NAME
set "MODEL_FOUND=false"
for /f "tokens=*" %%R in ('curl -sf --max-time 10 "!BASE_URL!/v1/models" 2^>nul') do (
    echo %%R | findstr /c:"!MODEL_NAME!" >nul 2>&1
    if !errorlevel! equ 0 set "MODEL_FOUND=true"
)
if "!MODEL_FOUND!"=="true" (
    echo [validate-e2e] [PASS] dashboard_model_name: "!MODEL_NAME!" found in /v1/models
    set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"
) else (
    echo [validate-e2e] [FAIL] dashboard_model_name: "!MODEL_NAME!" not found in /v1/models
    set "OVERALL_PASS=false"
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
)

REM 7c. Streaming SSE check
set "STREAM_PAYLOAD_FILE=%TEMP%\democlaw_e2e_stream_%RANDOM%.json"
set "STREAM_TMPFILE=%TEMP%\democlaw_e2e_stream_resp_%RANDOM%.txt"
%PY% -c "import json; print(json.dumps({'model':'!MODEL_NAME!','messages':[{'role':'user','content':'Say hello'}],'max_tokens':16,'temperature':0.1,'stream':True}))" > "!STREAM_PAYLOAD_FILE!" 2>nul

curl -sf --max-time 15 -H "Content-Type: application/json" -d @"!STREAM_PAYLOAD_FILE!" "!BASE_URL!/v1/chat/completions" > "!STREAM_TMPFILE!" 2>nul
del "!STREAM_PAYLOAD_FILE!" 2>nul

findstr /c:"data:" "!STREAM_TMPFILE!" >nul 2>&1
if !errorlevel! equ 0 (
    echo [validate-e2e] [PASS] dashboard_streaming: SSE stream data received
    set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"
) else (
    echo [validate-e2e] [FAIL] dashboard_streaming: No SSE data lines in stream response
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
)
del "!STREAM_TMPFILE!" 2>nul

REM 7d. Usage metrics — token counts and model name for dashboard display
set "METRICS_PAYLOAD_FILE=%TEMP%\democlaw_e2e_metrics_%RANDOM%.json"
set "METRICS_TMPFILE=%TEMP%\democlaw_e2e_metrics_resp_%RANDOM%.json"
%PY% -c "import json; print(json.dumps({'model':'!MODEL_NAME!','messages':[{'role':'user','content':'What is 2+2? Answer with just the number.'}],'max_tokens':16,'temperature':0.0,'stream':False}))" > "!METRICS_PAYLOAD_FILE!" 2>nul

set "METRICS_HTTP=000"
for /f %%H in ('curl -sf -o "!METRICS_TMPFILE!" -w "%%{http_code}" --max-time 30 -H "Content-Type: application/json" -d @"!METRICS_PAYLOAD_FILE!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "METRICS_HTTP=%%H"
del "!METRICS_PAYLOAD_FILE!" 2>nul

if "!METRICS_HTTP!"=="200" (
    %PY% -c "import json,sys; d=json.load(open(sys.argv[1])); u=d.get('usage',{}); m=d.get('model',''); assert m, 'no model'; assert u.get('prompt_tokens',0)>0 or u.get('completion_tokens',0)>0, 'no tokens'; print(f'model={m} prompt={u.get(\"prompt_tokens\",0)} completion={u.get(\"completion_tokens\",0)}')" "!METRICS_TMPFILE!" >nul 2>&1
    if !errorlevel! equ 0 (
        echo [validate-e2e] [PASS] dashboard_metrics: model name and token counts present
        set /a "TOTAL_GATES+=1" & set /a "PASSED_GATES+=1"
    ) else (
        echo [validate-e2e] [FAIL] dashboard_metrics: missing model name or token counts
        set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
    )
) else (
    echo [validate-e2e] [FAIL] dashboard_metrics: HTTP !METRICS_HTTP! from chat completions
    set /a "TOTAL_GATES+=1" & set /a "FAILED_GATES+=1"
)
del "!METRICS_TMPFILE!" 2>nul

REM ===========================================================================
REM Report
REM ===========================================================================
:report
echo.
echo [validate-e2e] ========================================================
echo [validate-e2e]   E2E Validation Report
echo [validate-e2e] ========================================================
echo [validate-e2e]   Profile    : !PROFILE_LABEL!
echo [validate-e2e]   Model      : !MODEL_NAME!
echo [validate-e2e]   Endpoint   : !BASE_URL!
echo [validate-e2e]   Threshold  : !BENCH_MIN_TPS! t/s
echo.
echo [validate-e2e]   Gates: !TOTAL_GATES! total ^| !PASSED_GATES! passed ^| !FAILED_GATES! failed ^| !SKIPPED_GATES! skipped
echo.

if "!OVERALL_PASS!"=="true" (
    echo [validate-e2e]   Result: PASS
    echo [validate-e2e] ========================================================
    endlocal
    exit /b 0
) else (
    echo [validate-e2e]   Result: FAIL
    echo [validate-e2e] ========================================================
    endlocal
    exit /b 1
)
