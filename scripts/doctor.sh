#!/usr/bin/env bash
# =============================================================================
# doctor.sh -- One-shot DGX Spark / vLLM diagnostic
#
# Captures everything needed to debug a stuck or failing democlaw launch on
# a remote node, writes a full report to /tmp/democlaw-doctor.txt, and prints
# a compact ~20 line summary to stdout. The compact summary is designed to be
# hand-copyable in environments without SSH/scroll-back access to the node.
#
# Usage:
#   ./scripts/doctor.sh
#   ./scripts/doctor.sh --full    # also tail container logs into the summary
#
# Safe to run anytime (does NOT start/stop containers, does NOT write outside
# /tmp, does NOT require root — but surfaces more data when run as root).
# =============================================================================
set -u

REPORT=/tmp/democlaw-doctor.txt
SUMMARY=/tmp/democlaw-doctor-summary.txt
FULL=0
if [ "${1:-}" = "--full" ]; then
    FULL=1
fi

: >"${REPORT}"
: >"${SUMMARY}"

# ---- tiny helpers ----------------------------------------------------------
_section() { printf '\n===== %s =====\n' "$*" >>"${REPORT}"; }
_run()     { printf '$ %s\n' "$*" >>"${REPORT}"; eval "$*" >>"${REPORT}" 2>&1 || true; }
_note()    { printf '%s\n' "$*" >>"${REPORT}"; }
_sum()     { printf '%s\n' "$*" >>"${SUMMARY}"; }

# ---- header ----------------------------------------------------------------
_section "META"
_run "date -u +%FT%TZ"
_run "hostname"
_run "uname -a"
_run "id"
_run "whoami"
_run "cat /etc/os-release 2>/dev/null | head -5"

# ---- git state (of democlaw repo) ------------------------------------------
_section "democlaw repo state"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_run "cd '${REPO_ROOT}' && git rev-parse --abbrev-ref HEAD"
_run "cd '${REPO_ROOT}' && git log --oneline -5"
_run "cd '${REPO_ROOT}' && git status --short"
_run "ls '${REPO_ROOT}/.env' 2>/dev/null && head -40 '${REPO_ROOT}/.env' 2>/dev/null || echo '.env not present'"

# ---- host GPU / driver -----------------------------------------------------
_section "GPU host state"
_run "nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader"
_run "nvidia-smi -L"
_run "command -v nvidia-ctk >/dev/null 2>&1 && nvidia-ctk --version 2>&1 | head -1 || echo 'nvidia-ctk: not found'"
_run "dpkg -l 2>/dev/null | awk '/nvidia-container/ {print \$2\"=\"\$3}'"

# ---- container runtime -----------------------------------------------------
_section "Container runtime"
_run "command -v docker >/dev/null 2>&1 && docker --version || echo 'docker: not found'"
_run "docker info 2>/dev/null | grep -E 'Runtimes:|Default Runtime:|Server Version' | sed 's/^ *//'"

# ---- storage / mount topology ----------------------------------------------
_section "Mounts and disks"
_run "df -h --output=source,fstype,size,used,avail,target 2>/dev/null | grep -Ev 'tmpfs|overlay|squashfs|proc|sysfs'"
_run "mount 2>/dev/null | grep -Ei 'nvme|/data|/mnt|/srv' | head"
_run "ls -ld /data /data/models /mnt /srv /opt /home 2>/dev/null"

# ---- existing Gemma 4 caches anywhere --------------------------------------
_section "Gemma 4 cache discovery"
_run "find /data /mnt /srv /opt /workspace /var/lib /root /home -xdev -maxdepth 6 \
        \( -name proc -o -name sys -o -name .git -o -name node_modules \) -prune -o \
        -type d -name 'models--google--gemma-4*' -print 2>/dev/null"

# ---- democlaw containers ---------------------------------------------------
_section "democlaw containers"
_run "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | head -20"
_run "docker inspect democlaw-vllm --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{\"\\n\"}}{{end}}' 2>/dev/null"
_run "docker inspect democlaw-vllm --format '{{.State.Status}} (OOMKilled={{.State.OOMKilled}}, ExitCode={{.State.ExitCode}}, StartedAt={{.State.StartedAt}}, Error={{.State.Error}})' 2>/dev/null"
_run "docker inspect democlaw-vllm --format '{{range .HostConfig.Binds}}{{.}}{{\"\\n\"}}{{end}}' 2>/dev/null"

# ---- vLLM runtime signals --------------------------------------------------
_section "vLLM runtime signals"
_run "docker stats --no-stream democlaw-vllm 2>/dev/null"
_run "docker top democlaw-vllm 2>/dev/null | head -20"
# Scan recent logs for stage markers + error markers we care about.
_run "docker logs --tail 400 democlaw-vllm 2>&1 | grep -E 'Downloading|Fetching|snapshot_download|HfHub|Loading safetensors|Starting to load model|AttentionBackendEnum|Application startup complete|Uvicorn running|RuntimeError|Traceback|OOM|CUDA error|libcuda|Failed core proc|enforce_eager' | tail -30"
if [ "${FULL}" = "1" ]; then
    _run "docker logs --tail 200 democlaw-vllm 2>&1"
