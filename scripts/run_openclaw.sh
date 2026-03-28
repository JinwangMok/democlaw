#!/usr/bin/env bash
# =============================================================================
# run_openclaw.sh — Launch the OpenClaw AI assistant container connected to
#                   the vLLM server via an OpenAI-compatible endpoint.
#
# Supports both docker and podman on Linux hosts.
# The OpenClaw web dashboard is published to the host on a configurable port.
#
# What this script does:
#   1. Validate host OS (Linux only)
#   2. Detect container runtime (docker or podman)
#   3. Ensure the shared container network exists
#   4. Verify the vLLM container is running and reachable on the shared network
#   5. Build the OpenClaw image if not already present
#   6. Launch the OpenClaw container with:
#        • vLLM endpoint env vars (VLLM_BASE_URL, VLLM_API_KEY, VLLM_MODEL_NAME)
#        • OpenAI-compatible env vars (OPENAI_API_BASE, OPENAI_BASE_URL, etc.)
#        • OpenClaw-specific env vars (OPENCLAW_LLM_PROVIDER, OPENCLAW_LLM_*)
#        • Shared network attachment so "vllm" hostname resolves
#        • Dashboard port published on the host
#   7. Wait for the OpenClaw dashboard to become available
#
# Usage:
#   ./scripts/run_openclaw.sh                              # auto-detect runtime, port 18789
#   OPENCLAW_HOST_PORT=8080 ./scripts/run_openclaw.sh      # expose dashboard on host port 8080
#   CONTAINER_RUNTIME=podman ./scripts/run_openclaw.sh     # force podman
#   VLLM_HOST_PORT=9000 ./scripts/run_openclaw.sh          # vLLM published on a non-default port
#
# Key environment variables (all have sensible defaults):
#   CONTAINER_RUNTIME         docker | podman  (auto-detected if unset)
#   VLLM_BASE_URL             OpenAI-compatible endpoint inside the shared network
#                             (default: http://vllm:8000/v1)
#   VLLM_API_KEY              API key passed to OpenClaw (default: EMPTY)
#   VLLM_MODEL_NAME           Model ID for OpenClaw to request (default: Qwen/Qwen3.5-9B-AWQ)
#   VLLM_MAX_TOKENS           Max response tokens            (default: 4096)
#   VLLM_TEMPERATURE          Sampling temperature           (default: 0.7)
#   VLLM_HEALTH_RETRIES       Max attempts to reach vLLM     (default: 60)
#   VLLM_HEALTH_INTERVAL      Seconds between retries        (default: 5)
#   OPENCLAW_PORT             Container-internal dashboard port (default: 18789)
#   OPENCLAW_HOST_PORT        Dashboard port published on host  (default: 18789)
#   OPENCLAW_CONTAINER_NAME   Container name                 (default: democlaw-openclaw)
#   OPENCLAW_IMAGE_TAG        Image tag to build/use         (default: democlaw/openclaw:latest)
#   VLLM_CONTAINER_NAME       vLLM container name for checks (default: democlaw-vllm)
#   DEMOCLAW_NETWORK          Shared network name            (default: democlaw-net)
#   OPENCLAW_HEALTH_TIMEOUT   Seconds to wait for dashboard  (default: 120)
#
# The OpenClaw dashboard will be available at:
#   http://localhost:<OPENCLAW_HOST_PORT>
#
# The vLLM endpoint is routed inside the container network as:
#   http://vllm:<VLLM_PORT>/v1  (resolved via the "vllm" network alias)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Locate project root and scripts directory
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { echo "[run_openclaw] $*"; }
warn()  { echo "[run_openclaw] WARNING: $*" >&2; }
error() { printf "[run_openclaw] ERROR: %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load .env file if present (key=value, one per line; no export needed here)
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
# Configurable defaults
# All values can be overridden by environment variables or .env file.
# ---------------------------------------------------------------------------

# --- vLLM endpoint (inside the shared container network) ---
# VLLM_BASE_URL references the vLLM container by its network alias "vllm" so
# that container-to-container traffic stays on the shared bridge network.
VLLM_BASE_URL="${VLLM_BASE_URL:-http://vllm:8000/v1}"
VLLM_API_KEY="${VLLM_API_KEY:-EMPTY}"
VLLM_MODEL_NAME="${VLLM_MODEL_NAME:-Qwen/Qwen3.5-9B-AWQ}"
VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-4096}"
VLLM_TEMPERATURE="${VLLM_TEMPERATURE:-0.7}"

