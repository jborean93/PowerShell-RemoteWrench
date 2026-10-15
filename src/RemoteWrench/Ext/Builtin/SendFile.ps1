<#
.SYNOPSIS
Copies files from the remote session to the client.

.DESCRIPTION
Copies remote files to the client, under the client path of the callback. A
directory isn't copied, only files.

.PARAMETER Path
The remote files to copy, wildcards are supported.

.PARAMETER Destination
The client path to copy them to, relative to the client path of the
callback. If it is a directory the files are copied into it, otherwise the
file is copied to this path. Defaults to the client path of the callback.

.PARAMETER Force
Overwrites a client file that already exists.

.PARAMETER Compression
How the file is compressed while it is copied, Deflate or None. Deflate
copies less data, None is faster for files that are already compressed.
Defaults to Deflate.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]
    $Path,

    [Parameter(Position = 1)]
    [string]
    $Destination,

    [Parameter()]
    [switch]
    $Force,

    [Parameter()]
    [ValidateSet('Deflate', 'None')]
    [string]
    $Compression = 'Deflate'
)

begin {
    $files = [System.Collections.Generic.List[string]]::new()
}
process {
    foreach ($item in $Path) {
        try {
            $provider = $null
            $resolved = $PSCmdlet.SessionState.Path.GetResolvedProviderPathFromPSPath($item, [ref]$provider)
        }
        catch {
            $PSCmdlet.WriteError($_)
            continue
        }

        foreach ($file in $resolved) {
            if ([System.IO.Directory]::Exists($file)) {
                $err = [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.IOException]::new("'$file' is a directory, only files can be copied."),
                    'DirectoryNotSupported',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $file)
                $PSCmdlet.WriteError($err)
                continue
            }
            $files.Add($file)
        }
    }
}
end {
    if ($files.Count -eq 0) {
        return
    }

    $callbackParams = @{
        Force = $Force
    }
    if ($Destination) {
        $callbackParams.Destination = $Destination
    }

    # Every file goes to one call of the client code. The header and chunks
    # of each file are piped to it as they are read.
    & {
        $chunkSize = 65536
        foreach ($file in $files) {
            try {
                $stream = [System.IO.File]::OpenRead($file)
            }
            catch {
                $PSCmdlet.WriteError($_)
                continue
            }

            try {
                $length = $stream.Length
                @{
                    Name = [System.IO.Path]::GetFileName($file)
                    Length = $length
                    Source = $file
                    Compression = $Compression
                }

                # Exactly the length in the header is sent, even if the file
                # changes while it is read. Each chunk is a new array as it
                # is sent after this has moved on.
                $remaining = $length
                $percent = -1
                while ($remaining -gt 0) {
                    $chunk = [byte[]]::new([Math]::Min($chunkSize, $remaining))
                    $read = 0
                    while ($read -lt $chunk.Length) {
                        $count = $stream.Read($chunk, $read, $chunk.Length - $read)
                        if ($count -eq 0) {
                            break
                        }
                        $read += $count
                    }
                    $remaining -= $chunk.Length
                    if ($Compression -eq 'Deflate') {
                        $output = [System.IO.MemoryStream]::new()
                        $deflate = [System.IO.Compression.DeflateStream]::new(
                            $output,
                            [System.IO.Compression.CompressionLevel]::Fastest,
                            $true)
                        $deflate.Write($chunk, 0, $chunk.Length)
                        $deflate.Dispose()
                        $chunk = $output.ToArray()
                    }

                    # The unary comma outputs the array as one object.
                    , $chunk

                    # Only when it changes, each record is sent to the client.
                    $newPercent = [int][Math]::Floor((($length - $remaining) / $length) * 100)
                    if ($newPercent -ne $percent) {
                        $percent = $newPercent
                        Write-Progress -Activity "Copying '$file' to the client" -PercentComplete $percent
                    }
                }
            }
            finally {
                $stream.Dispose()
            }
        }
        Write-Progress -Activity 'Copying to the client' -Completed
    } | Invoke-ExtCallback @callbackParams
}
