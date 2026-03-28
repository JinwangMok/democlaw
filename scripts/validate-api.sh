#!/usr/bin/env bash
# =============================================================================
# validate-api.sh — Validate the vLLM OpenAI-compatible API endpoints
#
# Tests that the vLLM server (default port 8000) correctly exposes the
# OpenAI-compatible REST API required by OpenClaw:
#
#   GET  /health               — liveness probe
#   GET  /v1/models            — list loaded models (OpenAI-compatible)
#   POST /v1/chat/completions  — chat inference (OpenAI-compatible)
#
# This script can be run against any already-running vLLM instance and
# does NOT require the container to be present on this host (it only uses
# the HTTP API).  It is intentionally free of Docker/Podman dependencies
# so it is safe to run in CI without a GPU.
#
# Exit codes:
#   0 — All endpoint checks passed
#   1 — One or more checks failed
#
# Usage:
#   ./scripts/validate-api.sh
#   VLLM_HOST_PORT=8001 ./scripts/validate-api.sh          # custom port
#   VLLM_BASE_URL=http://192.168.1.10:8000 ./scripts/validate-api.sh
#   SKIP_INFERENCE_TEST=true ./scripts/validate-api.sh     # skip POST test
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
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen2.5-7B-Instruct-AWQ}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
INFERENCE_TIMEOUT="${INFERENCE_TIMEOUT:-30}"

# Optional API key — must match VLLM_API_KEY passed to the vLLM container.
# Leave empty (or "EMPTY") when the server is running in no-auth mode (default).
# When set to a real key, every curl request will include:
#   Authorization: Bearer <VLLM_API_KEY>
VLLM_API_KEY="${VLLM_API_KEY:-}"

# Set to "true" to skip the POST /v1/chat/completions inference test
# (useful when you only want to confirm the API shape without spending GPU time)
SKIP_INFERENCE_TEST="${SKIP_INFERENCE_TEST:-false}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Disable colours when not a terminal
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
# Build optional Authorization header for API key auth.
# When VLLM_API_KEY is empty, "EMPTY", or "none" we run in no-auth mode and
# include no Authorization header.  This matches the vLLM entrypoint logic.
# ---------------------------------------------------------------------------
AUTH_HEADER=""
_AUTH_MODE_LABEL="no-auth"
case "${VLLM_API_KEY:-}" in
    "" | EMPTY | none | no-auth )
        AUTH_HEADER=""
        _AUTH_MODE_LABEL="no-auth"
        ;;
    *)
        AUTH_HEADER="Authorization: Bearer ${VLLM_API_KEY}"
        _AUTH_MODE_LABEL="api-key"
        ;;
esac

# Build the curl args array for the Authorization header once, globally.
# When AUTH_HEADER is empty (no-auth mode), the array is empty and expands
# to nothing in curl command lines.  When set, it adds -H "Authorization: Bearer <key>".
_CURL_AUTH_ARGS=()
if [ -n "${AUTH_HEADER}" ]; then
    _CURL_AUTH_ARGS=(-H "${AUTH_HEADER}")
fi

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
echo "  vLLM OpenAI-Compatible API Validation"
echo "======================================================="
echo "  Base URL  : ${VLLM_BASE_URL}"
echo "  Model     : ${MODEL_NAME}"
echo "  Auth mode : ${_AUTH_MODE_LABEL}"
echo "======================================================="
echo ""
echo "  Network note: when run from another container on the same network,"
echo "  set VLLM_BASE_URL=http://vllm:${VLLM_HOST_PORT} to test container-to-container"
echo "  reachability via the 'vllm' network alias."
echo "======================================================="

# ===========================================================================
# Check 1: GET /health — liveness probe
# ===========================================================================
header "1. GET /health — liveness probe"
info "Endpoint: ${VLLM_BASE_URL}/health"

HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    --max-time "${CURL_TIMEOUT}" \
    "${_CURL_AUTH_ARGS[@]}" \
    "${VLLM_BASE_URL}/health" 2>/dev/null || echo "000")

if [ "${HTTP_CODE}" = "200" ]; then
    pass "HTTP ${HTTP_CODE} — server is live"
else
    fail "HTTP ${HTTP_CODE} — expected 200. Is the vLLM server running at ${VLLM_BASE_URL}?"
fi

# ===========================================================================
# Check 2: GET /v1/models — OpenAI-compatible model listing
# ===========================================================================
header "2. GET /v1/models — OpenAI-compatible model listing"
info "Endpoint: ${VLLM_BASE_URL}/v1/models"

TMPFILE=$(mktemp)

HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
    --max-time "${CURL_TIMEOUT}" \
    -H "Accept: application/json" \
    "${_CURL_AUTH_ARGS[@]}" \
    "${VLLM_BASE_URL}/v1/models" 2>/dev/null || echo "000")

RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
rm -f "${TMPFILE}"

