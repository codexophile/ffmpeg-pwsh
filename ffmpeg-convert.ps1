param ( $inputFiles, $outputExt, [switch]$silent, [switch]$ACodec, [switch]$VCodec, [switch]$720p )

$ffmpegPath = & $PSScriptRoot/ffmpeg-find.ps1
if( -not $ffmpegPath ) {
  Write-Error "ffmpeg not found. Please install ffmpeg and ensure it is in your PATH."
  return
}

Write-Host "input files    : $inputFiles"
Write-Host "ext            : $outputExt"
Write-Host "AC             : $ACodec"
Write-Host "VC             : $VCodec"
Write-Host "silent         : $silent"
Write-Host "Resize to 720p : $720p"

$StopWatch = new-object system.diagnostics.stopwatch
$StopWatch.Start()

Add-Type -AssemblyName PresentationCore, PresentationFramework
Set-Location $PSScriptRoot
. ..\#lib\functions.ps1       
. ..\#lib\functions-forms.ps1

$fileS = $inputFiles -split [Environment]::NewLine

if ( -not $outputExt ) {
    $controls = @(
        ( $inputField = addTextBox 'mkv' ),
        ( $btProceed = addButton 'Proceed' -after $inputField -dialogRes Continue -eventClick {    } ),
        ( $btNo = addButton '×'       -after $btProceed  -dialogRes Cancel   -eventClick { return } -w 30 )
    )
    $Form = addForm -minSize -controls $controls -acceptBt $btProceed -cancelBt $btNo
    $response = $Form.ShowDialog()
    if ( $response -eq 'Cancel' ) { [Environment]::Exit(0) }
    $outputExt = $inputField.text
}

foreach ( $file in $fileS ) {
    $ParentPath = Split-Path -Path $file -Parent
    $LeafBase = Split-Path -Path $file -LeafBase
    $outputFile = CheckFile "$ParentPath\$LeafBase.$outputExt"
    Write-Host $outputFile
    $parameters = @( '-i', $file )
    if ( $VCodec ) { $parameters += '-vcodec', 'libx264' }
    if ( $ACodec ) { $parameters += '-acodec', 'aac' }
    if ( $720p   ) { $parameters += '-vf', 'scale=-1:720' }
    $parameters += $outputFile
    # Write-Host $parameters
    # pause
    & $ffmpegPath $parameters
    # pause
}

$StopWatch.Stop()
Write-Host "Elapsed: " -NoNewline; Write-Host $StopWatch.Elapsed -ForegroundColor Cyan

if ( $silent ) { return $outputFile }

$null = MessageBox 'Exiting' '' 'Ok' 'Information'
return $outputFile
[Environment]::Exit(0)