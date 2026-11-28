#Requires -Version 5.1
<#
.SYNOPSIS
    Decides whether re-encoding a video file (or folder of videos) to HEVC or AV1 is worth the time and quality cost.

.DESCRIPTION
    For every video file it runs these stages:

      1. TRIAGE (always)   - ffprobe metadata: codec, bitrate, bits-per-pixel, audio share, HDR, interlacing.
      2. SAMPLE ENCODE     - Cuts several short clips spread across the file, encodes them with your
                             intended settings, and extrapolates size savings and total encode time.
                             Enabled by default; disable with -SkipSample.
      3. QUALITY CHECK     - Compares each encoded clip to its source clip with VMAF (needs an ffmpeg
                             build with libvmaf). Disable with -SkipVmaf. Skipped when -SkipSample is used.
      4. VERDICT + NEXT STEPS - WORTH IT / MARGINAL / NOT WORTH IT, followed by ready-to-paste ffmpeg and
                             HandBrakeCLI command lines.
      5. RE-ENCODE (optional) - With -Reencode the script runs the ffmpeg encode itself, asking for
                             confirmation per file. The original file is never modified or deleted.

    Requirements (all free):  winget install Gyan.FFmpeg   (the "full" build includes libx265, libsvtav1, libvmaf)
    Optional: HandBrakeCLI (only used to print equivalent arguments).

    This file must stay ASCII / UTF-8 with BOM if you edit it in an editor that changes encodings, because
    Windows PowerShell 5.1 misreads BOM-less UTF-8 containing non-ASCII characters.

.PARAMETER Path
    One or more video files, folders, or wildcard patterns. Folders are scanned for common video extensions.

.PARAMETER Recurse
    Scan folders recursively.

.PARAMETER SkipSample
    Skip the sample encode (and therefore VMAF). The verdict is then based on metadata triage only.

.PARAMETER SkipVmaf
    Run the sample encode but skip the VMAF quality measurement.

.PARAMETER Codec
    Target codec: 'x265' (HEVC, default) or 'av1'. CPU encodes use libx265/SVT-AV1; GPU encodes use the
    matching hardware encoder available for the selected adapter.

.PARAMETER UseGpu
    Use a supported GPU video encoder for sample and final encodes instead of the CPU encoder. Hardware
    encoders interpret quality and preset values differently, so use the sample/VMAF results to judge output.

.PARAMETER Gpu
    Exact Windows display-adapter name to use with -UseGpu. If omitted, the adapter with the most
    reported dedicated memory is selected. If tied, selection fails rather than guessing.

.PARAMETER Crf
    Constant quality value. Defaults: 20 for x265, 27 for av1. Lower = better quality / bigger file.

.PARAMETER Preset
    Encoder preset. x265: ultrafast..placebo (default 'slow'). av1: 0-13 (default 5).

.PARAMETER SampleCount
    Number of clips to sample, spread evenly across the file. Default 5.

.PARAMETER SampleSeconds
    Length of each clip in seconds. Default 30.

.PARAMETER MinSavingsPercent
    Minimum projected total-file savings (percent) to count as worthwhile. Default 30.

.PARAMETER MinVmaf
    Minimum mean VMAF score considered visually near-transparent. Default 95.

.PARAMETER MinSavedMB
    Minimum absolute projected saving in MB, so small files are not re-encoded for trivial gains. Default 500.

.PARAMETER Reencode
    After analysis, offer to run the real re-encode (WORTH IT and MARGINAL files). Honors -Confirm and -WhatIf.
    Use -Confirm:$false to run without prompting.

.PARAMETER Force
    With -Reencode, also re-encode files whose verdict is NOT WORTH IT.

.PARAMETER OutputDir
    Folder for re-encoded files. Defaults to the source file's folder. Output is <name>.<codec>.mkv.

.PARAMETER TempDir
    Folder for temporary sample clips. Defaults to the system temp folder.

.PARAMETER KeepSamples
    Do not delete the temporary sample clips (useful for eyeballing them in mpv).

.PARAMETER ReportPath
    Optional CSV path to export the per-file results.

.PARAMETER PassThru
    Emit result objects to the pipeline.

.PARAMETER FfmpegPath
    Explicit path to ffmpeg.exe (otherwise PATH, winget, scoop and chocolatey locations are searched).

.PARAMETER FfprobePath
    Explicit path to ffprobe.exe.

.EXAMPLE
    .\Test-ReencodeWorth.ps1 'D:\Movies\Film.mkv'
    Full analysis with defaults (x265, CRF 20, 5 x 30 s samples, VMAF).

.EXAMPLE
    .\Test-ReencodeWorth.ps1 'D:\Movies' -Recurse -SkipSample
    Fast metadata-only triage of a whole library.

.EXAMPLE
    .\Test-ReencodeWorth.ps1 'D:\Movies\Film.mkv' -Codec av1 -Reencode
    Analyze with SVT-AV1, then prompt before encoding.

.EXAMPLE
    .\Test-ReencodeWorth.ps1 'D:\Movies\Film.mkv' -UseGpu -Reencode
    Analyze and encode using the most powerful GPU detected on Windows.

.EXAMPLE
    .\Test-ReencodeWorth.ps1 'D:\Movies\Film.mkv' -UseGpu -Gpu 'NVIDIA GeForce RTX 4080'
    Use the named GPU for sample encodes; analysis still runs without modifying the source.

.EXAMPLE
    .\Test-ReencodeWorth.ps1 'D:\Rips' -Recurse -Reencode -Confirm:$false -OutputDir 'E:\Encoded' -ReportPath .\report.csv
    Unattended: encode everything that is worth it (or marginal) and write a CSV report.

.OUTPUTS
    [pscustomobject] per file when -PassThru is specified.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
  [Parameter(Mandatory, Position = 0)]
  [string[]]$Path,

  [switch]$Recurse,
  [switch]$SkipSample,
  [switch]$SkipVmaf,

  [ValidateSet('x265', 'av1')]
  [string]$Codec = 'x265',

  [switch]$UseGpu,
  [ValidateNotNullOrEmpty()][string]$Gpu,

  [ValidateRange(0, 63)]
  [int]$Crf,

  [string]$Preset,

  [ValidateRange(1, 20)]
  [int]$SampleCount = 5,

  [ValidateRange(5, 300)]
  [int]$SampleSeconds = 30,

  [ValidateRange(1, 99)]
  [int]$MinSavingsPercent = 30,

  [ValidateRange(50, 100)]
  [double]$MinVmaf = 95,

  [ValidateRange(0, 100000000)]
  [int]$MinSavedMB = 500,

  [switch]$Reencode,
  [switch]$Force,
  [string]$OutputDir,
  [string]$TempDir,
  [switch]$KeepSamples,
  [string]$ReportPath,
  [switch]$PassThru,
  [string]$FfmpegPath,
  [string]$FfprobePath
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$Script:SelectedGpu = $null
if ($Gpu -and -not $UseGpu) { throw '-Gpu can only be used together with -UseGpu.' }
. (Join-Path $PSScriptRoot 'Reencode.Common.ps1')

#region Constants

# File extensions treated as video when a folder is scanned.
$Script:VideoExtensions = @('.mkv', '.mp4', '.m4v', '.mov', '.avi', '.ts', '.m2ts', '.mts', '.wmv', '.webm', '.mpg', '.mpeg', '.flv', '.vob')

# Intra-frame / near-lossless video codecs: huge savings potential.
$Script:IntraFrameCodecs = @('prores', 'dnxhd', 'mjpeg', 'ffv1', 'huffyuv', 'utvideo', 'rawvideo', 'cfhd', 'v210')

# Older inter-frame codecs that are far less efficient than HEVC/AV1.
$Script:LegacyCodecs = @('mpeg2video', 'mpeg1video', 'vc1', 'wmv1', 'wmv2', 'wmv3', 'mpeg4', 'msmpeg4v2', 'msmpeg4v3', 'h263', 'flv1', 'theora', 'vp8')

# Audio codecs that are lossless (large, and worth re-encoding to Opus/AAC separately).
$Script:LosslessAudioCodecs = @('truehd', 'mlp', 'flac', 'alac', 'wavpack')

# Valid x265 preset names.
$Script:X265Presets = @('ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow', 'placebo')

#endregion

#region Small helpers

