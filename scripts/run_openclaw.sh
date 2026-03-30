#!/usr/bin/env bash
# =============================================================================
# run_openclaw.sh — Launch the OpenClaw AI assistant container connected to
#                   the llama.cpp server via an OpenAI-compatible endpoint.
#
# Supports both docker and podman on Linux hosts.
# The OpenClaw web dashboard is published to the host on a configurable port.
#
# What this script does:
#   1. Validate host OS (Linux only)
#   2. Detect container runtime (docker or podman)
#   3. Ensure the shared container network exists
#   4. Verify the llama.cpp container is running and reachable on the shared network
#   5. Build the OpenClaw image if not already present
#   6. Launch the OpenClaw container with:
#        • llama.cpp endpoint env vars (LLAMACPP_BASE_URL, LLAMACPP_API_KEY, LLAMACPP_MODEL_NAME)
#        • OpenAI-compatible env vars (OPENAI_API_BASE, OPENAI_BASE_URL, etc.)
#        • OpenClaw-specific env vars (OPENCLAW_LLM_PROVIDER, OPENCLAW_LLM_*)
#        • Shared network attachment so "llamacpp" hostname resolves
#        • Dashboard port published on the host
#   7. Post-start validation: wait for the healthcheck to pass and print
#      a SUCCESS or FAILURE message to the user
#
# Usage:
#   ./scripts/run_openclaw.sh                              # auto-detect runtime, port 18789
#   OPENCLAW_HOST_PORT=8080 ./scripts/run_openclaw.sh      # expose dashboard on host port 8080
#   CONTAINER_RUNTIME=podman ./scripts/run_openclaw.sh     # force podman
#   LLAMACPP_HOST_PORT=9000 ./scripts/run_openclaw.sh          # llama.cpp published on a non-default port
#
# Key environment variables (all have sensible defaults):
#   CONTAINER_RUNTIME         docker | podman  (auto-detected if unset)
#   LLAMACPP_BASE_URL             OpenAI-compatible endpoint inside the shared network
#                             (default: http://llamacpp:8000/v1)
#   LLAMACPP_API_KEY              API key passed to OpenClaw (default: EMPTY)
#   LLAMACPP_MODEL_NAME           Model ID for OpenClaw to request (default: Qwen/Qwen3-4B-AWQ)
#   LLAMACPP_MAX_TOKENS           Max response tokens            (default: 4096)
#   LLAMACPP_TEMPERATURE          Sampling temperature           (default: 0.7)
#   LLAMACPP_HEALTH_RETRIES       Max attempts to reach llama.cpp     (default: 60)
#   LLAMACPP_HEALTH_INTERVAL      Seconds between retries        (default: 5)
#   OPENCLAW_PORT             Container-internal dashboard port (default: 18789)
#   OPENCLAW_HOST_PORT        Dashboard port published on host  (default: 18789)
#   OPENCLAW_CONTAINER_NAME   Container name                 (default: democlaw-openclaw)
#   OPENCLAW_IMAGE_TAG        Image tag to build/use         (default: democlaw/openclaw:latest)
#   LLAMACPP_CONTAINER_NAME       llama.cpp container name for checks (default: democlaw-llamacpp)
#   DEMOCLAW_NETWORK          Shared network name            (default: democlaw-net)
#   OPENCLAW_HEALTH_TIMEOUT   Seconds to wait for dashboard  (default: 120)
#
# The OpenClaw dashboard will be available at:
#   http://localhost:<OPENCLAW_HOST_PORT>
#
# The llama.cpp endpoint is routed inside the container network as:
#   http://llamacpp:<LLAMACPP_PORT>/v1  (resolved via the "llamacpp" network alias)
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

# --- llama.cpp endpoint (inside the shared container network) ---
# LLAMACPP_BASE_URL references the llama.cpp container by its network alias "llamacpp" so
# that container-to-container traffic stays on the shared bridge network.
LLAMACPP_BASE_URL="${LLAMACPP_BASE_URL:-http://llamacpp:8000/v1}"
LLAMACPP_API_KEY="${LLAMACPP_API_KEY:-EMPTY}"
LLAMACPP_MODEL_NAME="${LLAMACPP_MODEL_NAME:-Qwen/Qwen3-4B-AWQ}"
LLAMACPP_MAX_TOKENS="${LLAMACPP_MAX_TOKENS:-4096}"
LLAMACPP_TEMPERATURE="${LLAMACPP_TEMPERATURE:-0.7}"

