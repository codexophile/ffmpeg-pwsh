Param( $InputFile )

. ( 'c:\Mega\IDEs\powershell\#lib\functions.ps1' )
Set-Location $PSScriptRoot
$ffmpegPath = 'ffmpeg'

$ParentPath = Split-Path -Path $InputFile -Parent
$LeafBase = Split-Path -Path $InputFile -LeafBase
# $extension = Split-Path -Path $InputFile -Extension
$extension = "mp4"
$outputFile = CheckFile "$ParentPath\$LeafBase [s].$extension"

& $ffmpegPath -i $InputFile -vf vidstabdetect= -f null -
& $ffmpegPath -y -i $InputFile -vf vidstabtransform=input=transforms.trf:optzoom=0:smoothing=100`,unsharp -vcodec libx264 -tune film -acodec copy -preset slow $outputFile
Remove-Item transforms.trf