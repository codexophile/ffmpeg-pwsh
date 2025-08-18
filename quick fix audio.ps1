Set-Location $PSScriptRoot
. ..\#lib\functions.ps1

$InputFiles = @() 
If ($args.Length -gt 0) {
    $InputFiles = $args
}
Else {
    $filePathsString = Read-Host "Drag and drop files here, or enter paths separated by a comma"
    # Split the string into an array, trim whitespace and remove empty entries
    $InputFiles = $filePathsString.Split(',') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ }
}

if ($InputFiles.Count -eq 0) {
    Write-Host "No input files specified. Exiting." -ForegroundColor Yellow
    pause
    exit
}

Write-Host "Processing $($InputFiles.Count) files..."

foreach ( $OriginalPath in $InputFiles) {

  Write-Host "Processing: $OriginalPath"

  # --- START OF CHANGES ---

  # First, convert the input path (which could be relative) to a full path.
  # We use -LiteralPath because it's safer with filenames that might have special characters.
  $FullPath = (Resolve-Path -LiteralPath $OriginalPath).Path

  # Now, get the file object from the GUARANTEED full path.
  $OriginalFile = Get-Item -LiteralPath $FullPath

  # --- END OF CHANGES ---

  # The rest of the logic now works perfectly because .DirectoryName will never be null.
  $NewName = "$($OriginalFile.BaseName)_fixed.mp4" 
  $destFile = Join-Path $OriginalFile.DirectoryName $NewName

  Write-Host "Outputting to: $destFile `n"
  
  # Selects the first video/audio streams AND forces audio to stereo
& ffmpeg -i $originalPath -map 0:v:0 -map 0:a:0 -c:v copy -c:a ac3 -ac 2 $destFile
}

pause