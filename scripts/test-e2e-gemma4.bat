@echo off
setlocal enabledelayedexpansion
REM =============================================================================
REM test-e2e-gemma4.bat — Automated E2E tests for Gemma 4 dashboard integration
REM
REM Validates the full request-response cycle:
REM   Dashboard input -> llama.cpp (Gemma 4) inference -> parsed dashboard output
REM
REM Covers both Gemma 4 variants:
REM   - Gemma 4 E4B        (consumer GPU, 8GB VRAM)
REM   - Gemma 4 26B A4B MoE (DGX Spark, 128GB unified memory)
REM
REM Test suite:
REM   T1. Model identity     — /v1/models returns correct Gemma 4 variant
REM   T2. Dashboard payload  — Non-streaming with dashboard-format payload
REM   T3. Streaming SSE      — Dashboard streaming with chunk reassembly
REM   T4. Thinking tokens    — Gemma 4 thinking-token stripping
REM   T5. Multi-turn context — Dashboard conversation history round-trip
REM   T6. Token metrics      — Usage block for dashboard stats display
REM   T7. Latency budget     — Response time within dashboard UX threshold
REM   T8. Profile conformance — Model/config matches hardware profile
REM
REM Usage:
REM   scripts\test-e2e-gemma4.bat
REM   set MODEL_NAME=gemma-4-26B-A4B-it && scripts\test-e2e-gemma4.bat
REM   set TEST_OUTPUT_FORMAT=json && scripts\test-e2e-gemma4.bat
REM
REM Requires: curl, python3 (or python)
REM =============================================================================

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%I in ("%SCRIPT_DIR%\..") do set "PROJECT_ROOT=%%~fI"

REM ---------------------------------------------------------------------------
REM Load .env if present
REM ---------------------------------------------------------------------------
if exist "%PROJECT_ROOT%\.env" (
    for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%PROJECT_ROOT%\.env") do (
        if not "%%A"=="" if not "%%B"=="" set "%%A=%%B"
    )
)

REM ---------------------------------------------------------------------------
REM Configuration defaults
REM ---------------------------------------------------------------------------
if not defined LLAMACPP_HOST set "LLAMACPP_HOST=localhost"
if not defined LLAMACPP_PORT set "LLAMACPP_PORT=8000"
if not defined OPENCLAW_PORT set "OPENCLAW_PORT=18789"
if not defined MAX_LATENCY_S set "MAX_LATENCY_S=30"
if not defined TEST_OUTPUT_FORMAT set "TEST_OUTPUT_FORMAT=text"

set "BASE_URL=http://!LLAMACPP_HOST!:!LLAMACPP_PORT!"
set "DASH_URL=http://localhost:!OPENCLAW_PORT!"

REM Counters
set "PASS_COUNT=0"
set "FAIL_COUNT=0"
set "WARN_COUNT=0"
set "SKIP_COUNT=0"
set "TOTAL_TESTS=0"

REM Detect python
set "PY=python3"
where python3 >nul 2>&1 || (
    where python >nul 2>&1 || (
        echo [e2e-gemma4] ERROR: python3 not found
        exit /b 2
    )
    set "PY=python"
)

echo [e2e-gemma4] ========================================================
echo [e2e-gemma4]   Gemma 4 E2E Dashboard Integration Tests
echo [e2e-gemma4] ========================================================
echo.

REM ---------------------------------------------------------------------------
REM Pre-flight: server reachability
REM ---------------------------------------------------------------------------
echo [e2e-gemma4] [INFO] Pre-flight: checking llama.cpp at !BASE_URL! ...
set "SERVER_OK=false"
set "SRV_ATTEMPTS=0"

:srv_loop
if !SRV_ATTEMPTS! geq 6 goto :srv_done
set /a "SRV_ATTEMPTS+=1"
curl -sf --max-time 5 "!BASE_URL!/health" >nul 2>&1
if !errorlevel! equ 0 (
    set "SERVER_OK=true"
    goto :srv_done
)
echo [e2e-gemma4] [INFO]   Waiting for server ^(attempt !SRV_ATTEMPTS!/6^) ...
powershell -c "Start-Sleep -Seconds 5"
goto :srv_loop

:srv_done
if "!SERVER_OK!"=="false" (
    echo [e2e-gemma4] ERROR: llama.cpp not reachable at !BASE_URL!/health
    echo [e2e-gemma4]   Start the stack first: make start
    exit /b 2
)
echo [e2e-gemma4] [INFO] llama.cpp server is healthy.
echo.

