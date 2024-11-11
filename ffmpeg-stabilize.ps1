Param( $InputFile )

. ( 'D:\Mega\IDEs\powershell\functions.ps1' )
Set-Location $PSScriptRoot

$ParentPath = Split-Path -Path $InputFile -Parent
$LeafBase = Split-Path -Path $InputFile -LeafBase
$extension = Split-Path -Path $InputFile -Extension
$outputFile = CheckFile "$ParentPath\$LeafBase [s].$extension"

& 'ffmpeg' -i $InputFile -vf vidstabdetect= -f null -
& 'ffmpeg' -y -i $InputFile -vf vidstabtransform=input=transforms.trf:optzoom=0:smoothing=100`,unsharp -vcodec libx264 -tune film -acodec copy -preset slow $outputFile
Remove-Item transforms.trf