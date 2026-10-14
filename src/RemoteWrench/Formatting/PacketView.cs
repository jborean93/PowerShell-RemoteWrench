using System.Collections.Generic;
using RemoteWrench.Formatting.Views;

namespace RemoteWrench.Formatting;

internal sealed record ViewOptions(bool NoColor, int Width);

/// <summary>
/// Renders packets as text as each one is received.
/// </summary>
internal interface IPacketView
{
    IEnumerable<string> Process(OutOfProcPacket packet);
}

internal static class PacketViewFactory
{
    public static IPacketView Create(PSRPPacketView view, ViewOptions options) => view switch
    {
        PSRPPacketView.Grouped => new GroupedView(options, detail: false),
        PSRPPacketView.GroupedDetail => new GroupedView(options, detail: true),
        _ => new TimelineView(options),
    };
}
