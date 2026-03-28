#!/usr/bin/env bash
# =============================================================================
# stop.sh — Stop and remove DemoClaw containers and (optionally) the network
#
# Auto-detects docker or podman using the same shared detection library.
#
# Usage:
#   ./scripts/stop.sh                              # auto-detect runtime
#   CONTAINER_RUNTIME=podman ./scripts/stop.sh     # force podman
#   REMOVE_NETWORK=true ./scripts/stop.sh          # also remove the network
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { echo "[stop] $*"; }
warn()  { echo "[stop] WARNING: $*" >&2; }
error() { printf "[stop] ERROR: %s\n" "$*" >&2; exit 1; }

_rt_log()   { log "$@"; }
_rt_warn()  { warn "$@"; }
_rt_error() { error "$@"; }

# ---------------------------------------------------------------------------
# Load .env if present
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_ROOT}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
fi

# ---------------------------------------------------------------------------
# Source runtime detection
# ---------------------------------------------------------------------------
# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VLLM_CONTAINER="${VLLM_CONTAINER_NAME:-democlaw-vllm}"
OPENCLAW_CONTAINER="${OPENCLAW_CONTAINER_NAME:-democlaw-openclaw}"
NETWORK_NAME="${DEMOCLAW_NETWORK:-democlaw-net}"
REMOVE_NETWORK="${REMOVE_NETWORK:-false}"

# ---------------------------------------------------------------------------
# Stop and remove containers
# ---------------------------------------------------------------------------
for cname in "${OPENCLAW_CONTAINER}" "${VLLM_CONTAINER}"; do
    if "${RUNTIME}" container inspect "${cname}" > /dev/null 2>&1; then
        log "Stopping and removing container '${cname}' ..."
        "${RUNTIME}" rm -f "${cname}" 2>/dev/null || true
    else
        log "Container '${cname}' does not exist — skipping."
    fi
done

# ---------------------------------------------------------------------------
# Optionally remove the shared network
# ---------------------------------------------------------------------------
if [ "${REMOVE_NETWORK}" = "true" ]; then
    if "${RUNTIME}" network inspect "${NETWORK_NAME}" > /dev/null 2>&1; then
        log "Removing network '${NETWORK_NAME}' ..."
        "${RUNTIME}" network rm "${NETWORK_NAME}" 2>/dev/null || warn "Could not remove network '${NETWORK_NAME}' — it may still have connected containers."
    fi
fi

log "Done."
