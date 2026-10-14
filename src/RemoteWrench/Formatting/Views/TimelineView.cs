using System;
using System.Collections.Generic;
using System.Linq;

namespace RemoteWrench.Formatting.Views;

/// <summary>
/// One line per message or fragment. The column widths come from the protocol
/// so the output can be streamed, only the summary column grows with the
/// terminal. Narrow terminals drop the PSGuid and size columns.
/// </summary>
internal sealed class TimelineView : IPacketView
{
    private const int CompactWidth = 110;
    private const int MinSummaryWidth = 10;

    private readonly Palette _palette;
    private readonly List<Column> _columns;
    private bool _headerWritten;
    private int _index;

    public TimelineView(ViewOptions options)
    {
        _palette = new(options.NoColor);
        bool compact = options.Width < CompactWidth;

        // The longest packet name is CommandAck and the longest message type
        // RunspacePoolHostResponse.
        int messageWidth = Enum.GetNames(typeof(PSRPMessageType)).Max(n => n.Length);
        _columns =
        [
            new("#", 4, true, r => r.FirstOfPacket ? r.Index.ToString() : "", _ => _palette.Dim),
            new("Dir", 3, false, r => TextHelper.DirectionText(r.Direction), r => _palette.Direction(r.Direction)),
            new("Packet", 10, false, r => r.FirstOfPacket ? r.Packet.Type : "", _ => ""),
            .. compact
                ? Array.Empty<Column>()
                : [new("PSGuid", 8, false, r => r.FirstOfPacket ? TextHelper.ShortGuid(r.Packet.PSGuid) : "", _ => _palette.Yellow)],
            new("Message", messageWidth, false, r => r.MessageType, r => r.Kind == PacketRowKind.Fragment ? _palette.Dim : _palette.Blue),
            new("Obj:Frag", 11, false, r => r.Fragment, _ => _palette.Dim),
            .. compact
                ? Array.Empty<Column>()
                : [new("Size", 7, true, r => r.Size, _ => _palette.Dim)],
        ];

        int fixedWidth = _columns.Sum(c => c.Width + 1);
        _columns.Add(new(
            "Summary",
            Math.Max(options.Width - fixedWidth, MinSummaryWidth),
            false,
            r => r.Summary,
            r => r.Kind switch
            {
                PacketRowKind.Error => _palette.Red,
                PacketRowKind.Fragment or PacketRowKind.Control => _palette.Dim,
                _ => "",
            }));
    }

    public IEnumerable<string> Process(OutOfProcPacket packet)
    {
        if (!_headerWritten)
        {
            _headerWritten = true;
            string header = string.Join(" ", _columns.Select(c => TextHelper.Fit(c.Header, c.Width, c.AlignRight)));
            yield return _palette.Color(_palette.Bold, header.TrimEnd());
            yield return _palette.Color(_palette.Dim, new string('─', _columns.Sum(c => c.Width + 1) - 1));
        }

        _index++;
        foreach (PacketRow row in PacketRow.FromPacket(_index, packet))
        {
            IEnumerable<string> cells = _columns.Select(c =>
            {
                string value = TextHelper.Fit(c.Value(row), c.Width, c.AlignRight);
                string color = c.Color(row);
                return color.Length == 0 ? value : _palette.Color(color, value);
            });
            yield return string.Join(" ", cells).TrimEnd();
        }
    }

    private sealed record Column(
        string Header,
        int Width,
        bool AlignRight,
        Func<PacketRow, string> Value,
        Func<PacketRow, string> Color);
}
