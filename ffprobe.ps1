[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$MediaFilePath,
  [switch]$duration
)

$ProbeExePath = & "$PSScriptRoot\ffmpeg-find.ps1" -Executable 'ffprobe'
if(-not $ProbeExePath) {
  Write-Error "ffprobe.exe could not be located."
  return
}

if($duration) {
  $DurationCommand =@(
    "-v",
    "error",
    "-select_streams",
    "v:0",
    "-show_entries",
    "format=duration",
    "-of",
    "default=noprint_wrappers=1:nokey=1",
    $MediaFilePath
  )
  return & $ProbeExePath $DurationCommand
} else {
  Write-Host "Duration flag is not set."
}