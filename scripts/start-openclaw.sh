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

# ---------------------------------------------------------------------------
# OpenAI-compatible endpoint env vars — passed into the OpenClaw container
# ---------------------------------------------------------------------------
# Three variables define the core provider connection:
#
#   VLLM_BASE_URL   : API base URL using the vLLM container's network alias.
#                     "vllm" resolves inside the shared bridge network so
#                     OpenClaw reaches vLLM via container-to-container DNS.
#                     Format: http://<hostname>:<port>/v1
#                     Default: http://vllm:8000/v1
#
#   VLLM_MODEL_NAME : Model ID that OpenClaw sends in every API request.
#                     Must match the model served by vLLM.
#                     Default: Qwen/Qwen3.5-9B-AWQ  (AWQ 4-bit, 8 GB VRAM)
#
#   VLLM_API_KEY    : Placeholder API key.  vLLM accepts any non-empty value
#                     by default; use "EMPTY" as the conventional placeholder.
#                     Default: EMPTY
#
# Additional vLLM provider vars:
#   VLLM_MAX_TOKENS   : Maximum tokens per response (default: 4096)
#   VLLM_TEMPERATURE  : Sampling temperature (default: 0.7)
#
# Standard OpenAI SDK env vars (honoured by openai, LangChain, LiteLLM, …):
#   OPENAI_API_BASE / OPENAI_BASE_URL  — mirror VLLM_BASE_URL
#   OPENAI_API_KEY                     — mirror VLLM_API_KEY
#   OPENAI_MODEL                       — mirror VLLM_MODEL_NAME
#
# OpenClaw-specific env vars (secondary lookup path):
#   OPENCLAW_LLM_PROVIDER / OPENCLAW_LLM_BASE_URL / OPENCLAW_LLM_API_KEY
#   OPENCLAW_LLM_MODEL / OPENCLAW_LLM_MAX_TOKENS / OPENCLAW_LLM_TEMPERATURE
# ---------------------------------------------------------------------------
VLLM_BASE_URL="${VLLM_BASE_URL:-http://vllm:8000/v1}"
VLLM_API_KEY="${VLLM_API_KEY:-EMPTY}"
VLLM_MODEL_NAME="${VLLM_MODEL_NAME:-Qwen/Qwen3.5-9B-AWQ}"
VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-4096}"
VLLM_TEMPERATURE="${VLLM_TEMPERATURE:-0.7}"

# vLLM container name — used for network-membership verification before launch
VLLM_CONTAINER_NAME="${VLLM_CONTAINER_NAME:-democlaw-vllm}"

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
#
# Uses runtime_ensure_network() from lib/runtime.sh — idempotent and works
# identically on both docker and podman.  Creates the network if absent;
# no-ops (with a log message) if it already exists.
#
# Both the vLLM container (network alias: "vllm") and this OpenClaw container
# attach to this network so that OpenClaw can resolve vLLM by name:
#   http://vllm:${VLLM_PORT}/v1
# ---------------------------------------------------------------------------
runtime_ensure_network "${NETWORK_NAME}"