function ConvertTo-InvariantString {
  <#
    .SYNOPSIS
        Formats a number with the invariant culture so ffmpeg arguments never contain a decimal comma.
    .PARAMETER Value
        The number to format.
    .PARAMETER Format
        .NET numeric format string. Defaults to '0.###'.
    .OUTPUTS
        [string]
    #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory, Position = 0)][double]$Value,
    [Parameter(Position = 1)][string]$Format = '0.###'
  )
  return $Value.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-NullableDouble {
  <#
    .SYNOPSIS
        Parses a value (e.g. ffprobe's "N/A" or "1234") into a double, or returns $null when not numeric.
    .PARAMETER Value
        Any object; converted via its string form with the invariant culture.
    .OUTPUTS
        [double] or $null
    #>
  [CmdletBinding()]
  param([Parameter(Position = 0)][AllowNull()][object]$Value)
  if ($null -eq $Value) { return $null }
  $parsed = 0.0
  $styles = [System.Globalization.NumberStyles]::Float
  if ([double]::TryParse([string]$Value, $styles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
    return $parsed
  }
  return $null
}

function ConvertTo-FrameRate {
  <#
    .SYNOPSIS
        Converts an ffprobe frame-rate fraction such as "24000/1001" to frames per second.
    .PARAMETER Fraction
        The fraction string, or a plain number.
    .OUTPUTS
        [double] Frames per second, or 0 when it cannot be parsed.
    #>
  [CmdletBinding()]
  [OutputType([double])]
  param([Parameter(Position = 0)][AllowNull()][string]$Fraction)
  if ([string]::IsNullOrWhiteSpace($Fraction)) { return 0.0 }
  $parts = $Fraction.Split('/')
  $num = ConvertTo-NullableDouble $parts[0]
  if ($null -eq $num) { return 0.0 }
  if ($parts.Count -lt 2) { return [double]$num }
  $den = ConvertTo-NullableDouble $parts[1]
  if ($null -eq $den -or $den -eq 0) { return 0.0 }
  return [double]($num / $den)
}

function Format-FileSize {
  <#
    .SYNOPSIS
        Formats a byte count as a human-readable string (e.g. "4.20 GB").
    .PARAMETER Bytes
        Size in bytes. May be negative.
    .OUTPUTS
        [string]
    #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory, Position = 0)][double]$Bytes)
  $units = 'B', 'KB', 'MB', 'GB', 'TB'
  $i = 0
  $v = [Math]::Abs($Bytes)
  while ($v -ge 1024 -and $i -lt 4) { $v /= 1024; $i++ }
  $sign = if ($Bytes -lt 0) { '-' } else { '' }
  return ('{0}{1:N2} {2}' -f $sign, $v, $units[$i])
}

function Format-Duration {
  <#
    .SYNOPSIS
        Formats seconds as HH:MM:SS (hours may exceed 24).
    .PARAMETER Seconds
        Duration in seconds.
    .OUTPUTS
        [string]
    #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory, Position = 0)][double]$Seconds)
  $t = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
  return ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds)
}

function Format-CommandLine {
  <#
    .SYNOPSIS
        Builds a copy-pasteable command line, quoting arguments that contain spaces or shell metacharacters.
    .PARAMETER Executable
        Program name to display (e.g. 'ffmpeg').
    .PARAMETER Arguments
        Argument list.
    .OUTPUTS
        [string]
    #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory, Position = 0)][string]$Executable,
    [Parameter(Mandatory, Position = 1)][string[]]$Arguments
  )
  $parts = foreach ($a in $Arguments) {
    if ($a -match '[\s"&|<>^;]') { '"{0}"' -f ($a -replace '"', '\"') } else { $a }
  }
  return ($Executable + ' ' + ($parts -join ' ')).Trim()
}

function Invoke-Native {
  <#
    .SYNOPSIS
        Runs a native executable, capturing combined stdout/stderr and the exit code without throwing on stderr output.
    .PARAMETER FilePath
        Full path of the executable.
    .PARAMETER Arguments
        Argument list (each element is passed as one argument).
    .OUTPUTS
        [pscustomobject] with ExitCode (int) and Output (string).
    #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory, Position = 0)][string]$FilePath,
    [Parameter(Mandatory, Position = 1)][string[]]$Arguments
  )
  return Invoke-NativeCommand -FilePath $FilePath -Arguments $Arguments -Gpu $Script:SelectedGpu
}

#endregion

#region Tool discovery

function Resolve-Tool {
  <#
    .SYNOPSIS
        Finds an executable on an explicit path, on PATH, or in common Windows install locations
        (winget links, scoop, chocolatey, C:\ffmpeg\bin, Program Files\HandBrake).
    .PARAMETER Name
        Executable name without extension (e.g. 'ffmpeg').
    .PARAMETER ExplicitPath
        Optional user-supplied path; if given and invalid, an error is thrown.
    .OUTPUTS
        [string] Full path, or $null if not found.
    #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [ValidateSet('ffmpeg', 'ffprobe', 'handbrakecli')]
    [Parameter(Mandatory, Position = 0)]
    [string]$Name,
      
    [Parameter(Position = 1)][string]$ExplicitPath
  )

  $ffmpegFind = Join-Path $PSScriptRoot 'ffmpeg-find.ps1'

  if ($ExplicitPath) {
    if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
      return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    throw "The path given for $Name does not exist: $ExplicitPath"
  }
  switch ($Name) {
    'ffmpeg' {
      $Found = & $ffmpegFind -Executable ffmpeg
    }
    'ffprobe' {
      $Found = & $ffmpegFind -Executable ffprobe
    }
    'handbrakecli' {
      $Found = & 'C:\mega\IDEs\powershell\find.ps1' handbrakecli
    }
  }
  if ($Found) { return $Found }
  return $null
}

function Get-FfmpegCapabilities {
  <#
    .SYNOPSIS
        Detects which encoders/filters the located ffmpeg build supports.
    .OUTPUTS
        [pscustomobject] with Libx265, SvtAv1 and Libvmaf booleans.
    #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param()
  $enc = (Invoke-Native -FilePath $Script:FfmpegExe -Arguments @('-hide_banner', '-encoders')).Output
  $flt = (Invoke-Native -FilePath $Script:FfmpegExe -Arguments @('-hide_banner', '-filters')).Output
  $videoEncoders = @(
    [regex]::Matches($enc, '^\s*V\S*\s+(\S+)', [System.Text.RegularExpressions.RegexOptions]::Multiline) |
      ForEach-Object { $_.Groups[1].Value }
  )
  return [pscustomobject]@{
    Libx265       = [bool]($enc -match '\blibx265\b')
    SvtAv1        = [bool]($enc -match '\blibsvtav1\b')
    Libvmaf       = [bool]($flt -match '\blibvmaf\b')
    VideoEncoders = $videoEncoders
  }
}

function Get-SelectedGpu {
  <#
    .SYNOPSIS
        Selects a Windows display adapter by exact name or by reported dedicated memory.
    .PARAMETER Name
        Optional exact display-adapter name.
    .OUTPUTS
        [pscustomobject] with adapter identity, vendor, and NVIDIA encoder index.
    #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([string]$Name)

  if ($env:OS -ne 'Windows_NT') {
    throw 'GPU selection currently requires Windows display-adapter detection.'
  }

  try {
    $controllers = New-Object System.Collections.Generic.List[object]
    foreach ($controller in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
      if ($controller.PNPDeviceID -match '^PCI\\VEN_([0-9A-Fa-f]{4})&') {
        $adapterRam = [uint64]$controller.AdapterRAM
        if ($adapterRam -gt 0) {
          $controllers.Add([pscustomobject]@{
              Name       = [string]$controller.Name
              VendorId   = $Matches[1].ToLowerInvariant()
              AdapterRam = $adapterRam
            })
        }
      }
    }
  }
  catch {
    throw "Could not enumerate Windows display adapters needed for GPU selection: $($_.Exception.Message)"
  }
  if ($controllers.Count -eq 0) {
    throw 'Windows did not report a PCI display adapter with dedicated memory; cannot select a GPU safely.'
  }

  if ($Name) {
    $namedControllers = @($controllers | Where-Object { $_.Name -ieq $Name })
    if ($namedControllers.Count -ne 1) {
      $available = ($controllers.Name | Sort-Object -Unique) -join '; '
      if ($namedControllers.Count -gt 1) { throw "More than one display adapter is named '$Name'; selection is ambiguous." }
      throw "No display adapter exactly matches '$Name'. Available adapters: $available"
    }
    $gpu = $namedControllers[0]
  }
  else {
    $maximumRam = ($controllers | Measure-Object -Property AdapterRam -Maximum).Maximum
    $topControllers = @($controllers | Where-Object { $_.AdapterRam -eq $maximumRam })
    if ($topControllers.Count -ne 1) {
      throw 'Windows reported multiple top-ranked GPUs with equal dedicated memory; specify -Gpu with an exact adapter name.'
    }
    $gpu = $topControllers[0]
  }

  if ($gpu.VendorId -notin @('10de', '1002', '8086')) {
    throw "The selected GPU '$($gpu.Name)' has unsupported vendor ID 0x$($gpu.VendorId). Supported vendors are NVIDIA, AMD, and Intel."
  }

  $vendorCount = @($controllers | Where-Object { $_.VendorId -eq $gpu.VendorId }).Count
  $nvidiaIndex = $null
  if ($gpu.VendorId -eq '10de') {
    if (Test-Path Env:CUDA_VISIBLE_DEVICES) {
      throw 'CUDA_VISIBLE_DEVICES is set, so the selected NVIDIA adapter cannot be safely mapped to FFmpeg device indices.'
    }
    $smiPath = (Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue).Source
    if (-not $smiPath -and $env:ProgramFiles) {
      $knownSmiPath = Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
      if (Test-Path -LiteralPath $knownSmiPath -PathType Leaf) { $smiPath = $knownSmiPath }
    }

    if ($smiPath) {
      $oldPreference = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        $smiLines = @(& $smiPath '--query-gpu=index,name,memory.total' '--format=csv,noheader,nounits' 2>&1)
        $smiExitCode = $LASTEXITCODE
      }
      finally { $ErrorActionPreference = $oldPreference }

      if ($smiExitCode -eq 0) {
        $nvidiaGpus = @(
          foreach ($line in $smiLines) {
            if ("$line" -match '^\s*(\d+)\s*,\s*(.*?)\s*,\s*(\d+)\s*$') {
              [pscustomobject]@{
                Index     = [int]$Matches[1]
                Name      = $Matches[2]
                MemoryMiB = [uint64]$Matches[3]
              }
            }
          }
        )
        $namedNvidiaGpus = @($nvidiaGpus | Where-Object { $_.Name -ieq $gpu.Name })
        if ($namedNvidiaGpus.Count -eq 1) { $nvidiaIndex = $namedNvidiaGpus[0].Index }
        elseif ($namedNvidiaGpus.Count -gt 1) {
          $memoryMatches = @($namedNvidiaGpus | Where-Object {
              [Math]::Abs([double]$_.MemoryMiB - ($gpu.AdapterRam / 1MB)) -lt 256
            })
          if ($memoryMatches.Count -eq 1) { $nvidiaIndex = $memoryMatches[0].Index }
        }
      }
    }
    if ($null -eq $nvidiaIndex -and $vendorCount -eq 1) { $nvidiaIndex = 0 }
    if ($null -eq $nvidiaIndex) {
      throw "Could not safely map '$($gpu.Name)' to an NVIDIA FFmpeg device index. Verify nvidia-smi and select a uniquely identifiable adapter."
    }
  }

  return [pscustomobject]@{
    Name        = $gpu.Name
    VendorId    = $gpu.VendorId
    AdapterRam  = $gpu.AdapterRam
    VendorCount = $vendorCount
    NvidiaIndex = $nvidiaIndex
  }
}

