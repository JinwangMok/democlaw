#Requires -Version 5.1
<#
.SYNOPSIS
    SHA256 checksum calculation, storage, and verification for model files.

.DESCRIPTION
    Cross-platform (Windows native) checksum management for DemoClaw model files.
    Computes SHA256 hashes, stores them in .sha256 sidecar files, and verifies
    file integrity on every run.

    Checksum file format (compatible with sha256sum):
        <64-char-hex-hash>  <filename>

.PARAMETER Action
    One of: compute, store, verify, verify-dir, store-dir, verify-model-cache

.PARAMETER Path
    Path to the file or directory to process.

.PARAMETER ModelName
    HuggingFace model name (e.g., "Qwen/Qwen3-4B-AWQ"). Used with verify-model-cache.

.PARAMETER CacheDir
    HuggingFace cache directory. Defaults to $env:USERPROFILE\.cache\huggingface

.PARAMETER Pattern
    File glob pattern for directory operations. Default: *.safetensors,*.bin,*.gguf,*.json

.EXAMPLE
    .\scripts\checksum.ps1 -Action compute -Path .\model.safetensors
    .\scripts\checksum.ps1 -Action store -Path .\model.safetensors
    .\scripts\checksum.ps1 -Action verify -Path .\model.safetensors
    .\scripts\checksum.ps1 -Action verify-dir -Path .\models\
    .\scripts\checksum.ps1 -Action verify-model-cache -ModelName "Qwen/Qwen3-4B-AWQ"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("compute", "store", "verify", "verify-dir", "store-dir", "verify-model-cache", "needs-download", "store-model-cache")]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [string]$ModelName = "Qwen/Qwen3-4B-AWQ",

    [Parameter(Mandatory = $false)]
    [string]$CacheDir = "",

    [Parameter(Mandatory = $false)]
    [string[]]$Pattern = @("*.safetensors", "*.bin", "*.gguf", "*.json")
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
function Write-CkLog {
    param([string]$Message)
    Write-Host "[checksum] $Message"
}

function Write-CkWarn {
    param([string]$Message)
    Write-Warning "[checksum] $Message"
}

function Write-CkError {
    param([string]$Message)
    Write-Error "[checksum] ERROR: $Message"
}

# ---------------------------------------------------------------------------
# Compute-Sha256 — compute SHA256 hash of a file
# Returns the lowercase hex hash string.
# ---------------------------------------------------------------------------
function Compute-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Write-CkError "File not found: $FilePath"
        return $null
    }

    try {
        $hash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLower()
        return $hash
    }
    catch {
        Write-CkError "Failed to compute SHA256 for: $FilePath — $_"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Store-Checksum — compute hash and write .sha256 sidecar file
# ---------------------------------------------------------------------------
function Store-Checksum {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Write-CkError "File not found: $FilePath"
        return $false
    }

    $hash = Compute-Sha256 -FilePath $FilePath
    if (-not $hash) { return $false }

    $basename = [System.IO.Path]::GetFileName($FilePath)
    $checksumFile = "$FilePath.sha256"
    $content = "$hash  $basename"

    Set-Content -LiteralPath $checksumFile -Value $content -Encoding ASCII -NoNewline
    # Add trailing newline
    Add-Content -LiteralPath $checksumFile -Value ""

    Write-CkLog "Stored checksum: $checksumFile"
    Write-CkLog "  SHA256: $hash"
    Write-CkLog "  File  : $basename"

    return $true
}

# ---------------------------------------------------------------------------
# Read-Checksum — read hash from a .sha256 sidecar file
# ---------------------------------------------------------------------------
function Read-Checksum {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChecksumFile
    )

    if (-not (Test-Path -LiteralPath $ChecksumFile -PathType Leaf)) {
        Write-CkError "Checksum file not found: $ChecksumFile"
        return $null
    }

    $line = (Get-Content -LiteralPath $ChecksumFile -TotalCount 1).Trim()
    $storedHash = ($line -split '\s+')[0].ToLower().Trim()

    if (-not $storedHash -or $storedHash.Length -ne 64) {
        Write-CkError "Malformed checksum file: $ChecksumFile"
        return $null
    }

    return $storedHash
}

