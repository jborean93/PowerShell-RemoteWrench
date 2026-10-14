using System;
using System.Collections.Generic;
using System.Linq;

namespace RemoteWrench.Formatting.Views;

/// <summary>
/// The messages grouped under their runspace pool and pipeline, streamed in
/// the order received. A header is written whenever the pool or pipeline
/// changes, so concurrent pipelines show as alternating runs with a
/// "continued" header rather than being reordered. The detail mode adds the
/// decoded fields of each message.
/// </summary>
internal sealed class GroupedView : IPacketView
{
    private const int MaxDetailWidth = 120;
    private const string PoolPrefix = "│ ";
    private const string PipelinePrefix = "│  │ ";

    private readonly Palette _palette;
    private readonly bool _detail;
    private readonly int _width;
    private readonly int _typeWidth;
    private readonly HashSet<Guid> _pipelines = [];

    // The earlier fragments of a message still being received, keyed like
    // the parser's fragment pool.
    private readonly Dictionary<(Guid, ulong), List<PacketRow>> _fragments = [];
    private Guid? _lastPool;
    private Guid? _currentPool;
    private Guid? _currentPipeline;
    private int _index;

    public GroupedView(ViewOptions options, bool detail)
    {
        _palette = new(options.NoColor);
        _detail = detail;
        _width = options.Width;
        _typeWidth = Enum.GetNames(typeof(PSRPMessageType)).Max(n => n.Length);
    }

    public IEnumerable<string> Process(OutOfProcPacket packet)
    {
        _index++;
        foreach (PacketRow row in PacketRow.FromPacket(_index, packet))
        {
            List<PacketRow>? previousFragments = null;
            if (_detail && row.SourceFragment is PSRPFragment fragment && !(fragment.Start && fragment.End))
            {
                (Guid, ulong) key = (row.Packet.PSGuid, fragment.ObjectId);
                if (row.Kind == PacketRowKind.Fragment)
                {
                    if (fragment.Start)
                    {
                        _fragments[key] = [];
                    }
                    if (_fragments.TryGetValue(key, out List<PacketRow>? received))
                    {
                        received.Add(row);
                    }
                }
                else if (_fragments.TryGetValue(key, out List<PacketRow>? received))
                {
                    _fragments.Remove(key);
                    previousFragments = received;
                }
            }

            if (!TryGetGroup(row, out Guid pool, out Guid? pipeline))
            {
                continue;
            }

            if (pool != _currentPool)
            {
                if (_currentPool is not null)
                {
                    yield return "";
                }
                yield return $"{_palette.Bold}RunspacePool{_palette.Reset} {_palette.Color(_palette.Yellow, pool.ToString())}";
                _currentPool = pool;
                _currentPipeline = null;
            }

            if (pipeline is Guid pid && pid != _currentPipeline)
            {
                string continued = _pipelines.Add(pid) ? "" : _palette.Color(_palette.Dim, " (continued)");
                yield return $"{_palette.Color(_palette.Dim, "├─ ")}{_palette.Bold}Pipeline{_palette.Reset} " +
                    $"{_palette.Color(_palette.Yellow, pid.ToString())}{continued}";
            }
            _currentPipeline = pipeline;

            string prefix = pipeline is null ? PoolPrefix : PipelinePrefix;
            yield return _palette.Color(_palette.Dim, prefix) + EntryLine(row, prefix.Length);

            if (_detail)
            {
                foreach (string line in DetailLines(row, prefix, previousFragments))
                {
                    yield return line;
                }
            }
        }
    }

    private bool TryGetGroup(PacketRow row, out Guid pool, out Guid? pipeline)
    {
        pipeline = null;
        if (row.Message is PSRPMessage message)
        {
            // Some server messages, like its SessionCapability, have no
            // runspace pool id and belong to the pool already in use.
            pool = message.RunspacePoolId == Guid.Empty && _lastPool is Guid last
                ? last
                : message.RunspacePoolId;
            _lastPool = pool;
            if (message.PipelineId != Guid.Empty)
            {
                pipeline = message.PipelineId;
            }
            return true;
        }

        // Only the stop and close requests are shown, the acks and Command are
        // implied by the messages around them.
        pool = _lastPool ?? Guid.Empty;
        if (row.Kind == PacketRowKind.Control && row.Packet.Type is "Signal" or "Close")
        {
            if (_pipelines.Contains(row.Packet.PSGuid))
            {
                pipeline = row.Packet.PSGuid;
                return true;
            }
            return row.Packet.PSGuid == Guid.Empty;
        }

        return false;
    }

    private string EntryLine(PacketRow row, int prefixLength)
    {
        string arrow = _palette.Color(_palette.Direction(row.Direction), TextHelper.Arrow(row.Direction));
        int typeWidth = _typeWidth + (PipelinePrefix.Length - prefixLength);
        if (row.Message is null)
        {
            return $"{arrow} {_palette.Color(_palette.Dim, $"{row.Packet.Type} ({row.Summary})")}";
        }

        int summaryWidth = _width - prefixLength - 2 - typeWidth - 1;
        string summary = TextHelper.Truncate(row.Summary, summaryWidth);
        return $"{arrow} {_palette.Color(_palette.Blue, row.MessageType.PadRight(typeWidth))} " +
            (row.Kind == PacketRowKind.Error ? _palette.Color(_palette.Red, summary) : summary);
    }

    private IEnumerable<string> DetailLines(PacketRow row, string prefix, List<PacketRow>? previousFragments)
    {
        if (row.Decoded is not DecodedMessage decoded)
        {
            yield break;
        }

        // The fields line up under the message type.
        string indent = _palette.Color(_palette.Dim, prefix) + "    ";
        int width = Math.Min(_width, MaxDetailWidth) - prefix.Length - 4;
        if (previousFragments is null)
        {
            string meta = $"#{row.Index} · {row.Packet.Type} · Obj {row.Fragment} · {row.Size}";
            yield return indent + _palette.Color(_palette.Dim, meta);
        }
        else
        {
            // Each fragment with the packet it was received in, the last one
            // also has the size of the whole message.
            foreach (PacketRow fragmentRow in previousFragments)
            {
                string meta = $"#{fragmentRow.Index} · {fragmentRow.Packet.Type} · Obj {fragmentRow.Fragment} · {fragmentRow.Size}";
                yield return indent + _palette.Color(_palette.Dim, meta);
            }

            string lastMeta = $"#{row.Index} · {row.Packet.Type} · Obj {row.Fragment} · " +
                $"{TextHelper.FormatSize(row.SourceFragment!.Value.Length)} · {row.Size} total";
            yield return indent + _palette.Color(_palette.Dim, lastMeta);
        }

        int keyWidth = decoded.Fields.Count == 0 ? 0 : decoded.Fields.Max(f => f.Key.Length);
        foreach (KeyValuePair<string, string> field in decoded.Fields)
        {
            string key = field.Key;
            string value = field.Value;
            string valueColor = decoded.IsError && key is "Error" or "Message" ? _palette.Red : "";
            bool first = true;
            foreach (string line in TextHelper.Wrap(value, width - keyWidth - 2))
            {
                string keyText = first ? key.PadRight(keyWidth) : new string(' ', keyWidth);
                yield return $"{indent}{_palette.Color(_palette.Dim, keyText)}  " +
                    (valueColor.Length == 0 ? line : _palette.Color(valueColor, line));
                first = false;
            }
        }

        if (decoded.Tree is ClixmlNode tree)
        {
            foreach (string line in PlainTree.Render(tree, width, _palette))
            {
                yield return indent + line;
            }
        }
    }
}
