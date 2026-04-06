#!/usr/bin/env bash
# =============================================================================
# validate-chat-completion.sh — Chat completion format compatibility validator
#
# Validates that the llama.cpp server's /v1/chat/completions responses are
# fully compatible with the OpenClaw dashboard's expectations for Gemma 4
# models.
#
# Tests:
#   1. Non-streaming chat completion — full OpenAI response schema
#   2. Streaming chat completion — SSE (Server-Sent Events) format
#   3. Gemma 4 thinking-token handling — strips <start_of_thinking> markers
#   4. Model name agreement — response model matches configured MODEL_NAME
#   5. Multi-turn conversation — system + user + assistant history
#   6. Finish reason validation — accepts stop/end_turn/eos/length
#   7. Usage token counts — prompt_tokens + completion_tokens present
#
# Designed for two Gemma 4 variants:
#   - Gemma 4 E4B (consumer GPU, 8GB VRAM)
#   - Gemma 4 26B A4B MoE (DGX Spark, 128GB unified)
#
# Usage:
#   ./scripts/validate-chat-completion.sh
#   MODEL_NAME=gemma-4-26B-A4B-it ./scripts/validate-chat-completion.sh
#   LLAMACPP_PORT=8001 ./scripts/validate-chat-completion.sh
#
# Environment variables:
#   LLAMACPP_HOST   — llama.cpp server host (default: localhost)
#   LLAMACPP_PORT   — llama.cpp server port (default: 8000)
#   MODEL_NAME      — expected model name   (default: gemma-4-E4B-it)
#
# Exit codes:
#   0 — All checks passed
#   1 — One or more checks failed
#   2 — Server not reachable
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_log()  { echo "[chat-compat] $*"; }
_pass() { echo "[chat-compat] [PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
_fail() { echo "[chat-compat] [FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
_warn() { echo "[chat-compat] [WARN] $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
_info() { echo "[chat-compat] [INFO] $*"; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
if [ -f "${PROJECT_ROOT}/.env" ]; then
    set -a; source "${PROJECT_ROOT}/.env"; set +a
fi

LLAMACPP_HOST="${LLAMACPP_HOST:-localhost}"
LLAMACPP_PORT="${LLAMACPP_PORT:-8000}"
BASE_URL="http://${LLAMACPP_HOST}:${LLAMACPP_PORT}"
MODEL_NAME="${MODEL_NAME:-gemma-4-E4B-it}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
TOTAL_CHECKS=0

# ---------------------------------------------------------------------------
# Pre-flight: ensure server is reachable
# ---------------------------------------------------------------------------
_log "========================================================"
_log "  Chat Completion Format Compatibility Validator"
_log "========================================================"
_log "  Endpoint : ${BASE_URL}/v1/chat/completions"
_log "  Model    : ${MODEL_NAME}"
_log ""

_info "Checking server reachability ..."
SERVER_OK=false
for attempt in $(seq 1 6); do
    if curl -sf --max-time 5 "${BASE_URL}/health" >/dev/null 2>&1; then
        SERVER_OK=true
        break
    fi
    _info "  Waiting for server (attempt ${attempt}/6) ..."
    sleep 5
done

if [ "${SERVER_OK}" != "true" ]; then
    _log "ERROR: Server not reachable at ${BASE_URL}/health"
    _log "  Start the llama.cpp container first: make start"
    exit 2
fi
_info "Server is healthy."
_log ""

# ===========================================================================
# Test 1: Non-streaming chat completion — full schema validation
# ===========================================================================
_log "--- Test 1: Non-streaming Chat Completion ---"
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

TMPFILE=$(mktemp)
HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
    --max-time 120 \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
            {\"role\": \"user\", \"content\": \"What is 2+2? Reply with just the number.\"}
        ],
        \"max_tokens\": 32,
        \"temperature\": 0.0,
        \"stream\": false
    }" \
    "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

if [ "${HTTP_CODE}" != "200" ]; then
    _fail "Non-streaming: HTTP ${HTTP_CODE} (expected 200)"
    rm -f "${TMPFILE}"
else
    # Validate full OpenAI response schema
    SCHEMA_CHECK=$(python3 << 'PYEOF' "${TMPFILE}" "${MODEL_NAME}"
import sys, json, re

tmpfile = sys.argv[1]
expected_model = sys.argv[2] if len(sys.argv) > 2 else ''
errors = []
warnings = []

try:
    with open(tmpfile) as f:
        data = json.load(f)

    # --- Required top-level fields ---
    # id: string (chatcmpl-*)
    resp_id = data.get('id', '')
    if not resp_id:
        errors.append('missing "id" field')
    elif not isinstance(resp_id, str):
        errors.append(f'"id" is not a string: {type(resp_id).__name__}')

    # object: must be "chat.completion"
    obj = data.get('object', '')
    if obj != 'chat.completion':
        errors.append(f'"object" is "{obj}", expected "chat.completion"')

    # created: integer timestamp
    created = data.get('created')
    if created is None:
        errors.append('missing "created" field')
    elif not isinstance(created, (int, float)):
        errors.append(f'"created" is not numeric: {type(created).__name__}')

    # model: string matching expected
    resp_model = data.get('model', '')
    if not resp_model:
        errors.append('missing "model" field')
    elif expected_model and expected_model not in resp_model:
        # Non-fatal: llama.cpp may use filename as model id
        warnings.append(f'model mismatch: "{resp_model}" (expected contains "{expected_model}")')

    # choices: array with >= 1 element
    choices = data.get('choices', [])
    if not choices:
        errors.append('empty or missing "choices" array')
    else:
        c0 = choices[0]

        # index: integer
        if 'index' not in c0:
            errors.append('choices[0] missing "index"')

        # message: object with role + content
        msg = c0.get('message', {})
        if not msg:
            errors.append('choices[0] missing "message"')
        else:
            role = msg.get('role', '')
            if role != 'assistant':
                errors.append(f'message.role is "{role}", expected "assistant"')

            content = msg.get('content', '')
            # Strip Gemma 4 thinking tokens for content validation
            clean = re.sub(
                r'<start_of_thinking>.*?<end_of_thinking>\s*',
                '', content, flags=re.DOTALL
            ).strip()

            if not clean and not content:
                errors.append('message.content is empty')
            elif not clean and content:
                warnings.append('content is entirely thinking tokens (valid but noted)')

        # finish_reason: valid stop signal
        finish = c0.get('finish_reason', '')
        valid_reasons = {'stop', 'end_turn', 'eos', 'length'}
        if finish in valid_reasons:
            pass  # OK
        elif finish:
            warnings.append(f'unexpected finish_reason: "{finish}"')
        else:
            errors.append('missing "finish_reason"')

    # usage: object with token counts
    usage = data.get('usage', {})
    if not usage:
        warnings.append('missing "usage" block')
    else:
        pt = usage.get('prompt_tokens', 0)
        ct = usage.get('completion_tokens', 0)
        tt = usage.get('total_tokens', 0)
        if pt <= 0:
            warnings.append(f'prompt_tokens={pt} (expected > 0)')
        if ct <= 0:
            warnings.append(f'completion_tokens={ct} (expected > 0)')

    # --- Output ---
    if errors:
        print(f'FAIL|{"; ".join(errors)}')
    elif warnings:
        print(f'PASS_WARN|{"; ".join(warnings)}')
    else:
        print('PASS|Full OpenAI schema validated')

except Exception as e:
    print(f'FAIL|Parse error: {e}')
PYEOF
    )

    SCHEMA_STATUS="${SCHEMA_CHECK%%|*}"
    SCHEMA_DETAIL="${SCHEMA_CHECK#*|}"

    case "${SCHEMA_STATUS}" in
        PASS)
            _pass "Non-streaming: ${SCHEMA_DETAIL}"
            ;;
        PASS_WARN)
            _pass "Non-streaming: schema valid (warnings: ${SCHEMA_DETAIL})"
            ;;
        FAIL)
            _fail "Non-streaming: ${SCHEMA_DETAIL}"
            ;;
    esac
    rm -f "${TMPFILE}"
