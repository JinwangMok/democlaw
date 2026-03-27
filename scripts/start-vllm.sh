#!/usr/bin/env bash
# =============================================================================
# start-vllm.sh — Launch the vLLM container serving Qwen3.5-9B AWQ 4-bit
#
# Supports both docker and podman on Linux hosts.
# Requires: NVIDIA GPU with >= 8GB VRAM, nvidia-container-toolkit installed.
#
# Usage:
#   ./scripts/start-vllm.sh              # auto-detect runtime
#   CONTAINER_RUNTIME=podman ./scripts/start-vllm.sh   # force podman
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants & Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { echo "[start-vllm] $*"; }
warn()  { echo "[start-vllm] WARNING: $*" >&2; }
error() { printf "[start-vllm] ERROR: %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load .env file if present (key=value, no export needed)
# Must happen BEFORE variable defaults so .env values take precedence.
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    log "Loading environment from ${ENV_FILE}"
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

# ---------------------------------------------------------------------------
# Configurable defaults (all overridable via environment or .env file)
# ---------------------------------------------------------------------------
CONTAINER_NAME="${VLLM_CONTAINER_NAME:-democlaw-vllm}"
NETWORK_NAME="${DEMOCLAW_NETWORK:-democlaw-net}"
IMAGE_TAG="${VLLM_IMAGE_TAG:-democlaw/vllm:latest}"

MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3.5-9B-AWQ}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_HOST_PORT="${VLLM_HOST_PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
QUANTIZATION="${QUANTIZATION:-awq}"
DTYPE="${DTYPE:-float16}"

# HuggingFace cache — share host cache to avoid re-downloading models
HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"

# ---------------------------------------------------------------------------
# Detect container runtime: prefer $CONTAINER_RUNTIME, then docker, then podman
# Uses the shared runtime detection library for consistent behavior.
# ---------------------------------------------------------------------------
_rt_log()   { log "$@"; }
_rt_warn()  { warn "$@"; }
_rt_error() { error "$@"; }

# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

log "Using container runtime: ${RUNTIME}"

# ---------------------------------------------------------------------------
# Verify Linux host OS
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Linux" ]; then
    error "This script requires a Linux host (detected: $(uname -s)). Exiting."
fi

# ---------------------------------------------------------------------------
# Validate NVIDIA GPU & CUDA availability using the shared gpu library
# ---------------------------------------------------------------------------
# Override gpu.sh logging to use our prefix
_gpu_log()   { log "$@"; }
_gpu_warn()  { warn "$@"; }
_gpu_error() { error "$@"; }

# shellcheck source=lib/gpu.sh
source "${SCRIPT_DIR}/lib/gpu.sh"

validate_nvidia_gpu "${RUNTIME}"

# ---------------------------------------------------------------------------
# Ensure the shared container network exists
# ---------------------------------------------------------------------------
ensure_network() {
    if ! "${RUNTIME}" network inspect "${NETWORK_NAME}" > /dev/null 2>&1; then
        log "Creating network '${NETWORK_NAME}' ..."
        "${RUNTIME}" network create "${NETWORK_NAME}"
    else
        log "Network '${NETWORK_NAME}' already exists."
    fi
}

ensure_network

# ---------------------------------------------------------------------------
# Handle existing container (idempotent)
# ---------------------------------------------------------------------------
handle_existing_container() {
    if "${RUNTIME}" container inspect "${CONTAINER_NAME}" > /dev/null 2>&1; then
        local state
        state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null \
               || "${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}")

        if [ "${state}" = "running" ]; then
            log "Container '${CONTAINER_NAME}' is already running."
            log "To restart, run: ${RUNTIME} rm -f ${CONTAINER_NAME} && $0"
            exit 0
        else
            log "Removing stopped container '${CONTAINER_NAME}' ..."
            "${RUNTIME}" rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
        fi
    fi
}

handle_existing_container

# ---------------------------------------------------------------------------
# Build the vLLM image if not already present
# ---------------------------------------------------------------------------
build_image() {
    if ! "${RUNTIME}" image inspect "${IMAGE_TAG}" > /dev/null 2>&1; then
        log "Building vLLM image '${IMAGE_TAG}' ..."
        "${RUNTIME}" build -t "${IMAGE_TAG}" "${PROJECT_ROOT}/vllm"
    else
        log "Image '${IMAGE_TAG}' already exists. Use '${RUNTIME} rmi ${IMAGE_TAG}' to rebuild."
    fi
}

build_image

# ---------------------------------------------------------------------------
# Prepare HuggingFace cache directory on the host
# ---------------------------------------------------------------------------
mkdir -p "${HF_CACHE_DIR}"

# ---------------------------------------------------------------------------
# Build GPU flags based on runtime (uses shared library helper)
# ---------------------------------------------------------------------------
GPU_FLAGS=$(runtime_gpu_flags)

# ---------------------------------------------------------------------------
# Launch the vLLM container
# ---------------------------------------------------------------------------
log "Starting vLLM container '${CONTAINER_NAME}' ..."
log "  Model           : ${MODEL_NAME}"
log "  Quantization    : ${QUANTIZATION}"
log "  Max model len   : ${MAX_MODEL_LEN}"
log "  GPU mem util    : ${GPU_MEMORY_UTILIZATION}"
log "  Host port       : ${VLLM_HOST_PORT} -> container ${VLLM_PORT}"
log "  HF cache        : ${HF_CACHE_DIR}"

