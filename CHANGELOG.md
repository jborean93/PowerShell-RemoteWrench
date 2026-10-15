# Changelog for RemoteWrench

## v0.2.0 - TBD

+ Added `Enter-ExtSession` to enter a remote session with extension functions defined in it
  + It has the parameters of `New-PSSession` to create the session, like `-ComputerName` or `-HostName`, a `-SessionFactory` scriptblock can create it any other way, like with a custom transport
  + The session is closed on exit and removed from `Get-PSSession`
  + `New-ExtFunction` defines a function that runs in the remote session from any scriptblock, including a function's like `${function:Get-Thing}`, `$using:` values are supported
  + A local function can also be passed to `-Function` from `Get-Command` or by its name, or by the name of an alias to it which defines it with the alias name
  + `New-ExtCallback` defines a callback, a function in the remote session that runs a script on the client like a command, with its parameters, pipeline input and streaming output, an optional server script runs it with `Invoke-ExtCallback`
  + The functions are advanced functions that accept pipeline input, filters are supported
  + `New-ExtFileTransferCallback` creates the `Send-ClientFile` and `Receive-ClientFile` callbacks to copy files between the client and the remote session, limited to a client directory, with Deflate compression by default
  + `New-ExtEditCallback` creates the `PSEdit` callback to edit a remote file with an editor on the client

## v0.1.0 - 2026-10-15

+ Initial version
+ Added `ConvertTo-PSRPPacket` and `Format-PSRPPacket` to parse and display PSRP Out of Process packets
  + `Format-PSRPPacket -View` selects the `Timeline` of the raw packet exchange, the `Grouped` PSRP messages of each runspace pool and pipeline, or `GroupedDetail` with the fragments and decoded fields of each message, all of them stream so they can follow a log with `Get-Content -Wait`
  + Each message is decoded into a summary and its fields, like the command line of a `CreatePipeline`
