using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;
using System.Xml.Linq;
#if NET
using System.Buffers;
using System.Runtime.InteropServices;
#endif

namespace RemoteWrench;

public readonly record struct OutOfProcPacket(
    string Type,
    Guid PSGuid,
    string? Stream,
    PSRPFragment[] Fragments,
    PSRPMessage[] Messages,
    string Raw,
    PSRPDestination? Destination)
{
    private const int FragmentHeaderLength = 21;
    private const int MessageHeaderLength = 40;

    private static ReadOnlySpan<byte> Utf8Bom => [0xEF, 0xBB, 0xBF];

    internal static OutOfProcPacket Parse(
        string line,
        PSRPFragmentPool fragmentPool)
    {
        XElement element = XElement.Parse(line);

        string elementType = element.Name.LocalName;
        string psGuidRaw = element.Attribute("PSGuid")?.Value
            ?? throw new InvalidDataException("Missing PSGuid attribute");
        if (!Guid.TryParse(psGuidRaw, out Guid psGuid))
        {
            throw new InvalidDataException($"Invalid PSGuid value: {psGuidRaw}");
        }

        string? stream = element.Attribute("Stream")?.Value;
        PSRPFragment[] fragments = [];
        PSRPMessage[] messages = [];
        PSRPDestination? destination;
        if (elementType == "Data")
        {
            (fragments, messages, destination) = ParseFragments(psGuid, element.Value, fragmentPool);
        }
        else
        {
            // The client sends the commands and the server acknowledges them.
            destination = elementType switch
            {
                "Command" or "Signal" or "Close" => PSRPDestination.Server,
                "DataAck" or "CommandAck" or "SignalAck" or "CloseAck" => PSRPDestination.Client,
                _ => null,
            };
        }

        return new(elementType, psGuid, stream, fragments, messages, line, destination);
    }

    [SkipLocalsInit]
    private static (PSRPFragment[], PSRPMessage[], PSRPDestination?) ParseFragments(
        Guid psGuid,
        string base64,
        PSRPFragmentPool fragmentPool)
    {
        List<PSRPFragment> fragments = [];
        List<PSRPMessage> messages = [];
        PSRPDestination? destination = null;
#if NET
        // The upper bound of the decoded length, padding and whitespace mean
        // the actual length can be smaller.
        int maxLength = base64.Length * 3 / 4;
        byte[]? rentedBytes = null;
#endif
        try
        {
#if NET
            Span<byte> buffer = maxLength <= 256
                ? stackalloc byte[256]
                : (rentedBytes = ArrayPool<byte>.Shared.Rent(maxLength));

            if (!Convert.TryFromBase64String(base64, buffer, out int bytesWritten))
            {
                throw new InvalidDataException("Data packet does not contain valid base64 content");
            }
            buffer = buffer[..bytesWritten];
#else
            Span<byte> buffer;
            try
            {
                buffer = Convert.FromBase64String(base64);
            }
            catch (FormatException e)
            {
                throw new InvalidDataException("Data packet does not contain valid base64 content", e);
            }
#endif

            while (buffer.Length > 0)
            {
                if (buffer.Length < FragmentHeaderLength)
                {
                    throw new InvalidDataException(
                        $"Data packet has {buffer.Length} trailing bytes, expecting a {FragmentHeaderLength} byte PSRP fragment header");
                }

                int blobLength = BinaryPrimitives.ReadInt32BigEndian(buffer[17..]);
                PSRPFragment frag = new(
                    ObjectId: BinaryPrimitives.ReadUInt64BigEndian(buffer),
                    FragmentId: BinaryPrimitives.ReadUInt64BigEndian(buffer[8..]),
                    Start: (buffer[16] & 0x1) != 0,
                    End: (buffer[16] & 0x2) != 0,
                    Length: blobLength);

                buffer = buffer[FragmentHeaderLength..];
                if (blobLength < 0 || blobLength > buffer.Length)
                {
                    throw new InvalidDataException(
                        $"PSRP fragment Obj={frag.ObjectId} Frag={frag.FragmentId} has a blob length of {blobLength} " +
                        $"but only {buffer.Length} bytes remain in the Data packet");
                }

                ReadOnlySpan<byte> blob = buffer[..blobLength];
                buffer = buffer[blobLength..];
                fragments.Add(frag);

                // The message header, with the destination, is at the start of
                // the first fragment.
                if (frag.Start && blob.Length >= 4)
                {
                    destination ??= (PSRPDestination)BinaryPrimitives.ReadInt32LittleEndian(blob);
                }

                if (frag.Start && frag.End)
                {
                    // Optimisation, we don't need to worry about fragment
                    // reassembly if this is the only fragment
                    messages.Add(ParseMessage(blob));
                }
                else if (frag.Start)
                {
                    fragmentPool.Start(psGuid, frag, blob);
                }
                else
                {
                    List<byte> fragData = fragmentPool.Append(psGuid, frag, blob);
                    if (fragData.Count >= 4)
                    {
                        destination ??= (PSRPDestination)BinaryPrimitives.ReadInt32LittleEndian(AsSpan(fragData));
                    }

                    if (frag.End)
                    {
                        messages.Add(ParseMessage(AsSpan(fragData)));
                    }
                }
            }
        }
        finally
        {
#if NET
            if (rentedBytes is not null)
            {
                ArrayPool<byte>.Shared.Return(rentedBytes);
            }
#endif
        }

        return ([.. fragments], [.. messages], destination);
    }

    private static PSRPMessage ParseMessage(ReadOnlySpan<byte> buffer)
    {
        if (buffer.Length < MessageHeaderLength)
        {
            throw new InvalidDataException(
                $"PSRP message is {buffer.Length} bytes, expecting at least the {MessageHeaderLength} byte message header");
        }

        ReadOnlySpan<byte> data = buffer[MessageHeaderLength..];
        if (data.StartsWith(Utf8Bom))
        {
            data = data[Utf8Bom.Length..];
        }

        return new(
            (PSRPDestination)BinaryPrimitives.ReadInt32LittleEndian(buffer),
            (PSRPMessageType)BinaryPrimitives.ReadInt32LittleEndian(buffer[4..]),
            ReadGuid(buffer[8..24]),
            ReadGuid(buffer[24..40]),
#if NET
            Encoding.UTF8.GetString(data));
#else
            Encoding.UTF8.GetString(data.ToArray()));
#endif
    }

