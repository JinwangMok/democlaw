#!/usr/bin/env bash
# =============================================================================
# gpu.sh — Shared NVIDIA GPU and CUDA driver validation library
#
# Validates that the host has a working NVIDIA GPU with CUDA drivers and
# sufficient VRAM before any containers are launched. Fails fast with clear
# error messages if any prerequisite is missing.
#
# Source this file from any script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/gpu.sh"
#
# After sourcing, the following are available:
#   validate_nvidia_gpu()          — Full GPU/CUDA preflight check (exits on failure)
#   check_nvidia_smi()             — Verify nvidia-smi is installed and functional
#   check_gpu_hardware()           — Verify at least one physical NVIDIA GPU is detected
#   check_cuda_driver()            — Verify NVIDIA driver + CUDA version meet minimums
#   check_gpu_vram <min_mib>       — Verify GPU has at least <min_mib> MiB VRAM
#   check_nvidia_container_runtime — Verify nvidia-container-toolkit + runtime GPU config (exits on failure)
#   get_gpu_info()                 — Print detected GPU information
#   version_gte <v1> <v2>          — Return 0 if version v1 >= v2 (dot-separated)
#
# Minimum versions enforced:
#   MIN_DRIVER_VERSION (default: 520.0)  — NVIDIA kernel driver
#   MIN_CUDA_VERSION   (default: 11.8)   — CUDA runtime
#
# All check functions exit with a clear error if the check fails.
# =============================================================================

# Guard against double-sourcing
if [ "${_GPU_LIB_LOADED:-}" = "true" ]; then
    return 0 2>/dev/null || true
fi
_GPU_LIB_LOADED="true"

# ---------------------------------------------------------------------------
# Logging helpers (only defined if not already set by the sourcing script)
# ---------------------------------------------------------------------------
if ! declare -f _gpu_log > /dev/null 2>&1; then
    _gpu_log()   { echo "[gpu] $*"; }
fi
if ! declare -f _gpu_warn > /dev/null 2>&1; then
    _gpu_warn()  { echo "[gpu] WARNING: $*" >&2; }
