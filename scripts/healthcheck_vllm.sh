#!/usr/bin/env bash
# =============================================================================
# healthcheck_vllm.sh — Smoke-test/poll until the vLLM model is fully loaded
#
# Repeatedly polls the vLLM /v1/models endpoint until the expected model
# (MODEL_NAME) is listed in the response — indicating that model weights are
# fully loaded into GPU memory and the server is ready to serve inference
# requests.  Exits 0 only when the model is confirmed ready.
# Exits 1 if the timeout is exceeded before the model becomes available.
#
# WHY /v1/models INSTEAD OF /health?
#   /health responds HTTP 200 as soon as the vLLM HTTP server starts, but
#   model weights may still be loading.  /v1/models only returns a non-empty
#   "data" array after the model is fully initialised.  This script therefore
#   polls /v1/models and checks that the specific MODEL_NAME is present before
#   declaring readiness.
#
# Configurable via environment variables (or a .env file in the project root):
#
#   VLLM_HOST_PORT              Port the vLLM server is published on the host.
#                               Default: 8000
#
#   VLLM_BASE_URL               Full base URL override (e.g. http://host:8001).
#                               Default: http://localhost:<VLLM_HOST_PORT>
#
#   MODEL_NAME                  Model ID that MUST appear in the /v1/models
#                               response before this script exits 0.
#                               When set (default), exit 0 only when this exact
#                               model ID is listed.  Set to empty ("") to
#                               accept any model.
#                               Default: Qwen/Qwen3-4B-AWQ
#
#   VLLM_HEALTH_TIMEOUT         Maximum total seconds to wait before giving up.
#                               Default: 600  (model loading can take minutes)
#
#   VLLM_HEALTH_INTERVAL        Seconds between polling attempts.
#                               Default: 5
#
#   VLLM_HEALTH_CURL_TIMEOUT    Per-request curl timeout in seconds.
#                               Default: 10
#
# Exit codes:
#   0 — /v1/models confirmed the expected model is loaded and ready
#   1 — Timeout exceeded; model did not become ready within VLLM_HEALTH_TIMEOUT
#   2 — Prerequisite missing (curl not found in PATH)
#
# Usage:
#   ./scripts/healthcheck_vllm.sh
#   VLLM_HOST_PORT=8001 ./scripts/healthcheck_vllm.sh
#   MODEL_NAME=Qwen/Qwen3-4B-AWQ VLLM_HEALTH_TIMEOUT=900 ./scripts/healthcheck_vllm.sh
#   MODEL_NAME="" ./scripts/healthcheck_vllm.sh   # accept any loaded model
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Load .env file if present (honours user overrides in the project root)
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

# ---------------------------------------------------------------------------
# Configurable defaults (all overridable via environment or .env)
# ---------------------------------------------------------------------------
VLLM_HOST_PORT="${VLLM_HOST_PORT:-8000}"
VLLM_BASE_URL="${VLLM_BASE_URL:-http://localhost:${VLLM_HOST_PORT}}"
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-4B-AWQ}"

# Model loading on an 8 GB GPU can take 3-8 minutes; default to 10 minutes.
VLLM_HEALTH_TIMEOUT="${VLLM_HEALTH_TIMEOUT:-600}"
VLLM_HEALTH_INTERVAL="${VLLM_HEALTH_INTERVAL:-5}"
VLLM_HEALTH_CURL_TIMEOUT="${VLLM_HEALTH_CURL_TIMEOUT:-10}"

