#!/usr/bin/env bash
# =============================================================================
# healthcheck_openclaw.sh — Poll the OpenClaw dashboard until it is reachable
#
# Repeatedly polls http://localhost:<OPENCLAW_HOST_PORT> (default: 18789) until
# the endpoint returns HTTP 200, then exits 0. Exits 1 if the timeout is
# exceeded before a successful response is received.
#
# Uses curl if available; falls back to wget automatically.
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
#   OPENCLAW_HEALTH_CURL_TIMEOUT  Timeout in seconds for each individual HTTP
#                           request (applies to both curl and wget).
#                           Default: 5
#
# Exit codes:
#   0 — Dashboard responded with HTTP 200 within the timeout window
#   1 — Timeout exceeded; dashboard did not become reachable in time
#       (or neither curl nor wget is available)
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
# Detect HTTP client: prefer curl, fall back to wget
# ---------------------------------------------------------------------------
HTTP_CLIENT=""

if command -v curl > /dev/null 2>&1; then
    HTTP_CLIENT="curl"
elif command -v wget > /dev/null 2>&1; then
    HTTP_CLIENT="wget"
else
    error "Neither curl nor wget is available in PATH."
    error "Install curl or wget and retry."
    error "  Ubuntu/Debian : sudo apt-get install -y curl"
    error "  RHEL/Fedora   : sudo dnf install -y curl"
    error "  Alpine        : apk add --no-cache curl"
    exit 1
fi

log "Using HTTP client: ${HTTP_CLIENT}"

# ---------------------------------------------------------------------------
# http_get_status <url> — Fetch <url> and print only the HTTP status code.
#
# Returns the HTTP status code as a string (e.g. "200", "000" on failure).
# Suppresses all output except the status code to stdout.
# Never exits non-zero; connection failures are represented as "000".
#
# Depends on: ${HTTP_CLIENT}  (set above)
#             ${OPENCLAW_HEALTH_CURL_TIMEOUT}  (per-request timeout)
# ---------------------------------------------------------------------------
http_get_status() {
    local url="$1"

    if [ "${HTTP_CLIENT}" = "curl" ]; then
        # curl: -s silent, -o /dev/null discard body, -w print status code only
        curl -sf \
            -o /dev/null \
            -w "%{http_code}" \
            --max-time "${OPENCLAW_HEALTH_CURL_TIMEOUT}" \
            "${url}" 2>/dev/null \
        || echo "000"

    else
        # wget: --spider performs a HEAD-like request; --server-response prints headers.
        # We parse the first HTTP status line from stderr, which wget always writes there.
        # If the connection fails entirely, we return "000".
        local wget_output
        wget_output=$(wget \
            --server-response \
            --spider \
            --timeout="${OPENCLAW_HEALTH_CURL_TIMEOUT}" \
            --tries=1 \
            --quiet \
            "${url}" 2>&1 || true)

        # Extract the HTTP status code from a line like "  HTTP/1.1 200 OK"
        local status
        status=$(echo "${wget_output}" \
            | grep -oP '(?<=HTTP/\S\s)\d{3}' \
            | tail -1 \
        || true)

        # Fallback: try grep without Perl regex (busybox wget)
        if [ -z "${status}" ]; then
            status=$(echo "${wget_output}" \
                | grep -E '^[[:space:]]*HTTP/' \
                | awk '{print $2}' \
                | tail -1 \
            || true)
        fi

        echo "${status:-000}"
    fi
}

# ---------------------------------------------------------------------------
# Main polling loop
#
# Strategy:
#   - On each iteration perform a single HTTP request with a short per-request
#     timeout (OPENCLAW_HEALTH_CURL_TIMEOUT).
#   - Accept HTTP 200 as "reachable".
#   - Sleep OPENCLAW_HEALTH_INTERVAL seconds between attempts.
#   - Track wall-clock elapsed time; abort with exit 1 when
#     OPENCLAW_HEALTH_TIMEOUT is exceeded.
# ---------------------------------------------------------------------------
log "Polling OpenClaw dashboard at ${DASHBOARD_URL}"
log "  Timeout             : ${OPENCLAW_HEALTH_TIMEOUT}s"
log "  Interval            : ${OPENCLAW_HEALTH_INTERVAL}s"
log "  Per-request timeout : ${OPENCLAW_HEALTH_CURL_TIMEOUT}s"
log "  HTTP client         : ${HTTP_CLIENT}"

elapsed=0

while [ "${elapsed}" -lt "${OPENCLAW_HEALTH_TIMEOUT}" ]; do
    http_code=$(http_get_status "${DASHBOARD_URL}/")

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
http_code=$(http_get_status "${DASHBOARD_URL}/")

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
warn "  HTTP client  : ${HTTP_CLIENT}"
warn ""
warn "Possible causes:"
warn "  - The OpenClaw container is not running. Start it with:"
warn "      ./scripts/start-openclaw.sh"
warn "  - The container is still initialising. Increase OPENCLAW_HEALTH_TIMEOUT and retry:"
warn "      OPENCLAW_HEALTH_TIMEOUT=300 ./scripts/healthcheck_openclaw.sh"
warn "  - The vLLM server is not reachable; OpenClaw may be waiting for it."
warn "  - Port ${OPENCLAW_HOST_PORT} is blocked by a firewall or in use by another process:"
warn "      ss -tlnp | grep ${OPENCLAW_HOST_PORT}"
warn ""
exit 1
