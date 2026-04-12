#!/usr/bin/env bash
# =============================================================================
# gpu-preflight.sh -- Container GPU access validation and auto-repair
#
# Verifies that the selected container runtime can actually expose the host
# NVIDIA driver (libcuda.so.1) inside a container. Host-level `nvidia-smi`
# alone is not sufficient: vLLM / llama.cpp need the NVIDIA Container Toolkit
# to inject the driver into the container. When that is missing, vLLM dies
# with:
#     libcuda.so.1: cannot open shared object file
#     RuntimeError: Failed to infer device type
#     Failed core proc(s): {}
#
# Public API (source this file, then call):
#
#   gpu_container_smoke_test <image>
#     Runs `nvidia-smi` inside <image> using the currently chosen GPU flags.
#     If that fails, tries the alternative flag style (legacy --gpus all vs
#     CDI --device nvidia.com/gpu=all) and, on success, rewrites the global
#     GPU_FLAGS array to match. Returns 0 on success, 1 on failure.
#
#   gpu_toolkit_diagnose
#     Prints a short report of host-level toolkit state (dpkg, nvidia-ctk,
#     docker info Runtimes, CDI spec presence). Always returns 0.
#
#   gpu_toolkit_autoinstall
#     Installs and registers nvidia-container-toolkit on apt-based Linux
#     hosts. Requires sudo and DEMOCLAW_AUTO_INSTALL_NVIDIA_TOOLKIT=1.
#     Returns 0 on success, non-zero otherwise.
#
# Expected globals (set by the caller, typically start.sh):
#   RUNTIME       docker | podman
#   _is_podman    "true" | "false"
#   GPU_FLAGS     bash array of runtime flags to enable GPU access
#
# Logging: uses log()/error() from the caller if defined, otherwise prints
# to stderr with a [gpu-preflight] prefix.
# =============================================================================

if ! declare -f log >/dev/null 2>&1; then
    log() { echo "[gpu-preflight] $*"; }
fi
if ! declare -f error >/dev/null 2>&1; then
    error() { echo "[gpu-preflight] ERROR: $*" >&2; exit 1; }
fi

# -----------------------------------------------------------------------------
# gpu_container_smoke_test <image>
#
# Runs `nvidia-smi` inside the given image. Tries the current GPU_FLAGS first;
# on failure, flips between legacy (--gpus all) and CDI
# (--device nvidia.com/gpu=all) and retries. The working style is written back
# into the global GPU_FLAGS array so subsequent container launches inherit it.
# -----------------------------------------------------------------------------
gpu_container_smoke_test() {
    local image="$1"
    if [ -z "${image}" ]; then
        error "gpu_container_smoke_test: image argument required"
    fi

    local -a legacy_flags=(--gpus all)
    local -a cdi_flags=(--device nvidia.com/gpu=all)

    # Podman's native GPU syntax matches CDI.
    if [ "${_is_podman:-false}" = "true" ]; then
        legacy_flags=(--device nvidia.com/gpu=all)
    fi

    _gpu_try_flags() {
        local -a flags=("$@")
        # --entrypoint overrides the image default so we can invoke nvidia-smi
        # directly; we redirect all output and only care about the exit code.
        "${RUNTIME}" run --rm \
            --entrypoint nvidia-smi \
            "${flags[@]}" \
            "${image}" \
            -L >/dev/null 2>&1
    }

    log "Container GPU smoke test: ${RUNTIME} run --rm ${GPU_FLAGS[*]} ${image} nvidia-smi -L"
    if _gpu_try_flags "${GPU_FLAGS[@]}"; then
        log "Container GPU access OK (${GPU_FLAGS[*]})."
        unset -f _gpu_try_flags
        return 0
    fi

    log "Primary GPU flags failed. Trying alternative style ..."

    local -a alt_flags
    if [ "${GPU_FLAGS[*]}" = "${legacy_flags[*]}" ]; then
        alt_flags=("${cdi_flags[@]}")
    else
        alt_flags=("${legacy_flags[@]}")
    fi

    if _gpu_try_flags "${alt_flags[@]}"; then
        log "Container GPU access OK via alternative flags (${alt_flags[*]})."
        log "Updating GPU_FLAGS to: ${alt_flags[*]}"
        GPU_FLAGS=("${alt_flags[@]}")
        unset -f _gpu_try_flags
        return 0
    fi

    unset -f _gpu_try_flags
    log "Container GPU smoke test FAILED for both legacy and CDI flag styles."
    return 1
}

# -----------------------------------------------------------------------------
# gpu_toolkit_diagnose
#
# Prints the state of the host-level NVIDIA Container Toolkit so the user can
# tell at a glance what is missing.
# -----------------------------------------------------------------------------
gpu_toolkit_diagnose() {
    log "--- NVIDIA Container Toolkit diagnosis ---"

    if command -v dpkg >/dev/null 2>&1; then
        local pkgs
        pkgs=$(dpkg -l 2>/dev/null | awk '/nvidia-container/ {print $2"="$3}' | paste -sd ',' -)
        if [ -n "${pkgs}" ]; then
            log "  Packages     : ${pkgs}"
        else
            log "  Packages     : (no nvidia-container-* packages installed via dpkg)"
        fi
    fi

    if command -v nvidia-ctk >/dev/null 2>&1; then
        log "  nvidia-ctk   : $(nvidia-ctk --version 2>&1 | head -1)"
    else
        log "  nvidia-ctk   : not found in PATH"
    fi

    local runtimes
    runtimes=$("${RUNTIME}" info 2>/dev/null | awk '/Runtimes:/{print $2}' | head -1)
    if [ -n "${runtimes}" ]; then
        log "  ${RUNTIME} runtimes: ${runtimes}"
    else
        log "  ${RUNTIME} runtimes: (could not read from '${RUNTIME} info')"
    fi

    if [ -f /etc/cdi/nvidia.yaml ] || [ -f /var/run/cdi/nvidia.yaml ]; then
        log "  CDI spec     : present"
    else
        log "  CDI spec     : missing (only needed for CDI-mode runtimes)"
    fi

    log "  Host nvidia-smi: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo 'FAILED')"
    log "-------------------------------------------"
}

