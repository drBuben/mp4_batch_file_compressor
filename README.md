# ============================================================
# MP4 BATCH COMPRESSOR
# CPU: libx265
# GPU: NVIDIA NVENC
# Supports recursive folders, resume, reports and safe replace
# ============================================================

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
