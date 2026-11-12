# MP4 Batch Compressor

A PowerShell script for batch-compressing MP4 video files using CPU-based or NVIDIA GPU-based HEVC encoding.

## Overview

MP4 Batch Compressor automates video compression across multiple directories. It supports recursive file discovery, CPU and GPU encoding, automatic resume, detailed reporting, and safe replacement of original files.

| Feature | Description |
|---|---|
| CPU Encoding | FFmpeg `libx265` |
| GPU Encoding | NVIDIA NVENC HEVC |
| Input | Multiple directories or a paths file |
| Discovery | Recursive MP4 file search |
| Resume | Automatic resume using JSON markers |
| Reports | Per-folder reports and global summary |
| Audio | Copy audio streams without re-encoding |

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
| `-RootPath` | One or more directories to process (comma-separated). |
| `-PathsFile` | Path to a text file containing one directory per line. |

## Encoding Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Encoder` | `CPU` | Encoding backend: `CPU` or `GPU`. |
| `-Crf` | `20` | Quality setting (CRF for CPU encoding, CQ for GPU encoding). |
| `-Preset` | `slow` | CPU encoding preset. |
| `-NvencPreset` | `p7` | NVIDIA NVENC preset (`p1` = fastest, `p7` = slowest). |

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

## Requirements

- Windows operating system.
- PowerShell.
- FFmpeg with `libx265` support for CPU encoding.
- FFmpeg with NVIDIA NVENC HEVC support and compatible NVIDIA drivers for GPU encoding.

## Notes

- CPU encoding uses the `libx265` encoder.
- GPU encoding uses NVIDIA NVENC HEVC.
- The `-Crf` parameter controls CPU quality through CRF and GPU quality through CQ.
- The `Replace` mode should be used with care. Always ensure that important source files are backed up.
- Audio streams are copied directly from the source files without re-encoding.

## Project Structure

The script generates processing reports and JSON progress markers to support monitoring and recovery of batch operations.

- **Folder Reports** — Individual reports for processed directories.
- **Global Report** — Consolidated processing summary.
- **JSON Markers** — Processing state information used for automatic resume.
- **Error Logs** — Details of failed encoding or file-processing operations.