# ---------------------------------------------------------------------------
# Verify-Checksum — verify file against its .sha256 sidecar
# Returns: "pass", "fail", "missing-checksum", "missing-file"
# ---------------------------------------------------------------------------
function Verify-Checksum {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Write-CkError "File not found: $FilePath"
        return "missing-file"
    }

    $checksumFile = "$FilePath.sha256"

    if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
        Write-CkWarn "No checksum file found: $checksumFile"
        Write-CkWarn "This is expected on first download. Generating checksum now."
        return "missing-checksum"
    }

    $basename = [System.IO.Path]::GetFileName($FilePath)
    Write-CkLog "Verifying: $basename"

    $storedHash = Read-Checksum -ChecksumFile $checksumFile
    if (-not $storedHash) { return "fail" }

    $computedHash = Compute-Sha256 -FilePath $FilePath
    if (-not $computedHash) { return "fail" }

    if ($computedHash -eq $storedHash) {
        $shortHash = $computedHash.Substring(0, 16)
        Write-CkLog "  PASS: SHA256 matches ($shortHash...)"
        return "pass"
    }
    else {
        Write-CkError "  FAIL: SHA256 mismatch for $basename"
        Write-CkError "    Expected : $storedHash"
        Write-CkError "    Computed : $computedHash"
        return "fail"
    }
}

# ---------------------------------------------------------------------------
# Verify-ChecksumOrFail — verify or exit on failure; generate on first run
# ---------------------------------------------------------------------------
function Verify-ChecksumOrFail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $result = Verify-Checksum -FilePath $FilePath

    switch ($result) {
        "pass" {
            return $true
        }
        "missing-checksum" {
            Write-CkLog "Generating initial checksum for: $([System.IO.Path]::GetFileName($FilePath))"
            $stored = Store-Checksum -FilePath $FilePath
            if (-not $stored) {
                Write-CkError "Failed to generate checksum for: $FilePath"
                exit 1
            }
            return $true
        }
        "missing-file" {
            Write-CkError "Model file missing: $FilePath"
            exit 1
        }
        default {
            Write-CkError "Checksum verification FAILED for: $FilePath"
            Write-CkError "The file may be corrupted. Delete it and re-download."
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Process-Directory — store or verify checksums for files in a directory
# ---------------------------------------------------------------------------
function Process-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet("store", "verify")]
        [string]$Mode,

        [Parameter(Mandatory = $false)]
        [string[]]$FilePatterns = @("*.safetensors", "*.bin", "*.gguf", "*.json")
    )

    if (-not (Test-Path -LiteralPath $DirPath -PathType Container)) {
        Write-CkError "Directory not found: $DirPath"
        return $false
    }

    $total = 0
    $passed = 0
    $generated = 0
    $failed = 0

    if ($Mode -eq "verify") {
        Write-CkLog "Verifying checksums in: $DirPath"
    }

    foreach ($pat in $FilePatterns) {
        $files = Get-ChildItem -LiteralPath $DirPath -Filter $pat -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            # Skip .sha256 files
            if ($file.Extension -eq ".sha256") { continue }

            $total++

            if ($Mode -eq "store") {
                $stored = Store-Checksum -FilePath $file.FullName
                if (-not $stored) { $failed++ }
                else { $passed++ }
            }
            else {
                $result = Verify-Checksum -FilePath $file.FullName
                switch ($result) {
                    "pass" { $passed++ }
                    "missing-checksum" {
                        $stored = Store-Checksum -FilePath $file.FullName
                        if ($stored) { $generated++ }
                        else { $failed++ }
                    }
                    default { $failed++ }
                }
            }
        }
    }

    if ($Mode -eq "verify") {
        Write-CkLog "Verification summary: $total files"
        Write-CkLog "  Passed    : $passed"
        Write-CkLog "  Generated : $generated (first run)"
        Write-CkLog "  Failed    : $failed"
    }
    else {
        Write-CkLog "Stored checksums: $total files processed, $failed failures"
    }

    return ($failed -eq 0)
}

