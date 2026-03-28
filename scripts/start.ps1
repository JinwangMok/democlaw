# =============================================================================
# start.ps1 -- Full E2E startup for the DemoClaw stack (vLLM + OpenClaw)
#
# This single script handles the entire lifecycle:
#   1. Clean up old containers/network
#   2. Acquire images (pull from Docker Hub first; local build fallback)
#   3. Create network
#   4. Start vLLM, wait for /health + /v1/models
#   5. Start OpenClaw, wait for dashboard
#   6. Print tokenized dashboard URL
#
# Usage:
#   .\scripts\start.ps1
#   $env:HF_CACHE_DIR = "D:\models" ; .\scripts\start.ps1
#   $env:DEMOCLAW_VLLM_IMAGE = "myrepo/vllm:dev" ; .\scripts\start.ps1
# =============================================================================
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function log   { param([string]$msg) Write-Host "[start] $msg" -ForegroundColor Cyan }
function logok { param([string]$msg) Write-Host "[start] $msg" -ForegroundColor Green }
function logwarn { param([string]$msg) Write-Host "[start] WARNING: $msg" -ForegroundColor Yellow }
function logerr {
    param([string]$msg)
    Write-Host "[start] ERROR: $msg" -ForegroundColor Red
    exit 1
}

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$VllmImage      = if ($env:DEMOCLAW_VLLM_IMAGE)    { $env:DEMOCLAW_VLLM_IMAGE }    else { 'jinwangmok/democlaw-vllm:v1.0.0' }
$OpenclawImage  = if ($env:DEMOCLAW_OPENCLAW_IMAGE) { $env:DEMOCLAW_OPENCLAW_IMAGE } else { 'jinwangmok/democlaw-openclaw:v1.0.0' }
$Network        = 'democlaw-net'
$VllmContainer  = 'democlaw-vllm'
$OcContainer    = 'democlaw-openclaw'
$ModelName      = 'Qwen/Qwen3-4B-AWQ'

# vLLM tuning for 8GB VRAM
$MaxModelLen          = '16384'
$Quantization         = 'awq_marlin'
$Dtype                = 'float16'
$GpuMemoryUtilization = '0.95'

# Ports
$VllmPort = '8000'
$OcPort   = '18789'

# Timeouts (seconds)
$VllmHealthTimeout = 300
$OcHealthTimeout   = 120

# HuggingFace cache
$HfCacheDir = if ($env:HF_CACHE_DIR) { $env:HF_CACHE_DIR } else { Join-Path $env:USERPROFILE '.cache\huggingface' }

# ---------------------------------------------------------------------------
# Detect container runtime
# ---------------------------------------------------------------------------
$Runtime = ''
if ($env:CONTAINER_RUNTIME -and (Get-Command $env:CONTAINER_RUNTIME -ErrorAction SilentlyContinue)) {
    $Runtime = $env:CONTAINER_RUNTIME
} elseif (Get-Command 'docker' -ErrorAction SilentlyContinue) {
    $Runtime = 'docker'
} elseif (Get-Command 'podman' -ErrorAction SilentlyContinue) {
    $Runtime = 'podman'
} else {
    logerr "No container runtime found. Install Docker Desktop or Podman Desktop."
}

$GpuFlags = if ($Runtime -eq 'podman') { '--device', 'nvidia.com/gpu=all' } else { '--gpus', 'all' }

log "========================================================"
log "  DemoClaw Stack -- Full E2E Startup"
log "========================================================"
log "Runtime: $Runtime"

# ---------------------------------------------------------------------------
# Validate NVIDIA GPU
# ---------------------------------------------------------------------------
log "Checking NVIDIA GPU ..."
if (-not (Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue)) {
    logerr "nvidia-smi not found. Install NVIDIA drivers."
}
$null = & nvidia-smi 2>&1
if ($LASTEXITCODE -ne 0) {
    logerr "nvidia-smi failed. Check NVIDIA driver installation."
}
logok "NVIDIA GPU OK."