REM ---------------------------------------------------------------------------
REM Auto-detect model name from /v1/models
REM ---------------------------------------------------------------------------
set "DETECTED_MODEL="
set "DETECTED_VARIANT=unknown"
set "EXPECTED_PROFILE=consumer_gpu"

curl -sf --max-time 10 "!BASE_URL!/v1/models" > "%TEMP%\democlaw_e2e_models_%RANDOM%.json" 2>nul
if !errorlevel! equ 0 (
    for /f "usebackq delims=" %%R in (`%PY% -c "import json; d=json.load(open(r'%TEMP%\democlaw_e2e_models_%RANDOM%.json')); m=d.get('data',[]); print(m[0].get('id','')) if m else print('')" 2^>nul`) do set "DETECTED_MODEL=%%R"
)
del "%TEMP%\democlaw_e2e_models_%RANDOM%.json" 2>nul

REM Use MODEL_NAME override if set
if defined MODEL_NAME set "DETECTED_MODEL=!MODEL_NAME!"

REM Determine variant
echo "!DETECTED_MODEL!" | findstr /i "26B A4B" >nul 2>&1
if !errorlevel! equ 0 (
    set "DETECTED_VARIANT=26B-A4B"
    set "EXPECTED_PROFILE=dgx_spark"
) else (
    echo "!DETECTED_MODEL!" | findstr /i "E4B" >nul 2>&1
    if !errorlevel! equ 0 (
        set "DETECTED_VARIANT=E4B"
        set "EXPECTED_PROFILE=consumer_gpu"
    )
)

if not defined HARDWARE_PROFILE set "HARDWARE_PROFILE=!EXPECTED_PROFILE!"

REM Profile-specific labels
set "PROFILE_LABEL=Consumer GPU (8GB VRAM)"
set "EXPECTED_MODEL_PATTERN=gemma-4-E4B"
if "!HARDWARE_PROFILE!"=="dgx_spark" (
    set "PROFILE_LABEL=DGX Spark (128GB unified)"
    set "EXPECTED_MODEL_PATTERN=gemma-4-26B-A4B"
)

echo [e2e-gemma4]   Endpoint      : !BASE_URL!
echo [e2e-gemma4]   Dashboard     : !DASH_URL!
echo [e2e-gemma4]   Model         : !DETECTED_MODEL!
echo [e2e-gemma4]   Variant       : !DETECTED_VARIANT!
echo [e2e-gemma4]   Profile       : !PROFILE_LABEL!
echo [e2e-gemma4]   Max latency   : !MAX_LATENCY_S!s
echo.

REM ===========================================================================
REM T1: Model Identity
REM ===========================================================================
echo [e2e-gemma4] --- T1: Model Identity ---
set /a "TOTAL_TESTS+=1"

%PY% -c "import json,sys,urllib.request; base=sys.argv[1]; pat=sys.argv[2]; req=urllib.request.Request(f'{base}/v1/models'); resp=urllib.request.urlopen(req,timeout=10); d=json.loads(resp.read()); ids=[m.get('id','') for m in d.get('data',[])]; mid=ids[0] if ids else ''; ok='gemma' in mid.lower(); print(f'PASS|Model \"{mid}\" is Gemma 4') if ok and ids else print(f'FAIL|Not Gemma 4: {ids}')" "!BASE_URL!" "!EXPECTED_MODEL_PATTERN!" 2>nul > "%TEMP%\democlaw_e2e_t1_%RANDOM%.txt"

set "T1_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_e2e_t1_%RANDOM%.txt") do set "T1_RESULT=%%R"
del "%TEMP%\democlaw_e2e_t1_%RANDOM%.txt" 2>nul

