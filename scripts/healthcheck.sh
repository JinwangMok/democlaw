#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — Verify vLLM and OpenClaw containers are healthy
#
# Checks that:
#   1. The container runtime (docker/podman) is available
#   2. The vLLM container is running
#   3. The vLLM /health endpoint responds
#   4. The vLLM /v1/models endpoint lists the expected model
#   5. The vLLM /v1/chat/completions endpoint handles a test request
#   6. (Optional) The OpenClaw container is running and dashboard responds
#
# Exit codes:
#   0 — All checks passed
#   1 — One or more checks failed
#
# Supports both docker and podman on Linux hosts.
#
# Usage:
#   ./scripts/healthcheck.sh              # check all services
#   ./scripts/healthcheck.sh --vllm-only  # check vLLM only
#   ./scripts/healthcheck.sh --json       # output results as JSON
#   CONTAINER_RUNTIME=podman ./scripts/healthcheck.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants & Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Load .env file if present
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

# ---------------------------------------------------------------------------
# Configurable defaults (all overridable via environment or .env file)
# ---------------------------------------------------------------------------
VLLM_CONTAINER_NAME="${VLLM_CONTAINER_NAME:-democlaw-vllm}"
OPENCLAW_CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-democlaw-openclaw}"
NETWORK_NAME="${DEMOCLAW_NETWORK:-democlaw-net}"

VLLM_HOST_PORT="${VLLM_HOST_PORT:-8000}"
OPENCLAW_HOST_PORT="${OPENCLAW_HOST_PORT:-18789}"
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-4B-AWQ}"

VLLM_BASE_URL="http://localhost:${VLLM_HOST_PORT}"
OPENCLAW_URL="http://localhost:${OPENCLAW_HOST_PORT}"

# Timeout for individual curl requests (seconds)
CURL_TIMEOUT="${HEALTHCHECK_CURL_TIMEOUT:-10}"

# ---------------------------------------------------------------------------
# Parse CLI flags
# ---------------------------------------------------------------------------
VLLM_ONLY=false
JSON_OUTPUT=false

for arg in "$@"; do
    case "${arg}" in
        --vllm-only)  VLLM_ONLY=true ;;
        --json)       JSON_OUTPUT=true ;;
        --help|-h)
            echo "Usage: $0 [--vllm-only] [--json] [--help]"
            echo ""
            echo "Options:"
            echo "  --vllm-only   Only check the vLLM service (skip OpenClaw)"
            echo "  --json        Output results as JSON"
            echo "  --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg}. Use --help for usage." >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Disable colors if not a terminal or if JSON mode
if [ ! -t 1 ] || [ "${JSON_OUTPUT}" = true ]; then
    RED='' GREEN='' YELLOW='' CYAN='' NC=''
fi

pass()  { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; }
warn_() { echo -e "  ${YELLOW}⚠${NC} $*"; }
info()  { echo -e "${CYAN}▶${NC} $*"; }

# ---------------------------------------------------------------------------
# Result tracking
# ---------------------------------------------------------------------------
CHECKS_TOTAL=0
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

# JSON results accumulator
declare -a JSON_RESULTS=()

record_pass() {
    local name="$1"; local detail="${2:-}"
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    if [ "${JSON_OUTPUT}" = false ]; then
        pass "${name}${detail:+ — ${detail}}"
    fi
    JSON_RESULTS+=("{\"check\":\"${name}\",\"status\":\"pass\",\"detail\":\"${detail}\"}")
}

record_fail() {
    local name="$1"; local detail="${2:-}"
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    if [ "${JSON_OUTPUT}" = false ]; then
        fail "${name}${detail:+ — ${detail}}"
    fi
    JSON_RESULTS+=("{\"check\":\"${name}\",\"status\":\"fail\",\"detail\":\"${detail}\"}")
}

record_warn() {
    local name="$1"; local detail="${2:-}"
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    CHECKS_WARNED=$((CHECKS_WARNED + 1))
    if [ "${JSON_OUTPUT}" = false ]; then
        warn_ "${name}${detail:+ — ${detail}}"
    fi
    JSON_RESULTS+=("{\"check\":\"${name}\",\"status\":\"warn\",\"detail\":\"${detail}\"}")
}

