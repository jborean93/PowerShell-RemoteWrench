using System;
using System.Collections.Generic;

namespace RemoteWrench.Formatting;

internal enum PacketRowKind
{
    Message,
    Error,
    Fragment,
    Control,
}

/// <summary>
/// A single event of a packet, a completed message, a fragment of a message
/// still being received, or a control packet like a Command or DataAck.
/// </summary>
internal sealed record PacketRow(
    int Index,
    bool FirstOfPacket,
    OutOfProcPacket Packet,
    PSRPDestination? Direction,
    string MessageType,
    string Fragment,
    string Size,
    string Summary,
    PacketRowKind Kind,
    PSRPMessage? Message,
    DecodedMessage? Decoded,
    PSRPFragment? SourceFragment)
{
    public static IEnumerable<PacketRow> FromPacket(int index, OutOfProcPacket packet)
    {
        if (packet.Fragments.Length == 0)
        {
            yield return new(
                index,
                true,
                packet,
                packet.Destination,
                "",
                "",
                "",
                ControlSummary(packet),
                PacketRowKind.Control,
                null,
                null,
                null);
            yield break;
        }

        // Each fragment with the End flag completed the next message.
        int messageIdx = 0;
        bool first = true;
        foreach (PSRPFragment fragment in packet.Fragments)
        {
            if (fragment.End && messageIdx < packet.Messages.Length)
            {
                PSRPMessage message = packet.Messages[messageIdx++];
                DecodedMessage decoded = MessageDecoder.Decode(message);
                yield return new(
                    index,
                    first,
                    packet,
                    message.Destination,
                    message.MessageType.ToString(),
                    TextHelper.FragmentText(fragment),
                    TextHelper.FormatSize(MessageDecoder.MessageSize(message)),
                    decoded.Summary,
                    decoded.IsError ? PacketRowKind.Error : PacketRowKind.Message,
                    message,
                    decoded,
                    fragment);
            }
            else
            {
                yield return new(
                    index,
                    first,
                    packet,
                    packet.Destination,
                    "‹fragment›",
                    TextHelper.FragmentText(fragment),
                    TextHelper.FormatSize(fragment.Length),
                    fragment.Start ? "start of a fragmented message" : "continued",
                    PacketRowKind.Fragment,
                    null,
                    null,
                    fragment);
            }

            first = false;
        }
    }

    private static string ControlSummary(OutOfProcPacket packet) => packet.Type switch
    {
        "Command" => "create pipeline",
        "Signal" => "stop pipeline",
        "Close" => packet.PSGuid == Guid.Empty ? "close runspace pool" : "close pipeline",
        _ => "",
    };
}
