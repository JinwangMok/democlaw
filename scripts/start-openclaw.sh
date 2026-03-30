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
IMAGE_TAG="${OPENCLAW_IMAGE_TAG:-docker.io/jinwangmok/democlaw-openclaw:v1.0.0}"

# Port mapping — container listens on OPENCLAW_PORT, host exposes OPENCLAW_HOST_PORT
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_HOST_PORT="${OPENCLAW_HOST_PORT:-18789}"

# ---------------------------------------------------------------------------
# OpenAI-compatible endpoint env vars — passed into the OpenClaw container
# ---------------------------------------------------------------------------
# Three variables define the core provider connection:
#
#   LLAMACPP_BASE_URL   : API base URL using the llama.cpp container's network alias.
#                     "llamacpp" resolves inside the shared bridge network so
#                     OpenClaw reaches llama.cpp via container-to-container DNS.
#                     Format: http://<hostname>:<port>/v1
#                     Default: http://llamacpp:8000/v1
#
#   LLAMACPP_MODEL_NAME : Model ID that OpenClaw sends in every API request.
#                     Must match the model served by llama.cpp.
#                     Default: Qwen/Qwen3.5-9B-AWQ  (AWQ 4-bit, 8 GB VRAM)
#
#   LLAMACPP_API_KEY    : Placeholder API key.  llama.cpp accepts any non-empty value
#                     by default; use "EMPTY" as the conventional placeholder.
#                     Default: EMPTY
#
# Additional llama.cpp provider vars:
#   LLAMACPP_MAX_TOKENS   : Maximum tokens per response (default: 4096)
#   LLAMACPP_TEMPERATURE  : Sampling temperature (default: 0.7)
#
# Standard OpenAI SDK env vars (honoured by openai, LangChain, LiteLLM, …):
#   OPENAI_API_BASE / OPENAI_BASE_URL  — mirror LLAMACPP_BASE_URL
#   OPENAI_API_KEY                     — mirror LLAMACPP_API_KEY
#   OPENAI_MODEL                       — mirror LLAMACPP_MODEL_NAME
#
# OpenClaw-specific env vars (secondary lookup path):
#   OPENCLAW_LLM_PROVIDER / OPENCLAW_LLM_BASE_URL / OPENCLAW_LLM_API_KEY
#   OPENCLAW_LLM_MODEL / OPENCLAW_LLM_MAX_TOKENS / OPENCLAW_LLM_TEMPERATURE
# ---------------------------------------------------------------------------
LLAMACPP_BASE_URL="${LLAMACPP_BASE_URL:-http://llamacpp:8000/v1}"
LLAMACPP_API_KEY="${LLAMACPP_API_KEY:-EMPTY}"
LLAMACPP_MODEL_NAME="${LLAMACPP_MODEL_NAME:-Qwen/Qwen3.5-9B-AWQ}"
LLAMACPP_MAX_TOKENS="${LLAMACPP_MAX_TOKENS:-4096}"
LLAMACPP_TEMPERATURE="${LLAMACPP_TEMPERATURE:-0.7}"

# llama.cpp container name — used for network-membership verification before launch
LLAMACPP_CONTAINER_NAME="${LLAMACPP_CONTAINER_NAME:-democlaw-llamacpp}"

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
# Both the llama.cpp container (network alias: "llamacpp") and this OpenClaw container
# attach to this network so that OpenClaw can resolve llama.cpp by name:
#   http://llamacpp:${LLAMACPP_PORT}/v1
# ---------------------------------------------------------------------------
runtime_ensure_network "${NETWORK_NAME}"

