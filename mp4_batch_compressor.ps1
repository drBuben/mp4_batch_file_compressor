
param(
    [ValidateSet("Replace", "Suffix")]
    [string]$Mode = "Suffix",

    [string[]]$RootPath = @((Get-Location).Path),

    [string]$PathsFile,

    [ValidateSet("CPU", "GPU")]
    [string]$Encoder = "CPU",

    [ValidateRange(0, 51)]
    [int]$Crf = 20,

    [ValidateSet(
        "ultrafast", "superfast", "veryfast", "faster",
        "fast", "medium", "slow", "slower", "veryslow"
    )]
    [string]$Preset = "slow",

    [ValidateSet("p1", "p2", "p3", "p4", "p5", "p6", "p7")]
    [string]$NvencPreset = "p7",

    # Optional NAS/network keep-alive. Example: -KeepAliveHost "192.168.1.50"
    [string]$KeepAliveHost,

    [ValidateRange(5, 3600)]
    [int]$KeepAliveIntervalSeconds = 30,

    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ============================================================
# MP4 BATCH COMPRESSOR
# CPU: libx265
# GPU: NVIDIA NVENC
# Supports recursive folders, resume, reports and safe replace
# ============================================================

function Show-Help {
    Write-Host @"

============================================================
                   MP4 BATCH COMPRESSOR
============================================================

USAGE:
  .\mp4_batch_compressor.ps1 [options]

MODES:
  -Mode Suffix       Keep originals, add _compressed.mp4
  -Mode Replace      Replace originals after successful encoding

INPUT:
  -RootPath          One or more directories (comma-separated)
  -PathsFile         Text file with one directory per line

ENCODING:
  -Encoder CPU       Software HEVC (libx265), default
  -Encoder GPU       NVIDIA HEVC NVENC
  -Crf 20            Quality (CRF for CPU, CQ for GPU)
  -Preset slow       CPU preset
  -NvencPreset p7    GPU preset (p1 fastest, p7 slowest)

NETWORK / NAS:
  -KeepAliveHost     Optional override. If omitted, host is extracted from UNC path.
  -KeepAliveIntervalSeconds  Ping interval in seconds (default: 30)

OTHER:
  -Help              Display this help

EXAMPLES:

  CPU, keep originals:
  .\mp4_batch_compressor.ps1 -Mode Suffix -Encoder CPU

  NVIDIA GPU:
  .\mp4_batch_compressor.ps1 -Mode Suffix -Encoder GPU

  Multiple folders:
  .\mp4_batch_compressor.ps1 -Mode Suffix -RootPath "E:\Videos,F:\Movies"

  Folders from file:
  .\mp4_batch_compressor.ps1 -Mode Suffix -PathsFile ".\folders.txt"

  GPU, replace originals:
  .\mp4_batch_compressor.ps1 -Mode Replace -Encoder GPU -PathsFile ".\folders.txt"

  NAS keep-alive (host is automatically extracted from UNC path):
  .\mp4_batch_compressor.ps1 -Mode Suffix -Encoder GPU -RootPath "\\NAS326\Videos"

  Explicit ping target override:
  .\mp4_batch_compressor.ps1 -Mode Suffix -RootPath "\\NAS326\Videos" -KeepAliveHost "192.168.1.50"

  Custom ping interval (60 seconds):
  .\mp4_batch_compressor.ps1 -Mode Suffix -RootPath "\\NAS326\Videos" -KeepAliveHost "192.168.1.50" -KeepAliveIntervalSeconds 60

  CPU, higher compression:
  .\mp4_batch_compressor.ps1 -Mode Replace -Encoder CPU -Crf 22 -Preset slower

FEATURES:
  - Recursive MP4 discovery
  - CPU / GPU encoding
  - Automatic resume using JSON markers
  - Per-folder text reports
  - Global summary report
  - Error logging
  - Original protection if output is larger (Replace mode)
  - Skip existing output files (Suffix mode)
  - Preserve source resolution and frame rate
  - Copy audio without re-encoding

============================================================

"@ -ForegroundColor Cyan
}

if ($Help -or $PSBoundParameters.Count -eq 0) {
    Show-Help
    exit 0
}

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Format-Size {
    param([long]$Bytes)

    if ($Bytes -lt 0) {
        return "-$(Format-Size (-$Bytes))"
    }

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }

    return "{0:N2} KB" -f ($Bytes / 1KB)
}