fi
if ! declare -f _gpu_error > /dev/null 2>&1; then
    _gpu_error() { echo "[gpu] ERROR: $*" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Minimum VRAM required for Qwen3-4B AWQ 4-bit (in MiB)
# ---------------------------------------------------------------------------
DEFAULT_MIN_VRAM_MIB=7500

# ---------------------------------------------------------------------------
# Minimum NVIDIA driver and CUDA versions required by vLLM + Qwen3-4B AWQ
#
# CUDA 11.8 requires NVIDIA driver >= 520.61.05 on Linux.
# vLLM >= 0.3.x officially requires CUDA >= 11.8.
# We use 520 (no patch) as the integer floor for driver comparisons.
# ---------------------------------------------------------------------------
MIN_CUDA_VERSION="11.8"
MIN_DRIVER_VERSION="520.0"

# ---------------------------------------------------------------------------
# version_gte — Return 0 (true) if version string v1 >= v2
#
# Compares dot-separated version strings using GNU sort -V (version sort).
# Works for "11.8", "520.61.05", "12.2", etc.
#
# Usage: version_gte <v1> <v2>
#   Returns 0 if v1 >= v2, 1 otherwise.
# ---------------------------------------------------------------------------
version_gte() {
    local v1="${1:?first version required}"
    local v2="${2:?second version required}"
    # sort -V places the lowest version first; if v2 comes first (or equal) then v1 >= v2
    [ "$(printf '%s\n%s' "${v2}" "${v1}" | sort -V | head -1)" = "${v2}" ]
}

# ---------------------------------------------------------------------------
# check_nvidia_smi — Verify nvidia-smi is installed and can communicate with GPU
#
# Checks:
#   1. nvidia-smi binary exists in PATH
#   2. nvidia-smi can successfully query the GPU driver
# ---------------------------------------------------------------------------
check_nvidia_smi() {
    _gpu_log "Checking for nvidia-smi ..."

    if ! command -v nvidia-smi > /dev/null 2>&1; then
        _gpu_error "nvidia-smi not found in PATH.

  The NVIDIA GPU driver is either not installed or not in your PATH.

  To fix this:
    1. Install the NVIDIA driver for your GPU:
         sudo apt install nvidia-driver-560   # Ubuntu/Debian
         sudo dnf install nvidia-driver       # Fedora/RHEL
    2. Install nvidia-container-toolkit:
         See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html
    3. Reboot and try again.
"
    fi

    if ! nvidia-smi > /dev/null 2>&1; then
        _gpu_error "nvidia-smi is installed but failed to communicate with the NVIDIA driver.

  Possible causes:
    - The NVIDIA kernel module is not loaded (try: sudo modprobe nvidia)
    - No NVIDIA GPU is physically present in this machine
    - The driver version is incompatible with the installed GPU
    - A recent kernel update requires a driver reinstall

  Diagnostic commands:
    lspci | grep -i nvidia     # Check if GPU hardware is detected
    dmesg | grep -i nvidia     # Check kernel messages for driver errors
    sudo modprobe nvidia       # Try loading the kernel module
"
    fi

    _gpu_log "nvidia-smi is available and functional."
}

# ---------------------------------------------------------------------------
# check_gpu_hardware — Verify at least one NVIDIA GPU device is enumerated
#
# Uses nvidia-smi --list-gpus to confirm physical GPU hardware is present.
# Exits with a clear error if no GPU devices are found, even if the driver
# is installed (e.g. a driver-only install on a machine without a GPU).
# ---------------------------------------------------------------------------
check_gpu_hardware() {
    _gpu_log "Detecting NVIDIA GPU hardware ..."

    local gpu_list
    gpu_list=$(nvidia-smi --list-gpus 2>/dev/null || true)

    if [ -z "${gpu_list}" ]; then
        _gpu_error "No NVIDIA GPU hardware detected.

  nvidia-smi is installed but reported zero GPU devices.

  Possible causes:
    - No NVIDIA GPU is physically present or connected in this machine
    - The GPU is present but not recognised (PCIe slot issue, disabled in BIOS)
    - The NVIDIA kernel module failed to attach to the device

  Diagnostic commands:
    lspci | grep -i nvidia           # Check if PCIe hardware is visible
    dmesg | grep -i nvidia           # Look for driver attachment errors
    sudo modprobe nvidia             # Attempt to reload the kernel module
    sudo nvidia-smi -r               # Attempt driver reset

  This stack requires a physical NVIDIA CUDA GPU to run vLLM with
  Qwen3-4B AWQ 4-bit quantisation. There is no CPU fallback.
"
    fi

    local gpu_count
    gpu_count=$(echo "${gpu_list}" | grep -c 'GPU ' || true)
    _gpu_log "Detected ${gpu_count} NVIDIA GPU device(s):"
    echo "${gpu_list}" | while IFS= read -r line; do
        _gpu_log "  ${line}"
    done
}

# ---------------------------------------------------------------------------
# check_cuda_driver — Verify NVIDIA driver and CUDA versions are sufficient
#
# Parses both the NVIDIA driver version and the CUDA version reported by
# nvidia-smi, then enforces the minimum required versions:
#
#   Minimum NVIDIA driver : MIN_DRIVER_VERSION (default: 520.0)
#   Minimum CUDA version  : MIN_CUDA_VERSION   (default: 11.8)
#
# vLLM >= 0.3 requires CUDA >= 11.8; CUDA 11.8 requires driver >= 520.61.05.
# ---------------------------------------------------------------------------
check_cuda_driver() {
    local min_driver="${MIN_DRIVER_VERSION:-520.0}"
    local min_cuda="${MIN_CUDA_VERSION:-11.8}"

    _gpu_log "Checking NVIDIA driver and CUDA versions ..."
    _gpu_log "  Required: NVIDIA driver >= ${min_driver}, CUDA >= ${min_cuda}"

    # ------------------------------------------------------------------
    # 1. Parse NVIDIA driver version from nvidia-smi structured query.
    #    This is the kernel driver version (e.g. "535.154.05").
    # ------------------------------------------------------------------
    local driver_ver
    driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null \
        | head -1 | tr -d '[:space:]')

    if [ -z "${driver_ver}" ]; then
        _gpu_error "Could not determine NVIDIA driver version from nvidia-smi.

  Ensure the NVIDIA driver is properly installed and a GPU is accessible.
  Run 'nvidia-smi' manually to diagnose the problem.
"
    fi

    _gpu_log "Detected NVIDIA driver version: ${driver_ver}"

    # Validate driver version against the minimum requirement
    if ! version_gte "${driver_ver}" "${min_driver}"; then
        _gpu_error "NVIDIA driver version ${driver_ver} is too old.

  Minimum required driver version: ${min_driver}
  (Driver ${min_driver}+ is needed for CUDA >= ${min_cuda} support.)

  To upgrade the NVIDIA driver:
    Ubuntu/Debian : sudo apt install --reinstall nvidia-driver-535
                    (or newer; see 'ubuntu-drivers devices')
    Fedora/RHEL   : sudo dnf upgrade nvidia-driver
    Arch Linux    : sudo pacman -Syu nvidia

  After upgrading, reboot and run 'nvidia-smi' to confirm:
    nvidia-smi --query-gpu=driver_version --format=csv,noheader

  Release notes: https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/
"
    fi

    # ------------------------------------------------------------------
    # 2. Parse CUDA version from the nvidia-smi text header.
    #    The header line looks like:
    #      | NVIDIA-SMI 535.154.05  Driver Version: 535.154.05  CUDA Version: 12.2 |
    # ------------------------------------------------------------------
    local cuda_ver
    # Use POSIX-compatible grep (no -P/PCRE) to extract the CUDA version number
    # from the nvidia-smi header line: "... CUDA Version: 12.2 ..."
    cuda_ver=$(nvidia-smi 2>/dev/null \
        | grep -o 'CUDA Version: [0-9][0-9.]*' \
        | head -1 \
        | grep -o '[0-9][0-9.]*' \
        || true)

    if [ -z "${cuda_ver}" ]; then
        # nvidia-smi on very old drivers does not print CUDA Version in the header.
        # Treat this as a failure because we cannot confirm the CUDA support level.
        _gpu_error "Could not parse CUDA version from nvidia-smi output.

  Expected to find 'CUDA Version: X.Y' in 'nvidia-smi' header output.

  This usually means the installed NVIDIA driver (${driver_ver}) is too old
  to report CUDA version information, or the driver installation is corrupt.

  Minimum required: CUDA >= ${min_cuda} (needs driver >= ${min_driver}).

  Upgrade your NVIDIA driver and try again:
    https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/
"
    fi

    _gpu_log "Detected CUDA version: ${cuda_ver}"

    # Validate CUDA version against the minimum requirement
    if ! version_gte "${cuda_ver}" "${min_cuda}"; then
        _gpu_error "CUDA version ${cuda_ver} is too old.

  Minimum required CUDA version: ${min_cuda}
  vLLM requires CUDA >= ${min_cuda} to run Qwen3-4B AWQ 4-bit.

  Your current driver (${driver_ver}) only supports CUDA ${cuda_ver}.

  To fix this, upgrade your NVIDIA driver to version >= ${min_driver}:
    Ubuntu/Debian : sudo apt install --reinstall nvidia-driver-535
                    (run 'ubuntu-drivers devices' to find the best version)
    Fedora/RHEL   : sudo dnf upgrade nvidia-driver
    Arch Linux    : sudo pacman -Syu nvidia
    Manual        : https://www.nvidia.com/Download/index.aspx

  After upgrading:
    1. Reboot the host.
    2. Verify: nvidia-smi  (should show CUDA Version: ${min_cuda} or newer)
    3. Re-run this script.

  CUDA toolkit release notes: https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/
"
    fi

    _gpu_log "NVIDIA driver version ${driver_ver} meets requirement (>= ${min_driver})."
    _gpu_log "CUDA version ${cuda_ver} meets requirement (>= ${min_cuda})."
}

