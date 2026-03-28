#!/usr/bin/env bash
# =============================================================================
# validate_connection.sh — Confirm the vLLM provider connection is live from
#                          within or alongside the OpenClaw container.
#
# PURPOSE
# -------
# This script is the "provider connection gate" that must pass before
# OpenClaw starts accepting user requests.  It queries the vLLM
# OpenAI-compatible /v1/models endpoint to confirm:
#
#   • The vLLM server is reachable at the configured URL
#   • The /v1/models endpoint returns a valid JSON response
#   • At least one model is loaded and ready to serve requests
#   • (Optional) The expected model (Qwen/Qwen3-4B-AWQ) is present
#
# HOW IT CAN BE INVOKED
# ----------------------
# The script supports three execution contexts, selectable via flags:
#
#   1. Inside the OpenClaw container (default, no flag needed)
#      Uses VLLM_BASE_URL which defaults to http://vllm:8000/v1 — the
#      internal container-network URL that only resolves within democlaw-net.
#      Run via docker/podman exec:
#        docker exec democlaw-openclaw /scripts/validate_connection.sh
#        podman exec democlaw-openclaw /scripts/validate_connection.sh
#
#   2. --exec flag: Delegates to the OpenClaw container via docker/podman exec
#      The host-side script invokes curl from inside the OpenClaw container
#      so the validation uses the exact same network path OpenClaw would use.
#        ./scripts/validate_connection.sh --exec
#        CONTAINER_RUNTIME=podman ./scripts/validate_connection.sh --exec
#
#   3. --host flag: Validates via the host-published port (localhost)
#      Uses http://localhost:${VLLM_HOST_PORT}/v1 instead of the internal
#      container-network URL. Useful for quick host-side spot checks.
#        ./scripts/validate_connection.sh --host
#        VLLM_HOST_PORT=8001 ./scripts/validate_connection.sh --host
#
# EXIT CODES
# ----------
#   0 — Connection live: /v1/models responded and at least one model is loaded
#   1 — Connection failed: server unreachable, no models loaded, or timeout
#
# ENVIRONMENT VARIABLES (all have sensible defaults)
# ---------------------------------------------------
#   VLLM_BASE_URL          Full base URL for the vLLM API
#                          default: http://vllm:8000/v1    (container-network URL)
#   VLLM_HOST_PORT         Host port for vLLM (used with --host flag)
#                          default: 8000
#   MODEL_NAME             Expected model to verify is loaded
#                          default: Qwen/Qwen3-4B-AWQ
#   VALIDATE_RETRIES       Number of retry attempts before giving up
#                          default: 12
#   VALIDATE_INTERVAL      Seconds to wait between retries
#                          default: 5
#   VALIDATE_TIMEOUT       Per-request curl timeout in seconds
#                          default: 10
#   CONTAINER_RUNTIME      docker | podman (auto-detected if unset)
#   OPENCLAW_CONTAINER_NAME  OpenClaw container name for --exec mode
#                          default: democlaw-openclaw
#
# USAGE
# -----
#   # Check from inside / via exec into the OpenClaw container (default):
#   ./scripts/validate_connection.sh
#
#   # Delegate the curl call to the running OpenClaw container:
#   ./scripts/validate_connection.sh --exec
#
#   # Check via the host-published port (localhost):
#   ./scripts/validate_connection.sh --host
#
#   # Silent mode — only print on failure (for use in CI / entrypoint scripts):
#   ./scripts/validate_connection.sh --quiet
#
#   # Override URL directly:
#   VLLM_BASE_URL=http://192.168.1.20:8000/v1 ./scripts/validate_connection.sh
#
#   # Force podman as the container runtime (--exec mode):
#   CONTAINER_RUNTIME=podman ./scripts/validate_connection.sh --exec
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Locate project root and scripts directory
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Parse CLI flags
# ---------------------------------------------------------------------------
MODE="default"      # default | exec | host
QUIET=false

for arg in "$@"; do
    case "${arg}" in
        --exec)   MODE="exec"  ;;
        --host)   MODE="host"  ;;
        --quiet)  QUIET=true   ;;
        --help|-h)
            sed -n '/^# =/,/^# =/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option '${arg}'." >&2
            echo "       Use --help for usage information." >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Load .env file if present (key=value lines; no export needed here)
# Must happen BEFORE variable defaults so .env values take precedence.
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

