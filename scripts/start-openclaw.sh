#!/usr/bin/env bash
# =============================================================================
# start-openclaw.sh — Launch the OpenClaw container with web dashboard
#
# The OpenClaw WebChat/Control UI dashboard is published to the host on
# port 18789 (configurable via OPENCLAW_HOST_PORT).
#
# Supports both docker and podman on Linux hosts.
#
# Usage:
#   ./scripts/start-openclaw.sh                          # auto-detect runtime
#   CONTAINER_RUNTIME=podman ./scripts/start-openclaw.sh # force podman
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants & Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-democlaw-openclaw}"
NETWORK_NAME="${DEMOCLAW_NETWORK:-democlaw-net}"
IMAGE_TAG="${OPENCLAW_IMAGE_TAG:-democlaw/openclaw:latest}"

# Port mapping — container listens on OPENCLAW_PORT, host exposes OPENCLAW_HOST_PORT
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_HOST_PORT="${OPENCLAW_HOST_PORT:-18789}"

# vLLM connection defaults (passed to the OpenClaw container as env vars)
VLLM_BASE_URL="${VLLM_BASE_URL:-http://vllm:8000/v1}"
VLLM_API_KEY="${VLLM_API_KEY:-EMPTY}"
VLLM_MODEL_NAME="${VLLM_MODEL_NAME:-Qwen/Qwen3.5-9B-AWQ}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { echo "[start-openclaw] $*"; }
warn()  { echo "[start-openclaw] WARNING: $*" >&2; }
error() { echo "[start-openclaw] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load .env file if present
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
# Handle existing container (idempotent — safe to re-run)
# ---------------------------------------------------------------------------
handle_existing_container() {
    if "${RUNTIME}" container inspect "${CONTAINER_NAME}" > /dev/null 2>&1; then
        local state
        state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null \
               || "${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}")

        if [ "${state}" = "running" ]; then
            log "Container '${CONTAINER_NAME}' is already running."
            log "Dashboard should be available at: http://localhost:${OPENCLAW_HOST_PORT}"
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
# Build the OpenClaw image if not already present
# ---------------------------------------------------------------------------
build_image() {
    if ! "${RUNTIME}" image inspect "${IMAGE_TAG}" > /dev/null 2>&1; then
        log "Building OpenClaw image '${IMAGE_TAG}' ..."
        "${RUNTIME}" build -t "${IMAGE_TAG}" "${PROJECT_ROOT}/openclaw"
    else
        log "Image '${IMAGE_TAG}' already exists. Use '${RUNTIME} rmi ${IMAGE_TAG}' to rebuild."
    fi
}

build_image

# ---------------------------------------------------------------------------
# Launch the OpenClaw container
# ---------------------------------------------------------------------------
log "Starting OpenClaw container '${CONTAINER_NAME}' ..."
log "  Dashboard port  : localhost:${OPENCLAW_HOST_PORT} -> container:${OPENCLAW_PORT}"
log "  vLLM endpoint   : ${VLLM_BASE_URL}"
log "  Model           : ${VLLM_MODEL_NAME}"
log "  Network         : ${NETWORK_NAME}"

"${RUNTIME}" run -d \
    --name "${CONTAINER_NAME}" \
    --network "${NETWORK_NAME}" \
    --hostname openclaw \
    --network-alias openclaw \
    --restart unless-stopped \
    -p "${OPENCLAW_HOST_PORT}:${OPENCLAW_PORT}" \
    -e "VLLM_BASE_URL=${VLLM_BASE_URL}" \
    -e "VLLM_API_KEY=${VLLM_API_KEY}" \
    -e "VLLM_MODEL_NAME=${VLLM_MODEL_NAME}" \
    -e "OPENCLAW_PORT=${OPENCLAW_PORT}" \
    -e "OPENAI_API_BASE=${VLLM_BASE_URL}" \
    -e "OPENAI_BASE_URL=${VLLM_BASE_URL}" \
    -e "OPENAI_API_KEY=${VLLM_API_KEY}" \
    -e "OPENAI_MODEL=${VLLM_MODEL_NAME}" \
    -e "OPENCLAW_LLM_PROVIDER=openai-compatible" \
    -e "OPENCLAW_LLM_BASE_URL=${VLLM_BASE_URL}" \
    -e "OPENCLAW_LLM_API_KEY=${VLLM_API_KEY}" \
    -e "OPENCLAW_LLM_MODEL=${VLLM_MODEL_NAME}" \
    -e "VLLM_HEALTH_RETRIES=${VLLM_HEALTH_RETRIES:-60}" \
    -e "VLLM_HEALTH_INTERVAL=${VLLM_HEALTH_INTERVAL:-5}" \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid \
    --tmpfs /app/config:rw,noexec,nosuid,uid=1000,gid=1000 \
    "${IMAGE_TAG}"

log "Container '${CONTAINER_NAME}' started successfully."

# ---------------------------------------------------------------------------
# Wait for the OpenClaw dashboard to become available on the host
# ---------------------------------------------------------------------------
DASHBOARD_URL="http://localhost:${OPENCLAW_HOST_PORT}"
HEALTH_TIMEOUT="${OPENCLAW_HEALTH_TIMEOUT:-120}"
HEALTH_INTERVAL=3

log "Waiting for OpenClaw dashboard at ${DASHBOARD_URL} (timeout: ${HEALTH_TIMEOUT}s) ..."

elapsed=0
while [ "${elapsed}" -lt "${HEALTH_TIMEOUT}" ]; do
    # Verify the container hasn't crashed
    if ! "${RUNTIME}" container inspect "${CONTAINER_NAME}" > /dev/null 2>&1; then
        error "Container '${CONTAINER_NAME}' exited unexpectedly. Check logs:\n  ${RUNTIME} logs ${CONTAINER_NAME}"
    fi

    container_state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    if [ "${container_state}" = "exited" ] || [ "${container_state}" = "dead" ]; then
        error "Container '${CONTAINER_NAME}' has stopped (state: ${container_state}). Check logs:\n  ${RUNTIME} logs ${CONTAINER_NAME}"
    fi

    # Try to reach the dashboard on the published host port
    if curl -sf -o /dev/null -w '' "${DASHBOARD_URL}" 2>/dev/null; then
        log ""
        log "============================================="
        log "  OpenClaw dashboard is ready!"
        log "  URL: ${DASHBOARD_URL}"
        log "============================================="
        log ""
        exit 0
    fi

    sleep "${HEALTH_INTERVAL}"
    elapsed=$((elapsed + HEALTH_INTERVAL))
    log "  ... waiting (${elapsed}/${HEALTH_TIMEOUT}s)"
done

# ---------------------------------------------------------------------------
# Timeout — dashboard didn't respond but container may still be starting
# ---------------------------------------------------------------------------
warn "OpenClaw dashboard did not respond within ${HEALTH_TIMEOUT}s."
warn "The container is still running — it may be waiting for the vLLM server."
warn "  Dashboard URL : ${DASHBOARD_URL}"
warn "  Check logs    : ${RUNTIME} logs -f ${CONTAINER_NAME}"
warn ""
warn "If the vLLM server is not yet running, start it first:"
warn "  ./scripts/start-vllm.sh"
exit 1
