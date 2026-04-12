#!/usr/bin/env bash
# =============================================================================
# stop.sh -- Stop and clean up the entire DemoClaw stack
#
# Removes: containers (democlaw-openclaw, democlaw-llamacpp, democlaw-vllm, markitdown)
#          and optionally the shared network (democlaw-net, via REMOVE_NETWORK=true)
#
# Usage:
#   ./scripts/stop.sh
# =============================================================================
set -euo pipefail

log()  { echo "[stop] $*"; }

# ---------------------------------------------------------------------------
# Detect container runtime
# ---------------------------------------------------------------------------
RUNTIME=""
if [ -n "${CONTAINER_RUNTIME:-}" ] && command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1; then
    RUNTIME="${CONTAINER_RUNTIME}"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    echo "[stop] ERROR: No container runtime found (docker / podman)." >&2
    exit 1
fi

log "========================================"
log "  DemoClaw Stack -- Teardown"
log "========================================"
log "Runtime: ${RUNTIME}"

# ---------------------------------------------------------------------------
# Remove containers (order: openclaw first, then LLM engines [llamacpp/vllm], then sidecars)
# ---------------------------------------------------------------------------
for cname in democlaw-openclaw democlaw-llamacpp democlaw-vllm markitdown; do
    if "${RUNTIME}" container inspect "${cname}" >/dev/null 2>&1; then
        log "Removing container '${cname}' ..."
        "${RUNTIME}" rm -f "${cname}" >/dev/null 2>&1 || true
    else
        log "Container '${cname}' not found -- skipping."
    fi
done

# ---------------------------------------------------------------------------
# Remove network (skip unless REMOVE_NETWORK=true)
# Note: start.sh Phase 0 always recreates the network, so this flag mainly
# controls cleanup in teardown-only scenarios (no subsequent start).
# ---------------------------------------------------------------------------
REMOVE_NETWORK="${REMOVE_NETWORK:-false}"

if [ "${REMOVE_NETWORK}" = "true" ]; then
    if "${RUNTIME}" network inspect democlaw-net >/dev/null 2>&1; then
        log "Removing network 'democlaw-net' ..."
        "${RUNTIME}" network rm democlaw-net >/dev/null 2>&1 || true
    else
        log "Network 'democlaw-net' not found -- skipping."
    fi
else
    log "Network 'democlaw-net' preserved (REMOVE_NETWORK!=true)."
fi

log "Done."