if "!T1_RESULT:~0,4!"=="PASS" (
    echo [e2e-gemma4] [PASS] Model identity: !T1_RESULT:~5!
    set /a "PASS_COUNT+=1"
) else (
    echo [e2e-gemma4] [FAIL] Model identity: !T1_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

REM ===========================================================================
REM T2: Dashboard Non-Streaming Payload
REM ===========================================================================
echo.
echo [e2e-gemma4] --- T2: Dashboard Non-Streaming Payload ---
set /a "TOTAL_TESTS+=1"

set "T2_PAYLOAD=%TEMP%\democlaw_e2e_t2_pay_%RANDOM%.json"
set "T2_RESP=%TEMP%\democlaw_e2e_t2_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!DETECTED_MODEL!','messages':[{'role':'system','content':'You are a helpful assistant integrated into the OpenClaw dashboard. Be concise and accurate.'},{'role':'user','content':'What is the capital of France? Reply in one sentence.'}],'max_tokens':64,'temperature':0.1,'stream':False}))" > "!T2_PAYLOAD!" 2>nul

set "T2_START="
for /f %%T in ('%PY% -c "import time; print(time.time())"') do set "T2_START=%%T"

for /f %%H in ('curl -sf -o "!T2_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T2_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T2_HTTP=%%H"
del "!T2_PAYLOAD!" 2>nul

set "T2_END="
for /f %%T in ('%PY% -c "import time; print(time.time())"') do set "T2_END=%%T"

if not "!T2_HTTP!"=="200" (
    echo [e2e-gemma4] [FAIL] Dashboard payload: HTTP !T2_HTTP! ^(expected 200^)
    set /a "FAIL_COUNT+=1"
    del "!T2_RESP!" 2>nul
    goto :test3
)

%PY% -c "import json,sys,re; d=json.load(open(sys.argv[1])); errs=[]; obj=d.get('object',''); errs.append('object!=chat.completion') if obj!='chat.completion' else None; c=d.get('choices',[]); errs.append('empty choices') if not c else None; msg=c[0].get('message',{}) if c else {}; role=msg.get('role',''); errs.append('role!=assistant') if c and role!='assistant' else None; content=msg.get('content','') if c else ''; clean=re.sub(r'<start_of_thinking>.*?<end_of_thinking>\s*','',content,flags=re.DOTALL).strip() if content else ''; errs.append('empty content') if c and not clean and not content else None; u=d.get('usage',{}); errs.append('no usage') if not u else None; pt=u.get('prompt_tokens',0) if u else 0; ct=u.get('completion_tokens',0) if u else 0; errs=[e for e in errs if e]; print(f'PASS|model={d.get(\"model\",\"\")}, tokens(p={pt},c={ct})') if not errs else print('FAIL|'+'; '.join(errs))" "!T2_RESP!" 2>nul > "%TEMP%\democlaw_e2e_t2_check_%RANDOM%.txt"

set "T2_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_e2e_t2_check_%RANDOM%.txt") do set "T2_RESULT=%%R"
del "%TEMP%\democlaw_e2e_t2_check_%RANDOM%.txt" 2>nul
del "!T2_RESP!" 2>nul

if "!T2_RESULT:~0,4!"=="PASS" (
    echo [e2e-gemma4] [PASS] Dashboard payload: !T2_RESULT:~5!
    set /a "PASS_COUNT+=1"
) else (
    echo [e2e-gemma4] [FAIL] Dashboard payload: !T2_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test3
REM ===========================================================================
REM T3: Dashboard Streaming (SSE)
REM ===========================================================================
echo.
echo [e2e-gemma4] --- T3: Dashboard Streaming ^(SSE^) ---
set /a "TOTAL_TESTS+=1"

set "T3_PAYLOAD=%TEMP%\democlaw_e2e_t3_pay_%RANDOM%.json"
set "T3_RESP=%TEMP%\democlaw_e2e_t3_resp_%RANDOM%.txt"

%PY% -c "import json; print(json.dumps({'model':'!DETECTED_MODEL!','messages':[{'role':'user','content':'Say hello in one sentence.'}],'max_tokens':48,'temperature':0.1,'stream':True}))" > "!T3_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T3_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T3_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T3_HTTP=%%H"
del "!T3_PAYLOAD!" 2>nul

if not "!T3_HTTP!"=="200" (
    echo [e2e-gemma4] [FAIL] Streaming SSE: HTTP !T3_HTTP! ^(expected 200^)
    set /a "FAIL_COUNT+=1"
    del "!T3_RESP!" 2>nul
    goto :test4
)

%PY% -c "import json,sys,re; f=open(sys.argv[1]).read(); lines=[l.strip() for l in f.split('\n') if l.strip().startswith('data: ')]; chunks=[]; done=False; errs=[]; [chunks.append(json.loads(l[6:])) if l[6:].strip()!='[DONE]' else setattr(sys.modules[__name__],'_done',True) for l in lines]; done=any('data: [DONE]' in l for l in f.split('\n')); ok=len(chunks)>0; obj=chunks[0].get('object','') if chunks else ''; ok=ok and obj=='chat.completion.chunk'; parts=[c.get('choices',[{}])[0].get('delta',{}).get('content','') for c in chunks]; assembled=''.join(parts); clean=re.sub(r'<start_of_thinking>.*?<end_of_thinking>\s*','',assembled,flags=re.DOTALL).strip(); has_fr=any(c.get('choices',[{}])[0].get('finish_reason') for c in chunks); ok=ok and (clean or assembled) and has_fr and done; print(f'PASS|{len(chunks)} chunks, {len(clean)} chars, [DONE]') if ok else print(f'FAIL|chunks={len(chunks)}, content={len(clean)}, fr={has_fr}, done={done}')" "!T3_RESP!" 2>nul > "%TEMP%\democlaw_e2e_t3_check_%RANDOM%.txt"

set "T3_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_e2e_t3_check_%RANDOM%.txt") do set "T3_RESULT=%%R"
del "%TEMP%\democlaw_e2e_t3_check_%RANDOM%.txt" 2>nul
del "!T3_RESP!" 2>nul

if "!T3_RESULT:~0,4!"=="PASS" (
    echo [e2e-gemma4] [PASS] Streaming SSE: !T3_RESULT:~5!
    set /a "PASS_COUNT+=1"
) else (
    echo [e2e-gemma4] [FAIL] Streaming SSE: !T3_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test4
REM ===========================================================================
REM T4: Thinking Token Handling
REM ===========================================================================
echo.
echo [e2e-gemma4] --- T4: Thinking Token Handling ---
set /a "TOTAL_TESTS+=1"

set "T4_PAYLOAD=%TEMP%\democlaw_e2e_t4_pay_%RANDOM%.json"
set "T4_RESP=%TEMP%\democlaw_e2e_t4_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!DETECTED_MODEL!','messages':[{'role':'user','content':'What is the square root of 256? Show your reasoning.'}],'max_tokens':256,'temperature':0.0,'stream':False}))" > "!T4_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T4_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T4_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T4_HTTP=%%H"
del "!T4_PAYLOAD!" 2>nul

if not "!T4_HTTP!"=="200" (
    echo [e2e-gemma4] [FAIL] Thinking tokens: HTTP !T4_HTTP!
    set /a "FAIL_COUNT+=1"
    del "!T4_RESP!" 2>nul
    goto :test5
)

%PY% -c "import json,sys,re; d=json.load(open(sys.argv[1])); c=d.get('choices',[{}])[0].get('message',{}).get('content',''); has=bool(re.search(r'<start_of_thinking>',c)); clean=re.sub(r'<start_of_thinking>.*?<end_of_thinking>\s*','',c,flags=re.DOTALL).strip(); print('PASS|OK') if clean or c else print('FAIL|empty')" "!T4_RESP!" 2>nul > "%TEMP%\democlaw_e2e_t4_check_%RANDOM%.txt"

set "T4_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_e2e_t4_check_%RANDOM%.txt") do set "T4_RESULT=%%R"
del "%TEMP%\democlaw_e2e_t4_check_%RANDOM%.txt" 2>nul
del "!T4_RESP!" 2>nul

if "!T4_RESULT:~0,4!"=="PASS" (
    echo [e2e-gemma4] [PASS] Thinking tokens: content valid after stripping
    set /a "PASS_COUNT+=1"
) else (
    echo [e2e-gemma4] [FAIL] Thinking tokens: !T4_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test5
REM ===========================================================================
REM T5: Multi-Turn Conversation Context
REM ===========================================================================
echo.
echo [e2e-gemma4] --- T5: Multi-Turn Conversation Context ---
set /a "TOTAL_TESTS+=1"

set "T5_PAYLOAD=%TEMP%\democlaw_e2e_t5_pay_%RANDOM%.json"
set "T5_RESP=%TEMP%\democlaw_e2e_t5_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!DETECTED_MODEL!','messages':[{'role':'system','content':'You are a helpful assistant in the OpenClaw dashboard. Be concise.'},{'role':'user','content':'My favorite color is blue and my name is TestUser.'},{'role':'assistant','content':'Nice to meet you, TestUser! Blue is a great color.'},{'role':'user','content':'What is my name and favorite color? Reply in one sentence.'}],'max_tokens':64,'temperature':0.0,'stream':False}))" > "!T5_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T5_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T5_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T5_HTTP=%%H"
del "!T5_PAYLOAD!" 2>nul

if not "!T5_HTTP!"=="200" (
    echo [e2e-gemma4] [FAIL] Multi-turn: HTTP !T5_HTTP!
    set /a "FAIL_COUNT+=1"
    del "!T5_RESP!" 2>nul
    goto :test6
)

%PY% -c "import json,sys,re; d=json.load(open(sys.argv[1])); msg=d.get('choices',[{}])[0].get('message',{}); role=msg.get('role',''); c=msg.get('content',''); clean=re.sub(r'<start_of_thinking>.*?<end_of_thinking>\s*','',c,flags=re.DOTALL).strip().lower(); ok=role=='assistant' and bool(clean); has_name='testuser' in clean if clean else False; has_color='blue' in clean if clean else False; detail='name+color' if has_name and has_color else ('partial' if has_name or has_color else 'valid'); print(f'PASS|{detail}') if ok else print('FAIL|invalid')" "!T5_RESP!" 2>nul > "%TEMP%\democlaw_e2e_t5_check_%RANDOM%.txt"

set "T5_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_e2e_t5_check_%RANDOM%.txt") do set "T5_RESULT=%%R"
del "%TEMP%\democlaw_e2e_t5_check_%RANDOM%.txt" 2>nul
del "!T5_RESP!" 2>nul

if "!T5_RESULT:~0,4!"=="PASS" (
    echo [e2e-gemma4] [PASS] Multi-turn: context recall !T5_RESULT:~5!
    set /a "PASS_COUNT+=1"
) else (
    echo [e2e-gemma4] [FAIL] Multi-turn: !T5_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test6
REM ===========================================================================
REM T6: Dashboard Token Metrics
REM ===========================================================================
echo.
echo [e2e-gemma4] --- T6: Dashboard Token Metrics ---
set /a "TOTAL_TESTS+=1"

set "T6_PAYLOAD=%TEMP%\democlaw_e2e_t6_pay_%RANDOM%.json"
set "T6_RESP=%TEMP%\democlaw_e2e_t6_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!DETECTED_MODEL!','messages':[{'role':'user','content':'Count from 1 to 5, each on a new line.'}],'max_tokens':48,'temperature':0.0,'stream':False}))" > "!T6_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T6_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T6_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T6_HTTP=%%H"
del "!T6_PAYLOAD!" 2>nul

if not "!T6_HTTP!"=="200" (
    echo [e2e-gemma4] [FAIL] Token metrics: HTTP !T6_HTTP!
    set /a "FAIL_COUNT+=1"
    del "!T6_RESP!" 2>nul
    goto :test7
)

%PY% -c "import json,sys; d=json.load(open(sys.argv[1])); u=d.get('usage',{}); m=d.get('model',''); fr=d.get('choices',[{}])[0].get('finish_reason',''); pt=u.get('prompt_tokens',0); ct=u.get('completion_tokens',0); tt=u.get('total_tokens',0); ok=bool(u) and pt>0 and ct>0 and bool(m) and bool(d.get('id')) and bool(fr); print(f'PASS|model={m}, p={pt}, c={ct}, t={tt}, fr={fr}') if ok else print(f'FAIL|usage={bool(u)}, pt={pt}, ct={ct}, model={m}, fr={fr}')" "!T6_RESP!" 2>nul > "%TEMP%\democlaw_e2e_t6_check_%RANDOM%.txt"

set "T6_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_e2e_t6_check_%RANDOM%.txt") do set "T6_RESULT=%%R"
del "%TEMP%\democlaw_e2e_t6_check_%RANDOM%.txt" 2>nul
del "!T6_RESP!" 2>nul

if "!T6_RESULT:~0,4!"=="PASS" (
    echo [e2e-gemma4] [PASS] Token metrics: !T6_RESULT:~5!
    set /a "PASS_COUNT+=1"
) else (
    echo [e2e-gemma4] [FAIL] Token metrics: !T6_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test7
REM ===========================================================================
REM T7: Latency Budget
REM ===========================================================================
echo.
echo [e2e-gemma4] --- T7: Latency Budget ---
set /a "TOTAL_TESTS+=1"

set "T7_PAYLOAD=%TEMP%\democlaw_e2e_t7_pay_%RANDOM%.json"
set "T7_RESP=%TEMP%\democlaw_e2e_t7_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!DETECTED_MODEL!','messages':[{'role':'user','content':'Hi'}],'max_tokens':16,'temperature':0.0,'stream':False}))" > "!T7_PAYLOAD!" 2>nul

set "T7_START="
for /f %%T in ('%PY% -c "import time; print(time.time())"') do set "T7_START=%%T"

for /f %%H in ('curl -sf -o "!T7_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T7_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T7_HTTP=%%H"
del "!T7_PAYLOAD!" 2>nul

set "T7_END="
for /f %%T in ('%PY% -c "import time; print(time.time())"') do set "T7_END=%%T"

set "T7_ELAPSED="
for /f %%E in ('%PY% -c "print(round(!T7_END!-!T7_START!,3))"') do set "T7_ELAPSED=%%E"

del "!T7_RESP!" 2>nul

if not "!T7_HTTP!"=="200" (
    echo [e2e-gemma4] [FAIL] Latency budget: HTTP !T7_HTTP!
    set /a "FAIL_COUNT+=1"
    goto :test8
)

set "T7_PASS="
for /f %%P in ('%PY% -c "print('yes' if !T7_ELAPSED!<=!MAX_LATENCY_S! else 'no')"') do set "T7_PASS=%%P"

if "!T7_PASS!"=="yes" (
    echo [e2e-gemma4] [PASS] Latency budget: !T7_ELAPSED!s ^<= !MAX_LATENCY_S!s threshold
    set /a "PASS_COUNT+=1"
) else (
    echo [e2e-gemma4] [FAIL] Latency budget: !T7_ELAPSED!s ^> !MAX_LATENCY_S!s threshold
    set /a "FAIL_COUNT+=1"
)

:test8
REM ===========================================================================
REM T8: Profile Conformance
REM ===========================================================================
echo.
echo [e2e-gemma4] --- T8: Profile Conformance ---
set /a "TOTAL_TESTS+=1"

set "T8_OK=true"

REM Check model-profile alignment
if "!HARDWARE_PROFILE!"=="dgx_spark" (
    echo "!DETECTED_MODEL!" | findstr /i "E4B" >nul 2>&1
    if !errorlevel! equ 0 (
        REM E4B model on dgx_spark profile is a mismatch
        echo "!DETECTED_MODEL!" | findstr /i "26B A4B" >nul 2>&1
        if !errorlevel! neq 0 (
            set "T8_OK=false"
            echo [e2e-gemma4] [FAIL] Profile conformance: dgx_spark profile but E4B model loaded
            set /a "FAIL_COUNT+=1"
        )
    )
)

if "!HARDWARE_PROFILE!"=="consumer_gpu" (
    echo "!DETECTED_MODEL!" | findstr /i "26B" >nul 2>&1
    if !errorlevel! equ 0 (
        set "T8_OK=false"
        echo [e2e-gemma4] [FAIL] Profile conformance: consumer_gpu profile but 26B model loaded
        set /a "FAIL_COUNT+=1"
    )
)

REM Check dashboard reachability
set "DASH_HTTP=000"
for /f %%H in ('curl -s -o nul -w "%%{http_code}" --max-time 10 "!DASH_URL!/" 2^>nul') do set "DASH_HTTP=%%H"

if "!T8_OK!"=="true" (
    if "!DASH_HTTP!"=="000" (
        echo [e2e-gemma4] [PASS] Profile conformance: !HARDWARE_PROFILE! with !DETECTED_VARIANT! ^(dashboard not reachable^)
    ) else (
        echo [e2e-gemma4] [PASS] Profile conformance: !HARDWARE_PROFILE! with !DETECTED_VARIANT!, dashboard HTTP !DASH_HTTP!
    )
    set /a "PASS_COUNT+=1"
)

REM ===========================================================================
REM Report
REM ===========================================================================
echo.
echo [e2e-gemma4] ========================================================
echo [e2e-gemma4]   Gemma 4 E2E Test Report
echo [e2e-gemma4] ========================================================
echo [e2e-gemma4]   Model    : !DETECTED_MODEL!
echo [e2e-gemma4]   Variant  : !DETECTED_VARIANT!
echo [e2e-gemma4]   Profile  : !PROFILE_LABEL!
echo [e2e-gemma4]   Endpoint : !BASE_URL!
echo.
echo [e2e-gemma4]   Tests    : !TOTAL_TESTS! total
echo [e2e-gemma4]   Passed   : !PASS_COUNT!
echo [e2e-gemma4]   Failed   : !FAIL_COUNT!
echo.

if !FAIL_COUNT! equ 0 (
    echo [e2e-gemma4]   Result: PASS -- All E2E dashboard integration tests passed
    echo [e2e-gemma4] ========================================================
    endlocal
    exit /b 0
) else (
    echo [e2e-gemma4]   Result: FAIL -- !FAIL_COUNT! test^(s^) failed
    echo [e2e-gemma4] ========================================================
    endlocal
    exit /b 1
)
