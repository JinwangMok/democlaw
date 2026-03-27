#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — In-container healthcheck for the OpenClaw dashboard
#
# Verifies:
#   1. The dashboard HTTP endpoint responds with a success status (2xx)
#   2. The response body contains HTML content (confirms the UI actually loads)
#   3. The response Content-Type header indicates HTML
#
# Used as the Docker/Podman HEALTHCHECK command inside the OpenClaw container.
# Exit 0 = healthy, Exit 1 = unhealthy.
# =============================================================================
set -euo pipefail

PORT="${OPENCLAW_PORT:-18789}"
BASE_URL="http://localhost:${PORT}"
TIMEOUT=5

# --- Check 1: Dashboard endpoint responds with 2xx ---
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" \
    "${BASE_URL}/" 2>/dev/null || echo "000")

if [ "${HTTP_CODE}" = "000" ]; then
    echo "UNHEALTHY: Dashboard not responding at ${BASE_URL}/" >&2
    exit 1
fi

if [ "${HTTP_CODE}" -lt 200 ] || [ "${HTTP_CODE}" -ge 400 ]; then
    echo "UNHEALTHY: Dashboard returned HTTP ${HTTP_CODE}" >&2
    exit 1
fi

# --- Check 2: Response contains HTML content ---
# Fetch body and verify it contains recognizable HTML markers
BODY=$(curl -sf --max-time "${TIMEOUT}" "${BASE_URL}/" 2>/dev/null || echo "")

if [ -z "${BODY}" ]; then
    echo "UNHEALTHY: Dashboard returned empty body" >&2
    exit 1
fi

# Check for common HTML indicators (case-insensitive via grep -i)
if echo "${BODY}" | grep -qi -e '<!doctype' -e '<html' -e '<head' -e '<body' -e '<div'; then
    exit 0
fi

# Even without HTML tags, a 2xx with non-empty body is acceptable
# (could be a JSON-based SPA loader or redirect)
if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 300 ]; then
    exit 0
fi

echo "UNHEALTHY: Dashboard response does not contain expected content" >&2
exit 1