#if NET
    private static ReadOnlySpan<byte> AsSpan(List<byte> value) => CollectionsMarshal.AsSpan(value);

    private static Guid ReadGuid(ReadOnlySpan<byte> value) => new(value);
#else
    // .NET Framework has no span overloads, the values are copied instead.
    private static ReadOnlySpan<byte> AsSpan(List<byte> value) => value.ToArray();

    private static Guid ReadGuid(ReadOnlySpan<byte> value) => new(value.ToArray());
#endif
}

/// <summary>
/// Holds the partial PSRP messages that span multiple Data packets until the
/// end fragment is received.
/// </summary>
/// <remarks>
/// Object ids are only unique inside the PowerShell process that sent them,
/// the client and server each have their own sequence, so they are tracked
/// per PSGuid to keep messages of different pipelines apart.
/// </remarks>
internal sealed class PSRPFragmentPool
{
    private readonly Dictionary<(Guid, ulong), PartialMessage> _pool = [];

    public void Start(Guid psGuid, PSRPFragment fragment, ReadOnlySpan<byte> blob)
    {
        PartialMessage partial = new([.. blob.ToArray()])
        {
            NextFragmentId = fragment.FragmentId + 1,
        };
        _pool[(psGuid, fragment.ObjectId)] = partial;
    }

    public List<byte> Append(Guid psGuid, PSRPFragment fragment, ReadOnlySpan<byte> blob)
    {
        (Guid, ulong) key = (psGuid, fragment.ObjectId);
        if (!_pool.TryGetValue(key, out PartialMessage? partial))
        {
            throw new InvalidDataException(
                $"PSRP fragment Obj={fragment.ObjectId} Frag={fragment.FragmentId} was received without a start fragment");
        }

        if (fragment.FragmentId != partial.NextFragmentId)
        {
            // The message cannot be reassembled, drop it so the following
            // fragments of the same object are reported too.
            _pool.Remove(key);
            throw new InvalidDataException(
                $"PSRP fragment Obj={fragment.ObjectId} Frag={fragment.FragmentId} was received but expected " +
                $"Frag={partial.NextFragmentId}");
        }

        partial.Data.AddRange(blob.ToArray());
        partial.NextFragmentId++;
        if (fragment.End)
        {
            _pool.Remove(key);
        }

        return partial.Data;
    }

    private sealed class PartialMessage(List<byte> data)
    {
        public List<byte> Data { get; } = data;
        public ulong NextFragmentId { get; set; }
    }
}
