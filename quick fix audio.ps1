.( 'D:\Mega\IDEs\powershell\functions.ps1' )

write-host Processing $args.Length files`n

for ( $i=0; $i -lt $args.length; $i++)
{

	write-host "$($args[$i])" `n`n
	$originalPath = $args[$i]
	$destFile     = checkFile $originalPath
	write-host $destFile
	ffmpeg -i $originalPath -c:v copy -c:a ac3 $destFile
	
}
pause