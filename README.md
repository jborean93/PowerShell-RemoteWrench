# RemoteWrench

[![Test workflow](https://github.com/jborean93/PowerShell-RemoteWrench/workflows/Test%20RemoteWrench/badge.svg)](https://github.com/jborean93/PowerShell-RemoteWrench/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/jborean93/PowerShell-RemoteWrench/branch/main/graph/badge.svg)](https://codecov.io/gh/jborean93/PowerShell-RemoteWrench)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/dt/RemoteWrench.svg)](https://www.powershellgallery.com/packages/RemoteWrench)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/jborean93/PowerShell-RemoteWrench/blob/main/LICENSE)

## Documentation

Documentation for this module and details on the cmdlets included can be found [here](docs/en-US/RemoteWrench/RemoteWrench.md).

## Examples

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
