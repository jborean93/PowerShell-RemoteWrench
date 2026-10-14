#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
Replays a captured PSRP OutOfProc log line by line as if it was being received.

.DESCRIPTION
Outputs each line of the log with a delay between them to see how the
Format-PSRPPacket views behave on a session that is still in progress. The
lines are written to the pipeline by default, or appended to a file with
-OutFile to follow it with Get-Content -Wait from another terminal.

The logs have no timestamps so the delay is a fixed time with some random
jitter. A packet that completes a pipeline (CloseAck) is followed by a
longer pause, like the gap between commands in a real session.

.PARAMETER Path
The OutOfProc log to replay.

.PARAMETER DelayMilliseconds
The time between lines.

.PARAMETER JitterMilliseconds
A random amount of time up to this value added to each delay.

.PARAMETER PauseMilliseconds
The extra time after a CloseAck packet.

.PARAMETER OutFile
Appends the lines to this file instead of outputting them. The file is
cleared first.

.PARAMETER Wait
Keeps running after the last line until Ctrl+C is pressed, like
Get-Content -Wait. Views that only output once all the input is received never
output with this set.

.EXAMPLE
./tools/ReplayPSRPLog.ps1 -Path ./OutOfProc.xml | ConvertTo-PSRPPacket | Format-PSRPPacket -View Grouped

Replays the log into the formatter.

.EXAMPLE
./tools/ReplayPSRPLog.ps1 -Path ./OutOfProc.xml -OutFile ./live.xml

# In another terminal
Get-Content ./live.xml -Wait | ConvertTo-PSRPPacket | Format-PSRPPacket -View Timeline

Replays the log into a file that is followed in another terminal.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]
    $Path,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]
    $DelayMilliseconds = 150,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]
    $JitterMilliseconds = 200,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]
    $PauseMilliseconds = 1000,

    [Parameter()]
    [string]
    $OutFile,

    [Parameter()]
    [switch]
    $Wait
)

$ErrorActionPreference = 'Stop'

$lines = Get-Content -LiteralPath $Path
if ($OutFile) {
    Set-Content -LiteralPath $OutFile -Value $null -NoNewline
}

foreach ($line in $lines) {
    if ($OutFile) {
        Add-Content -LiteralPath $OutFile -Value $line
    }
    else {
        $line
    }

    $delay = $DelayMilliseconds + (Get-Random -Minimum 0 -Maximum ($JitterMilliseconds + 1))
    if ($line.StartsWith('<CloseAck')) {
        $delay += $PauseMilliseconds
    }
    Start-Sleep -Milliseconds $delay
}

if ($Wait) {
    while ($true) {
        Start-Sleep -Seconds 1
    }
}