function Get-Percent {
    param(
        [long]$Original,
        [long]$Final
    )

    if ($Original -le 0) {
        return 0
    }

    return [math]::Round(
        (1 - ($Final / $Original)) * 100, 2
    )
}

function Get-KeepAliveHostFromPath {
    param([string]$Path)

    # UNC path format: \\server\share\folder
    if ($Path -match '^\\\\([^\\]+)\\') {
        return $Matches[1]
    }

    return $null
}

function Invoke-FFmpegWithKeepAlive {
    param(
        [string]$FFmpegPath,
        [string[]]$Arguments,
        [string]$TargetHost,
        [int]$IntervalSeconds
    )

    $KeepAliveJob = $null

    if (-not [string]::IsNullOrWhiteSpace($TargetHost)) {
        Write-Host "    NAS keep-alive: pinging $TargetHost every $IntervalSeconds seconds" -ForegroundColor DarkCyan

        # Run the ping loop in a background PowerShell job while FFmpeg runs.
        # ICMP failures are non-fatal and do not interrupt encoding.
        $KeepAliveJob = Start-Job -ArgumentList $TargetHost, $IntervalSeconds -ScriptBlock {
            param($HostToPing, $DelaySeconds)

            $Pinger = New-Object System.Net.NetworkInformation.Ping
            try {
                while ($true) {
                    try {
                        $null = $Pinger.Send($HostToPing, 1500)
                    }
                    catch {
                        # A missed ICMP reply must not stop video encoding.
                    }
                    Start-Sleep -Seconds $DelaySeconds
                }
            }
            finally {
                $Pinger.Dispose()
            }
        }

        Start-Sleep -Milliseconds 300
    }

    try {
        & $FFmpegPath @Arguments
        $ExitCode = $LASTEXITCODE
        return [int]$ExitCode
    }
    finally {
        if ($KeepAliveJob) {
            Stop-Job -Job $KeepAliveJob -ErrorAction SilentlyContinue
            Remove-Job -Job $KeepAliveJob -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-Marker {
    param(
        [hashtable]$Data,
        [string]$Path
    )

    # Defensive: .NET file APIs require a native path, not a PowerShell
    # provider-qualified path such as Microsoft.PowerShell.Core\\FileSystem::...
    $Path = $Path -replace '^[^:]+::', ''

    $TempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"

    try {
        $Json = ConvertTo-Json -InputObject $Data -Depth 10
        [System.IO.File]::WriteAllText(
            $TempPath,
            $Json,
            [System.Text.UTF8Encoding]::new($false)
        )

        # Replace marker without leaving a partial JSON file
        if (Test-Path -LiteralPath $Path) {
            # File.Replace works on Windows PowerShell 5.1 and PowerShell 7.
            $BackupMarker = "$Path.old-$([guid]::NewGuid().ToString('N'))"
            try {
                [System.IO.File]::Replace($TempPath, $Path, $BackupMarker)
            }
            finally {
                if (Test-Path -LiteralPath $BackupMarker) {
                    Remove-Item -LiteralPath $BackupMarker -Force
                }
            }
        }
        else {
            [System.IO.File]::Move($TempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $TempPath) {
            Remove-Item -LiteralPath $TempPath -Force
        }
    }
}

function Load-Marker {
    param([string]$Path)

    $Result = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Result
    }

    try {
        $Content = Get-Content -LiteralPath $Path -Raw

        if ([string]::IsNullOrWhiteSpace($Content)) {
            return $Result
        }

        $Data = ConvertFrom-Json -InputObject $Content

        foreach ($Property in $Data.PSObject.Properties) {
            $Result[$Property.Name] = $Property.Value
        }
    }
    catch {
        throw "Cannot read marker $Path : $($_.Exception.Message)"
    }

    return $Result
}

function Get-RelativePath {
    param(
        [string]$Base,
        [string]$FullPath
    )

    return [System.IO.Path]::GetRelativePath($Base, $FullPath)
}

function Write-Report {
    param(
        [string]$Path,
        [string]$Title,
        [string]$Directory,
        [object[]]$Items,
        [string]$Mode,
        [string]$Encoder,
        [int]$Crf,
        [string]$Preset
    )

    [long]$Original = 0
    [long]$Final = 0

    foreach ($Item in $Items) {
        $Original += [long]$Item.OriginalBytes
        $Final += [long]$Item.FinalBytes
    }

    $Success = @($Items | Where-Object Status -eq "SUCCESS").Count
    $Skipped = @($Items | Where-Object Status -like "SKIPPED*").Count
    $Failed = @($Items | Where-Object Status -eq "FAILED").Count
    $Larger = @($Items | Where-Object Status -eq "NOT_SMALLER").Count

    $Lines = [System.Collections.Generic.List[string]]::new()

    $Lines.Add("============================================================")
    $Lines.Add($Title)
    $Lines.Add("============================================================")
    $Lines.Add("")
    $Lines.Add("Date:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $Lines.Add("Directory:  $Directory")
    $Lines.Add("Mode:       $Mode")
    $Lines.Add("Encoder:    $Encoder")
    $Lines.Add("Quality:    $Crf")
    $Lines.Add("Preset:     $Preset")
    $Lines.Add("")
    $Lines.Add("-------------------- SUMMARY -------------------------------")
    $Lines.Add("Total files:       $($Items.Count)")
    $Lines.Add("Processed:         $Success")
    $Lines.Add("Skipped:           $Skipped")
    $Lines.Add("Not smaller:       $Larger")
    $Lines.Add("Failed:            $Failed")
    $Lines.Add("")
    $Lines.Add("Original size:     $(Format-Size $Original)")
    $Lines.Add("Final size:        $(Format-Size $Final)")
    $Lines.Add("Space saved:       $(Format-Size ($Original - $Final))")
    $Lines.Add("Compression:       $(Get-Percent $Original $Final)%")
    $Lines.Add("")
    $Lines.Add("-------------------- FILE DETAILS --------------------------")

    foreach ($Item in $Items) {
        $Lines.Add("")
        $Lines.Add("File:       $($Item.File)")
        $Lines.Add("Status:     $($Item.Status)")
        $Lines.Add("Original:   $(Format-Size $Item.OriginalBytes)")
        $Lines.Add("Final:      $(Format-Size $Item.FinalBytes)")
        $Lines.Add("Saved:      $(Format-Size ([long]($Item.OriginalBytes - $Item.FinalBytes)))")
        $Lines.Add("Reduction:  $(Get-Percent $Item.OriginalBytes $Item.FinalBytes)%")

        if ($Item.ErrorMessage) {
            $Lines.Add("Error:      $($Item.ErrorMessage)")
        }
    }

    $Lines.Add("")
    $Lines.Add("============================================================")

    $Lines | Out-File -LiteralPath $Path -Encoding utf8

    return [PSCustomObject]@{
        OriginalBytes = $Original
        FinalBytes = $Final
        Success = $Success
        Skipped = $Skipped
        Failed = $Failed
        NotSmaller = $Larger
    }
}

# ============================================================
# CHECK FFMPEG AND FFPROBE
# ============================================================

$FFmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
$FFprobe = Get-Command ffprobe -ErrorAction SilentlyContinue

if (-not $FFmpeg -or -not $FFprobe) {
    Write-Host "ERROR: FFmpeg and FFprobe must be installed and in PATH." -ForegroundColor Red
    exit 1
}

if ($Encoder -eq "GPU") {
    Write-Host "Checking NVIDIA NVENC..." -ForegroundColor Cyan

    $Encoders = & $FFmpeg.Source -hide_banner -encoders 2>&1 | Out-String

    if ($Encoders -notmatch '\bhevc_nvenc\b') {
        Write-Host "ERROR: hevc_nvenc not available." -ForegroundColor Red
        exit 1
    }

    Write-Host "NVENC available." -ForegroundColor Green
}

# ============================================================
# ENCODER CONFIGURATION
# ============================================================

if ($Encoder -eq "CPU") {
    $VideoArgs = @(
        "-c:v", "libx265",
        "-preset", $Preset,
        "-crf", "$Crf"
    )

    $ActivePreset = $Preset
}
else {
    $VideoArgs = @(
        "-c:v", "hevc_nvenc",
        "-preset", $NvencPreset,
        "-tune", "hq",
        "-rc", "vbr",
        "-cq", "$Crf",
        "-b:v", "0"
    )

    $ActivePreset = $NvencPreset
}

$SettingsKey = "$Mode|$Encoder|$Crf|$ActivePreset|hevc|yuv420p|v1"

# ============================================================
# INPUT FOLDERS
# ============================================================

$Folders = [System.Collections.Generic.List[string]]::new()

if ($PathsFile) {
    if (-not (Test-Path -LiteralPath $PathsFile -PathType Leaf)) {
        throw "Paths file not found: $PathsFile"
    }

    $PathsFileFull = (Resolve-Path -LiteralPath $PathsFile).ProviderPath
    $PathsFileDir = Split-Path $PathsFileFull -Parent

    foreach ($Line in (Get-Content -LiteralPath $PathsFileFull)) {
        $P = $Line.Trim().Trim('"')

        if (-not $P -or $P.StartsWith("#")) {
            continue
        }

        if (-not [System.IO.Path]::IsPathRooted($P)) {
            $P = Join-Path $PathsFileDir $P
        }

        $Folders.Add($P)
    }
}
else {
    foreach ($Entry in $RootPath) {
        foreach ($P in ($Entry -split ',')) {
            $P = $P.Trim().Trim('"')

            if ($P) {
                $Folders.Add($P)
            }
        }
    }
}

$ValidFolders = [System.Collections.Generic.List[string]]::new()

foreach ($Folder in $Folders) {
    if (Test-Path -LiteralPath $Folder -PathType Container) {
        # Use ProviderPath, not Path. Path can contain a PowerShell provider
        # prefix (FileSystem::) which .NET file APIs cannot use as a native path.
        $ResolvedInfo = Resolve-Path -LiteralPath $Folder
        $Resolved = $ResolvedInfo.ProviderPath.TrimEnd('\')

        if (-not $ValidFolders.Contains($Resolved)) {
            $ValidFolders.Add($Resolved)
        }
    }
    else {
        Write-Host "WARNING: Folder not found: $Folder" -ForegroundColor Yellow
    }
}

if ($ValidFolders.Count -eq 0) {
    throw "No valid folders found."
}

# Prevent duplicate processing for overlapping root directories
$VisitedFiles = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$AllItems = [System.Collections.Generic.List[object]]::new()
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# ============================================================
# PROCESS FOLDERS
# ============================================================

foreach ($Root in $ValidFolders) {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "PROCESSING: $Root" -ForegroundColor Cyan
    Write-Host "Encoder: $Encoder | Preset: $ActivePreset | Quality: $Crf"
    Write-Host "Mode: $Mode"
    if (-not [string]::IsNullOrWhiteSpace($KeepAliveHost)) {
        Write-Host "NAS keep-alive override: $KeepAliveHost (every $KeepAliveIntervalSeconds sec)"
    }
    else {
        Write-Host "NAS keep-alive: automatic for UNC paths (every $KeepAliveIntervalSeconds sec)"
    }
    Write-Host "============================================================" -ForegroundColor Cyan

    $MarkerFile = Join-Path $Root ".mp4_compressor_processed.json"
    $LogFile = Join-Path $Root "ffmpeg-errors.log"

    $SafeName = (Split-Path $Root -Leaf) -replace '[^a-zA-Z0-9_-]', '_'
    $ReportFile = Join-Path $Root "compress_report_${SafeName}_${Timestamp}.txt"

    $Processed = Load-Marker $MarkerFile

    $Files = @(
        Get-ChildItem -LiteralPath $Root -Filter "*.mp4" -File -Recurse |
        Where-Object {
            $_.BaseName -notmatch '_compressed$' -and
            $_.Name -notmatch '^\.tmp-'
        } |
        Sort-Object FullName
    )

    $FolderItems = [System.Collections.Generic.List[object]]::new()
    $Current = 0

    Write-Host "Found $($Files.Count) MP4 files."
    Write-Host "Marker entries: $($Processed.Count)"
    Write-Host ""

    foreach ($File in $Files) {

        if (-not $VisitedFiles.Add($File.FullName)) {
            continue
        }

        $Current++
        $InputFile = $File.FullName
        $RelativePath = Get-RelativePath $Root $InputFile

        [long]$CurrentSize = $File.Length
        [long]$CurrentTicks = $File.LastWriteTimeUtc.Ticks

        if ($Mode -eq "Suffix") {
            $OutputFile = Join-Path $File.DirectoryName (
                $File.BaseName + "_compressed.mp4"
            )
        }
        else {
            $OutputFile = $InputFile
        }

        Write-Host "[$Current/$($Files.Count)] $RelativePath" -ForegroundColor Cyan

        $Status = ""
        $ErrorMessage = ""
        $OriginalSize = $CurrentSize
        $FinalSize = $CurrentSize

        # ----------------------------------------------------
        # CHECK PREVIOUSLY PROCESSED FILE
        # ----------------------------------------------------

        $AlreadyProcessed = $false

        if ($Processed.ContainsKey($RelativePath)) {
            $Entry = $Processed[$RelativePath]

            if (Test-Path -LiteralPath $OutputFile -PathType Leaf) {
                $ActualOutput = Get-Item -LiteralPath $OutputFile

                if (
                    $Entry.SettingsKey -eq $SettingsKey -and
                    [long]$Entry.SourceLength -eq $CurrentSize -and
                    [long]$Entry.SourceTicks -eq $CurrentTicks -and
                    [long]$Entry.OutputLength -eq $ActualOutput.Length -and
                    $Entry.OutputPath -eq $OutputFile
                ) {
                    $AlreadyProcessed = $true
                }
            }
        }

        if ($AlreadyProcessed) {
            $Status = "SKIPPED_MARKER"
            $OriginalSize = [long]$Entry.OriginalLength
            $FinalSize = [long]$Entry.OutputLength

            Write-Host "    SKIPPED: Already processed" -ForegroundColor Yellow
        }
        elseif ($Mode -eq "Suffix" -and (Test-Path -LiteralPath $OutputFile)) {
            # Never overwrite an existing compressed file
            $Status = "SKIPPED_EXISTING"
            $FinalSize = (Get-Item -LiteralPath $OutputFile).Length

            Write-Host "    SKIPPED: Output exists" -ForegroundColor Yellow
        }
        else {

            $TempFile = Join-Path $File.DirectoryName (
                ".tmp-$([guid]::NewGuid().ToString('N')).mp4"
            )

            try {
                # ------------------------------------------------
                # ENCODE
                # ------------------------------------------------

                $FFArgs = @(
                    "-hide_banner",
                    "-nostdin",
                    "-y",
                    "-i", $InputFile,
                    "-map", "0:v:0",
                    "-map", "0:a?",
                    "-map_metadata", "0",
                    "-map_chapters", "0"
                )

                $FFArgs += $VideoArgs

                $FFArgs += @(
                    "-tag:v", "hvc1",
                    "-pix_fmt", "yuv420p",
                    "-c:a", "copy",
                    "-movflags", "+faststart",
                    $TempFile
                )

                # Prefer an explicitly supplied host. Otherwise, for UNC paths,
                # extract the server name (for example, \\NAS326\Share -> NAS326).
                # Windows resolves this hostname using its normal name-resolution
                # mechanisms, just like: ping NAS326
                $FileKeepAliveHost = $KeepAliveHost

                if ([string]::IsNullOrWhiteSpace($FileKeepAliveHost)) {
                    $FileKeepAliveHost = Get-KeepAliveHostFromPath -Path $InputFile
                }

                $FFmpegExitCode = Invoke-FFmpegWithKeepAlive `
                    -FFmpegPath $FFmpeg.Source `
                    -Arguments $FFArgs `
                    -TargetHost $FileKeepAliveHost `
                    -IntervalSeconds $KeepAliveIntervalSeconds

                if ($FFmpegExitCode -ne 0) {
                    throw "FFmpeg exit code: $FFmpegExitCode"
                }

                if (-not (Test-Path -LiteralPath $TempFile)) {
                    throw "Output file not created."
                }

                $NewFile = Get-Item -LiteralPath $TempFile
                [long]$NewSize = $NewFile.Length

                if ($NewSize -le 0) {
                    throw "Output file is empty."
                }

                # ------------------------------------------------
                # VALIDATE VIDEO WITH FFPROBE
                # ------------------------------------------------

                # Read stream information as JSON. This is more robust than
                # comparing raw console output, especially with GoPro MP4 files.
                $ProbeOutput = & $FFprobe.Source `
                    -v error `
                    -show_entries stream=codec_type,codec_name,codec_tag_string `
                    -of json `
                    $TempFile 2>&1

                $ProbeExitCode = $LASTEXITCODE

                if ($ProbeExitCode -ne 0) {
                    $ProbeDetails = ($ProbeOutput | ForEach-Object { "$_" }) -join " "
                    throw "FFprobe failed (exit code $ProbeExitCode): $ProbeDetails"
                }

                try {
                    $ProbeJson = ($ProbeOutput | Out-String) | ConvertFrom-Json
                }
                catch {
                    $ProbeDetails = ($ProbeOutput | ForEach-Object { "$_" }) -join " "
                    throw "FFprobe returned invalid JSON: $ProbeDetails"
                }

                $VideoStream = @(
                    $ProbeJson.streams |
                    Where-Object { $_.codec_type -eq "video" }
                ) | Select-Object -First 1

                if (-not $VideoStream) {
                    throw "FFprobe validation failed: no video stream found."
                }

                # FFprobe normally reports HEVC as codec_name=hevc.
                # HVC1 is the MP4 codec tag, not the codec_name.
                if ($VideoStream.codec_name -notin @("hevc", "h265")) {
                    throw "FFprobe validation failed: expected HEVC, found codec_name='$($VideoStream.codec_name)', codec_tag_string='$($VideoStream.codec_tag_string)'."
                }

                # ------------------------------------------------
                # DO NOT REPLACE WITH A LARGER FILE
                # ------------------------------------------------

                if ($Mode -eq "Replace" -and $NewSize -ge $CurrentSize) {
                    $Status = "NOT_SMALLER"
                    $FinalSize = $CurrentSize

                    Write-Host "    SKIPPED: New file is not smaller." -ForegroundColor Yellow
                }
                else {

                    # --------------------------------------------
                    # SAVE RESULT
                    # --------------------------------------------

                    if ($Mode -eq "Replace") {
                        $BackupFile = "$InputFile.backup-$([guid]::NewGuid().ToString('N'))"

                        [System.IO.File]::Replace(
                            $TempFile,
                            $InputFile,
                            $BackupFile
                        )

                        # Keep backup until marker has been saved
                    }
                    else {
                        Move-Item -LiteralPath $TempFile -Destination $OutputFile
                    }

                    $FinalInfo = Get-Item -LiteralPath $OutputFile
                    $FinalSize = $FinalInfo.Length

                    # --------------------------------------------
                    # SAVE PROGRESS MARKER
                    # --------------------------------------------

                    $NewEntry = [PSCustomObject]@{
                        SettingsKey = $SettingsKey
                        Mode = $Mode
                        Encoder = $Encoder
                        Quality = $Crf
                        Preset = $ActivePreset
                        OriginalLength = $CurrentSize
                        SourceLength = if ($Mode -eq "Replace") {
                            $FinalInfo.Length
                        } else {
                            $CurrentSize
                        }
                        SourceTicks = if ($Mode -eq "Replace") {
                            $FinalInfo.LastWriteTimeUtc.Ticks
                        } else {
                            $CurrentTicks
                        }
                        OutputLength = $FinalSize
                        OutputPath = $OutputFile
                        ProcessedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    }

                    $Processed[$RelativePath] = $NewEntry
                    Save-Marker -Data $Processed -Path $MarkerFile

                    if ($Mode -eq "Replace" -and
                        (Test-Path -LiteralPath $BackupFile)) {
                        Remove-Item -LiteralPath $BackupFile -Force
                    }

                    $Status = "SUCCESS"

                    $SavedPercent = Get-Percent $CurrentSize $FinalSize

                    Write-Host "    SUCCESS: $(Format-Size $CurrentSize) -> $(Format-Size $FinalSize)" -ForegroundColor Green
                    Write-Host "    Saved: $SavedPercent%" -ForegroundColor Green
                }
            }
            catch {
                $Status = "FAILED"
                $ErrorMessage = $_.Exception.Message

                Write-Host "    ERROR: $ErrorMessage" -ForegroundColor Red

                Add-Content -LiteralPath $LogFile -Value (
                    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $InputFile | $ErrorMessage"
                )

                # If replacement happened before marker save,
                # restore original from backup when available.
                if ($Mode -eq "Replace" -and
                    $BackupFile -and
                    (Test-Path -LiteralPath $BackupFile)) {

                    try {
                        [System.IO.File]::Copy(
                            $BackupFile, $InputFile, $true
                        )
                        Remove-Item -LiteralPath $BackupFile -Force
                    }
                    catch {
                        Write-Warning "Could not restore backup: $BackupFile"
                    }
                }

                $FinalSize = if (Test-Path -LiteralPath $InputFile) {
                    (Get-Item -LiteralPath $InputFile).Length
                } else {
                    $CurrentSize
                }
            }
            finally {
                if (Test-Path -LiteralPath $TempFile) {
                    Remove-Item -LiteralPath $TempFile -Force
                }
            }
        }

        # ----------------------------------------------------
        # RECORD STATISTICS
        # ----------------------------------------------------

        $Item = [PSCustomObject]@{
            File = $InputFile
            Status = $Status
            OriginalBytes = [long]$OriginalSize
            FinalBytes = [long]$FinalSize
            ErrorMessage = $ErrorMessage
        }

        $FolderItems.Add($Item)
        $AllItems.Add($Item)
    }

    # ========================================================
    # FOLDER REPORT
    # ========================================================

    $Stats = Write-Report `
        -Path $ReportFile `
        -Title "MP4 COMPRESSION REPORT" `
        -Directory $Root `
        -Items $FolderItems.ToArray() `
        -Mode $Mode `
        -Encoder $Encoder `
        -Crf $Crf `
        -Preset $ActivePreset

    Write-Host ""
    Write-Host "---------------- FOLDER SUMMARY ----------------" -ForegroundColor Cyan
    Write-Host "Processed:     $($Stats.Success)" -ForegroundColor Green
    Write-Host "Skipped:       $($Stats.Skipped)" -ForegroundColor Yellow
    Write-Host "Not smaller:   $($Stats.NotSmaller)"
    Write-Host "Failed:        $($Stats.Failed)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Original:      $(Format-Size $Stats.OriginalBytes)"
    Write-Host "Final:         $(Format-Size $Stats.FinalBytes)"
    Write-Host "Saved:         $(Format-Size ($Stats.OriginalBytes - $Stats.FinalBytes))"
    Write-Host "Reduction:     $(Get-Percent $Stats.OriginalBytes $Stats.FinalBytes)%"
    Write-Host ""
    Write-Host "Marker: $MarkerFile"
    Write-Host "Report: $ReportFile" -ForegroundColor Green
}

# ============================================================
# GLOBAL REPORT
# ============================================================

$GlobalReportDir = Split-Path -Parent $ValidFolders[0]

$GlobalReport = Join-Path $GlobalReportDir ".compress_reports\compress_report_GLOBAL_${Timestamp}.txt"

$GlobalStats = Write-Report `
    -Path $GlobalReport `
    -Title "GLOBAL MP4 COMPRESSION REPORT" `
    -Directory ($ValidFolders -join ", ") `
    -Items $AllItems.ToArray() `
    -Mode $Mode `
    -Encoder $Encoder `
    -Crf $Crf `
    -Preset $ActivePreset

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                       GLOBAL SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host "Folders:       $($ValidFolders.Count)"
Write-Host "Files:         $($AllItems.Count)"
Write-Host "Processed:     $($GlobalStats.Success)" -ForegroundColor Green
Write-Host "Skipped:       $($GlobalStats.Skipped)" -ForegroundColor Yellow
Write-Host "Not smaller:   $($GlobalStats.NotSmaller)"
Write-Host "Failed:        $($GlobalStats.Failed)" -ForegroundColor Red

Write-Host ""
Write-Host "Original:      $(Format-Size $GlobalStats.OriginalBytes)"
Write-Host "Final:         $(Format-Size $GlobalStats.FinalBytes)"
Write-Host "Saved:         $(Format-Size ($GlobalStats.OriginalBytes - $GlobalStats.FinalBytes))"
Write-Host "Reduction:     $(Get-Percent $GlobalStats.OriginalBytes $GlobalStats.FinalBytes)%"

Write-Host ""
Write-Host "Global report: $GlobalReport" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan

if ($GlobalStats.Failed -gt 0) {
    exit 1
}

exit 0