# ---------------------------------------------------------------------------
# check_gpu_vram — Verify the GPU has sufficient VRAM
#
# Usage: check_gpu_vram [min_mib]
#   min_mib — minimum VRAM in MiB (default: 7500, i.e. ~8 GB for AWQ 4-bit)
# ---------------------------------------------------------------------------
check_gpu_vram() {
    local min_mib="${1:-${DEFAULT_MIN_VRAM_MIB}}"

    _gpu_log "Checking GPU VRAM (minimum required: ${min_mib} MiB) ..."

    local vram_mib
    vram_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '[:space:]')

    if [ -z "${vram_mib}" ]; then
        _gpu_error "Could not determine GPU VRAM. Ensure nvidia-smi is working correctly."
    fi

    _gpu_log "Detected GPU VRAM: ${vram_mib} MiB"

    if [ "${vram_mib}" -lt "${min_mib}" ]; then
        _gpu_error "Insufficient GPU VRAM: ${vram_mib} MiB detected, but ${min_mib} MiB required.

  Qwen3-4B AWQ 4-bit requires approximately 8 GB (8192 MiB) of VRAM.

  Options:
    - Use a GPU with at least 8 GB VRAM
    - Reduce MAX_MODEL_LEN in .env to lower memory usage
    - Use a smaller quantized model