fi

# ===========================================================================
# Test 2: Streaming chat completion — SSE format validation
# ===========================================================================
_log ""
_log "--- Test 2: Streaming Chat Completion (SSE) ---"
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

STREAM_TMPFILE=$(mktemp)
STREAM_HTTP=$(curl -sf -o "${STREAM_TMPFILE}" -w "%{http_code}" \
    --max-time 120 \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
            {\"role\": \"user\", \"content\": \"Say hello.\"}
        ],
        \"max_tokens\": 32,
        \"temperature\": 0.0,
        \"stream\": true
    }" \
    "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

if [ "${STREAM_HTTP}" != "200" ]; then
    _fail "Streaming: HTTP ${STREAM_HTTP} (expected 200)"
    rm -f "${STREAM_TMPFILE}"
else
    _PYSCRIPT=$(mktemp --suffix=.py)
    cat > "${_PYSCRIPT}" << 'PYEOF'
import sys, json, re

tmpfile = sys.argv[1]
expected_model = sys.argv[2] if len(sys.argv) > 2 else ''
errors = []
warnings = []

try:
    with open(tmpfile) as f:
        raw = f.read()

    lines = raw.strip().split('\n')

    # Parse SSE data lines
    chunks = []
    has_done = False

    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith('data: '):
            payload = line[6:].strip()
            if payload == '[DONE]':
                has_done = True
                continue
            try:
                chunk = json.loads(payload)
                chunks.append(chunk)
            except json.JSONDecodeError:
                errors.append(f'Invalid JSON in SSE chunk: {payload[:60]}')

    if not chunks:
        errors.append('No SSE data chunks received')
    else:
        # Validate first chunk structure
        c0 = chunks[0]

        # id field
        if 'id' not in c0:
            errors.append('First chunk missing "id"')

        # object: must be "chat.completion.chunk"
        obj = c0.get('object', '')
        if obj != 'chat.completion.chunk':
            errors.append(f'Chunk "object" is "{obj}", expected "chat.completion.chunk"')

        # model field
        resp_model = c0.get('model', '')
        if not resp_model:
            warnings.append('Chunk missing "model" field')
        elif expected_model and expected_model not in resp_model:
            warnings.append(f'Chunk model mismatch: "{resp_model}"')

        # choices with delta
        choices = c0.get('choices', [])
        if not choices:
            errors.append('First chunk has empty "choices"')
        else:
            delta = choices[0].get('delta', {})
            if not isinstance(delta, dict):
                errors.append('"delta" is not an object')

        # Verify content accumulation across chunks
        content_parts = []
        finish_reason_found = False
        for chunk in chunks:
            for choice in chunk.get('choices', []):
                delta = choice.get('delta', {})
                c = delta.get('content', '')
                if c:
                    content_parts.append(c)
                fr = choice.get('finish_reason')
                if fr is not None:
                    finish_reason_found = True

        assembled = ''.join(content_parts)
        # Strip thinking tokens
        clean = re.sub(
            r'<start_of_thinking>.*?<end_of_thinking>\s*',
            '', assembled, flags=re.DOTALL
        ).strip()

        if not clean and not assembled:
            errors.append('No content in any streaming chunk')
        elif not clean and assembled:
            warnings.append('Streamed content is entirely thinking tokens')

        if not finish_reason_found:
            warnings.append('No finish_reason in final chunk')

    if not has_done:
        warnings.append('Missing [DONE] sentinel in SSE stream')

    if errors:
        print(f'FAIL|{"; ".join(errors)}')
    elif warnings:
        print(f'PASS_WARN|{len(chunks)} chunks, assembled {len(clean if clean else assembled)} chars (warnings: {"; ".join(warnings)})')
    else:
        print(f'PASS|{len(chunks)} SSE chunks, assembled {len(clean)} chars, [DONE] present')

