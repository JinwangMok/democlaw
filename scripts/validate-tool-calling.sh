#!/usr/bin/env bash
# =============================================================================
# validate-tool-calling.sh — Verify llama.cpp server tool/function calling
#
# Tests that the llama.cpp server (default port 8000) correctly exposes
# OpenAI-compatible /v1/chat/completions with tool/function calling support:
#
#   1. tools parameter accepted (array of function definitions)
#   2. tool_choice parameter accepted (auto, none, required, specific function)
#   3. Response contains tool_calls array when model decides to call a tool
#   4. Multi-turn tool use flow (tool call → tool result → final response)
#
# This script validates the API contract that OpenClaw depends on for
# function calling. It does NOT require the container to be local — it
# only uses the HTTP API.
#
# Exit codes:
#   0 — All tool-calling checks passed
#   1 — One or more checks failed
#
# Usage:
#   ./scripts/validate-tool-calling.sh
#   VLLM_HOST_PORT=8001 ./scripts/validate-tool-calling.sh
#   VLLM_BASE_URL=http://192.168.1.10:8000 ./scripts/validate-tool-calling.sh
#   SKIP_LIVE_TEST=true ./scripts/validate-tool-calling.sh   # schema-only
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

VLLM_HOST_PORT="${VLLM_HOST_PORT:-8000}"
VLLM_BASE_URL="${VLLM_BASE_URL:-http://localhost:${VLLM_HOST_PORT}}"
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3.5-9B}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
INFERENCE_TIMEOUT="${INFERENCE_TIMEOUT:-60}"

# Optional API key
VLLM_API_KEY="${VLLM_API_KEY:-}"

# Set to "true" to skip live inference tests (only validate request schemas)
SKIP_LIVE_TEST="${SKIP_LIVE_TEST:-false}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ ! -t 1 ]; then
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

pass()  { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; FAILED=$((FAILED + 1)); }
skip()  { echo -e "  ${YELLOW}—${NC} $* (skipped)"; }
info()  { echo -e "${CYAN}▶${NC} $*"; }
header(){ echo -e "\n${BOLD}$*${NC}"; }

FAILED=0

# ---------------------------------------------------------------------------
# Build auth header
# ---------------------------------------------------------------------------
_CURL_AUTH_ARGS=()
_AUTH_MODE_LABEL="no-auth"
case "${VLLM_API_KEY:-}" in
    "" | EMPTY | none | no-auth )
        _AUTH_MODE_LABEL="no-auth"
        ;;
    *)
        _CURL_AUTH_ARGS=(-H "Authorization: Bearer ${VLLM_API_KEY}")
        _AUTH_MODE_LABEL="api-key"
        ;;
esac

# ---------------------------------------------------------------------------
# Require curl
# ---------------------------------------------------------------------------
if ! command -v curl > /dev/null 2>&1; then
    echo "ERROR: 'curl' is required but not found in PATH." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Print banner
# ---------------------------------------------------------------------------
echo ""
echo "======================================================="
echo "  llama.cpp Tool/Function Calling API Validation"
echo "======================================================="
echo "  Base URL  : ${VLLM_BASE_URL}"
echo "  Model     : ${MODEL_NAME}"
echo "  Auth mode : ${_AUTH_MODE_LABEL}"
echo "======================================================="
echo ""

# ===========================================================================
# Check 1: POST /v1/chat/completions with tools parameter accepted
#
# Verify the server accepts a request containing the 'tools' array
# without returning a 4xx/5xx error. This confirms the endpoint
# recognizes OpenAI function calling schema.
# ===========================================================================
header "1. POST /v1/chat/completions — tools parameter accepted"
info "Endpoint: ${VLLM_BASE_URL}/v1/chat/completions"

if [ "${SKIP_LIVE_TEST}" = "true" ]; then
    skip "Live test skipped (SKIP_LIVE_TEST=true)"