"
    fi
}

# ---------------------------------------------------------------------------
# check_nvidia_container_runtime — Verify nvidia-container-toolkit is set up
#   and the container engine can expose NVIDIA GPUs before launch proceeds.
#
# Usage: check_nvidia_container_runtime <runtime>
#   runtime — "docker" or "podman"
#
# This is a HARD check: any missing prerequisite causes an immediate exit
# with a clear, actionable error message.  The goal is to guarantee that
# GPU passthrough will succeed before any container is started.
#
# Steps performed:
#   1. Verify nvidia-ctk is installed (required for both runtimes)
#   2a. Docker  — verify NVIDIA OCI runtime is registered with the daemon
#   2b. Podman  — verify a CDI device spec file exists for NVIDIA
# ---------------------------------------------------------------------------
check_nvidia_container_runtime() {
    local runtime="${1:?container runtime name required}"

    _gpu_log "Checking NVIDIA container runtime support for '${runtime}' ..."

    # -----------------------------------------------------------------------
    # Step 1: nvidia-ctk must be present for BOTH docker and podman.
    #
    # nvidia-container-toolkit provides:
    #   - The NVIDIA OCI runtime hook used by Docker (--gpus flag)
    #   - The CDI spec generator used by Podman (--device nvidia.com/gpu=all)
    #
    # Without the toolkit, neither runtime can expose NVIDIA GPUs inside
    # containers.  There is no fallback — this is a hard requirement.
    # -----------------------------------------------------------------------
    if ! command -v nvidia-ctk > /dev/null 2>&1; then
        _gpu_error "nvidia-ctk not found in PATH.

  nvidia-container-toolkit must be installed so that containers can access
  the NVIDIA GPU.  This is required for BOTH docker and podman runtimes.

  Install on Ubuntu/Debian:
    distribution=\$(. /etc/os-release; echo \"\${ID}\${VERSION_ID}\")
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \\
      | sudo gpg --dearmor \\
          -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L \"https://nvidia.github.io/libnvidia-container/\${distribution}/libnvidia-container.list\" \\
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \\
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

  Install on Fedora/RHEL:
    sudo dnf install nvidia-container-toolkit

  Install on Arch Linux:
    yay -S nvidia-container-toolkit   # AUR

  Documentation:
    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html
"
    fi

    local ctk_version
    ctk_version=$(nvidia-ctk --version 2>/dev/null | head -1 | tr -d '\n' || echo "unknown")
    _gpu_log "nvidia-ctk found: ${ctk_version}"

    # -----------------------------------------------------------------------
    # Step 2: Runtime-specific GPU exposure checks
    # -----------------------------------------------------------------------
    if [ "${runtime}" = "docker" ]; then
        _check_nvidia_docker_runtime
    elif [ "${runtime}" = "podman" ]; then
        _check_nvidia_podman_runtime
    else
        _gpu_warn "Unknown container runtime '${runtime}' — skipping runtime-specific GPU check."
    fi
}

# ---------------------------------------------------------------------------
# _check_nvidia_docker_runtime — Verify Docker is configured to use the
#   NVIDIA container runtime (OCI hook).
#
# The NVIDIA OCI runtime must be registered with the Docker daemon so that
# --gpus flags work.  Without this, Docker silently ignores GPU requests
# and the vLLM server will start without GPU access, then fail to load the
# model.
#
# Detection strategy (first match wins):
#   1. 'docker info' output contains "nvidia"  (daemon already configured)
#   2. /etc/docker/daemon.json references "nvidia"  (config file present)
# ---------------------------------------------------------------------------
_check_nvidia_docker_runtime() {
    _gpu_log "Verifying NVIDIA runtime is registered with Docker ..."

    # Primary: docker info reports the nvidia runtime when properly configured.
    # The relevant sections look like:
    #   Runtimes: io.containerd.runc.v2 nvidia runc
    #   Default Runtime: runc
    local docker_info
    docker_info=$(docker info 2>/dev/null || true)

    if echo "${docker_info}" | grep -qi "nvidia"; then
        _gpu_log "NVIDIA runtime is registered with Docker (confirmed via 'docker info')."
        return 0
    fi

    # Secondary: inspect the daemon config file directly.  This covers the
    # case where the daemon has not been restarted after toolkit installation.
    local docker_config="/etc/docker/daemon.json"
    if [ -f "${docker_config}" ] && grep -qi "nvidia" "${docker_config}" 2>/dev/null; then
        _gpu_log "NVIDIA runtime found in Docker daemon config (${docker_config})."
        _gpu_warn "The daemon config references NVIDIA but 'docker info' did not confirm it."
        _gpu_warn "If you just installed the toolkit, restart Docker:"
        _gpu_warn "  sudo systemctl restart docker"
        # Treat daemon.json presence as sufficient to proceed; Docker may need restart.
        return 0
    fi

    # Neither check passed — hard error with actionable fix instructions.
    _gpu_error "NVIDIA container runtime is NOT configured for Docker.

  nvidia-container-toolkit is installed (nvidia-ctk found) but Docker
  has not been configured to use the NVIDIA OCI runtime.

  Without this configuration, the --gpus flag is silently ignored and
  the vLLM container will start without any GPU access.

  To fix this:
    1. Configure the NVIDIA runtime:
         sudo nvidia-ctk runtime configure --runtime=docker
    2. Restart the Docker daemon:
         sudo systemctl restart docker
    3. Verify the configuration:
         docker info | grep -A2 'Runtimes'
         # Expected: Runtimes: ... nvidia ...

  If Docker is not managed by systemd, restart it manually:
    sudo service docker restart   # SysV init

  Documentation:
    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html#configuration
"
}

# ---------------------------------------------------------------------------
# _check_nvidia_podman_runtime — Verify a CDI device spec exists for Podman.
#
# Podman 4.x+ uses the Container Device Interface (CDI) to expose NVIDIA
# GPUs inside containers.  nvidia-ctk generates the CDI spec file, which
# must exist before 'podman run --device nvidia.com/gpu=all' will work.
#
# CDI spec search locations (checked in priority order):
#   /etc/cdi/nvidia.yaml          — default nvidia-ctk output path
#   /etc/cdi/nvidia*.yaml         — versioned variants
#   /var/run/cdi/nvidia*.yaml     — runtime-generated path
# ---------------------------------------------------------------------------
_check_nvidia_podman_runtime() {
    _gpu_log "Verifying NVIDIA CDI device spec for Podman ..."

    local cdi_found=false
    local cdi_path=""
    local _cdi_match=""

    # Check standard and alternative CDI spec locations
    if [ -f "/etc/cdi/nvidia.yaml" ]; then
        cdi_found=true
        cdi_path="/etc/cdi/nvidia.yaml"
    elif _cdi_match="$(find /etc/cdi -maxdepth 1 -name 'nvidia*.yaml' 2>/dev/null | head -1)" \
         && [ -n "${_cdi_match}" ]; then
        cdi_found=true
        cdi_path="${_cdi_match}"
    elif [ -d "/var/run/cdi" ]; then
        _cdi_match="$(find /var/run/cdi -maxdepth 1 -name 'nvidia*.yaml' 2>/dev/null | head -1)"
        if [ -n "${_cdi_match}" ]; then
            cdi_found=true
            cdi_path="${_cdi_match}"
        fi
    fi

    if [ "${cdi_found}" = "true" ]; then
        _gpu_log "NVIDIA CDI device spec found at: ${cdi_path}"
        return 0
    fi

    # CDI spec not found — hard error with fix instructions.
    _gpu_error "NVIDIA CDI device spec not found for Podman.

  nvidia-container-toolkit is installed (nvidia-ctk found) but no CDI spec
  file exists at /etc/cdi/nvidia.yaml (or /var/run/cdi/nvidia*.yaml).

  Podman 4.x+ uses the Container Device Interface (CDI) to expose NVIDIA
  GPUs inside containers.  You must generate the CDI spec before running
  the DemoClaw stack.

  To generate the CDI spec:
    sudo mkdir -p /etc/cdi
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

  Verify the spec was created:
    ls -la /etc/cdi/
    nvidia-ctk cdi list        # should list: nvidia.com/gpu=0, etc.

  Test GPU access in Podman:
    podman run --rm --device nvidia.com/gpu=all ubuntu:24.04 \\
      bash -c 'nvidia-smi && echo GPU OK'

  Documentation:
    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html
"
}

# ---------------------------------------------------------------------------
# get_gpu_info — Print a summary of detected GPU(s) for diagnostic purposes
# ---------------------------------------------------------------------------
get_gpu_info() {
    _gpu_log "=== GPU Information ==="
    nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.free,temperature.gpu \
        --format=csv,noheader 2>/dev/null | while IFS=',' read -r idx name driver mem_total mem_free temp; do
        _gpu_log "  GPU ${idx}: ${name} | Driver: ${driver} | VRAM: ${mem_total} MiB (${mem_free} MiB free) | Temp: ${temp}C"
    done
    _gpu_log "======================="
}

# ---------------------------------------------------------------------------
# validate_nvidia_gpu — Complete GPU/CUDA preflight validation
#
# Runs all checks in sequence:
#   1. nvidia-smi availability
#   2. Physical GPU hardware enumeration
#   3. CUDA driver version
#   4. GPU VRAM sufficiency
#   5. nvidia-container-toolkit for the active runtime
#
# Usage: validate_nvidia_gpu [runtime] [min_vram_mib]
#   runtime       — "docker" or "podman" (default: value of $RUNTIME if set)
#   min_vram_mib  — minimum VRAM in MiB (default: 7500)
#
# Exits immediately with a clear error if any check fails.
# ---------------------------------------------------------------------------
validate_nvidia_gpu() {
    local runtime="${1:-${RUNTIME:-}}"
    local min_vram="${2:-${DEFAULT_MIN_VRAM_MIB}}"

    _gpu_log "========================================="
    _gpu_log "  NVIDIA GPU / CUDA Preflight Check"
    _gpu_log "========================================="

    # Step 1: nvidia-smi must be present and working
    check_nvidia_smi

    # Step 2: At least one physical GPU must be enumerated by the driver
    check_gpu_hardware

    # Step 3: CUDA driver version check
    check_cuda_driver

    # Step 4: VRAM check
    check_gpu_vram "${min_vram}"

    # Step 5: Container runtime GPU integration
    if [ -n "${runtime}" ]; then
        check_nvidia_container_runtime "${runtime}"
    else
        _gpu_warn "No container runtime specified — skipping container GPU integration check."
    fi

    # Print GPU summary
    get_gpu_info

    _gpu_log "========================================="
    _gpu_log "  GPU preflight checks PASSED"
    _gpu_log "========================================="
}