function Get-ProcessorName {
  [CmdletBinding()]
  [OutputType([string])]
  param()

  try {
    $names = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
      ForEach-Object { $_.Name.Trim() } | Where-Object { $_ })
  }
  catch {
    throw "Could not identify the CPU for the processing-device report: $($_.Exception.Message)"
  }
  if ($names.Count -eq 0) {
    throw 'Windows did not report a CPU model; cannot display the processing device.'
  }
  return ($names -join ', ')
}

function Get-GpuDeviceArguments {
  [CmdletBinding()]
  [OutputType([string[]])]
  param([Parameter(Mandatory)][pscustomobject]$Gpu)

  switch ($Gpu.VendorId) {
    '8086' {
      if ($Gpu.VendorCount -gt 1) {
        throw "Multiple Intel GPUs are present, and FFmpeg cannot unambiguously pin QSV to '$($Gpu.Name)'."
      }
      return @(
        '-init_hw_device', "d3d11va=preferred:,vendor_id=0x$($Gpu.VendorId)",
        '-init_hw_device', 'qsv=encode@preferred', '-filter_hw_device', 'encode'
      )
    }
    '1002' {
      if ($Gpu.VendorCount -gt 1) {
        throw "Multiple AMD GPUs are present, and FFmpeg cannot unambiguously pin AMF to '$($Gpu.Name)'."
      }
      return @(
        '-init_hw_device', "d3d11va=preferred:,vendor_id=0x$($Gpu.VendorId)",
        '-init_hw_device', 'amf=encode@preferred', '-filter_hw_device', 'encode'
      )
    }
    default { return @() }
  }
}

function Get-GpuVideoEncoderArguments {
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][pscustomobject]$Gpu,
    [Parameter(Mandatory)][string]$Codec,
    [Parameter(Mandatory)][int]$Crf,
    [Parameter(Mandatory)][string]$Preset,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AvailableEncoders
  )

  $encoder = switch ($Gpu.VendorId) {
    '10de' { if ($Codec -eq 'x265') { 'hevc_nvenc' } else { 'av1_nvenc' } }
    '1002' { if ($Codec -eq 'x265') { 'hevc_amf' } else { 'av1_amf' } }
    '8086' { if ($Codec -eq 'x265') { 'hevc_qsv' } else { 'av1_qsv' } }
  }
  if ($AvailableEncoders -notcontains $encoder) {
    throw "FFmpeg does not provide '$encoder' for the selected GPU. Verify the adapter supports $Codec hardware encoding and use an FFmpeg build with that encoder."
  }

  if ($Gpu.VendorId -eq '10de') {
    if ($null -eq $Gpu.NvidiaIndex) { throw "Could not determine the NVIDIA adapter index for '$($Gpu.Name)'." }
    if ($Codec -eq 'x265') {
      $presetRanks = @{
        ultrafast = 1; superfast = 2; veryfast = 3; faster = 4; fast = 4
        medium = 5; slow = 6; slower = 7; veryslow = 7; placebo = 7
      }
      $presetRank = $presetRanks[$Preset]
    }
    else {
      $presetRank = [Math]::Max(1, [Math]::Min(7, 7 - [int][Math]::Round([int]$Preset * 6 / 13)))
    }
    return @('-c:v', $encoder, '-preset', "p$presetRank", '-rc', 'vbr', '-cq', "$Crf", '-b:v', '0',
      '-gpu', [string]$Gpu.NvidiaIndex, '-pix_fmt', 'yuv420p')
  }
  if ($Gpu.VendorId -eq '1002') {
    if ($Codec -eq 'x265') {
      $quality = if ($Preset -in @('ultrafast', 'superfast', 'veryfast', 'faster', 'fast')) {
        'speed'
      }
      elseif ($Preset -eq 'medium') { 'balanced' }
      else { 'quality' }
    }
    else {
      if ([int]$Preset -ge 9) { $quality = 'speed' }
      elseif ([int]$Preset -ge 5) { $quality = 'balanced' }
      else { $quality = 'quality' }
    }
    return @('-c:v', $encoder, '-quality', $quality, '-rc', 'cqp', '-qp_i', "$Crf", '-qp_p', "$Crf",
      '-vf', 'format=nv12,hwupload')
  }

  if ($Codec -eq 'x265') {
    $qsvPresets = @{
      ultrafast = 'veryfast'; superfast = 'veryfast'; veryfast = 'veryfast'; faster = 'faster'
      fast = 'fast'; medium = 'medium'; slow = 'slow'; slower = 'slower'; veryslow = 'veryslow'; placebo = 'veryslow'
    }
    $qsvPreset = $qsvPresets[$Preset]
  }
  else {
    $presetValue = [int]$Preset
    if ($presetValue -ge 10) { $qsvPreset = 'veryfast' }
    elseif ($presetValue -ge 7) { $qsvPreset = 'faster' }
    elseif ($presetValue -ge 4) { $qsvPreset = 'medium' }
    elseif ($presetValue -ge 2) { $qsvPreset = 'slow' }
    else { $qsvPreset = 'veryslow' }
  }
  return @('-c:v', $encoder, '-preset', $qsvPreset, '-global_quality', "$Crf",
    '-vf', 'format=nv12,hwupload=extra_hw_frames=64')
}

#endregion

#region Input discovery

function Get-VideoFiles {
  <#
    .SYNOPSIS
        Expands files, folders and wildcard patterns into a de-duplicated list of video files.
    .PARAMETER Paths
        Files, folders or wildcard patterns.
    .PARAMETER Recurse
        Scan folders recursively.
    .OUTPUTS
        [System.IO.FileInfo[]]
    #>
  [CmdletBinding()]
  [OutputType([System.IO.FileInfo[]])]
  param(
    [Parameter(Mandatory, Position = 0)][string[]]$Paths,
    [Parameter(Position = 1)][switch]$Recurse
  )
  $found = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  foreach ($p in $Paths) {
    $items = @()
    if (Test-Path -LiteralPath $p) { $items = @(Get-Item -LiteralPath $p) }
    else { $items = @(Resolve-Path -Path $p -ErrorAction SilentlyContinue | ForEach-Object { Get-Item -LiteralPath $_.Path }) }
    if ($items.Count -eq 0) { Write-Warning "No match for path: $p"; continue }
    foreach ($item in $items) {
      if ($item.PSIsContainer) {
        $gci = @{ LiteralPath = $item.FullName; File = $true }
        if ($Recurse) { $gci['Recurse'] = $true }
        Get-ChildItem @gci | Where-Object { $Script:VideoExtensions -contains $_.Extension.ToLowerInvariant() } |
          ForEach-Object { $found.Add($_) }
      }
      else { $found.Add([System.IO.FileInfo]$item) }
    }
  }
  return @($found | Sort-Object FullName -Unique)
}

#endregion

#region Stage 1: triage

