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
#   7. Post-start validation: wait for the healthcheck to pass and print
#      a SUCCESS or FAILURE message to the user
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
#   VLLM_MODEL_NAME           Model ID for OpenClaw to request (default: Qwen/Qwen2.5-7B-Instruct-AWQ)
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
# run_healthcheck — Invoke scripts/healthcheck.sh after the OpenClaw container
#                  is confirmed running and the dashboard is reachable.
#
# Prints a clear HEALTHCHECK PASS / HEALTHCHECK FAIL line to stdout so the
# operator knows immediately whether all services are healthy end-to-end.
# A non-zero healthcheck exit is reported as a warning but does NOT cause
# this script to exit non-zero — the container itself started successfully.
# ---------------------------------------------------------------------------
run_healthcheck() {
    log ""
    log "--- Running DemoClaw healthcheck (post-launch) ---"
    local hc_exit=0
    bash "${SCRIPT_DIR}/healthcheck.sh" || hc_exit=$?
    if [ "${hc_exit}" -eq 0 ]; then
        log ""
        log "HEALTHCHECK PASS: All services are healthy."
    else
        warn ""
        warn "HEALTHCHECK FAIL: One or more service checks did not pass."
        warn "  See the report above for details."
        warn "  Re-run at any time: ./scripts/healthcheck.sh"
    fi
    log ""
}

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
VLLM_MODEL_NAME="${VLLM_MODEL_NAME:-Qwen/Qwen2.5-7B-Instruct-AWQ}"
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

# --- vLLM host port (used in post-start success banners to show host endpoint) ---
VLLM_HOST_PORT="${VLLM_HOST_PORT:-8000}"

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

log "Container '${CONTAINER_NAME}' started."
log ""
log "OpenClaw is starting up and waiting for the vLLM server ..."
log "Monitor progress with:"
log "  ${RUNTIME} logs -f ${CONTAINER_NAME}"
log ""

# ---------------------------------------------------------------------------
# Step 7: Post-start validation — wait for the OpenClaw healthcheck to pass
#
# Waits for the OpenClaw container to be confirmed healthy and prints a clear
# SUCCESS or FAILURE message to the user.
#
# Two-layer validation strategy:
#
#   Layer 1 — HTTP reachability probe (fast feedback)
#     Polls http://localhost:<OPENCLAW_HOST_PORT> every HEALTH_POLL_INTERVAL
#     seconds.  Gives the operator quick confirmation once the Node.js server
#     is accepting connections (typically 10–30 s after container start).
#
#   Layer 2 — Container healthcheck confirmation (authoritative result)
#     Concurrently reads the container's built-in HEALTHCHECK status via
#     `container inspect .State.Health.Status`.  The Docker/Podman runtime
#     runs the /app/healthcheck.sh probe inside the container on a schedule
#     (--interval=30s, --start-period=60s) and updates this status field.
#     Possible values: "starting", "healthy", "unhealthy", or empty/"none"
#     (when no HEALTHCHECK instruction is present in the image).
#
#   Decision table:
#     hc_status = "healthy"   → SUCCESS banner, exit 0
#     hc_status = "unhealthy" → FAILURE banner, exit 1  (even if HTTP is up,
#                               the app-level probe detected a problem)
#     hc_status = "none"/""   → treat HTTP-up as success (no probe configured)
#     hc_status = "starting"  → keep waiting; healthcheck start-period not yet
#                               elapsed (60 s per Dockerfile)
#     timeout elapsed, HTTP up, hc_status = "starting"
#                             → SUCCESS with advisory note (dashboard works)
#     timeout elapsed, HTTP never responded
#                             → FAILURE banner with diagnostic hints
# ---------------------------------------------------------------------------
DASHBOARD_URL="http://localhost:${OPENCLAW_HOST_PORT}"
HEALTH_POLL_INTERVAL=3
elapsed=0
http_ready=false

log "Waiting for OpenClaw dashboard at ${DASHBOARD_URL} (timeout: ${OPENCLAW_HEALTH_TIMEOUT}s) ..."
log "Will validate using container healthcheck once the dashboard is reachable."