# ---------------------------------------------------------------------------
# verify_vllm_network_membership — Ensure the vLLM container is running and
#   connected to the shared network so that http://vllm:<port>/v1 is reachable
#   from the OpenClaw container once it starts.
#
# This is the "endpoint reachability" check for Sub-AC 3c:
#   - Confirms the vLLM container exists and is in "running" state.
#   - Confirms the vLLM container is attached to NETWORK_NAME so that its
#     network alias "vllm" resolves within the shared bridge network.
#   - Emits a clear warning (rather than a hard exit) when vLLM is absent,
#     because the OpenClaw entrypoint already retries the vLLM health probe
#     internally (VLLM_HEALTH_RETRIES / VLLM_HEALTH_INTERVAL env vars).
# ---------------------------------------------------------------------------
verify_vllm_network_membership() {
    log "Verifying vLLM endpoint reachability on network '${NETWORK_NAME}' ..."
    log "  vLLM container : ${VLLM_CONTAINER_NAME}"
    log "  vLLM endpoint  : ${VLLM_BASE_URL}"

    # -----------------------------------------------------------------------
    # Step 1: vLLM container existence check
    # -----------------------------------------------------------------------
    if ! "${RUNTIME}" container inspect "${VLLM_CONTAINER_NAME}" > /dev/null 2>&1; then
        warn "vLLM container '${VLLM_CONTAINER_NAME}' does not exist."
        warn "OpenClaw will start, but it will wait for vLLM to become available."
        warn "Start vLLM with: ./scripts/start-vllm.sh"
        warn ""
        return 0
    fi

    # -----------------------------------------------------------------------
    # Step 2: vLLM container running state check
    # -----------------------------------------------------------------------
    local vllm_state
    vllm_state=$("${RUNTIME}" container inspect \
        --format '{{.State.Status}}' "${VLLM_CONTAINER_NAME}" 2>/dev/null \
        || echo "unknown")

    if [ "${vllm_state}" != "running" ]; then
        warn "vLLM container '${VLLM_CONTAINER_NAME}' exists but is not running (state: ${vllm_state})."
        warn "OpenClaw will start and wait for vLLM at: ${VLLM_BASE_URL}"
        warn "Start vLLM with: ./scripts/start-vllm.sh"
        warn ""
        return 0
    fi

    # -----------------------------------------------------------------------
    # Step 3: Verify vLLM is attached to the shared container network so its
    #   hostname alias ("vllm") resolves from within OpenClaw's network scope.
    # -----------------------------------------------------------------------
    local vllm_networks
    vllm_networks=$("${RUNTIME}" container inspect \
        --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
        "${VLLM_CONTAINER_NAME}" 2>/dev/null | tr -s ' ' || echo "")

    if echo "${vllm_networks}" | grep -qw "${NETWORK_NAME}"; then
        log "vLLM container '${VLLM_CONTAINER_NAME}' is running and attached to '${NETWORK_NAME}'."
        log "OpenClaw will reach vLLM via the shared network alias: ${VLLM_BASE_URL}"
    else
        warn "vLLM container '${VLLM_CONTAINER_NAME}' is running but is NOT connected to '${NETWORK_NAME}'."
        warn "Attached networks: ${vllm_networks:-<none detected>}"
        warn "The hostname 'vllm' may not resolve from within OpenClaw's network."
        warn "Ensure the vLLM container was started with: ./scripts/start-vllm.sh"
        warn "(which always connects it to '${NETWORK_NAME}' with alias 'vllm')"
        warn ""
    fi
}

verify_vllm_network_membership

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
#
# Key flags:
#   -d                          Run detached (background)
#   --name                      Container name for log/stop/inspect access
#   --network / --network-alias Attach to shared network; reachable as "openclaw"
#   --hostname openclaw         Container hostname (for self-reference / logs)
#   --restart unless-stopped    Auto-restart on failure (not on explicit stop)
#   -p OPENCLAW_HOST_PORT:...   Publish dashboard port on the Linux host
#
#   OpenAI-compatible provider env vars (three sets for maximum compatibility):
#   ① vLLM-specific vars consumed by the container entrypoint:
#       VLLM_BASE_URL           URL of the OpenAI-compatible API endpoint
#       VLLM_API_KEY            Placeholder API key (vLLM accepts any value)
#       VLLM_MODEL_NAME         Model ID to request (must match vLLM's model)
#       VLLM_MAX_TOKENS         Max tokens per response
#       VLLM_TEMPERATURE        Sampling temperature
#       VLLM_HEALTH_RETRIES     How many times to retry the vLLM health probe
#       VLLM_HEALTH_INTERVAL    Seconds between health probe retries
#   ② Standard OpenAI SDK env vars (openai-node / openai-python / LangChain):
#       OPENAI_API_BASE         Legacy LangChain convention
#       OPENAI_BASE_URL         Current openai SDK convention
#       OPENAI_API_KEY          Must be non-empty; vLLM accepts any value
#       OPENAI_MODEL            Model ID for SDK clients that read this var
#   ③ OpenClaw-specific env vars (secondary lookup path):
#       OPENCLAW_LLM_PROVIDER   "openai-compatible" selects vLLM as backend
#       OPENCLAW_LLM_BASE_URL   Mirrors VLLM_BASE_URL
#       OPENCLAW_LLM_API_KEY    Mirrors VLLM_API_KEY
#       OPENCLAW_LLM_MODEL      Mirrors VLLM_MODEL_NAME
#       OPENCLAW_LLM_MAX_TOKENS Mirrors VLLM_MAX_TOKENS
#       OPENCLAW_LLM_TEMPERATURE Mirrors VLLM_TEMPERATURE
#
#   Security flags:
#   --cap-drop ALL              Drop all Linux capabilities
#   --security-opt no-new-privileges  Prevent privilege escalation
#   --read-only                 Read-only root filesystem
#   --tmpfs /tmp                Writable tmpfs for runtime temp files
#   --tmpfs /app/config         Writable tmpfs for entrypoint-generated config.json
# ---------------------------------------------------------------------------
log "======================================================="
log "  Starting OpenClaw container"
log "======================================================="
log "  Container  : ${CONTAINER_NAME}"
log "  Image      : ${IMAGE_TAG}"
log "  Network    : ${NETWORK_NAME} (alias: openclaw)"
log "  Dashboard  : localhost:${OPENCLAW_HOST_PORT} -> container:${OPENCLAW_PORT}"
log "  vLLM URL   : ${VLLM_BASE_URL}"
log "  Model      : ${VLLM_MODEL_NAME}"
log "  API Key    : ${VLLM_API_KEY:0:4}****"
log "  Max tokens : ${VLLM_MAX_TOKENS}"
log "  Temperature: ${VLLM_TEMPERATURE}"
log "======================================================="

