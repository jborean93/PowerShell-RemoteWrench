using System;
using System.Management.Automation;

namespace RemoteWrench.Commands;

[Cmdlet(
    VerbsData.ConvertTo, "PSRPPacket"
)]
[OutputType(typeof(OutOfProcPacket))]
public sealed class ConvertToPSRPPacket : PSCmdlet
{
    private readonly PSRPFragmentPool _fragmentPool = new();

    [Parameter(
        Mandatory = true,
        Position = 0,
        ValueFromPipeline = true
    )]
    [AllowEmptyString]
    public string[] InputObject { get; set; } = [];

    protected override void ProcessRecord()
    {
        foreach (string line in InputObject)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            OutOfProcPacket packet;
            try
            {
                packet = OutOfProcPacket.Parse(line, _fragmentPool);
            }
            catch (Exception ex)
            {
                ErrorRecord errorRecord = new(
                    ex,
                    "ParseError",
                    ErrorCategory.InvalidData,
                    line)
                {
                    ErrorDetails = new($"Failed to parse line '{line}': {ex.Message}")
                };

                WriteError(errorRecord);
                continue;
            }

            WriteObject(packet);
        }
    }
}
