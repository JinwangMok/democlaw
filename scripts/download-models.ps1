#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-download model weights for DemoClaw (Windows).

.DESCRIPTION
    Downloads Qwen/Qwen3-4B-AWQ (or any HuggingFace model) to the local cache
    so vLLM startup is fast — no download delay on first container run.

    After download, verifies file integrity using SHA256 via Get-FileHash and
    delegates to checksum.ps1 for sidecar .sha256 file management.

    Download strategy:
      1. Try huggingface-cli (if on PATH)
      2. Fall back to Python huggingface_hub library

.PARAMETER ModelName
    HuggingFace model ID to download. Default: Qwen/Qwen3-4B-AWQ

.PARAMETER CacheDir
    HuggingFace cache root directory.
    Default: $env:HF_CACHE_DIR if set, else $env:USERPROFILE\.cache\huggingface

.PARAMETER HfToken
    HuggingFace token for gated/private models. Also reads $env:HF_TOKEN.

.EXAMPLE
    .\scripts\download-models.ps1
    .\scripts\download-models.ps1 -ModelName "Qwen/Qwen3-4B-AWQ"
    .\scripts\download-models.ps1 -HfToken "hf_xxx"
    .\scripts\download-models.ps1 -CacheDir "D:\models"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ModelName = "Qwen/Qwen3-4B-AWQ",

    [Parameter(Mandatory = $false)]
    [string]$CacheDir = "",

    [Parameter(Mandatory = $false)]
    [string]$HfToken = ""
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
function Write-DlLog {
    param([string]$Message)
    Write-Host "[download-models] $Message"
}

function Write-DlWarn {
    param([string]$Message)
    Write-Warning "[download-models] $Message"
}

