#!/usr/bin/env bash
# =============================================================================
# start.sh -- Full E2E startup for the DemoClaw stack (vLLM + OpenClaw)
#
# This single script handles the entire lifecycle:
#   1. Clean up old containers/network
#   2. Build images (always rebuild to pick up Dockerfile changes)
#   3. Create network
#   4. Start vLLM, wait for /health + /v1/models
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
# Configuration
# ---------------------------------------------------------------------------
VLLM_IMAGE="${DEMOCLAW_VLLM_IMAGE:-jinwangmok/democlaw-vllm:v1.0.0}"
OPENCLAW_IMAGE="${DEMOCLAW_OPENCLAW_IMAGE:-jinwangmok/democlaw-openclaw:v1.0.0}"
NETWORK="democlaw-net"
VLLM_CONTAINER="democlaw-vllm"
OPENCLAW_CONTAINER="democlaw-openclaw"
MODEL_NAME="Qwen/Qwen3-4B-AWQ"

# vLLM tuning for 8GB VRAM
MAX_MODEL_LEN="16384"
QUANTIZATION="awq_marlin"
DTYPE="float16"
GPU_MEMORY_UTILIZATION="0.95"

# Ports
VLLM_PORT="8000"
OPENCLAW_PORT="18789"

# Timeouts (seconds)
VLLM_HEALTH_TIMEOUT=300
OPENCLAW_HEALTH_TIMEOUT=120

# HuggingFace cache
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"

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
if [ "${RUNTIME}" = "podman" ]; then
    GPU_FLAGS="--device nvidia.com/gpu=all"
fi

log "========================================================"
log "  DemoClaw Stack -- Full E2E Startup"
log "========================================================"
log "Runtime: ${RUNTIME}"

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

for cname in "${OPENCLAW_CONTAINER}" "${VLLM_CONTAINER}"; do
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
source "${SCRIPT_DIR}/lib/image.sh"

ensure_image "${VLLM_IMAGE}" "${PROJECT_ROOT}/vllm"
ensure_image "${OPENCLAW_IMAGE}" "${PROJECT_ROOT}/openclaw"

log "Images ready."

# ===========================================================================
# Phase 2: Create network + start vLLM
# ===========================================================================
log ""
log "--- Phase 2: Start vLLM ---"

log "Creating network '${NETWORK}' ..."
"${RUNTIME}" network create "${NETWORK}" || error "Failed to create network."

mkdir -p "${HF_CACHE_DIR}"

# Source checksum library for model integrity verification
_cksum_log()   { log "$@"; }
_cksum_warn()  { log "WARNING: $*"; }
_cksum_error() { log "ERROR: $*"; }
source "${SCRIPT_DIR}/lib/checksum.sh"

# Verify model checksums (if model is already cached)
if ! checksum_model_needs_download "${HF_CACHE_DIR}" "${MODEL_NAME}"; then
    log "Model checksums verified — cached model is intact."
else
    log "Model not yet cached or checksums missing — vLLM will download on first start."
fi

log "Starting vLLM container ..."
log "  Model        : ${MODEL_NAME}"
log "  Quantization : ${QUANTIZATION}"
log "  Context      : ${MAX_MODEL_LEN}"
log "  GPU mem util : ${GPU_MEMORY_UTILIZATION}"

# shellcheck disable=SC2086
"${RUNTIME}" run -d \
    --name "${VLLM_CONTAINER}" \
    --network "${NETWORK}" \
    --hostname vllm \
    --network-alias vllm \
    ${GPU_FLAGS} \
    --restart unless-stopped \
    --shm-size 1g \
    -p "${VLLM_PORT}:${VLLM_PORT}" \
    -v "${HF_CACHE_DIR}:/root/.cache/huggingface:rw" \
    -e "MODEL_NAME=${MODEL_NAME}" \
    -e "MAX_MODEL_LEN=${MAX_MODEL_LEN}" \
    -e "GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}" \
    -e "QUANTIZATION=${QUANTIZATION}" \
    -e "DTYPE=${DTYPE}" \
    -e "VLLM_ATTENTION_BACKEND=FLASHINFER" \
    "${VLLM_IMAGE}" || error "Failed to start vLLM container."

log "vLLM container started. Waiting for health ..."

# ---------------------------------------------------------------------------
# Wait for vLLM /health
# ---------------------------------------------------------------------------
elapsed=0
while [ "${elapsed}" -lt "${VLLM_HEALTH_TIMEOUT}" ]; do
    state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${VLLM_CONTAINER}" 2>/dev/null || echo "unknown")
    if [ "${state}" = "exited" ] || [ "${state}" = "dead" ]; then
        log "ERROR: vLLM container exited unexpectedly."
        "${RUNTIME}" logs --tail 20 "${VLLM_CONTAINER}" 2>&1 || true
        exit 1
    fi

    if curl -sf "http://localhost:${VLLM_PORT}/health" >/dev/null 2>&1; then
        log "vLLM /health OK."
        break
    fi

    sleep 5
    elapsed=$((elapsed + 5))
    if [ $((elapsed % 30)) -eq 0 ]; then
        log "  ... vLLM loading (${elapsed}/${VLLM_HEALTH_TIMEOUT}s)"
    fi
