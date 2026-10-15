# RemoteWrench

[![Test workflow](https://github.com/jborean93/PowerShell-RemoteWrench/workflows/Test%20RemoteWrench/badge.svg)](https://github.com/jborean93/PowerShell-RemoteWrench/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/jborean93/PowerShell-RemoteWrench/branch/main/graph/badge.svg)](https://codecov.io/gh/jborean93/PowerShell-RemoteWrench)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/dt/RemoteWrench.svg)](https://www.powershellgallery.com/packages/RemoteWrench)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/jborean93/PowerShell-RemoteWrench/blob/main/LICENSE)

## Documentation

Documentation for this module and details on the cmdlets included can be found [here](docs/en-US/RemoteWrench/RemoteWrench.md).

## Examples

### Extension Sessions

[`Enter-ExtSession`](docs/en-US/RemoteWrench/Enter-ExtSession.md) enters a remote session like `Enter-PSSession` with extension functions defined in it.
They can be local functions you want in the remote session without reloading them by hand, or callbacks, functions in the remote session that run code on the client.
See [about_ExtSession](docs/en-US/RemoteWrench/about_ExtSession.md) for how they work.

#### Enter a session

`Enter-ExtSession` has the same parameters as `New-PSSession` to create the session, the session is closed when it is exited.
For anything else, like a custom transport, a scriptblock can create the session instead.

```powershell
Enter-ExtSession server -Function Invoke-Sudo
Enter-ExtSession -HostName admin@server -Port 2222 -Function Invoke-Sudo
Enter-ExtSession { New-CustomSession -Endpoint foo } -Function Invoke-Sudo
```

#### Remote functions

A local function can be given by name, its definition is copied to the remote session.
[`New-ExtFunction`](docs/en-US/RemoteWrench/New-ExtFunction.md) defines one from a scriptblock, with `$using:` for values from the client.

```powershell
Function Get-ServiceStatus {
    param ([string[]]$Name)

    Get-Service -Name $Name | Select-Object Name, Status
}

$logPath = 'C:\Logs\app.log'
$tail = New-ExtFunction Get-AppLog {
    param ([int]$Tail = 20)

    Get-Content -LiteralPath $using:logPath -Tail $Tail
}

Enter-ExtSession server -Function Get-ServiceStatus, $tail
```

```powershell
[server]: PS> Get-ServiceStatus WinRM
[server]: PS> Get-AppLog -Tail 5
```

The functions behave like any other, with their parameters, help and pipeline input.

#### Callbacks

[`New-ExtCallback`](docs/en-US/RemoteWrench/New-ExtCallback.md) defines a function in the remote session that runs a script on the client.
Without a server script the remote function is a proxy for the client script, its arguments and pipeline input go to the client script and the client script's output comes back as it is written.

```powershell
$callbacks = @(
    New-ExtCallback Get-ClientName { [Environment]::MachineName }

    New-ExtCallback Out-ClientGridView {
        param ([string]$Title = 'Remote')

        $input | Out-GridView -Title $Title -PassThru
    }
)
Enter-ExtSession server -Function $callbacks
```

```powershell
[server]: PS> Get-ClientName
[server]: PS> Get-Process | Out-ClientGridView -Title 'Pick a process' | Stop-Process
```

`Get-Process` runs in the remote session, the grid view opens on the client and the selected processes are stopped in the remote session.

A server script runs in the remote session and calls the client script with `Invoke-ExtCallback`, which has the client script's parameters.

```powershell
$archive = New-ExtCallback Save-ClientArchive -ServerScript {
    param ([string[]]$Path, [string]$Destination)

    # Runs in the remote session, the client can't read the remote files.
    Get-Item -Path $Path | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            Content = [System.IO.File]::ReadAllBytes($_.FullName)
        }
    } | Invoke-ExtCallback -Destination $Destination
} -ClientScript {
    param ([string]$Destination)

    # Runs on the client, it gets the objects as pipeline input.
    begin {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
        $zip = [System.IO.Compression.ZipFile]::Open($path, 'Create')
    }
    process {
        $entry = $zip.CreateEntry([System.IO.Path]::GetFileName($_.Name))
        $stream = $entry.Open()
        try {
            $stream.Write($_.Content, 0, $_.Content.Length)
        }
        finally {
            $stream.Dispose()
        }
    }
    end {
        $zip.Dispose()
        $path
    }
}
```

```powershell
[server]: PS> Save-ClientArchive -Path C:\Logs\*.log -Destination logs.zip
```

> [!IMPORTANT]
> Anything running in the remote session can call a callback with any input, not only the function defined for it.
> Treat what a client script receives as untrusted and validate it, see [about_ExtSession](docs/en-US/RemoteWrench/about_ExtSession.md).

#### Copy and edit files

[`New-ExtFileTransferCallback`](docs/en-US/RemoteWrench/New-ExtFileTransferCallback.md) creates `Send-ClientFile` and `Receive-ClientFile` to copy files between the client and the remote session, limited to one client directory.
[`New-ExtEditCallback`](docs/en-US/RemoteWrench/New-ExtEditCallback.md) creates `PSEdit` to edit a remote file with the client's editor.

```powershell
$functions = @(
    New-ExtFileTransferCallback -ClientPath ~/Downloads
    New-ExtEditCallback -Editor 'code --wait'
)
Enter-ExtSession server -Function $functions
```

```powershell
[server]: PS> Get-ChildItem C:\Logs\*.log | Send-ClientFile -Destination logs
[server]: PS> Receive-ClientFile tool.zip C:\Temp
[server]: PS> PSEdit C:\inetpub\wwwroot\web.config
```

### PSRP Packets

[`ConvertTo-PSRPPacket`](docs/en-US/RemoteWrench/ConvertTo-PSRPPacket.md) and [`Format-PSRPPacket`](docs/en-US/RemoteWrench/Format-PSRPPacket.md) parse and display PowerShell Remoting Protocol (PSRP) packets to see what a remote session is doing.
These examples use a log of PSRP packets sent over the OutOfProc transport, like a `Start-Job` or `pwsh -s` session, with one packet per line.
The `Format-PSRPPacket` output below is shown with `-NoColor`, in a terminal it is colored by direction with errors in red.

#### Parse the packets

[`ConvertTo-PSRPPacket`](docs/en-US/RemoteWrench/ConvertTo-PSRPPacket.md) parses each packet, reassembles messages that span multiple packets, and decodes the PSRP messages inside them.

```powershell
$packets = Get-Content session.log | ConvertTo-PSRPPacket
$packets | Select-Object -First 6 Type, Destination, @{ N = 'Messages'; E = { $_.Messages.MessageType -join ', ' } }
```

```text
Type    Destination Messages
----    ----------- --------
Data         Server SessionCapability, InitRunspacePool
Data         Client SessionCapability
Data         Client PipelineState
Data         Client ApplicationPrivateData
Data         Client RunspacePoolState
DataAck      Client
```

The packets are objects so they can be filtered like any other, for example to find the error records the server sent;

```powershell
$packets.Messages | Where-Object MessageType -eq ErrorRecord
```

#### Format the packets

[`Format-PSRPPacket`](docs/en-US/RemoteWrench/Format-PSRPPacket.md) formats the packets with one of three views selected by `-View [Timeline|Grouped|GroupedDetail]`.

The default `Timeline` view shows every packet in the order it was received, one line per message with a summary of what it contains.
This is similar to a Wireshark capture that shows the raw transport exchange of PSRP.
The `PSGuid` and `Size` columns are dropped when the terminal is narrower than 110 characters.

```powershell
Get-Content session.log | ConvertTo-PSRPPacket | Format-PSRPPacket
```

```text
   # Dir Packet     PSGuid   Message                  Obj:Frag       Size Summary
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  14 C→S Command    ec459654                                              create pipeline
  15 S→C CommandAck ec459654
  16 C→S Data       ec459654 CreatePipeline           4:0 SE        2.5KB "output string"↵[PSCustomObject]@{ Name = "ob…
  17 S→C DataAck    ec459654
  18 C→S Data       ec459654 PipelineInput            5:0 SE          52B "piped"
     C→S                     EndOfPipelineInput       6:0 SE          40B end of input
  19 S→C DataAck    ec459654
  20 S→C Data       ec459654 PipelineOutput           6:0 SE          60B "output string"
  21 S→C Data       ec459654 PipelineOutput           7:0 SE         200B [PSCustomObject] @{Name=obj; Value=1}
  22 S→C Data       ec459654 ErrorRecord              8:0 SE        2.9KB an error
  23 S→C Data       ec459654 WarningRecord            9:0 SE         351B a warning
  24 S→C Data       ec459654 PipelineHostCall         10:0 SE        442B WriteWarningLine("a warning")
```

The `Grouped` view focuses more on the actual PowerShell operations and not the raw `OutOfProc` XML payloads.
It groups the messages under their runspace pool and pipeline and leaving out the acknowledgements and fragments.
This is exchange showing a job pipeline that was stopped with `Stop-Job`;

```powershell
Get-Content session.log | ConvertTo-PSRPPacket | Format-PSRPPacket -View Grouped
```

```text
RunspacePool 6dcabbe1-d800-4bee-b550-2cd095c39512
│ ▶ SessionCapability           protocol 2.4, PS 2.0, serialization 1.1.0.1
│ ▶ InitRunspacePool            min 1, max 1, client PS 7.6.6
│ ◀ SessionCapability           protocol 2.4, PS 2.0, serialization 1.1.0.1
│ ◀ RunspacePoolState           Opened
├─ Pipeline 203d3125-97cc-491d-aaf8-79efbe5a86bd
│  │ ▶ CreatePipeline           Start-Sleep 30
│  │ ▶ Signal (stop pipeline)
│  │ ◀ PipelineState            Stopped: The pipeline has been stopped.
│  │ ▶ Close (close pipeline)
│ ▶ Close (close runspace pool)
│ ◀ RunspacePoolState           Closing
│ ◀ RunspacePoolState           Closed
```

The `GroupedDetail` view expands on `Grouped`, adding more details around each message and its decoded fields;

```powershell
Get-Content session.log | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail
```

```text
│  │ ◀ PipelineOutput           [PSCustomObject] @{Name=obj; Value=1}
│  │     #21 · Data · Obj 7:0 SE · 200B
│  │     [PSCustomObject]
│  │     ├─ Name: obj
│  │     └─ Value: 1
│  │ ◀ ErrorRecord              an error
│  │     #22 · Data · Obj 8:0 SE · 2.9KB
│  │     Message    an error
│  │     ErrorId    Microsoft.PowerShell.Commands.WriteErrorException
│  │     Category   NotSpecified: (:) [Write-Error], WriteErrorException
│  │     Exception  WriteErrorException
```

Every view streams so a log that is still being written can be followed with `Get-Content session.log -Wait`.

## Requirements

These cmdlets have the following requirements

* PowerShell v7.4 or newer, or Windows PowerShell v5.1

## Installing

The easiest way to install this module is through
[PowerShellGet](https://docs.microsoft.com/en-us/powershell/gallery/overview).

You can install this module by running;

```powershell
# Install for only the current user
Install-PSResource -Name RemoteWrench -Scope CurrentUser

# Install for all users
Install-PSResource -Name RemoteWrench -Scope AllUsers
```

Windows PowerShell 5.1 does not include `Install-PSResource`, use `Install-Module` from PowerShellGet instead;

```powershell
# Install for only the current user
Install-Module -Name RemoteWrench -Scope CurrentUser

# Install for all users
Install-Module -Name RemoteWrench -Scope AllUsers
```

## Contributing

Contributing is quite easy, fork this repo and submit a pull request with the changes.
To build this module run `pwsh -File ./build.ps1 -Task Build` in PowerShell.
To test a build run `pwsh -File ./build.ps1 -Task Test` in PowerShell.
This script will ensure all dependencies are installed before running the test suite.