function Get-MediaInfo {
  <#
    .SYNOPSIS
        Reads stream and container metadata with ffprobe and normalizes it.
    .DESCRIPTION
        Video bitrate is taken from the stream, then from the MKV BPS tag, and otherwise estimated as
        (file size / duration) minus known audio bitrates. BitrateSource reports which was used.
    .PARAMETER LiteralPath
        Full path of the media file.
    .OUTPUTS
        [pscustomobject] with Path, FileSize, Duration, VideoIndex, Codec, Profile, Width, Height, Fps,
        PixFmt, BitDepth, IsHdr, FieldOrder, VideoBitrate (bits/s), BitrateSource, Audio[], SubtitleCodecs[].
    #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param([Parameter(Mandatory, Position = 0)][string]$LiteralPath)

  $entries = 'stream=index,codec_name,codec_type,profile,width,height,pix_fmt,r_frame_rate,avg_frame_rate,bit_rate,channels,color_transfer,field_order' +
  ':stream_tags=BPS:stream_disposition=attached_pic:format=duration,bit_rate'
  $probeArgs = @('-v', 'error', '-print_format', 'json', '-show_entries', $entries, $LiteralPath)
  $raw = & $Script:FfprobeExe @probeArgs 2>$null | Out-String
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { throw "ffprobe could not read '$LiteralPath'." }
  $data = $raw | ConvertFrom-Json

  $fileSize = (Get-Item -LiteralPath $LiteralPath).Length
  $duration = ConvertTo-NullableDouble $data.format.duration
  if ($null -eq $duration -or $duration -le 0) { throw 'Could not determine the duration of this file.' }

  $streams = @($data.streams)
  $video = @($streams | Where-Object { $_.codec_type -eq 'video' -and -not ($_.disposition -and $_.disposition.attached_pic -eq 1) })
  if ($video.Count -eq 0) { throw 'No video stream found.' }
  $v = $video[0]

  $audio = foreach ($a in @($streams | Where-Object { $_.codec_type -eq 'audio' })) {
    $br = ConvertTo-NullableDouble $a.bit_rate
    if ($null -eq $br -and $a.tags) { $br = ConvertTo-NullableDouble $a.tags.BPS }
    $codecName = [string]$a.codec_name
    $AudioProfile = [string]$a.profile
    $lossless = ($Script:LosslessAudioCodecs -contains $codecName) -or ($codecName -like 'pcm_*') -or ($AudioProfile -match 'MA|Lossless')
    [pscustomobject]@{
      Codec    = $codecName
      Profile  = $AudioProfile
      Channels = $a.channels
      Bitrate  = $(if ($null -ne $br) { [double]$br } else { 0.0 })
      Lossless = [bool]$lossless
    }
  }
  $audio = @($audio)
  $subs = @($streams | Where-Object { $_.codec_type -eq 'subtitle' } | ForEach-Object { [string]$_.codec_name })

  $audioBps = ($audio | Measure-Object -Property Bitrate -Sum).Sum
  if ($null -eq $audioBps) { $audioBps = 0.0 }

  $vb = ConvertTo-NullableDouble $v.bit_rate
  $source = 'stream'
  if ($null -eq $vb -and $v.tags) { $vb = ConvertTo-NullableDouble $v.tags.BPS; $source = 'tag' }
  if ($null -eq $vb -or $vb -le 0) {
    $vb = [Math]::Max(1.0, ($fileSize * 8.0 / $duration) - $audioBps)
    $source = 'estimated'
  }

  $fps = ConvertTo-FrameRate $v.avg_frame_rate
  if ($fps -le 0) { $fps = ConvertTo-FrameRate $v.r_frame_rate }

  $pix = [string]$v.pix_fmt
  $depth = 8
  if ($pix -match '(?<d>10|12|14|16)(le|be)$') { $depth = [int]$Matches['d'] }

  return [pscustomobject]@{
    Path           = $LiteralPath
    FileSize       = [long]$fileSize
    Duration       = [double]$duration
    VideoIndex     = [int]$v.index
    Codec          = [string]$v.codec_name
    Profile        = [string]$v.profile
    Width          = [int]$v.width
    Height         = [int]$v.height
    Fps            = [double]$fps
    PixFmt         = $pix
    BitDepth       = $depth
    IsHdr          = ([string]$v.color_transfer -in @('smpte2084', 'arib-std-b67'))
    FieldOrder     = [string]$v.field_order
    VideoBitrate   = [double]$vb
    BitrateSource  = $source
    Audio          = $audio
    SubtitleCodecs = $subs
  }
}

function Get-TriageAssessment {
  <#
    .SYNOPSIS
        Rates how much a file is likely to shrink when re-encoded, using metadata only.
    .DESCRIPTION
        Uses codec family and bits-per-pixel-per-frame (video bitrate / (width * height * fps)).
        For H.264, roughly < 0.05 is already lean, > 0.10 has plenty of headroom.
    .PARAMETER Info
        Object returned by Get-MediaInfo.
    .PARAMETER Codec
        Target codec ('x265' or 'av1').
    .OUTPUTS
        [pscustomobject] with Potential (High|Medium|Low|Skip), Bpp, AudioShare, LosslessAudio, Notes[].
    #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory, Position = 0)][pscustomobject]$Info,
    [Parameter(Mandatory, Position = 1)][ValidateSet('x265', 'av1')][string]$Codec
  )
  $notes = New-Object System.Collections.Generic.List[string]
  $pixels = [double]$Info.Width * $Info.Height
  $bpp = 0.0
  if ($pixels -gt 0 -and $Info.Fps -gt 0) { $bpp = $Info.VideoBitrate / ($pixels * $Info.Fps) }

  $potential = 'Medium'
  $c = $Info.Codec
  if ($Script:IntraFrameCodecs -contains $c) {
    $potential = 'High'; $notes.Add("Intra-frame/lossless codec ($c): very large savings expected.")
  }
  elseif ($Script:LegacyCodecs -contains $c) {
    $potential = 'High'; $notes.Add("Legacy codec ($c): much less efficient than HEVC/AV1.")
  }
  elseif ($c -eq 'av1' -or ($c -eq 'hevc' -and $Codec -eq 'x265')) {
    $potential = 'Skip'; $notes.Add("Already $($c): gains would be small and re-encoding adds generational loss.")
  }
  elseif ($c -eq 'hevc' -and $Codec -eq 'av1') {
    $potential = $(if ($bpp -ge 0.15) { 'Medium' } else { 'Low' })
    $notes.Add('HEVC -> AV1 typically saves only ~10-25%.')
  }
  elseif ($c -eq 'vp9') {
    $potential = 'Low'; $notes.Add('VP9 is already efficient; expect modest savings.')
  }
  else {
    if ($bpp -lt 0.05) { $potential = 'Low' }
    elseif ($bpp -lt 0.10) { $potential = 'Medium' }
    else { $potential = 'High' }
  }

  if ($Info.BitrateSource -eq 'estimated') { $notes.Add('Video bitrate was estimated from file size (stream did not report it).') }
  if ($Info.IsHdr) { $notes.Add('HDR source: check HDR metadata after encoding; Dolby Vision layers are dropped; VMAF is less reliable on HDR.') }
  if ($Info.FieldOrder -in @('tt', 'bb', 'tb', 'bt')) { $notes.Add('Interlaced source: consider deinterlacing (e.g. -vf bwdif) before encoding.') }
  if ($Info.SubtitleCodecs -contains 'mov_text') { $notes.Add('mov_text subtitles cannot be copied into MKV; they will be converted to SRT.') }

  $audioBytes = (($Info.Audio | Measure-Object -Property Bitrate -Sum).Sum) * $Info.Duration / 8
  if ($null -eq $audioBytes) { $audioBytes = 0 }
  $audioShare = $(if ($Info.FileSize -gt 0) { $audioBytes / $Info.FileSize } else { 0 })
  $lossless = @($Info.Audio | Where-Object { $_.Lossless }).Count -gt 0
  if ($lossless -and $audioShare -ge 0.08) {
    $notes.Add(('Lossless audio is ~{0:P0} of the file; re-encoding it to Opus/AAC may save more than the video.' -f $audioShare))
  }

  return [pscustomobject]@{
    Potential     = $potential
    Bpp           = $bpp
    AudioShare    = $audioShare
    LosslessAudio = $lossless
    Notes         = @($notes)
  }
}

function Write-TriageReport {
  <#
    .SYNOPSIS
        Prints the triage stage to the console.
    .PARAMETER Info
        Object returned by Get-MediaInfo.
    .PARAMETER Triage
        Object returned by Get-TriageAssessment.
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position = 0)][pscustomobject]$Info,
    [Parameter(Mandatory, Position = 1)][pscustomobject]$Triage
  )
  $color = switch ($Triage.Potential) { 'High' { 'Green' } 'Medium' { 'Yellow' } default { 'Red' } }
  $audioDesc = ($Info.Audio | ForEach-Object { '{0}{1}' -f $_.Codec, $(if ($_.Lossless) { '(lossless)' } else { '' }) }) -join ', '
  Write-Host '[1] Triage (metadata)' -ForegroundColor Cyan
  Write-Host ('    Size      : {0}   Duration: {1}' -f (Format-FileSize $Info.FileSize), (Format-Duration $Info.Duration))
  Write-Host ('    Video     : {0} {1}x{2} @ {3:N3} fps, {4}-bit, {5:N0} kbps ({6})' -f $Info.Codec, $Info.Width, $Info.Height, $Info.Fps, $Info.BitDepth, ($Info.VideoBitrate / 1000), $Info.BitrateSource)
  Write-Host ('    Bits/px   : {0:N3}   Audio: {1}' -f $Triage.Bpp, $(if ($audioDesc) { $audioDesc } else { 'none' }))
  Write-Host '    Potential : ' -NoNewline
  Write-Host $Triage.Potential -ForegroundColor $color
  foreach ($n in $Triage.Notes) { Write-Host "    - $n" -ForegroundColor DarkGray }
}

#endregion

#region Stage 2/3: sample encode and VMAF

