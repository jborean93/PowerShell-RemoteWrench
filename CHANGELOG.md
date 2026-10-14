# Changelog for RemoteWrench

## v0.2.0 - TBD

## v0.1.0 - 2026-10-15

+ Initial version
+ Added `ConvertTo-PSRPPacket` and `Format-PSRPPacket` to parse and display PSRP Out of Process packets
  + `Format-PSRPPacket -View` selects the `Timeline` of the raw packet exchange, the `Grouped` PSRP messages of each runspace pool and pipeline, or `GroupedDetail` with the fragments and decoded fields of each message, all of them stream so they can follow a log with `Get-Content -Wait`
  + Each message is decoded into a summary and its fields, like the command line of a `CreatePipeline`
