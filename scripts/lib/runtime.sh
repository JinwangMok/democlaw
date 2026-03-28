#!/usr/bin/env bash
# =============================================================================
# runtime.sh — Shared container-runtime detection library
#
# Provides detect_runtime() which auto-detects docker or podman and sets the
# RUNTIME variable. Works identically on both runtimes with no manual changes.
#
# Source this file from any script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/runtime.sh"
#
# Override detection via environment:
#   CONTAINER_RUNTIME=podman ./scripts/start.sh
#
# After sourcing, the following are available:
#   RUNTIME              — resolved binary name ("docker" or "podman")
#   RUNTIME_IS_PODMAN    — "true" if podman, "false" if docker
#   runtime_gpu_flags()  — outputs the correct GPU passthrough flags
#   runtime_exec()       — wrapper that calls $RUNTIME with all arguments
# =============================================================================

# Guard against double-sourcing
if [ "${_RUNTIME_LIB_LOADED:-}" = "true" ]; then
    return 0 2>/dev/null || true
fi
_RUNTIME_LIB_LOADED="true"

# ---------------------------------------------------------------------------
# Logging helpers (only defined if not already set by the sourcing script)
# ---------------------------------------------------------------------------
if ! declare -f _rt_log > /dev/null 2>&1; then
    _rt_log()   { echo "[runtime] $*"; }
fi
if ! declare -f _rt_warn > /dev/null 2>&1; then
    _rt_warn()  { echo "[runtime] WARNING: $*" >&2; }