# ---------------------------------------------------------------------------
# Helper: Invoke-ContainerCmd — run & check exit code
# ---------------------------------------------------------------------------
function Invoke-ContainerCmd {
    param([string[]]$Args)
    & $Runtime @Args
    if ($LASTEXITCODE -ne 0) { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# Helper: Wait-Http — poll a URL until it responds or timeout expires
# ---------------------------------------------------------------------------
function Wait-Http {
    param(
        [string]$Url,
        [int]$TimeoutSec,
        [int]$IntervalSec = 5,
        [int]$ProgressEvery = 30
    )
    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($resp.StatusCode -lt 400) { return $true }
        } catch { }
        Start-Sleep -Seconds $IntervalSec
        $elapsed += $IntervalSec
        if ($elapsed % $ProgressEvery -eq 0) {
            log "  ... waiting for $Url ($elapsed/${TimeoutSec}s)"
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Helper: Get-ContainerState
# ---------------------------------------------------------------------------
function Get-ContainerState {
    param([string]$Name)
    $state = & $Runtime container inspect --format '{{.State.Status}}' $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    return ($state -join '').Trim()
}

# ---------------------------------------------------------------------------
# Helper: Ensure-Image — pull from registry; fall back to local build
# ---------------------------------------------------------------------------
function Ensure-Image {
    param(
        [string]$ImageTag,
        [string]$BuildContext
    )
    log "Acquiring image '$ImageTag' ..."
    log "  Strategy: pull from registry first, local build fallback"
    log "  Pulling '$ImageTag' from registry ..."

    & $Runtime pull $ImageTag 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        logok "  Pull succeeded. Using registry image '$ImageTag'."
        return
    }

    logwarn "Pull failed for '$ImageTag'. Falling back to local build ..."
    log "  Building '$ImageTag' from $BuildContext ..."

    if (-not (Test-Path $BuildContext -PathType Container)) {
        logerr "Build context directory does not exist: $BuildContext"
    }
    if (-not (Test-Path (Join-Path $BuildContext 'Dockerfile'))) {
        logerr "No Dockerfile found in build context: $BuildContext"
    }

    & $Runtime build -t $ImageTag $BuildContext
    if ($LASTEXITCODE -ne 0) {
        logerr "Both pull and local build failed for '$ImageTag'. Cannot proceed."
    }
    logok "  Local build succeeded. Image '$ImageTag' is ready."
}

# ===========================================================================
# Phase 0: Clean up old containers and network
# ===========================================================================
log ""
log "--- Phase 0: Cleanup ---"

foreach ($cname in @($OcContainer, $VllmContainer)) {
    & $Runtime container inspect $cname >$null 2>&1
    if ($LASTEXITCODE -eq 0) {
        log "Removing old container '$cname' ..."
        & $Runtime rm -f $cname >$null 2>&1
    }
}

& $Runtime network inspect $Network >$null 2>&1
if ($LASTEXITCODE -eq 0) {
    log "Removing old network '$Network' ..."
    & $Runtime network rm $Network >$null 2>&1
}

# ===========================================================================
# Phase 1: Acquire images (pull from Docker Hub first; local build fallback)
# ===========================================================================
log ""
log "--- Phase 1: Acquire images ---"

Ensure-Image -ImageTag $VllmImage     -BuildContext (Join-Path $ProjectRoot 'vllm')
Ensure-Image -ImageTag $OpenclawImage -BuildContext (Join-Path $ProjectRoot 'openclaw')

logok "Images ready."

# ===========================================================================
# Phase 2: Create network + start vLLM
# ===========================================================================
log ""
log "--- Phase 2: Start vLLM ---"

log "Creating network '$Network' ..."
& $Runtime network create $Network
if ($LASTEXITCODE -ne 0) { logerr "Failed to create network." }

if (-not (Test-Path $HfCacheDir)) {
    New-Item -ItemType Directory -Path $HfCacheDir -Force | Out-Null
}

log "Starting vLLM container ..."
log "  Model        : $ModelName"
log "  Quantization : $Quantization"
log "  Context      : $MaxModelLen"
log "  GPU mem util : $GpuMemoryUtilization"

& $Runtime run -d `
    --name $VllmContainer `
    --network $Network `
    --hostname vllm `
    --network-alias vllm `
    @GpuFlags `
    --restart unless-stopped `
    --shm-size 1g `
    -p "${VllmPort}:${VllmPort}" `
    -v "${HfCacheDir}:/root/.cache/huggingface:rw" `
    -e "MODEL_NAME=$ModelName" `
    -e "MAX_MODEL_LEN=$MaxModelLen" `
    -e "GPU_MEMORY_UTILIZATION=$GpuMemoryUtilization" `
    -e "QUANTIZATION=$Quantization" `
    -e "DTYPE=$Dtype" `
    -e 'VLLM_ATTENTION_BACKEND=FLASHINFER' `
    $VllmImage

if ($LASTEXITCODE -ne 0) { logerr "Failed to start vLLM container." }

log "vLLM container started. Waiting for health ..."

# ---------------------------------------------------------------------------
# Wait for vLLM /health (with container-died detection)
# ---------------------------------------------------------------------------
$elapsed = 0
$vllmHealthUrl = "http://localhost:${VllmPort}/health"
$healthy = $false

while ($elapsed -lt $VllmHealthTimeout) {
    $state = Get-ContainerState $VllmContainer
    if ($state -eq 'exited' -or $state -eq 'dead') {
        log "ERROR: vLLM container exited unexpectedly."
        & $Runtime logs --tail 20 $VllmContainer 2>&1
        exit 1
    }

    try {
        $resp = Invoke-WebRequest -Uri $vllmHealthUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($resp.StatusCode -lt 400) { $healthy = $true; break }
    } catch { }

    Start-Sleep -Seconds 5
    $elapsed += 5
    if ($elapsed % 30 -eq 0) {
        log "  ... vLLM loading ($elapsed/${VllmHealthTimeout}s)"
    }
}

if (-not $healthy) {
    logerr "vLLM did not become healthy within ${VllmHealthTimeout}s. Check logs: $Runtime logs $VllmContainer"
}
logok "vLLM /health OK."

# ---------------------------------------------------------------------------
# Verify /v1/models
# ---------------------------------------------------------------------------
log "Checking /v1/models ..."
$modelsElapsed = 0
while ($modelsElapsed -lt 60) {
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:${VllmPort}/v1/models" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($resp.StatusCode -lt 400) {
            logok "vLLM /v1/models OK. Model ready."
            break
        }
    } catch { }
    Start-Sleep -Seconds 5
    $modelsElapsed += 5
}