function Get-VideoEncoderArguments {
  <#
    .SYNOPSIS
        Returns the ffmpeg video-encoder arguments for the chosen codec (10-bit output).
    .PARAMETER Codec
        'x265' or 'av1'.
    .PARAMETER Crf
        Constant-quality value.
    .PARAMETER Preset
        Encoder preset.
    .PARAMETER QuietEncoder
        Suppress x265's own log output (used for sample encodes).
    .PARAMETER Gpu
        Selected GPU adapter, or $null to use the CPU.
    .PARAMETER AvailableEncoders
        Video encoders exposed by the selected FFmpeg build.
    .OUTPUTS
        [string[]]
    #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][ValidateSet('x265', 'av1')][string]$Codec,
    [Parameter(Mandatory)][int]$Crf,
    [Parameter(Mandatory)][string]$Preset,
    [AllowNull()][pscustomobject]$Gpu,
    [string[]]$AvailableEncoders = @(),
    [switch]$QuietEncoder
  )
  if ($Gpu) {
    return @(Get-GpuVideoEncoderArguments -Gpu $Gpu -Codec $Codec -Crf $Crf `
        -Preset $Preset -AvailableEncoders $AvailableEncoders)
  }
  if ($Codec -eq 'x265') {
    $a = @('-c:v', 'libx265', '-preset', $Preset, '-crf', "$Crf", '-pix_fmt', 'yuv420p10le')
    if ($QuietEncoder) { $a += @('-x265-params', 'log-level=error') }
  }
  else {
    $a = @('-c:v', 'libsvtav1', '-preset', $Preset, '-crf', "$Crf", '-pix_fmt', 'yuv420p10le')
  }
  return $a
}

function Get-ClipDuration {
  <#
    .SYNOPSIS
        Returns the duration of a media file in seconds using ffprobe.
    .PARAMETER LiteralPath
        Path of the clip.
    .PARAMETER Fallback
        Value returned when the duration cannot be read.
    .OUTPUTS
        [double]
    #>
  [CmdletBinding()]
  [OutputType([double])]
  param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [double]$Fallback = 0
  )
  $out = & $Script:FfprobeExe -v error -show_entries format=duration -of 'csv=p=0' $LiteralPath 2>$null | Select-Object -First 1
  $d = ConvertTo-NullableDouble $out
  if ($null -eq $d -or $d -le 0) { return $Fallback }
  return [double]$d
}

function Measure-Vmaf {
  <#
    .SYNOPSIS
        Computes per-frame VMAF scores of an encoded clip against its reference clip.
    .DESCRIPTION
        Both inputs are converted to yuv420p10le so libvmaf's matching-format requirement is satisfied.
        The log is written to a relative path inside WorkDir to avoid Windows drive-letter escaping in filters.
    .PARAMETER Distorted
        Encoded clip (first input).
    .PARAMETER Reference
        Source clip (second input).
    .PARAMETER WorkDir
        Temp folder used as the working directory.
    .OUTPUTS
        [double[]] per-frame VMAF scores, or $null if the measurement failed.
    #>
  [CmdletBinding()]
  [OutputType([double[]])]
  param(
    [Parameter(Mandatory)][string]$Distorted,
    [Parameter(Mandatory)][string]$Reference,
    [Parameter(Mandatory)][string]$WorkDir
  )
  $logName = 'vmaf.json'
  $logPath = Join-Path $WorkDir $logName
  if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }
  $threads = [Environment]::ProcessorCount
  $filter = '[0:v]format=yuv420p10le,setpts=PTS-STARTPTS[d];[1:v]format=yuv420p10le,setpts=PTS-STARTPTS[r];' +
  "[d][r]libvmaf=log_fmt=json:log_path=${logName}:n_threads=$threads"
  Push-Location -LiteralPath $WorkDir
  try {
    $r = Invoke-Native -FilePath $Script:FfmpegExe -Arguments @('-hide_banner', '-v', 'error', '-nostats', '-nostdin', '-i', $Distorted, '-i', $Reference, '-lavfi', $filter, '-f', 'null', '-')
  }
  finally { Pop-Location }
  if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $logPath)) {
    Write-Warning "VMAF failed: $($r.Output)"
    return $null
  }
  $json = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
  $scores = @($json.frames | ForEach-Object { [double]$_.metrics.vmaf })
  if ($scores.Count -eq 0) { return $null }
  return $scores
}

function Invoke-SampleAnalysis {
  <#
    .SYNOPSIS
        Cuts, encodes and (optionally) VMAF-scores short clips, returning aggregate numbers.
    .DESCRIPTION
        Each clip is first stream-copied out of the source (video only) so size comparison is fair
        (same frames in and out), then encoded with the intended settings and timed.
    .PARAMETER Info
        Object returned by Get-MediaInfo.
    .PARAMETER Codec
        'x265' or 'av1'.
    .PARAMETER Crf
        Constant-quality value.
    .PARAMETER Preset
        Encoder preset.
    .PARAMETER WorkDir
        Temp folder for clips.
    .PARAMETER SampleCount
        Number of clips.
    .PARAMETER SampleSeconds
        Length of each clip.
    .PARAMETER Gpu
        Selected GPU adapter, or $null to encode on the CPU.
    .PARAMETER AvailableEncoders
        Video encoders exposed by the selected FFmpeg build.
    .PARAMETER IncludeVmaf
        Also compute VMAF.
    .OUTPUTS
        [pscustomobject] with ClipCount, SrcBytes, EncBytes, SizeRatio, SrcSeconds, WallSeconds, Speed,
        VmafMean, VmafP1, VmafMin (the VMAF values are $null if not measured).
    #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][pscustomobject]$Info,
    [Parameter(Mandatory)][string]$Codec,
    [Parameter(Mandatory)][int]$Crf,
    [Parameter(Mandatory)][string]$Preset,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][int]$SampleCount,
    [Parameter(Mandatory)][int]$SampleSeconds,
    [AllowNull()][pscustomobject]$Gpu,
    [string[]]$AvailableEncoders = @(),
    [bool]$IncludeVmaf = $true
  )
  $plan = @(Get-SamplePlan -Duration $Info.Duration -Count $SampleCount -Seconds $SampleSeconds)
  $encArgs = @(Get-VideoEncoderArguments -Codec $Codec -Crf $Crf -Preset $Preset -Gpu $Gpu `
      -AvailableEncoders $AvailableEncoders -QuietEncoder)
  $srcBytes = 0L; $encBytes = 0L; $srcSeconds = 0.0; $wall = 0.0
  $scores = New-Object System.Collections.Generic.List[double]
  $done = 0

  Write-Host ('[2] Sample encode: {0} clip(s) x {1}s, {2} CRF {3} preset {4}' -f $plan.Count, $SampleSeconds, $Codec, $Crf, $Preset) -ForegroundColor Cyan
  $n = 0
  foreach ($clip in $plan) {
    $n++
    $srcClip = Join-Path $WorkDir ('clip{0}_src.mkv' -f $n)
    $encClip = Join-Path $WorkDir ('clip{0}_enc.mkv' -f $n)
    Write-Host ('    Clip {0}/{1} at {2} ...' -f $n, $plan.Count, (Format-Duration $clip.Start)) -NoNewline

    $extract = @('-y', '-v', 'error', '-nostdin', '-ss', (ConvertTo-InvariantString $clip.Start), '-t', (ConvertTo-InvariantString $clip.Length),
      '-i', $Info.Path, '-map', ('0:{0}' -f $Info.VideoIndex), '-c', 'copy', '-an', '-sn', '-dn', '-avoid_negative_ts', 'make_zero', $srcClip)
    $r = Invoke-Native -FilePath $Script:FfmpegExe -Arguments $extract
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $srcClip)) { Write-Host ' extract failed, skipped' -ForegroundColor Red; continue }
    $clipSeconds = Get-ClipDuration -LiteralPath $srcClip -Fallback $clip.Length

    $deviceArgs = if ($Gpu) { @(Get-GpuDeviceArguments -Gpu $Gpu) } else { @() }
    $encode = @('-y', '-v', 'error', '-nostdin') + $deviceArgs +
      @('-i', $srcClip, '-map', '0:v:0') + $encArgs + @('-an', '-sn', '-dn', $encClip)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Native -FilePath $Script:FfmpegExe -Arguments $encode
    $sw.Stop()
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $encClip)) { Write-Host " encode failed: $($r.Output)" -ForegroundColor Red; continue }

    $s = (Get-Item -LiteralPath $srcClip).Length
    $e = (Get-Item -LiteralPath $encClip).Length
    $srcBytes += $s; $encBytes += $e; $srcSeconds += $clipSeconds; $wall += $sw.Elapsed.TotalSeconds
    $done++
    Write-Host (' {0} -> {1} ({2:P0} of source, {3:N2}x speed)' -f (Format-FileSize $s), (Format-FileSize $e), ($e / [Math]::Max(1, $s)), ($clipSeconds / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)))

    if ($IncludeVmaf) {
      $clipScores = Measure-Vmaf -Distorted $encClip -Reference $srcClip -WorkDir $WorkDir
      if ($clipScores) { foreach ($x in $clipScores) { $scores.Add($x) } }
    }
  }
  if ($done -eq 0 -or $srcBytes -le 0) { throw 'No sample clips could be encoded.' }

  $vMean = $null; $vP1 = $null; $vMin = $null
  if ($scores.Count -gt 0) {
    $sorted = @($scores | Sort-Object)
    $vMean = ($scores | Measure-Object -Average).Average
    $vMin = $sorted[0]
    $vP1 = $sorted[[int][Math]::Floor(0.01 * ($sorted.Count - 1))]
  }
  return [pscustomobject]@{
    ClipCount   = $done
    SrcBytes    = $srcBytes
    EncBytes    = $encBytes
    SizeRatio   = $encBytes / [double]$srcBytes
    SrcSeconds  = $srcSeconds
    WallSeconds = $wall
    Speed       = $srcSeconds / [Math]::Max(0.001, $wall)
    VmafMean    = $vMean
    VmafP1      = $vP1
    VmafMin     = $vMin
  }
}

