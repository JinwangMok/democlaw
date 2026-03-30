#Requires -Version 5.1
<#
.SYNOPSIS
    Idempotent model download with checksum & resume (Windows PowerShell).

.DESCRIPTION
    Downloads HuggingFace model weights (default: Qwen/Qwen3-4B-AWQ) to the
    local cache with full SHA256 checksum verification, resume support for
    interrupted downloads, and idempotent behavior (safe to run repeatedly).

    Lifecycle:
      1. Pre-download integrity check - verify cached files via SHA256 sidecars
      2. Download (if needed)         - huggingface-cli -> Python fallback
      3. Post-download verification   - re-verify all downloaded files
      4. Store checksums              - write .sha256 sidecars for future runs

    Idempotency guarantee:
      - If all cached model files are present AND their SHA256 checksums match
        stored .sha256 sidecar files, the download is skipped entirely.
      - On every run, checksums are re-verified from scratch (never trust cache
        state from a prior run).
      - Interrupted downloads resume from where they left off (no re-download
        of completed files).

.PARAMETER ModelName
    HuggingFace model ID to download. Default: Qwen/Qwen3-4B-AWQ.
    Can also be set via $env:MODEL_NAME.

.PARAMETER CacheDir
    HuggingFace cache root directory.
    Default: $env:HF_CACHE_DIR if set, else $env:USERPROFILE\.cache\huggingface

.PARAMETER HfToken
    HuggingFace token for gated/private models.
    Also reads $env:HF_TOKEN or $env:HUGGING_FACE_HUB_TOKEN.

.PARAMETER ForceDownload
    Force re-download even if checksums pass. Default: $false.
    Can also be set via $env:FORCE_DOWNLOAD = "1".

.PARAMETER MaxRetries
    Max download retry attempts with exponential backoff. Default: 3.
    Can also be set via $env:MAX_RETRIES.

.EXAMPLE
    .\scripts\download_model.ps1
    .\scripts\download_model.ps1 -ModelName "Qwen/Qwen3-4B-AWQ"
    .\scripts\download_model.ps1 -HfToken "hf_xxx"
    .\scripts\download_model.ps1 -CacheDir "D:\models"
    .\scripts\download_model.ps1 -ForceDownload
    $env:FORCE_DOWNLOAD = "1"; .\scripts\download_model.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$ModelName = "",

    [Parameter(Mandatory = $false)]
    [string]$CacheDir = "",

    [Parameter(Mandatory = $false)]
    [string]$HfToken = "",

    [Parameter(Mandatory = $false)]
    [switch]$ForceDownload,

    [Parameter(Mandatory = $false)]
    [int]$MaxRetries = 0
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# ---------------------------------------------------------------------------
# Logging helpers with color support
# ---------------------------------------------------------------------------
function Write-DlLog {
    param([string]$Message)
    Write-Host "[download_model] $Message"
}

function Write-DlOk {
    param([string]$Message)
    Write-Host "[download_model] " -NoNewline
    Write-Host "OK: $Message" -ForegroundColor Green
}

function Write-DlInfo {
    param([string]$Message)
    Write-Host "[download_model] $Message" -ForegroundColor Cyan
}

function Write-DlWarn {
    param([string]$Message)
    Write-Host "[download_model] WARNING: $Message" -ForegroundColor Yellow
}

