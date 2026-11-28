#Requires -Version 7.0
<#
.SYNOPSIS
    Compares CPU and hardware H.264 encoding and video decoding on short samples.

.DESCRIPTION
    Checks the selected FFmpeg build for hardware video encoders and decode
    accelerators, then benchmarks CPU libx264 against detected H.264 hardware
    encoders. Encodes use the same target bitrate so the quality comparison is
    meaningful; VMAF is used when available, otherwise SSIM. Decoding is timed
    separately with and without each advertised hardware accelerator.

    Hardware encoders that require hardware frames are tested with a device and
    upload filter. OpenCL is reported as an FFmpeg hardware API but excluded
    from decoder tests. Unavailable device paths are skipped with a concise
    reason; use -Verbose to see full FFmpeg diagnostics.

    On Windows, the script prefers the adapter reporting the most dedicated
    video memory and pins compatible NVIDIA, AMD, Intel, and Direct3D tests to
    that vendor. Hardware tests that cannot be pinned unambiguously are skipped
    rather than silently using another adapter.

    The verdict is based on measured sample results, not a guarantee of
    full-file performance. Hardware encoder quality modes and power use vary by
    device, so test the chosen settings on your own content before batch use.
    Requires PowerShell 7.0 or later.

.PARAMETER Path
    Input video file.

.PARAMETER SampleCount
    Number of short samples distributed across the input (1-3, default 2).

.PARAMETER SampleSeconds
    Duration of each sample in seconds (default 8).

.PARAMETER TargetBitrateKbps
    Bitrate used for every encoder. By default, inferred from the source video.

.PARAMETER MinimumSpeedup
    Minimum GPU/CPU encoding speed ratio to count as a worthwhile speed gain.

.PARAMETER MinimumSizeSavingsPercent
    Minimum output size savings that can count as a worthwhile storage gain.

.PARAMETER MaximumSizeGrowthPercent
    Maximum output size increase allowed for an otherwise worthwhile result.

.PARAMETER MaximumVmafLoss
    Maximum VMAF point loss versus CPU encoding considered acceptable.

.PARAMETER MaximumSsimLoss
    Maximum SSIM loss versus CPU encoding considered acceptable.

.PARAMETER FfmpegPath
    Optional path to ffmpeg.exe.

.PARAMETER FfprobePath
    Optional path to ffprobe.exe.

.PARAMETER TempDir
    Optional directory for temporary sample and encoded files.

.PARAMETER KeepSamples
    Keep the temporary files after the benchmark.

.EXAMPLE
    .\Test-HardwareReencodeWorth.ps1 'D:\Movies\Film.mkv'
    Compare CPU and available H.264 hardware encoders, and decode accelerators.

.EXAMPLE
    .\Test-HardwareReencodeWorth.ps1 'D:\Movies\Film.mkv' -SampleCount 3 -SampleSeconds 10 -TargetBitrateKbps 5000
    Use three 10-second samples and a fixed 5,000 kbit/s bitrate for all encoders.

.EXAMPLE
    .\Test-HardwareReencodeWorth.ps1 'D:\Movies\Film.mkv'
    On Windows, prefer the adapter with the most dedicated memory and skip any
    hardware backend that cannot be pinned to that adapter.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
  [string]$Path,

  [ValidateRange(1, 3)]
  [int]$SampleCount = 2,

  [ValidateRange(4, 30)]
  [int]$SampleSeconds = 8,

  [ValidateRange(0, 100000)]
  [int]$TargetBitrateKbps = 0,

  [ValidateRange(1.0, 10.0)]
  [double]$MinimumSpeedup = 1.15,

  [ValidateRange(0, 50)]
  [double]$MinimumSizeSavingsPercent = 2,

  [ValidateRange(0, 100)]
  [double]$MaximumSizeGrowthPercent = 5,

  [ValidateRange(0, 20)]
  [double]$MaximumVmafLoss = 1,

  [ValidateRange(0, 0.2)]
  [double]$MaximumSsimLoss = 0.01,

  [string]$FfmpegPath,
  [string]$FfprobePath,
  [string]$TempDir,
  [switch]$KeepSamples
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