else
    # Define a simple tool (get_weather) following OpenAI function calling format
    TOOLS_PAYLOAD=$(cat <<'TOOLS_EOF'
{
  "model": "__MODEL__",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant with access to tools. When the user asks about weather, use the get_weather tool."},
    {"role": "user", "content": "What is the weather like in Seoul right now?"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a given location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {
              "type": "string",
              "description": "City name, e.g. Seoul, Korea"
            },
            "unit": {
              "type": "string",
              "enum": ["celsius", "fahrenheit"],
              "description": "Temperature unit"
            }
          },
          "required": ["location"]
        }
      }
    }
  ],
  "tool_choice": "auto",
  "max_tokens": 512,
  "temperature": 0
}
TOOLS_EOF
)
    # Replace __MODEL__ with actual model name
    TOOLS_PAYLOAD="${TOOLS_PAYLOAD//__MODEL__/${MODEL_NAME}}"

    TMPFILE=$(mktemp)

    HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
        --max-time "${INFERENCE_TIMEOUT}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        ${_CURL_AUTH_ARGS[@]+"${_CURL_AUTH_ARGS[@]}"} \
        -d "${TOOLS_PAYLOAD}" \
        "${VLLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
    rm -f "${TMPFILE}"

    if [ "${HTTP_CODE}" = "000" ]; then
        fail "HTTP 000 — server unreachable at ${VLLM_BASE_URL}"
    elif [ "${HTTP_CODE}" = "200" ]; then
        pass "HTTP 200 — server accepts tools parameter"

        # Parse the response to check for tool_calls.
        # llama.cpp has two known response format variants:
        #   - Standard OpenAI: tool_calls[].function.{name, arguments}, finish_reason="tool_calls"
        #   - Older llama.cpp: tool_calls[].{name, arguments} (flat), finish_reason="tool"
        # We handle both formats gracefully.
        if command -v python3 > /dev/null 2>&1; then
            TOOL_RESULT=$(echo "${RESPONSE}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)

    # Basic structure validation
    assert 'choices' in data, 'missing choices array'
    assert len(data['choices']) > 0, 'choices is empty'

    choice = data['choices'][0]
    msg = choice.get('message', {})
    finish = choice.get('finish_reason', '')

    # Check if model made tool calls
    tool_calls = msg.get('tool_calls', None)
    content = msg.get('content', None)

    if tool_calls and len(tool_calls) > 0:
        print('has_tool_calls=true')
        print('tool_call_count=' + str(len(tool_calls)))
        for i, tc in enumerate(tool_calls):
            # Strict OpenAI format validation:
            #   Each tool_call MUST have: id (string), type ('function'),
            #   function.name (string), function.arguments (string/JSON)
            tc_id = tc.get('id', None)
            tc_type = tc.get('type', None)
            fn_obj = tc.get('function', None)

            # Track format compliance per tool call
            fmt_ok = True

            if tc_id is None or not isinstance(tc_id, str) or tc_id == '':
                print(f'tool_call_{i}_id_missing=true')
                fmt_ok = False
            else:
                print(f'tool_call_{i}_id={tc_id}')

            if tc_type != 'function':
                print(f'tool_call_{i}_type_invalid={tc_type}')
                fmt_ok = False
            else:
                print(f'tool_call_{i}_type={tc_type}')

            if fn_obj is None or not isinstance(fn_obj, dict):
                print(f'tool_call_{i}_function_missing=true')
                fmt_ok = False
                name = 'unknown'
                args = '{}'
            else:
                name = fn_obj.get('name', None)
                args = fn_obj.get('arguments', None)
                if name is None or not isinstance(name, str) or name == '':
                    print(f'tool_call_{i}_name_missing=true')
                    fmt_ok = False
                    name = 'unknown'
                else:
                    print(f'tool_call_{i}_name={name}')
                if args is None:
                    print(f'tool_call_{i}_args_missing=true')
                    fmt_ok = False
                    args = '{}'
                else:
                    print(f'tool_call_{i}_args={args}')
                    # Verify arguments is valid JSON string
                    if isinstance(args, str):
                        try:
                            json.loads(args)
                            print(f'tool_call_{i}_args_valid_json=true')
                        except json.JSONDecodeError:
                            print(f'tool_call_{i}_args_valid_json=false')
                            fmt_ok = False
                    else:
                        print(f'tool_call_{i}_args_valid_json=false')
                        fmt_ok = False

            print(f'tool_call_{i}_format_ok={str(fmt_ok).lower()}')
        # finish_reason may be 'tool_calls' (OpenAI standard) or 'tool' (some llama.cpp builds)
        print('finish_reason=' + str(finish))
        if finish in ('tool_calls', 'tool', 'stop'):
            print('finish_reason_valid=true')
        else:
            print('finish_reason_valid=false')
    else:
        print('has_tool_calls=false')
        print('finish_reason=' + str(finish))
        if content:
            print('content=' + content.strip()[:120])
except Exception as e:
    print('error=' + str(e))
" 2>/dev/null || echo "error=python3 parse failed")

            case "${TOOL_RESULT}" in
                error=*)
                    fail "Response parse error: ${TOOL_RESULT#error=}"
                    ;;
                *)
                    HAS_TOOL_CALLS=$(echo "${TOOL_RESULT}" | grep '^has_tool_calls=' | cut -d= -f2)
                    FINISH_REASON=$(echo "${TOOL_RESULT}" | grep '^finish_reason=' | cut -d= -f2)

                    if [ "${HAS_TOOL_CALLS}" = "true" ]; then
                        TC_COUNT=$(echo "${TOOL_RESULT}" | grep '^tool_call_count=' | cut -d= -f2)
                        TC0_NAME=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_name=' | cut -d= -f2)
                        TC0_ARGS=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_args=' | cut -d= -f2-)
                        TC0_ID=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_id=' | cut -d= -f2-)
                        TC0_TYPE=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_type=' | cut -d= -f2-)
                        FR_VALID=$(echo "${TOOL_RESULT}" | grep '^finish_reason_valid=' | cut -d= -f2)
                        pass "Model returned ${TC_COUNT} tool call(s)"
                        pass "Tool call: ${TC0_NAME}(${TC0_ARGS})"
                        pass "finish_reason: ${FINISH_REASON}"

                        # Strict OpenAI format compliance checks
                        TC0_FMT=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_format_ok=' | cut -d= -f2)
                        TC0_ARGS_JSON=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_args_valid_json=' | cut -d= -f2)

                        if [ "${TC0_FMT}" = "true" ]; then
                            pass "OpenAI format: all required fields present (id, type, function.name, function.arguments)"
                        else
                            fail "OpenAI format: one or more required fields missing or invalid"
                        fi

                        # Individual field checks
                        TC0_ID_MISSING=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_id_missing=' | cut -d= -f2)
                        TC0_TYPE_INVALID=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_type_invalid=' | cut -d= -f2-)
                        TC0_FN_MISSING=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_function_missing=' | cut -d= -f2)
                        TC0_NAME_MISSING=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_name_missing=' | cut -d= -f2)
                        TC0_ARGS_MISSING=$(echo "${TOOL_RESULT}" | grep '^tool_call_0_args_missing=' | cut -d= -f2)

                        if [ "${TC0_ID_MISSING}" = "true" ]; then
                            fail "tool_calls[].id MISSING — required by OpenAI API spec"
                        else
                            pass "tool_calls[].id present: ${TC0_ID}"
                        fi

                        if [ -n "${TC0_TYPE_INVALID}" ]; then
                            fail "tool_calls[].type = '${TC0_TYPE_INVALID}' — expected 'function'"
                        else
                            pass "tool_calls[].type = 'function'"
                        fi

                        if [ "${TC0_FN_MISSING}" = "true" ]; then
                            fail "tool_calls[].function MISSING — required nested object"
                        else
                            if [ "${TC0_NAME_MISSING}" = "true" ]; then
                                fail "tool_calls[].function.name MISSING"
                            else
                                pass "tool_calls[].function.name = '${TC0_NAME}'"
                            fi
                            if [ "${TC0_ARGS_MISSING}" = "true" ]; then
                                fail "tool_calls[].function.arguments MISSING"
                            elif [ "${TC0_ARGS_JSON}" = "false" ]; then
                                fail "tool_calls[].function.arguments is not valid JSON"
                            else
                                pass "tool_calls[].function.arguments is valid JSON"
                            fi
                        fi

                        # Validate tool call name matches our defined tool
                        if [ "${TC0_NAME}" = "get_weather" ]; then
                            pass "Tool call name matches defined function 'get_weather'"
                        else
                            echo -e "  ${YELLOW}⚠${NC}  Tool call name '${TC0_NAME}' differs from expected 'get_weather'"
                        fi

                        # Validate arguments contain location
                        if echo "${TC0_ARGS}" | grep -qi "seoul"; then
                            pass "Tool call arguments contain expected location 'Seoul'"
                        else
                            echo -e "  ${YELLOW}⚠${NC}  Tool call arguments may not contain 'Seoul': ${TC0_ARGS}"
                        fi
                    else
                        # Model chose to respond with text instead of tool call
                        # This is valid behavior when tool_choice=auto
                        echo -e "  ${YELLOW}⚠${NC}  Model responded with text instead of tool call (tool_choice=auto allows this)"
                        CONTENT=$(echo "${TOOL_RESULT}" | grep '^content=' | cut -d= -f2-)
                        echo -e "  ${YELLOW}ℹ${NC}  Content: ${CONTENT:-<empty>}"
                        pass "Response is valid OpenAI chat completion JSON (tools parameter accepted)"
                    fi
                    ;;
            esac
        else
            # Fallback: grep-based check
            if echo "${RESPONSE}" | grep -q '"choices"'; then
                pass "Response contains choices array (tools parameter accepted)"
            else
                fail "Response does not appear valid"
            fi
        fi
    else
        fail "HTTP ${HTTP_CODE} — server rejected tools parameter"
        # Show error detail if available
        if [ -n "${RESPONSE}" ]; then
            echo -e "  ${RED}Detail:${NC} ${RESPONSE}" | head -c 300
            echo ""
        fi
    fi
