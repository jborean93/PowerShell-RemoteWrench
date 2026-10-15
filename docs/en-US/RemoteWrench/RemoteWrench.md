---
document type: module
Help Version: 1.0.0.0
HelpInfoUri: ''
Locale: en-US
Module Guid: 2be3f01a-b9a4-4e27-842d-9d3f5d9a2ed3
Module Name: RemoteWrench
ms.date: ''
PlatyPS schema version: 2024-05-01
---

# RemoteWrench Module

## Description

PowerShell module for working with remote PSSessions.

## RemoteWrench Cmdlets

### [ConvertTo-PSRPPacket](ConvertTo-PSRPPacket.md)

Converts PSRP Out of Process protocol strings into parsed packet objects.

### [Enter-ExtSession](Enter-ExtSession.md)

Starts an interactive session with a remote computer that has functions from the client.

### [Format-PSRPPacket](Format-PSRPPacket.md)

Formats PSRP packet objects into human-readable output.

### [New-ExtCallback](New-ExtCallback.md)

Creates a function in the session entered with `Enter-ExtSession` that runs code on the client.

### [New-ExtEditCallback](New-ExtEditCallback.md)

Creates a callback that edits a file in the session entered with `Enter-ExtSession` with an editor on the client.

### [New-ExtFileTransferCallback](New-ExtFileTransferCallback.md)

Creates callbacks that copy files between the client and the session entered with `Enter-ExtSession`.

### [New-ExtFunction](New-ExtFunction.md)

Creates a function to define in the session entered with `Enter-ExtSession`.