# ---------------------------------------------------------------------------
# Source the shared runtime-detection library
#
# Define custom handlers before sourcing so the library uses them:
#   - _rt_log  : silence library chatter in healthcheck output
#   - _rt_warn : capture to stderr only
#   - _rt_error: record error string but do NOT exit (healthcheck handles gracefully)
#
# _SKIP_RUNTIME_DETECT=true prevents the library from auto-running detect_runtime()
# on source; check_runtime() below will call it explicitly.
# ---------------------------------------------------------------------------
_RUNTIME_DETECT_ERROR=""

_rt_log()   { :; }  # silence info messages from the detection library
_rt_warn()  { echo "[runtime] WARNING: $*" >&2; }
# Override _rt_error so it records the error but does NOT call exit 1.
# The empty-RUNTIME guard in check_runtime() handles the failure path.
_rt_error() { _RUNTIME_DETECT_ERROR="$*"; echo "[runtime] ERROR: $*" >&2; }

_SKIP_RUNTIME_DETECT=true
# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

# ---------------------------------------------------------------------------
# Check: Container runtime available
#
# Uses the shared library's detect_runtime() which honours:
#   1. $CONTAINER_RUNTIME env var  (explicit override)
#   2. docker                       (if found in PATH)
#   3. podman                       (if found in PATH)
# ---------------------------------------------------------------------------
check_runtime() {
    info "Checking container runtime ..."

    _RUNTIME_DETECT_ERROR=""
    RUNTIME=""

    # detect_runtime sets RUNTIME / RUNTIME_IS_PODMAN globals (or records error)
    detect_runtime 2>/dev/null || true

    if [ -n "${_RUNTIME_DETECT_ERROR}" ] || [ -z "${RUNTIME:-}" ]; then
        local detail="${_RUNTIME_DETECT_ERROR:-Neither docker nor podman found in PATH}"
        record_fail "Container runtime" "${detail}"
        return 1
    fi

    local rt_ver
    rt_ver=$("${RUNTIME}" --version 2>/dev/null | head -1 || echo "version unknown")
    record_pass "Container runtime" "${RUNTIME} available (${rt_ver})"
    return 0
}

# ---------------------------------------------------------------------------
# Check: Container exists and is running
# ---------------------------------------------------------------------------
check_container_running() {
    local name="$1"
    local label="$2"

    if ! "${RUNTIME}" container inspect "${name}" > /dev/null 2>&1; then
        record_fail "${label} container" "Container '${name}' does not exist"
        return 1
    fi

    local state
    state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${name}" 2>/dev/null || echo "unknown")

    if [ "${state}" = "running" ]; then
        record_pass "${label} container" "'${name}' is running"
        return 0
    else
        record_fail "${label} container" "'${name}' state is '${state}' (expected: running)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Check: Container health status (if container has HEALTHCHECK)
# ---------------------------------------------------------------------------
check_container_health() {
    local name="$1"
    local label="$2"

    local health
    health=$("${RUNTIME}" container inspect --format '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo "none")

    case "${health}" in
        healthy)
            record_pass "${label} container health" "Docker HEALTHCHECK reports healthy"
            ;;
        unhealthy)
            record_fail "${label} container health" "Docker HEALTHCHECK reports unhealthy"
            return 1
            ;;
        starting)
            record_warn "${label} container health" "HEALTHCHECK still starting (model may be loading)"
            ;;
        none|"")
            # No healthcheck configured or not supported — skip silently
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Check: vLLM /health endpoint
# ---------------------------------------------------------------------------
check_vllm_health_endpoint() {
    info "Checking vLLM health endpoint ..."

    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        --max-time "${CURL_TIMEOUT}" \
        "${VLLM_BASE_URL}/health" 2>/dev/null || echo "000")

    if [ "${http_code}" = "200" ]; then
        record_pass "vLLM /health endpoint" "HTTP 200"
        return 0
    else
        record_fail "vLLM /health endpoint" "HTTP ${http_code} (expected 200) at ${VLLM_BASE_URL}/health"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Check: vLLM /v1/models endpoint — verifies OpenAI-compatible API works
