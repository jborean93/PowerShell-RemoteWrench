using System;
using System.IO;
using System.Management.Automation;
using RemoteWrench.Ext;

namespace RemoteWrench.Commands;

[Cmdlet(
    VerbsCommon.New, "ExtFileTransferCallback"
)]
[OutputType(typeof(ExtSendFileCallback), typeof(ExtReceiveFileCallback))]
public sealed class NewExtFileTransferCallback : PSCmdlet
{
    [Parameter(
        Position = 0
    )]
    public string? ClientPath { get; set; }

    [Parameter]
    public string SendName { get; set; } = "Send-ClientFile";

    [Parameter]
    public string ReceiveName { get; set; } = "Receive-ClientFile";

    protected override void EndProcessing()
    {
        string clientPath = string.IsNullOrEmpty(ClientPath)
            ? SessionState.Path.CurrentFileSystemLocation.ProviderPath
            : SessionState.Path.GetUnresolvedProviderPathFromPSPath(ClientPath);
        if (!Directory.Exists(clientPath))
        {
            ThrowTerminatingError(new(
                new DirectoryNotFoundException($"The client path '{clientPath}' is not a directory that exists."),
                "ClientPathNotFound",
                ErrorCategory.ObjectNotFound,
                clientPath));
            return;
        }

        ExtSendFileCallback send;
        ExtReceiveFileCallback receive;
        try
        {
            send = new(SendName, clientPath);
            receive = new(ReceiveName, clientPath);
        }
        catch (ArgumentException e)
        {
            ThrowTerminatingError(new(
                e,
                "InvalidExtFileTransferCallback",
                ErrorCategory.InvalidArgument,
                null));
            return;
        }

        WriteObject(send);
        WriteObject(receive);
    }
}