while [ "${elapsed}" -lt "${OPENCLAW_HEALTH_TIMEOUT}" ]; do
    # ---- Guard: ensure the container has not crashed ----
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

    # ---- Layer 2: read container HEALTHCHECK status ----
    hc_status=$("${RUNTIME}" container inspect \
        --format '{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null \
        || echo "none")

    # Unhealthy is an immediate, authoritative failure — exit early
    if [ "${hc_status}" = "unhealthy" ]; then
        warn ""
        warn "============================================="
        warn "  FAILURE: OpenClaw healthcheck is UNHEALTHY"
        warn "============================================="
        warn "  Container  : ${CONTAINER_NAME}"
        warn "  Dashboard  : ${DASHBOARD_URL}"
        warn "  Healthcheck: ${hc_status}"
        warn "============================================="
        warn ""
        warn "The container's built-in healthcheck (/app/healthcheck.sh) has failed."
        warn "Diagnose with:"
        warn "  ${RUNTIME} logs ${CONTAINER_NAME}"
        warn "  ${RUNTIME} inspect --format '{{json .State.Health}}' ${CONTAINER_NAME}"
        exit 1
    fi

    # ---- Layer 1: HTTP reachability probe ----
    if curl -sf -o /dev/null -w '' "${DASHBOARD_URL}" 2>/dev/null; then
        http_ready=true
    fi

    # ---- Decision: HTTP up + healthcheck status ----
    if [ "${http_ready}" = "true" ]; then
        case "${hc_status}" in
            healthy)
                log ""
                log "============================================="
                log "  SUCCESS: OpenClaw is healthy and ready!"
                log "============================================="
                log "  Container  : ${CONTAINER_NAME}"
                log "  Dashboard  : ${DASHBOARD_URL}"
                log "  Healthcheck: ${hc_status}"
                log "============================================="
                log ""
                log "vLLM OpenAI-compatible endpoint (from host):"
                log "  http://localhost:${VLLM_HOST_PORT:-8000}/v1"
                log ""
                log "To stop both containers:"
                log "  ./scripts/stop.sh"
                run_healthcheck
                exit 0
                ;;
            none|"")
                # Image has no HEALTHCHECK instruction — HTTP response is sufficient
                log ""
                log "============================================="
                log "  SUCCESS: OpenClaw dashboard is ready!"
                log "============================================="
                log "  Container  : ${CONTAINER_NAME}"
                log "  Dashboard  : ${DASHBOARD_URL}"
                log "  Healthcheck: not configured (HTTP 200 OK)"
                log "============================================="
                log ""
                log "vLLM OpenAI-compatible endpoint (from host):"
                log "  http://localhost:${VLLM_HOST_PORT:-8000}/v1"
                log ""
                log "To stop both containers:"
                log "  ./scripts/stop.sh"
                run_healthcheck
                exit 0
                ;;
            starting)
                # Healthcheck start-period (60 s per Dockerfile) not yet elapsed.
                # HTTP is already responding — keep polling for the authoritative result.
                ;;
        esac
    fi

    sleep "${HEALTH_POLL_INTERVAL}"
    elapsed=$((elapsed + HEALTH_POLL_INTERVAL))

    # Progress message every 15 seconds
    if [ $((elapsed % 15)) -eq 0 ]; then
        http_label=$([ "${http_ready}" = "true" ] && echo "up" || echo "waiting")
        log "  ... ${elapsed}/${OPENCLAW_HEALTH_TIMEOUT}s — http: ${http_label}, healthcheck: ${hc_status:-n/a}"
    fi
done

# ---------------------------------------------------------------------------
# Timeout reached — evaluate partial success vs full failure
#
# If HTTP was already responding when the timeout expired the dashboard IS
# reachable; the healthcheck just hasn't completed its start-period yet.
# Treat this as a soft success so the user can immediately open the browser.
# If HTTP never responded the service is definitely not ready — report failure.
# ---------------------------------------------------------------------------
hc_status_final=$("${RUNTIME}" container inspect \
    --format '{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null \
    || echo "unknown")

if [ "${http_ready}" = "true" ]; then
    log ""
    log "============================================="
    log "  SUCCESS: OpenClaw dashboard is responding."
    log "  (Healthcheck still confirming: ${hc_status_final})"
    log "============================================="
    log "  Container  : ${CONTAINER_NAME}"
    log "  Dashboard  : ${DASHBOARD_URL}"
    log "  Healthcheck: ${hc_status_final}"
    log "============================================="
    log ""
    log "The dashboard is accessible. The container healthcheck (start-period: 60 s)"
    log "may still be running its first probe — this is normal for large model loads."
    log "Monitor with:  ${RUNTIME} inspect --format '{{json .State.Health}}' ${CONTAINER_NAME}"
    log ""
    log "vLLM OpenAI-compatible endpoint (from host):"
    log "  http://localhost:${VLLM_HOST_PORT:-8000}/v1"
    log ""
    log "To stop both containers:"
    log "  ./scripts/stop.sh"
    run_healthcheck
    exit 0
fi

# Dashboard never responded — definitive failure
warn ""
warn "============================================="
warn "  FAILURE: OpenClaw did not become ready"
warn "  within ${OPENCLAW_HEALTH_TIMEOUT}s"
warn "============================================="
warn "  Dashboard  : ${DASHBOARD_URL}"
warn "  Healthcheck: ${hc_status_final}"
warn "  OpenClaw logs : ${RUNTIME} logs -f ${CONTAINER_NAME}"
warn "  vLLM logs     : ${RUNTIME} logs -f ${VLLM_CONTAINER_NAME}"
warn "============================================="
warn ""
warn "The Qwen3.5-9B AWQ model can take several minutes to load on first run."
warn "Re-check the dashboard in a few minutes, or increase OPENCLAW_HEALTH_TIMEOUT:"
warn "  OPENCLAW_HEALTH_TIMEOUT=300 ./scripts/run_openclaw.sh"
warn ""
warn "If vLLM is not yet running, start it first:"
warn "  ./scripts/run_vllm.sh"
exit 1