if [ "${HTTP_CODE}" != "200" ]; then
    fail "HTTP ${HTTP_CODE} — expected 200"
else
    pass "HTTP 200"

    # Validate JSON structure: must have {"object":"list","data":[...]}
    if command -v python3 > /dev/null 2>&1; then
        MODELS_RESULT=$(echo "${RESPONSE}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    assert data.get('object') == 'list', 'object field is not \"list\"'
    models = data.get('data', [])
    assert isinstance(models, list), 'data field is not an array'
    ids = [m.get('id', '') for m in models]
    print('count=' + str(len(ids)))
    print('ids=' + ','.join(ids))
except AssertionError as e:
    print('error=' + str(e))
except Exception as e:
    print('error=parse failed: ' + str(e))
" 2>/dev/null || echo "error=python3 parse failed")

        case "${MODELS_RESULT}" in
            error=*)
                fail "Response JSON invalid: ${MODELS_RESULT#error=}"
                ;;
            *)
                MODEL_COUNT=$(echo "${MODELS_RESULT}" | grep '^count=' | cut -d= -f2)
                MODEL_IDS=$(echo "${MODELS_RESULT}" | grep '^ids=' | cut -d= -f2-)

                if [ "${MODEL_COUNT:-0}" -gt 0 ]; then
                    pass "Response is valid OpenAI-format JSON (object=list, data=[...])"
                    pass "${MODEL_COUNT} model(s) listed: ${MODEL_IDS}"
                else
                    fail "Response is valid JSON but data[] is empty — no models loaded yet"
                fi

                # Check the expected model is present
                if echo "${MODEL_IDS:-}" | grep -qF "${MODEL_NAME}"; then
                    pass "Expected model '${MODEL_NAME}' is loaded"
                else
                    if [ "${MODEL_COUNT:-0}" -gt 0 ]; then
                        echo -e "  ${YELLOW}⚠${NC}  Expected model '${MODEL_NAME}' not found; available: ${MODEL_IDS}"
                    fi
                fi
                ;;
        esac
    else
        # Fallback: grep-based check when python3 is unavailable
        if echo "${RESPONSE}" | grep -q '"object"' && echo "${RESPONSE}" | grep -q '"data"'; then
            pass "Response contains expected JSON fields (object, data)"
        else
            fail "Response does not appear to be valid OpenAI model-list JSON"
        fi
    fi
fi

# ===========================================================================
# Check 3: POST /v1/chat/completions — OpenAI-compatible chat inference
# ===========================================================================
header "3. POST /v1/chat/completions — chat inference endpoint"
info "Endpoint: ${VLLM_BASE_URL}/v1/chat/completions"

if [ "${SKIP_INFERENCE_TEST}" = "true" ]; then
    skip "Inference test skipped (SKIP_INFERENCE_TEST=true)"