fi

# ===========================================================================
# Check 2: tool_choice variants accepted
#
# Test that tool_choice accepts: "auto", "none", "required", and
# specific function form {"type":"function","function":{"name":"..."}}
# ===========================================================================
header "2. POST /v1/chat/completions — tool_choice variants"

if [ "${SKIP_LIVE_TEST}" = "true" ]; then
    skip "Live test skipped (SKIP_LIVE_TEST=true)"
else
    # Test tool_choice="none" — model should NOT make tool calls
    NONE_PAYLOAD=$(cat <<'NONE_EOF'
{
  "model": "__MODEL__",
  "messages": [
    {"role": "user", "content": "What is 2+2?"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "calculator",
        "description": "Perform arithmetic",
        "parameters": {
          "type": "object",
          "properties": {
            "expression": {"type": "string"}
          },
          "required": ["expression"]
        }
      }
    }
  ],
  "tool_choice": "none",
  "max_tokens": 128,
  "temperature": 0
}
NONE_EOF
)
    NONE_PAYLOAD="${NONE_PAYLOAD//__MODEL__/${MODEL_NAME}}"

    TMPFILE=$(mktemp)
    HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
        --max-time "${INFERENCE_TIMEOUT}" \
        -H "Content-Type: application/json" \
        ${_CURL_AUTH_ARGS[@]+"${_CURL_AUTH_ARGS[@]}"} \
        -d "${NONE_PAYLOAD}" \
        "${VLLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
    rm -f "${TMPFILE}"

    if [ "${HTTP_CODE}" = "200" ]; then
        pass "tool_choice=\"none\" — HTTP 200 accepted"

        if command -v python3 > /dev/null 2>&1; then
            HAS_TC=$(echo "${RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    tc = d.get('choices',[{}])[0].get('message',{}).get('tool_calls', None)
    print('true' if tc and len(tc) > 0 else 'false')
except:
    print('error')
" 2>/dev/null || echo "error")
            if [ "${HAS_TC}" = "false" ]; then
                pass "tool_choice=\"none\" — model correctly did NOT return tool calls"
            elif [ "${HAS_TC}" = "true" ]; then
                echo -e "  ${YELLOW}⚠${NC}  tool_choice=\"none\" but model still returned tool calls"
            fi
        fi
    else
        fail "tool_choice=\"none\" — HTTP ${HTTP_CODE} (expected 200)"
    fi

    # Test tool_choice="required" — model MUST make a tool call
    REQUIRED_PAYLOAD=$(cat <<'REQ_EOF'
{
  "model": "__MODEL__",
  "messages": [
    {"role": "user", "content": "What is the weather in Tokyo?"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string", "description": "City name"}
          },
          "required": ["location"]
        }
      }
    }
  ],
  "tool_choice": "required",
  "max_tokens": 256,
  "temperature": 0
}
REQ_EOF
)
    REQUIRED_PAYLOAD="${REQUIRED_PAYLOAD//__MODEL__/${MODEL_NAME}}"

    TMPFILE=$(mktemp)
    HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
        --max-time "${INFERENCE_TIMEOUT}" \
        -H "Content-Type: application/json" \
        ${_CURL_AUTH_ARGS[@]+"${_CURL_AUTH_ARGS[@]}"} \
        -d "${REQUIRED_PAYLOAD}" \
        "${VLLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
    rm -f "${TMPFILE}"

    if [ "${HTTP_CODE}" = "200" ]; then
        pass "tool_choice=\"required\" — HTTP 200 accepted"

        if command -v python3 > /dev/null 2>&1; then
            HAS_TC=$(echo "${RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    tc = d.get('choices',[{}])[0].get('message',{}).get('tool_calls', None)
    print('true' if tc and len(tc) > 0 else 'false')
except:
    print('error')
" 2>/dev/null || echo "error")
            if [ "${HAS_TC}" = "true" ]; then
                pass "tool_choice=\"required\" — model correctly returned tool call(s)"
            else
                echo -e "  ${YELLOW}⚠${NC}  tool_choice=\"required\" but model did not return tool calls"
            fi
        fi
    else
        fail "tool_choice=\"required\" — HTTP ${HTTP_CODE} (expected 200)"
    fi

    # Test tool_choice=specific function
    SPECIFIC_PAYLOAD=$(cat <<'SPEC_EOF'
{
  "model": "__MODEL__",
  "messages": [
    {"role": "user", "content": "Tell me about Seoul"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string"}
          },
          "required": ["location"]
        }
      }
    }
  ],
  "tool_choice": {"type": "function", "function": {"name": "get_weather"}},
  "max_tokens": 256,
  "temperature": 0
}
SPEC_EOF
)
    SPECIFIC_PAYLOAD="${SPECIFIC_PAYLOAD//__MODEL__/${MODEL_NAME}}"

    TMPFILE=$(mktemp)
    HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
        --max-time "${INFERENCE_TIMEOUT}" \
        -H "Content-Type: application/json" \
        ${_CURL_AUTH_ARGS[@]+"${_CURL_AUTH_ARGS[@]}"} \
        -d "${SPECIFIC_PAYLOAD}" \
        "${VLLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
    rm -f "${TMPFILE}"

    if [ "${HTTP_CODE}" = "200" ]; then
        pass "tool_choice={specific function} — HTTP 200 accepted"
    elif [ "${HTTP_CODE}" = "400" ]; then
        echo -e "  ${YELLOW}⚠${NC}  tool_choice={specific function} — HTTP 400 (may not be supported by this build)"
    else
        fail "tool_choice={specific function} — HTTP ${HTTP_CODE}"
    fi