fi
if ! declare -f _rt_error > /dev/null 2>&1; then
    _rt_error() { echo "[runtime] ERROR: $*" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# detect_runtime — Determine which container runtime to use
#
# Priority:
#   1. $CONTAINER_RUNTIME env var (explicit override)
#   2. docker (if found in PATH)
#   3. podman (if found in PATH)
#
# Sets globals: RUNTIME, RUNTIME_IS_PODMAN
# Exits with error if no runtime found.
# ---------------------------------------------------------------------------
detect_runtime() {
    # 1. Honour explicit override
    if [ -n "${CONTAINER_RUNTIME:-}" ]; then
        if ! command -v "${CONTAINER_RUNTIME}" > /dev/null 2>&1; then
            _rt_error "CONTAINER_RUNTIME='${CONTAINER_RUNTIME}' is set but not found in PATH."
        fi
        RUNTIME="${CONTAINER_RUNTIME}"
    else
        # 2. Auto-detect: try docker first, then podman
        RUNTIME=""
        for _rt_candidate in docker podman; do
            if command -v "${_rt_candidate}" > /dev/null 2>&1; then
                RUNTIME="${_rt_candidate}"
                break
            fi
        done

        if [ -z "${RUNTIME}" ]; then
            _rt_error "No container runtime found. Install docker or podman and ensure it is in PATH."
        fi
    fi

    # Derive convenience flag
    if [ "${RUNTIME}" = "podman" ]; then
        RUNTIME_IS_PODMAN="true"
    else
        RUNTIME_IS_PODMAN="false"
    fi

    export RUNTIME
    export RUNTIME_IS_PODMAN
    _rt_log "Detected container runtime: ${RUNTIME} ($(${RUNTIME} --version 2>/dev/null || echo 'version unknown'))"
}

# ---------------------------------------------------------------------------
# runtime_gpu_flags — Output the correct GPU passthrough flags for the runtime
#
# Docker uses --gpus all (nvidia-container-toolkit).
# Podman 4.x+ uses CDI: --device nvidia.com/gpu=all
# Older Podman falls back to raw device nodes.
# ---------------------------------------------------------------------------
runtime_gpu_flags() {
    if [ "${RUNTIME_IS_PODMAN}" = "true" ]; then
        # podman 4.x+ supports CDI (Container Device Interface) for GPU access
        local podman_major
        podman_major=$("${RUNTIME}" --version 2>/dev/null | grep -oP '\d+' | head -1)
        if [ "${podman_major:-0}" -ge 4 ]; then
            echo "--device nvidia.com/gpu=all"
        else
            # Fallback for podman < 4: expose raw device nodes
            echo "--device /dev/nvidia0 --device /dev/nvidiactl --device /dev/nvidia-uvm"
        fi
    else
        # docker with nvidia-container-toolkit
        echo "--gpus all"
    fi
}

# ---------------------------------------------------------------------------
# runtime_exec — Convenience wrapper: calls $RUNTIME with all arguments
# ---------------------------------------------------------------------------
runtime_exec() {
    "${RUNTIME}" "$@"
}

# ---------------------------------------------------------------------------
# runtime_ensure_network — Create a container network if it doesn't exist
#
# Usage: runtime_ensure_network <network_name>
# Idempotent — safe to call multiple times.
# ---------------------------------------------------------------------------
runtime_ensure_network() {
    local net_name="${1:?network name required}"
    if ! "${RUNTIME}" network inspect "${net_name}" > /dev/null 2>&1; then
        _rt_log "Creating network '${net_name}' ..."
        "${RUNTIME}" network create "${net_name}"
    else
        _rt_log "Network '${net_name}' already exists."
    fi
}

# ---------------------------------------------------------------------------
# runtime_force_remove — Unconditionally destroy a container regardless of state
#
# Idempotent: returns 0 whether the container existed or not.
# This is the preferred teardown method — every run should destroy and recreate
# containers to guarantee identical end-state.
#
# Usage: runtime_force_remove <container_name>
# ---------------------------------------------------------------------------
runtime_force_remove() {
    local cname="${1:?container name required}"
    if "${RUNTIME}" container inspect "${cname}" > /dev/null 2>&1; then
        local state
        state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${cname}" 2>/dev/null || echo "unknown")
        _rt_log "Removing container '${cname}' (state: ${state}) for fresh recreation ..."
        "${RUNTIME}" rm -f "${cname}" > /dev/null 2>&1 || true
    fi
    return 0
}

# ---------------------------------------------------------------------------
# runtime_remove_if_stopped — Remove a container only if it exists and is not running
#
# DEPRECATED: Prefer runtime_force_remove() for idempotent destroy-and-recreate.
# This function is kept for backward compatibility but new code should use
# runtime_force_remove() to ensure containers are always recreated.
#
# Usage: runtime_remove_if_stopped <container_name>
# Returns 0 if container was removed or didn't exist, 1 if still running.
# ---------------------------------------------------------------------------
runtime_remove_if_stopped() {
    local cname="${1:?container name required}"
    if "${RUNTIME}" container inspect "${cname}" > /dev/null 2>&1; then
        local state
        state=$("${RUNTIME}" container inspect --format '{{.State.Status}}' "${cname}" 2>/dev/null || echo "unknown")
        if [ "${state}" = "running" ]; then
            return 1
        else
            _rt_log "Removing stopped container '${cname}' ..."
            "${RUNTIME}" rm -f "${cname}" > /dev/null 2>&1 || true
            return 0
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# runtime_build_if_missing — Build an image if it doesn't already exist
#
# Usage: runtime_build_if_missing <image_tag> <context_dir>
# ---------------------------------------------------------------------------
runtime_build_if_missing() {
    local tag="${1:?image tag required}"
    local ctx="${2:?build context directory required}"
    if ! "${RUNTIME}" image inspect "${tag}" > /dev/null 2>&1; then
        _rt_log "Building image '${tag}' from ${ctx} ..."
        "${RUNTIME}" build -t "${tag}" "${ctx}"
    else
        _rt_log "Image '${tag}' already exists. Use '${RUNTIME} rmi ${tag}' to force rebuild."
    fi
}

# ---------------------------------------------------------------------------
# Auto-run detection on source (can be skipped by setting _SKIP_RUNTIME_DETECT)
# ---------------------------------------------------------------------------
if [ "${_SKIP_RUNTIME_DETECT:-}" != "true" ]; then
    detect_runtime
fi