else
    PAYLOAD=$(cat <<PAYLOAD_EOF
{
  "model": "${MODEL_NAME}",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user",   "content": "Reply with exactly one word: hello"}
  ],
  "max_tokens": 16,
  "temperature": 0
}
PAYLOAD_EOF
)

    TMPFILE=$(mktemp)

    HTTP_CODE=$(curl -sf -o "${TMPFILE}" -w "%{http_code}" \
        --max-time "${INFERENCE_TIMEOUT}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        "${_CURL_AUTH_ARGS[@]}" \
        -d "${PAYLOAD}" \
        "${VLLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    RESPONSE=$(cat "${TMPFILE}" 2>/dev/null || echo "")
    rm -f "${TMPFILE}"

    if [ "${HTTP_CODE}" != "200" ]; then
        fail "HTTP ${HTTP_CODE} — expected 200"
    else
        pass "HTTP 200"

        if command -v python3 > /dev/null 2>&1; then
            INFERENCE_RESULT=$(echo "${RESPONSE}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)

    # Validate top-level shape
    assert 'id' in data,      'missing id field'
    assert 'object' in data,  'missing object field'
    assert 'choices' in data, 'missing choices array'
    assert 'usage' in data,   'missing usage object'

    choices = data['choices']
    assert isinstance(choices, list) and len(choices) > 0, 'choices is empty'

    choice = choices[0]
    assert 'message' in choice,          'choice missing message'
    assert 'finish_reason' in choice,    'choice missing finish_reason'

    msg = choice['message']
    assert msg.get('role') == 'assistant', 'message role is not assistant'
    content = msg.get('content', '')
    assert content, 'message content is empty'

    usage = data['usage']
    assert 'prompt_tokens' in usage,     'usage missing prompt_tokens'
    assert 'completion_tokens' in usage, 'usage missing completion_tokens'
    assert 'total_tokens' in usage,      'usage missing total_tokens'

    print('ok=content=' + content.strip()[:80])
    print('ok=finish_reason=' + str(choice.get('finish_reason')))
    print('ok=prompt_tokens=' + str(usage.get('prompt_tokens', 0)))
    print('ok=completion_tokens=' + str(usage.get('completion_tokens', 0)))
except AssertionError as e:
    print('error=' + str(e))
except Exception as e:
    print('error=parse failed: ' + str(e))
" 2>/dev/null || echo "error=python3 parse failed")

            case "${INFERENCE_RESULT}" in
                error=*)
                    fail "Response JSON invalid: ${INFERENCE_RESULT#error=}"
                    ;;
                *)
                    CONTENT=$(echo "${INFERENCE_RESULT}"    | grep '^ok=content=' | cut -d= -f3-)
                    FINISH=$(echo "${INFERENCE_RESULT}"     | grep '^ok=finish_reason=' | cut -d= -f3-)
                    PROMPT_TOK=$(echo "${INFERENCE_RESULT}" | grep '^ok=prompt_tokens=' | cut -d= -f3-)
                    COMP_TOK=$(echo "${INFERENCE_RESULT}"   | grep '^ok=completion_tokens=' | cut -d= -f3-)

                    pass "Response is valid OpenAI chat completion JSON"
                    pass "Message content: \"${CONTENT}\""
                    pass "finish_reason: ${FINISH}"
                    pass "Tokens used: ${PROMPT_TOK} prompt + ${COMP_TOK} completion"
                    ;;
            esac
        else
            # Fallback: grep-based check
            if echo "${RESPONSE}" | grep -q '"choices"' && echo "${RESPONSE}" | grep -q '"message"'; then
                pass "Response contains expected JSON fields (choices, message)"
            else
                fail "Response does not appear to be valid OpenAI chat completion JSON"
            fi
        fi
    fi
fi

# ===========================================================================
# Check 4: Network reachability configuration (informational)
#
# This check reports the network configuration that makes the vLLM API
# reachable from other containers on the shared network.  It does not
# attempt a live connection (that requires running inside the network) but
# validates that the configured VLLM_BASE_URL uses the correct alias when
# invoked container-to-container, vs localhost when invoked from the host.
# ===========================================================================
header "4. Network reachability configuration"

# Inspect the base URL to determine if we're testing from the host or from
# within the container network.
_IS_NETWORK_TEST="false"
_EXPECTED_NETWORK_URL="http://vllm:${VLLM_HOST_PORT}/v1"

if echo "${VLLM_BASE_URL}" | grep -q "vllm"; then
    _IS_NETWORK_TEST="true"
fi

info "Configured base URL    : ${VLLM_BASE_URL}"
info "Container network alias: vllm  (reachable at http://vllm:${VLLM_HOST_PORT}/v1)"
info "Host access URL        : http://localhost:${VLLM_HOST_PORT}/v1"
info "Shared network name    : democlaw-net (created by start-vllm.sh)"

if [ "${_IS_NETWORK_TEST}" = "true" ]; then
    pass "VLLM_BASE_URL uses the container network alias 'vllm' — correct for container-to-container access"
else
    pass "VLLM_BASE_URL uses localhost — correct for host-side access"
    echo ""
    echo -e "  ${CYAN}ℹ${NC}  To test container-to-container reachability from within the shared network,"
    echo -e "  ${CYAN}ℹ${NC}  run this script with:  VLLM_BASE_URL=${_EXPECTED_NETWORK_URL} $0"
fi

# Report auth mode
case "${_AUTH_MODE_LABEL}" in
    no-auth)
        pass "Auth mode: no-auth — vLLM accepts all requests; no Authorization header required"
        echo -e "  ${YELLOW}ℹ${NC}  OpenClaw config.json apiKey ('EMPTY') is compatible with no-auth mode"
        ;;
    api-key)
        pass "Auth mode: api-key — requests must include 'Authorization: Bearer ${VLLM_API_KEY}'"
        echo -e "  ${CYAN}ℹ${NC}  Ensure openclaw/config.json apiKey matches VLLM_API_KEY"
        ;;
esac

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "======================================================="
if [ "${FAILED}" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}PASS${NC} — All API endpoint checks passed"
    echo ""
    echo "  The vLLM server at ${VLLM_BASE_URL} correctly exposes"
    echo "  an OpenAI-compatible API on port ${VLLM_HOST_PORT}."
    echo ""
    echo "  Container-to-container access (from OpenClaw):"
    echo "    URL : http://vllm:${VLLM_HOST_PORT}/v1"
    echo "    Auth: ${_AUTH_MODE_LABEL}"
else
    echo -e "  ${RED}${BOLD}FAIL${NC} — ${FAILED} check(s) failed"
    echo ""
    echo "  Ensure the vLLM container is running and healthy:"
    echo "    ./scripts/start-vllm.sh"
    echo "    ./scripts/healthcheck.sh --vllm-only"
fi
echo "======================================================="
echo ""

exit "${FAILED}"
