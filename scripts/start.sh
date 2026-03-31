#!/usr/bin/env bash
# =============================================================================
# start.sh -- Full E2E startup for the DemoClaw stack (llama.cpp + MarkItDown + OpenClaw)
#
# This single script handles the entire lifecycle:
#   1. Clean up old containers/network
#   2. Acquire images (pull from Docker Hub first; local build fallback)
#   3. Create network
#   4. Start llama.cpp server, wait for /health + /v1/models
#   5. Start OpenClaw, wait for dashboard
#   6. Print tokenized dashboard URL
#
# Usage:
#   ./scripts/start.sh
# =============================================================================
set -euo pipefail

log()   { echo "[start] $*"; }
error() { echo "[start] ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Load .env file if present (overrides defaults below)
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck source=/dev/null
    set -a; source "${ENV_FILE}"; set +a
    log "Loaded config from ${ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LLAMACPP_IMAGE="${DEMOCLAW_LLAMACPP_IMAGE:-docker.io/jinwangmok/democlaw-llamacpp:v1.1.0}"
OPENCLAW_IMAGE="${DEMOCLAW_OPENCLAW_IMAGE:-docker.io/jinwangmok/democlaw-openclaw:v1.1.0}"
MARKITDOWN_IMAGE="${DEMOCLAW_MARKITDOWN_IMAGE:-docker.io/jinwangmok/democlaw-markitdown:v1.1.0}"
NETWORK="democlaw-net"
LLAMACPP_CONTAINER="democlaw-llamacpp"
OPENCLAW_CONTAINER="democlaw-openclaw"
MARKITDOWN_CONTAINER="democlaw-markitdown"
MODEL_NAME="Qwen3.5-9B-Q4_K_M"
MODEL_REPO="unsloth/Qwen3.5-9B-GGUF"
MODEL_FILE="Qwen3.5-9B-Q4_K_M.gguf"

# llama.cpp tuning for 8GB VRAM
CTX_SIZE="${CTX_SIZE:-32768}"
N_GPU_LAYERS="${N_GPU_LAYERS:-99}"
FLASH_ATTN="${FLASH_ATTN:-1}"
CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"

# Ports
LLAMACPP_PORT="8000"
OPENCLAW_PORT="18789"
MARKITDOWN_PORT="${MARKITDOWN_PORT:-3001}"

# Timeouts (seconds)
LLAMACPP_HEALTH_TIMEOUT=600   # longer: model may need to download on first run
OPENCLAW_HEALTH_TIMEOUT=120

# Model directory (host path mounted into the container)
MODEL_DIR="${MODEL_DIR:-${HOME}/.cache/democlaw/models}"

# ---------------------------------------------------------------------------
# Detect container runtime
# ---------------------------------------------------------------------------
RUNTIME=""
if [ -n "${CONTAINER_RUNTIME:-}" ] && command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1; then
    RUNTIME="${CONTAINER_RUNTIME}"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    error "No container runtime found. Install docker or podman."
fi

GPU_FLAGS="--gpus all"
HOSTNAME_LLM="--hostname llamacpp"
HOSTNAME_OPENCLAW="--hostname openclaw"
SHM_FLAGS="--shm-size 1g"

# Detect if the runtime is actually podman (covers podman-docker aliases)
_is_podman=false
if [ "${RUNTIME}" = "podman" ]; then
    _is_podman=true
elif "${RUNTIME}" --version 2>/dev/null | grep -qi podman; then
    _is_podman=true
fi

if [ "${_is_podman}" = "true" ]; then
    GPU_FLAGS="--device nvidia.com/gpu=all"
    # Podman rootful inherits host UTS/IPC namespaces; --hostname and --shm-size are invalid
    HOSTNAME_LLM=""
    HOSTNAME_OPENCLAW=""
    SHM_FLAGS=""
fi

log "========================================================"
log "  DemoClaw Stack -- Full E2E Startup"
log "========================================================"
log "Runtime: ${RUNTIME}"
log "Engine : llama.cpp (CUDA backend)"
log "Model  : ${MODEL_NAME} (GGUF Q4_K_M)"

# ---------------------------------------------------------------------------
# Validate NVIDIA GPU
# ---------------------------------------------------------------------------
log "Checking NVIDIA GPU ..."
command -v nvidia-smi >/dev/null 2>&1 || error "nvidia-smi not found. Install NVIDIA drivers."
nvidia-smi >/dev/null 2>&1 || error "nvidia-smi failed. Check NVIDIA driver installation."
log "NVIDIA GPU OK."

# ===========================================================================
# Phase 0: Clean up old containers and network
# ===========================================================================
log ""
log "--- Phase 0: Cleanup ---"

for cname in "${OPENCLAW_CONTAINER}" "${MARKITDOWN_CONTAINER}" "${LLAMACPP_CONTAINER}"; do
    if "${RUNTIME}" container inspect "${cname}" >/dev/null 2>&1; then
        log "Removing old container '${cname}' ..."
        "${RUNTIME}" rm -f "${cname}" >/dev/null 2>&1 || true
    fi
done

if "${RUNTIME}" network inspect "${NETWORK}" >/dev/null 2>&1; then
    log "Removing old network '${NETWORK}' ..."
    "${RUNTIME}" network rm "${NETWORK}" >/dev/null 2>&1 || true
fi

# ===========================================================================
# Phase 1: Acquire images (pull from Docker Hub first; local build fallback)
# ===========================================================================
log ""
log "--- Phase 1: Acquire images ---"

# Source the shared image acquisition library
_img_log()   { log "$@"; }
_img_warn()  { log "WARNING: $*"; }
_img_error() { error "$@"; }
source "${SCRIPT_DIR}/reference/image.sh"

ensure_image "${LLAMACPP_IMAGE}" "${PROJECT_ROOT}/llamacpp"
ensure_image "${OPENCLAW_IMAGE}" "${PROJECT_ROOT}/openclaw"
ensure_image "${MARKITDOWN_IMAGE}" "${PROJECT_ROOT}/markitdown"

log "Images ready."

# ===========================================================================
# Phase 2: Create network + start llama.cpp
# ===========================================================================
log ""
log "--- Phase 2: Start llama.cpp ---"

log "Creating network '${NETWORK}' ..."
"${RUNTIME}" network create "${NETWORK}" || error "Failed to create network."

mkdir -p "${MODEL_DIR}"

log "Starting llama.cpp container ..."
log "  Model      : ${MODEL_REPO}/${MODEL_FILE}"
log "  Context    : ${CTX_SIZE} tokens"
log "  GPU layers : ${N_GPU_LAYERS}"
log "  Flash attn : ${FLASH_ATTN}"
log "  KV cache   : K=${CACHE_TYPE_K}, V=${CACHE_TYPE_V}"
log "  Model dir  : ${MODEL_DIR}"

# shellcheck disable=SC2086
"${RUNTIME}" run -d \
    --name "${LLAMACPP_CONTAINER}" \
    --network "${NETWORK}" \
    ${HOSTNAME_LLM} \
    --network-alias llamacpp \
    ${GPU_FLAGS} \
    --restart unless-stopped \
    ${SHM_FLAGS} \
    -p "${LLAMACPP_PORT}:${LLAMACPP_PORT}" \
    -v "${MODEL_DIR}:/models:rw" \
    -e "MODEL_PATH=/models/${MODEL_FILE}" \
    -e "MODEL_REPO=${MODEL_REPO}" \
    -e "MODEL_FILE=${MODEL_FILE}" \
    -e "MODEL_ALIAS=${MODEL_NAME}" \
    -e "LLAMA_HOST=0.0.0.0" \
    -e "LLAMA_PORT=${LLAMACPP_PORT}" \
    -e "CTX_SIZE=${CTX_SIZE}" \
    -e "N_GPU_LAYERS=${N_GPU_LAYERS}" \
    -e "FLASH_ATTN=${FLASH_ATTN}" \
    -e "CACHE_TYPE_K=${CACHE_TYPE_K}" \
    -e "CACHE_TYPE_V=${CACHE_TYPE_V}" \
    "${LLAMACPP_IMAGE}" || error "Failed to start llama.cpp container."

log "llama.cpp container started. Waiting for health ..."

# ---------------------------------------------------------------------------
# Wait for llama.cpp /health
# ---------------------------------------------------------------------------
elapsed=0
while [ "${elapsed}" -lt "${LLAMACPP_HEALTH_TIMEOUT}" ]; do
    state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${LLAMACPP_CONTAINER}" 2>/dev/null || echo "unknown")
    if [ "${state}" = "exited" ] || [ "${state}" = "dead" ]; then
        log "ERROR: llama.cpp container exited unexpectedly."
        "${RUNTIME}" logs --tail 30 "${LLAMACPP_CONTAINER}" 2>&1 || true
        exit 1
    fi

    if curl -sf "http://localhost:${LLAMACPP_PORT}/health" >/dev/null 2>&1; then
        log "llama.cpp /health OK."
        break
    fi

    sleep 5
    elapsed=$((elapsed + 5))
    if [ $((elapsed % 30)) -eq 0 ]; then
        log "  ... llama.cpp loading (${elapsed}/${LLAMACPP_HEALTH_TIMEOUT}s)"
    fi
done

if [ "${elapsed}" -ge "${LLAMACPP_HEALTH_TIMEOUT}" ]; then
    error "llama.cpp did not become healthy within ${LLAMACPP_HEALTH_TIMEOUT}s. Check logs: ${RUNTIME} logs ${LLAMACPP_CONTAINER}"
fi

# ---------------------------------------------------------------------------
# Verify /v1/models returns HTTP 200 with the expected model loaded
# ---------------------------------------------------------------------------
log "Checking /v1/models for model '${MODEL_NAME}' ..."
MODELS_URL="http://localhost:${LLAMACPP_PORT}/v1/models"
MODELS_TIMEOUT=60
models_elapsed=0
models_verified=false

while [ "${models_elapsed}" -lt "${MODELS_TIMEOUT}" ]; do
    tmpfile=$(mktemp)
    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time 10 "${MODELS_URL}" 2>/dev/null || echo "000")
    response=$(cat "${tmpfile}" 2>/dev/null || echo "")
    rm -f "${tmpfile}"

    if [ "${http_code}" = "200" ] && [ -n "${response}" ]; then
        model_check=$(echo "${response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = [m.get('id','') for m in data.get('data', [])]
    if models:
        print('found:' + ','.join(models))
    else:
        print('empty')
except Exception:
    print('error')
" 2>/dev/null || echo "error")

        case "${model_check}" in
            found:*)
                models_listed="${model_check#found:}"
                log "llama.cpp /v1/models returned HTTP 200."
                log "  Available models: ${models_listed}"
                models_verified=true
                break
                ;;
            empty)
                ;;
        esac
    fi

    sleep 5
    models_elapsed=$((models_elapsed + 5))
    if [ $((models_elapsed % 15)) -eq 0 ]; then
        log "  ... waiting for /v1/models (${models_elapsed}/${MODELS_TIMEOUT}s, HTTP ${http_code})"
    fi
