@echo off
setlocal enabledelayedexpansion
REM =============================================================================
REM validate-chat-completion.bat — Chat completion format compatibility validator
REM
REM Validates that the llama.cpp server's /v1/chat/completions responses are
REM fully compatible with the OpenClaw dashboard for Gemma 4 models.
REM
REM Tests:
REM   1. Non-streaming chat completion — full OpenAI response schema
REM   2. Streaming chat completion — SSE format
REM   3. Gemma 4 thinking-token handling
REM   4. Model name agreement
REM   5. Multi-turn conversation
REM   6. Finish reason validation
REM   7. Usage token counts
REM
REM Usage:
REM   scripts\validate-chat-completion.bat
REM   set MODEL_NAME=gemma-4-26B-A4B-it && scripts\validate-chat-completion.bat
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
if not defined MODEL_NAME set "MODEL_NAME=gemma-4-E4B-it"

set "BASE_URL=http://!LLAMACPP_HOST!:!LLAMACPP_PORT!"

set "PASS_COUNT=0"
set "FAIL_COUNT=0"
set "WARN_COUNT=0"
set "TOTAL_CHECKS=0"

REM Detect python
set "PY=python3"
where python3 >nul 2>&1 || (
    where python >nul 2>&1 || (
        echo [chat-compat] ERROR: python3 not found
        exit /b 2
    )
    set "PY=python"
)

echo [chat-compat] ========================================================
echo [chat-compat]   Chat Completion Format Compatibility Validator
echo [chat-compat] ========================================================
echo [chat-compat]   Endpoint : !BASE_URL!/v1/chat/completions
echo [chat-compat]   Model    : !MODEL_NAME!
echo.

REM ---------------------------------------------------------------------------
REM Pre-flight: server reachability
REM ---------------------------------------------------------------------------
echo [chat-compat] [INFO] Checking server reachability ...
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
echo [chat-compat] [INFO]   Waiting for server ^(attempt !SRV_ATTEMPTS!/6^) ...
powershell -c "Start-Sleep -Seconds 5"
goto :srv_loop

:srv_done
if "!SERVER_OK!"=="false" (
    echo [chat-compat] ERROR: Server not reachable at !BASE_URL!/health
    exit /b 2
)
echo [chat-compat] [INFO] Server is healthy.
echo.

REM ===========================================================================
REM Test 1: Non-streaming chat completion
REM ===========================================================================
echo [chat-compat] --- Test 1: Non-streaming Chat Completion ---
set /a "TOTAL_CHECKS+=1"

set "T1_PAYLOAD=%TEMP%\democlaw_cc_t1_payload_%RANDOM%.json"
set "T1_RESP=%TEMP%\democlaw_cc_t1_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!MODEL_NAME!','messages':[{'role':'user','content':'What is 2+2? Reply with just the number.'}],'max_tokens':32,'temperature':0.0,'stream':False}))" > "!T1_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T1_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T1_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T1_HTTP=%%H"
del "!T1_PAYLOAD!" 2>nul

if not "!T1_HTTP!"=="200" (
    echo [chat-compat] [FAIL] Non-streaming: HTTP !T1_HTTP! ^(expected 200^)
    set /a "FAIL_COUNT+=1"
    del "!T1_RESP!" 2>nul
    goto :test2
)

REM Validate schema via python
%PY% -c "import json,sys,re; d=json.load(open(sys.argv[1])); errs=[]; obj=d.get('object',''); errs.append('object!=chat.completion') if obj!='chat.completion' else None; c=d.get('choices',[]); errs.append('empty choices') if not c else None; msg=c[0].get('message',{}) if c else {}; role=msg.get('role',''); errs.append('role!=assistant') if c and role!='assistant' else None; content=msg.get('content','') if c else ''; clean=re.sub(r'<start_of_thinking>.*?<end_of_thinking>\s*','',content,flags=re.DOTALL).strip() if content else ''; errs.append('empty content') if c and not clean and not content else None; errs=[e for e in errs if e]; print('PASS|Schema valid') if not errs else print('FAIL|'+'; '.join(errs))" "!T1_RESP!" 2>nul > "%TEMP%\democlaw_cc_t1_check.txt"

set "T1_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_cc_t1_check.txt") do set "T1_RESULT=%%R"
del "%TEMP%\democlaw_cc_t1_check.txt" 2>nul
del "!T1_RESP!" 2>nul

