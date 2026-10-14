---
document type: cmdlet
external help file: RemoteWrench.dll-Help.xml
HelpUri: https://www.github.com/jborean93/PowerShell-RemoteWrench/blob/main/docs/en-US/RemoteWrench/Format-PSRPPacket.md
Module Name: RemoteWrench
ms.date: ''
PlatyPS schema version: 2024-05-01
---

# Format-PSRPPacket

## SYNOPSIS

Formats PSRP packet objects into human-readable output.

## SYNTAX

### __AllParameterSets

```
Format-PSRPPacket -Packet <OutOfProcPacket[]> [-NoColor] [-View <PSRPPacketView>] [-Width <int>]
 [<CommonParameters>]
```

## ALIASES

## DESCRIPTION

The `Format-PSRPPacket` cmdlet formats parsed PSRP (PowerShell Remoting Protocol) packet objects from `ConvertTo-PSRPPacket` into human-readable text.

Each message is decoded into a summary and the fields that matter for its type, for example the command line of a `CreatePipeline`, the state and error of a `PipelineState`, or the method and arguments of a host call.
`SecureString` values are always shown as `[SecureString]`, even when the transport sends them unencrypted.

The `-View` parameter selects how the packets are laid out, each view answers a different question:

- `Timeline`: what was actually sent over the transport. This is the default and shows every packet in the order it was received, one line for each message, fragment, and control packet like `Command` or `DataAck`. The columns are the packet number, direction, packet type, PSGuid, message type, object and fragment id, message size, and a summary of the message. Use it to analyse the raw exchange, for example to find a missing acknowledgement, see how a large object was fragmented, or match a packet number from another view. The PSGuid and size columns are dropped when the output is narrower than 110 characters.
- `Grouped`: what happened in the session. Each PSRP message is a single line under the runspace pool and pipeline it belongs to, so a pipeline reads as its command, the output and records it produced, and the state it finished in. Acknowledgements, `Command` packets, and fragments are left out. When pipelines run concurrently a new header marked `(continued)` is written each time the messages switch between them, so the messages stay in the order received.
- `GroupedDetail`: `Grouped` with the in-depth information of each message underneath it. The packet number, packet type, and fragment of every fragment the message was received in, the decoded fields, like the parameters of a host call or the full multi-line script of a `CreatePipeline`, and object data as a tree. Use it to investigate a specific message found in the other views.

Every view streams, a packet is output as soon as it is received, so the cmdlet can follow a log that is still being written with `Get-Content -Wait`.
The direction is shown as `C→S` or `▶` for a packet sent by the client and `S→C` or `◀` for one sent by the server.
The output uses ANSI color codes by default, with different colors for each direction and red for errors.

## EXAMPLES

### Example 1: Format packets from a log file

```powershell
Get-Content psremoting.log | ConvertTo-PSRPPacket | Format-PSRPPacket
```

Reads, parses, and formats PSRP packets as a timeline with one line per message.

### Example 2: Group the messages by runspace pool and pipeline

```powershell
Get-Content psremoting.log | ConvertTo-PSRPPacket | Format-PSRPPacket -View Grouped
```

Shows what each pipeline did, with the runspace pool messages between them, without the acknowledgements and fragments of the transport.

### Example 3: Follow a log as it is written

```powershell
Get-Content psremoting.log -Wait | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail
```

Formats each message with its fragments and decoded fields as it is written to the log.

### Example 4: Format packets without color to a file

```powershell
Get-Content psremoting.log | ConvertTo-PSRPPacket | Format-PSRPPacket -NoColor -Width 200 | Set-Content psremoting.txt
```

Writes the timeline to a file without ANSI color codes, 200 characters wide regardless of the console size.

## PARAMETERS

### -NoColor

Disables ANSI color codes in the output.
Use this when redirecting to a file or when color output is not desired.

```yaml
Type: System.Management.Automation.SwitchParameter
DefaultValue: ''
SupportsWildcards: false
Aliases:
- NoColour
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Packet

The PSRP packet objects to format.
Accepts pipeline input from `ConvertTo-PSRPPacket`.

```yaml
Type: RemoteWrench.OutOfProcPacket[]
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: true
  ValueFromPipeline: true
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -View

The layout of the output, `Timeline` for the raw packet exchange, `Grouped` for the PSRP messages of each runspace pool and pipeline, or `GroupedDetail` for the grouped messages with their fragments and decoded fields.
See the description for more details on each view.
Defaults to `Timeline`.

```yaml
Type: RemoteWrench.PSRPPacketView
DefaultValue: Timeline
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues:
- Timeline
- Grouped
- GroupedDetail
HelpMessage: ''
```

### -Width

The width of the output in characters, between 40 and 1000.
Defaults to the buffer width of the host, which is the console of the client in a remote session, or 120 when the host does not provide one.
Summaries are truncated to the width, the fields of the `GroupedDetail` view are wrapped at the width or 120 characters, whichever is smaller.

```yaml
Type: System.Int32
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable,
-InformationAction, -InformationVariable, -OutBuffer, -OutVariable, -PipelineVariable,
-ProgressAction, -Verbose, -WarningAction, and -WarningVariable. For more information, see
[about_CommonParameters](https://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

### RemoteWrench.OutOfProcPacket[]

Parsed PSRP packet objects from `ConvertTo-PSRPPacket`.

## OUTPUTS

### System.String

A string for each formatted line.

## NOTES

The output uses box drawing and arrow characters that need the console to use UTF-8 to display correctly.
Linux and macOS use UTF-8 by default but the Windows console uses a legacy code page unless changed, a warning is written on Windows when the console output encoding is not UTF-8.
The warning is not written in a remote session, the output is sent back to the client and displayed with its console encoding.
Set the console to UTF-8 with `[Console]::OutputEncoding = [Text.UTF8Encoding]::new()`, adding it to the PowerShell profile sets it for every session.

## RELATED LINKS

- [ConvertTo-PSRPPacket](./ConvertTo-PSRPPacket.md)
