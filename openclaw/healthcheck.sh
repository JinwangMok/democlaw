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

# --- Check 1: Dashboard endpoint responds with HTTP 200 ---
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" \
    "${BASE_URL}/" 2>/dev/null || echo "000")

if [ "${HTTP_CODE}" = "000" ]; then
    echo "UNHEALTHY: Dashboard not responding at ${BASE_URL}/" >&2
    exit 1
fi

if [ "${HTTP_CODE}" != "200" ]; then
    echo "UNHEALTHY: Dashboard returned HTTP ${HTTP_CODE} (expected 200)" >&2
    exit 1
fi

# --- Check 2: Response body is non-empty ---
BODY=$(curl -s --max-time "${TIMEOUT}" "${BASE_URL}/" 2>/dev/null || echo "")

if [ -z "${BODY}" ]; then
    echo "UNHEALTHY: Dashboard returned HTTP 200 but empty body" >&2
    exit 1
fi

# --- Check 3 (informational): HTML content markers ---
# Check for common HTML indicators (case-insensitive via grep -i)
if echo "${BODY}" | grep -qi -e '<!doctype' -e '<html' -e '<head' -e '<body' -e '<div'; then
    echo "HEALTHY: HTTP 200, HTML content verified"
else
    # Non-HTML but HTTP 200 with non-empty body is still healthy
    # (could be a JSON-based SPA loader)
    echo "HEALTHY: HTTP 200, non-empty response ($(echo -n "${BODY}" | wc -c) bytes)"
fi

exit 0