# --- vLLM readiness wait parameters (used by the entrypoint inside the container) ---
VLLM_HEALTH_RETRIES="${VLLM_HEALTH_RETRIES:-60}"
VLLM_HEALTH_INTERVAL="${VLLM_HEALTH_INTERVAL:-5}"

# --- OpenClaw dashboard port ---
# OPENCLAW_PORT      : port the dashboard listens on inside the container
# OPENCLAW_HOST_PORT : port published on the Linux host for browser access
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_HOST_PORT="${OPENCLAW_HOST_PORT:-18789}"

# --- Container / image ---
CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-democlaw-openclaw}"
IMAGE_TAG="${OPENCLAW_IMAGE_TAG:-democlaw/openclaw:latest}"
NETWORK_NAME="${DEMOCLAW_NETWORK:-democlaw-net}"

# --- vLLM container name for pre-flight checks ---
VLLM_CONTAINER_NAME="${VLLM_CONTAINER_NAME:-democlaw-vllm}"

# --- Dashboard availability wait (host-side, after container starts) ---
OPENCLAW_HEALTH_TIMEOUT="${OPENCLAW_HEALTH_TIMEOUT:-120}"

# ---------------------------------------------------------------------------
# Step 0: Linux-only guard
# This stack is Linux-exclusive; the NVIDIA container toolkit and container
# networking behaviour assumed here are not available on macOS or Windows.
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Linux" ]; then
    error "Linux host required (detected: $(uname -s)).
  This script uses Linux-specific container networking to connect OpenClaw
  to the vLLM container on the shared bridge network.
  macOS and Windows are not supported."
fi

log "Host OS: Linux $(uname -r)"

# ---------------------------------------------------------------------------
# Step 1: Detect container runtime (docker or podman)
# Delegates to the shared runtime detection library which:
#   • Respects the CONTAINER_RUNTIME override
#   • Auto-detects docker (preferred) then podman
#   • Sets RUNTIME and RUNTIME_IS_PODMAN
# ---------------------------------------------------------------------------
_rt_log()   { log "$@"; }
_rt_warn()  { warn "$@"; }
_rt_error() { error "$@"; }

# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

log "Container runtime: ${RUNTIME} (podman=${RUNTIME_IS_PODMAN})"

# ---------------------------------------------------------------------------
# Step 2: Ensure the shared container network exists
#
# Both the vLLM container (alias: "vllm") and the OpenClaw container attach
# to this network.  OpenClaw resolves the vLLM endpoint as:
#   http://vllm:<port>/v1
# which is only reachable when both containers share this bridge network.
# ---------------------------------------------------------------------------
log "Ensuring shared network '${NETWORK_NAME}' exists ..."
# runtime_ensure_network() from lib/runtime.sh is idempotent:
#   creates the bridge network if absent, no-ops if it already exists.
# Works identically on docker and podman.
runtime_ensure_network "${NETWORK_NAME}"

# ---------------------------------------------------------------------------
# Step 3: Verify the vLLM container is running and on the shared network
#
# OpenClaw's container entrypoint will retry the vLLM health endpoint
# internally (up to VLLM_HEALTH_RETRIES × VLLM_HEALTH_INTERVAL seconds),
# so a missing vLLM container here is a warning rather than a hard error.
# This check gives the operator early, actionable feedback.
# ---------------------------------------------------------------------------
log "Verifying vLLM container '${VLLM_CONTAINER_NAME}' ..."

if ! "${RUNTIME}" container inspect "${VLLM_CONTAINER_NAME}" > /dev/null 2>&1; then
    warn "vLLM container '${VLLM_CONTAINER_NAME}' does not exist."
    warn "OpenClaw will start but will wait internally for vLLM to become available."
    warn "Start vLLM first with:  ./scripts/run_vllm.sh"
    warn ""