# ===========================================================================
# Phase 3: Start OpenClaw
# ===========================================================================
log ""
log "--- Phase 3: Start OpenClaw ---"

log "Starting OpenClaw container ..."

& $Runtime run -d `
    --name $OcContainer `
    --network $Network `
    --hostname openclaw `
    --network-alias openclaw `
    --restart unless-stopped `
    -p "${OcPort}:${OcPort}" `
    -p '18791:18791' `
    -e 'VLLM_BASE_URL=http://vllm:8000/v1' `
    -e 'VLLM_API_KEY=EMPTY' `
    -e "VLLM_MODEL_NAME=$ModelName" `
    -e "OPENCLAW_PORT=$OcPort" `
    $OpenclawImage

if ($LASTEXITCODE -ne 0) { logerr "Failed to start OpenClaw container." }

log "OpenClaw container started. Waiting for dashboard ..."

# ---------------------------------------------------------------------------
# Wait for OpenClaw dashboard
# ---------------------------------------------------------------------------
$ocElapsed = 0
$ocHealthy = $false
$ocUrl = "http://localhost:${OcPort}/"

while ($ocElapsed -lt $OcHealthTimeout) {
    $state = Get-ContainerState $OcContainer
    if ($state -eq 'exited' -or $state -eq 'dead') {
        log "ERROR: OpenClaw container exited unexpectedly."
        & $Runtime logs --tail 20 $OcContainer 2>&1
        exit 1
    }

    try {
        $resp = Invoke-WebRequest -Uri $ocUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($resp.StatusCode -lt 400) { $ocHealthy = $true; break }
    } catch { }

    Start-Sleep -Seconds 3
    $ocElapsed += 3
    if ($ocElapsed % 15 -eq 0) {
        log "  ... waiting for OpenClaw ($ocElapsed/${OcHealthTimeout}s)"
    }
}

if (-not $ocHealthy) {
    logerr "OpenClaw dashboard did not respond within ${OcHealthTimeout}s. Check logs: $Runtime logs $OcContainer"
}
logok "OpenClaw dashboard responding."

# ===========================================================================
# Phase 4: Show result
# ===========================================================================
log ""
log "========================================================"
log "  DemoClaw is running!"
log "========================================================"
log ""
log "  vLLM API : http://localhost:${VllmPort}/v1"
log "  Model    : $ModelName"
log "  Runtime  : $Runtime"
log ""

# Try to get tokenized dashboard URL from openclaw binary
$DashboardUrl = ''
try {
    $raw = & $Runtime exec $OcContainer openclaw dashboard --no-open 2>$null
    if ($raw) {
        $match = [regex]::Match(($raw -join ' '), 'https?://\S+')
        if ($match.Success) {
            $DashboardUrl = $match.Value -replace '127\.0\.0\.1', 'localhost'
        }
    }
} catch { }

if ($DashboardUrl) {
    log "  Dashboard: $DashboardUrl"
} else {
    log "  Dashboard: http://localhost:${OcPort}"
}

log ""
log "  NOTE: On first connect, click `"Connect`" in the browser."
log "        The device pairing is auto-approved within ~2 seconds."
log "        If needed, click `"Connect`" again after approval."
log ""
log "  Stop with: .\scripts\stop.sh  (or docker rm -f democlaw-vllm democlaw-openclaw)"
log "========================================================"
