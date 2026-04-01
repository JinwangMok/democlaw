#!/usr/bin/env bash
# =============================================================================
# stop.sh -- Stop and clean up the entire DemoClaw stack
#
# Removes: containers (democlaw-openclaw, democlaw-llamacpp) + network (democlaw-net)
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
# Remove containers (order: openclaw first, then llamacpp)
# ---------------------------------------------------------------------------
for cname in democlaw-openclaw democlaw-llamacpp markitdown; do
    if "${RUNTIME}" container inspect "${cname}" >/dev/null 2>&1; then
        log "Removing container '${cname}' ..."
        "${RUNTIME}" rm -f "${cname}" >/dev/null 2>&1 || true
    else
        log "Container '${cname}' not found -- skipping."
    fi
done

# ---------------------------------------------------------------------------
# Remove network
# ---------------------------------------------------------------------------
if "${RUNTIME}" network inspect democlaw-net >/dev/null 2>&1; then
    log "Removing network 'democlaw-net' ..."
    "${RUNTIME}" network rm democlaw-net >/dev/null 2>&1 || true
else
    log "Network 'democlaw-net' not found -- skipping."
fi

log "Done."