function Resolve-Executable {
  param(
    [Parameter(Mandatory)][string]$Name,
    [string]$ExplicitPath
  )

  if ($ExplicitPath) {
    if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
      throw "The specified $Name path does not exist: $ExplicitPath"
    }
    return (Resolve-Path -LiteralPath $ExplicitPath).Path
  }

  $command = Get-Command ($Name + '.exe') -ErrorAction SilentlyContinue
  if ($command -and $command.Source) { return $command.Source }

  if ($Name -eq 'ffprobe') { return $null }
  $finder = Join-Path $PSScriptRoot 'ffmpeg-find.ps1'
  if (Test-Path -LiteralPath $finder -PathType Leaf) {
    $found = @(& $finder -Executable $Name -ErrorAction SilentlyContinue 2>$null |
        Where-Object { $_ -is [string] -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($found.Count -gt 0) { return [string]$found[0] }
  }
  return $null
}

function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  $oldPreference = $ErrorActionPreference
  $oldCudaDeviceOrder = $env:CUDA_DEVICE_ORDER
  if ($Script:PreferredGpu -and $Script:PreferredGpu.VendorId -eq '10de' -and
      $null -ne $Script:PreferredGpu.NvidiaIndex) {
    $env:CUDA_DEVICE_ORDER = 'PCI_BUS_ID'
  }
  $ErrorActionPreference = 'Continue'
  try {
    $lines = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldPreference
    if ($null -eq $oldCudaDeviceOrder) {
      Remove-Item Env:CUDA_DEVICE_ORDER -ErrorAction SilentlyContinue
    }
    else {
      $env:CUDA_DEVICE_ORDER = $oldCudaDeviceOrder
    }
  }
  [pscustomobject]@{ ExitCode = $exitCode; Output = ($lines -join "`n") }
}

function Get-SamplePlan {
  param(
    [Parameter(Mandatory)][double]$Duration,
    [Parameter(Mandatory)][int]$Count,
    [Parameter(Mandatory)][double]$Seconds
  )

  $length = [Math]::Min($Seconds, $Duration)
  $count = [Math]::Min($Count, [Math]::Max(1, [int][Math]::Floor($Duration / $length)))
  for ($i = 0; $i -lt $count; $i++) {
    $center = $Duration * ($i + 0.5) / $count
    $start = [Math]::Max(0.0, [Math]::Min($center - ($length / 2), $Duration - $length))
    [pscustomobject]@{ Start = $start; Length = $length }
  }
}

function Get-QualityScore {
  param(
    [Parameter(Mandatory)][string]$EncodedPath,
    [Parameter(Mandatory)][string]$ReferencePath,
    [Parameter(Mandatory)][string]$Metric,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$Index
  )

  if ($Metric -eq 'VMAF') {
    $logName = "vmaf_$Index.json"
    $logPath = Join-Path $WorkDir $logName
    Push-Location -LiteralPath $WorkDir
    try {
      $run = Invoke-Native -FilePath $Script:FfmpegExe -Arguments @(
        '-hide_banner', '-v', 'error', '-nostdin', '-i', $EncodedPath, '-i', $ReferencePath,
        '-lavfi', "libvmaf=log_fmt=json:log_path=$logName", '-f', 'null', '-'
      )
    }
    finally { Pop-Location }
    if ($run.ExitCode -eq 0 -and (Test-Path -LiteralPath $logPath)) {
      $json = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $scores = @($json.frames | ForEach-Object { [double]$_.metrics.vmaf })
      if ($scores.Count -gt 0) {
        return ($scores | Measure-Object -Average).Average
      }
    }
    return $null
  }

  $run = Invoke-Native -FilePath $Script:FfmpegExe -Arguments @(
    '-hide_banner', '-v', 'info', '-nostdin', '-i', $EncodedPath, '-i', $ReferencePath,
    '-lavfi', 'ssim', '-f', 'null', '-'
  )
  if ($run.ExitCode -ne 0) { return $null }
  $match = [regex]::Match($run.Output, 'All:([0-9]+(?:\.[0-9]+)?)')
  if ($match.Success) { return [double]::Parse($match.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture) }
  return $null
}

