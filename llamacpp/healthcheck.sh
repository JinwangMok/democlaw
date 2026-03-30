#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — In-container healthcheck for the llama.cpp server
#
# Verifies:
#   1. The /health endpoint responds with HTTP 200
#   2. The /v1/models endpoint responds and lists at least one model
#
# Used as the Docker/Podman HEALTHCHECK command inside the llama.cpp container.
# Exit 0 = healthy, Exit 1 = unhealthy.
# =============================================================================
set -euo pipefail

PORT="${LLAMA_PORT:-8000}"
BASE_URL="http://localhost:${PORT}"
TIMEOUT=5

# --- Check 1: /health endpoint ---
health_response=$(curl -sf --max-time "${TIMEOUT}" "${BASE_URL}/health" 2>/dev/null || echo "")

if [ -z "${health_response}" ]; then
    echo "UNHEALTHY: /health endpoint not responding" >&2
    exit 1
fi

# --- Check 2: /v1/models endpoint returns valid JSON with at least one model ---
MODELS_RESPONSE=$(curl -sf --max-time "${TIMEOUT}" "${BASE_URL}/v1/models" 2>/dev/null || echo "")

if [ -z "${MODELS_RESPONSE}" ]; then
    echo "UNHEALTHY: /v1/models endpoint not responding" >&2
    exit 1
fi

# Verify the response contains model data using python3
MODEL_COUNT=$(echo "${MODELS_RESPONSE}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    print(len(models))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

if [ "${MODEL_COUNT}" -gt 0 ]; then
    exit 0
else
    echo "UNHEALTHY: /v1/models returned no models" >&2
    exit 1
fi
