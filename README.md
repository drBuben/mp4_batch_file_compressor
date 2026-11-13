# MP4 Batch Compressor

A PowerShell script for batch-compressing MP4 video files using CPU-based or NVIDIA GPU-based HEVC encoding.

## Overview

MP4 Batch Compressor automates video compression across multiple directories. It supports recursive file discovery, CPU and GPU encoding, automatic resume, detailed reporting, safe replacement of original files, and network keep-alive for NAS storage.

| Feature | Description |
|---|---|
| CPU Encoding | FFmpeg `libx265` |
| GPU Encoding | NVIDIA NVENC HEVC |
| Input | Multiple directories or a paths file |
| Discovery | Recursive MP4 file search |
| Resume | Automatic resume using JSON markers |
| Reports | Per-folder reports and global summary |
| Audio | Copy audio streams without re-encoding |
| NAS Keep-Alive | Periodic ping to keep network storage connections active |

## Usage

```powershell
.\mp4_batch_compressor.ps1 [options]
```

## Operating Modes

| Mode | Description |
|---|---|
| `Suffix` | Keep original files and create compressed copies with the `_compressed.mp4` suffix. |
| `Replace` | Replace original files after successful encoding, subject to output-size protection. |

## Input Parameters

| Parameter | Description |
|---|---|
| `-RootPath` | One or more directories to process (comma-separated). Supports local paths and UNC network paths. |
| `-PathsFile` | Path to a text file containing one directory per line. Supports local paths and UNC network paths. |

## Encoding Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Encoder` | `CPU` | Encoding backend: `CPU` or `GPU`. |
| `-Crf` | `20` | Quality setting (CRF for CPU encoding, CQ for GPU encoding). |
| `-Preset` | `slow` | CPU encoding preset. |
| `-NvencPreset` | `p7` | NVIDIA NVENC preset (`p1` = fastest, `p7` = slowest). |

## NAS / Network Keep-Alive Parameters

| Parameter | Default | Description |
|---|---|---|
| `-KeepAliveHost` | Automatic | Optional hostname or IP address to ping. If omitted, the hostname is extracted automatically from the UNC path. |
| `-KeepAliveIntervalSeconds` | `30` | Interval between ping requests, in seconds. Valid range: 5–3600. |

### How NAS Keep-Alive Works

When processing files located on a network share, the script can periodically send ICMP ping requests to the NAS while FFmpeg is encoding a file.

If `-KeepAliveHost` is not specified, the script automatically extracts the server name from the UNC path.

For example, given this input path:

```text
\\NAS326\Videos
```

The script extracts:

```text
NAS326
```

Windows resolves the hostname using its normal name-resolution mechanisms, just as it does when executing:

```powershell
ping NAS326
```

This means there is no need to manually configure the NAS IP address.

Keep-alive behavior:

- A background PowerShell job sends periodic ICMP ping requests while FFmpeg is running.
- The default ping interval is 30 seconds.
- The first ping is sent shortly after the background job starts.
- The background job is stopped when FFmpeg finishes processing the current file.
- If multiple UNC paths point to different NAS devices, the hostname is detected separately for each file.
- An explicitly specified `-KeepAliveHost` overrides automatic hostname detection.
- Local disk paths do not require network keep-alive.
- Failed ping responses do not interrupt video encoding.

**Note:** ICMP ping helps maintain network activity but does not guarantee that an SMB session will remain open if the NAS or network equipment independently terminates idle connections.

## Other Parameters

| Parameter | Description |
|---|---|
| `-Help` | Display help information. |

## Examples

### 1. CPU Encoding — Keep Originals

Compress videos using the CPU and preserve all original files.

```powershell
.\mp4_batch_compressor.ps1 -Mode Suffix -Encoder CPU
```

### 2. NVIDIA GPU Encoding

Use NVIDIA NVENC for hardware-accelerated HEVC encoding.

```powershell
.\mp4_batch_compressor.ps1 -Mode Suffix -Encoder GPU
```

### 3. Process Multiple Directories

Specify multiple input directories separated by commas.

```powershell
.\mp4_batch_compressor.ps1 -Mode Suffix -RootPath "E:\Videos,F:\Movies"
```

### 4. Load Directories from a File

Read input directories from a text file, with one directory per line.

```powershell
.\mp4_batch_compressor.ps1 -Mode Suffix -PathsFile ".\folders.txt"
```

### 5. GPU Encoding — Replace Originals

Use NVIDIA NVENC and replace original files after successful encoding.

```powershell
.\mp4_batch_compressor.ps1 -Mode Replace -Encoder GPU -PathsFile ".\folders.txt"
```

### 6. CPU Encoding — Higher Compression

Use a higher CRF value and a slower preset to achieve greater compression.

```powershell
.\mp4_batch_compressor.ps1 -Mode Replace -Encoder CPU -Crf 22 -Preset slower
```

### 7. NAS Processing — Automatic Keep-Alive