function Get-Projection {
  <#
    .SYNOPSIS
        Extrapolates sample results to the whole file.
    .DESCRIPTION
        Applies the sample size ratio to the video stream only; audio, subtitles and attachments are
        assumed to be copied unchanged.
    .PARAMETER Info
        Object returned by Get-MediaInfo.
    .PARAMETER Sample
        Object returned by Invoke-SampleAnalysis.
    .OUTPUTS
        [pscustomobject] with ProjectedBytes, SavedBytes, SavingsPercent, EstimatedEncodeSeconds.
    #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][pscustomobject]$Info,
    [Parameter(Mandatory)][pscustomobject]$Sample
  )
  $videoBytes = [Math]::Min([double]$Info.FileSize, $Info.VideoBitrate * $Info.Duration / 8)
  $nonVideo = [Math]::Max(0.0, $Info.FileSize - $videoBytes)
  $projected = $nonVideo + $videoBytes * $Sample.SizeRatio
  $saved = $Info.FileSize - $projected
  return [pscustomobject]@{
    ProjectedBytes         = [long]$projected
    SavedBytes             = [long]$saved
    SavingsPercent         = 100.0 * $saved / [Math]::Max(1.0, [double]$Info.FileSize)
    EstimatedEncodeSeconds = $Info.Duration / [Math]::Max(0.001, $Sample.Speed)
  }
}

#endregion

#region Verdict and next steps

function Get-Verdict {
  <#
    .SYNOPSIS
        Combines triage, projected savings and VMAF into WORTH IT / MARGINAL / NOT WORTH IT.
    .PARAMETER Triage
        Object returned by Get-TriageAssessment.
    .PARAMETER Sample
        Object returned by Invoke-SampleAnalysis, or $null when samples were skipped.
    .PARAMETER Projection
        Object returned by Get-Projection, or $null when samples were skipped.
    .PARAMETER MinSavingsPercent
        Required projected savings (percent).
    .PARAMETER MinVmaf
        Required mean VMAF.
    .PARAMETER MinSavedMB
        Required absolute saving in MB.
    .OUTPUTS
        [pscustomobject] with Verdict, Basis ('sample' or 'triage-only') and Reasons[].
    #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][pscustomobject]$Triage,
    [AllowNull()][object]$Sample,
    [AllowNull()][object]$Projection,
    [Parameter(Mandatory)][int]$MinSavingsPercent,
    [Parameter(Mandatory)][double]$MinVmaf,
    [Parameter(Mandatory)][int]$MinSavedMB
  )
  $reasons = New-Object System.Collections.Generic.List[string]
  $fail = $false; $marginal = $false

  if ($null -eq $Sample -or $null -eq $Projection) {
    switch ($Triage.Potential) {
      'High' { $v = 'WORTH IT' }
      'Medium' { $v = 'MARGINAL' }
      default { $v = 'NOT WORTH IT' }
    }
    $reasons.Add("Metadata-only estimate (potential: $($Triage.Potential)). Run without -SkipSample to verify.")
    return [pscustomobject]@{ Verdict = $v; Basis = 'triage-only'; Reasons = @($reasons) }
  }

  $sav = $Projection.SavingsPercent
  if ($sav -ge $MinSavingsPercent) { $reasons.Add(('[+] Projected savings {0:N0}% (>= {1}%)' -f $sav, $MinSavingsPercent)) }
  elseif ($sav -ge ($MinSavingsPercent * 0.66)) { $marginal = $true; $reasons.Add(('[~] Projected savings {0:N0}% is below the {1}% target' -f $sav, $MinSavingsPercent)) }
  else { $fail = $true; $reasons.Add(('[-] Projected savings only {0:N0}% (target {1}%)' -f $sav, $MinSavingsPercent)) }

  $savedMB = $Projection.SavedBytes / 1MB
  if ($savedMB -ge $MinSavedMB) { $reasons.Add(('[+] Saves {0} (>= {1} MB)' -f (Format-FileSize $Projection.SavedBytes), $MinSavedMB)) }
  else { $marginal = $true; $reasons.Add(('[~] Absolute saving {0} is under {1} MB' -f (Format-FileSize $Projection.SavedBytes), $MinSavedMB)) }

  if ($null -ne $Sample.VmafMean) {
    if ($Sample.VmafMean -ge $MinVmaf) { $reasons.Add(('[+] Mean VMAF {0:N2} (>= {1})' -f $Sample.VmafMean, $MinVmaf)) }
    elseif ($Sample.VmafMean -ge ($MinVmaf - 3)) { $marginal = $true; $reasons.Add(('[~] Mean VMAF {0:N2} is slightly below {1}' -f $Sample.VmafMean, $MinVmaf)) }
    else { $fail = $true; $reasons.Add(('[-] Mean VMAF {0:N2} is well below {1}' -f $Sample.VmafMean, $MinVmaf)) }
    if ($Sample.VmafP1 -lt ($MinVmaf - 10)) { $marginal = $true; $reasons.Add(('[~] Worst 1% of frames score {0:N1}; some scenes may look visibly worse' -f $Sample.VmafP1)) }
  }
  else { $reasons.Add('[~] Quality not measured (VMAF skipped or unavailable); check the clips by eye.') }

  if ($Triage.Potential -eq 'Skip') { $marginal = $true; $reasons.Add('[~] Source is already HEVC/AV1; generational loss applies.') }

  $v = if ($fail) { 'NOT WORTH IT' } elseif ($marginal) { 'MARGINAL' } else { 'WORTH IT' }
  return [pscustomobject]@{ Verdict = $v; Basis = 'sample'; Reasons = @($reasons) }
}

function Get-OutputPath {
  <#
    .SYNOPSIS
        Builds the re-encoded output path: <name>.<codec>.mkv in OutputDir or beside the source.
    .PARAMETER SourcePath
        Full path of the source video.
    .PARAMETER Codec
        'x265' or 'av1' (used as the name suffix).
    .PARAMETER OutputDir
        Optional destination folder.
    .OUTPUTS
        [string]
    #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$Codec,
    [string]$OutputDir
  )
  $dir = if ($OutputDir) { $OutputDir } else { Split-Path -Parent $SourcePath }
  $base = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
  return (Join-Path $dir ('{0}.{1}.mkv' -f $base, $Codec))
}