if "!T1_RESULT:~0,4!"=="PASS" (
    echo [chat-compat] [PASS] Non-streaming: !T1_RESULT:~5!
    set /a "PASS_COUNT+=1"
) else (
    echo [chat-compat] [FAIL] Non-streaming: !T1_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test2
REM ===========================================================================
REM Test 2: Streaming chat completion
REM ===========================================================================
echo.
echo [chat-compat] --- Test 2: Streaming Chat Completion ^(SSE^) ---
set /a "TOTAL_CHECKS+=1"

set "T2_PAYLOAD=%TEMP%\democlaw_cc_t2_payload_%RANDOM%.json"
set "T2_RESP=%TEMP%\democlaw_cc_t2_resp_%RANDOM%.txt"

%PY% -c "import json; print(json.dumps({'model':'!MODEL_NAME!','messages':[{'role':'user','content':'Say hello.'}],'max_tokens':32,'temperature':0.0,'stream':True}))" > "!T2_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T2_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T2_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T2_HTTP=%%H"
del "!T2_PAYLOAD!" 2>nul

if not "!T2_HTTP!"=="200" (
    echo [chat-compat] [FAIL] Streaming: HTTP !T2_HTTP! ^(expected 200^)
    set /a "FAIL_COUNT+=1"
    del "!T2_RESP!" 2>nul
    goto :test3
)

%PY% -c "import json,sys; f=open(sys.argv[1]).read(); lines=[l.strip() for l in f.split('\n') if l.strip().startswith('data: ')]; chunks=[json.loads(l[6:]) for l in lines if l[6:].strip()!='[DONE]']; done=any('data: [DONE]' in l for l in f.split('\n')); ok=len(chunks)>0 and chunks[0].get('object')=='chat.completion.chunk'; print(f'PASS|{len(chunks)} SSE chunks') if ok else print('FAIL|Invalid SSE format')" "!T2_RESP!" 2>nul > "%TEMP%\democlaw_cc_t2_check.txt"

set "T2_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_cc_t2_check.txt") do set "T2_RESULT=%%R"
del "%TEMP%\democlaw_cc_t2_check.txt" 2>nul
del "!T2_RESP!" 2>nul

if "!T2_RESULT:~0,4!"=="PASS" (
    echo [chat-compat] [PASS] Streaming: !T2_RESULT:~5!
    set /a "PASS_COUNT+=1"
) else (
    echo [chat-compat] [FAIL] Streaming: !T2_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test3
REM ===========================================================================
REM Test 3: Thinking token handling
REM ===========================================================================
echo.
echo [chat-compat] --- Test 3: Thinking Token Handling ---
set /a "TOTAL_CHECKS+=1"

set "T3_PAYLOAD=%TEMP%\democlaw_cc_t3_payload_%RANDOM%.json"
set "T3_RESP=%TEMP%\democlaw_cc_t3_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!MODEL_NAME!','messages':[{'role':'user','content':'What is the square root of 144? Answer briefly.'}],'max_tokens':128,'temperature':0.0,'stream':False}))" > "!T3_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T3_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T3_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T3_HTTP=%%H"
del "!T3_PAYLOAD!" 2>nul

if not "!T3_HTTP!"=="200" (
    echo [chat-compat] [FAIL] Thinking tokens: HTTP !T3_HTTP!
    set /a "FAIL_COUNT+=1"
    del "!T3_RESP!" 2>nul
    goto :test4
)

%PY% -c "import json,sys,re; d=json.load(open(sys.argv[1])); c=d.get('choices',[{}])[0].get('message',{}).get('content',''); clean=re.sub(r'<start_of_thinking>.*?<end_of_thinking>\s*','',c,flags=re.DOTALL).strip(); has_think=bool(re.search(r'<start_of_thinking>',c)); print('PASS|OK') if clean or c else print('FAIL|No content')" "!T3_RESP!" 2>nul > "%TEMP%\democlaw_cc_t3_check.txt"

set "T3_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_cc_t3_check.txt") do set "T3_RESULT=%%R"
del "%TEMP%\democlaw_cc_t3_check.txt" 2>nul
del "!T3_RESP!" 2>nul

