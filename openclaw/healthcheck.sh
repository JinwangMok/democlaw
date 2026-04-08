#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — In-container healthcheck for the OpenClaw dashboard
#
# Verifies:
#   1. The dashboard HTTP endpoint responds (any HTTP status except 000)
#
# Used as the Docker/Podman HEALTHCHECK command inside the OpenClaw container.
# Exit 0 = healthy, Exit 1 = unhealthy.
# =============================================================================
set -euo pipefail

PORT="${OPENCLAW_PORT:-18789}"
TIMEOUT=5

# --- Check 1: Gateway process responds on the port ---
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" \
    "http://localhost:${PORT}/" 2>/dev/null || echo "000")

if [ "${HTTP_CODE}" = "000" ]; then
    echo "UNHEALTHY: Gateway not responding at http://localhost:${PORT}/" >&2
    exit 1
fi

echo "HEALTHY: Gateway (HTTP ${HTTP_CODE})"
exit 0
