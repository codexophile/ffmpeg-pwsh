Param( $InputFile )

. ( 'c:\Mega\IDEs\powershell\#lib\functions.ps1' )
$ffmpegPath = & $PSScriptRoot\ffmpeg-find.ps1
if( -not $ffmpegPath ) {
  Write-Error "ffmpeg not found. Please install ffmpeg and ensure it is in your PATH."
  return
}

$ParentPath = Split-Path -Path $InputFile -Parent
$LeafBase = Split-Path -Path $InputFile -LeafBase
# $extension = Split-Path -Path $InputFile -Extension
$extension = "mp4"
$outputFile = CheckFile "$ParentPath\$LeafBase [s].$extension"

& $ffmpegPath -i $InputFile -vf vidstabdetect= -f null -
& $ffmpegPath -y -i $InputFile -vf vidstabtransform=input=transforms.trf:optzoom=0:smoothing=100`,unsharp -vcodec libx264 -tune film -acodec copy -preset slow $outputFile
Remove-Item transforms.trf