else
    vllm_state=$("${RUNTIME}" container inspect \
        --format '{{.State.Status}}' "${VLLM_CONTAINER_NAME}" 2>/dev/null \
        || echo "unknown")

    if [ "${vllm_state}" != "running" ]; then
        warn "vLLM container '${VLLM_CONTAINER_NAME}' is not running (state: ${vllm_state})."
        warn "OpenClaw will start and wait for vLLM at: ${VLLM_BASE_URL}"
        warn "Start vLLM with:  ./scripts/run_vllm.sh"
        warn ""
    else
        # Verify the vLLM container is attached to the shared network so the
        # "vllm" hostname alias resolves within OpenClaw's network scope.
        vllm_networks=$("${RUNTIME}" container inspect \
            --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
            "${VLLM_CONTAINER_NAME}" 2>/dev/null | tr -s ' ' || echo "")

        if echo "${vllm_networks}" | grep -qw "${NETWORK_NAME}"; then
            log "vLLM container is running and attached to '${NETWORK_NAME}'."
            log "OpenClaw will reach vLLM via network alias: ${VLLM_BASE_URL}"
        else
            warn "vLLM container '${VLLM_CONTAINER_NAME}' is running but NOT on '${NETWORK_NAME}'."
            warn "Attached networks: ${vllm_networks:-<none detected>}"
            warn "The hostname 'vllm' may not resolve inside OpenClaw."
            warn "Ensure vLLM was started with:  ./scripts/run_vllm.sh"
            warn ""
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Step 4: Handle existing container (idempotent)
#
# If a container with this name is already running, report its status and
# exit cleanly.  If a stopped/failed container exists, remove it so the
# fresh launch can proceed.
# ---------------------------------------------------------------------------
if "${RUNTIME}" container inspect "${CONTAINER_NAME}" > /dev/null 2>&1; then
    container_state=$("${RUNTIME}" container inspect \
        --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

    case "${container_state}" in
        running)
            log "Container '${CONTAINER_NAME}' is already running."
            log "  Dashboard: http://localhost:${OPENCLAW_HOST_PORT}"
            log "  To restart: ${RUNTIME} rm -f ${CONTAINER_NAME} && $0"
            exit 0
            ;;
        *)
            log "Removing existing container '${CONTAINER_NAME}' (state: ${container_state}) ..."
            "${RUNTIME}" rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Step 5: Build the OpenClaw image if not already present
#
# The Dockerfile is at <project_root>/openclaw/Dockerfile and builds an
# Ubuntu 24.04 image with Node.js and the openclaw npm package.
# ---------------------------------------------------------------------------
if ! "${RUNTIME}" image inspect "${IMAGE_TAG}" > /dev/null 2>&1; then
    log "Image '${IMAGE_TAG}' not found — building from ${PROJECT_ROOT}/openclaw ..."
    "${RUNTIME}" build -t "${IMAGE_TAG}" "${PROJECT_ROOT}/openclaw"
    log "Image '${IMAGE_TAG}' built successfully."
else
    log "Image '${IMAGE_TAG}' already exists."
fi

# ---------------------------------------------------------------------------
# Step 6: Launch the OpenClaw container
#
# Key flags explained:
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
#       VLLM_API_KEY            API key (vLLM accepts any non-empty value)
#       VLLM_MODEL_NAME         Model ID to request (must match vLLM's served model)
#       VLLM_MAX_TOKENS         Max tokens per response
#       VLLM_TEMPERATURE        Sampling temperature
#       VLLM_HEALTH_RETRIES     How many times to retry the vLLM health probe
#       VLLM_HEALTH_INTERVAL    Seconds between health probe retries
#   ② Standard OpenAI SDK env vars (honoured by openai / LangChain / LiteLLM):
#       OPENAI_API_BASE         (legacy LangChain convention)
#       OPENAI_BASE_URL         (current openai-node / openai-python convention)
#       OPENAI_API_KEY          Must be non-empty; vLLM accepts any value
#       OPENAI_MODEL            Model ID for client libraries that read this var
#   ③ OpenClaw-specific env vars (OPENCLAW_LLM_*):
#       OPENCLAW_LLM_PROVIDER   "openai-compatible" selects vLLM as the backend
#       OPENCLAW_LLM_BASE_URL   Mirrors VLLM_BASE_URL
#       OPENCLAW_LLM_API_KEY    Mirrors VLLM_API_KEY
#       OPENCLAW_LLM_MODEL      Mirrors VLLM_MODEL_NAME
#       OPENCLAW_LLM_MAX_TOKENS Mirrors VLLM_MAX_TOKENS
#       OPENCLAW_LLM_TEMPERATURE Mirrors VLLM_TEMPERATURE
#
#   Security flags:
#   --cap-drop ALL              Drop all Linux capabilities (minimal surface)
#   --security-opt no-new-privileges  Prevent privilege escalation
#   --read-only                 Read-only root filesystem
#   --tmpfs /tmp                Writable tmpfs for runtime temp files
#   --tmpfs /app/config         Writable tmpfs for entrypoint-generated config.json
# ---------------------------------------------------------------------------
log "======================================================="
log "  Launching OpenClaw container"
log "======================================================="
log "  Container  : ${CONTAINER_NAME}"
log "  Image      : ${IMAGE_TAG}"
log "  Network    : ${NETWORK_NAME} (alias: openclaw)"
log "  Dashboard  : host:${OPENCLAW_HOST_PORT} -> container:${OPENCLAW_PORT}"
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
    -p "${OPENCLAW_HOST_PORT}:${OPENCLAW_PORT}" \
    -e "VLLM_BASE_URL=${VLLM_BASE_URL}" \
    -e "VLLM_API_KEY=${VLLM_API_KEY}" \
    -e "VLLM_MODEL_NAME=${VLLM_MODEL_NAME}" \
    -e "VLLM_MAX_TOKENS=${VLLM_MAX_TOKENS}" \
    -e "VLLM_TEMPERATURE=${VLLM_TEMPERATURE}" \
    -e "VLLM_HEALTH_RETRIES=${VLLM_HEALTH_RETRIES}" \
    -e "VLLM_HEALTH_INTERVAL=${VLLM_HEALTH_INTERVAL}" \
    -e "OPENCLAW_PORT=${OPENCLAW_PORT}" \
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

