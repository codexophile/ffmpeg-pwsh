Param( $InputFile )

if ( -not $InputFile -or -not (Test-Path $InputFile) ) {
	Write-Host "Usage: powershell -File ffmpeg-decimate.ps1 <video-file>" -ForegroundColor Yellow
	exit 1
}

# Load shared helpers
. ( '..\#lib\functions.ps1')

Set-Location $PSScriptRoot
$ffmpegPath = 'ffmpeg'

$ParentPath = Split-Path -Path $InputFile -Parent
$LeafBase   = Split-Path -Path $InputFile -LeafBase
$extension  = [IO.Path]::GetExtension($InputFile).TrimStart('.')
if ( -not $extension ) { $extension = 'mp4' }

$outputFile = CheckFile "$ParentPath\$LeafBase [decimated].$extension"
Write-Host "Output: $outputFile" -ForegroundColor Cyan

# mpdecimate removes duplicate frames; -vsync vfr keeps variable frame rate after drops
# setpts enforces proper timestamps if constant frame rate is desired; we'll keep VFR for size
# Copy audio to avoid re-encoding unless container/codec mismatch forces re-encode

& $ffmpegPath -hide_banner -y -i $InputFile -vf mpdecimate -vsync vfr -c:v libx264 -crf 18 -preset medium -c:a copy $outputFile

if ($LASTEXITCODE -ne 0) {
	Write-Host "ffmpeg failed with exit code $LASTEXITCODE" -ForegroundColor Red
	exit $LASTEXITCODE
}

return $outputFile