# --- llama.cpp readiness wait parameters (used by the entrypoint inside the container) ---
LLAMACPP_HEALTH_RETRIES="${LLAMACPP_HEALTH_RETRIES:-60}"
LLAMACPP_HEALTH_INTERVAL="${LLAMACPP_HEALTH_INTERVAL:-5}"

# --- OpenClaw dashboard port ---
# OPENCLAW_PORT      : port the dashboard listens on inside the container
# OPENCLAW_HOST_PORT : port published on the Linux host for browser access
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_HOST_PORT="${OPENCLAW_HOST_PORT:-18789}"

# --- Container / image ---
CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-democlaw-openclaw}"
IMAGE_TAG="${OPENCLAW_IMAGE_TAG:-docker.io/jinwangmok/democlaw-openclaw:v1.0.0}"
NETWORK_NAME="${DEMOCLAW_NETWORK:-democlaw-net}"

# --- llama.cpp container name for pre-flight checks ---
LLAMACPP_CONTAINER_NAME="${LLAMACPP_CONTAINER_NAME:-democlaw-llamacpp}"

# --- llama.cpp host port (used in post-start success banners to show host endpoint) ---
LLAMACPP_HOST_PORT="${LLAMACPP_HOST_PORT:-8000}"

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
  to the llama.cpp container on the shared bridge network.
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
# Both the llama.cpp container (alias: "llamacpp") and the OpenClaw container attach
# to this network.  OpenClaw resolves the llama.cpp endpoint as:
#   http://llamacpp:<port>/v1
# which is only reachable when both containers share this bridge network.
# ---------------------------------------------------------------------------
log "Ensuring shared network '${NETWORK_NAME}' exists ..."
# runtime_ensure_network() from lib/runtime.sh is idempotent:
#   creates the bridge network if absent, no-ops if it already exists.
# Works identically on docker and podman.
runtime_ensure_network "${NETWORK_NAME}"

# ---------------------------------------------------------------------------
# Step 3: Verify the llama.cpp container is running and on the shared network
#
# OpenClaw's container entrypoint will retry the llama.cpp health endpoint
# internally (up to LLAMACPP_HEALTH_RETRIES × LLAMACPP_HEALTH_INTERVAL seconds),
# so a missing llama.cpp container here is a warning rather than a hard error.
# This check gives the operator early, actionable feedback.
# ---------------------------------------------------------------------------
log "Verifying llama.cpp container '${LLAMACPP_CONTAINER_NAME}' ..."

if ! "${RUNTIME}" container inspect "${LLAMACPP_CONTAINER_NAME}" > /dev/null 2>&1; then
    warn "llama.cpp container '${LLAMACPP_CONTAINER_NAME}' does not exist."
    warn "OpenClaw will start but will wait internally for llama.cpp to become available."
    warn "Start llama.cpp first with:  ./scripts/run_llamacpp.sh"
    warn ""