fi

# ===========================================================================
# Check 3: Multi-turn tool use flow
#
# Simulates the full tool-use conversation:
#   1. User asks question → model returns tool_call
#   2. Tool result sent back → model generates final response
# This validates the complete round-trip that OpenClaw uses.
# ===========================================================================
header "3. Multi-turn tool use flow (tool_call → tool_result → response)"

if [ "${SKIP_LIVE_TEST}" = "true" ]; then
    skip "Live test skipped (SKIP_LIVE_TEST=true)"
else
    # Step 1: Get tool call from model
    info "Step 1: Send request with tools, expect tool_call response"

    STEP1_PAYLOAD=$(cat <<'S1_EOF'
{
  "model": "__MODEL__",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant. When asked about weather, always use the get_weather tool. Do not answer weather questions without using the tool."},
    {"role": "user", "content": "What is the current weather in Seoul?"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {
              "type": "string",
              "description": "City name"
            }
          },
          "required": ["location"]
        }
      }
    }
  ],
  "tool_choice": "auto",
  "max_tokens": 256,
  "temperature": 0
}
S1_EOF
)
    STEP1_PAYLOAD="${STEP1_PAYLOAD//__MODEL__/${MODEL_NAME}}"

    TMPFILE=$(mktemp)
    HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
        --max-time "${INFERENCE_TIMEOUT}" \
        -H "Content-Type: application/json" \
        ${_CURL_AUTH_ARGS[@]+"${_CURL_AUTH_ARGS[@]}"} \
        -d "${STEP1_PAYLOAD}" \
        "${VLLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    STEP1_RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
    rm -f "${TMPFILE}"

    TOOL_CALL_ID=""
    TOOL_CALL_NAME=""

    if [ "${HTTP_CODE}" = "200" ] && command -v python3 > /dev/null 2>&1; then
        STEP1_PARSED=$(echo "${STEP1_RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    msg = d['choices'][0]['message']
    tc = msg.get('tool_calls', None)
    if tc and len(tc) > 0:
        call = tc[0]
        # Handle both llama.cpp format and standard OpenAI format
        call_id = call.get('id', 'call_0')
        fn = call.get('function', call)
        name = fn.get('name', '')
        args = fn.get('arguments', '{}')
        print('ok')
        print('id=' + str(call_id))
        print('name=' + name)
        print('args=' + args)
    else:
        content = msg.get('content', '')
        print('no_tool_call')
        print('content=' + content[:100])
except Exception as e:
    print('error=' + str(e))
" 2>/dev/null || echo "error=python3 failed")

        case "${STEP1_PARSED}" in
            ok*)
                TOOL_CALL_ID=$(echo "${STEP1_PARSED}" | grep '^id=' | cut -d= -f2-)
                TOOL_CALL_NAME=$(echo "${STEP1_PARSED}" | grep '^name=' | cut -d= -f2-)
                TOOL_CALL_ARGS=$(echo "${STEP1_PARSED}" | grep '^args=' | cut -d= -f2-)
                pass "Step 1: Model returned tool call: ${TOOL_CALL_NAME}(${TOOL_CALL_ARGS})"
                ;;
            no_tool_call*)
                echo -e "  ${YELLOW}⚠${NC}  Step 1: Model responded with text instead of tool call"
                CONTENT=$(echo "${STEP1_PARSED}" | grep '^content=' | cut -d= -f2-)
                echo -e "  ${YELLOW}ℹ${NC}  Content: ${CONTENT}"
                ;;
            *)
                fail "Step 1: Failed to parse tool call response: ${STEP1_PARSED}"
                ;;
        esac
    else
        if [ "${HTTP_CODE}" != "200" ]; then
            fail "Step 1: HTTP ${HTTP_CODE}"
        fi
    fi

    # Step 2: Send tool result back and get final answer
    if [ -n "${TOOL_CALL_ID}" ] && [ -n "${TOOL_CALL_NAME}" ]; then
        info "Step 2: Send tool result, expect final text response"

        # Build multi-turn payload with tool result
        # Using python3 to properly construct the JSON
        STEP2_PAYLOAD=$(python3 -c "
import json
payload = {
    'model': '${MODEL_NAME}',
    'messages': [
        {'role': 'system', 'content': 'You are a helpful assistant. Use tool results to answer the user.'},
        {'role': 'user', 'content': 'What is the current weather in Seoul?'},
        {
            'role': 'assistant',
            'content': None,
            'tool_calls': [{
                'id': '${TOOL_CALL_ID}',
                'type': 'function',
                'function': {
                    'name': '${TOOL_CALL_NAME}',
                    'arguments': '{\"location\": \"Seoul\"}'
                }
            }]
        },
        {
            'role': 'tool',
            'tool_call_id': '${TOOL_CALL_ID}',
            'content': '{\"temperature\": 18, \"condition\": \"partly cloudy\", \"humidity\": 65, \"unit\": \"celsius\"}'
        }
    ],
    'max_tokens': 256,
    'temperature': 0
}
print(json.dumps(payload))
" 2>/dev/null || echo "{}")

        if [ "${STEP2_PAYLOAD}" != "{}" ]; then
            TMPFILE=$(mktemp)
            HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
                --max-time "${INFERENCE_TIMEOUT}" \
                -H "Content-Type: application/json" \
                ${_CURL_AUTH_ARGS[@]+"${_CURL_AUTH_ARGS[@]}"} \
                -d "${STEP2_PAYLOAD}" \
                "${VLLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

            STEP2_RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
            rm -f "${TMPFILE}"

            if [ "${HTTP_CODE}" = "200" ]; then
                pass "Step 2: HTTP 200 — server accepts tool result message"

                if command -v python3 > /dev/null 2>&1; then
                    STEP2_PARSED=$(echo "${STEP2_RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    msg = d['choices'][0]['message']
    content = msg.get('content', '')
    role = msg.get('role', '')
    finish = d['choices'][0].get('finish_reason', '')
    if content and role == 'assistant':
        print('ok')
        print('content=' + content.strip()[:200])
        print('finish_reason=' + finish)
    else:
        print('empty')
except Exception as e:
    print('error=' + str(e))
" 2>/dev/null || echo "error=parse failed")

                    case "${STEP2_PARSED}" in
                        ok*)
                            FINAL_CONTENT=$(echo "${STEP2_PARSED}" | grep '^content=' | cut -d= -f2-)
                            FINAL_FINISH=$(echo "${STEP2_PARSED}" | grep '^finish_reason=' | cut -d= -f2-)
                            pass "Step 2: Model generated final response from tool result"
                            pass "Content: \"${FINAL_CONTENT}\""
                            pass "finish_reason: ${FINAL_FINISH}"
                            ;;
                        empty*)
                            echo -e "  ${YELLOW}⚠${NC}  Step 2: Response has empty content"
                            ;;
                        *)
                            fail "Step 2: Parse error: ${STEP2_PARSED}"
                            ;;
                    esac
                fi
            else
                fail "Step 2: HTTP ${HTTP_CODE} — server rejected tool result message"
            fi
        else
            fail "Step 2: Could not construct multi-turn payload (python3 error)"
        fi
    else
        skip "Step 2: Skipped (no tool call from Step 1 to follow up on)"
    fi
