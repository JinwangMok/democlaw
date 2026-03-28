#!/usr/bin/env bash
# =============================================================================
# start.sh — Main orchestration script for the DemoClaw stack
#
# Launches both the vLLM server and OpenClaw containers using whichever
# container runtime (docker or podman) is available on the host.
#
# Auto-detection priority:
#   1. $CONTAINER_RUNTIME env var  (explicit override)
#   2. docker                      (if in PATH)
#   3. podman                      (if in PATH)
#
# Usage:
#   ./scripts/start.sh                              # auto-detect runtime
#   CONTAINER_RUNTIME=podman ./scripts/start.sh     # force podman
#
# Requires: Linux host, NVIDIA GPU with CUDA drivers, nvidia-container-toolkit
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { echo "[start] $*"; }
warn()  { echo "[start] WARNING: $*" >&2; }
error() { printf "[start] ERROR: %s\n" "$*" >&2; exit 1; }

# Override internal logging for the runtime library
_rt_log()   { log "$@"; }
_rt_warn()  { warn "$@"; }
_rt_error() { error "$@"; }

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
# Source the shared runtime-detection library
# ---------------------------------------------------------------------------
# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

# At this point, RUNTIME is set to "docker" or "podman" automatically.
log "========================================================"
log "  DemoClaw Stack — Container Runtime: ${RUNTIME}"
log "  Podman mode: ${RUNTIME_IS_PODMAN}"
log "========================================================"

# ---------------------------------------------------------------------------
# Verify Linux host OS
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Linux" ]; then
    error "This script requires a Linux host (detected: $(uname -s)). Exiting."
fi

# ---------------------------------------------------------------------------
# Validate NVIDIA GPU and CUDA drivers BEFORE launching any containers
# ---------------------------------------------------------------------------
# Override gpu.sh logging to use our prefix
_gpu_log()   { log "$@"; }
_gpu_warn()  { warn "$@"; }
_gpu_error() { error "$@"; }

# shellcheck source=lib/gpu.sh
source "${SCRIPT_DIR}/lib/gpu.sh"

validate_nvidia_gpu "${RUNTIME}"

# ---------------------------------------------------------------------------
# Launch the vLLM container first (it takes time to load the model)
# ---------------------------------------------------------------------------
log ""
log "--- Phase 1: Starting vLLM server ---"
bash "${SCRIPT_DIR}/start-vllm.sh" &
VLLM_PID=$!

# Give vLLM a head start before starting OpenClaw
log "Waiting a moment for vLLM container to initialize..."
sleep 5

# ---------------------------------------------------------------------------
# Launch the OpenClaw container
# ---------------------------------------------------------------------------
log ""
log "--- Phase 2: Starting OpenClaw ---"
bash "${SCRIPT_DIR}/start-openclaw.sh" &
OPENCLAW_PID=$!

# ---------------------------------------------------------------------------
# Wait for both to complete
# ---------------------------------------------------------------------------
VLLM_EXIT=0
OPENCLAW_EXIT=0

wait "${VLLM_PID}" || VLLM_EXIT=$?
wait "${OPENCLAW_PID}" || OPENCLAW_EXIT=$?

# ---------------------------------------------------------------------------
# Phase 3: OpenClaw healthcheck — verify dashboard is reachable after start
# ---------------------------------------------------------------------------
log ""
log "--- Phase 3: OpenClaw healthcheck ---"

HEALTHCHECK_EXIT=0
if [ "${OPENCLAW_EXIT}" -eq 0 ]; then
    # Use a short timeout since start-openclaw.sh already waited for the
    # dashboard; this is a final confirmation pass with a clear status line.
    OPENCLAW_HEALTH_TIMEOUT="${OPENCLAW_HEALTH_TIMEOUT:-30}" \
        bash "${SCRIPT_DIR}/healthcheck_openclaw.sh" || HEALTHCHECK_EXIT=$?

    if [ "${HEALTHCHECK_EXIT}" -eq 0 ]; then
        log "HEALTHCHECK PASS: OpenClaw dashboard is reachable at http://localhost:${OPENCLAW_HOST_PORT:-18789}"
    else
        log "HEALTHCHECK FAIL: OpenClaw dashboard did not respond within the timeout."
    fi
else
    HEALTHCHECK_EXIT=1
    log "HEALTHCHECK FAIL: OpenClaw container did not start (exit code ${OPENCLAW_EXIT}); skipping dashboard poll."
fi

log ""
log "========================================================"
if [ "${VLLM_EXIT}" -eq 0 ] && [ "${OPENCLAW_EXIT}" -eq 0 ] && [ "${HEALTHCHECK_EXIT}" -eq 0 ]; then
    log "  Both services started successfully!"
    log "  vLLM API     : http://localhost:${VLLM_HOST_PORT:-8000}/v1"
    log "  OpenClaw UI  : http://localhost:${OPENCLAW_HOST_PORT:-18789}"
    log "  Runtime      : ${RUNTIME}"
    log "========================================================"
    exit 0
else
    [ "${VLLM_EXIT}" -ne 0 ]      && warn "vLLM start script exited with code ${VLLM_EXIT}"
    [ "${OPENCLAW_EXIT}" -ne 0 ]  && warn "OpenClaw start script exited with code ${OPENCLAW_EXIT}"
    [ "${HEALTHCHECK_EXIT}" -ne 0 ] && warn "OpenClaw healthcheck exited with code ${HEALTHCHECK_EXIT}"
    log "========================================================"
    exit 1
fi