# ---------------------------------------------------------------------------
# verify_llamacpp_network_membership — Ensure the llama.cpp container is running and
#   connected to the shared network so that http://llamacpp:<port>/v1 is reachable
#   from the OpenClaw container once it starts.
#
# This is the "endpoint reachability" check for Sub-AC 3c:
#   - Confirms the llama.cpp container exists and is in "running" state.
#   - Confirms the llama.cpp container is attached to NETWORK_NAME so that its
#     network alias "llamacpp" resolves within the shared bridge network.
#   - Emits a clear warning (rather than a hard exit) when llama.cpp is absent,
#     because the OpenClaw entrypoint already retries the llama.cpp health probe
#     internally (LLAMACPP_HEALTH_RETRIES / LLAMACPP_HEALTH_INTERVAL env vars).
# ---------------------------------------------------------------------------
verify_llamacpp_network_membership() {
    log "Verifying llama.cpp endpoint reachability on network '${NETWORK_NAME}' ..."
    log "  llama.cpp container : ${LLAMACPP_CONTAINER_NAME}"
    log "  llama.cpp endpoint  : ${LLAMACPP_BASE_URL}"

    # -----------------------------------------------------------------------
    # Step 1: llama.cpp container existence check
    # -----------------------------------------------------------------------
    if ! "${RUNTIME}" container inspect "${LLAMACPP_CONTAINER_NAME}" > /dev/null 2>&1; then
        warn "llama.cpp container '${LLAMACPP_CONTAINER_NAME}' does not exist."
        warn "OpenClaw will start, but it will wait for llama.cpp to become available."
        warn "Start llama.cpp with: ./scripts/start-llamacpp.sh"
        warn ""
        return 0
    fi

    # -----------------------------------------------------------------------
    # Step 2: llama.cpp container running state check
    # -----------------------------------------------------------------------
    local llamacpp_state
    llamacpp_state=$("${RUNTIME}" container inspect \
        --format '{{.State.Status}}' "${LLAMACPP_CONTAINER_NAME}" 2>/dev/null \
        || echo "unknown")

    if [ "${llamacpp_state}" != "running" ]; then
        warn "llama.cpp container '${LLAMACPP_CONTAINER_NAME}' exists but is not running (state: ${llamacpp_state})."
        warn "OpenClaw will start and wait for llama.cpp at: ${LLAMACPP_BASE_URL}"
        warn "Start llama.cpp with: ./scripts/start-llamacpp.sh"
        warn ""
        return 0
    fi

    # -----------------------------------------------------------------------
    # Step 3: Verify llama.cpp is attached to the shared container network so its
    #   hostname alias ("llamacpp") resolves from within OpenClaw's network scope.
    # -----------------------------------------------------------------------
    local llamacpp_networks
    llamacpp_networks=$("${RUNTIME}" container inspect \
        --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
        "${LLAMACPP_CONTAINER_NAME}" 2>/dev/null | tr -s ' ' || echo "")

    if echo "${llamacpp_networks}" | grep -qw "${NETWORK_NAME}"; then
        log "llama.cpp container '${LLAMACPP_CONTAINER_NAME}' is running and attached to '${NETWORK_NAME}'."
        log "OpenClaw will reach llama.cpp via the shared network alias: ${LLAMACPP_BASE_URL}"
    else
        warn "llama.cpp container '${LLAMACPP_CONTAINER_NAME}' is running but is NOT connected to '${NETWORK_NAME}'."
        warn "Attached networks: ${llamacpp_networks:-<none detected>}"
        warn "The hostname 'llamacpp' may not resolve from within OpenClaw's network."
        warn "Ensure the llama.cpp container was started with: ./scripts/start-llamacpp.sh"
        warn "(which always connects it to '${NETWORK_NAME}' with alias 'llamacpp')"
        warn ""
    fi
}

verify_llamacpp_network_membership

# ---------------------------------------------------------------------------
# Handle existing container (idempotent destroy-and-recreate)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Idempotent container teardown: ALWAYS destroy and recreate.
# This ensures every run produces an identical end-state regardless of prior
# state — running, stopped, paused, or dead containers are all removed.
# ---------------------------------------------------------------------------
handle_existing_container() {
    if "${RUNTIME}" container inspect "${CONTAINER_NAME}" > /dev/null 2>&1; then
        local state
        state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null \
               || "${RUNTIME}" container inspect --format '{{.State.Status}}' "${CONTAINER_NAME}")

        log "Removing existing container '${CONTAINER_NAME}' (state: ${state}) for fresh recreation ..."
        "${RUNTIME}" rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
    fi
}

handle_existing_container

