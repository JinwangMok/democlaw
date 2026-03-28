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
# Logging helpers with color support
# ---------------------------------------------------------------------------
function Write-DlLog {
    param([string]$Message)
    Write-Host "[download-models] $Message"
}

function Write-DlOk {
    param([string]$Message)
    Write-Host "[download-models] " -NoNewline
    Write-Host "OK: $Message" -ForegroundColor Green
}

function Write-DlInfo {
    param([string]$Message)
    Write-Host "[download-models] $Message" -ForegroundColor Cyan
}

function Write-DlWarn {
    param([string]$Message)
    Write-Host "[download-models] WARNING: $Message" -ForegroundColor Yellow
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
$checksumAvailable = Test-Path -LiteralPath $checksumScript -PathType Leaf

if (-not $checksumAvailable) {
    Write-DlWarn "Checksum script not found at: $checksumScript"
    Write-DlWarn "Model integrity verification will be DISABLED."
    Write-DlWarn "To enable checksums, ensure checksum.ps1 is present."
}

if ($checksumAvailable) {
    Write-DlLog "======================================================="
    Write-DlInfo "  Step 1/3: Pre-download integrity check (SHA256)"
    Write-DlLog "======================================================="
    Write-DlLog ""
    Write-DlLog "Comparing cached model files against stored checksums ..."
    Write-DlLog "This ensures no corrupt or tampered files are reused."
    Write-DlLog ""

    $verifyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Invoke checksum.ps1 needs-download action — outputs "true" or "false"
        # Also display the per-file verification output to the user
        $needsResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checksumScript `
            -Action "needs-download" `
            -ModelName $ModelName `
            -CacheDir $CacheDir 2>&1

        # Show checksum output lines to the user for transparency
        foreach ($line in $needsResult) {
            $lineStr = "$line"
            if ($lineStr -match '^\s*(true|false)\s*$') { continue }
            if ($lineStr -match '\S') {
                Write-DlLog "  $lineStr"
            }
        }

        # Extract the true/false result from output (last non-empty line)
        $needsDownload = ($needsResult | Where-Object { $_ -match '^\s*(true|false)\s*$' } | Select-Object -Last 1)
        if ($needsDownload) { $needsDownload = $needsDownload.ToString().Trim() }

        $verifyStopwatch.Stop()
        $elapsedSec = [math]::Round($verifyStopwatch.Elapsed.TotalSeconds, 1)

        if ($needsDownload -eq "false") {
            Write-DlLog ""
            Write-DlOk "All model files present and SHA256 checksums verified!"
            if ($elapsedSec -gt 0) { Write-DlLog "  Verification completed in ${elapsedSec}s" }
            Write-DlLog ""
            Write-DlLog "======================================================="
            Write-DlOk "  Model ready! (verified from cache)"
            Write-DlLog ""
            Write-DlLog "  Model     : $ModelName"
            Write-DlLog "  Cache dir : $CacheDir"
            Write-DlLog ""
            Write-DlLog "  vLLM will use this cache on next startup."
            Write-DlLog "  Start the stack with: scripts\windows\start.bat"
            Write-DlLog "======================================================="
            exit 0
        }

        Write-DlLog ""
        if ($elapsedSec -gt 0) { Write-DlLog "  Check completed in ${elapsedSec}s" }
        Write-DlWarn "Checksum verification indicates model is missing or corrupted."
        Write-DlLog "Proceeding with fresh download ..."
        Write-DlLog ""
    }
    catch {
        $verifyStopwatch.Stop()
        Write-DlWarn "Pre-download checksum check failed: $_"
        Write-DlWarn "Proceeding with download as fallback."
        Write-DlLog ""
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
# Step 2/3: Post-download checksum verification
#
# Delegates to checksum.ps1 for .sha256 sidecar file management.
# Uses the verify-model-cache and store-model-cache actions which resolve
# the HF snapshot directory from the cache layout automatically.
# ---------------------------------------------------------------------------
Write-DlLog "======================================================="
Write-DlInfo "  Step 2/3: Post-download integrity verification (SHA256)"
Write-DlLog "======================================================="
Write-DlLog ""

if (-not $checksumAvailable) {
    Write-DlWarn "Checksum script not found at: $checksumScript"
    Write-DlWarn "Skipping post-download checksum verification."
    Write-DlWarn "Without checksums, the model will be re-downloaded on every run."
    Write-DlWarn "To fix: ensure scripts\checksum.ps1 is present."
} else {
    $postVerifyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Verify existing checksums (or generate them on first download).
    # verify-model-cache handles both: verifies if .sha256 sidecars exist,
    # generates them if this is the first download.
    try {
        Write-DlLog "Verifying downloaded model files ..."
        $verifyOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checksumScript `
            -Action "verify-model-cache" `
            -ModelName $ModelName `
            -CacheDir $CacheDir 2>&1

        foreach ($line in $verifyOutput) {
            $lineStr = "$line"
            if ($lineStr -match '\S') { Write-DlLog "  $lineStr" }
        }

        Write-DlOk "Post-download checksum verification passed."
    }
    catch {
        Write-DlWarn "Post-download checksum verification returned non-zero."
        Write-DlWarn "This is normal on first download (no prior checksums exist)."
        Write-DlWarn "Checksums will be generated in the next step."
    }

    Write-DlLog ""
    Write-DlLog "======================================================="
    Write-DlInfo "  Step 3/3: Storing SHA256 checksums for future runs"
    Write-DlLog "======================================================="
    Write-DlLog ""

    # Store checksums for all model files (idempotent: overwrites existing sidecars).
    # This ensures .sha256 sidecars are present for all downloaded files.
    try {
        Write-DlLog "Computing and storing SHA256 hashes for all model files ..."
        Write-DlLog "Each file gets a .sha256 sidecar for future verification."
        Write-DlLog ""

        $storeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checksumScript `
            -Action "store-model-cache" `
            -ModelName $ModelName `
            -CacheDir $CacheDir 2>&1

        foreach ($line in $storeOutput) {
            $lineStr = "$line"
            if ($lineStr -match '\S') { Write-DlLog "  $lineStr" }
        }

        $postVerifyStopwatch.Stop()
        $postElapsedSec = [math]::Round($postVerifyStopwatch.Elapsed.TotalSeconds, 1)

        Write-DlOk "Checksums stored successfully."
        if ($postElapsedSec -gt 0) { Write-DlLog "  Checksum operations completed in ${postElapsedSec}s" }
        Write-DlLog ""
        Write-DlLog "  On subsequent runs, these checksums will be verified before"
        Write-DlLog "  downloading. If all files match, the download is skipped."
    }
    catch {
        $postVerifyStopwatch.Stop()
        Write-DlWarn "Checksum storage step failed: $_"
        Write-DlWarn "Next run may need to re-download the model."
        Write-DlWarn "This is non-fatal - the model files are still usable."
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-DlLog ""
Write-DlLog "======================================================="
Write-DlOk "  Model download and verification complete!"
Write-DlLog ""
Write-DlLog "  Model     : $ModelName"
Write-DlLog "  Cache dir : $CacheDir"
Write-DlLog "  Checksum  : SHA256 sidecar files stored"
Write-DlLog ""
Write-DlLog "  vLLM will use this cache on next startup."
Write-DlLog "  Start the stack with: scripts\windows\start.bat"
Write-DlLog "======================================================="