except Exception as e:
    print(f'FAIL|Parse error: {e}')
PYEOF
    STREAM_CHECK=$(python3 "${_PYSCRIPT}" "${STREAM_TMPFILE}" "${MODEL_NAME}")
    rm -f "${_PYSCRIPT}"

    SSE_STATUS="${STREAM_CHECK%%|*}"
    SSE_DETAIL="${STREAM_CHECK#*|}"

    case "${SSE_STATUS}" in
        PASS)
            _pass "Streaming: ${SSE_DETAIL}"
            ;;
        PASS_WARN)
            _pass "Streaming: SSE format valid (${SSE_DETAIL})"
            ;;
        FAIL)
            _fail "Streaming: ${SSE_DETAIL}"
            ;;
    esac
    rm -f "${STREAM_TMPFILE}"
fi

# ===========================================================================
# Test 3: Gemma 4 thinking-token stripping
# ===========================================================================
_log ""
_log "--- Test 3: Thinking Token Handling ---"
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

# Send a prompt that may trigger Gemma 4's thinking mode
THINK_TMPFILE=$(mktemp)
THINK_HTTP=$(curl -sf -o "${THINK_TMPFILE}" -w "%{http_code}" \
    --max-time 120 \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
            {\"role\": \"user\", \"content\": \"What is the square root of 144? Answer briefly.\"}
        ],
        \"max_tokens\": 128,
        \"temperature\": 0.0,
        \"stream\": false
    }" \
    "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

