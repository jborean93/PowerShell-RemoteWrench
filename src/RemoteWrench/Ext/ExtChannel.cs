using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Threading;

namespace RemoteWrench.Ext;

/// <summary>The details of a callback call, available to its client script as $ExtCallbackContext.</summary>
public sealed class ExtCallbackContext
{
    internal ExtCallbackContext(
        string name,
        object?[] argumentList,
        IDictionary parameter,
        ExtChannel channel,
        RunspaceConnectionInfo? connectionInfo,
        PSHost host)
    {
        Name = name;
        ArgumentList = argumentList;
        Parameter = parameter;
        Channel = channel;
        ConnectionInfo = connectionInfo;
        Host = host;
    }

    /// <summary>The name of the callback.</summary>
    public string Name { get; }

    /// <summary>The connection info of the remote session.</summary>
    public RunspaceConnectionInfo? ConnectionInfo { get; }


    /// <summary>
    /// Cancelled when the server stops the call, like when the command that called it is stopped, the callback
    /// should stop.
    /// </summary>
    public CancellationToken CancellationToken => Channel.CancellationToken;

    /// <summary>The host of the client, a script has it as $Host.</summary>
    internal PSHost Host { get; }

    /// <summary>The positional arguments from the server.</summary>
    internal object?[] ArgumentList { get; }

    /// <summary>The named arguments from the server.</summary>
    internal IDictionary Parameter { get; }

    /// <summary>The channel with the input from the server, the output is written to.</summary>
    internal ExtChannel Channel { get; }
}

/// <summary>The client side of the data exchanged with the server for a callback call.</summary>
internal sealed class ExtChannel
{
    // How often the client tells the server how many input objects it has
    // read, see Invoke-ExtProxyProcess.
    private const int ReadReportInterval = 16;

    private readonly ExtSession _session;
    private readonly BlockingCollection<object?> _incoming = new();
    private readonly CancellationTokenSource _closed = new();

    internal ExtChannel(ExtSession session, string id, string name, bool expectingInput)
    {
        _session = session;
        Id = id;
        Name = name;
        ExpectingInput = expectingInput;
    }

    /// <summary>The id of the channel.</summary>
    public string Id { get; }

    /// <summary>The name of the callback.</summary>
    public string Name { get; }

    /// <summary>Whether the server sends pipeline input.</summary>
    public bool ExpectingInput { get; }

    /// <summary>True when the server has closed the channel, anything written is discarded.</summary>
    public bool IsClosed => _closed.IsCancellationRequested;

    /// <summary>Cancelled when the server closes the channel.</summary>
    public CancellationToken CancellationToken => _closed.Token;

    /// <summary>
    /// Outputs the input from the server as it arrives until it has sent all of it. It throws
    /// OperationCanceledException if the channel is closed first, so a script reading it stops rather than
    /// finishing as if all the input was received.
    /// </summary>
    /// <returns>The objects from the server.</returns>
    public IEnumerable<object?> ReadInput()
    {
        // The server only sends so many objects ahead of what has been read,
        // tell it as they are read.
        int read = 0;
        foreach (object? item in _incoming.GetConsumingEnumerable(_closed.Token))
        {
            yield return item;

            read++;
            if (read % ReadReportInterval == 0)
            {
                ExtTrace.Write($"{Id} read {read}");
                _session.Enqueue(new(Id, ExtMessageKind.Read, read));
            }
        }
    }

    /// <summary>Sends an object to the server.</summary>
    /// <param name="value">The object to send.</param>
    public void Write(object? value)
    {
        if (!IsClosed)
        {
            _session.EnqueueData(new(Id, ExtMessageKind.Data, value), _closed.Token);
        }
    }

    /// <summary>Sends an error message to the server, it is written as an error there.</summary>
    /// <param name="message">The error message.</param>
    public void WriteError(string message)
    {
        if (!IsClosed)
        {
            _session.EnqueueData(new(Id, ExtMessageKind.Error, message), _closed.Token);
        }
    }

    internal void Receive(object? item)
    {
        try
        {
            _incoming.Add(item);
        }
        catch (InvalidOperationException)
        {
            // The server wrote after it completed, the channel ignores it.
        }
    }

    /// <summary>The server has sent all its input.</summary>
    internal void CompleteIncoming() => _incoming.CompleteAdding();

    /// <summary>The server has closed the channel, or the session is gone.</summary>
    internal void Close()
    {
        if (IsClosed)
        {
            return;
        }

        _closed.Cancel();
        _incoming.CompleteAdding();
    }
}
