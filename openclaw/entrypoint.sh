#!/usr/bin/env bash
# =============================================================================
# OpenClaw Container Entrypoint
#
# Configures OpenClaw to use the llama.cpp container as its default LLM provider
# via the OpenAI-compatible API endpoint.
#
# Configuration strategy (belt-and-suspenders):
#   1. Generate /app/config/config.json from environment variables at startup
#   2. Export standard OpenAI-compatible env vars (OPENAI_API_BASE, etc.)
#   3. Export OpenClaw-specific env vars (OPENCLAW_LLM_*)
#
# This ensures OpenClaw picks up the llama.cpp backend regardless of whether it
# reads config from a JSON file, from OpenAI-standard env vars, or from its
# own OPENCLAW_* env vars.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Default environment variables (overridable via .env or container env)
# ---------------------------------------------------------------------------
LLAMACPP_BASE_URL="${LLAMACPP_BASE_URL:-http://llamacpp:8000/v1}"
LLAMACPP_API_KEY="${LLAMACPP_API_KEY:-EMPTY}"
LLAMACPP_MODEL_NAME="${LLAMACPP_MODEL_NAME:-Qwen3.5-9B-Q4_K_M}"
LLAMACPP_MAX_TOKENS="${LLAMACPP_MAX_TOKENS:-4096}"
LLAMACPP_TEMPERATURE="${LLAMACPP_TEMPERATURE:-0.7}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"

export LLAMACPP_BASE_URL LLAMACPP_API_KEY LLAMACPP_MODEL_NAME OPENCLAW_PORT

# ---------------------------------------------------------------------------
# Generate runtime OpenClaw configuration from environment variables
# ---------------------------------------------------------------------------
# Overwrite the template config.json with resolved values so OpenClaw can
# read it directly.  This runs every time the container starts, so updates
# to environment variables always take effect.
# ---------------------------------------------------------------------------
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/app/config}"
mkdir -p "${OPENCLAW_CONFIG_DIR}"

CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/config.json"
cat > "${CONFIG_FILE}" <<JSONEOF
{
  "llm": {
    "provider": "openai-compatible",
    "baseUrl": "${LLAMACPP_BASE_URL}",
    "apiKey": "${LLAMACPP_API_KEY}",
    "model": "${LLAMACPP_MODEL_NAME}",
    "maxTokens": ${LLAMACPP_MAX_TOKENS},
    "temperature": ${LLAMACPP_TEMPERATURE}
  },
  "server": {
    "host": "0.0.0.0",
    "port": ${OPENCLAW_PORT}
  },
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "controlUi": {
      "allowedOrigins": ["*"],
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
JSONEOF

echo "[openclaw-entrypoint] LLM provider configuration written to ${CONFIG_FILE}"
echo "[openclaw-entrypoint]   Provider : openai-compatible (llama.cpp)"
echo "[openclaw-entrypoint]   Base URL : ${LLAMACPP_BASE_URL}"
echo "[openclaw-entrypoint]   Model    : ${LLAMACPP_MODEL_NAME}"
echo "[openclaw-entrypoint]   API Key  : ${LLAMACPP_API_KEY:0:4}****"
echo "[openclaw-entrypoint]   Tokens   : ${LLAMACPP_MAX_TOKENS}"
echo "[openclaw-entrypoint]   Port     : ${OPENCLAW_PORT}"

# ---------------------------------------------------------------------------
# Export OpenAI-compatible environment variables
#
# Many Node.js LLM client libraries (openai, LangChain, LiteLLM, etc.)
# honour these standard env vars out of the box.
# ---------------------------------------------------------------------------
export OPENAI_API_BASE="${LLAMACPP_BASE_URL}"
export OPENAI_BASE_URL="${LLAMACPP_BASE_URL}"
export OPENAI_API_KEY="${LLAMACPP_API_KEY}"
export OPENAI_MODEL="${LLAMACPP_MODEL_NAME}"

# ---------------------------------------------------------------------------
# Export OpenClaw-specific provider env vars
# ---------------------------------------------------------------------------
export OPENCLAW_LLM_PROVIDER="openai-compatible"
export OPENCLAW_LLM_BASE_URL="${LLAMACPP_BASE_URL}"
export OPENCLAW_LLM_API_KEY="${LLAMACPP_API_KEY}"
export OPENCLAW_LLM_MODEL="${LLAMACPP_MODEL_NAME}"
export OPENCLAW_LLM_MAX_TOKENS="${LLAMACPP_MAX_TOKENS}"
export OPENCLAW_LLM_TEMPERATURE="${LLAMACPP_TEMPERATURE}"
export OPENCLAW_CONFIG="${CONFIG_FILE}"
export OPENCLAW_HOST="0.0.0.0"
export OPENCLAW_PORT

# ---------------------------------------------------------------------------
# Wait for the llama.cpp server to become available before starting OpenClaw
# ---------------------------------------------------------------------------
# Strip /v1 suffix to get the base server URL for the health endpoint
LLAMACPP_HEALTH_URL="${LLAMACPP_BASE_URL%/v1}/health"
MAX_RETRIES="${LLAMACPP_HEALTH_RETRIES:-60}"
RETRY_INTERVAL="${LLAMACPP_HEALTH_INTERVAL:-5}"

echo "[openclaw-entrypoint] Waiting for llama.cpp server at ${LLAMACPP_HEALTH_URL} ..."
retries=0
while [ "${retries}" -lt "${MAX_RETRIES}" ]; do
    if curl -sf "${LLAMACPP_HEALTH_URL}" > /dev/null 2>&1; then
        echo "[openclaw-entrypoint] llama.cpp server is ready."
        break
    fi
    retries=$((retries + 1))
    if [ $((retries % 6)) -eq 0 ]; then
        echo "[openclaw-entrypoint] llama.cpp not ready yet (attempt ${retries}/${MAX_RETRIES}). Retrying in ${RETRY_INTERVAL}s ..."
    fi
    sleep "${RETRY_INTERVAL}"
done

if [ "${retries}" -ge "${MAX_RETRIES}" ]; then
    echo "[openclaw-entrypoint] ERROR: llama.cpp server did not become ready after $((MAX_RETRIES * RETRY_INTERVAL))s."
    echo "[openclaw-entrypoint] Check that the llama.cpp container is running and reachable at ${LLAMACPP_BASE_URL}."
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify the expected model is loaded on llama.cpp
# ---------------------------------------------------------------------------
echo "[openclaw-entrypoint] Verifying model '${LLAMACPP_MODEL_NAME}' is available ..."
MODEL_RESPONSE=$(curl -sf "${LLAMACPP_BASE_URL}/models" 2>/dev/null || echo "")
if [ -n "${MODEL_RESPONSE}" ]; then
    if echo "${MODEL_RESPONSE}" | grep -q "${LLAMACPP_MODEL_NAME}"; then
        echo "[openclaw-entrypoint] Confirmed: model '${LLAMACPP_MODEL_NAME}' is loaded on llama.cpp."
    else
        echo "[openclaw-entrypoint] WARNING: Model '${LLAMACPP_MODEL_NAME}' not found in llama.cpp /v1/models response."
        echo "[openclaw-entrypoint] Response: ${MODEL_RESPONSE}"
        echo "[openclaw-entrypoint] Proceeding — the model name may differ in the listing."
    fi
else
    echo "[openclaw-entrypoint] WARNING: Could not query /v1/models — proceeding anyway."
fi

# ---------------------------------------------------------------------------
# Launch OpenClaw with config
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Run onboard if not already done (creates workspace + pairs gateway)
# ---------------------------------------------------------------------------
if [ ! -f "${HOME}/.openclaw/openclaw.json" ]; then
    echo "[openclaw-entrypoint] Running initial onboard (llama.cpp provider) ..."
    openclaw onboard \
        --non-interactive \
        --accept-risk \
        --mode local \
        --auth-choice custom \
        --custom-base-url "${LLAMACPP_BASE_URL}" \
        --custom-model-id "${LLAMACPP_MODEL_NAME}" \
        2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Configure gateway settings via CLI (these write to OpenClaw's own config store)
# ---------------------------------------------------------------------------
openclaw config set gateway.mode local 2>/dev/null || true
openclaw config set gateway.bind lan 2>/dev/null || true
openclaw config set gateway.auth.mode token 2>/dev/null || true
openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true 2>/dev/null || true

# Fix model settings (onboard defaults may be wrong)
openclaw config set models.providers.llamacpp.apiKey EMPTY 2>/dev/null || true
openclaw config set models.providers.llamacpp.models.0.maxTokens 2048 2>/dev/null || true
openclaw config set models.providers.llamacpp.models.0.contextWindow 32000 2>/dev/null || true

echo "[openclaw-entrypoint] Starting OpenClaw (config=${CONFIG_FILE}, port=${OPENCLAW_PORT}) ..."

# ---------------------------------------------------------------------------
# Launch gateway + auto-approve device pairing
#
# Strategy: run gateway in background, auto-approver in foreground.
# When gateway dies, the script exits (container restarts via --restart).
# ---------------------------------------------------------------------------
echo "[openclaw-entrypoint] Starting OpenClaw gateway on port ${OPENCLAW_PORT} ..."

if [ $# -gt 0 ]; then
    "$@" &
else
    openclaw gateway --port "${OPENCLAW_PORT}" --bind lan --allow-unconfigured &
fi
GATEWAY_PID=$!

# Wait for gateway to be ready
sleep 8

# ---------------------------------------------------------------------------
# Auto-approve the FIRST device pairing request only (one-shot, not a loop)
# After the first device is paired, stop watching — no blanket auto-approve.
# ---------------------------------------------------------------------------
echo "[openclaw-entrypoint] Waiting to auto-approve first device pairing ..."
APPROVED=false
for attempt in $(seq 1 60); do
    if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then break; fi
    pending=$(openclaw devices list 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)
    if [ -n "$pending" ]; then
        openclaw devices approve "$pending" 2>/dev/null && \
            echo "[openclaw-entrypoint] First device auto-approved: $pending" && \
            APPROVED=true
        break
    fi
    sleep 2
done

if [ "$APPROVED" = false ]; then
    echo "[openclaw-entrypoint] No pairing request received within 120s. Manual approve required."
fi

# Hand off to gateway — block until it exits
wait "$GATEWAY_PID"