function Get-PreferredGpu {
  if ($env:OS -ne 'Windows_NT') { return $null }

  try {
    $controllers = [System.Collections.Generic.List[object]]::new()
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
    throw "Could not enumerate Windows display adapters needed for safe GPU selection: $($_.Exception.Message)"
  }

  if ($controllers.Count -eq 0) {
    throw 'Windows did not report a PCI display adapter; refusing to run hardware tests with an unverified default GPU.'
  }

  $maximumRam = ($controllers | Measure-Object -Property AdapterRam -Maximum).Maximum
  $topControllers = @($controllers | Where-Object { $_.AdapterRam -eq $maximumRam })
  if ($topControllers.Count -ne 1) {
    throw 'Windows reported multiple top-ranked GPUs with equal dedicated memory; cannot choose a preferred adapter safely.'
  }

  $gpu = $topControllers[0]
  $vendorCount = @($controllers | Where-Object { $_.VendorId -eq $gpu.VendorId }).Count
  if ($gpu.VendorId -notin @('10de', '1002', '8086')) {
    throw "The preferred GPU '$($gpu.Name)' has unsupported vendor ID 0x$($gpu.VendorId); refusing to use an unselected adapter."
  }

  $nvidiaIndex = $null
  if ($gpu.VendorId -eq '10de') {
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
                Index       = [int]$Matches[1]
                Name        = $Matches[2]
                MemoryMiB   = [uint64]$Matches[3]
              }
            }
          }
        )
        if ($nvidiaGpus.Count -gt 0) {
          $nvidiaIndex = ($nvidiaGpus | Sort-Object MemoryMiB -Descending | Select-Object -First 1).Index
        }
      }
    }
    if (Test-Path Env:CUDA_VISIBLE_DEVICES) {
      Write-Warning 'CUDA_VISIBLE_DEVICES is set; cannot safely map the selected NVIDIA adapter to FFmpeg CUDA/NVENC device indices.'
      $nvidiaIndex = $null
    }
    if ($null -eq $nvidiaIndex -and $vendorCount -eq 1 -and -not (Test-Path Env:CUDA_VISIBLE_DEVICES)) {
      $nvidiaIndex = 0
    }
  }

  [pscustomobject]@{
    Name           = $gpu.Name
    VendorId       = $gpu.VendorId
    AdapterRam     = $gpu.AdapterRam
    VendorCount    = $vendorCount
    NvidiaIndex    = $nvidiaIndex
  }
}

function Get-EncoderSetup {
  param([Parameter(Mandatory)][string]$Encoder)

  $encoderVendorId = switch -Regex ($Encoder) {
    '(?i)_nvenc$' { '10de'; break }
    '(?i)_amf$' { '1002'; break }
    '(?i)_qsv$' { '8086'; break }
    default { $null }
  }
  if ($Script:PreferredGpu -and $encoderVendorId -and
      $encoderVendorId -ne $Script:PreferredGpu.VendorId) {
    return [pscustomobject]@{
      SkipReason = "Windows prefers '$($Script:PreferredGpu.Name)'; $Encoder targets a different GPU vendor."
    }
  }
  if ($Script:PreferredGpu -and $Encoder -ne 'libx264' -and -not $encoderVendorId) {
    return [pscustomobject]@{
      SkipReason = "FFmpeg does not expose a reliable selector for the preferred GPU '$($Script:PreferredGpu.Name)' with $Encoder."
    }
  }
  if ($Script:PreferredGpu -and $encoderVendorId -and
      $Script:PreferredGpu.VendorId -eq $encoderVendorId -and
      $Script:PreferredGpu.VendorCount -gt 1 -and $encoderVendorId -ne '10de') {
    return [pscustomobject]@{
      SkipReason = "Multiple GPUs from this vendor are present, and FFmpeg cannot unambiguously select '$($Script:PreferredGpu.Name)' for $Encoder."
    }
  }

  switch -Regex ($Encoder) {
    '_(d3d12va|vaapi|vulkan)$' {
      $deviceType = $Matches[1]
      if ($deviceType -eq 'vaapi' -and $env:OS -eq 'Windows_NT') {
        return [pscustomobject]@{
          SkipReason = 'VAAPI requires a Linux DRM render device and is not available in native Windows.'
        }
      }

      $deviceName = 'bench'
      return [pscustomobject]@{
        DeviceArgs  = @('-init_hw_device', "$deviceType=$deviceName", '-filter_hw_device', $deviceName)
        VideoFilter = 'format=nv12,hwupload'
        PixelFormat = $null
        EncoderArgs = @()
        SkipReason  = $null
      }
    }
    '_qsv$' {
      $deviceName = 'bench'
      $deviceArgs = if ($env:OS -eq 'Windows_NT' -and $Script:PreferredGpu -and
          $Script:PreferredGpu.VendorId -eq '8086') {
        @(
          '-init_hw_device', "d3d11va=preferred:,vendor_id=0x$($Script:PreferredGpu.VendorId)",
          '-init_hw_device', "qsv=$deviceName@preferred", '-filter_hw_device', $deviceName
        )
      }
      else {
        @('-init_hw_device', "qsv=$deviceName", '-filter_hw_device', $deviceName)
      }
      return [pscustomobject]@{
        DeviceArgs  = $deviceArgs
        VideoFilter = 'format=nv12,hwupload=extra_hw_frames=64'
        PixelFormat = $null
        EncoderArgs = @()
        SkipReason  = $null
      }
    }
    '(?i)_amf$' {
      $deviceName = 'bench'
      $deviceArgs = if ($env:OS -eq 'Windows_NT' -and $Script:PreferredGpu -and
          $Script:PreferredGpu.VendorId -eq '1002') {
        @(
          '-init_hw_device', "d3d11va=preferred:,vendor_id=0x$($Script:PreferredGpu.VendorId)",
          '-init_hw_device', "amf=$deviceName@preferred", '-filter_hw_device', $deviceName
        )
      }
      else { @() }
      $videoFilter = if ($deviceArgs.Count -gt 0) { 'format=nv12,hwupload' } else { $null }
      return [pscustomobject]@{
        DeviceArgs  = $deviceArgs
        VideoFilter = $videoFilter
        PixelFormat = $(if ($videoFilter) { $null } else { 'yuv420p' })
        EncoderArgs = @()
        SkipReason  = $null
      }
    }
    '(?i)_nvenc$' {
      if ($Script:PreferredGpu -and $null -eq $Script:PreferredGpu.NvidiaIndex) {
        return [pscustomobject]@{
          SkipReason = "Could not determine the NVIDIA adapter index for '$($Script:PreferredGpu.Name)'."
        }
      }
      return [pscustomobject]@{
        DeviceArgs  = @()
        VideoFilter = $null
        PixelFormat = 'yuv420p'
        EncoderArgs = $(if ($Script:PreferredGpu) { @('-gpu', [string]$Script:PreferredGpu.NvidiaIndex) } else { @() })
        SkipReason  = $null
      }
    }
    default {
      return [pscustomobject]@{
        DeviceArgs  = @()
        VideoFilter = $null
        PixelFormat = 'yuv420p'
        EncoderArgs = @()
        SkipReason  = $null
      }
    }
  }
}