# ---------------------------------------------------------------------------
# Configurable defaults
# ---------------------------------------------------------------------------
# Internal container-network URL — used when running inside or via exec into
# the OpenClaw container. The hostname "vllm" resolves within democlaw-net.
VLLM_BASE_URL="${VLLM_BASE_URL:-http://vllm:8000/v1}"

# Host-published port — used with --host flag for localhost access
VLLM_HOST_PORT="${VLLM_HOST_PORT:-8000}"

# Expected model name
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-4B-AWQ}"

# Retry configuration
VALIDATE_RETRIES="${VALIDATE_RETRIES:-12}"
VALIDATE_INTERVAL="${VALIDATE_INTERVAL:-5}"
VALIDATE_TIMEOUT="${VALIDATE_TIMEOUT:-10}"

# Container names (used in --exec mode)
OPENCLAW_CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-democlaw-openclaw}"

# ---------------------------------------------------------------------------
# Resolve the effective URL based on the selected mode
# ---------------------------------------------------------------------------
if [ "${MODE}" = "host" ]; then
    # --host: Override to use the localhost-published port
    VLLM_BASE_URL="http://localhost:${VLLM_HOST_PORT}/v1"
fi

MODELS_URL="${VLLM_BASE_URL}/models"
# Strip /v1 suffix (if present) to build the health URL for diagnostics
VLLM_SERVER_ROOT="${VLLM_BASE_URL%/v1}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Disable colours when not attached to a terminal
if [ ! -t 1 ]; then
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

log()    {
    [ "${QUIET}" = true ] && return 0
    echo -e "${CYAN}[validate_connection]${NC} $*"
}
success(){
    echo -e "${GREEN}[validate_connection]${NC} $*"
}
warn_()  {
    echo -e "${YELLOW}[validate_connection] WARNING:${NC} $*" >&2
}
fail()   {
    echo -e "${RED}[validate_connection] ERROR:${NC} $*" >&2
}

# ---------------------------------------------------------------------------
# Require curl (the only runtime dependency for the default/host modes)
# ---------------------------------------------------------------------------
if ! command -v curl > /dev/null 2>&1; then
    fail "'curl' is required but not found in PATH."
    fail "Install it with: apt-get install -y curl  (or yum install curl)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Print banner
# ---------------------------------------------------------------------------
if [ "${QUIET}" = false ]; then
    echo ""
    echo "======================================================="
    echo -e "  ${BOLD}vLLM Provider Connection Validation${NC}"
    echo "======================================================="
    echo "  Mode          : ${MODE}"
    echo "  Models URL    : ${MODELS_URL}"
    echo "  Expected model: ${MODEL_NAME}"
    echo "  Retries       : ${VALIDATE_RETRIES} x ${VALIDATE_INTERVAL}s interval"
    echo "======================================================="
    echo ""
fi

# ===========================================================================
# --exec mode: Delegate curl to inside the running OpenClaw container
#
# This exercises the exact same network path that OpenClaw itself would use.
# The internal container-network URL (http://vllm:8000/v1) only resolves
# within the shared container network, so running curl from inside the
# OpenClaw container is the most accurate reachability test.
# ===========================================================================
if [ "${MODE}" = "exec" ]; then
    # Detect container runtime for exec
    RUNTIME="${CONTAINER_RUNTIME:-}"
    if [ -z "${RUNTIME}" ]; then
        for _candidate in docker podman; do
            if command -v "${_candidate}" > /dev/null 2>&1; then
                RUNTIME="${_candidate}"
                break
            fi
        done
    fi

    if [ -z "${RUNTIME}" ]; then
        fail "No container runtime found. Install docker or podman and ensure it is in PATH."
        fail "Alternatively, run without --exec to test directly from the host."
        exit 1
    fi

    log "Container runtime: ${RUNTIME}"

    # Verify the OpenClaw container is running
    if ! "${RUNTIME}" container inspect "${OPENCLAW_CONTAINER_NAME}" > /dev/null 2>&1; then
        fail "OpenClaw container '${OPENCLAW_CONTAINER_NAME}' does not exist."
        fail "Start it first with: ./scripts/start-openclaw.sh"
        exit 1
    fi

    container_state=$("${RUNTIME}" container inspect \
        --format '{{.State.Status}}' "${OPENCLAW_CONTAINER_NAME}" 2>/dev/null \
        || echo "unknown")

    if [ "${container_state}" != "running" ]; then
        fail "OpenClaw container '${OPENCLAW_CONTAINER_NAME}' is not running (state: ${container_state})."
        fail "Start it first with: ./scripts/start-openclaw.sh"
        exit 1
    fi

    log "OpenClaw container '${OPENCLAW_CONTAINER_NAME}' is running."
    log "Delegating connection check to inside the container ..."
    log "  Testing: ${MODELS_URL}"
    echo ""

    # Run curl from inside the OpenClaw container.
    # The internal URL (http://vllm:8000/v1) resolves within democlaw-net.
    # We pass the configuration via environment so the exec'd command is
    # self-contained and does not depend on the host .env file.
    exec_exit=0
    "${RUNTIME}" exec \
        -e "VLLM_BASE_URL=${VLLM_BASE_URL}" \
        -e "MODEL_NAME=${MODEL_NAME}" \
        -e "VALIDATE_RETRIES=${VALIDATE_RETRIES}" \
        -e "VALIDATE_INTERVAL=${VALIDATE_INTERVAL}" \
        -e "VALIDATE_TIMEOUT=${VALIDATE_TIMEOUT}" \
        "${OPENCLAW_CONTAINER_NAME}" \
        bash -c "