# ---------------------------------------------------------------------------
# Resolve-ModelCacheDir — find the HF model snapshot directory
# ---------------------------------------------------------------------------
function Resolve-ModelCacheDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Model
    )

    # Convert model name to HF cache directory format: org/name -> models--org--name
    $cacheName = "models--" + ($Model -replace "/", "--")
    $modelDir = Join-Path $CacheDirectory "hub" $cacheName

    if (-not (Test-Path -LiteralPath $modelDir -PathType Container)) {
        Write-CkWarn "Model cache directory not found: $modelDir"
        return $null
    }

    $snapshotDir = Join-Path $modelDir "snapshots"
    if (-not (Test-Path -LiteralPath $snapshotDir -PathType Container)) {
        Write-CkWarn "No snapshots directory found: $snapshotDir"
        return $null
    }

    # Get the latest snapshot (sorted by name, which is a revision hash)
    $latestSnapshot = Get-ChildItem -LiteralPath $snapshotDir -Directory |
        Sort-Object Name |
        Select-Object -Last 1

    if (-not $latestSnapshot) {
        Write-CkWarn "No model snapshots found in: $snapshotDir"
        return $null
    }

    return $latestSnapshot.FullName
}

# ---------------------------------------------------------------------------
# Test-ModelNeedsDownload — Check if a model needs (re-)download
#
# Compares existing model files against stored .sha256 checksums.
# Returns $true if download is needed, $false if all checksums match.
# ---------------------------------------------------------------------------
function Test-ModelNeedsDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Model
    )

    Write-CkLog "Checking if model '$Model' needs download ..."

    # Step 1: Resolve snapshot directory
    $snapshotDir = Resolve-ModelCacheDir -CacheDirectory $CacheDirectory -Model $Model
    if (-not $snapshotDir) {
        Write-CkLog "  No cached snapshot found - download needed."
        return $true
    }

    Write-CkLog "  Found snapshot: $(Split-Path $snapshotDir -Leaf)"

    # Step 2: Check for .safetensors model files
    $modelFiles = Get-ChildItem -LiteralPath $snapshotDir -Filter "*.safetensors" -File -ErrorAction SilentlyContinue
    if (-not $modelFiles -or $modelFiles.Count -eq 0) {
        Write-CkLog "  No .safetensors files found - download needed."
        return $true
    }

    # Step 3: Verify each model file against its .sha256 sidecar
    foreach ($file in $modelFiles) {
        $checksumFile = "$($file.FullName).sha256"

        # 3a. Missing sidecar -> needs download
        if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
            Write-CkLog "  Missing checksum for: $($file.Name) - download needed."
            return $true
        }

        # 3b. Read stored hash
        $storedHash = Read-Checksum -ChecksumFile $checksumFile
        if (-not $storedHash) {
            Write-CkLog "  Malformed checksum for: $($file.Name) - download needed."
            return $true
        }

        # 3c. Compute current hash
        $computedHash = Compute-Sha256 -FilePath $file.FullName
        if (-not $computedHash) {
            Write-CkLog "  Failed to hash: $($file.Name) - download needed."
            return $true
        }

        # 3d. Compare
        if ($computedHash -ne $storedHash) {
            Write-CkLog "  Checksum MISMATCH for: $($file.Name)"
            Write-CkLog "    Expected : $storedHash"
            Write-CkLog "    Computed : $computedHash"
            Write-CkLog "  Re-download needed."
            return $true
        }

        $shortHash = $computedHash.Substring(0, 12)
        Write-CkLog "  PASS: $($file.Name) ($shortHash...)"
    }

    # Step 4: Also verify key JSON config files
    $jsonConfigs = @("config.json", "tokenizer.json")
    foreach ($jsonName in $jsonConfigs) {
        $jsonPath = Join-Path $snapshotDir $jsonName
        if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
            $jsonCksum = "$jsonPath.sha256"
            if (Test-Path -LiteralPath $jsonCksum -PathType Leaf) {
                $result = Verify-Checksum -FilePath $jsonPath
                if ($result -eq "fail") {
                    Write-CkLog "  JSON config checksum mismatch: $jsonName - download needed."
                    return $true
                }
            }
        }
    }

    Write-CkLog "  All checksums verified - model is intact. Skipping download."
    return $false
}