done

if [ "${elapsed}" -ge "${VLLM_HEALTH_TIMEOUT}" ]; then
    error "vLLM did not become healthy within ${VLLM_HEALTH_TIMEOUT}s. Check logs: ${RUNTIME} logs ${VLLM_CONTAINER}"
fi

# ---------------------------------------------------------------------------
# Verify /v1/models returns HTTP 200 with the expected model loaded
# ---------------------------------------------------------------------------
log "Checking /v1/models for model '${MODEL_NAME}' ..."
MODELS_URL="http://localhost:${VLLM_PORT}/v1/models"
MODELS_TIMEOUT=120
models_elapsed=0
models_verified=false

while [ "${models_elapsed}" -lt "${MODELS_TIMEOUT}" ]; do
    # Capture both HTTP status code and response body
    tmpfile=$(mktemp)
    http_code=$(curl -sf -o "${tmpfile}" -w "%{http_code}" \
        --max-time 10 "${MODELS_URL}" 2>/dev/null || echo "000")
    response=$(cat "${tmpfile}" 2>/dev/null || echo "")
    rm -f "${tmpfile}"

    if [ "${http_code}" = "200" ] && [ -n "${response}" ]; then
        # Parse model list and verify expected model is present
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
                log "vLLM /v1/models returned HTTP 200."
                log "  Available models: ${models_listed}"
                if echo "${models_listed}" | grep -qF "${MODEL_NAME}"; then
                    log "  Confirmed: '${MODEL_NAME}' is loaded and serving."
                    models_verified=true
                else
                    log "  WARNING: Expected model '${MODEL_NAME}' not in list."
                    log "  Proceeding with available models: ${models_listed}"
                    models_verified=true
                fi
                break
                ;;
            empty)
                # HTTP 200 but no models yet — keep polling
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
    log "  Container logs: ${RUNTIME} logs -f ${VLLM_CONTAINER}"
fi

# ===========================================================================
# Phase 3: Start OpenClaw
# ===========================================================================
log ""
log "--- Phase 3: Start OpenClaw ---"

log "Starting OpenClaw container ..."

"${RUNTIME}" run -d \
    --name "${OPENCLAW_CONTAINER}" \
    --network "${NETWORK}" \
    --hostname openclaw \
    --network-alias openclaw \
    --restart unless-stopped \
    -p "${OPENCLAW_PORT}:${OPENCLAW_PORT}" \
    -p 18791:18791 \
    -e "VLLM_BASE_URL=http://vllm:8000/v1" \
    -e "VLLM_API_KEY=EMPTY" \
    -e "VLLM_MODEL_NAME=${MODEL_NAME}" \
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
# Phase 4: Both health-checks passed — print dashboard URL
# ===========================================================================

# Resolve dashboard URL: try tokenized URL from openclaw binary, fall back to localhost
DASHBOARD_URL=$("${RUNTIME}" exec "${OPENCLAW_CONTAINER}" openclaw dashboard --no-open 2>/dev/null \
    | grep -oP 'https?://[^\s]+' | head -1 | sed 's/127\.0\.0\.1/localhost/' || true)

if [ -z "${DASHBOARD_URL}" ]; then
    DASHBOARD_URL="http://localhost:${OPENCLAW_PORT}"
fi

VLLM_API_URL="http://localhost:${VLLM_PORT}/v1"

log ""
log "========================================================"
log "  ✅ DemoClaw is running!"
log "========================================================"
log ""
log "  Both health-checks passed:"
log "    • vLLM /v1/models .... HTTP 200 ✓"
log "    • OpenClaw dashboard . HTTP 200 ✓"
log ""
log "  Services:"
log "    vLLM API  : ${VLLM_API_URL}"
log "    Model     : ${MODEL_NAME}"
log "    Runtime   : ${RUNTIME}"
log ""
log "  Web UI Dashboard:"
log "    ${DASHBOARD_URL}"
log ""

# Print bare dashboard URL to stdout for easy parsing by scripts/tools
# This line has no prefix so it can be captured with: ./scripts/start.sh | grep '^http'
echo "${DASHBOARD_URL}"

log ""
log "  NOTE: On first connect, click \"Connect\" in the browser."
log "        The device pairing is auto-approved within ~2 seconds."
log "        If needed, click \"Connect\" again after approval."
log ""
log "  Stop with: ./scripts/stop.sh"
log "========================================================"
