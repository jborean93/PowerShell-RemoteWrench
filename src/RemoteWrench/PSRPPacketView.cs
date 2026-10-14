namespace RemoteWrench;

/// <summary>
/// The layouts Format-PSRPPacket can render, all are streamed.
/// </summary>
public enum PSRPPacketView
{
    /// <summary>One line per packet, message, or fragment in the order received.</summary>
    Timeline,
    /// <summary>One line per message grouped by runspace pool and pipeline.</summary>
    Grouped,
    /// <summary>Grouped with the fragments and decoded fields of each message.</summary>
    GroupedDetail,
}