function Get-FfmpegReencodeArguments {
  <#
    .SYNOPSIS
        Builds the full ffmpeg argument list for the real re-encode.
    .DESCRIPTION
        Maps all real video streams (not cover art), audio, subtitles and attachments; copies everything
        except video; keeps chapters and metadata. mov_text subtitles are converted to SRT for MKV.
    .PARAMETER Info
        Object returned by Get-MediaInfo.
    .PARAMETER OutputPath
        Destination file.
    .PARAMETER Codec
        'x265' or 'av1'.
    .PARAMETER Crf
        Constant-quality value.
    .PARAMETER Preset
        Encoder preset.
    .PARAMETER Gpu
        Selected GPU adapter, or $null to encode on the CPU.
    .PARAMETER AvailableEncoders
        Video encoders exposed by the selected FFmpeg build.
    .OUTPUTS
        [string[]]
    #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][pscustomobject]$Info,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$Codec,
    [Parameter(Mandatory)][int]$Crf,
    [Parameter(Mandatory)][string]$Preset,
    [AllowNull()][pscustomobject]$Gpu,
    [string[]]$AvailableEncoders = @()
  )
  $subCodec = if ($Info.SubtitleCodecs -contains 'mov_text') { 'srt' } else { 'copy' }
  $deviceArgs = if ($Gpu) { @(Get-GpuDeviceArguments -Gpu $Gpu) } else { @() }
  $a = @('-hide_banner', '-n') + $deviceArgs + @('-i', $Info.Path,
    '-map', '0:V', '-map', '0:a?', '-map', '0:s?', '-map', '0:t?',
    '-map_metadata', '0', '-map_chapters', '0',
    '-c', 'copy')
  $a += @(Get-VideoEncoderArguments -Codec $Codec -Crf $Crf -Preset $Preset -Gpu $Gpu `
      -AvailableEncoders $AvailableEncoders)
  $a += @('-c:s', $subCodec, $OutputPath)
  return $a
}

function Get-HandBrakeArguments {
  <#
    .SYNOPSIS
        Builds the equivalent HandBrakeCLI argument list (10-bit encoder, audio passthrough, all subtitles).
    .PARAMETER Info
        Object returned by Get-MediaInfo.
    .PARAMETER OutputPath
        Destination file.
    .PARAMETER Codec
        'x265' or 'av1'.
    .PARAMETER Crf
        Constant-quality value (HandBrake's -q).
    .PARAMETER Preset
        Encoder preset.
    .OUTPUTS
        [string[]]
    #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory)][pscustomobject]$Info,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$Codec,
    [Parameter(Mandatory)][int]$Crf,
    [Parameter(Mandatory)][string]$Preset
  )
  $enc = if ($Codec -eq 'x265') { 'x265_10bit' } else { 'svt_av1_10bit' }
  return @('-i', $Info.Path, '-o', $OutputPath, '-f', 'av_mkv', '-e', $enc, '-q', "$Crf", '--encoder-preset', $Preset,
    '--vfr', '--crop', '0:0:0:0', '--all-audio', '-E', 'copy', '--audio-fallback', 'opus', '--all-subtitles', '--markers')
}

function Write-NextSteps {
  <#
    .SYNOPSIS
        Prints the verdict, quality-tuning advice, and ready-to-run ffmpeg / HandBrakeCLI commands.
    .PARAMETER Info
        Object returned by Get-MediaInfo.
    .PARAMETER Triage
        Object returned by Get-TriageAssessment.
    .PARAMETER Sample
        Sample results or $null.
    .PARAMETER Projection
        Projection results or $null.
    .PARAMETER Verdict
        Object returned by Get-Verdict.
    .PARAMETER Codec
        'x265' or 'av1'.
    .PARAMETER Crf
        Constant-quality value used.
    .PARAMETER Preset
        Encoder preset used.
    .PARAMETER OutputPath
        Planned output path.
    .PARAMETER MinVmaf
        VMAF target used for tuning advice.
    .PARAMETER Gpu
        Selected GPU adapter, or $null to encode on the CPU.
    .PARAMETER AvailableEncoders
        Video encoders exposed by the selected FFmpeg build.
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][pscustomobject]$Info,
    [Parameter(Mandatory)][pscustomobject]$Triage,
    [AllowNull()][object]$Sample,
    [AllowNull()][object]$Projection,
    [Parameter(Mandatory)][pscustomobject]$Verdict,
    [Parameter(Mandatory)][string]$Codec,
    [Parameter(Mandatory)][int]$Crf,
    [Parameter(Mandatory)][string]$Preset,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][double]$MinVmaf,
    [AllowNull()][pscustomobject]$Gpu,
    [string[]]$AvailableEncoders = @()
  )
  Write-Host '[4] Next steps' -ForegroundColor Cyan

  if ($Verdict.Verdict -eq 'NOT WORTH IT') {
    Write-Host '    Recommendation: keep the original. If you still want to try:' -ForegroundColor Red
    if ($Projection) { Write-Host '    - Raise CRF by 2-3 (smaller, lower quality) or try -Codec av1.' }
    Write-Host '    - If audio is lossless, re-encoding only the audio may be the better win.'
  }
  else {
    if ($Sample -and $null -ne $Sample.VmafMean) {
      if ($Sample.VmafMean -lt $MinVmaf) { Write-Host ('    - Quality is under target: try CRF {0} (bigger file) and re-run the sample.' -f ($Crf - 2)) }
      elseif ($Sample.VmafMean -ge ($MinVmaf + 2.5)) { Write-Host ('    - VMAF has headroom: CRF {0} would likely be smaller and still look fine; re-run the sample to confirm.' -f ($Crf + 2)) }
    }
    Write-Host '    - Eyeball dark scenes, gradients and grain in mpv; use -KeepSamples to inspect the clips.'
  }

  $ff = Get-FfmpegReencodeArguments -Info $Info -OutputPath $OutputPath -Codec $Codec -Crf $Crf -Preset $Preset `
    -Gpu $Gpu -AvailableEncoders $AvailableEncoders
  Write-Host ''
  Write-Host '    ffmpeg:' -ForegroundColor Yellow
  Write-Host ('      ' + (Format-CommandLine -Executable 'ffmpeg' -Arguments $ff))
  if ($Triage.LosslessAudio) {
    $idx = [array]::IndexOf($ff, '-c:s')
    $ffAudio = @($ff[0..($idx - 1)]) + @('-c:a', 'libopus', '-b:a', '256k') + @($ff[$idx..($ff.Count - 1)])
    Write-Host ''
    Write-Host '    ffmpeg, also re-encoding the lossless audio to Opus (lossy; check 5.1/7.1 tracks play correctly):' -ForegroundColor Yellow
    Write-Host ('      ' + (Format-CommandLine -Executable 'ffmpeg' -Arguments $ffAudio))
  }
  Write-Host ''
  Write-Host '    HandBrakeCLI (or set the same values in the GUI):' -ForegroundColor Yellow
  if ($Gpu) { Write-Host '      Note: this HandBrakeCLI example uses its CPU encoder; use the ffmpeg command above for GPU encoding.' -ForegroundColor DarkGray }
  $hb = Get-HandBrakeArguments -Info $Info -OutputPath $OutputPath -Codec $Codec -Crf $Crf -Preset $Preset
  Write-Host ('      ' + (Format-CommandLine -Executable 'HandBrakeCLI' -Arguments $hb))
  if (-not $Script:HandBrakeExe) { Write-Host '      (HandBrakeCLI not found on this PC; download it from handbrake.fr, or use the GUI with the same settings.)' -ForegroundColor DarkGray }
  Write-Host '      Needs HandBrake 1.6+ for svt_av1_10bit. HandBrake auto-crops by default; --crop 0:0:0:0 disables that.' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '    Before deleting any original: confirm the output plays, durations match, and audio/subtitle tracks are all present.' -ForegroundColor DarkGray
  if (-not $Reencode) { Write-Host '    To let this script run the encode, add -Reencode.' -ForegroundColor DarkGray }
}

#endregion

#region Stage 5: optional re-encode

function Invoke-Reencode {
  <#
    .SYNOPSIS
        Runs the real ffmpeg re-encode with live progress; removes the partial file on failure.
    .PARAMETER Info
        Object returned by Get-MediaInfo.
    .PARAMETER OutputPath
        Destination file (must not exist; ffmpeg runs with -n).
    .PARAMETER Codec
        'x265' or 'av1'.
    .PARAMETER Crf
        Constant-quality value.
    .PARAMETER Preset
        Encoder preset.
    .PARAMETER Gpu
        Selected GPU adapter, or $null to encode on the CPU.
    .PARAMETER AvailableEncoders
        Video encoders exposed by the selected FFmpeg build.
    .OUTPUTS
        [pscustomobject] with Success, Path, Bytes, SavingsPercent, Seconds.
    #>
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory)][pscustomobject]$Info,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$Codec,
    [Parameter(Mandatory)][int]$Crf,
    [Parameter(Mandatory)][string]$Preset,
    [AllowNull()][pscustomobject]$Gpu,
    [string[]]$AvailableEncoders = @()
  )
  $ffArgs = @(Get-FfmpegReencodeArguments -Info $Info -OutputPath $OutputPath -Codec $Codec -Crf $Crf -Preset $Preset `
      -Gpu $Gpu -AvailableEncoders $AvailableEncoders)
  $ffArgs = @('-loglevel', 'warning', '-stats') + $ffArgs
  $backend = if ($Gpu) { "GPU '$($Gpu.Name)'" } else { 'CPU' }
  Write-Host "[5] Re-encoding to $OutputPath using $backend" -ForegroundColor Cyan
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $oldPreference = $ErrorActionPreference
  $oldCudaDeviceOrder = $env:CUDA_DEVICE_ORDER
  if ($Gpu -and $Gpu.VendorId -eq '10de') { $env:CUDA_DEVICE_ORDER = 'PCI_BUS_ID' }
  try {
    $ErrorActionPreference = 'Continue'
    & $Script:FfmpegExe @ffArgs
    $code = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldPreference
    if ($null -eq $oldCudaDeviceOrder) { Remove-Item Env:CUDA_DEVICE_ORDER -ErrorAction SilentlyContinue }
    else { $env:CUDA_DEVICE_ORDER = $oldCudaDeviceOrder }
  }
  $sw.Stop()
  Write-Host ''
  if ($code -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
    Write-Warning "ffmpeg exited with code $code."
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Success = $false; Path = $null; Bytes = 0L; SavingsPercent = 0.0; Seconds = $sw.Elapsed.TotalSeconds }
  }
  $bytes = (Get-Item -LiteralPath $OutputPath).Length
  $pct = 100.0 * ($Info.FileSize - $bytes) / [Math]::Max(1.0, [double]$Info.FileSize)
  Write-Host ('    Done in {0}: {1} -> {2} ({3:N1}% smaller). Original left untouched.' -f (Format-Duration $sw.Elapsed.TotalSeconds), (Format-FileSize $Info.FileSize), (Format-FileSize $bytes), $pct) -ForegroundColor Green
  return [pscustomobject]@{ Success = $true; Path = $OutputPath; Bytes = [long]$bytes; SavingsPercent = $pct; Seconds = $sw.Elapsed.TotalSeconds }
}

#endregion

#region Main

$Script:FfmpegExe = Resolve-Tool -Name 'ffmpeg' -ExplicitPath $FfmpegPath
$Script:FfprobeExe = Resolve-Tool -Name 'ffprobe' -ExplicitPath $FfprobePath
if (-not $Script:FfprobeExe -and $Script:FfmpegExe) {
  $sibling = Join-Path (Split-Path -Parent $Script:FfmpegExe) 'ffprobe.exe'
  if (Test-Path -LiteralPath $sibling) { $Script:FfprobeExe = $sibling }
}
$Script:HandBrakeExe = Resolve-Tool -Name 'HandBrakeCLI'
if (-not $Script:FfmpegExe -or -not $Script:FfprobeExe) {
  throw 'ffmpeg/ffprobe not found. Install the free build with:  winget install Gyan.FFmpeg   (then open a new terminal), or pass -FfmpegPath / -FfprobePath.'
}

$caps = Get-FfmpegCapabilities
if (-not $UseGpu -and $Codec -eq 'x265' -and -not $caps.Libx265) { throw 'This ffmpeg build lacks libx265. Install the Gyan "full" build.' }
if (-not $UseGpu -and $Codec -eq 'av1' -and -not $caps.SvtAv1) { throw 'This ffmpeg build lacks libsvtav1. Install the Gyan "full" build.' }
if (-not $SkipSample -and -not $SkipVmaf -and -not $caps.Libvmaf) {
  Write-Warning 'This ffmpeg build lacks libvmaf; quality verification will be skipped. The Gyan "full" build includes it.'
  $SkipVmaf = $true
}

if (-not $PSBoundParameters.ContainsKey('Crf')) { $Crf = $(if ($Codec -eq 'x265') { 20 } else { 27 }) }
if (-not $Preset) { $Preset = $(if ($Codec -eq 'x265') { 'slow' } else { '5' }) }
if ($Codec -eq 'x265' -and $Script:X265Presets -notcontains $Preset) { throw "Invalid x265 preset '$Preset'. Use one of: $($Script:X265Presets -join ', ')" }
if ($Codec -eq 'av1' -and -not ($Preset -match '^\d+$' -and [int]$Preset -le 13)) { throw "Invalid SVT-AV1 preset '$Preset'. Use 0-13." }

$cpuName = Get-ProcessorName
$selectedGpu = $null
$gpuEncoderName = $null
if ($UseGpu) {
  $selectedGpu = Get-SelectedGpu -Name $Gpu
  $Script:SelectedGpu = $selectedGpu
  $gpuEncoderArgs = @(Get-GpuVideoEncoderArguments -Gpu $selectedGpu -Codec $Codec -Crf $Crf `
      -Preset $Preset -AvailableEncoders $caps.VideoEncoders)
  $gpuEncoderName = $gpuEncoderArgs[1]
  $null = Get-GpuDeviceArguments -Gpu $selectedGpu
}

