[CmdletBinding()]
param(
  [ValidateSet('general', 'Gyan', 'yt-dlp')]
  [string]$Variety = 'general',
  [ValidateSet('ffmpeg', 'ffprobe')]
  [string]$Executable = 'ffmpeg'
)

function Find-FfmpegInWinGet {
  param(
    [ValidateSet('Gyan', 'yt-dlp')]
    [string]$PackageVariety
  )

  $EsPath = "C:\mega\program-files\Everything\es.exe"
  if (-not (Test-Path -Path $EsPath -PathType Leaf)) {
    Write-Error "Everything Search (es.exe) not found at path: $EsPath"
    return $null
  }

  Write-Host "Searching for $Executable.exe ($PackageVariety) in WinGet packages using Everything Search..." -ForegroundColor Cyan
  $EsQuery1 = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\$PackageVariety.FFmpeg_Microsoft.Winget.Source_"
  $EsQuery2 = "\bin\$Executable.exe"
  $EsParams = @('-p', $EsQuery1, $EsQuery2)
  $EsResult = & $EsPath $EsParams
  $FfmpegWingetPath = ($EsResult -split '\r?\n')[0]

  if ([string]::IsNullOrWhiteSpace($FfmpegWingetPath)) {
    Write-Warning "ffmpeg ($PackageVariety) not found in WinGet packages."
    return $null
  }

  Write-Host "$Executable.exe found in WinGet packages: $FfmpegWingetPath" -ForegroundColor Green
  return $FfmpegWingetPath
}

function Find-FfmpegGeneral {
  $Cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($Cmd) {
    Write-Information "ffmpeg found in PATH: $($Cmd.Source)"
    return $Cmd.Source
  }

  Write-Warning "ffmpeg not found in PATH."

  # No specific variety requested (or it already failed) — try each known variety
  foreach ($PackageVariety in @('Gyan', 'yt-dlp')) {
    $Result = Find-FfmpegInWinGet -PackageVariety $PackageVariety
    if ($Result) {
      return $Result
    }
  }

  return $null
}

$FfmpegPath = $null

if ($Variety -eq 'general') {
  $FfmpegPath = Find-FfmpegGeneral
}
else {
  $FfmpegPath = Find-FfmpegInWinGet -PackageVariety $Variety
  if (-not $FfmpegPath) {
    Write-Warning "Specific variety '$Variety' not found. Falling back to general search..."
    $FfmpegPath = Find-FfmpegGeneral
  }
}

if (-not $FfmpegPath) {
  Write-Error "$Executable.exe could not be located."
}

return $FfmpegPath