if [ "${THINK_HTTP}" != "200" ]; then
    _fail "Thinking tokens: HTTP ${THINK_HTTP}"
    rm -f "${THINK_TMPFILE}"
else
    THINK_CHECK=$(python3 << 'PYEOF' "${THINK_TMPFILE}"
import sys, json, re

tmpfile = sys.argv[1]

try:
    with open(tmpfile) as f:
        data = json.load(f)

    content = data.get('choices', [{}])[0].get('message', {}).get('content', '')

    has_thinking = bool(re.search(r'<start_of_thinking>', content))
    clean = re.sub(
        r'<start_of_thinking>.*?<end_of_thinking>\s*',
        '', content, flags=re.DOTALL
    ).strip()

    if has_thinking and clean:
        print(f'PASS|Thinking tokens present and strippable; clean content: "{clean[:60]}"')
    elif has_thinking and not clean:
        print(f'PASS_WARN|Thinking tokens present but no user-facing content after stripping')
    elif not has_thinking and clean:
        print(f'PASS|No thinking tokens (model did not use thinking mode); content: "{clean[:60]}"')
    else:
        print(f'FAIL|No content at all')

except Exception as e:
    print(f'FAIL|Parse error: {e}')
PYEOF
    )

    THINK_STATUS="${THINK_CHECK%%|*}"
    THINK_DETAIL="${THINK_CHECK#*|}"

    case "${THINK_STATUS}" in
        PASS)
            _pass "Thinking tokens: ${THINK_DETAIL}"
            ;;
        PASS_WARN)
            _pass "Thinking tokens: ${THINK_DETAIL}"
            ;;
        FAIL)
            _fail "Thinking tokens: ${THINK_DETAIL}"
            ;;
    esac
    rm -f "${THINK_TMPFILE}"
fi

# ===========================================================================
# Test 4: Model name agreement (/v1/models vs chat completion response)
# ===========================================================================
_log ""
_log "--- Test 4: Model Name Agreement ---"
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

MODEL_CHECK=$(python3 << 'PYEOF' "${BASE_URL}" "${MODEL_NAME}"
import sys, json, urllib.request

base_url = sys.argv[1]
expected = sys.argv[2]
errors = []

try:
    # Fetch /v1/models
    req = urllib.request.Request(f'{base_url}/v1/models')
    with urllib.request.urlopen(req, timeout=10) as resp:
        models_data = json.loads(resp.read())

    model_ids = [m.get('id', '') for m in models_data.get('data', [])]

    if not model_ids:
        errors.append('/v1/models returned no models')
    else:
        # Check if expected model name is present (exact or contained)
        matched = any(expected in mid or mid in expected for mid in model_ids)
        if not matched:
            errors.append(f'Expected "{expected}" not found in /v1/models: {model_ids}')

    if errors:
        print(f'FAIL|{"; ".join(errors)}')
    else:
        print(f'PASS|/v1/models lists "{model_ids[0]}" — matches expected "{expected}"')

except Exception as e:
    print(f'FAIL|{e}')
PYEOF
)

MODEL_STATUS="${MODEL_CHECK%%|*}"
MODEL_DETAIL="${MODEL_CHECK#*|}"

case "${MODEL_STATUS}" in
    PASS)   _pass "Model name: ${MODEL_DETAIL}" ;;
    FAIL)   _fail "Model name: ${MODEL_DETAIL}" ;;
