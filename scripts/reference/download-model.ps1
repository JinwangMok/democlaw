#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-download GGUF model weights for DemoClaw (Windows).

.DESCRIPTION
    Downloads Gemma 4 E4B Q4_K_M GGUF from HuggingFace so llama.cpp startup
    is fast — no download delay on first container run.

.PARAMETER ModelRepo
    HuggingFace repo ID. Default: unsloth/gemma-4-E4B-it-GGUF

.PARAMETER ModelFile
    GGUF filename. Default: gemma-4-E4B-it-Q4_K_M.gguf

.PARAMETER ModelDir
    Local directory for GGUF files.
    Default: $env:MODEL_DIR if set, else $env:USERPROFILE\.cache\democlaw\models

.PARAMETER HfToken
    HuggingFace token for gated models. Also reads $env:HF_TOKEN.

.EXAMPLE
    .\scripts\download-models.ps1
    .\scripts\download-models.ps1 -ModelDir "D:\models"
    .\scripts\download-models.ps1 -HfToken "hf_xxx"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ModelRepo = "unsloth/gemma-4-E4B-it-GGUF",

    [Parameter(Mandatory = $false)]
    [string]$ModelFile = "gemma-4-E4B-it-Q4_K_M.gguf",

    [Parameter(Mandatory = $false)]
    [string]$ModelDir = "",

    [Parameter(Mandatory = $false)]
    [string]$HfToken = ""
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Resolve defaults
# ---------------------------------------------------------------------------
if (-not $ModelDir) {
    $ModelDir = if ($env:MODEL_DIR) { $env:MODEL_DIR }
                else { Join-Path $env:USERPROFILE ".cache\democlaw\models" }
}
if (-not $HfToken -and $env:HF_TOKEN) { $HfToken = $env:HF_TOKEN }

$ModelPath = Join-Path $ModelDir $ModelFile
$HfUrl = "https://huggingface.co/$ModelRepo/resolve/main/$ModelFile"
$MinSize = 5000000000  # ~5 GB minimum

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Log   { param([string]$m) Write-Host "[download-model] $m" }
function Warn  { param([string]$m) Write-Warning "[download-model] $m" }
function Ok    { param([string]$m) Write-Host "[download-model] OK: $m" -ForegroundColor Green }
function Info  { param([string]$m) Write-Host "[download-model] $m" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Log "======================================================="
Log "  DemoClaw - Model Pre-Download (GGUF)"
Log "  Repo      : $ModelRepo"
Log "  File      : $ModelFile"
Log "  Save to   : $ModelPath"
Log "======================================================="
Log "This may take several minutes on first run (~5.7 GB download)."

# ---------------------------------------------------------------------------
# Ensure directory exists
# ---------------------------------------------------------------------------
if (-not (Test-Path $ModelDir)) {
    Log "Creating model directory: $ModelDir"
    New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Check if model already exists
# ---------------------------------------------------------------------------
if (Test-Path $ModelPath) {
    $fileInfo = Get-Item $ModelPath
    if ($fileInfo.Length -gt $MinSize) {
        Ok "Model already downloaded and valid."
        Log "  Path: $ModelPath"
        Log "  Size: $($fileInfo.Length) bytes"

        # Verify SHA256 if sidecar exists
        $shaFile = "$ModelPath.sha256"
        if (Test-Path $shaFile) {
            $storedHash = (Get-Content $shaFile -Raw).Trim().Split()[0]
            Log "  Verifying SHA256 checksum ..."
            $computed = (Get-FileHash -Path $ModelPath -Algorithm SHA256).Hash.ToLower()
            if ($computed -eq $storedHash.ToLower()) {
                Ok "SHA256 checksum verified."
            } else {
                Warn "SHA256 mismatch! Re-downloading ..."
                Remove-Item $ModelPath -Force
            }
        }

        if (Test-Path $ModelPath) {
            Log ""
            Log "======================================================="
            Ok "  Model ready! (verified from cache)"
            Log ""
            Log "  Start the stack with: .\scripts\start.ps1"
            Log "======================================================="
            exit 0
        }
    } else {
        Warn "Model file appears incomplete ($($fileInfo.Length) bytes). Re-downloading ..."
        Remove-Item $ModelPath -Force
    }
}

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
Log ""
Info "  Downloading $ModelFile ..."
Log "  URL: $HfUrl"

$tmpPath = "$ModelPath.tmp"
$webArgs = @{ Uri = $HfUrl; OutFile = $tmpPath }
if ($HfToken) {
    $webArgs.Headers = @{ Authorization = "Bearer $HfToken" }
    Log "  Using HF_TOKEN for authenticated download."
}

try {
    # Use BITS for better large-file handling on Windows
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        Log "  Using BITS transfer ..."
        $bitsArgs = @{
            Source      = $HfUrl
            Destination = $tmpPath
            DisplayName = "DemoClaw Model Download"
            Description = "Downloading $ModelFile from HuggingFace"
        }
        if ($HfToken) {
            # BITS doesn't support custom headers easily; fall back to Invoke-WebRequest
            throw "BITS does not support auth headers"
        }
        Start-BitsTransfer @bitsArgs
    } else {
        throw "No BITS"
    }
} catch {
    Log "  Using Invoke-WebRequest ..."
    $ProgressPreference = 'SilentlyContinue'  # huge speed improvement
    Invoke-WebRequest @webArgs -UseBasicParsing
    $ProgressPreference = 'Continue'
}

# Verify size
$tmpInfo = Get-Item $tmpPath
if ($tmpInfo.Length -lt $MinSize) {
    Remove-Item $tmpPath -Force
    throw "Downloaded file too small ($($tmpInfo.Length) bytes). Expected >= $MinSize."
}

# Move to final location
Move-Item $tmpPath $ModelPath -Force
Ok "Download complete: $ModelPath ($($tmpInfo.Length) bytes)"

# ---------------------------------------------------------------------------
# Store SHA256
# ---------------------------------------------------------------------------
Log ""
Info "  Computing SHA256 checksum ..."
$hash = (Get-FileHash -Path $ModelPath -Algorithm SHA256).Hash.ToLower()
"$hash  $ModelFile" | Set-Content -Path "$ModelPath.sha256" -Encoding UTF8
Ok "SHA256 checksum stored: $ModelPath.sha256"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Log ""
Log "======================================================="
Ok "  Model download and verification complete!"
Log ""
Log "  Model     : $ModelFile"
Log "  Repo      : $ModelRepo"
Log "  Location  : $ModelPath"
Log ""
Log "  Start the stack with: .\scripts\start.ps1"
Log "======================================================="