"${RUNTIME}" run -d \
    --name "${CONTAINER_NAME}" \
    --network "${NETWORK_NAME}" \
    --hostname openclaw \
    --network-alias openclaw \
    --restart unless-stopped \
    -p "${OPENCLAW_HOST_PORT:-18789}:${OPENCLAW_PORT:-18789}" \
    -e "VLLM_BASE_URL=${VLLM_BASE_URL}" \
    -e "VLLM_API_KEY=${VLLM_API_KEY}" \
    -e "VLLM_MODEL_NAME=${VLLM_MODEL_NAME}" \
    -e "VLLM_MAX_TOKENS=${VLLM_MAX_TOKENS}" \
    -e "VLLM_TEMPERATURE=${VLLM_TEMPERATURE}" \
    -e "VLLM_HEALTH_RETRIES=${VLLM_HEALTH_RETRIES:-60}" \
    -e "VLLM_HEALTH_INTERVAL=${VLLM_HEALTH_INTERVAL:-5}" \
    -e "OPENCLAW_PORT=${OPENCLAW_PORT}" \
    -e "OPENCLAW_HOST=0.0.0.0" \
    -e "OPENAI_API_BASE=${VLLM_BASE_URL}" \
    -e "OPENAI_BASE_URL=${VLLM_BASE_URL}" \
    -e "OPENAI_API_KEY=${VLLM_API_KEY}" \
    -e "OPENAI_MODEL=${VLLM_MODEL_NAME}" \
    -e "OPENCLAW_LLM_PROVIDER=openai-compatible" \
    -e "OPENCLAW_LLM_BASE_URL=${VLLM_BASE_URL}" \
    -e "OPENCLAW_LLM_API_KEY=${VLLM_API_KEY}" \
    -e "OPENCLAW_LLM_MODEL=${VLLM_MODEL_NAME}" \
    -e "OPENCLAW_LLM_MAX_TOKENS=${VLLM_MAX_TOKENS}" \
    -e "OPENCLAW_LLM_TEMPERATURE=${VLLM_TEMPERATURE}" \
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

        # -----------------------------------------------------------------
        # Validate the vLLM provider connection from within/alongside the
        # OpenClaw container before declaring the assistant fully ready.
        # validate_connection.sh queries /v1/models via the internal
        # container network to confirm the provider link is live.
        # A non-zero exit is treated as a warning — OpenClaw is running
        # but the vLLM backend may not yet be serving requests.
        # -----------------------------------------------------------------
        log "Running provider connection validation (validate_connection.sh --exec) ..."
        if bash "${SCRIPT_DIR}/validate_connection.sh" --exec; then
            log "Provider connection confirmed — OpenClaw is fully ready."
        else
            warn "Provider connection check returned non-zero."
            warn "OpenClaw dashboard is up but the vLLM backend may not be ready yet."
            warn "Re-run when vLLM is healthy: ./scripts/validate_connection.sh --exec"
            warn "Or check the host port     : ./scripts/validate_connection.sh --host"
        fi

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
