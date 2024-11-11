param ( $inputFiles, $outputFileName )

. ( 'D:\Mega\IDEs\powershell\functions.ps1' )

$inputFilesArray = $inputFiles -split "`r`n" | Sort-Object
$FileNameCommonPart = (Get-LongestCommonSubstring -arr $inputFilesArray).trim()
$combinedUniqueTags = Get-UniqueTags($inputFilesArray)
$extension = [System.IO.Path]::GetExtension($inputFilesArray[0])
$newFileName = "$($FileNameCommonPart) $($combinedUniqueTags)$($extension)"

Clear-Host
Write-Host "Common part   : $FileNameCommonPart"
Write-Host "New file name : $newFileName"
Pause

# Create a temporary text file that FFmpeg will use to concatenate the videos
$tempListFile = "ffmpeg-concat.txt"
$inputFilesArray | ForEach-Object { "file '$_'" } | Out-File -Encoding ASCII $tempListFile

# Execute the FFmpeg command to concatenate the videos
ffmpeg -f concat -safe 0 -i $tempListFile -c copy $newFileName

# Clean up the temporary file
Remove-Item $tempListFile

# Output the final file name
Write-Output "`n`nConcatenation completed. Output file:`n$newFileName"