# -----------------------------------------------------------------------------
# gpu_toolkit_autoinstall
#
# Installs nvidia-container-toolkit on apt-based Linux hosts and registers it
# with Docker. Gated behind DEMOCLAW_AUTO_INSTALL_NVIDIA_TOOLKIT=1 so it never
# runs silently. Does nothing on macOS/Windows/podman-only hosts.
# -----------------------------------------------------------------------------
gpu_toolkit_autoinstall() {
    if [ "${DEMOCLAW_AUTO_INSTALL_NVIDIA_TOOLKIT:-0}" != "1" ]; then
        log "Auto-install skipped. Set DEMOCLAW_AUTO_INSTALL_NVIDIA_TOOLKIT=1 to enable."
        return 1
    fi

    case "$(uname -s)" in
        Linux) ;;
        *)
            log "Auto-install only supported on Linux (found $(uname -s))."
            return 1
            ;;
    esac

    if ! command -v apt-get >/dev/null 2>&1; then
        log "Auto-install requires apt-get. Install nvidia-container-toolkit manually."
        return 1
    fi

    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        log "Auto-install requires root or sudo."
        return 1
    fi

    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        SUDO="sudo"
    fi

    log "Installing nvidia-container-toolkit via apt ..."

    local keyring=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    local listfile=/etc/apt/sources.list.d/nvidia-container-toolkit.list

    if ! curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | ${SUDO} gpg --dearmor -o "${keyring}" 2>/dev/null; then
        log "Failed to fetch nvidia-container-toolkit gpg key."
        return 1
    fi

    if ! curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed "s#deb https://#deb [signed-by=${keyring}] https://#g" \
        | ${SUDO} tee "${listfile}" >/dev/null; then
        log "Failed to write apt source list."
        return 1
    fi

    ${SUDO} apt-get update -y >/dev/null 2>&1 || { log "apt-get update failed."; return 1; }
    ${SUDO} apt-get install -y nvidia-container-toolkit >/dev/null 2>&1 \
        || { log "apt-get install nvidia-container-toolkit failed."; return 1; }

    log "Registering nvidia runtime with ${RUNTIME} ..."
    ${SUDO} nvidia-ctk runtime configure --runtime="${RUNTIME}" >/dev/null 2>&1 \
        || { log "nvidia-ctk runtime configure failed."; return 1; }

    # Generate CDI spec as well so both legacy and CDI paths are available.
    ${SUDO} mkdir -p /etc/cdi
    ${SUDO} nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml >/dev/null 2>&1 || true

    log "Restarting ${RUNTIME} daemon ..."
    if command -v systemctl >/dev/null 2>&1; then
        ${SUDO} systemctl restart "${RUNTIME}" >/dev/null 2>&1 \
            || { log "Failed to restart ${RUNTIME}."; return 1; }
    else
        log "systemctl not found; please restart ${RUNTIME} manually."
    fi

    log "nvidia-container-toolkit install complete."
    return 0
}

# -----------------------------------------------------------------------------
# gpu_preflight_require <image>
#
# Convenience wrapper: run smoke test; on failure, print diagnosis, attempt
# auto-install (if enabled), and re-run the smoke test. Exits the process with
# a clear error message if GPU access still cannot be established.
# -----------------------------------------------------------------------------
gpu_preflight_require() {
    local image="$1"

    if gpu_container_smoke_test "${image}"; then
        return 0
    fi

    gpu_toolkit_diagnose

    cat >&2 <<'EOF'
[gpu-preflight] Containers cannot access the host NVIDIA driver.
[gpu-preflight] Host `nvidia-smi` works, but `libcuda.so.1` is not being
[gpu-preflight] injected into containers. This means the NVIDIA Container
[gpu-preflight] Toolkit is missing, not registered with your container
[gpu-preflight] runtime, or the daemon was not restarted after install.
[gpu-preflight]
[gpu-preflight] Fix (Ubuntu/DGX OS, aarch64 or x86_64):
[gpu-preflight]   curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
[gpu-preflight]     | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
[gpu-preflight]   curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
[gpu-preflight]     | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
[gpu-preflight]     | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
[gpu-preflight]   sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
[gpu-preflight]   sudo nvidia-ctk runtime configure --runtime=docker
[gpu-preflight]   sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
[gpu-preflight]   sudo systemctl restart docker
[gpu-preflight]
[gpu-preflight] Or re-run start.sh with DEMOCLAW_AUTO_INSTALL_NVIDIA_TOOLKIT=1
[gpu-preflight] to let this script perform the install for you.
EOF

    if gpu_toolkit_autoinstall; then
        log "Re-running container GPU smoke test after auto-install ..."
        if gpu_container_smoke_test "${image}"; then
            return 0
        fi
    fi

    error "Container GPU access is not working. See fix instructions above."
}