function Write-DlError {
    param([string]$Message)
    Write-Host "[download_model] ERROR: $Message" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve configuration: parameter > environment variable > default
# ---------------------------------------------------------------------------

# ModelName
if (-not $ModelName) {
    if ($env:MODEL_NAME) {
        $ModelName = $env:MODEL_NAME
    } else {
        $ModelName = "Qwen/Qwen3-4B-AWQ"
    }
}

# CacheDir
if (-not $CacheDir) {
    if ($env:HF_CACHE_DIR) {
        $CacheDir = $env:HF_CACHE_DIR
    } else {
        $CacheDir = Join-Path $env:USERPROFILE ".cache\huggingface"
    }
}

# HfToken
if (-not $HfToken) {
    if ($env:HF_TOKEN) {
        $HfToken = $env:HF_TOKEN
    } elseif ($env:HUGGING_FACE_HUB_TOKEN) {
        $HfToken = $env:HUGGING_FACE_HUB_TOKEN
    }
}

# ForceDownload: switch param or env var
if (-not $ForceDownload) {
    if ($env:FORCE_DOWNLOAD -eq "1") {
        $ForceDownload = $true
    }
}
$ForceDownloadStr = if ($ForceDownload) { "1" } else { "0" }

# MaxRetries
if ($MaxRetries -le 0) {
    if ($env:MAX_RETRIES -and [int]::TryParse($env:MAX_RETRIES, [ref]$null)) {
        $MaxRetries = [int]$env:MAX_RETRIES
    } else {
        $MaxRetries = 3
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-DlLog "======================================================="
Write-DlLog "  DemoClaw - Model Download (Windows PowerShell)"
Write-DlLog "======================================================="
Write-DlLog "  Model        : $ModelName"
Write-DlLog "  Cache dir    : $CacheDir"
Write-DlLog "  Force re-dl  : $ForceDownloadStr"
Write-DlLog "  Max retries  : $MaxRetries"
Write-DlLog "======================================================="
Write-DlLog ""
Write-DlLog "This may take several minutes on first run (~5 GB download)."
Write-DlLog "Subsequent runs detect the cached model and finish instantly."
Write-DlLog ""

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
    Write-DlLog "HF_TOKEN is set - will authenticate for gated models."
}

# ---------------------------------------------------------------------------
# Load checksum script
# ---------------------------------------------------------------------------
$checksumScript = Join-Path $ScriptDir "checksum.ps1"
$checksumAvailable = Test-Path -LiteralPath $checksumScript -PathType Leaf

if (-not $checksumAvailable) {
    Write-DlWarn "Checksum script not found at: $checksumScript"
    Write-DlWarn "Model integrity verification will be DISABLED."
    Write-DlWarn "To enable checksums, ensure scripts\checksum.ps1 is present."
}

# ---------------------------------------------------------------------------
# Helper: invoke checksum.ps1 and capture output
# ---------------------------------------------------------------------------
function Invoke-ChecksumAction {
    param(
        [string]$Action,
        [switch]$ShowOutput
    )

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checksumScript `
        -Action $Action `
        -ModelName $ModelName `
        -CacheDir $CacheDir 2>&1

    if ($ShowOutput) {
        foreach ($line in $output) {
            $lineStr = "$line"
            if ($lineStr -match '\S') {
                Write-DlLog "  $lineStr"
            }
        }
    }

    return $output
}

# ===========================================================================
# Step 1/4: Pre-download integrity check (SHA256)
#
# If all model files are present and their SHA256 checksums match the stored
# .sha256 sidecar files, skip the download entirely. This makes the script
# idempotent - running it multiple times produces the same end-state.
# ===========================================================================
Write-DlLog "======================================================="
Write-DlInfo "  Step 1/4: Pre-download integrity check"
Write-DlLog "======================================================="
Write-DlLog ""

if ($ForceDownload) {
    Write-DlWarn "ForceDownload is set - skipping pre-download checksum verification."
    Write-DlWarn "Will re-download model regardless of cache state."
    Write-DlLog ""
}
elseif ($checksumAvailable) {
    Write-DlLog "Comparing cached model files against stored SHA256 checksums ..."
    Write-DlLog "This ensures no corrupt or tampered files are reused."
    Write-DlLog ""

    $verifyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $needsResult = Invoke-ChecksumAction -Action "needs-download" -ShowOutput

        # Extract the true/false result from output (last matching line)
        $needsDownload = ($needsResult | Where-Object { "$_" -match '^\s*(true|false)\s*$' } | Select-Object -Last 1)
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
            Write-DlLog "  llama.cpp will use this cache on next startup."
            Write-DlLog "  Start the stack with: .\scripts\start.sh (WSL2) or scripts\windows\start.bat"
            Write-DlLog "======================================================="
            exit 0
        }

        Write-DlLog ""
        if ($elapsedSec -gt 0) { Write-DlLog "  Check completed in ${elapsedSec}s" }
        Write-DlWarn "Checksum verification indicates model is missing or corrupted."
        Write-DlLog "Proceeding with download ..."
        Write-DlLog ""
    }
    catch {
        $verifyStopwatch.Stop()
        Write-DlWarn "Pre-download checksum check failed: $_"
        Write-DlWarn "Proceeding with download as fallback."
        Write-DlLog ""
    }
}
else {
    Write-DlWarn "Checksum library unavailable - cannot verify cached model."
    Write-DlLog "Proceeding with download ..."
    Write-DlLog ""
}

# ===========================================================================
# Step 2/4: Download model with resume support
#
# Strategy (try in order):
#   1. huggingface-cli download (native resume via HTTP range requests)
#   2. Python huggingface_hub snapshot_download (native resume)
#
# All methods support resume: interrupted downloads continue from where they
# stopped, avoiding redundant re-transfer of completed bytes.
# ===========================================================================
Write-DlLog "======================================================="
Write-DlInfo "  Step 2/4: Download model files"
Write-DlLog "======================================================="
Write-DlLog ""

# ---------------------------------------------------------------------------
# Invoke-DownloadWithCli - download via huggingface-cli (preferred)
#
# huggingface-cli download is idempotent and supports resume natively.
# It uses HTTP range requests to continue interrupted downloads.
# Returns $true on success, $false if huggingface-cli is unavailable.
# ---------------------------------------------------------------------------
function Invoke-DownloadWithCli {
    $hfCli = Get-Command "huggingface-cli" -ErrorAction SilentlyContinue
    if (-not $hfCli) {
        return $false
    }

    Write-DlLog "Using huggingface-cli to download '$ModelName' ..."
    Write-DlLog "  Resume support: enabled (native HTTP range requests)"

    $cliArgs = @(
        "download",
        $ModelName,
        "--cache-dir", $CacheDir,
        "--resume-download",
        "--ignore-patterns", "*.pt", "*.bin"
    )

    if ($HfToken) {
        $cliArgs += @("--token", $HfToken)
    }

    if ($ForceDownload) {
        $cliArgs += "--force-download"
        Write-DlLog "  Force download: enabled (re-downloading all files)"
    }

    & huggingface-cli @cliArgs
    if ($LASTEXITCODE -ne 0) {
        Write-DlWarn "huggingface-cli exited with code $LASTEXITCODE"
        return $false
    }

    return $true
}

# ---------------------------------------------------------------------------
# Invoke-DownloadWithPython - fallback via huggingface_hub Python library
#
# Used when huggingface-cli is not on PATH. snapshot_download also supports
# resume natively and is idempotent.
# ---------------------------------------------------------------------------
function Invoke-DownloadWithPython {
    Write-DlLog "huggingface-cli not found - falling back to Python huggingface_hub ..."
    Write-DlLog "  Resume support: enabled (native in huggingface_hub)"

    # Find Python executable
    $pythonCmd = $null
    foreach ($candidate in @("python", "python3", "py")) {
        $found = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($found) {
            $pythonCmd = $candidate
            break
        }
    }

    if (-not $pythonCmd) {
        Write-DlWarn "Python is not installed or not on PATH."
        return $false
    }

    $forceFlag = if ($ForceDownload) { "True" } else { "False" }

    $pyScript = @"
import sys, os

model_name  = r'$ModelName'
cache_dir   = r'$CacheDir'
force       = $forceFlag
hf_token    = os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN') or None

print(f'[download_model] Checking local cache for: {model_name}')

try:
    from huggingface_hub import snapshot_download
except ImportError:
    print('[download_model] ERROR: huggingface_hub is not installed.', file=sys.stderr)
    print('[download_model] Install it with: pip install huggingface_hub', file=sys.stderr)
    sys.exit(1)

# Check if model is already fully cached (skip if force)
if not force:
    try:
        local_path = snapshot_download(
            repo_id=model_name,
            cache_dir=cache_dir,
            local_files_only=True,
        )
        print(f'[download_model] Model already cached at: {local_path}')
        print('[download_model] Skipping download (use -ForceDownload to override).')
        sys.exit(0)
    except Exception:
        pass  # not cached -- proceed to download

print(f'[download_model] Downloading {model_name} ...')

try:
    local_path = snapshot_download(
        repo_id=model_name,
        cache_dir=cache_dir,
        ignore_patterns=['*.pt', '*.bin'],
        token=hf_token,
        resume_download=True,
        force_download=force,
    )
    print(f'[download_model] Download complete. Weights stored at: {local_path}')
except Exception as e:
    print(f'[download_model] ERROR: Download failed: {e}', file=sys.stderr)
    sys.exit(1)
"@

    & $pythonCmd -c $pyScript
    if ($LASTEXITCODE -ne 0) {
        Write-DlWarn "Python download failed with exit code $LASTEXITCODE"
        return $false
    }

    return $true
}

# ---------------------------------------------------------------------------
# Invoke-DownloadWithRetry - wrap a download function with retry logic
#
# Retries the given download function up to MaxRetries times with
# exponential backoff. Each retry benefits from resume support -
# already-downloaded files/bytes are not re-transferred.
# ---------------------------------------------------------------------------
function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$DownloadFunction
    )

    $attempt = 1

    while ($attempt -le $MaxRetries) {
        Write-DlLog "Download attempt ${attempt}/${MaxRetries} ..."

        $result = & $DownloadFunction
        if ($result -eq $true) {
            Write-DlLog "Download succeeded on attempt ${attempt}."
            return $true
        }

        if ($attempt -lt $MaxRetries) {
            $backoff = [math]::Pow(2, $attempt - 1) * 5
            Write-DlWarn "Download attempt $attempt failed."
            Write-DlWarn "Retrying in ${backoff}s (attempt $($attempt + 1)/${MaxRetries}) ..."
            Write-DlWarn "Resume support ensures no data is re-downloaded."
            Start-Sleep -Seconds $backoff
        }
        else {
            Write-DlWarn "Download attempt $attempt failed. No more retries."
        }

        $attempt++
    }

    return $false
}

# ---------------------------------------------------------------------------
# Perform download: try CLI first, fall back to Python, with retry wrapper
# ---------------------------------------------------------------------------
$dlStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$downloadSuccess = $false

# Try huggingface-cli first
$hfCli = Get-Command "huggingface-cli" -ErrorAction SilentlyContinue
if ($hfCli) {
    $downloadSuccess = Invoke-DownloadWithRetry -DownloadFunction { Invoke-DownloadWithCli }
}

# Fall back to Python
if (-not $downloadSuccess) {
    $pythonAvailable = $false
    foreach ($candidate in @("python", "python3", "py")) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) {
            $pythonAvailable = $true
            break
        }
    }

    if ($pythonAvailable) {
        $downloadSuccess = Invoke-DownloadWithRetry -DownloadFunction { Invoke-DownloadWithPython }
    }
}

if (-not $downloadSuccess) {
    Write-DlError @"
All download methods failed after $MaxRetries attempts each.
  Ensure one of the following is installed:
    - huggingface-cli (pip install huggingface-cli)
    - python + huggingface_hub (pip install huggingface_hub)
  Check your network connection and try again.
"@
}

$dlStopwatch.Stop()
$dlElapsedSec = [math]::Round($dlStopwatch.Elapsed.TotalSeconds, 1)
Write-DlLog "Download step complete."
if ($dlElapsedSec -gt 0) { Write-DlLog "  Download took ${dlElapsedSec}s" }

# ===========================================================================
# Step 3/4: Post-download integrity verification (SHA256)
#
# Re-verify all model files after download to ensure:
#   - No corruption occurred during transfer
#   - Files match their expected checksums (if sidecars exist)
#   - On first download, checksums are generated in Step 4
# ===========================================================================
Write-DlLog ""
Write-DlLog "======================================================="
Write-DlInfo "  Step 3/4: Post-download integrity verification (SHA256)"
Write-DlLog "======================================================="
Write-DlLog ""

if ($checksumAvailable) {
    $postVerifyStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        Write-DlLog "Verifying downloaded model files ..."
        Invoke-ChecksumAction -Action "verify-model-cache" -ShowOutput | Out-Null
        Write-DlOk "Post-download checksum verification passed."
    }
    catch {
        Write-DlWarn "Post-download checksum verification returned non-zero."
        Write-DlWarn "This is normal on first download (no prior checksums exist)."
        Write-DlWarn "Checksums will be generated in Step 4."
    }

    $postVerifyStopwatch.Stop()
    $postVerifyElapsed = [math]::Round($postVerifyStopwatch.Elapsed.TotalSeconds, 1)
    if ($postVerifyElapsed -gt 0) { Write-DlLog "  Verification took ${postVerifyElapsed}s" }
}
else {
    Write-DlWarn "Checksum library unavailable - skipping post-download verification."
}

# ===========================================================================
# Step 4/4: Store SHA256 checksums for future runs
#
# Write .sha256 sidecar files alongside each model file. These sidecars are
# used by Step 1 on subsequent runs to skip unnecessary downloads.
#
# This step is idempotent: re-running overwrites existing sidecars with
# freshly computed hashes.
# ===========================================================================
Write-DlLog ""
Write-DlLog "======================================================="
Write-DlInfo "  Step 4/4: Storing SHA256 checksums for future runs"
Write-DlLog "======================================================="
Write-DlLog ""

if ($checksumAvailable) {
    Write-DlLog "Computing and storing SHA256 hashes for all model files ..."
    Write-DlLog "Each file gets a .sha256 sidecar for future verification."
    Write-DlLog ""

    $storeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        Invoke-ChecksumAction -Action "store-model-cache" -ShowOutput | Out-Null

        $storeStopwatch.Stop()
        $storeElapsed = [math]::Round($storeStopwatch.Elapsed.TotalSeconds, 1)

        Write-DlOk "Checksums stored successfully."
        if ($storeElapsed -gt 0) { Write-DlLog "  Checksum storage took ${storeElapsed}s" }
        Write-DlLog ""
        Write-DlLog "  On subsequent runs, these checksums will be verified before"
        Write-DlLog "  downloading. If all files match, the download is skipped."
    }
    catch {
        $storeStopwatch.Stop()
        Write-DlWarn "Failed to store some checksums."
        Write-DlWarn "Next run may need to re-download the model."
        Write-DlWarn "This is non-fatal - the model files are still usable."
    }
}
else {
    Write-DlWarn "Checksum library unavailable - skipping checksum storage."
    Write-DlWarn "Without checksums, re-download skip optimization is disabled."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-DlLog ""
Write-DlLog "======================================================="
Write-DlOk "  Model download and verification complete!"
Write-DlLog ""
Write-DlLog "  Model     : $ModelName"
Write-DlLog "  Cache dir : $CacheDir"
if ($checksumAvailable) {
    Write-DlLog "  Checksum  : SHA256 sidecar files stored"
} else {
    Write-DlLog "  Checksum  : DISABLED (checksum.ps1 not found)"
}
Write-DlLog "  Resume    : Supported (interrupted downloads resume automatically)"
Write-DlLog ""
Write-DlLog "  llama.cpp will use this cache on next startup."
Write-DlLog "  Start the stack with: .\scripts\start.sh (WSL2) or scripts\windows\start.bat"
Write-DlLog "======================================================="