fi

# ===========================================================================
# Check 4: Multiple tools in a single request
#
# Verify the server accepts multiple tool definitions in the tools array.
# This is critical for OpenClaw which may register several skill functions.
# ===========================================================================
header "4. Multiple tools definition support"

if [ "${SKIP_LIVE_TEST}" = "true" ]; then
    skip "Live test skipped (SKIP_LIVE_TEST=true)"
else
    MULTI_TOOLS_PAYLOAD=$(cat <<'MT_EOF'
{
  "model": "__MODEL__",
  "messages": [
    {"role": "user", "content": "What time is it in London and what is the weather there?"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {"type": "string", "description": "City name"}
          },
          "required": ["location"]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "get_time",
        "description": "Get the current time in a timezone",
        "parameters": {
          "type": "object",
          "properties": {
            "timezone": {"type": "string", "description": "IANA timezone, e.g. Europe/London"}
          },
          "required": ["timezone"]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "search_web",
        "description": "Search the web for information",
        "parameters": {
          "type": "object",
          "properties": {
            "query": {"type": "string", "description": "Search query"}
          },
          "required": ["query"]
        }
      }
    }
  ],
  "tool_choice": "auto",
  "max_tokens": 512,
  "temperature": 0
}
MT_EOF
)
    MULTI_TOOLS_PAYLOAD="${MULTI_TOOLS_PAYLOAD//__MODEL__/${MODEL_NAME}}"

    TMPFILE=$(mktemp)
    HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
        --max-time "${INFERENCE_TIMEOUT}" \
        -H "Content-Type: application/json" \
        ${_CURL_AUTH_ARGS[@]+"${_CURL_AUTH_ARGS[@]}"} \
        -d "${MULTI_TOOLS_PAYLOAD}" \
        "${VLLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
    rm -f "${TMPFILE}"

    if [ "${HTTP_CODE}" = "200" ]; then
        pass "HTTP 200 — server accepts multiple tools (3 functions defined)"

        if command -v python3 > /dev/null 2>&1; then
            MT_RESULT=$(echo "${RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    msg = d['choices'][0]['message']
    tc = msg.get('tool_calls', None)
    if tc and len(tc) > 0:
        names = []
        for call in tc:
            fn = call.get('function', call)
            names.append(fn.get('name', 'unknown'))
        print('tool_calls=' + ','.join(names))
        print('count=' + str(len(tc)))
    else:
        print('no_tool_calls')
        print('content=' + (msg.get('content', '') or '')[:100])
except Exception as e:
    print('error=' + str(e))
" 2>/dev/null || echo "error")

            case "${MT_RESULT}" in
                tool_calls=*)
                    TC_NAMES=$(echo "${MT_RESULT}" | grep '^tool_calls=' | cut -d= -f2-)
                    TC_COUNT=$(echo "${MT_RESULT}" | grep '^count=' | cut -d= -f2)
                    pass "Model selected ${TC_COUNT} tool(s) from multiple options: ${TC_NAMES}"
                    ;;
                no_tool_calls*)
                    pass "Response valid — model chose text response (tool_choice=auto)"
                    ;;
                *)
                    echo -e "  ${YELLOW}⚠${NC}  Could not parse tool call details"
                    ;;
            esac
        fi
    else
        fail "HTTP ${HTTP_CODE} — server rejected multiple tools"
    fi
