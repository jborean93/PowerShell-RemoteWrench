---
document type: cmdlet
external help file: RemoteWrench.dll-Help.xml
HelpUri: https://www.github.com/jborean93/PowerShell-RemoteWrench/blob/main/docs/en-US/RemoteWrench/New-ExtFileTransferCallback.md
Locale: en-US
Module Name: RemoteWrench
ms.date: ''
PlatyPS schema version: 2024-05-01
title: New-ExtFileTransferCallback
---

# New-ExtFileTransferCallback

## SYNOPSIS

Creates callbacks that copy files between the client and the session entered with `Enter-ExtSession`.

## SYNTAX

### __AllParameterSets

```
New-ExtFileTransferCallback [[-ClientPath] <string>] [-SendName <string>] [-ReceiveName <string>]
 [<CommonParameters>]
```

## ALIASES

## DESCRIPTION

The `New-ExtFileTransferCallback` cmdlet creates two callbacks for `Enter-ExtSession -Function` that copy files between the client and the remote session:

- `Send-ClientFile <Path> [<Destination>] [-Force] [-Compression <Deflate|None>]` copies remote files to the client. `-Path` supports wildcards and pipeline input like the output of `Get-ChildItem`.
- `Receive-ClientFile <Path> [<Destination>] [-Force] [-Compression <Deflate|None>]` copies client files to the remote session, `-Destination` defaults to the current location.

They can only copy files, not directories.
A `-Destination` that is a directory gets the files copied into it, otherwise the file is copied to that path.
A file that already exists isn't overwritten unless `-Force` is used.
`Send-ClientFile` outputs an object with the `Source`, client `Destination` and `Length` of each file, `Receive-ClientFile` outputs the remote file.

The client paths are relative to the client path of the callbacks, `-ClientPath`, the remote session can't read or write a client file outside of it.
The paths come from the remote session and, like any callback, anything running in the remote session can call them, see [about_ExtSession](./about_ExtSession.md).
Use a client path with only the files the remote session should be able to read and write.

Files are copied in 64KB chunks and only a few MB are sent ahead of what the other side has written, so a file of any size can be copied without holding it in memory.
Each chunk is compressed with Deflate unless `-Compression None` is used, which is faster for files that are already compressed, like archives or media.

The copies are slower than a tool made for copying files, like `scp`, because every chunk goes through PowerShell remoting with its overhead.
Locally, it copies about 20 to 50MB a second depending on the direction and how well the file compresses, over a network it is usually limited by the network.

## EXAMPLES

### Example 1: Copy files between the client and a remote session

```powershell
$transfer = New-ExtFileTransferCallback -ClientPath ~/Downloads
Enter-ExtSession server -Function $transfer
```

In the remote session `Get-ChildItem C:\Logs\*.log | Send-ClientFile -Destination logs` copies the remote log files into `~/Downloads/logs` on the client.
`Receive-ClientFile tool.zip C:\Temp` copies `~/Downloads/tool.zip` from the client to `C:\Temp` in the remote session.

### Example 2: Use other names for the callbacks

```powershell
$transfer = New-ExtFileTransferCallback -SendName Copy-ToClient -ReceiveName Copy-FromClient
Enter-ExtSession server -Function $transfer
```

The callbacks are defined as `Copy-ToClient` and `Copy-FromClient`, with the current directory as the client path.

### Example 3: Copy without progress

```powershell
$transfer = New-ExtFileTransferCallback
Enter-ExtSession server -Function $transfer
```

In the remote session, either of these copies the file without writing progress, which is a little faster:

```powershell
Send-ClientFile C:\Logs\app.log -ProgressAction SilentlyContinue

$ProgressPreference = 'SilentlyContinue'
Send-ClientFile C:\Logs\app.log
```

The progress is written in the remote session, setting `$ProgressPreference` on the client doesn't change it.
`-ProgressAction` needs PowerShell 7.4 or newer in the remote session, use `$ProgressPreference` with Windows PowerShell.

## PARAMETERS

### -ClientPath

The client directory the callbacks copy files to and from, the remote session can't use a client path outside of it.
It defaults to the current location.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 0
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -ReceiveName

The name of the callback that copies client files to the remote session, defaults to `Receive-ClientFile`.

```yaml
Type: System.String
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

### -SendName

The name of the callback that copies remote files to the client, defaults to `Send-ClientFile`.

```yaml
Type: System.String
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

## OUTPUTS

### RemoteWrench.Ext.ExtSendFileCallback

The callback that copies remote files to the client, pass it to `Enter-ExtSession -Function`.

### RemoteWrench.Ext.ExtReceiveFileCallback

The callback that copies client files to the remote session, pass it to `Enter-ExtSession -Function`.

## NOTES

The client path is checked after the paths are combined, so `..` can't reach outside of it.
A symbolic link inside the client path that points outside of it is followed, don't use a client path with links the remote session shouldn't follow.

Copying a file reports its progress in the remote session with `Write-Progress`, see Example 3 to turn it off.
`$ProgressPreference` set in a function or script that calls the callback doesn't reach it, as with any module command, set it globally in the remote session or use `-ProgressAction`.
A file that fails to copy part way through is removed.

## RELATED LINKS

- [Enter-ExtSession](./Enter-ExtSession.md)
- [New-ExtCallback](./New-ExtCallback.md)
- [about_ExtSession](./about_ExtSession.md)