# ---------------------------------------------------------------------------
check_vllm_models_endpoint() {
    info "Checking vLLM /v1/models endpoint ..."

    local http_code
    local response
    local tmpfile
    tmpfile=$(mktemp)

    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time "${CURL_TIMEOUT}" \
        "${VLLM_BASE_URL}/v1/models" 2>/dev/null || echo "000")

    response=$(cat "${tmpfile}" 2>/dev/null || echo "")
    rm -f "${tmpfile}"

    if [ "${http_code}" = "000" ] || [ -z "${response}" ]; then
        record_fail "vLLM /v1/models endpoint" "No response from ${VLLM_BASE_URL}/v1/models (HTTP ${http_code})"
        return 1
    fi

    if [ "${http_code}" != "200" ]; then
        record_fail "vLLM /v1/models endpoint" "HTTP ${http_code} (expected 200)"
        return 1
    fi

    # Verify it's valid JSON with a 'data' field containing models
    # Use python3 if available, fall back to grep-based validation
    local is_valid_json="false"
    local model_count="0"

    if command -v python3 > /dev/null 2>&1; then
        model_count=$(echo "${response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    print(len(models))
except Exception:
    print(-1)
" 2>/dev/null || echo "-1")

        if [ "${model_count}" -ge 0 ]; then
            is_valid_json="true"
        fi
    else
        # Fallback: grep-based validation (no python3)
        if echo "${response}" | grep -q '"data"'; then
            is_valid_json="true"
            # Rough count of model objects
            model_count=$(echo "${response}" | grep -o '"id"' | wc -l | tr -d '[:space:]')
        fi
    fi

    if [ "${is_valid_json}" != "true" ]; then
        record_fail "vLLM /v1/models response" "Response is not valid JSON"
        return 1
    fi

    if [ "${model_count}" -le 0 ]; then
        record_fail "vLLM /v1/models response" "No models listed in response"
        return 1
    fi

    record_pass "vLLM /v1/models endpoint" "HTTP 200 — ${model_count} model(s) available"

    # Check if expected model is listed
    if echo "${response}" | grep -q "${MODEL_NAME}"; then
        record_pass "vLLM model loaded" "'${MODEL_NAME}' found in /v1/models"
    else
        # Try to extract what models are available
        local models_listed
        if command -v python3 > /dev/null 2>&1; then
            models_listed=$(echo "${response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = [m.get('id','?') for m in data.get('data',[])]
    print(', '.join(models) if models else 'none')
except Exception: print('parse-error')
" 2>/dev/null || echo "unknown")
        else
            models_listed=$(echo "${response}" | grep -oP '"id"\s*:\s*"\K[^"]+' | paste -sd ',' || echo "unknown")
        fi
        record_warn "vLLM model loaded" "'${MODEL_NAME}' not found; available: ${models_listed}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Check: vLLM /v1/chat/completions — end-to-end inference test
# ---------------------------------------------------------------------------
check_vllm_chat_completions() {
    info "Checking vLLM /v1/chat/completions (inference test) ..."

    local payload
    payload=$(cat <<'PAYLOAD_EOF'
{
  "model": "MODEL_PLACEHOLDER",
  "messages": [{"role": "user", "content": "Say hello in one word."}],
  "max_tokens": 16,
  "temperature": 0
}
PAYLOAD_EOF
)
    # Replace model placeholder
    payload="${payload//MODEL_PLACEHOLDER/${MODEL_NAME}}"

    local http_code
    local response_body
    local tmpfile
    tmpfile=$(mktemp)

    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time 30 \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${VLLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    response_body=$(cat "${tmpfile}" 2>/dev/null || echo "")
    rm -f "${tmpfile}"

    if [ "${http_code}" = "200" ]; then
        # Validate the response has expected structure
        local has_choices
        has_choices=$(echo "${response_body}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    choices = data.get('choices', [])
    if choices and choices[0].get('message', {}).get('content'):
        print('yes')
    else:
        print('no')
except: print('error')
" 2>/dev/null || echo "error")

        if [ "${has_choices}" = "yes" ]; then
            record_pass "vLLM chat completions" "Inference working — HTTP 200 with valid response"
        else
            record_warn "vLLM chat completions" "HTTP 200 but response structure unexpected"
        fi
        return 0
    else
        record_fail "vLLM chat completions" "HTTP ${http_code} at ${VLLM_BASE_URL}/v1/chat/completions"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Check: Network exists
# ---------------------------------------------------------------------------
check_network() {
    info "Checking container network ..."
    if "${RUNTIME}" network inspect "${NETWORK_NAME}" > /dev/null 2>&1; then
        record_pass "Container network" "'${NETWORK_NAME}' exists"
    else
        record_fail "Container network" "'${NETWORK_NAME}' not found"
    fi
}

# ---------------------------------------------------------------------------
# Check: OpenClaw dashboard — verifies HTTP status AND content on port 18789
# ---------------------------------------------------------------------------
check_openclaw_dashboard() {
    info "Checking OpenClaw dashboard on port ${OPENCLAW_HOST_PORT} ..."

    local tmpfile
    tmpfile=$(mktemp)

    local http_code
    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time "${CURL_TIMEOUT}" \
        "${OPENCLAW_URL}/" 2>/dev/null || echo "000")

    # Check 1: HTTP status code — dashboard must be reachable
    if [ "${http_code}" = "000" ]; then
        record_fail "OpenClaw dashboard reachable" "No response at ${OPENCLAW_URL} (port ${OPENCLAW_HOST_PORT})"
        rm -f "${tmpfile}"
        return 1
    fi

    if ! { [ "${http_code}" -ge 200 ] && [ "${http_code}" -lt 400 ]; } 2>/dev/null; then
        record_fail "OpenClaw dashboard reachable" "HTTP ${http_code} (expected 2xx/3xx) at ${OPENCLAW_URL}"
        rm -f "${tmpfile}"
        return 1
    fi

    record_pass "OpenClaw dashboard reachable" "HTTP ${http_code} at ${OPENCLAW_URL}"

    # Check 2: Response body is non-empty
    local body_size
    body_size=$(wc -c < "${tmpfile}" 2>/dev/null || echo "0")
    body_size="${body_size// /}"  # trim whitespace from wc output

    if [ "${body_size}" -eq 0 ] 2>/dev/null; then
        record_fail "OpenClaw dashboard content" "Response body is empty"
        rm -f "${tmpfile}"
        return 1
    fi

    # Check 3: Response contains HTML content (dashboard actually loads)
    if grep -qi -e '<!doctype' -e '<html' -e '<head' -e '<body' -e '<div' "${tmpfile}" 2>/dev/null; then
        record_pass "OpenClaw dashboard content" "HTML content verified (${body_size} bytes)"
    else
        # Non-HTML but valid response — might be a JSON SPA loader; still acceptable
        record_pass "OpenClaw dashboard content" "Non-empty response (${body_size} bytes)"
    fi

    rm -f "${tmpfile}"
    return 0
}

# ---------------------------------------------------------------------------
# Check: OpenClaw dashboard with retry — waits for the dashboard to become
# available, useful when called right after container start
# ---------------------------------------------------------------------------
check_openclaw_dashboard_with_retry() {
    local max_retries="${OPENCLAW_HEALTH_RETRIES:-10}"
    local retry_interval="${OPENCLAW_HEALTH_INTERVAL:-3}"
    local attempt=0

    info "Waiting for OpenClaw dashboard at ${OPENCLAW_URL} (max ${max_retries} attempts) ..."

    while [ "${attempt}" -lt "${max_retries}" ]; do
        local http_code
        http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
            --max-time "${CURL_TIMEOUT}" \
            "${OPENCLAW_URL}/" 2>/dev/null || echo "000")

        if { [ "${http_code}" -ge 200 ] && [ "${http_code}" -lt 400 ]; } 2>/dev/null; then
            # Dashboard is up — run the full content check
            check_openclaw_dashboard
            return $?
        fi

        attempt=$((attempt + 1))
        if [ "${attempt}" -lt "${max_retries}" ]; then
            sleep "${retry_interval}"
        fi
    done

    # Exhausted retries — run the check once more to record the failure
    check_openclaw_dashboard
    return $?
}

# =============================================================================
# Main
# =============================================================================
if [ "${JSON_OUTPUT}" = false ]; then
    echo ""
    echo "======================================"
    echo "  DemoClaw Health Check"
    echo "======================================"
    echo ""
fi

# 1. Container runtime
if ! check_runtime; then
    # Can't proceed without a runtime
    if [ "${JSON_OUTPUT}" = true ]; then
        echo "{\"status\":\"fail\",\"checks_total\":${CHECKS_TOTAL},\"checks_passed\":${CHECKS_PASSED},\"checks_failed\":${CHECKS_FAILED},\"checks_warned\":${CHECKS_WARNED},\"results\":[$(IFS=,; echo "${JSON_RESULTS[*]}")]}"
    fi
    exit 1
fi

# 2. Network
check_network || true

# 3. vLLM container
info "Checking vLLM service ..."
VLLM_CONTAINER_OK=true
if ! check_container_running "${VLLM_CONTAINER_NAME}" "vLLM"; then
    VLLM_CONTAINER_OK=false
fi

if [ "${VLLM_CONTAINER_OK}" = true ]; then
    check_container_health "${VLLM_CONTAINER_NAME}" "vLLM" || true
fi

# 4. vLLM API endpoints (check even if container check failed — might be external)
VLLM_HEALTHY=0
check_vllm_health_endpoint || VLLM_HEALTHY=$?

if [ "${VLLM_HEALTHY}" -eq 0 ]; then
    check_vllm_models_endpoint || true
    check_vllm_chat_completions || true
fi

# 5. OpenClaw (unless --vllm-only)
if [ "${VLLM_ONLY}" = false ]; then
    info "Checking OpenClaw service ..."
    OPENCLAW_CONTAINER_OK=true
    if ! check_container_running "${OPENCLAW_CONTAINER_NAME}" "OpenClaw"; then
        OPENCLAW_CONTAINER_OK=false
    fi
    if [ "${OPENCLAW_CONTAINER_OK}" = true ]; then
        check_container_health "${OPENCLAW_CONTAINER_NAME}" "OpenClaw" || true
    fi
    check_openclaw_dashboard || true
fi

# =============================================================================
# Summary
# =============================================================================
if [ "${JSON_OUTPUT}" = true ]; then
    overall="pass"
    if [ "${CHECKS_FAILED}" -gt 0 ]; then
        overall="fail"
    elif [ "${CHECKS_WARNED}" -gt 0 ]; then
        overall="warn"
    fi
    echo "{\"status\":\"${overall}\",\"checks_total\":${CHECKS_TOTAL},\"checks_passed\":${CHECKS_PASSED},\"checks_failed\":${CHECKS_FAILED},\"checks_warned\":${CHECKS_WARNED},\"results\":[$(IFS=,; echo "${JSON_RESULTS[*]}")]}"
else
    echo ""
    echo "--------------------------------------"
    echo "  Results: ${CHECKS_PASSED} passed, ${CHECKS_FAILED} failed, ${CHECKS_WARNED} warnings (${CHECKS_TOTAL} total)"
    echo "--------------------------------------"

    if [ "${CHECKS_FAILED}" -gt 0 ]; then
        echo -e "  ${RED}Overall: UNHEALTHY${NC}"
        echo ""
        exit 1
    elif [ "${CHECKS_WARNED}" -gt 0 ]; then
        echo -e "  ${YELLOW}Overall: DEGRADED${NC}"
        echo ""
        exit 0
    else
        echo -e "  ${GREEN}Overall: HEALTHY${NC}"
        echo ""
        exit 0
    fi
fi

if [ "${CHECKS_FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
