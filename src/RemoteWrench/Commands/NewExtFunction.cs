using System;
using System.Management.Automation;
using RemoteWrench.Ext;

namespace RemoteWrench.Commands;

[Cmdlet(
    VerbsCommon.New, "ExtFunction"
)]
[OutputType(typeof(ExtFunction))]
public sealed class NewExtFunction : PSCmdlet
{
    [Parameter(
        Mandatory = true,
        Position = 0
    )]
    public string Name { get; set; } = "";

    [Parameter(
        Mandatory = true,
        Position = 1
    )]
    public ScriptBlock ScriptBlock { get; set; } = default!;

    protected override void EndProcessing()
    {
        ExtFunction function;
        try
        {
            ParsedScript script = ScriptParser.Parse(ScriptBlock, SessionState, $"script of function '{Name}'");
            function = new(Name, script);
        }
        catch (ArgumentException e)
        {
            ErrorRecord err = new(
                e,
                "InvalidExtFunction",
                ErrorCategory.InvalidArgument,
                Name);
            ThrowTerminatingError(err);
            return;
        }

        WriteObject(function);
    }
}