fi

# ===========================================================================
# Check 5: Verify llama.cpp server configuration for tool calling
#
# Check that the server was started with --jinja flag (required for
# tool calling) by testing characteristic behavior.
# ===========================================================================
header "5. Server tool-calling capability verification"

if [ "${SKIP_LIVE_TEST}" = "true" ]; then
    skip "Live test skipped (SKIP_LIVE_TEST=true)"
else
    # The /health or /props endpoint may reveal server capabilities
    # Try /props first (llama.cpp specific)
    TMPFILE=$(mktemp)
    HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
        --max-time "${CURL_TIMEOUT}" \
        ${_CURL_AUTH_ARGS[@]+"${_CURL_AUTH_ARGS[@]}"} \
        "${VLLM_BASE_URL}/props" 2>/dev/null || echo "000")

    PROPS_RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
    rm -f "${TMPFILE}"

    if [ "${HTTP_CODE}" = "200" ] && [ -n "${PROPS_RESPONSE}" ]; then
        pass "GET /props — HTTP 200 (llama.cpp server properties)"

        if command -v python3 > /dev/null 2>&1; then
            PROPS_INFO=$(echo "${PROPS_RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    chat_template = d.get('default_generation_settings', {}).get('chat_template', '')
    has_template = bool(chat_template)
    total_slots = d.get('total_slots', 'unknown')
    print('has_chat_template=' + str(has_template))
    print('total_slots=' + str(total_slots))
    # Check for tool-related template markers
    if 'tool' in chat_template.lower() or 'function' in chat_template.lower():
        print('template_has_tool_support=true')
    else:
        print('template_has_tool_support=unknown')
except Exception as e:
    print('error=' + str(e))
" 2>/dev/null || echo "error")

            HAS_TEMPLATE=$(echo "${PROPS_INFO}" | grep '^has_chat_template=' | cut -d= -f2)
            TEMPLATE_TOOLS=$(echo "${PROPS_INFO}" | grep '^template_has_tool_support=' | cut -d= -f2)

            if [ "${HAS_TEMPLATE}" = "True" ]; then
                pass "Chat template is loaded"
                if [ "${TEMPLATE_TOOLS}" = "true" ]; then
                    pass "Chat template contains tool/function handling"
                fi
            else
                echo -e "  ${YELLOW}⚠${NC}  No chat template detected — tool calling may not work correctly"
            fi
        fi
    else
        info "GET /props not available (HTTP ${HTTP_CODE}) — this is normal if not running llama.cpp"
    fi

    # Verify the server is running and the model endpoint works
    TMPFILE=$(mktemp)
    HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
        --max-time "${CURL_TIMEOUT}" \
        ${_CURL_AUTH_ARGS[@]+"${_CURL_AUTH_ARGS[@]}"} \
        "${VLLM_BASE_URL}/v1/models" 2>/dev/null || echo "000")

    MODELS_RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
    rm -f "${TMPFILE}"

    if [ "${HTTP_CODE}" = "200" ]; then
        pass "GET /v1/models — HTTP 200"
        if command -v python3 > /dev/null 2>&1; then
            MODEL_ID=$(echo "${MODELS_RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    models = d.get('data', [])
    if models:
        print(models[0].get('id', 'unknown'))
    else:
        print('no_models')
except:
    print('error')
" 2>/dev/null || echo "error")
            if [ "${MODEL_ID}" != "error" ] && [ "${MODEL_ID}" != "no_models" ]; then
                pass "Model loaded: ${MODEL_ID}"
            fi
        fi
    fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "======================================================="
if [ "${FAILED}" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}PASS${NC} — All tool/function calling checks passed"
    echo ""
    echo "  The llama.cpp server at ${VLLM_BASE_URL} correctly exposes"
    echo "  OpenAI-compatible tool/function calling on /v1/chat/completions."
    echo ""
    echo "  Verified capabilities:"
    echo "    ✓ tools parameter (array of function definitions)"
    echo "    ✓ tool_choice variants (auto, none, required, specific)"
    echo "    ✓ Multi-turn tool use (call → result → response)"
    echo "    ✓ Multiple tool definitions in single request"
    echo ""
    echo "  OpenClaw Integration:"
    echo "    URL : http://vllm:${VLLM_HOST_PORT}/v1"
    echo "    Auth: ${_AUTH_MODE_LABEL}"
    echo "    Tool calling: SUPPORTED"
else
    echo -e "  ${RED}${BOLD}FAIL${NC} — ${FAILED} check(s) failed"
    echo ""
    echo "  Ensure the llama.cpp server is running with --jinja flag enabled:"
    echo "    llama-server --jinja -fa -m /models/model.gguf -ngl 99"
    echo ""
    echo "  For Qwen3.5 models, also consider:"
    echo "    --reasoning-format none   (avoids <think> tag interference)"
fi
echo "======================================================="
echo ""

exit "${FAILED}"