MODELS_URL="${VLLM_BASE_URL}/v1/models"
HEALTH_URL="${VLLM_BASE_URL}/health"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log()   { echo "[healthcheck-vllm] $*"; }
warn()  { echo "[healthcheck-vllm] WARNING: $*" >&2; }
error() { echo "[healthcheck-vllm] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Prerequisite check: curl must be available
# ---------------------------------------------------------------------------
if ! command -v curl > /dev/null 2>&1; then
    error "curl is required but not found in PATH. Install curl and retry."
    exit 2
fi

# ---------------------------------------------------------------------------
# Helper: query /v1/models and return status
#
# Returns one of:
#   "ok:<count>:<models>"  — HTTP 200 with <count> models listed
#   "empty"                — HTTP 200 but data[] is empty (model still loading)
#   "http:<code>"          — Non-200 HTTP response
#   "error"                — Connection error or invalid JSON
# ---------------------------------------------------------------------------
query_models() {
    local tmpfile
    tmpfile=$(mktemp)

    local http_code
    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time "${VLLM_HEALTH_CURL_TIMEOUT}" \
        -H "Accept: application/json" \
        "${MODELS_URL}" 2>/dev/null || echo "000")

    local response
    response=$(cat "${tmpfile}" 2>/dev/null || echo "")
    rm -f "${tmpfile}"

    if [ "${http_code}" = "000" ] || [ -z "${response}" ]; then
        echo "error"
        return
    fi

    if [ "${http_code}" != "200" ]; then
        echo "http:${http_code}"
        return
    fi

    # Parse JSON: extract model count and IDs
    if command -v python3 > /dev/null 2>&1; then
        local parsed
        parsed=$(echo "${response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    ids = [m.get('id', '') for m in models if isinstance(m, dict)]
    if ids:
        print('ok:' + str(len(ids)) + ':' + ','.join(ids))
    else:
        print('empty')
except Exception:
    print('error')
" 2>/dev/null || echo "error")
        echo "${parsed}"
    else
        # Fallback: grep/sed-based extraction when python3 is unavailable.
        # Extract model IDs using grep extended regex (POSIX-compatible).
        if echo "${response}" | grep -q '"data"' && echo "${response}" | grep -q '"id"'; then
            local ids count
            # Extract all values from "id":"<value>" fields in the JSON
            ids=$(echo "${response}" \
                | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
                | sed 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
                | paste -sd ',' 2>/dev/null || echo "")
            count=$(echo "${response}" | grep -o '"id"' | wc -l | tr -d '[:space:]')
            if [ -n "${ids}" ]; then
                echo "ok:${count}:${ids}"
            else
                echo "ok:${count}:unknown"
            fi
        else
            echo "empty"
        fi
    fi
}

# ---------------------------------------------------------------------------
# check_model_ready
#
# Combines query_models output with MODEL_NAME validation.
# Returns 0 only when the endpoint is up AND the expected model is listed.
# ---------------------------------------------------------------------------
check_model_ready() {
    local result
    result=$(query_models)

    case "${result}" in
        ok:*)
            local count models
            count=$(echo "${result}" | cut -d: -f2)
            models=$(echo "${result}" | cut -d: -f3-)

            # If MODEL_NAME is set, the exact model ID must be present.
            # This is the critical readiness gate: the model must be fully
            # loaded into GPU memory, not just the HTTP server started.
            if [ -n "${MODEL_NAME:-}" ]; then
                # "unknown" is emitted by the grep fallback when python3 is absent
                # and grep-based ID extraction also fails.  In that edge case we
                # cannot confirm the specific model, so accept any loaded model
                # rather than looping forever.
                if [ "${models}" != "unknown" ]; then
                    if ! echo ",${models}," | grep -qF ",${MODEL_NAME},"; then
                        # Model weights not yet registered — keep polling.
                        _LAST_STATUS="models loaded: [${models}] — waiting for '${MODEL_NAME}'"
                        return 1
                    fi
                fi
            fi

            # Ready — store details for success message
            _READY_COUNT="${count}"
            _READY_MODELS="${models}"
            return 0
            ;;
        empty)
            _LAST_STATUS="empty data[] — model weights still loading"
            return 1
            ;;
        http:*)
            _LAST_STATUS="HTTP ${result#http:} from /v1/models"
            return 1
            ;;
        error|*)
            _LAST_STATUS="connection error or parse failure"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Polling vLLM /v1/models for model readiness"
log "  URL              : ${MODELS_URL}"
log "  Expected model   : ${MODEL_NAME:-<any>}"
log "  Timeout          : ${VLLM_HEALTH_TIMEOUT}s"
log "  Interval         : ${VLLM_HEALTH_INTERVAL}s"
log "  Per-request curl : ${VLLM_HEALTH_CURL_TIMEOUT}s"
log ""

elapsed=0
_LAST_STATUS="not started"
_READY_COUNT=""
_READY_MODELS=""

while [ "${elapsed}" -lt "${VLLM_HEALTH_TIMEOUT}" ]; do
    if check_model_ready; then
        log "============================================="
        log "  vLLM model is ready!"
        log "  URL     : ${MODELS_URL}"
        log "  Models  : ${_READY_COUNT} loaded — ${_READY_MODELS}"
        if [ -n "${MODEL_NAME:-}" ]; then
            log "  Confirmed: '${MODEL_NAME}' is loaded and serving"
        fi
        log "============================================="
        log ""
        exit 0
    fi

    remaining=$(( VLLM_HEALTH_TIMEOUT - elapsed ))
    log "  ... not ready (${elapsed}s elapsed, ${remaining}s remaining) — ${_LAST_STATUS}"

    sleep "${VLLM_HEALTH_INTERVAL}"
    elapsed=$(( elapsed + VLLM_HEALTH_INTERVAL ))
done

# ---------------------------------------------------------------------------
# One final attempt right at the timeout boundary
# ---------------------------------------------------------------------------
if check_model_ready; then
    log "============================================="
    log "  vLLM model is ready!"
    log "  URL     : ${MODELS_URL}"
    log "  Models  : ${_READY_COUNT} loaded — ${_READY_MODELS}"
    if [ -n "${MODEL_NAME:-}" ]; then
        log "  Confirmed: '${MODEL_NAME}' is loaded and serving"
    fi
    log "============================================="
    log ""
    exit 0
fi

# ---------------------------------------------------------------------------
# Timeout reached — model did not become ready within VLLM_HEALTH_TIMEOUT
# ---------------------------------------------------------------------------
warn ""
warn "TIMEOUT: vLLM model '${MODEL_NAME:-<any>}' did not become ready within ${VLLM_HEALTH_TIMEOUT}s."
warn "  /v1/models URL  : ${MODELS_URL}"
warn "  /health URL     : ${HEALTH_URL}"
warn "  Last status     : ${_LAST_STATUS}"
warn ""
warn "Possible causes:"
warn "  1. The vLLM container is not running. Start it with:"
warn "       ./scripts/start-vllm.sh"
warn "  2. Model weights are still downloading or loading into GPU memory."
warn "     First-time runs can take several minutes. Increase the timeout:"
warn "       VLLM_HEALTH_TIMEOUT=900 ./scripts/healthcheck_vllm.sh"
warn "  3. Insufficient VRAM. Qwen3-4B-AWQ requires ≥8 GB GPU VRAM."
warn "     Check GPU memory usage: nvidia-smi"
warn "  4. The container crashed or OOM-killed. Check container logs:"
warn "       docker logs democlaw-vllm --tail 50"
warn "       podman logs democlaw-vllm --tail 50"
warn "  5. Port ${VLLM_HOST_PORT} is blocked or bound by another process."
warn "       ss -tlnp | grep ${VLLM_HOST_PORT}"
warn ""
exit 1