function Get-FailureSummary {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)

  $relevant = @(
    $Output -split '\r?\n' |
      Where-Object { $_ -match '(?i)(error|failed|failure|unable|no device|not supported|unsupported|impossible|not implemented|could not|cannot)' } |
        Select-Object -Last 4
  )
  if ($relevant.Count -eq 0) {
    $relevant = @($Output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 3)
  }
  return ($relevant -join ' | ')
}

function Measure-Encoder {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Encoder,
    [Parameter(Mandatory)][string[]]$Samples,
    [Parameter(Mandatory)][int]$BitrateKbps,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$Metric
  )

  $totalBytes = 0L
  $totalSeconds = 0.0
  $qualityScores = [System.Collections.Generic.List[double]]::new()
  $sampleDuration = 0.0
  $setup = Get-EncoderSetup -Encoder $Encoder
  if ($setup.SkipReason) {
    Write-Warning "Skipping ${Encoder}: $($setup.SkipReason)"
    return $null
  }

  for ($i = 0; $i -lt $Samples.Count; $i++) {
    $outputPath = Join-Path $WorkDir ('{0}_{1}.mkv' -f $Name, $i)
    $rate = "$($BitrateKbps)k"
    $encodeArgs = @('-hide_banner', '-v', 'error', '-nostdin', '-y') + $setup.DeviceArgs +
    @('-i', $Samples[$i], '-map', '0:v:0', '-an', '-sn', '-dn')
    if ($setup.VideoFilter) { $encodeArgs += @('-vf', $setup.VideoFilter) }
    $encodeArgs += @(
      '-c:v', $Encoder, '-b:v', $rate, '-maxrate', $rate, '-bufsize', "$($BitrateKbps * 2)k"
    )
    if ($setup.EncoderArgs) { $encodeArgs += $setup.EncoderArgs }
    if ($setup.PixelFormat) { $encodeArgs += @('-pix_fmt', $setup.PixelFormat) }
    $encodeArgs += $outputPath
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-Native -FilePath $Script:FfmpegExe -Arguments $encodeArgs
    $timer.Stop()

    if ($run.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
      Write-Verbose "$Name encoder full error: $($run.Output.Trim())"
      Write-Warning "$Name encoder '$Encoder' unavailable for this run: $(Get-FailureSummary -Output $run.Output)"
      return $null
    }

    $totalSeconds += $timer.Elapsed.TotalSeconds
    $totalBytes += (Get-Item -LiteralPath $outputPath).Length
    $durationRun = Invoke-Native -FilePath $Script:FfprobeExe -Arguments @(
      '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', $Samples[$i]
    )
    $durationValue = 0.0
    if ([double]::TryParse($durationRun.Output.Trim(), [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$durationValue)) {
      $sampleDuration += $durationValue
    }

    $quality = Get-QualityScore -EncodedPath $outputPath -ReferencePath $Samples[$i] `
      -Metric $Metric -WorkDir $WorkDir -Index ('{0}_{1}' -f $Name, $i)
    if ($null -ne $quality) { $qualityScores.Add([double]$quality) }
  }

  [pscustomobject]@{
    Name          = $Name
    Encoder       = $Encoder
    Bytes         = $totalBytes
    Seconds       = $totalSeconds
    Speed         = $sampleDuration / [Math]::Max(0.001, $totalSeconds)
    Quality       = $(if ($qualityScores.Count -gt 0) { ($qualityScores | Measure-Object -Average).Average } else { $null })
    QualityMetric = $Metric
  }
}

function Measure-DecodeSpeed {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][int]$VideoIndex,
    [Parameter(Mandatory)][pscustomobject[]]$Plan,
    [string]$HardwareAcceleration
  )

  if ($HardwareAcceleration -eq 'vaapi' -and $env:OS -eq 'Windows_NT') {
    Write-Warning 'Skipping VAAPI decode: VAAPI requires a Linux DRM render device and is not available in native Windows.'
    return $null
  }

  $decodeDeviceArgs = @()
  $hardwareAccelerationArgs = @()
  if ($HardwareAcceleration -and $env:OS -eq 'Windows_NT' -and $Script:PreferredGpu) {
    $vendorId = $Script:PreferredGpu.VendorId
    switch ($HardwareAcceleration) {
      'cuda' {
        if ($vendorId -ne '10de' -or $null -eq $Script:PreferredGpu.NvidiaIndex) {
          Write-Warning "Skipping CUDA decode: it cannot be pinned to the preferred GPU '$($Script:PreferredGpu.Name)'."
          return $null
        }
        $hardwareAccelerationArgs = @('-hwaccel', 'cuda', '-hwaccel_device', [string]$Script:PreferredGpu.NvidiaIndex)
      }
      'd3d11va' {
        if ($Script:PreferredGpu.VendorCount -gt 1) {
          Write-Warning "Skipping D3D11VA decode: multiple GPUs share vendor 0x$vendorId, so '$($Script:PreferredGpu.Name)' cannot be selected unambiguously."
          return $null
        }
        $decodeDeviceArgs = @('-init_hw_device', "d3d11va=preferred:,vendor_id=0x$vendorId")
        $hardwareAccelerationArgs = @('-hwaccel', 'd3d11va', '-hwaccel_device', 'preferred')
      }
      'amf' {
        if ($vendorId -ne '1002' -or $Script:PreferredGpu.VendorCount -gt 1) {
          Write-Warning "Skipping AMF decode: it cannot be pinned unambiguously to the preferred GPU '$($Script:PreferredGpu.Name)'."
          return $null
        }
        $decodeDeviceArgs = @(
          '-init_hw_device', "d3d11va=preferred:,vendor_id=0x$vendorId",
          '-init_hw_device', 'amf=decode@preferred'
        )
        $hardwareAccelerationArgs = @('-hwaccel', 'amf', '-hwaccel_device', 'decode')
      }
      'qsv' {
        if ($vendorId -ne '8086' -or $Script:PreferredGpu.VendorCount -gt 1) {
          Write-Warning "Skipping QSV decode: it cannot be pinned unambiguously to the preferred GPU '$($Script:PreferredGpu.Name)'."
          return $null
        }
        $decodeDeviceArgs = @(
          '-init_hw_device', "d3d11va=preferred:,vendor_id=0x$vendorId",
          '-init_hw_device', 'qsv=decode@preferred'
        )
        $hardwareAccelerationArgs = @('-hwaccel', 'qsv', '-hwaccel_device', 'decode')
      }
      default {
        Write-Warning "Skipping $HardwareAcceleration decode: this script cannot reliably pin that backend to the preferred GPU '$($Script:PreferredGpu.Name)'."
        return $null
      }
    }
  }

  $duration = 0.0
  $seconds = 0.0
  foreach ($clip in $Plan) {
    $startText = $clip.Start.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
    $lengthText = $clip.Length.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
    $decodeArgs = @('-hide_banner', '-v', 'error', '-nostdin') + $decodeDeviceArgs + $hardwareAccelerationArgs
    if ($HardwareAcceleration -and -not $hardwareAccelerationArgs) {
      $decodeArgs += @('-hwaccel', $HardwareAcceleration)
    }
    $decodeArgs += @(
      '-ss', $startText, '-t', $lengthText, '-i', $InputPath,
      '-map', ('0:{0}' -f $VideoIndex), '-an', '-f', 'null', '-'
    )
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-Native -FilePath $Script:FfmpegExe -Arguments $decodeArgs
    $timer.Stop()
    if ($run.ExitCode -ne 0) {
      Write-Verbose "$Label decoder full error: $($run.Output.Trim())"
      Write-Warning "$Label decode unavailable for this run: $(Get-FailureSummary -Output $run.Output)"
      return $null
    }
    $seconds += $timer.Elapsed.TotalSeconds
    $duration += $clip.Length
  }

  [pscustomobject]@{
    Accelerator = $(if ($HardwareAcceleration) { $HardwareAcceleration } else { 'CPU' })
    Seconds     = $seconds
    Speed       = $duration / [Math]::Max(0.001, $seconds)
  }
}

$Script:FfmpegExe = Resolve-Executable -Name 'ffmpeg' -ExplicitPath $FfmpegPath
if (-not $Script:FfmpegExe) { throw 'ffmpeg.exe was not found. Put it on PATH or specify -FfmpegPath.' }
$Script:FfprobeExe = Resolve-Executable -Name 'ffprobe' -ExplicitPath $FfprobePath
if (-not $Script:FfprobeExe) {
  $siblingProbe = Join-Path (Split-Path -Parent $Script:FfmpegExe) 'ffprobe.exe'
  if (Test-Path -LiteralPath $siblingProbe -PathType Leaf) { $Script:FfprobeExe = $siblingProbe }
}
if (-not $Script:FfprobeExe) { throw 'ffprobe.exe was not found. Put it on PATH or specify -FfprobePath.' }
$Script:PreferredGpu = Get-PreferredGpu
if ($Script:PreferredGpu) {
  $reportedMemoryGiB = $Script:PreferredGpu.AdapterRam / 1GB
  Write-Host ('Preferred Windows GPU: {0} (vendor 0x{1}, {2:N2} GiB reported dedicated memory).' -f
    $Script:PreferredGpu.Name, $Script:PreferredGpu.VendorId, $reportedMemoryGiB)
}

$inputPath = (Resolve-Path -LiteralPath $Path).Path
$probe = Invoke-Native -FilePath $Script:FfprobeExe -Arguments @(
  '-v', 'error', '-print_format', 'json',
  '-show_entries', 'format=duration:stream=index,codec_type,codec_name,bit_rate:stream_disposition=attached_pic',
  $inputPath
)
if ($probe.ExitCode -ne 0) { throw "ffprobe could not read '$inputPath': $($probe.Output)" }
$media = $probe.Output | ConvertFrom-Json
$videoStream = @(
  $media.streams |
    Where-Object { $_.codec_type -eq 'video' -and -not ($_.disposition -and $_.disposition.attached_pic -eq 1) } |
      Select-Object -First 1
)
if ($videoStream.Count -eq 0) { throw "No video stream found in '$inputPath'." }
$duration = 0.0
if (-not [double]::TryParse([string]$media.format.duration, [System.Globalization.NumberStyles]::Float,
    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration) -or $duration -le 0) {
  throw 'Could not determine a positive input duration.'
}

if ($TargetBitrateKbps -le 0) {
  $sourceBitrate = 0.0
  [void][double]::TryParse([string]$videoStream[0].bit_rate, [System.Globalization.NumberStyles]::Float,
    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$sourceBitrate)
  if ($sourceBitrate -le 0) {
    $sourceBitrate = ((Get-Item -LiteralPath $inputPath).Length * 8.0) / $duration
    Write-Warning 'Video bitrate was unavailable; using total file bitrate as the target estimate.'
  }
  $TargetBitrateKbps = [int][Math]::Max(500, [Math]::Min(50000, [Math]::Round($sourceBitrate / 1000)))
}

$encoderRun = Invoke-Native -FilePath $Script:FfmpegExe -Arguments @('-hide_banner', '-encoders')
if ($encoderRun.ExitCode -ne 0) { throw "Could not query FFmpeg encoders: $($encoderRun.Output)" }
$allHardwareEncoders = @(
  [regex]::Matches($encoderRun.Output, '^\s*V\S*\s+(\S+)', [System.Text.RegularExpressions.RegexOptions]::Multiline) |
    ForEach-Object { $_.Groups[1].Value } |
      Where-Object { $_ -match '(?i)(nvenc|qsv|amf|vaapi|videotoolbox|v4l2m2m|mediacodec|omx|vulkan|d3d12va|_mf$)' } |
        Sort-Object -Unique
)
$h264HardwareEncoders = @($allHardwareEncoders | Where-Object { $_ -match '^h264_' })
if ($allHardwareEncoders.Count -gt 0) {
  Write-Host ('Hardware video encoders in this FFmpeg build: {0}' -f ($allHardwareEncoders -join ', '))
}
else {
  Write-Host 'No known hardware video encoders were listed by this FFmpeg build.'
}

$accelRun = Invoke-Native -FilePath $Script:FfmpegExe -Arguments @('-hide_banner', '-hwaccels')
if ($accelRun.ExitCode -ne 0) { throw "Could not query FFmpeg hardware accelerators: $($accelRun.Output)" }
$hardwareAccels = @(
  [regex]::Matches($accelRun.Output, '^\s*([a-z0-9_]+)\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline) |
    ForEach-Object { $_.Groups[1].Value } |
      Sort-Object -Unique
)
$decodeAccels = @(
  $hardwareAccels |
    Where-Object { $_ -ne 'opencl' -and -not ($_ -eq 'vaapi' -and $env:OS -eq 'Windows_NT') }
)
if ($Script:PreferredGpu) {
  $preferredAccels = switch ($Script:PreferredGpu.VendorId) {
    '10de' { @('cuda', 'd3d11va') }
    '1002' { @('amf', 'd3d11va') }
    '8086' { @('qsv', 'd3d11va') }
  }
  $decodeAccels = @($decodeAccels | Where-Object { $_ -in $preferredAccels })
}
Write-Host ('Hardware acceleration APIs listed by FFmpeg: {0}' -f $(if ($hardwareAccels.Count) { $hardwareAccels -join ', ' } else { 'none' }))
Write-Host ('Decode backends to test: {0}' -f $(if ($decodeAccels.Count) { $decodeAccels -join ', ' } else { 'none' }))
if ($hardwareAccels -contains 'opencl') {
  Write-Host 'OpenCL is a compute/filter API, not a video decoder; skipping it in decode tests.' -ForegroundColor DarkGray
}
if ($hardwareAccels -contains 'vaapi' -and $env:OS -eq 'Windows_NT') {
  Write-Host 'VAAPI needs a Linux DRM render device; skipping it in native Windows decode tests.' -ForegroundColor DarkGray
}

$filterRun = Invoke-Native -FilePath $Script:FfmpegExe -Arguments @('-hide_banner', '-filters')
if ($filterRun.ExitCode -ne 0) { throw "Could not query FFmpeg filters: $($filterRun.Output)" }
$qualityMetric = if ($filterRun.Output -match '\blibvmaf\b') { 'VMAF' } else { 'SSIM' }
if ($qualityMetric -eq 'SSIM') { Write-Host 'libvmaf is unavailable; using FFmpeg SSIM for the quality comparison.' }

$tempRoot = if ($TempDir) { $TempDir } else { [System.IO.Path]::GetTempPath() }
if (-not (Test-Path -LiteralPath $tempRoot -PathType Container)) {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
}
$workDir = Join-Path $tempRoot ('hardware-reencode-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
  $plan = @(Get-SamplePlan -Duration $duration -Count $SampleCount -Seconds $SampleSeconds)
  $samples = [System.Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $plan.Count; $i++) {
    $samplePath = Join-Path $workDir ('reference_{0}.mkv' -f $i)
    $startText = $plan[$i].Start.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
    $lengthText = $plan[$i].Length.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
    $extract = Invoke-Native -FilePath $Script:FfmpegExe -Arguments @(
      '-hide_banner', '-v', 'error', '-nostdin', '-y', '-ss', $startText, '-t', $lengthText,
      '-i', $inputPath, '-map', ('0:{0}' -f $videoStream[0].index), '-an', '-sn', '-dn', '-c:v', 'ffv1', $samplePath
    )
    if ($extract.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $samplePath -PathType Leaf)) {
      throw "Could not create sample $($i + 1): $($extract.Output)"
    }
    $samples.Add($samplePath)
  }

  $libx264 = [regex]::IsMatch($encoderRun.Output, '^\s*V\S*\s+libx264\b', [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if (-not $libx264) { throw 'This FFmpeg build does not include libx264, required for the CPU comparison.' }
  Write-Host ('Testing {0} sample(s), {1}s each, target bitrate {2} kbit/s.' -f $samples.Count, $SampleSeconds, $TargetBitrateKbps)
  Write-Host "Encoding quality metric: $qualityMetric. Sample preparation is excluded from timings."

  $cpuResult = Measure-Encoder -Name 'cpu' -Encoder 'libx264' -Samples $samples.ToArray() `
    -BitrateKbps $TargetBitrateKbps -WorkDir $workDir -Metric $qualityMetric
  if (-not $cpuResult) { throw 'The CPU libx264 baseline encode failed; no GPU comparison can be made.' }
  $encodeResults = [System.Collections.Generic.List[object]]::new()
  $encodeResults.Add($cpuResult)

  foreach ($encoder in $h264HardwareEncoders) {
    $name = $encoder -replace '[^a-zA-Z0-9_-]', '_'
    $result = Measure-Encoder -Name $name -Encoder $encoder -Samples $samples.ToArray() `
      -BitrateKbps $TargetBitrateKbps -WorkDir $workDir -Metric $qualityMetric
    if ($result) { $encodeResults.Add($result) }
  }

  Write-Host ''
  Write-Host '=== Encoding comparison (speed is sample seconds per wall-clock second)' -ForegroundColor Cyan
  $encodeResults |
    Select-Object Name, Encoder,
    @{n = 'SizeMB'; e = { [Math]::Round($_.Bytes / 1MB, 2) } },
    @{n = 'EncodeSeconds'; e = { [Math]::Round($_.Seconds, 2) } },
    @{n = 'RealtimeSpeed'; e = { [Math]::Round($_.Speed, 2) } },
    @{n = $qualityMetric; e = { if ($null -ne $_.Quality) { [Math]::Round($_.Quality, 3) } else { 'n/a' } } } |
      Format-Table -AutoSize | Out-Host

  if ($null -eq $cpuResult.Quality) {
    Write-Warning 'Quality scores could not be measured; encoding verdicts are inconclusive.'
  }
  else {
    foreach ($result in @($encodeResults | Where-Object { $_.Name -ne 'cpu' })) {
      $speedup = $result.Speed / [Math]::Max(0.001, $cpuResult.Speed)
      $sizeChange = 100.0 * ($result.Bytes - $cpuResult.Bytes) / [Math]::Max(1.0, [double]$cpuResult.Bytes)
      $qualityLoss = $cpuResult.Quality - $result.Quality
      $maxLoss = if ($qualityMetric -eq 'VMAF') { $MaximumVmafLoss } else { $MaximumSsimLoss }
      if ($null -eq $result.Quality) {
        $verdict = 'INCONCLUSIVE (quality measurement failed)'
      }
      elseif ($qualityLoss -gt $maxLoss) {
        $verdict = 'NOT WORTH IT (quality loss exceeds threshold)'
      }
      elseif ($sizeChange -gt $MaximumSizeGrowthPercent) {
        $verdict = 'NOT WORTH IT (output is too large)'
      }
      elseif ($speedup -ge $MinimumSpeedup) {
        $verdict = 'WORTH IT (faster at acceptable quality and size)'
      }
      elseif ($sizeChange -le (-$MinimumSizeSavingsPercent)) {
        $verdict = 'WORTH IT (smaller output at acceptable quality)'
      }
      else {
        $verdict = 'NOT WORTH IT (no sufficient speed or size gain)'
      }
      Write-Host ('{0}: {1}; speed {2:N2}x CPU, size {3:+0.0;-0.0;0.0}% vs CPU, quality loss {4:N3} {5}.' -f
        $result.Encoder, $verdict, $speedup, $sizeChange, $qualityLoss, $qualityMetric)
    }
  }

  Write-Host ''
  Write-Host '=== Decode comparison' -ForegroundColor Cyan
  $decodeResults = [System.Collections.Generic.List[object]]::new()
  $cpuDecode = Measure-DecodeSpeed -Label 'CPU' -InputPath $inputPath -VideoIndex $videoStream[0].index -Plan $plan
  if ($cpuDecode) { $decodeResults.Add($cpuDecode) }
  else { Write-Warning 'CPU decode baseline failed; GPU decode speedups cannot be evaluated.' }
  foreach ($accel in $decodeAccels) {
    $result = Measure-DecodeSpeed -Label $accel -InputPath $inputPath `
      -VideoIndex $videoStream[0].index -Plan $plan -HardwareAcceleration $accel
    if ($result) { $decodeResults.Add($result) }
  }
  $decodeResults |
    Select-Object Accelerator,
    @{n = 'DecodeSeconds'; e = { [Math]::Round($_.Seconds, 2) } },
    @{n = 'RealtimeSpeed'; e = { [Math]::Round($_.Speed, 2) } },
    @{n = 'SpeedupVsCPU'; e = { if ($cpuDecode) { [Math]::Round($_.Speed / [Math]::Max(0.001, $cpuDecode.Speed), 2) } else { $null } } } |
      Format-Table -AutoSize | Out-Host

  if ($cpuDecode) {
    foreach ($result in @($decodeResults | Where-Object { $_.Accelerator -ne 'CPU' })) {
      $ratio = $result.Speed / [Math]::Max(0.001, $cpuDecode.Speed)
      $verdict = if ($ratio -ge $MinimumSpeedup) { 'WORTH IT (faster decode)' } else { 'NOT WORTH IT (no sufficient decode speed gain)' }
      Write-Host ('{0}: {1} ({2:N2}x CPU speed).' -f $result.Accelerator, $verdict, $ratio)
    }
  }
}
finally {
  if ($KeepSamples) {
    Write-Host "Temporary samples and outputs kept at: $workDir" -ForegroundColor DarkGray
  }
  else {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