log "Container '${CONTAINER_NAME}' started."
log ""
log "OpenClaw is starting up and waiting for the vLLM server ..."
log "Monitor progress with:"
log "  ${RUNTIME} logs -f ${CONTAINER_NAME}"
log ""

# ---------------------------------------------------------------------------
# Step 7: Wait for the OpenClaw dashboard to become available on the host
#
# The container entrypoint waits for vLLM readiness before starting OpenClaw,
# so this host-side poll accounts for both vLLM startup time and OpenClaw's
# own initialisation.
# ---------------------------------------------------------------------------
DASHBOARD_URL="http://localhost:${OPENCLAW_HOST_PORT}"
HEALTH_INTERVAL=3
elapsed=0

log "Waiting for OpenClaw dashboard at ${DASHBOARD_URL} (timeout: ${OPENCLAW_HEALTH_TIMEOUT}s) ..."

while [ "${elapsed}" -lt "${OPENCLAW_HEALTH_TIMEOUT}" ]; do
    # Check the container hasn't crashed
    if ! "${RUNTIME}" container inspect "${CONTAINER_NAME}" > /dev/null 2>&1; then
        error "Container '${CONTAINER_NAME}' exited unexpectedly.
  Check logs:  ${RUNTIME} logs ${CONTAINER_NAME}"
    fi

    current_state=$("${RUNTIME}" container inspect \
        --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

    if [ "${current_state}" = "exited" ] || [ "${current_state}" = "dead" ]; then
        error "Container '${CONTAINER_NAME}' has stopped (state: ${current_state}).
  Check logs:  ${RUNTIME} logs ${CONTAINER_NAME}"
    fi

    # Try to reach the dashboard on the published host port
    if curl -sf -o /dev/null -w '' "${DASHBOARD_URL}" 2>/dev/null; then
        log ""
        log "============================================="
        log "  OpenClaw dashboard is ready!"
        log "  URL: ${DASHBOARD_URL}"
        log "============================================="
        log ""
        log "vLLM OpenAI-compatible endpoint (from host):"
        log "  http://localhost:${VLLM_HOST_PORT:-8000}/v1"
        log ""
        log "To stop both containers:"
        log "  ./scripts/stop.sh"
        log ""
        exit 0
    fi

    sleep "${HEALTH_INTERVAL}"
    elapsed=$((elapsed + HEALTH_INTERVAL))

    # Progress message every 15 seconds
    if [ $((elapsed % 15)) -eq 0 ]; then
        log "  ... waiting for dashboard (${elapsed}/${OPENCLAW_HEALTH_TIMEOUT}s) — OpenClaw may still be waiting for vLLM"
    fi
done

# ---------------------------------------------------------------------------
# Timeout — dashboard didn't respond in time
# The container may still be waiting for the vLLM model to finish loading.
# ---------------------------------------------------------------------------
warn "OpenClaw dashboard did not respond within ${OPENCLAW_HEALTH_TIMEOUT}s."
warn "The container is still running — it may be waiting for vLLM to load the model."
warn ""
warn "  Dashboard URL : ${DASHBOARD_URL}"
warn "  OpenClaw logs : ${RUNTIME} logs -f ${CONTAINER_NAME}"
warn "  vLLM logs     : ${RUNTIME} logs -f ${VLLM_CONTAINER_NAME}"
warn ""
warn "The Qwen3.5-9B AWQ model can take several minutes to load on first run."
warn "Re-check the dashboard in a few minutes, or increase OPENCLAW_HEALTH_TIMEOUT:"
warn "  OPENCLAW_HEALTH_TIMEOUT=300 ./scripts/run_openclaw.sh"
warn ""
warn "If vLLM is not yet running, start it first:"
warn "  ./scripts/run_vllm.sh"
exit 1
