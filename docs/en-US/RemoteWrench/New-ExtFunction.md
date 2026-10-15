---
document type: cmdlet
external help file: RemoteWrench.dll-Help.xml
HelpUri: https://www.github.com/jborean93/PowerShell-RemoteWrench/blob/main/docs/en-US/RemoteWrench/New-ExtFunction.md
Locale: en-US
Module Name: RemoteWrench
ms.date: ''
PlatyPS schema version: 2024-05-01
title: New-ExtFunction
---

# New-ExtFunction

## SYNOPSIS

Creates a function to define in the session entered with `Enter-ExtSession`.

## SYNTAX

### __AllParameterSets

```
New-ExtFunction [-Name] <string> [-ScriptBlock] <scriptblock> [<CommonParameters>]
```

## ALIASES

## DESCRIPTION

The `New-ExtFunction` cmdlet creates the definition of a function that `Enter-ExtSession` defines in the remote session it enters.
The function only runs in the remote session, use `New-ExtCallback` for a function that runs code on the client.

The script is sent to the remote session as text, it can't use the variables of the client except through `$using:`.
The values of `$using:` expressions are read when `New-ExtFunction` runs, not when the function is called, and are serialized to the remote session once when it is entered.
A reference type like a hashtable is shared by every call of the function in that session, changes made to it persist across calls but aren't sent back to the client.

A local function can also be passed to `Enter-ExtSession -Function` by its name, or from `Get-Command`.
`New-ExtFunction` is only needed to give it a different name, like `New-ExtFunction Get-Other ${function:Get-Thing}`.

## EXAMPLES

### Example 1: Define a function with a value from the client

```powershell
$logPath = 'C:\Logs\app.log'
$tail = New-ExtFunction Get-AppLog {
    param ([int]$Tail = 20)

    Get-Content -LiteralPath $using:logPath -Tail $Tail
}
Enter-ExtSession server -Function $tail
```

Defines `Get-AppLog` in the remote session, it reads the log path set on the client.

### Example 2: Define a local function under another name

```powershell
$sudo = New-ExtFunction sudo ${function:Invoke-Sudo}
Enter-ExtSession server -Function $sudo
```

Defines the local function `Invoke-Sudo` as `sudo` in the remote session.
Its parameters, including ones declared inline like `function Invoke-Sudo($Command) { }`, become the parameters of `sudo`.

## PARAMETERS

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

### -ScriptBlock

The script of the function.
Its param block, attributes and comment based help become the remote function's so tab completion and `Get-Help` work in the remote session.

The param block is evaluated in the remote session, its types and validation attributes need to work there.

It can be a function's scriptblock, like `${function:Get-Thing}`.
A filter runs for each pipeline input, a script with a `dynamicparam` block isn't supported.

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

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable,
-InformationAction, -InformationVariable, -OutBuffer, -OutVariable, -PipelineVariable,
-ProgressAction, -Verbose, -WarningAction, and -WarningVariable. For more information, see
[about_CommonParameters](https://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### RemoteWrench.Ext.ExtFunction

The function definition to pass to `Enter-ExtSession -Function`.

## NOTES

The function is an advanced function with the parameters and pipeline input of the script.
A script that isn't advanced keeps working the same, its parameters stay positional, other arguments are passed as `$args` and pipeline input as `$input`.

See [about_ExtSession](./about_ExtSession.md) for how the functions run in the remote session.

## RELATED LINKS

- [Enter-ExtSession](./Enter-ExtSession.md)
- [New-ExtCallback](./New-ExtCallback.md)
- [about_ExtSession](./about_ExtSession.md)