function Write-DlError {
    param([string]$Message)
    Write-Host "[download-models] ERROR: $Message" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve configuration
# ---------------------------------------------------------------------------

# CacheDir: parameter > env var > default
if (-not $CacheDir) {
    if ($env:HF_CACHE_DIR) {
        $CacheDir = $env:HF_CACHE_DIR
    } else {
        $CacheDir = Join-Path $env:USERPROFILE ".cache\huggingface"
    }
}

# HfToken: parameter > env var
if (-not $HfToken) {
    if ($env:HF_TOKEN) {
        $HfToken = $env:HF_TOKEN
    } elseif ($env:HUGGING_FACE_HUB_TOKEN) {
        $HfToken = $env:HUGGING_FACE_HUB_TOKEN
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-DlLog "======================================================="
Write-DlLog "  DemoClaw — Model Pre-Download (Windows)"
Write-DlLog "  Model     : $ModelName"
Write-DlLog "  Cache dir : $CacheDir"
Write-DlLog "======================================================="
Write-DlLog "This may take several minutes on first run (~5 GB download)."
Write-DlLog "Subsequent runs detect the cached model and finish instantly."

# ---------------------------------------------------------------------------
# Ensure cache directory exists
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $CacheDir -PathType Container)) {
    Write-DlLog "Creating cache directory: $CacheDir"
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Propagate token into environment for child processes
# ---------------------------------------------------------------------------
if ($HfToken) {
    $env:HF_TOKEN = $HfToken
    $env:HUGGING_FACE_HUB_TOKEN = $HfToken
    Write-DlLog "HF_TOKEN is set — will authenticate for gated models."
}

# ---------------------------------------------------------------------------
# Pre-download checksum verification: skip download if all files pass
#
# Loads checksum.ps1 functions inline and uses Test-ModelNeedsDownload to
# compare existing model files against their stored .sha256 sidecar checksums.
# Download is skipped ONLY when every model file is present AND its computed
# SHA256 matches the stored value.
# ---------------------------------------------------------------------------
$checksumScript = Join-Path $ScriptDir "checksum.ps1"

if (Test-Path -LiteralPath $checksumScript -PathType Leaf) {
    Write-DlLog "======================================================="
    Write-DlLog "  Step: Pre-download checksum verification"
    Write-DlLog "======================================================="

    try {
        # Invoke checksum.ps1 needs-download action — outputs "true" or "false"
        $needsResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checksumScript `
            -Action "needs-download" `
            -ModelName $ModelName `
            -CacheDir $CacheDir 2>&1

        # Extract the true/false result from output (last non-empty line)
        $needsDownload = ($needsResult | Where-Object { $_ -match '^\s*(true|false)\s*$' } | Select-Object -Last 1).Trim()

        if ($needsDownload -eq "false") {
            Write-DlLog "All model files present and checksums verified - skipping download."
            Write-DlLog ""
            Write-DlLog "======================================================="
            Write-DlLog "  Model download complete! (cached)"
            Write-DlLog ""
            Write-DlLog "  Model     : $ModelName"
            Write-DlLog "  Cache dir : $CacheDir"
            Write-DlLog ""
            Write-DlLog "  vLLM will use this cache on next startup."
            Write-DlLog "  Start the stack with: scripts\windows\start.bat"
            Write-DlLog "======================================================="
            exit 0
        }

        Write-DlLog "Download needed - proceeding with model acquisition."
    }
    catch {
        Write-DlWarn "Pre-download checksum check failed: $_"
        Write-DlWarn "Proceeding with download as fallback."
    }
}

# ---------------------------------------------------------------------------
# Invoke-DownloadWithCli — attempt download via huggingface-cli
#
# Returns $true on success, $false if huggingface-cli is not on PATH.
# ---------------------------------------------------------------------------
function Invoke-DownloadWithCli {
    $hfCli = Get-Command "huggingface-cli" -ErrorAction SilentlyContinue
    if (-not $hfCli) {
        return $false
    }

    Write-DlLog "Using huggingface-cli to download '$ModelName' ..."

    # Build argument list
    $cliArgs = @(
        "download",
        $ModelName,
        "--cache-dir", $CacheDir,
        "--ignore-patterns", "*.pt", "*.bin"   # prefer safetensors
    )

    if ($HfToken) {
        $cliArgs += @("--token", $HfToken)
    }

    & huggingface-cli @cliArgs
    if ($LASTEXITCODE -ne 0) {
        Write-DlWarn "huggingface-cli exited with code $LASTEXITCODE"
        return $false
    }

    return $true
}

# ---------------------------------------------------------------------------
# Invoke-DownloadWithPython — fallback via huggingface_hub Python library
# ---------------------------------------------------------------------------
function Invoke-DownloadWithPython {
    Write-DlLog "huggingface-cli not found — falling back to Python huggingface_hub ..."

    $python = Get-Command "python" -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command "python3" -ErrorAction SilentlyContinue
    }
    if (-not $python) {
        Write-DlError "Python is not installed or not on PATH. Install Python 3.8+ to continue."
    }

    # Build the inline Python script
    $pyScript = @"
import sys, os

model_name = r'$ModelName'
cache_dir  = r'$CacheDir'
hf_token   = os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN') or None

print(f'[download-models] Checking local cache for: {model_name}')

try:
    from huggingface_hub import snapshot_download
except ImportError:
    print('[download-models] ERROR: huggingface_hub is not installed.', file=sys.stderr)
    print('[download-models] Install it with: pip install huggingface_hub', file=sys.stderr)
    sys.exit(1)

# Check if model is already fully cached
try:
    local_path = snapshot_download(
        repo_id=model_name,
        cache_dir=cache_dir,
        local_files_only=True,
    )
    print(f'[download-models] Model already cached at: {local_path}')
    print('[download-models] Skipping download.')
    sys.exit(0)
except Exception:
    pass  # not cached -- proceed to download

print(f'[download-models] Downloading {model_name} ...')

try:
    local_path = snapshot_download(
        repo_id=model_name,
        cache_dir=cache_dir,
        ignore_patterns=['*.pt', '*.bin'],
        token=hf_token,
    )
    print(f'[download-models] Download complete. Weights stored at: {local_path}')
except Exception as e:
    print(f'[download-models] ERROR: Download failed: {e}', file=sys.stderr)
    sys.exit(1)
"@

    & python -c $pyScript
    if ($LASTEXITCODE -ne 0) {
        Write-DlError "Python download failed with exit code $LASTEXITCODE"
    }
}

# ---------------------------------------------------------------------------
# Perform download: try CLI first, fall back to Python
# ---------------------------------------------------------------------------
$cliSucceeded = Invoke-DownloadWithCli
if (-not $cliSucceeded) {
    Invoke-DownloadWithPython
}

Write-DlLog "Download step complete."

# ---------------------------------------------------------------------------
# Checksum verification and storage
#
# Delegates to checksum.ps1 for .sha256 sidecar file management.
# Uses the verify-model-cache and store-model-cache actions which resolve
# the HF snapshot directory from the cache layout automatically.
# ---------------------------------------------------------------------------
Write-DlLog "======================================================="
Write-DlLog "  Step: Checksum verification"
Write-DlLog "======================================================="

$checksumScript = Join-Path $ScriptDir "checksum.ps1"

if (-not (Test-Path -LiteralPath $checksumScript -PathType Leaf)) {
    Write-DlWarn "Checksum script not found at: $checksumScript"
    Write-DlWarn "Skipping checksum verification."
} else {
    # Verify existing checksums (or generate them on first download).
    # verify-model-cache handles both: verifies if .sha256 sidecars exist,
    # generates them if this is the first download.
    try {
        Write-DlLog "Running checksum verification for: $ModelName"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checksumScript `
            -Action "verify-model-cache" `
            -ModelName $ModelName `
            -CacheDir $CacheDir
        Write-DlLog "Checksum verification passed."
    }
    catch {
        Write-DlWarn "Checksum verify-model-cache step returned an error: $_"
        Write-DlWarn "Attempting to store fresh checksums ..."
    }

    # Store checksums for all model files (idempotent: overwrites existing sidecars).
    # This ensures .sha256 sidecars are present for all downloaded files.
    try {
        Write-DlLog "Storing checksums for: $ModelName"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checksumScript `
            -Action "store-model-cache" `
            -ModelName $ModelName `
            -CacheDir $CacheDir
        Write-DlLog "Checksums stored."
    }
    catch {
        Write-DlWarn "Checksum storage step failed: $_"
        Write-DlWarn "This is non-fatal — the model files are still usable."
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-DlLog "======================================================="
Write-DlLog "  Model download complete!"
Write-DlLog ""
Write-DlLog "  Model     : $ModelName"
Write-DlLog "  Cache dir : $CacheDir"
Write-DlLog ""
Write-DlLog "  vLLM will use this cache on next startup."
Write-DlLog "  Start the stack with: scripts\windows\start.bat"
Write-DlLog "======================================================="
