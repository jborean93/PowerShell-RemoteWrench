<#
.SYNOPSIS
Copies files from the client to the remote session.

.DESCRIPTION
Copies client files, under the client path of the callback, to the remote
session. A directory isn't copied, only files.

.PARAMETER Path
The client files to copy, relative to the client path of the callback.

.PARAMETER Destination
The remote path to copy them to. If it is a directory the files are copied
into it, otherwise the file is copied to this path. Defaults to the current
location.

.PARAMETER Force
Overwrites a remote file that already exists.

.PARAMETER Compression
How the file is compressed while it is copied, Deflate or None. Deflate
copies less data, None is faster for files that are already compressed.
Defaults to Deflate.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
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
    $destinationPath = if ($Destination) {
        $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    }
    else {
        $PSCmdlet.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    }
    $clientPaths = [System.Collections.Generic.List[string]]::new()
}
process {
    $clientPaths.AddRange($Path)
}
end {
    # The client sends a header for each file followed by its bytes.
    $state = @{
        Stream = $null
        Target = $null
        Source = $null
        Length = 0
        Remaining = 0
        Percent = -1
        Compressed = $false
    }

    $finish = {
        if ($state.Stream) {
            $state.Stream.Dispose()
            $state.Stream = $null
            Get-Item -LiteralPath $state.Target
        }
        Write-Progress -Activity "Copying '$($state.Source)' from the client" -Completed
    }

    try {
        Invoke-ExtCallback -Path $clientPaths.ToArray() -Compression $Compression | ForEach-Object {
            if ($state.Remaining -eq 0 -and $_ -is [hashtable]) {
                $state.Source = $_.Source
                $state.Length = [long]$_.Length
                $state.Remaining = $state.Length
                $state.Percent = -1
                $state.Compressed = $_.Compression -eq 'Deflate'
                $state.Target = if ([System.IO.Directory]::Exists($destinationPath)) {
                    # Only the file name of the client's path is used.
                    [System.IO.Path]::Combine($destinationPath, [System.IO.Path]::GetFileName($_.Name))
                }
                else {
                    $destinationPath
                }

                try {
                    if (-not $Force -and [System.IO.File]::Exists($state.Target)) {
                        throw [System.IO.IOException]::new(
                            "The file '$($state.Target)' already exists, use -Force to overwrite it.")
                    }
                    $state.Stream = [System.IO.FileStream]::new(
                        $state.Target,
                        [System.IO.FileMode]::Create,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::None)
                }
                catch {
                    $err = [System.Management.Automation.ErrorRecord]::new(
                        $_.Exception,
                        'ReceiveFileFailed',
                        [System.Management.Automation.ErrorCategory]::WriteError,
                        $state.Target)
                    $err.ErrorDetails = "Failed to copy '$($state.Source)': $($_.Exception.Message)"
                    $PSCmdlet.WriteError($err)
                }

                if ($state.Remaining -eq 0) {
                    & $finish
                }
            }
            elseif ($state.Remaining -gt 0 -and $_ -is [byte[]]) {
                $chunk = $_
                if ($state.Compressed) {
                    $deflate = [System.IO.Compression.DeflateStream]::new(
                        [System.IO.MemoryStream]::new($chunk),
                        [System.IO.Compression.CompressionMode]::Decompress)
                    $output = [System.IO.MemoryStream]::new()
                    $deflate.CopyTo($output)
                    $deflate.Dispose()
                    $chunk = $output.ToArray()
                }

                if ($state.Stream) {
                    $state.Stream.Write($chunk, 0, $chunk.Length)
                }
                $state.Remaining -= $chunk.Length

                # Only when it changes, each record is sent to the client.
                $percent = [int][Math]::Floor((($state.Length - $state.Remaining) / $state.Length) * 100)
                if ($percent -ne $state.Percent) {
                    $state.Percent = $percent
                    Write-Progress -Activity "Copying '$($state.Source)' from the client" -PercentComplete $percent
                }

                if ($state.Remaining -le 0) {
                    $state.Remaining = 0
                    & $finish
                }
            }
            else {
                throw "Received unexpected data from the client: $($_.GetType().FullName)"
            }
        }
    }
    finally {
        # A file that didn't finish is left incomplete, remove it.
        if ($state.Stream) {
            $state.Stream.Dispose()
            Remove-Item -LiteralPath $state.Target -Force -ErrorAction SilentlyContinue
        }
    }
}
