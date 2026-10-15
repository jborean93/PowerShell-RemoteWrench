using System;
using System.Management.Automation;
using RemoteWrench.Ext;

namespace RemoteWrench.Commands;

[Cmdlet(
    VerbsCommon.New, "ExtCallback"
)]
[OutputType(typeof(ExtScriptCallback))]
public sealed class NewExtCallback : PSCmdlet
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
    public ScriptBlock ClientScript { get; set; } = default!;

    [Parameter]
    public ScriptBlock? ServerScript { get; set; }

    protected override void EndProcessing()
    {
        ExtScriptCallback callback;
        try
        {
            ParsedScript? serverScript = ServerScript is null
                ? null
                : ScriptParser.Parse(ServerScript, SessionState, $"server script of callback '{Name}'");
            callback = new(Name, ClientScript, SessionState, serverScript);
        }
        catch (ArgumentException e)
        {
            ErrorRecord err = new(
                e,
                "InvalidExtCallback",
                ErrorCategory.InvalidArgument,
                Name);
            ThrowTerminatingError(err);
            return;
        }

        WriteObject(callback);
    }
}