# shellcheck disable=SC2086
"${RUNTIME}" run -d \
    --name "${CONTAINER_NAME}" \
    --network "${NETWORK_NAME}" \
    --hostname vllm \
    --network-alias vllm \
    ${GPU_FLAGS} \
    --restart unless-stopped \
    --shm-size 1g \
    -p "${VLLM_HOST_PORT}:${VLLM_PORT}" \
    -v "${HF_CACHE_DIR}:/root/.cache/huggingface:rw" \
    -e "MODEL_NAME=${MODEL_NAME}" \
    -e "VLLM_PORT=${VLLM_PORT}" \
    -e "MAX_MODEL_LEN=${MAX_MODEL_LEN}" \
    -e "GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}" \
    -e "QUANTIZATION=${QUANTIZATION}" \
    -e "DTYPE=${DTYPE}" \
    -e "HF_TOKEN=${HF_TOKEN:-}" \
    -e "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN:-}" \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    "${IMAGE_TAG}"

log "Container '${CONTAINER_NAME}' started successfully."

# ---------------------------------------------------------------------------
# Wait for the vLLM health endpoint to become available
# ---------------------------------------------------------------------------
HEALTH_URL="http://localhost:${VLLM_HOST_PORT}/health"
MODELS_URL="http://localhost:${VLLM_HOST_PORT}/v1/models"
HEALTH_TIMEOUT="${VLLM_HEALTH_TIMEOUT:-300}"
HEALTH_INTERVAL=5

log "Waiting for vLLM to become healthy (timeout: ${HEALTH_TIMEOUT}s) ..."

# ---------------------------------------------------------------------------
# Phase 1: Wait for /health to respond
# ---------------------------------------------------------------------------
log "Phase 1/2: Waiting for /health endpoint at ${HEALTH_URL} ..."

elapsed=0
while [ "${elapsed}" -lt "${HEALTH_TIMEOUT}" ]; do
    # Check container is still running
    container_state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "missing")
    if [ "${container_state}" = "exited" ] || [ "${container_state}" = "dead" ] || [ "${container_state}" = "missing" ]; then
        log "Container logs:"
        "${RUNTIME}" logs --tail 30 "${CONTAINER_NAME}" 2>&1 || true
        error "Container '${CONTAINER_NAME}' exited unexpectedly (state: ${container_state}). See logs above or run: ${RUNTIME} logs ${CONTAINER_NAME}"
    fi

    if curl -sf "${HEALTH_URL}" > /dev/null 2>&1; then
        log "/health endpoint is responding."
        break
    fi

    sleep "${HEALTH_INTERVAL}"
    elapsed=$((elapsed + HEALTH_INTERVAL))
    log "  ... waiting for /health (${elapsed}/${HEALTH_TIMEOUT}s)"
done

if [ "${elapsed}" -ge "${HEALTH_TIMEOUT}" ]; then
    warn "vLLM /health did not respond within ${HEALTH_TIMEOUT}s."
    warn "The container is still running — the model may still be downloading."
    warn "Check progress with: ${RUNTIME} logs -f ${CONTAINER_NAME}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 2: Verify /v1/models returns the expected model
# ---------------------------------------------------------------------------
log "Phase 2/2: Verifying /v1/models endpoint lists '${MODEL_NAME}' ..."

MODELS_TIMEOUT=60  # Additional time after /health is up for model listing
models_elapsed=0

while [ "${models_elapsed}" -lt "${MODELS_TIMEOUT}" ]; do
    models_response=$(curl -sf --max-time 10 "${MODELS_URL}" 2>/dev/null || echo "")

    if [ -n "${models_response}" ]; then
        # Check if the response is valid JSON with model data
        model_check=$(echo "${models_response}" | python3 -c "
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
                log "/v1/models responded successfully."
                log "  Available models: ${models_listed}"

                if echo "${models_listed}" | grep -q "${MODEL_NAME}"; then
                    log "Expected model '${MODEL_NAME}' confirmed."
                else
                    warn "Expected model '${MODEL_NAME}' not found in model list."
                    warn "Available models: ${models_listed}"
                fi

                log ""
                log "vLLM server is healthy and ready to serve requests."
                log "  API endpoint: http://localhost:${VLLM_HOST_PORT}/v1"
                log "  Models API  : ${MODELS_URL}"
                log "  Health check: ${HEALTH_URL}"
                exit 0
                ;;
            empty)
                # Models endpoint works but no models loaded yet
                ;;
            *)
                # Error parsing or no response
                ;;
        esac
    fi

    sleep "${HEALTH_INTERVAL}"
    models_elapsed=$((models_elapsed + HEALTH_INTERVAL))
    log "  ... waiting for /v1/models (${models_elapsed}/${MODELS_TIMEOUT}s)"
done

warn "vLLM /v1/models did not list any models within ${MODELS_TIMEOUT}s after /health became available."
warn "The server is running but the model may still be loading."
warn "Check with: curl ${MODELS_URL}"
warn "Check logs: ${RUNTIME} logs -f ${CONTAINER_NAME}"
exit 1