# ---------------------------------------------------------------------------
# Save-ModelChecksums — Store checksums for all model files after download
# ---------------------------------------------------------------------------
function Save-ModelChecksums {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Model
    )

    Write-CkLog "Storing checksums for model '$Model' ..."

    $snapshotDir = Resolve-ModelCacheDir -CacheDirectory $CacheDirectory -Model $Model
    if (-not $snapshotDir) {
        Write-CkError "Cannot store checksums - no snapshot directory found for '$Model'"
        return $false
    }

    Write-CkLog "  Snapshot: $(Split-Path $snapshotDir -Leaf)"

    return (Process-Directory -DirPath $snapshotDir -Mode "store" -FilePatterns @("*.safetensors", "*.json"))
}

# ===========================================================================
# Main dispatcher
# ===========================================================================

switch ($Action) {
    "compute" {
        if (-not $Path) {
            Write-CkError "Path parameter is required for compute action"
            exit 1
        }
        $hash = Compute-Sha256 -FilePath $Path
        if ($hash) {
            Write-Output $hash
        }
        else {
            exit 1
        }
    }

    "store" {
        if (-not $Path) {
            Write-CkError "Path parameter is required for store action"
            exit 1
        }
        $result = Store-Checksum -FilePath $Path
        if (-not $result) { exit 1 }
    }

    "verify" {
        if (-not $Path) {
            Write-CkError "Path parameter is required for verify action"
            exit 1
        }
        Verify-ChecksumOrFail -FilePath $Path
    }

    "verify-dir" {
        if (-not $Path) {
            Write-CkError "Path parameter is required for verify-dir action"
            exit 1
        }
        $result = Process-Directory -DirPath $Path -Mode "verify" -FilePatterns $Pattern
        if (-not $result) { exit 1 }
    }

    "store-dir" {
        if (-not $Path) {
            Write-CkError "Path parameter is required for store-dir action"
            exit 1
        }
        $result = Process-Directory -DirPath $Path -Mode "store" -FilePatterns $Pattern
        if (-not $result) { exit 1 }
    }

    "verify-model-cache" {
        if (-not $CacheDir) {
            $CacheDir = Join-Path $env:USERPROFILE ".cache" "huggingface"
        }

        Write-CkLog "Model cache: $ModelName"

        $snapshotDir = Resolve-ModelCacheDir -CacheDirectory $CacheDir -Model $ModelName
        if (-not $snapshotDir) {
            Write-CkError "Could not locate model cache for: $ModelName"
            exit 1
        }

        Write-CkLog "Snapshot: $(Split-Path $snapshotDir -Leaf)"

        $result = Process-Directory -DirPath $snapshotDir -Mode "verify" -FilePatterns @("*.safetensors", "*.json")
        if (-not $result) { exit 1 }
    }

    "needs-download" {
        if (-not $CacheDir) {
            $CacheDir = Join-Path $env:USERPROFILE ".cache" "huggingface"
        }

        $needsDownload = Test-ModelNeedsDownload -CacheDirectory $CacheDir -Model $ModelName
        if ($needsDownload) {
            Write-Output "true"
            exit 0
        }
        else {
            Write-Output "false"
            exit 0
        }
    }

    "store-model-cache" {
        if (-not $CacheDir) {
            $CacheDir = Join-Path $env:USERPROFILE ".cache" "huggingface"
        }

        $result = Save-ModelChecksums -CacheDirectory $CacheDir -Model $ModelName
        if (-not $result) { exit 1 }
    }
}