Process videos directly from a NAS network share. The NAS hostname is automatically extracted from the UNC path.

```powershell
.\mp4_batch_compressor.ps1 `
    -Mode Suffix `
    -Encoder GPU `
    -RootPath "\\NAS326\Videos"
```

The script automatically detects `NAS326` and sends periodic ping requests while FFmpeg is encoding.

### 8. NAS Processing — Custom Keep-Alive Interval

Use a 15-second ping interval.

```powershell
.\mp4_batch_compressor.ps1 `
    -Mode Suffix `
    -Encoder GPU `
    -RootPath "\\NAS326\Videos" `
    -KeepAliveIntervalSeconds 15
```

### 9. NAS Processing — Explicit Keep-Alive Host

Manually specify the hostname or IP address if automatic detection is not suitable.

```powershell
.\mp4_batch_compressor.ps1 `
    -Mode Suffix `
    -Encoder GPU `
    -RootPath "\\NAS326\Videos" `
    -KeepAliveHost "192.168.10.125"
```

### 10. NAS Processing — Paths from a File

Keep-alive works with UNC paths loaded from a paths file as well.

Example `folders.txt`:

```text
\\NAS326\Videos
\\NAS326\Movies
E:\LocalVideos
```

Run:

```powershell
.\mp4_batch_compressor.ps1 `
    -Mode Suffix `
    -Encoder GPU `
    -PathsFile ".\folders.txt" `
    -KeepAliveIntervalSeconds 30
```

## Features

- **Recursive Discovery** — Automatically discovers MP4 files in all subdirectories.
- **CPU / GPU Encoding** — Supports software encoding using FFmpeg `libx265` and hardware-accelerated encoding using NVIDIA NVENC.
- **Automatic Resume** — Uses JSON markers to track processing progress and resume interrupted jobs.
- **Per-Folder Reports** — Generates individual text reports for each processed directory.
- **Global Summary** — Creates a consolidated report covering all processed directories.
- **Error Logging** — Records encoding and processing errors for troubleshooting.
- **Original File Protection** — In `Replace` mode, original files are preserved if the compressed output is larger than the source.
- **Existing Output Detection** — In `Suffix` mode, files with existing compressed outputs are skipped.
- **Source Properties Preservation** — Preserves the original video resolution and frame rate.
- **Audio Stream Copy** — Copies audio streams without re-encoding, avoiding unnecessary quality loss and processing time.
- **NAS Keep-Alive** — Periodically pings network storage during encoding to help prevent idle network connections from timing out.
- **Automatic NAS Host Detection** — Extracts the NAS hostname from UNC paths without requiring manual IP configuration.
- **Multiple NAS Support** — Detects the appropriate hostname separately for files from different network shares.

## Requirements

- Windows operating system.
- PowerShell.
- FFmpeg with `libx265` support for CPU encoding.
- FFmpeg with NVIDIA NVENC HEVC support and compatible NVIDIA drivers for GPU encoding.
- Network connectivity to the NAS when processing files from network shares.
- ICMP ping requests must be permitted by the NAS and network configuration for NAS keep-alive to work.

### Installing FFmpeg with WinGet

FFmpeg can be installed using Windows Package Manager (WinGet).

Run the following command in PowerShell:

```powershell
winget install --id Gyan.FFmpeg.Shared -e
```

After installation, restart PowerShell or open a new terminal window to refresh the environment.

Verify the installation:

```powershell
ffmpeg -version
```

Check whether the required video encoders are available:

```powershell
ffmpeg -encoders | Select-String "libx265|hevc_nvenc"
```

Expected encoders:

- `libx265` — CPU-based HEVC encoding.
- `hevc_nvenc` — NVIDIA GPU-based HEVC encoding.

**Note:** The availability of `hevc_nvenc` depends on the installed FFmpeg build and compatible NVIDIA drivers. Installing FFmpeg does not guarantee that NVENC is supported by your GPU or driver configuration.

## Notes

- CPU encoding uses the `libx265` encoder.
- GPU encoding uses NVIDIA NVENC HEVC.
- The `-Crf` parameter controls CPU quality through CRF and GPU quality through CQ.
- The `Replace` mode should be used with care. Always ensure that important source files are backed up.
- Audio streams are copied directly from the source files without re-encoding.
- NAS keep-alive is enabled automatically for UNC paths unless an explicit `-KeepAliveHost` is provided.
- The default keep-alive interval is 30 seconds.
- Keep-alive ping failures are non-fatal and do not stop FFmpeg processing.
- ICMP ping does not guarantee that SMB sessions will remain active if the NAS or network equipment closes them independently.

## Project Structure

The script generates processing reports and JSON progress markers to support monitoring and recovery of batch operations.

- **Folder Reports** — Individual reports for processed directories.
- **Global Report** — Consolidated processing summary.
- **JSON Markers** — Processing state information used for automatic resume.
- **Error Logs** — Details of failed encoding or file-processing operations.