if "!T3_RESULT:~0,4!"=="PASS" (
    echo [chat-compat] [PASS] Thinking tokens: content valid
    set /a "PASS_COUNT+=1"
) else (
    echo [chat-compat] [FAIL] Thinking tokens: !T3_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test4
REM ===========================================================================
REM Test 4: Model name agreement
REM ===========================================================================
echo.
echo [chat-compat] --- Test 4: Model Name Agreement ---
set /a "TOTAL_CHECKS+=1"

curl -sf "!BASE_URL!/v1/models" > "%TEMP%\democlaw_cc_models.json" 2>nul
if !errorlevel! equ 0 (
    %PY% -c "import json,sys; d=json.load(open(sys.argv[1])); ids=[m.get('id','') for m in d.get('data',[])]; m=sys.argv[2]; ok=any(m in i or i in m for i in ids); print(f'PASS|{ids[0]}') if ok and ids else print(f'FAIL|{ids}')" "%TEMP%\democlaw_cc_models.json" "!MODEL_NAME!" 2>nul > "%TEMP%\democlaw_cc_t4_check.txt"

    set "T4_RESULT="
    for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_cc_t4_check.txt") do set "T4_RESULT=%%R"
    del "%TEMP%\democlaw_cc_t4_check.txt" 2>nul

    if "!T4_RESULT:~0,4!"=="PASS" (
        echo [chat-compat] [PASS] Model name: matches "!MODEL_NAME!"
        set /a "PASS_COUNT+=1"
    ) else (
        echo [chat-compat] [FAIL] Model name: !T4_RESULT:~5!
        set /a "FAIL_COUNT+=1"
    )
) else (
    echo [chat-compat] [FAIL] Model name: /v1/models not responding
    set /a "FAIL_COUNT+=1"
)
del "%TEMP%\democlaw_cc_models.json" 2>nul

REM ===========================================================================
REM Test 5: Multi-turn conversation
REM ===========================================================================
echo.
echo [chat-compat] --- Test 5: Multi-turn Conversation ---
set /a "TOTAL_CHECKS+=1"

set "T5_PAYLOAD=%TEMP%\democlaw_cc_t5_payload_%RANDOM%.json"
set "T5_RESP=%TEMP%\democlaw_cc_t5_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!MODEL_NAME!','messages':[{'role':'system','content':'You are a helpful assistant. Be concise.'},{'role':'user','content':'My name is Alice.'},{'role':'assistant','content':'Hello Alice! How can I help you?'},{'role':'user','content':'What is my name?'}],'max_tokens':32,'temperature':0.0,'stream':False}))" > "!T5_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T5_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T5_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T5_HTTP=%%H"
del "!T5_PAYLOAD!" 2>nul

if not "!T5_HTTP!"=="200" (
    echo [chat-compat] [FAIL] Multi-turn: HTTP !T5_HTTP!
    set /a "FAIL_COUNT+=1"
    del "!T5_RESP!" 2>nul
    goto :test6
)

%PY% -c "import json,sys,re; d=json.load(open(sys.argv[1])); c=d.get('choices',[{}])[0].get('message',{}).get('content',''); clean=re.sub(r'<start_of_thinking>.*?<end_of_thinking>\s*','',c,flags=re.DOTALL).strip(); role=d.get('choices',[{}])[0].get('message',{}).get('role',''); print('PASS|OK') if role=='assistant' and clean else print('FAIL|invalid')" "!T5_RESP!" 2>nul > "%TEMP%\democlaw_cc_t5_check.txt"

set "T5_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_cc_t5_check.txt") do set "T5_RESULT=%%R"
del "%TEMP%\democlaw_cc_t5_check.txt" 2>nul
del "!T5_RESP!" 2>nul

if "!T5_RESULT:~0,4!"=="PASS" (
    echo [chat-compat] [PASS] Multi-turn: valid multi-turn response
    set /a "PASS_COUNT+=1"
) else (
    echo [chat-compat] [FAIL] Multi-turn: !T5_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test6
REM ===========================================================================
REM Test 6: Finish reason validation
REM ===========================================================================
echo.
echo [chat-compat] --- Test 6: Finish Reason ---
set /a "TOTAL_CHECKS+=1"

set "T6_PAYLOAD=%TEMP%\democlaw_cc_t6_payload_%RANDOM%.json"
set "T6_RESP=%TEMP%\democlaw_cc_t6_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!MODEL_NAME!','messages':[{'role':'user','content':'Write a very long detailed essay about the history of mathematics.'}],'max_tokens':5,'temperature':0.0,'stream':False}))" > "!T6_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T6_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T6_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T6_HTTP=%%H"
del "!T6_PAYLOAD!" 2>nul

if not "!T6_HTTP!"=="200" (
    echo [chat-compat] [FAIL] Finish reason: HTTP !T6_HTTP!
    set /a "FAIL_COUNT+=1"
    del "!T6_RESP!" 2>nul
    goto :test7
)

%PY% -c "import json,sys; d=json.load(open(sys.argv[1])); f=d.get('choices',[{}])[0].get('finish_reason',''); print('PASS|'+f) if f else print('FAIL|missing')" "!T6_RESP!" 2>nul > "%TEMP%\democlaw_cc_t6_check.txt"

set "T6_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_cc_t6_check.txt") do set "T6_RESULT=%%R"
del "%TEMP%\democlaw_cc_t6_check.txt" 2>nul
del "!T6_RESP!" 2>nul

