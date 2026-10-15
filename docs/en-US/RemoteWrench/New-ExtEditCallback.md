---
document type: cmdlet
external help file: RemoteWrench.dll-Help.xml
HelpUri: https://www.github.com/jborean93/PowerShell-RemoteWrench/blob/main/docs/en-US/RemoteWrench/New-ExtEditCallback.md
Locale: en-US
Module Name: RemoteWrench
ms.date: ''
PlatyPS schema version: 2024-05-01
title: New-ExtEditCallback
---

# New-ExtEditCallback

## SYNOPSIS

Creates a callback that edits a file in the session entered with `Enter-ExtSession` with an editor on the client.

## SYNTAX

### __AllParameterSets

```
New-ExtEditCallback [[-Name] <string>] [-Editor <string>] [<CommonParameters>]
```

## ALIASES

## DESCRIPTION

The `New-ExtEditCallback` cmdlet creates a callback for `Enter-ExtSession -Function` that edits a remote file with an editor on the client.
In the remote session, `PSEdit <Path>` copies the file to a temporary file on the client with the same name and opens it in the editor.
When the editor exits, the file is written back to the remote session if it changed, a file that doesn't exist is created.
If it didn't change, or the editor exits with a failing exit code like `:cq` in vim, the remote file is left as it was.

The editor is the first of:

- `-Editor`
- `$env:VISUAL`
- `$env:EDITOR`
- On Windows, the edit verb of the file's type, otherwise `notepad.exe`
- On other platforms, the first of `editor`, `nano` or `vi` that is found

`-Editor`, `$env:VISUAL` and `$env:EDITOR` can include arguments, like `code --wait`, the file path is added after them.
Quote the executable if its path has spaces.
The editor is found when the callback is created, so a missing editor is an error before entering the session.
Changes to `$env:VISUAL` or `$env:EDITOR` afterwards don't apply to the callback.

The editor must not return until the file has been edited and closed, the file is read back as soon as it does.
A GUI editor that passes the file to an existing window returns straight away, use an option that waits like `code --wait`.

## EXAMPLES

### Example 1: Edit remote files with the client's editor

```powershell
$edit = New-ExtEditCallback
Enter-ExtSession server -Function $edit
```

In the remote session `PSEdit C:\inetpub\wwwroot\web.config` edits the file with the client's editor.

### Example 2: Edit with VSCode

```powershell
$edit = New-ExtEditCallback Edit-RemoteFile -Editor 'code --wait'
Enter-ExtSession server -Function $edit
```

`Edit-RemoteFile` in the remote session edits the file with VSCode, `--wait` keeps it from returning before the file is closed.

## PARAMETERS

### -Editor

The editor command to use instead of `$env:VISUAL`, `$env:EDITOR` or the platform default.
It can include arguments, the file path is added after them.

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

### -Name

The name of the function in the remote session, defaults to `PSEdit`.

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

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable,
-InformationAction, -InformationVariable, -OutBuffer, -OutVariable, -PipelineVariable,
-ProgressAction, -Verbose, -WarningAction, and -WarningVariable. For more information, see
[about_CommonParameters](https://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### RemoteWrench.Ext.ExtEditCallback

The callback that edits a remote file, pass it to `Enter-ExtSession -Function`.

## NOTES

The editor runs in the client's console while the remote command waits, a console editor like vim or nano works like it does locally.
Ctrl+C in the remote session stops the remote function, not the editor, the edit is discarded when the editor exits.

The file is copied as one object, it is meant for files of a size an editor opens, use `New-ExtFileTransferCallback` to copy large files.
The client only uses the file name of the remote path for the temporary file, the remote session can't choose where it is written.

## RELATED LINKS

- [Enter-ExtSession](./Enter-ExtSession.md)
- [New-ExtCallback](./New-ExtCallback.md)
- [New-ExtFileTransferCallback](./New-ExtFileTransferCallback.md)
