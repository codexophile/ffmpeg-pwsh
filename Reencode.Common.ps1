function Invoke-NativeCommand {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory, Position = 0)][string]$FilePath,
    [Parameter(Mandatory, Position = 1)][string[]]$Arguments,
    [AllowNull()][pscustomobject]$Gpu
  )

  $oldPreference = $ErrorActionPreference
  $oldCudaDeviceOrder = $env:CUDA_DEVICE_ORDER
  if ($Gpu -and $Gpu.VendorId -eq '10de' -and $null -ne $Gpu.NvidiaIndex) {
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
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output   = ($lines -join "`n")
  }
}

function Get-SamplePlan {
  <#
    .SYNOPSIS
        Chooses clip start times spread evenly across the file.
    .PARAMETER Duration
        File duration in seconds.
    .PARAMETER Count
        Desired number of clips.
    .PARAMETER Seconds
        Desired clip length in seconds.
    .PARAMETER CenterShortSample
        Center the sample when the file is longer than one sample but no more than 1.5 sample lengths.
    .OUTPUTS
        [pscustomobject[]] each with Start and Length (seconds).
  #>
  [CmdletBinding()]
  [OutputType([pscustomobject[]])]
  param(
    [Parameter(Mandatory)][double]$Duration,
    [Parameter(Mandatory)][int]$Count,
    [Parameter(Mandatory)][double]$Seconds,
    [switch]$CenterShortSample
  )
  $length = [Math]::Min($Duration, $Seconds)
  if ($Duration -le ($Seconds * 1.5) -and -not $CenterShortSample) {
    return @([pscustomobject]@{ Start = 0.0; Length = $length })
  }
  $n = [Math]::Max(1, [Math]::Min($Count, [int][Math]::Floor($Duration / $length)))
  $plan = for ($i = 0; $i -lt $n; $i++) {
    $center = $Duration * ($i + 0.5) / $n
    $start = [Math]::Max(0.0, [Math]::Min($center - $length / 2.0, $Duration - $length))
    [pscustomobject]@{ Start = $start; Length = [double]$length }
  }
  return @($plan)
}