fi

# ---- model dir filesystem --------------------------------------------------
_section "Current MODEL_DIR candidates"
for candidate in /data/models /root/.cache/democlaw/models "${HOME}/.cache/democlaw/models"; do
    if [ -e "${candidate}" ]; then
        _run "du -sh '${candidate}' 2>/dev/null"
        _run "find '${candidate}' -maxdepth 4 -type d 2>/dev/null | head -20"
    else
        _note "(missing) ${candidate}"
    fi
done

# ---- HTTP probes -----------------------------------------------------------
_section "HTTP probes"
_run "curl -s -o /dev/null -w 'health:%{http_code}\n' --max-time 3 http://localhost:8000/health"
_run "curl -s --max-time 3 http://localhost:8000/v1/models | head -c 400 ; echo"

# =============================================================================
# Compact summary (stdout) — designed to fit in ~20 lines for hand-copy
# =============================================================================
{
    echo "=========== democlaw doctor summary ==========="

    # host + GPU
    echo "host  : $(hostname) $(uname -sr)"
    echo "gpu   : $(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>/dev/null | head -1)"

    # repo
    git_head=$(cd "${REPO_ROOT}" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    git_branch=$(cd "${REPO_ROOT}" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    env_present=$([ -f "${REPO_ROOT}/.env" ] && echo "yes" || echo "no")
    echo "repo  : ${git_branch}@${git_head}  .env=${env_present}"

    # toolkit
    toolkit=$(command -v nvidia-ctk >/dev/null 2>&1 && echo present || echo missing)
    runtimes=$(docker info 2>/dev/null | awk -F': ' '/Runtimes:/ {print $2; exit}')
    echo "toolkit: nvidia-ctk=${toolkit}  docker.Runtimes=${runtimes:-unknown}"

    # vllm container
    c_status=$(docker inspect democlaw-vllm --format '{{.State.Status}}' 2>/dev/null || echo "absent")
    c_oom=$(docker inspect democlaw-vllm --format '{{.State.OOMKilled}}' 2>/dev/null || echo "-")
    c_exit=$(docker inspect democlaw-vllm --format '{{.State.ExitCode}}' 2>/dev/null || echo "-")
    c_bind=$(docker inspect democlaw-vllm --format '{{range .Mounts}}{{if eq .Destination "/data/models"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
    echo "vllm  : status=${c_status} oom=${c_oom} exit=${c_exit}"
    echo "mount : ${c_bind:-none}"
    if [ -n "${c_bind}" ] && [ -d "${c_bind}" ]; then
        bind_size=$(du -sh "${c_bind}" 2>/dev/null | awk '{print $1}')
        shard_count=$(find "${c_bind}" -maxdepth 6 -name '*.safetensors' 2>/dev/null | wc -l | tr -d ' ')
        echo "cache : size=${bind_size:-0}  safetensors=${shard_count:-0}"
    fi

    # Gemma 4 cache hits elsewhere (comma-joined, truncated)
    other=$(find /data /mnt /srv /opt /workspace /var/lib /root /home -xdev -maxdepth 6 \
        \( -name proc -o -name sys -o -name .git -o -name node_modules \) -prune -o \
        -type d -name 'models--google--gemma-4*' -print 2>/dev/null \
        | grep -v -F "${c_bind:-__nope__}" | head -3 | paste -sd',' -)
    echo "other : ${other:-none}"

    # last meaningful log line (stall marker or progress)
    last=$(docker logs --tail 400 democlaw-vllm 2>&1 \
        | grep -E 'Downloading|Loading safetensors|Starting to load model|AttentionBackendEnum|Application startup complete|Uvicorn running|RuntimeError|Failed core proc|libcuda|Traceback' \
        | tail -1 | cut -c1-140)
    echo "loglast: ${last:-<none>}"

    # HTTP probes
    health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:8000/health 2>/dev/null)
    models=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:8000/v1/models 2>/dev/null)
    echo "http  : /health=${health:-000}  /v1/models=${models:-000}"

    # NVMe presence
    nvme=$(awk '$1 ~ /^\/dev\/nvme/ {print $2}' /proc/mounts 2>/dev/null | paste -sd',' -)
    echo "nvme  : ${nvme:-none}"

    echo "report: ${REPORT}"
    echo "=============================================="
} | tee "${SUMMARY}"

# Append the short summary to the full report so a single file has both.
{
    echo
    echo "===== COMPACT SUMMARY ====="
    cat "${SUMMARY}"
} >>"${REPORT}"

exit 0