done

if [ "${models_verified}" != "true" ]; then
    log "WARNING: /v1/models did not confirm model readiness within ${MODELS_TIMEOUT}s."
    log "  Last HTTP status: ${http_code:-000}"
    log "  The model may still be loading. Check: curl ${MODELS_URL}"
    log "  Container logs: ${RUNTIME} logs -f ${LLAMACPP_CONTAINER}"
fi

# ===========================================================================
# Phase 3: Start MarkItDown MCP sidecar
# ===========================================================================
log ""
log "--- Phase 3: Start MarkItDown MCP server ---"

log "Starting MarkItDown container ..."
log "  Port : ${MARKITDOWN_PORT}"

"${RUNTIME}" run -d \
    --name "${MARKITDOWN_CONTAINER}" \
    --network "${NETWORK}" \
    --network-alias markitdown \
    --restart unless-stopped \
    -p "${MARKITDOWN_PORT}:${MARKITDOWN_PORT}" \
    -e "MARKITDOWN_PORT=${MARKITDOWN_PORT}" \
    -e "MARKITDOWN_HOST=0.0.0.0" \
    "${MARKITDOWN_IMAGE}" || log "WARNING: Failed to start MarkItDown container. Continuing without it."

log "MarkItDown container started. Waiting for health ..."