# ---------------------------------------------------------------------------
# Acquire OpenClaw image (pull from Docker Hub first; local build fallback)
#
# Strategy: Always attempt to pull the pre-built image from Docker Hub.
# If pull fails (non-zero exit), fall back to building from the local
# Dockerfile at <project_root>/openclaw/Dockerfile.
# ---------------------------------------------------------------------------
_img_log()   { log "$@"; }
_img_warn()  { warn "$@"; }
_img_error() { error "$@"; }
source "${SCRIPT_DIR}/lib/image.sh"

ensure_image "${IMAGE_TAG}" "${PROJECT_ROOT}/openclaw"

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
#   ① llama.cpp-specific vars consumed by the container entrypoint:
#       LLAMACPP_BASE_URL           URL of the OpenAI-compatible API endpoint
#       LLAMACPP_API_KEY            Placeholder API key (llama.cpp accepts any value)
#       LLAMACPP_MODEL_NAME         Model ID to request (must match llama.cpp's model)
#       LLAMACPP_MAX_TOKENS         Max tokens per response
#       LLAMACPP_TEMPERATURE        Sampling temperature
#       LLAMACPP_HEALTH_RETRIES     How many times to retry the llama.cpp health probe
#       LLAMACPP_HEALTH_INTERVAL    Seconds between health probe retries
#   ② Standard OpenAI SDK env vars (openai-node / openai-python / LangChain):
#       OPENAI_API_BASE         Legacy LangChain convention
#       OPENAI_BASE_URL         Current openai SDK convention
#       OPENAI_API_KEY          Must be non-empty; llama.cpp accepts any value
#       OPENAI_MODEL            Model ID for SDK clients that read this var
#   ③ OpenClaw-specific env vars (secondary lookup path):
#       OPENCLAW_LLM_PROVIDER   "openai-compatible" selects llama.cpp as backend
#       OPENCLAW_LLM_BASE_URL   Mirrors LLAMACPP_BASE_URL
#       OPENCLAW_LLM_API_KEY    Mirrors LLAMACPP_API_KEY
#       OPENCLAW_LLM_MODEL      Mirrors LLAMACPP_MODEL_NAME
#       OPENCLAW_LLM_MAX_TOKENS Mirrors LLAMACPP_MAX_TOKENS
#       OPENCLAW_LLM_TEMPERATURE Mirrors LLAMACPP_TEMPERATURE
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
log "  llama.cpp URL   : ${LLAMACPP_BASE_URL}"
log "  Model      : ${LLAMACPP_MODEL_NAME}"
log "  API Key    : ${LLAMACPP_API_KEY:0:4}****"
log "  Max tokens : ${LLAMACPP_MAX_TOKENS}"
log "  Temperature: ${LLAMACPP_TEMPERATURE}"
log "======================================================="

