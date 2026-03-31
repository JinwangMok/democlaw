#!/usr/bin/env bash
# =============================================================================
# MarkItDown MCP Server Healthcheck
#
# Verifies the SSE endpoint is responding on the configured port.
# =============================================================================
set -euo pipefail

MARKITDOWN_PORT="${MARKITDOWN_PORT:-3001}"

# The MCP SSE server exposes /sse as the SSE endpoint.
# A GET to /health (or the root) should return a non-error status.
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    --max-time 3 "http://localhost:${MARKITDOWN_PORT}/health" 2>/dev/null || echo "000")

if [ "${HTTP_CODE}" = "200" ]; then
    exit 0
fi

# Fallback: try the SSE endpoint — a 200 or 405 means the server is up
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    --max-time 3 "http://localhost:${MARKITDOWN_PORT}/sse" 2>/dev/null || echo "000")

case "${HTTP_CODE}" in
    200|405) exit 0 ;;
    *)       exit 1 ;;
esac