# Wait for MarkItDown MCP server to be ready
markitdown_elapsed=0
MARKITDOWN_HEALTH_TIMEOUT=60
while [ "${markitdown_elapsed}" -lt "${MARKITDOWN_HEALTH_TIMEOUT}" ]; do
    if curl -sf "http://localhost:${MARKITDOWN_PORT}/health" >/dev/null 2>&1; then
        log "MarkItDown MCP server /health OK."
        break
    fi
    sleep 2
    markitdown_elapsed=$((markitdown_elapsed + 2))
    if [ $((markitdown_elapsed % 10)) -eq 0 ]; then
        log "  ... waiting for MarkItDown (${markitdown_elapsed}/${MARKITDOWN_HEALTH_TIMEOUT}s)"
    fi
done

markitdown_healthy=true
if [ "${markitdown_elapsed}" -ge "${MARKITDOWN_HEALTH_TIMEOUT}" ]; then
    markitdown_healthy=false
    log "WARNING: MarkItDown MCP server did not become healthy within ${MARKITDOWN_HEALTH_TIMEOUT}s."
    log "  OpenClaw will start without MarkItDown. Check logs: ${RUNTIME} logs ${MARKITDOWN_CONTAINER}"
fi

# ===========================================================================
# Phase 4: Start OpenClaw
# ===========================================================================
log ""
log "--- Phase 4: Start OpenClaw ---"

log "Starting OpenClaw container ..."

# mcporter configuration — mount from host if it exists
MCPORTER_MOUNT=""
MCPORTER_CONFIG="${PROJECT_ROOT}/config/mcporter.json"
if [ -f "${MCPORTER_CONFIG}" ]; then
    MCPORTER_MOUNT="-v ${MCPORTER_CONFIG}:/app/config/mcporter.json:ro"
    log "  mcporter config: ${MCPORTER_CONFIG} -> /app/config/mcporter.json"