"${RUNTIME}" run -d \
    --name "${CONTAINER_NAME}" \
    --network "${NETWORK_NAME}" \
    --hostname openclaw \
    --network-alias openclaw \
    --restart unless-stopped \
    -p "${OPENCLAW_HOST_PORT:-18789}:${OPENCLAW_PORT:-18789}" \
    -e "LLAMACPP_BASE_URL=${LLAMACPP_BASE_URL}" \
    -e "LLAMACPP_API_KEY=${LLAMACPP_API_KEY}" \
    -e "LLAMACPP_MODEL_NAME=${LLAMACPP_MODEL_NAME}" \
    -e "LLAMACPP_MAX_TOKENS=${LLAMACPP_MAX_TOKENS}" \
    -e "LLAMACPP_TEMPERATURE=${LLAMACPP_TEMPERATURE}" \
    -e "LLAMACPP_HEALTH_RETRIES=${LLAMACPP_HEALTH_RETRIES:-60}" \
    -e "LLAMACPP_HEALTH_INTERVAL=${LLAMACPP_HEALTH_INTERVAL:-5}" \
    -e "OPENCLAW_PORT=${OPENCLAW_PORT}" \
    -e "OPENCLAW_HOST=0.0.0.0" \
    -e "OPENAI_API_BASE=${LLAMACPP_BASE_URL}" \
    -e "OPENAI_BASE_URL=${LLAMACPP_BASE_URL}" \
    -e "OPENAI_API_KEY=${LLAMACPP_API_KEY}" \
    -e "OPENAI_MODEL=${LLAMACPP_MODEL_NAME}" \
    -e "OPENCLAW_LLM_PROVIDER=openai-compatible" \
    -e "OPENCLAW_LLM_BASE_URL=${LLAMACPP_BASE_URL}" \
    -e "OPENCLAW_LLM_API_KEY=${LLAMACPP_API_KEY}" \
    -e "OPENCLAW_LLM_MODEL=${LLAMACPP_MODEL_NAME}" \
    -e "OPENCLAW_LLM_MAX_TOKENS=${LLAMACPP_MAX_TOKENS}" \
    -e "OPENCLAW_LLM_TEMPERATURE=${LLAMACPP_TEMPERATURE}" \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid \
    --tmpfs /app/config:rw,noexec,nosuid,uid=1000,gid=1000 \
    --tmpfs /home/openclaw:rw,noexec,nosuid,uid=1000,gid=1000 \
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

    # Try to reach the dashboard on the published host port — require HTTP 200
    oc_http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${DASHBOARD_URL}/" 2>/dev/null || echo "000")
    if [ "${oc_http_code}" = "200" ]; then
        log ""
        log "============================================="
        log "  OpenClaw dashboard is ready!"
        log "  URL: ${DASHBOARD_URL}"
        log "============================================="
        log ""

        # -----------------------------------------------------------------
        # Validate the llama.cpp provider connection from within/alongside the
        # OpenClaw container before declaring the assistant fully ready.
        # validate_connection.sh queries /v1/models via the internal
        # container network to confirm the provider link is live.
        # A non-zero exit is treated as a warning — OpenClaw is running
        # but the llama.cpp backend may not yet be serving requests.
        # -----------------------------------------------------------------
        log "Running provider connection validation (validate_connection.sh --exec) ..."
        if bash "${SCRIPT_DIR}/validate_connection.sh" --exec; then
            log "Provider connection confirmed — OpenClaw is fully ready."
        else
            warn "Provider connection check returned non-zero."
            warn "OpenClaw dashboard is up but the llama.cpp backend may not be ready yet."
            warn "Re-run when llama.cpp is healthy: ./scripts/validate_connection.sh --exec"
            warn "Or check the host port     : ./scripts/validate_connection.sh --host"
        fi

        # -----------------------------------------------------------------
        # Run the OpenClaw-specific healthcheck to confirm the service is
        # reachable and report a clear PASS / FAIL status to stdout.
        #
        # healthcheck_openclaw.sh polls the dashboard URL and exits 0 on
        # HTTP 200, so it will succeed immediately here since the dashboard
        # just responded above. The explicit PASS / FAIL message ensures the
        # operator sees an unambiguous status line in the start log.
        #
        # Note: when start-openclaw.sh is invoked by start.sh, the
        # comprehensive scripts/healthcheck.sh is also run as Phase 3 of
        # that orchestration — running the OpenClaw-specific check here
        # covers the standalone start-openclaw.sh use case.
        # -----------------------------------------------------------------
        log ""
        log "--- Running OpenClaw healthcheck (post-launch) ---"
        OPENCLAW_HC_EXIT=0
        bash "${SCRIPT_DIR}/healthcheck_openclaw.sh" || OPENCLAW_HC_EXIT=$?
        if [ "${OPENCLAW_HC_EXIT}" -eq 0 ]; then
            log "HEALTHCHECK PASS: OpenClaw service is healthy and reachable."
        else
            warn "HEALTHCHECK FAIL: OpenClaw healthcheck did not pass. See output above."
            warn "  Re-run at any time: ./scripts/healthcheck_openclaw.sh"
        fi
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
warn "The container is still running — it may be waiting for the llama.cpp server."
warn "  Dashboard URL : ${DASHBOARD_URL}"
warn "  Check logs    : ${RUNTIME} logs -f ${CONTAINER_NAME}"
warn ""
warn "If the llama.cpp server is not yet running, start it first:"
warn "  ./scripts/start-llamacpp.sh"
exit 1