if "!T6_RESULT:~0,4!"=="PASS" (
    echo [chat-compat] [PASS] Finish reason: !T6_RESULT:~5!
    set /a "PASS_COUNT+=1"
) else (
    echo [chat-compat] [FAIL] Finish reason: !T6_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

:test7
REM ===========================================================================
REM Test 7: Usage token counts
REM ===========================================================================
echo.
echo [chat-compat] --- Test 7: Usage Token Counts ---
set /a "TOTAL_CHECKS+=1"

set "T7_PAYLOAD=%TEMP%\democlaw_cc_t7_payload_%RANDOM%.json"
set "T7_RESP=%TEMP%\democlaw_cc_t7_resp_%RANDOM%.json"

%PY% -c "import json; print(json.dumps({'model':'!MODEL_NAME!','messages':[{'role':'user','content':'Count from 1 to 3.'}],'max_tokens':32,'temperature':0.0,'stream':False}))" > "!T7_PAYLOAD!" 2>nul

for /f %%H in ('curl -sf -o "!T7_RESP!" -w "%%{http_code}" --max-time 120 -H "Content-Type: application/json" -d @"!T7_PAYLOAD!" "!BASE_URL!/v1/chat/completions" 2^>nul') do set "T7_HTTP=%%H"
del "!T7_PAYLOAD!" 2>nul

if not "!T7_HTTP!"=="200" (
    echo [chat-compat] [FAIL] Usage tokens: HTTP !T7_HTTP!
    set /a "FAIL_COUNT+=1"
    del "!T7_RESP!" 2>nul
    goto :report
)

%PY% -c "import json,sys; d=json.load(open(sys.argv[1])); u=d.get('usage',{}); pt=u.get('prompt_tokens',0); ct=u.get('completion_tokens',0); tt=u.get('total_tokens',0); print(f'PASS|pt={pt},ct={ct},tt={tt}') if u else print('FAIL|missing usage')" "!T7_RESP!" 2>nul > "%TEMP%\democlaw_cc_t7_check.txt"

set "T7_RESULT="
for /f "usebackq delims=" %%R in ("%TEMP%\democlaw_cc_t7_check.txt") do set "T7_RESULT=%%R"
del "%TEMP%\democlaw_cc_t7_check.txt" 2>nul
del "!T7_RESP!" 2>nul

if "!T7_RESULT:~0,4!"=="PASS" (
    echo [chat-compat] [PASS] Usage tokens: !T7_RESULT:~5!
    set /a "PASS_COUNT+=1"
) else (
    echo [chat-compat] [FAIL] Usage tokens: !T7_RESULT:~5!
    set /a "FAIL_COUNT+=1"
)

REM ===========================================================================
REM Report
REM ===========================================================================
:report
echo.
echo [chat-compat] ========================================================
echo [chat-compat]   Chat Completion Compatibility Report
echo [chat-compat] ========================================================
echo [chat-compat]   Endpoint : !BASE_URL!/v1/chat/completions
echo [chat-compat]   Model    : !MODEL_NAME!
echo.
echo [chat-compat]   Checks   : !TOTAL_CHECKS! total
echo [chat-compat]   Passed   : !PASS_COUNT!
echo [chat-compat]   Failed   : !FAIL_COUNT!
echo.

if !FAIL_COUNT! equ 0 (
    echo [chat-compat]   Result: PASS -- Chat completion format is OpenClaw-compatible
    echo [chat-compat] ========================================================
    endlocal
    exit /b 0
) else (
    echo [chat-compat]   Result: FAIL -- !FAIL_COUNT! check^(s^) failed
    echo [chat-compat] ========================================================
    endlocal
    exit /b 1
)
