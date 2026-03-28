#!/usr/bin/env bash
# =============================================================================
# healthcheck_openclaw.sh — Poll the OpenClaw dashboard until it is reachable
#
# Repeatedly polls http://localhost:<OPENCLAW_HOST_PORT> (default: 18789) until
# the endpoint returns HTTP 200, then exits 0. Exits 1 if the timeout is
# exceeded before a successful response is received.
#
# Configurable via environment variables (or a .env file in the project root):
#
#   OPENCLAW_HOST_PORT      Port the OpenClaw dashboard is published on the host
#                           Default: 18789
#
#   OPENCLAW_HEALTH_TIMEOUT Maximum total seconds to wait for a successful
#                           response before giving up.
#                           Default: 120
#
#   OPENCLAW_HEALTH_INTERVAL  Seconds to sleep between each polling attempt.
#                           Default: 3
#
#   OPENCLAW_HEALTH_CURL_TIMEOUT  Timeout in seconds for each individual curl
#                           request.
#                           Default: 5
#
# Exit codes:
#   0 — Dashboard responded with HTTP 200 within the timeout window
#   1 — Timeout exceeded; dashboard did not become reachable in time
#
# Usage:
#   ./scripts/healthcheck_openclaw.sh
#   OPENCLAW_HOST_PORT=18789 OPENCLAW_HEALTH_TIMEOUT=60 ./scripts/healthcheck_openclaw.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Load .env file if present (honours user overrides in the project root)
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

# ---------------------------------------------------------------------------
# Configurable defaults (all overridable via environment or .env)
# ---------------------------------------------------------------------------
OPENCLAW_HOST_PORT="${OPENCLAW_HOST_PORT:-18789}"
OPENCLAW_HEALTH_TIMEOUT="${OPENCLAW_HEALTH_TIMEOUT:-120}"
OPENCLAW_HEALTH_INTERVAL="${OPENCLAW_HEALTH_INTERVAL:-3}"
OPENCLAW_HEALTH_CURL_TIMEOUT="${OPENCLAW_HEALTH_CURL_TIMEOUT:-5}"

DASHBOARD_URL="http://localhost:${OPENCLAW_HOST_PORT}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log()   { echo "[healthcheck-openclaw] $*"; }
warn()  { echo "[healthcheck-openclaw] WARNING: $*" >&2; }
error() { echo "[healthcheck-openclaw] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Prerequisite check: curl must be available
# ---------------------------------------------------------------------------
if ! command -v curl > /dev/null 2>&1; then
    error "curl is required but not found in PATH. Install curl and retry."
    exit 1
fi

# ---------------------------------------------------------------------------
# Main polling loop
#
# Strategy:
#   - On each iteration perform a single curl request with a short per-request
#     timeout (OPENCLAW_HEALTH_CURL_TIMEOUT).
#   - Accept any HTTP 200 response as "reachable".
#   - Sleep OPENCLAW_HEALTH_INTERVAL seconds between attempts.
#   - Track wall-clock elapsed time; abort with exit 1 when
#     OPENCLAW_HEALTH_TIMEOUT is exceeded.
# ---------------------------------------------------------------------------
log "Polling OpenClaw dashboard at ${DASHBOARD_URL}"
log "  Timeout   : ${OPENCLAW_HEALTH_TIMEOUT}s"
log "  Interval  : ${OPENCLAW_HEALTH_INTERVAL}s"
log "  Per-request curl timeout: ${OPENCLAW_HEALTH_CURL_TIMEOUT}s"

elapsed=0

while [ "${elapsed}" -lt "${OPENCLAW_HEALTH_TIMEOUT}" ]; do
    # Perform the HTTP request; capture the status code only.
    # curl exits non-zero on connection failure, so we suppress errors and
    # treat them as HTTP 000 (unreachable).
    http_code=$(curl -sf \
        -o /dev/null \
        -w "%{http_code}" \
        --max-time "${OPENCLAW_HEALTH_CURL_TIMEOUT}" \
        "${DASHBOARD_URL}/" 2>/dev/null || echo "000")

    if [ "${http_code}" = "200" ]; then
        log ""
        log "============================================="
        log "  OpenClaw dashboard is reachable!"
        log "  URL  : ${DASHBOARD_URL}"
        log "  HTTP : ${http_code}"
        log "============================================="
        log ""
        exit 0
    fi

    # Not yet reachable — report status and wait before next attempt
    remaining=$(( OPENCLAW_HEALTH_TIMEOUT - elapsed ))
    log "  ... HTTP ${http_code} — not ready yet (${elapsed}s elapsed, ${remaining}s remaining)"

    sleep "${OPENCLAW_HEALTH_INTERVAL}"
    elapsed=$(( elapsed + OPENCLAW_HEALTH_INTERVAL ))
done

# ---------------------------------------------------------------------------
# Timeout reached — perform one final attempt to capture the exact response
# ---------------------------------------------------------------------------
http_code=$(curl -sf \
    -o /dev/null \
    -w "%{http_code}" \
    --max-time "${OPENCLAW_HEALTH_CURL_TIMEOUT}" \
    "${DASHBOARD_URL}/" 2>/dev/null || echo "000")

if [ "${http_code}" = "200" ]; then
    log ""
    log "============================================="
    log "  OpenClaw dashboard is reachable!"
    log "  URL  : ${DASHBOARD_URL}"
    log "  HTTP : ${http_code}"
    log "============================================="
    log ""
    exit 0
fi

# ---------------------------------------------------------------------------
# Final failure — dashboard did not respond with HTTP 200 within the timeout
# ---------------------------------------------------------------------------
warn ""
warn "OpenClaw dashboard did not respond with HTTP 200 within ${OPENCLAW_HEALTH_TIMEOUT}s."
warn "  URL          : ${DASHBOARD_URL}"
warn "  Last HTTP    : ${http_code}"
warn ""
warn "Possible causes:"
warn "  - The OpenClaw container is not running. Start it with:"
warn "      ./scripts/start-openclaw.sh"
warn "  - The container is still initialising. Increase OPENCLAW_HEALTH_TIMEOUT and retry."
warn "  - The vLLM server is not reachable; OpenClaw may be waiting for it."
warn "  - Port ${OPENCLAW_HOST_PORT} is blocked by a firewall or in use by another process."
warn ""
exit 1
