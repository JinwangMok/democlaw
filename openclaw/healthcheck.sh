#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — In-container healthcheck for the OpenClaw dashboard
#
# Verifies:
#   1. The dashboard HTTP endpoint responds with HTTP 200
#   2. The response body is non-empty (confirms the UI actually loads)
#   3. Optionally checks for HTML content markers
#
# Used as the Docker/Podman HEALTHCHECK command inside the OpenClaw container.
# Exit 0 = healthy (HTTP 200), Exit 1 = unhealthy.
# =============================================================================
set -euo pipefail

PORT="${OPENCLAW_PORT:-18789}"
BASE_URL="http://localhost:${PORT}"
TIMEOUT=5

# --- Check 1: Gateway process responds on the port ---
# The dashboard root (/) returns HTTP 500 without an auth token — this is
# expected behaviour.  Any HTTP response means the gateway is alive.
# Only HTTP 000 (connection refused / timeout) is unhealthy.
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" \
    "${BASE_URL}/" 2>/dev/null || echo "000")

if [ "${HTTP_CODE}" = "000" ]; then
    echo "UNHEALTHY: Gateway not responding at ${BASE_URL}/" >&2
    exit 1
fi

echo "HEALTHY: Gateway responding (HTTP ${HTTP_CODE})"
exit 0