set -euo pipefail
MODELS_URL=\"\${VLLM_BASE_URL}/models\"
retries=0
while [ \"\${retries}\" -lt \"\${VALIDATE_RETRIES}\" ]; do
    response=\$(curl -sf --max-time \"\${VALIDATE_TIMEOUT}\" \
        -H 'Accept: application/json' \
        \"\${MODELS_URL}\" 2>/dev/null || echo '')

    if [ -n \"\${response}\" ]; then
        # Validate JSON structure and model count
        if command -v python3 > /dev/null 2>&1; then
            result=\$(echo \"\${response}\" | python3 -c \"
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    ids = [m.get('id', '') for m in models]
    if ids:
        print('ok:' + ','.join(ids))
    else:
        print('empty')
except Exception as e:
    print('error:' + str(e))
\" 2>/dev/null || echo 'error:parse failed')
        else
            # Fallback: grep-based check
            if echo \"\${response}\" | grep -q '\"data\"' && echo \"\${response}\" | grep -q '\"id\"'; then
                result='ok:unknown'
            else
                result='empty'
            fi
        fi

        case \"\${result}\" in
            ok:*)
                models_found=\"\${result#ok:}\"
                echo \"[exec-check] PASS: /v1/models responded — models: \${models_found}\"
                if echo \"\${models_found}\" | grep -qF \"\${MODEL_NAME}\"; then
                    echo \"[exec-check] PASS: Expected model '\${MODEL_NAME}' is loaded\"
                else
                    echo \"[exec-check] WARN: '\${MODEL_NAME}' not in model list: \${models_found}\" >&2
                fi
                exit 0
                ;;
            empty)
                echo \"[exec-check] /v1/models returned no models yet (attempt \$((retries+1))/\${VALIDATE_RETRIES})\" >&2
                ;;
            error:*)
                echo \"[exec-check] Response parse error: \${result#error:}\" >&2
                ;;
        esac
    else
        echo \"[exec-check] No response from \${MODELS_URL} (attempt \$((retries+1))/\${VALIDATE_RETRIES})\" >&2
    fi

    retries=\$((retries + 1))
    if [ \"\${retries}\" -lt \"\${VALIDATE_RETRIES}\" ]; then
        sleep \"\${VALIDATE_INTERVAL}\"
    fi
done

echo \"[exec-check] FAIL: vLLM provider unreachable at \${MODELS_URL} after \${VALIDATE_RETRIES} attempts\" >&2
echo \"[exec-check] The OpenClaw container cannot reach the vLLM server.\" >&2
echo \"[exec-check] Ensure the vLLM container is running on network '\${VLLM_BASE_URL%/v1}'.\" >&2
exit 1
" || exec_exit=$?

    if [ "${exec_exit}" -eq 0 ]; then
        echo ""
        success "Provider connection confirmed from inside '${OPENCLAW_CONTAINER_NAME}'."
        success "OpenClaw can reach vLLM at: ${VLLM_BASE_URL}"
        echo ""
    else
        echo ""
        fail "Provider connection FAILED from inside '${OPENCLAW_CONTAINER_NAME}'."
        fail "OpenClaw cannot reach the vLLM server at: ${VLLM_BASE_URL}"
        echo "" >&2
        fail "Troubleshooting steps:" >&2
        fail "  1. Verify vLLM is running   : ${RUNTIME} ps --filter name=${OPENCLAW_CONTAINER_NAME/openclaw/vllm}" >&2
        fail "  2. Check vLLM logs          : ${RUNTIME} logs democlaw-vllm" >&2
        fail "  3. Check network membership : ${RUNTIME} inspect democlaw-vllm | grep -A5 Networks" >&2
        fail "  4. Restart vLLM             : ./scripts/start-vllm.sh" >&2
        echo "" >&2
    fi

    exit "${exec_exit}"
fi

# ===========================================================================
# default / host modes: Query the /v1/models endpoint directly via curl
#
# "default" uses VLLM_BASE_URL (http://vllm:8000/v1) — works when this
# script itself runs inside the container network, or when VLLM_BASE_URL
# is overridden to a reachable URL.
#
# "host" uses http://localhost:<VLLM_HOST_PORT>/v1 — host-side check via
# the published port.
# ===========================================================================

log "Querying vLLM /v1/models endpoint ..."
log "  URL: ${MODELS_URL}"
echo ""

attempt=0
while [ "${attempt}" -lt "${VALIDATE_RETRIES}" ]; do
    attempt=$((attempt + 1))

    # -----------------------------------------------------------------------
    # Query /v1/models — capture both the HTTP status code and the body
    # -----------------------------------------------------------------------
    tmpfile=$(mktemp)

    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time "${VALIDATE_TIMEOUT}" \
        -H "Accept: application/json" \
        "${MODELS_URL}" 2>/dev/null || echo "000")

    response=$(cat "${tmpfile}" 2>/dev/null || echo "")
    rm -f "${tmpfile}"

    # -----------------------------------------------------------------------
    # Case 1: No response (connection refused / DNS failure / timeout)
    # -----------------------------------------------------------------------
    if [ "${http_code}" = "000" ] || [ -z "${response}" ]; then
        if [ "${attempt}" -lt "${VALIDATE_RETRIES}" ]; then
            log "Attempt ${attempt}/${VALIDATE_RETRIES}: No response from ${MODELS_URL} — retrying in ${VALIDATE_INTERVAL}s ..."
            sleep "${VALIDATE_INTERVAL}"
            continue
        fi
        # Final attempt failed
        echo ""
        fail "FAIL: vLLM server unreachable at ${MODELS_URL}"
        fail "      (${VALIDATE_RETRIES} attempts x ${VALIDATE_INTERVAL}s = $((VALIDATE_RETRIES * VALIDATE_INTERVAL))s elapsed)"
        echo "" >&2
        fail "Possible causes:" >&2
        fail "  • vLLM container is not running" >&2
        fail "  • vLLM container is not on the same container network" >&2
        fail "  • The model is still loading (check logs: docker logs democlaw-vllm)" >&2
        fail "  • Wrong URL — current: ${MODELS_URL}" >&2
        echo "" >&2
        fail "Quick checks:" >&2
        fail "  curl ${VLLM_SERVER_ROOT}/health" >&2
        fail "  curl ${MODELS_URL}" >&2
        exit 1
    fi

    # -----------------------------------------------------------------------
    # Case 2: Non-200 HTTP response
    # -----------------------------------------------------------------------
    if [ "${http_code}" != "200" ]; then
        if [ "${attempt}" -lt "${VALIDATE_RETRIES}" ]; then
            log "Attempt ${attempt}/${VALIDATE_RETRIES}: HTTP ${http_code} from ${MODELS_URL} — retrying in ${VALIDATE_INTERVAL}s ..."
            sleep "${VALIDATE_INTERVAL}"
            continue
        fi
        echo ""
        fail "FAIL: /v1/models returned HTTP ${http_code} (expected 200)"
        fail "      URL: ${MODELS_URL}"
        exit 1
    fi

    # -----------------------------------------------------------------------
    # Case 3: HTTP 200 — validate JSON structure and extract model list
    # -----------------------------------------------------------------------
    if command -v python3 > /dev/null 2>&1; then
        parse_result=$(echo "${response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    assert isinstance(data, dict),            'response is not a JSON object'
    assert data.get('object') == 'list',      'object field is not \"list\"'
    models = data.get('data', [])
    assert isinstance(models, list),          'data field is not an array'
    ids = [m.get('id', '?') for m in models]
    if ids:
        print('ok:' + '|'.join(ids))
    else:
        print('empty')
except AssertionError as e:
    print('invalid:' + str(e))
except Exception as e:
    print('invalid:parse error: ' + str(e))
" 2>/dev/null || echo "invalid:python3 failed")
    else
        # Fallback: grep-based validation when python3 is unavailable
        if echo "${response}" | grep -q '"object"' \
           && echo "${response}" | grep -q '"data"' \
           && echo "${response}" | grep -q '"id"'; then
            model_ids=$(echo "${response}" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
                        | sed 's/"id"[[:space:]]*:[[:space:]]*"\(.*\)"/\1/' \
                        | paste -sd '|' || echo "unknown")
            parse_result="ok:${model_ids}"
        else
            parse_result="invalid:response missing expected JSON fields (object, data, id)"
        fi
    fi

    # -----------------------------------------------------------------------
    # Evaluate parse result
    # -----------------------------------------------------------------------
    case "${parse_result}" in

        # ---- /v1/models returned an empty model list ----------------------
        empty)
            if [ "${attempt}" -lt "${VALIDATE_RETRIES}" ]; then
                log "Attempt ${attempt}/${VALIDATE_RETRIES}: HTTP 200 but no models loaded yet — retrying in ${VALIDATE_INTERVAL}s ..."
                sleep "${VALIDATE_INTERVAL}"
                continue
            fi
            echo ""
            fail "FAIL: /v1/models responded with an empty model list."
            fail "      The vLLM server is running but no model has finished loading."
            fail "      This may take several minutes on first start."
            echo "" >&2
            fail "Monitor loading progress:" >&2
            fail "  docker logs -f democlaw-vllm" >&2
            fail "  curl ${MODELS_URL}" >&2
            exit 1
            ;;

        # ---- /v1/models returned an invalid JSON response -----------------
        invalid:*)
            reason="${parse_result#invalid:}"
            if [ "${attempt}" -lt "${VALIDATE_RETRIES}" ]; then
                log "Attempt ${attempt}/${VALIDATE_RETRIES}: Invalid response (${reason}) — retrying in ${VALIDATE_INTERVAL}s ..."
                sleep "${VALIDATE_INTERVAL}"
                continue
            fi
            echo ""
            fail "FAIL: /v1/models returned an unexpected response."
            fail "      Reason  : ${reason}"
            fail "      Raw body: $(echo "${response}" | head -c 200)"
            exit 1
            ;;

        # ---- SUCCESS: at least one model is loaded ------------------------
        ok:*)
            model_ids_raw="${parse_result#ok:}"
            # Convert pipe-separated IDs for display
            model_ids_display="${model_ids_raw//|/, }"

            echo ""
            success "PASS: vLLM provider connection is LIVE"
            echo ""
            echo -e "  ${GREEN}✓${NC} Endpoint  : ${MODELS_URL}"
            echo -e "  ${GREEN}✓${NC} HTTP code : 200"
            echo -e "  ${GREEN}✓${NC} Models    : ${model_ids_display}"

            # Check if the expected model is in the list
            if echo "${model_ids_raw}" | grep -qF "${MODEL_NAME}"; then
                echo -e "  ${GREEN}✓${NC} Expected  : '${MODEL_NAME}' is loaded and ready"
            else
                echo -e "  ${YELLOW}⚠${NC}  Expected  : '${MODEL_NAME}' NOT in model list"
                echo -e "  ${YELLOW}⚠${NC}  Available : ${model_ids_display}"
                warn_ "The expected model '${MODEL_NAME}' was not found in the /v1/models response."
                warn_ "OpenClaw will start but may receive errors if the model name is mismatched."
                warn_ "Set MODEL_NAME or VLLM_MODEL_NAME to one of: ${model_ids_display}"
            fi

            echo ""
            success "OpenClaw can use the vLLM provider at: ${VLLM_BASE_URL}"
            echo ""
            exit 0
            ;;

    esac
done

# Should not be reached — all paths inside the loop exit explicitly
fail "Unexpected state: validation loop exhausted without result."
exit 1