fi

# shellcheck disable=SC2086
"${RUNTIME}" run -d \
    --name "${OPENCLAW_CONTAINER}" \
    --network "${NETWORK}" \
    ${HOSTNAME_OPENCLAW} \
    --network-alias openclaw \
    --restart unless-stopped \
    -p "${OPENCLAW_PORT}:${OPENCLAW_PORT}" \
    -p 18791:18791 \
    ${MCPORTER_MOUNT} \
    -e "LLAMACPP_BASE_URL=http://llamacpp:8000/v1" \
    -e "LLAMACPP_API_KEY=EMPTY" \
    -e "LLAMACPP_MODEL_NAME=${MODEL_NAME}" \
    -e "OPENCLAW_PORT=${OPENCLAW_PORT}" \
    "${OPENCLAW_IMAGE}" || error "Failed to start OpenClaw container."

log "OpenClaw container started. Waiting for dashboard ..."

# ---------------------------------------------------------------------------
# Wait for OpenClaw dashboard — requires HTTP 200 to pass health-check
# ---------------------------------------------------------------------------
oc_elapsed=0
oc_http_code="000"
while [ "${oc_elapsed}" -lt "${OPENCLAW_HEALTH_TIMEOUT}" ]; do
    state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${OPENCLAW_CONTAINER}" 2>/dev/null || echo "unknown")
    if [ "${state}" = "exited" ] || [ "${state}" = "dead" ]; then
        log "ERROR: OpenClaw container exited unexpectedly."
        "${RUNTIME}" logs --tail 20 "${OPENCLAW_CONTAINER}" 2>&1 || true
        exit 1
    fi

    oc_http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 "http://localhost:${OPENCLAW_PORT}/" 2>/dev/null || echo "000")

    if [ "${oc_http_code}" = "200" ]; then
        log "OpenClaw dashboard health-check passed (HTTP 200)."
        break
    fi

    sleep 3
    oc_elapsed=$((oc_elapsed + 3))
    if [ $((oc_elapsed % 15)) -eq 0 ]; then
        log "  ... waiting for OpenClaw (${oc_elapsed}/${OPENCLAW_HEALTH_TIMEOUT}s, HTTP ${oc_http_code})"
    fi
done

if [ "${oc_http_code}" != "200" ]; then
    error "OpenClaw dashboard did not return HTTP 200 within ${OPENCLAW_HEALTH_TIMEOUT}s (last: HTTP ${oc_http_code}). Check logs: ${RUNTIME} logs ${OPENCLAW_CONTAINER}"
fi

# ===========================================================================
# Phase 5: All health-checks passed — print dashboard URL
# ===========================================================================

# Resolve dashboard URL: try tokenized URL from openclaw binary, fall back to localhost
DASHBOARD_URL=$("${RUNTIME}" exec "${OPENCLAW_CONTAINER}" openclaw dashboard --no-open 2>/dev/null \
    | grep -oP 'https?://[^\s]+' | head -1 | sed 's/127\.0\.0\.1/localhost/' || true)

if [ -z "${DASHBOARD_URL}" ]; then
    DASHBOARD_URL="http://localhost:${OPENCLAW_PORT}"
fi

LLM_API_URL="http://localhost:${LLAMACPP_PORT}/v1"

log ""
log "========================================================"
log "  DemoClaw is running!"
log "========================================================"
log ""
log "  Health-checks passed:"
log "    - llama.cpp /v1/models ... HTTP 200"
if [ "${markitdown_healthy}" = "true" ]; then
    log "    - MarkItDown MCP ........ OK"
else
    log "    - MarkItDown MCP ........ WARN (unhealthy)"
fi
log "    - OpenClaw dashboard .... HTTP 200"
log ""
log "  Services:"
log "    LLM API  : ${LLM_API_URL}"
log "    Engine   : llama.cpp (CUDA)"
log "    Model    : ${MODEL_NAME} (${MODEL_REPO})"
log "    Context  : ${CTX_SIZE} tokens"
log "    Runtime  : ${RUNTIME}"
log ""
log "  Web UI Dashboard:"
log "    ${DASHBOARD_URL}"
log ""

# Print bare dashboard URL to stdout for easy parsing by scripts/tools
echo "${DASHBOARD_URL}"

log ""
log "  NOTE: On first connect, click \"Connect\" in the browser."
log "        The device pairing is auto-approved within ~2 seconds."
log "        If needed, click \"Connect\" again after approval."
log ""
log "  Stop with: ./scripts/stop.sh"
log "========================================================"
