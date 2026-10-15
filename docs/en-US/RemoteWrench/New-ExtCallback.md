---
document type: cmdlet
external help file: RemoteWrench.dll-Help.xml
HelpUri: https://www.github.com/jborean93/PowerShell-RemoteWrench/blob/main/docs/en-US/RemoteWrench/New-ExtCallback.md
Locale: en-US
Module Name: RemoteWrench
ms.date: ''
PlatyPS schema version: 2024-05-01
title: New-ExtCallback
---

# New-ExtCallback

## SYNOPSIS

Creates a function in the session entered with `Enter-ExtSession` that runs code on the client.

## SYNTAX

### __AllParameterSets

```
New-ExtCallback [-Name] <string> [-ClientScript] <scriptblock> [-ServerScript <scriptblock>]
 [<CommonParameters>]
```

## ALIASES

## DESCRIPTION

The `New-ExtCallback` cmdlet creates the definition of a callback, a function that `Enter-ExtSession` defines in the remote session which runs `-ClientScript` on the client when it is called.
The remote function waits while the client script runs, the console isn't reading console input so the client script can use it, for example to run an editor.

The client script is run like a command on the other side of the connection.
Without `-ServerScript` the remote function has the parameters of `-ClientScript`, its arguments and pipeline input are passed to the client script and the client script's output is the function's output, as it is written.
With `-ServerScript` the remote function runs it instead, it runs the client script with `Invoke-ExtCallback`, which has the parameters of `-ClientScript` and passes its pipeline input to it the same way.
See [about_ExtSession](./about_ExtSession.md) for more.

The client script runs in the session state it was created in, like any scriptblock, it can use the variables and functions of the script or module that created it.
To use the local variables of a function when it is defined, call `.GetNewClosure()` on the scriptblock.
The variable `$ExtCallbackContext` has the details of the call, see [about_ExtSession](./about_ExtSession.md).

Values sent between the client and the remote session are serialized like any remoting output.

> [!IMPORTANT]
> Treat everything the client script receives as untrusted input, its arguments and its pipeline input.
> The remote function is not the only way to call the client script.
> Any code running in the remote session, including code run by another user or process that can reach it, can send the same messages the remote function does.
> It can call any callback by name with any arguments, without the parameter types or validation of the remote function's param block or anything its server script checks.
> Validate the input in the client script itself, for example don't use a path from the server without checking it, and don't run it as code.

## EXAMPLES

### Example 1: Get a value from the client

```powershell
$callback = New-ExtCallback Get-ClientName { [Environment]::MachineName }
Enter-ExtSession server -Function $callback
```

`Get-ClientName` in the remote session outputs the name of the client.

### Example 2: Edit a remote file with a client editor

```powershell
$edit = New-ExtCallback Edit-RemoteFile -ServerScript {
    param ([Parameter(Mandatory)][string]$Path)

    $content = [System.IO.File]::ReadAllText($Path)
    $new = Invoke-ExtCallback -Content $content
    if ($null -ne $new) {
        [System.IO.File]::WriteAllText($Path, $new)
    }
} -ClientScript {
    param ($Content)

    $tempFile = New-TemporaryFile
    try {
        Set-Content -LiteralPath $tempFile -Value $Content -NoNewline
        Start-Process -FilePath code -ArgumentList '--wait', $tempFile -Wait -NoNewWindow
        Get-Content -LiteralPath $tempFile -Raw
    }
    finally {
        Remove-Item -LiteralPath $tempFile
    }
}
Enter-ExtSession server -Function $edit
```

`Edit-RemoteFile` reads the remote file, the client script edits it with VSCode and the server script writes the result back.

### Example 3: Pipe remote objects to the client

```powershell
$grid = New-ExtCallback Out-ClientGridView {
    param ([string]$Title = 'Remote')

    $input | Out-GridView -Title $Title -PassThru
}
Enter-ExtSession server -Function $grid
```

In the remote session, `Get-Service | Out-ClientGridView` shows the remote services in a grid view on the client and outputs the selected ones.

## PARAMETERS

### -ClientScript

The script to run on the client.
Its param block is the remote function's without `-ServerScript`, and `Invoke-ExtCallback`'s with one.
It receives the arguments and pipeline input of the remote function or `Invoke-ExtCallback`, its output and errors are sent to the server as they are written.
Its other streams, like warnings and verbose messages, are written to the client's console directly.
They follow the client's preferences, not the remote function's common parameters, and can't be redirected in the remote session, see [about_ExtSession](./about_ExtSession.md).

Run interactive programs with `Start-Process -NoNewWindow -Wait` so they use the console directly rather than through PowerShell's redirected output.

`$using:` isn't supported, the script runs on the client and already has access to the same session state.

The arguments and pipeline input it receives are untrusted, anything in the remote session can call it with any values, see the description.

```yaml
Type: System.Management.Automation.ScriptBlock
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 1
  IsRequired: true
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -Name

The name of the function in the remote session.
It can only contain letters, digits, underscores and dashes.

```yaml
Type: System.String
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 0
  IsRequired: true
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -ServerScript

The script of the remote function.
Its param block, attributes and comment based help become the remote function's.
It runs `-ClientScript` with `Invoke-ExtCallback`.

The script is sent to the remote session as text, it can use client values through `$using:` like `New-ExtFunction`.

```yaml
Type: System.Management.Automation.ScriptBlock
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

### RemoteWrench.Ext.ExtScriptCallback

The callback definition to pass to `Enter-ExtSession -Function`.

## NOTES

Callbacks only work when the function is run from the prompt of the session entered with `Enter-ExtSession`.
The client replies through a nested pipeline, which PowerShell only allows in a command run like the interactive prompt runs it.
A callback run any other way, like in a job, fails after 10 seconds with an error saying the client did not respond.

Ctrl+C while the client script runs stops the remote function, not the client script.
A client script reading pipeline input fails when that happens, one that runs for long without reading input should check `$ExtCallbackContext.CancellationToken`.

If the client script fails, the remote function, or `Invoke-ExtCallback`, fails with "Callback '<Name>' failed on the client: <message>" and the position in the client script.

## RELATED LINKS

- [Enter-ExtSession](./Enter-ExtSession.md)
- [New-ExtFunction](./New-ExtFunction.md)
- [about_ExtSession](./about_ExtSession.md)
