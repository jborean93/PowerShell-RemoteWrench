---
document type: cmdlet
external help file: RemoteWrench.dll-Help.xml
HelpUri: https://www.github.com/jborean93/PowerShell-RemoteWrench/blob/main/docs/en-US/RemoteWrench/Enter-ExtSession.md
Locale: en-US
Module Name: RemoteWrench
ms.date: ''
PlatyPS schema version: 2024-05-01
title: Enter-ExtSession
---

# Enter-ExtSession

## SYNOPSIS

Starts an interactive session with a remote computer that has functions from the client.

## SYNTAX

### New-PSSession Dynamic Parameters (Default)

```
Enter-ExtSession [-Function <Object[]>] [<CommonParameters>]
```

The parameters of this parameter set are defined dynamically based on [New-PSSession](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/new-pssession).
`Get-Command Enter-ExtSession -Syntax` shows them.

### SessionFactory

```
Enter-ExtSession [-SessionFactory] <scriptblock> [-Function <Object[]>] [<CommonParameters>]
```

## ALIASES

## DESCRIPTION

The `Enter-ExtSession` cmdlet enters an interactive remote session like `Enter-PSSession`, with extension functions defined in it.
They can be local functions given by name, or definitions from `New-ExtFunction` and `New-ExtCallback`.
Callbacks from `New-ExtCallback` run code on the client when they are called in the remote session.
Anything running in the remote session can call a callback, not only the function defined for it, treat what a callback receives as untrusted, see [about_ExtSession](./about_ExtSession.md).

`Enter-ExtSession` also has the parameters of `New-PSSession` that create a session, like `-ComputerName`, `-Credential`, `-HostName` or `-SessionOption`, and they work the same way.
They come from the `New-PSSession` of the PowerShell it runs in, see [New-PSSession](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/new-pssession) for more details on what can be used and how.
They aren't listed here in the help due to them being defined as dynamic parameters, use `Get-Command Enter-ExtSession -Syntax` shows them.
For any other way of creating a session, like a custom transport, use the `-SessionFactory` scriptblock to create the PSSession.

`Enter-ExtSession` owns the session, so unlike `Enter-PSSession` it can't enter an existing one.
The session is closed when it is exited with `exit` or `Exit-PSSession` and removed from `Get-PSSession`.

The current PowerShell host/console must support entering a remote session, like the PowerShell console does.

## EXAMPLES

### Example 1: Enter a session with a callback

```powershell
$callback = New-ExtCallback Get-ClientName { [Environment]::MachineName }
Enter-ExtSession server -Function $callback
```

Enters a session on `server` where `Get-ClientName` outputs the name of the client.

### Example 2: Define local functions by name

```powershell
Set-Alias -Name sudo -Value Invoke-Sudo
Enter-ExtSession server -Function sudo, Get-ServiceStatus
```

Defines the local functions in the remote session without reloading them by hand.
`Get-ServiceStatus` is defined with its name, the alias `sudo` defines `Invoke-Sudo` with the name `sudo`.

### Example 3: Connect with the parameters of New-PSSession

```powershell
Enter-ExtSession -HostName admin@server -Port 2222 -KeyFilePath ~/.ssh/id_ed25519 -Function sudo
Enter-ExtSession server -Credential $cred -UseSSL -Function sudo
```

Enters a session over SSH, then over WinRM with HTTPS and explicit credentials, the parameters are the same as `New-PSSession`'s.

### Example 4: Create the session with a scriptblock

```powershell
Enter-ExtSession { New-CustomSession -Endpoint foo } -Function sudo
```

The scriptblock can use any command that outputs a `PSSession` or remote `Runspace`, like one for a custom transport, with the variables of the caller.

## PARAMETERS

### -Function

The functions to define in the remote session.
They are the names of local functions, definitions from `New-ExtFunction` or `New-ExtCallback`, or functions from `Get-Command`.
A name can also be an alias to a function, the function is defined in the remote session with the alias name.
A value of another type, or one with the same name as an earlier one, writes an error and is skipped.

```yaml
Type: System.Object[]
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: Named
  IsRequired: false
  ValueFromPipeline: true
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### -SessionFactory

A scriptblock that creates the session to enter.
It must output one `PSSession` or remote `Runspace`, it is opened if it isn't already.

The session is closed when it is exited, don't output a session that is used elsewhere.

```yaml
Type: System.Management.Automation.ScriptBlock
DefaultValue: ''
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: SessionFactory
  Position: 0
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

### System.Object[]

The function definitions to define in the remote session, see `-Function`.

## OUTPUTS

### System.Void

This cmdlet does not output anything, the console enters the remote session.

## NOTES

A local function, given by name or from `Get-Command`, is defined from its script, `$using:` values in it are read when `Enter-ExtSession` runs.
Functions with a `dynamicparam` block aren't supported, the remote function only has the parameters of the param block.
Anything it uses from its module, like private functions or variables, isn't available in the remote session.

The functions are defined in a module named `RemoteWrench.Ext` in the remote session, see [about_ExtSession](./about_ExtSession.md).

## RELATED LINKS

- [New-ExtFunction](./New-ExtFunction.md)
- [New-ExtCallback](./New-ExtCallback.md)
- [about_ExtSession](./about_ExtSession.md)
- [Enter-PSSession](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/enter-pssession)
- [New-PSSession](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/new-pssession)
