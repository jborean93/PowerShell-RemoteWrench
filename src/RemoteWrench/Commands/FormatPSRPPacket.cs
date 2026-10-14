using System;
using System.Management.Automation;
using System.Management.Automation.Remoting;
using System.Runtime.InteropServices;
using System.Text;
using RemoteWrench.Formatting;

namespace RemoteWrench.Commands;

[Cmdlet(
    VerbsCommon.Format, "PSRPPacket"
)]
[OutputType(typeof(string))]
public sealed class FormatPSRPPacket : PSCmdlet
{
    private const int DefaultWidth = 120;
    private const int Utf8CodePage = 65001;

    private IPacketView? _view;

    [Parameter(
        Mandatory = true,
        ValueFromPipeline = true
    )]
    public OutOfProcPacket[] Packet { get; set; } = [];

    [Parameter]
    [Alias("NoColour")]
    public SwitchParameter NoColor { get; set; }

    [Parameter]
    public PSRPPacketView View { get; set; } = PSRPPacketView.Timeline;

    [Parameter]
    [ValidateRange(40, 1000)]
    public int Width { get; set; }

    protected override void BeginProcessing()
    {
        WarnIfConsoleNotUtf8();
        _view = PacketViewFactory.Create(View, new ViewOptions(NoColor, GetWidth()));
    }

    protected override void ProcessRecord()
    {
        // Created in BeginProcessing.
        IPacketView view = _view!;

        foreach (OutOfProcPacket item in Packet)
        {
            foreach (string line in view.Process(item))
            {
                WriteObject(line);
            }
        }
    }

    /// <summary>
    /// The views use box drawing and arrow characters that are garbled when
    /// written with a legacy code page. Linux and macOS default to UTF-8 but
    /// the Windows console uses the OEM code page unless changed.
    /// </summary>
    private void WarnIfConsoleNotUtf8()
    {
        // $PSSenderInfo is only set in a remote session, its output is sent
        // back to the client so the console of this process does not matter.
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ||
            SessionState.PSVariable.GetValue("PSSenderInfo") is PSSenderInfo)
        {
            return;
        }

        int codePage;
        string encodingName;
        try
        {
            Encoding encoding = Console.OutputEncoding;
            codePage = encoding.CodePage;
            encodingName = encoding.WebName;
        }
        catch (Exception)
        {
            // A process without a console may not be able to get it.
            return;
        }

        if (codePage != Utf8CodePage)
        {
            WriteWarning(
                $"The console output encoding is {encodingName} (code page {codePage}) and not UTF-8, the box " +
                "drawing and arrow characters in the output may not display correctly. Set the console to " +
                "UTF-8 with '[Console]::OutputEncoding = [Text.UTF8Encoding]::new()'.");
        }
    }

    private int GetWidth()
    {
        if (Width > 0)
        {
            return Width;
        }

        try
        {
            // PowerShell wraps the host so UI and RawUI are never null, a host
            // without them throws instead.
            int hostWidth = Host.UI.RawUI.BufferSize.Width;
            if (hostWidth > 0)
            {
                return hostWidth;
            }
        }
        catch (Exception)
        {
            // Hosts without a console, or with redirected output, may not
            // implement or be able to get the buffer size.
        }

        return DefaultWidth;
    }
}