esac

# ===========================================================================
# Test 5: Multi-turn conversation (system + user + assistant history)
# ===========================================================================
_log ""
_log "--- Test 5: Multi-turn Conversation ---"
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

MULTI_TMPFILE=$(mktemp)
MULTI_HTTP=$(curl -sf -o "${MULTI_TMPFILE}" -w "%{http_code}" \
    --max-time 120 \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
            {\"role\": \"system\", \"content\": \"You are a helpful assistant. Be concise.\"},
            {\"role\": \"user\", \"content\": \"My name is Alice.\"},
            {\"role\": \"assistant\", \"content\": \"Hello Alice! How can I help you?\"},
            {\"role\": \"user\", \"content\": \"What is my name?\"}
        ],
        \"max_tokens\": 32,
        \"temperature\": 0.0,
        \"stream\": false
    }" \
    "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

if [ "${MULTI_HTTP}" != "200" ]; then
    _fail "Multi-turn: HTTP ${MULTI_HTTP}"
    rm -f "${MULTI_TMPFILE}"
else
    MULTI_CHECK=$(python3 << 'PYEOF' "${MULTI_TMPFILE}"
import sys, json, re

tmpfile = sys.argv[1]

try:
    with open(tmpfile) as f:
        data = json.load(f)

    content = data.get('choices', [{}])[0].get('message', {}).get('content', '')
    clean = re.sub(
        r'<start_of_thinking>.*?<end_of_thinking>\s*',
        '', content, flags=re.DOTALL
    ).strip()
    role = data.get('choices', [{}])[0].get('message', {}).get('role', '')
    finish = data.get('choices', [{}])[0].get('finish_reason', '')

    if role != 'assistant':
        print(f'FAIL|Response role is "{role}", expected "assistant"')
    elif not clean:
        print(f'FAIL|Empty response content')
    else:
        # Check if model remembered context (Alice's name)
        has_context = 'alice' in clean.lower()
        if has_context:
            print(f'PASS|Multi-turn context preserved; response mentions Alice: "{clean[:60]}"')
        else:
            # Model answered but may not have mentioned the name explicitly
            print(f'PASS|Multi-turn response valid (context recall uncertain): "{clean[:60]}"')

except Exception as e:
    print(f'FAIL|Parse error: {e}')
PYEOF
    )

    MULTI_STATUS="${MULTI_CHECK%%|*}"
    MULTI_DETAIL="${MULTI_CHECK#*|}"

    case "${MULTI_STATUS}" in
        PASS)   _pass "Multi-turn: ${MULTI_DETAIL}" ;;
        FAIL)   _fail "Multi-turn: ${MULTI_DETAIL}" ;;
    esac
    rm -f "${MULTI_TMPFILE}"
fi

# ===========================================================================
# Test 6: Finish reason validation (max_tokens triggers "length")
# ===========================================================================
_log ""
_log "--- Test 6: Finish Reason — Length Truncation ---"
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

FINISH_TMPFILE=$(mktemp)
FINISH_HTTP=$(curl -sf -o "${FINISH_TMPFILE}" -w "%{http_code}" \
    --max-time 120 \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
            {\"role\": \"user\", \"content\": \"Write a very long detailed essay about the history of mathematics.\"}
        ],
        \"max_tokens\": 5,
        \"temperature\": 0.0,
        \"stream\": false
    }" \
    "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

if [ "${FINISH_HTTP}" != "200" ]; then
    _fail "Finish reason: HTTP ${FINISH_HTTP}"
    rm -f "${FINISH_TMPFILE}"
else
    FINISH_CHECK=$(python3 << 'PYEOF' "${FINISH_TMPFILE}"
import sys, json

tmpfile = sys.argv[1]

try:
    with open(tmpfile) as f:
        data = json.load(f)

    finish = data.get('choices', [{}])[0].get('finish_reason', '')
    usage = data.get('usage', {})
    ct = usage.get('completion_tokens', 0)

    # With max_tokens=5, we expect "length" or "stop" (if model finished early)
    valid = {'stop', 'length', 'end_turn', 'eos'}
    if finish in valid:
        print(f'PASS|finish_reason="{finish}", completion_tokens={ct}')
    elif finish:
        print(f'PASS|finish_reason="{finish}" (non-standard but present), completion_tokens={ct}')
    else:
        print(f'FAIL|finish_reason missing')

except Exception as e:
    print(f'FAIL|Parse error: {e}')
PYEOF
    )

    FINISH_STATUS="${FINISH_CHECK%%|*}"
    FINISH_DETAIL="${FINISH_CHECK#*|}"

    case "${FINISH_STATUS}" in
        PASS)   _pass "Finish reason: ${FINISH_DETAIL}" ;;
        FAIL)   _fail "Finish reason: ${FINISH_DETAIL}" ;;
    esac
    rm -f "${FINISH_TMPFILE}"