if ($OutputDir -and -not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$tempRoot = if ($TempDir) { $TempDir } else { [System.IO.Path]::GetTempPath() }
if (-not (Test-Path -LiteralPath $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }

$files = @(Get-VideoFiles -Paths $Path -Recurse:$Recurse)
if ($files.Count -eq 0) { throw 'No video files found.' }
Write-Host ('Analyzing {0} file(s): {1} CRF {2} preset {3}{4}' -f $files.Count, $Codec, $Crf, $Preset, $(if ($SkipSample) { ' (triage only)' } else { '' })) -ForegroundColor White
Write-Host "CPU: $cpuName" -ForegroundColor DarkGray
if ($selectedGpu) {
  Write-Host ('Encoding backend: GPU - {0} ({1}); VMAF and non-encoding analysis use the CPU.' -f $selectedGpu.Name, $gpuEncoderName) -ForegroundColor Cyan
}
else {
  Write-Host "Encoding backend: CPU - $cpuName" -ForegroundColor Cyan
}

$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($file in $files) {
  $i++
  Write-Host ''
  Write-Host ('=== [{0}/{1}] {2}' -f $i, $files.Count, $file.FullName) -ForegroundColor White
  try {
    $info = Get-MediaInfo -LiteralPath $file.FullName
    $triage = Get-TriageAssessment -Info $info -Codec $Codec
    Write-TriageReport -Info $info -Triage $triage

    $sample = $null; $projection = $null
    if (-not $SkipSample) {
      $work = Join-Path $tempRoot ('reencode-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
      New-Item -ItemType Directory -Path $work -Force | Out-Null
      try {
        $sample = Invoke-SampleAnalysis -Info $info -Codec $Codec -Crf $Crf -Preset $Preset -WorkDir $work `
          -SampleCount $SampleCount -SampleSeconds $SampleSeconds -Gpu $selectedGpu `
          -AvailableEncoders $caps.VideoEncoders -IncludeVmaf (-not $SkipVmaf)
        $projection = Get-Projection -Info $info -Sample $sample
      }
      finally {
        if ($KeepSamples) { Write-Host "    Samples kept in: $work" -ForegroundColor DarkGray }
        else { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
      }
      Write-Host '[3] Projection and quality' -ForegroundColor Cyan
      Write-Host ('    Sample size ratio : {0:P0} of source video' -f $sample.SizeRatio)
      Write-Host ('    Projected file    : {0} -> {1}  ({2:N0}% smaller, saves {3})' -f (Format-FileSize $info.FileSize), (Format-FileSize $projection.ProjectedBytes), $projection.SavingsPercent, (Format-FileSize $projection.SavedBytes))
      Write-Host ('    Encode speed      : {0:N2}x realtime -> about {1} for the full file' -f $sample.Speed, (Format-Duration $projection.EstimatedEncodeSeconds))
      if ($null -ne $sample.VmafMean) {
        Write-Host ('    VMAF              : mean {0:N2}, 1st percentile {1:N1}, min {2:N1}' -f $sample.VmafMean, $sample.VmafP1, $sample.VmafMin)
      }
    }

    $verdict = Get-Verdict -Triage $triage -Sample $sample -Projection $projection `
      -MinSavingsPercent $MinSavingsPercent -MinVmaf $MinVmaf -MinSavedMB $MinSavedMB
    $vColor = switch ($verdict.Verdict) { 'WORTH IT' { 'Green' } 'MARGINAL' { 'Yellow' } default { 'Red' } }
    Write-Host '    Verdict           : ' -NoNewline
    Write-Host ('{0} ({1})' -f $verdict.Verdict, $verdict.Basis) -ForegroundColor $vColor
    foreach ($r in $verdict.Reasons) { Write-Host "      $r" -ForegroundColor DarkGray }

    $outPath = Get-OutputPath -SourcePath $info.Path -Codec $Codec -OutputDir $OutputDir
    Write-NextSteps -Info $info -Triage $triage -Sample $sample -Projection $projection -Verdict $verdict `
      -Codec $Codec -Crf $Crf -Preset $Preset -OutputPath $outPath -MinVmaf $MinVmaf `
      -Gpu $selectedGpu -AvailableEncoders $caps.VideoEncoders

    $enc = $null
    if ($Reencode) {
      if ($verdict.Verdict -eq 'NOT WORTH IT' -and -not $Force) {
        Write-Host '    Skipping re-encode (NOT WORTH IT). Use -Force to override.' -ForegroundColor Yellow
      }
      elseif (Test-Path -LiteralPath $outPath) {
        Write-Warning "Output already exists, skipping: $outPath"
      }
      elseif ($PSCmdlet.ShouldProcess($info.Path, "Re-encode to '$outPath' ($Codec, CRF $Crf, preset $Preset)")) {
        $enc = Invoke-Reencode -Info $info -OutputPath $outPath -Codec $Codec -Crf $Crf -Preset $Preset `
          -Gpu $selectedGpu -AvailableEncoders $caps.VideoEncoders
      }
    }

    $results.Add([pscustomobject]@{
        Path                = $info.Path
        SizeBytes           = $info.FileSize
        Codec               = $info.Codec
        Resolution          = ('{0}x{1}' -f $info.Width, $info.Height)
        DurationSeconds     = [Math]::Round($info.Duration, 1)
        VideoKbps           = [Math]::Round($info.VideoBitrate / 1000)
        BitsPerPixel        = [Math]::Round($triage.Bpp, 3)
        Potential           = $triage.Potential
        ProjectedSavingsPct = $(if ($projection) { [Math]::Round($projection.SavingsPercent, 1) } else { $null })
        ProjectedSavedMB    = $(if ($projection) { [Math]::Round($projection.SavedBytes / 1MB) } else { $null })
        EstEncodeMinutes    = $(if ($projection) { [Math]::Round($projection.EstimatedEncodeSeconds / 60, 1) } else { $null })
        VmafMean            = $(if ($sample -and $null -ne $sample.VmafMean) { [Math]::Round($sample.VmafMean, 2) } else { $null })
        VmafP1              = $(if ($sample -and $null -ne $sample.VmafP1) { [Math]::Round($sample.VmafP1, 1) } else { $null })
        Verdict             = $verdict.Verdict
        Basis               = $verdict.Basis
        Reasons             = ($verdict.Reasons -join ' | ')
        Reencoded           = [bool]($enc -and $enc.Success)
        OutputPath          = $(if ($enc -and $enc.Success) { $enc.Path } else { $null })
        ActualSavingsPct    = $(if ($enc -and $enc.Success) { [Math]::Round($enc.SavingsPercent, 1) } else { $null })
      })
  }
  catch {
    Write-Warning "Failed on '$($file.FullName)': $($_.Exception.Message)"
  }
}

if ($results.Count -gt 0) {
  Write-Host ''
  Write-Host '=== Summary' -ForegroundColor White
  $results | Select-Object @{n = 'File'; e = { Split-Path -Leaf $_.Path } }, Codec, Resolution, Potential, ProjectedSavingsPct, ProjectedSavedMB, EstEncodeMinutes, VmafMean, Verdict, Reencoded |
    Format-Table -AutoSize | Out-Host
  if ($ReportPath) {
    $results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
    Write-Host "Report written to $ReportPath" -ForegroundColor DarkGray
  }
}
if ($PassThru) { $results }

#endregion