else
    llamacpp_state=$("${RUNTIME}" container inspect \
        --format '{{.State.Status}}' "${LLAMACPP_CONTAINER_NAME}" 2>/dev/null \
        || echo "unknown")

    if [ "${llamacpp_state}" != "running" ]; then
        warn "llama.cpp container '${LLAMACPP_CONTAINER_NAME}' is not running (state: ${llamacpp_state})."
        warn "OpenClaw will start and wait for llama.cpp at: ${LLAMACPP_BASE_URL}"
        warn "Start llama.cpp with:  ./scripts/run_llamacpp.sh"
        warn ""
    else
        # Verify the llama.cpp container is attached to the shared network so the
        # "llamacpp" hostname alias resolves within OpenClaw's network scope.
        llamacpp_networks=$("${RUNTIME}" container inspect \
            --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
            "${LLAMACPP_CONTAINER_NAME}" 2>/dev/null | tr -s ' ' || echo "")

        if echo "${llamacpp_networks}" | grep -qw "${NETWORK_NAME}"; then
            log "llama.cpp container is running and attached to '${NETWORK_NAME}'."
            log "OpenClaw will reach llama.cpp via network alias: ${LLAMACPP_BASE_URL}"
        else
            warn "llama.cpp container '${LLAMACPP_CONTAINER_NAME}' is running but NOT on '${NETWORK_NAME}'."
            warn "Attached networks: ${llamacpp_networks:-<none detected>}"
            warn "The hostname 'llamacpp' may not resolve inside OpenClaw."
            warn "Ensure llama.cpp was started with:  ./scripts/run_llamacpp.sh"
            warn ""
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Step 4: Handle existing container (idempotent destroy-and-recreate)
#
# Every run must produce an identical end-state. Any pre-existing container
# — running, stopped, paused, or dead — is unconditionally removed so a
# fresh container is always created with the latest configuration.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Idempotent container teardown: ALWAYS destroy and recreate.
# This ensures every run produces an identical end-state regardless of prior
# state — running, stopped, paused, or dead containers are all removed.
# ---------------------------------------------------------------------------
if "${RUNTIME}" container inspect "${CONTAINER_NAME}" > /dev/null 2>&1; then
    container_state=$("${RUNTIME}" container inspect \
        --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")

    log "Removing existing container '${CONTAINER_NAME}' (state: ${container_state}) for fresh recreation ..."
    "${RUNTIME}" rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Step 5: Acquire OpenClaw image (pull from Docker Hub first; local build fallback)
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
#   ① llama.cpp-specific vars consumed by the container entrypoint:
#       LLAMACPP_BASE_URL           URL of the OpenAI-compatible API endpoint
#       LLAMACPP_API_KEY            API key (llama.cpp accepts any non-empty value)
#       LLAMACPP_MODEL_NAME         Model ID to request (must match llama.cpp's served model)
#       LLAMACPP_MAX_TOKENS         Max tokens per response
#       LLAMACPP_TEMPERATURE        Sampling temperature
#       LLAMACPP_HEALTH_RETRIES     How many times to retry the llama.cpp health probe
#       LLAMACPP_HEALTH_INTERVAL    Seconds between health probe retries
#   ② Standard OpenAI SDK env vars (honoured by openai / LangChain / LiteLLM):
#       OPENAI_API_BASE         (legacy LangChain convention)
#       OPENAI_BASE_URL         (current openai-node / openai-python convention)
#       OPENAI_API_KEY          Must be non-empty; llama.cpp accepts any value
#       OPENAI_MODEL            Model ID for client libraries that read this var
#   ③ OpenClaw-specific env vars (OPENCLAW_LLM_*):
#       OPENCLAW_LLM_PROVIDER   "openai-compatible" selects llama.cpp as the backend
#       OPENCLAW_LLM_BASE_URL   Mirrors LLAMACPP_BASE_URL
#       OPENCLAW_LLM_API_KEY    Mirrors LLAMACPP_API_KEY
#       OPENCLAW_LLM_MODEL      Mirrors LLAMACPP_MODEL_NAME
#       OPENCLAW_LLM_MAX_TOKENS Mirrors LLAMACPP_MAX_TOKENS
#       OPENCLAW_LLM_TEMPERATURE Mirrors LLAMACPP_TEMPERATURE
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
    -p "${OPENCLAW_HOST_PORT}:${OPENCLAW_PORT}" \
    -e "LLAMACPP_BASE_URL=${LLAMACPP_BASE_URL}" \
    -e "LLAMACPP_API_KEY=${LLAMACPP_API_KEY}" \
    -e "LLAMACPP_MODEL_NAME=${LLAMACPP_MODEL_NAME}" \
    -e "LLAMACPP_MAX_TOKENS=${LLAMACPP_MAX_TOKENS}" \
    -e "LLAMACPP_TEMPERATURE=${LLAMACPP_TEMPERATURE}" \
    -e "LLAMACPP_HEALTH_RETRIES=${LLAMACPP_HEALTH_RETRIES}" \
    -e "LLAMACPP_HEALTH_INTERVAL=${LLAMACPP_HEALTH_INTERVAL}" \
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

log "Container '${CONTAINER_NAME}' started."
log ""
log "OpenClaw is starting up and waiting for the llama.cpp server ..."
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
                log "llama.cpp OpenAI-compatible endpoint (from host):"
                log "  http://localhost:${LLAMACPP_HOST_PORT:-8000}/v1"
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
                log "llama.cpp OpenAI-compatible endpoint (from host):"
                log "  http://localhost:${LLAMACPP_HOST_PORT:-8000}/v1"
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
    log "llama.cpp OpenAI-compatible endpoint (from host):"
    log "  http://localhost:${LLAMACPP_HOST_PORT:-8000}/v1"
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
warn "  llama.cpp logs     : ${RUNTIME} logs -f ${LLAMACPP_CONTAINER_NAME}"
warn "============================================="
warn ""
warn "The Qwen3-4B AWQ model can take several minutes to load on first run."
warn "Re-check the dashboard in a few minutes, or increase OPENCLAW_HEALTH_TIMEOUT:"
warn "  OPENCLAW_HEALTH_TIMEOUT=300 ./scripts/run_openclaw.sh"
warn ""
warn "If llama.cpp is not yet running, start it first:"
warn "  ./scripts/run_llamacpp.sh"
exit 1
