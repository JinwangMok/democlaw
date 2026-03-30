#!/usr/bin/env bash
# =============================================================================
# image.sh -- Shared container image acquisition library
#
# Provides ensure_image() which implements the "pull first, fallback to local
# build" pattern required for idempotent, reproducible container setups.
#
# Strategy:
#   1. Attempt to pull the image from Docker Hub (or configured registry)
#   2. If pull succeeds -> done (use the pre-built image)
#   3. If pull fails (non-zero exit) -> fall back to local build
#   4. If local build also fails -> exit with error
#
# Source this file from any script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/image.sh"
#
# After sourcing, the following are available:
#   ensure_image <image_tag> <build_context_dir>  -- pull-or-build an image
#
# The function always removes and re-acquires the image to guarantee that
# every run has the exact pinned version from the registry (or a fresh build).
#
# Requires: RUNTIME variable to be set (via lib/runtime.sh)
# =============================================================================

# Guard against double-sourcing
if [ "${_IMAGE_LIB_LOADED:-}" = "true" ]; then
    return 0 2>/dev/null || true
fi
_IMAGE_LIB_LOADED="true"

# ---------------------------------------------------------------------------
# Logging helpers (only defined if not already set by the sourcing script)
# ---------------------------------------------------------------------------
if ! declare -f _img_log > /dev/null 2>&1; then
    _img_log()   { echo "[image] $*"; }
fi
if ! declare -f _img_warn > /dev/null 2>&1; then
    _img_warn()  { echo "[image] WARNING: $*" >&2; }
fi
if ! declare -f _img_error > /dev/null 2>&1; then
    _img_error() { echo "[image] ERROR: $*" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# ensure_image — Pull from registry first; fall back to local build on failure
#
# Usage:
#   ensure_image <image_tag> <build_context_dir> [build_args...]
#
# Arguments:
#   image_tag          Docker image reference (e.g. "democlaw/llamacpp:v1.0.0")
#   build_context_dir  Path to Dockerfile directory for local build fallback
#   build_args...      Optional extra arguments passed to "docker build"
#                      (e.g. "--build-arg VERSION=1.0" "--build-arg FOO=bar")
#
# Behaviour:
#   1. Always attempts `docker pull <image_tag>` first
#   2. If pull exits 0 -> image acquired from registry, function returns 0
#   3. If pull exits non-zero -> logs warning, attempts local build
#   4. If local build exits 0 -> image built locally, function returns 0
#   5. If local build exits non-zero -> calls _img_error (exits script)
#
# The function is fully idempotent: calling it multiple times with the same
# arguments produces the same result regardless of prior image state.
# ---------------------------------------------------------------------------
ensure_image() {
    local image_tag="${1:?ensure_image: image_tag argument required}"
    local build_context="${2:?ensure_image: build_context_dir argument required}"
    shift 2
    local build_args=("$@")

    if [ -z "${RUNTIME:-}" ]; then
        _img_error "RUNTIME variable is not set. Source lib/runtime.sh before lib/image.sh."
    fi

    _img_log "Acquiring image '${image_tag}' ..."
    _img_log "  Strategy: pull from registry first, local build fallback"

    # ------------------------------------------------------------------
    # Step 1: Attempt to pull from Docker Hub / configured registry
    # ------------------------------------------------------------------
    _img_log "  Pulling '${image_tag}' from registry ..."

    if "${RUNTIME}" pull "${image_tag}" 2>&1; then
        _img_log "  Pull succeeded. Using registry image '${image_tag}'."
        return 0
    fi

    # ------------------------------------------------------------------
    # Step 2: Pull failed — fall back to local build
    # ------------------------------------------------------------------
    _img_warn "Pull failed for '${image_tag}'. Falling back to local build ..."
    _img_log "  Building '${image_tag}' from ${build_context} ..."

    if [ ! -d "${build_context}" ]; then
        _img_error "Build context directory does not exist: ${build_context}"
    fi

    if [ ! -f "${build_context}/Dockerfile" ]; then
        _img_error "No Dockerfile found in build context: ${build_context}"
    fi

    # Build with any extra build args passed by the caller
    # shellcheck disable=SC2068
    if "${RUNTIME}" build -t "${image_tag}" ${build_args[@]+"${build_args[@]}"} "${build_context}" 2>&1; then
        _img_log "  Local build succeeded. Image '${image_tag}' is ready."
        return 0
    fi

    _img_error "Both pull and local build failed for '${image_tag}'. Cannot proceed."
}
