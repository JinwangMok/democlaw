#!/usr/bin/env bash
# =============================================================================
# MarkItDown MCP Server Entrypoint
#
# Starts the markitdown MCP server with SSE transport on the configured port.
# =============================================================================
set -euo pipefail

MARKITDOWN_PORT="${MARKITDOWN_PORT:-3001}"
MARKITDOWN_HOST="${MARKITDOWN_HOST:-0.0.0.0}"

echo "[markitdown-entrypoint] Starting MarkItDown MCP server ..."
echo "[markitdown-entrypoint]   Host : ${MARKITDOWN_HOST}"
echo "[markitdown-entrypoint]   Port : ${MARKITDOWN_PORT}"

exec python /app/server.py \
    --host "${MARKITDOWN_HOST}" \
    --port "${MARKITDOWN_PORT}"
