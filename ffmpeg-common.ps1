if( -not -not (Get-Command ffmpeg -ErrorAction SilentlyContinue) ) {
  Write-Information "ffmpeg found in PATH: $(Get-Command ffmpeg).Source"
  return (Get-Command ffmpeg).Source
}

Write-Warning "ffmpeg not found in PATH." 
$FfmpegPath = Find-FfmpegInWinGet
return $FfmpegPath
 
function Find-FfmpegInWinGet {
  $EsPath = "C:\mega\program-files\Everything\es.exe"
  if(-not (Test-Path -Path $EsPath -PathType Leaf)) {
    Write-Error "Everything Search (es.exe) not found at path: $EsPath"
    return false
  }
  Write-Host "Searching for ffmpeg.exe in WinGet packages using Everything Search..." -ForegroundColor Cyan
  $EsQuery1 = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_"
  $EsQuery2 = "\bin\ffmpeg.exe"
  $EsParams = @( '-p', $EsQuery1, $EsQuery2)
  $EsResult =& $EsPath $EsParams 
  $FfmpegWingetPath = ($EsResult -split '\r?\n')[0]
  Write-Host "ffmpeg found in WinGet packages: $FfmpegWingetPath" -ForegroundColor Green
  return $FfmpegWingetPath
}