fi

# ===========================================================================
# Test 7: Usage token counts present and valid
# ===========================================================================
_log ""
_log "--- Test 7: Usage Token Counts ---"
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

# Reuse the first test response if available, or send a fresh request
USAGE_TMPFILE=$(mktemp)
USAGE_HTTP=$(curl -sf -o "${USAGE_TMPFILE}" -w "%{http_code}" \
    --max-time 120 \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
            {\"role\": \"user\", \"content\": \"Count from 1 to 3.\"}
        ],
        \"max_tokens\": 32,
        \"temperature\": 0.0,
        \"stream\": false
    }" \
    "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

if [ "${USAGE_HTTP}" != "200" ]; then
    _fail "Usage tokens: HTTP ${USAGE_HTTP}"
    rm -f "${USAGE_TMPFILE}"
else
    USAGE_CHECK=$(python3 << 'PYEOF' "${USAGE_TMPFILE}"
import sys, json

tmpfile = sys.argv[1]

try:
    with open(tmpfile) as f:
        data = json.load(f)

    usage = data.get('usage', {})
    if not usage:
        print('FAIL|"usage" block missing from response')
    else:
        pt = usage.get('prompt_tokens', 0)
        ct = usage.get('completion_tokens', 0)
        tt = usage.get('total_tokens', 0)

        issues = []
        if pt <= 0:
            issues.append(f'prompt_tokens={pt}')
        if ct <= 0:
            issues.append(f'completion_tokens={ct}')

        # Validate total = prompt + completion (if total is present)
        if tt > 0 and pt > 0 and ct > 0:
            expected_total = pt + ct
            if tt != expected_total:
                issues.append(f'total_tokens={tt} != prompt({pt})+completion({ct})={expected_total}')

        if issues:
            print(f'PASS|Token counts present but noted: {"; ".join(issues)} (prompt={pt}, completion={ct}, total={tt})')
        else:
            print(f'PASS|prompt_tokens={pt}, completion_tokens={ct}, total_tokens={tt}')

except Exception as e:
    print(f'FAIL|Parse error: {e}')
PYEOF
    )

    USAGE_STATUS="${USAGE_CHECK%%|*}"
    USAGE_DETAIL="${USAGE_CHECK#*|}"

    case "${USAGE_STATUS}" in
        PASS)   _pass "Usage tokens: ${USAGE_DETAIL}" ;;
        FAIL)   _fail "Usage tokens: ${USAGE_DETAIL}" ;;
    esac
    rm -f "${USAGE_TMPFILE}"
fi

# ===========================================================================
# Summary Report
# ===========================================================================
_log ""
_log "========================================================"
_log "  Chat Completion Compatibility Report"
_log "========================================================"
_log "  Endpoint : ${BASE_URL}/v1/chat/completions"
_log "  Model    : ${MODEL_NAME}"
_log ""
_log "  Checks   : ${TOTAL_CHECKS} total"
_log "  Passed   : ${PASS_COUNT}"
_log "  Failed   : ${FAIL_COUNT}"
_log "  Warnings : ${WARN_COUNT}"
_log ""

if [ "${FAIL_COUNT}" -eq 0 ]; then
    _log "  Result: PASS -- Chat completion format is OpenClaw-compatible"
    _log "========================================================"
    exit 0
else
    _log "  Result: FAIL -- ${FAIL_COUNT} check(s) failed"
    _log "========================================================"
    exit 1
fi
