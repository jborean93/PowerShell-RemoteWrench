using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Threading;

namespace RemoteWrench.Ext;

internal enum ExtMessageKind
{
    Ack,
    Data,
    Error,
    End,

    /// <summary>How many input objects the client script has read, the server limits how many it sends ahead.</summary>
    Read,
}

/// <summary>A message from the client to the server.</summary>
/// <param name="Id">The channel id.</param>
/// <param name="Kind">The message kind.</param>
/// <param name="Item">The data or error message for a Data or Error message.</param>
/// <param name="Failure">Why the client script failed for an End message.</param>
internal readonly record struct ExtMessage(string Id, ExtMessageKind Kind, object? Item, string? Failure = null);

/// <summary>The client side of a remote session with the functions of Enter-ExtSession.</summary>
/// <remarks>
/// The server sends messages as engine events forwarded to the client, they are received from the remote
/// runspace's event queue. The client sends messages as nested pipelines in the remote runspace. They can only run
/// while the pipeline that called the callback is running, which is the case while the callback waits for them.
/// </remarks>
internal sealed class ExtSession : IDisposable
{
    private const string ServerScriptResource = "RemoteWrench.Ext.ExtServer.ps1";

    // Passes each object to the remote module, see Receive-ExtClientInput.
    private const string NestedScript =
        "begin { $receive = & (Get-Module -Name RemoteWrench.Ext) { ${function:Receive-ExtClientInput} } } " +
        "process { & $receive $_ }";

    // Outputs the ids of the channels whose command was stopped before they
    // were closed, see Get-ExtStoppedChannel.
    private const string PingScript =
        "$ids = @($input); & (Get-Module -Name RemoteWrench.Ext) { Get-ExtStoppedChannel -Id $args[0] } $ids";

    // How many messages are sent in one nested pipeline.
    private const int MaxBatchSize = 256;

    // How many data and error messages can wait to be sent, a callback
    // writing more waits for them to be sent. It keeps a callback that
    // outputs a lot, like a large file, from queuing all of it in memory.
    private const int MaxPendingData = 64;

    // How many pings in a row have to fail before the open channels are
    // closed, see PingOpenChannels.
    private const int MaxPingFailures = 3;

    // How long the sender waits for something to send before it pings the
    // server about the open channels.
    private const int PingIntervalMs = 1000;

    // How long the server waits for the client to acknowledge a callback by
    // default.
    private const int DefaultAckTimeoutMs = 10000;

    private static string? s_serverScript;

    private readonly Runspace _remote;
    private readonly Runspace _local;
    private readonly PSHost _host;
    private readonly Dictionary<string, ExtCallback> _callbacks;
    private readonly ConcurrentDictionary<string, ExtChannel> _channels = new();
    private readonly BlockingCollection<ExtMessage> _outgoing = new();
    private readonly SemaphoreSlim _dataSlots = new(MaxPendingData, MaxPendingData);
    private readonly string _sourceIdentifier = $"RemoteWrench.Ext.{Guid.NewGuid()}";
    private readonly string _dispatchIdentifier = $"RemoteWrench.Ext.Dispatch.{Guid.NewGuid()}";
    private readonly Thread _sender;
    private readonly List<PSEventSubscriber> _localSubscribers = [];

    // The server's messages are forwarded events, they can be raised out of
    // the order they were sent in. Each has a sequence number, one that
    // arrives early waits here until the ones before it are handled.
    private readonly object _orderLock = new();
    private readonly Dictionary<long, Hashtable> _earlyMessages = [];
    private long _nextSequence = 1;
    private int _pingFailures;
    private int _disposed;

    private ExtSession(Runspace remote, Runspace local, PSHost host, Dictionary<string, ExtCallback> callbacks)
    {
        _remote = remote;
        _local = local;
        _host = host;
        _callbacks = callbacks;
        _sender = new(SendLoop)
        {
            IsBackground = true,
            Name = "RemoteWrench.Ext sender",
        };
    }

    /// <summary>Sets up the functions in the remote session.</summary>
    /// <param name="remote">The remote runspace, opened if it isn't already.</param>
    /// <param name="local">The runspace that is entering the session, script callbacks run on it.</param>
    /// <param name="host">The host of the client.</param>
    /// <param name="definitions">The functions to define.</param>
    /// <param name="ackTimeoutMs">How long the server waits for the client to acknowledge a callback.</param>
    /// <returns>The session, it is disposed when the remote runspace closes.</returns>
    public static ExtSession Create(
        Runspace remote,
        Runspace local,
        PSHost host,
        IReadOnlyList<ExtDefinition> definitions,
        int ackTimeoutMs = DefaultAckTimeoutMs)
    {
        Dictionary<string, ExtCallback> callbacks = new(StringComparer.OrdinalIgnoreCase);
        foreach (ExtDefinition definition in definitions)
        {
            if (definition is ExtCallback callback)
            {
                callbacks[callback.Name] = callback;
            }
        }

        ExtSession session = new(remote, local, host, callbacks);
        try
        {
            session.Start(definitions, ackTimeoutMs);
        }
        catch
        {
            session.Dispose();
            throw;
        }

        return session;
    }

    private void Start(IReadOnlyList<ExtDefinition> definitions, int ackTimeoutMs)
    {
        // A closed runspace has no events to subscribe to, check it first.
        if (_remote.RunspaceStateInfo.State == RunspaceState.BeforeOpen)
        {
            try
            {
                _remote.Open();
            }
            catch (Exception e)
            {
                throw new ExtSessionException($"Failed to open the remote session: {FormatException(e)}", e);
            }
        }
        if (_remote.RunspaceStateInfo.State != RunspaceState.Opened)
        {
            throw new InvalidOperationException(
                $"The remote session is {_remote.RunspaceStateInfo.State}, it must be open.");
        }

        // Script callbacks run in the local runspace as the action of an
        // event, that runs them when the runspace is idle, which it is while
        // the remote session is entered.
        _localSubscribers.Add(_local.Events.SubscribeEvent(
            null,
            null,
            _dispatchIdentifier,
            null,
            ScriptBlock.Create("$Event.MessageData.Invoke()"),
            true,
            false));

        // New-PSSession also forwards the events of its runspace into the
        // local event queue. Nothing reads them there, a subscriber that does
        // nothing stops them from building up.
        _localSubscribers.Add(_local.Events.SubscribeEvent(
            null,
            null,
            _sourceIdentifier,
            null,
            static (_, _) => { },
            true,
            false));

        _remote.Events.ReceivedEvents.PSEventReceived += OnRemoteEvent;
        _remote.StateChanged += OnRemoteStateChanged;


        object[] serverDefinitions = new object[definitions.Count];
        for (int i = 0; i < definitions.Count; i++)
        {
            serverDefinitions[i] = definitions[i].ToServerDefinition();
        }

        using PowerShell ps = PowerShell.Create();
        ps.Runspace = _remote;
        // A local scope keeps the script's variables out of the global scope
        // of the remote session.
        ps.AddScript(GetServerScript(), true)
            .AddParameter("SourceIdentifier", _sourceIdentifier)
            .AddParameter("Definitions", serverDefinitions)
            .AddParameter("AckTimeoutMs", ackTimeoutMs);

        try
        {
            ps.Invoke();
        }
        catch (RuntimeException e)
        {
            throw new ExtSessionException(
                $"Failed to set up the functions in the remote session: {FormatException(e)}",
                e);
        }

        if (ps.HadErrors && ps.Streams.Error.Count > 0)
        {
            ErrorRecord err = ps.Streams.Error[0];
            throw new ExtSessionException(
                $"Failed to set up the functions in the remote session: {FormatErrorRecord(err)}",
                err.Exception);
        }

        _sender.Start();
    }

    /// <summary>Queues a data or error message to the server, it waits while too many are waiting to be sent.</summary>
    /// <param name="message">The message.</param>
    /// <param name="cancellationToken">Cancelled when the channel is closed, the message is dropped.</param>
    internal void EnqueueData(ExtMessage message, CancellationToken cancellationToken)
    {
        try
        {
            if (!_dataSlots.Wait(0))
            {
                ExtTrace.Write($"{message.Id} waiting for a data slot");
                _dataSlots.Wait(cancellationToken);
            }
        }
        catch (OperationCanceledException)
        {
            ExtTrace.Write($"{message.Id} dropped {message.Kind}, the channel is closed");
            return;
        }

        Enqueue(message);
    }

    /// <summary>Queues a message to the server.</summary>
    internal void Enqueue(ExtMessage message)
    {
        try
        {
            _outgoing.Add(message);
        }
        catch (InvalidOperationException)
        {
            // The session is closed, there is nothing to send to.
        }
    }

    private void OnRemoteStateChanged(object? sender, RunspaceStateEventArgs e)
    {
        ExtTrace.Write($"remote runspace {e.RunspaceStateInfo.State}");
        if (e.RunspaceStateInfo.State is RunspaceState.Closed or RunspaceState.Broken)
        {
            Dispose();
        }
    }

    private void OnRemoteEvent(object sender, PSEventArgs e)
    {
        if (e.SourceIdentifier != _sourceIdentifier)
        {
            return;
        }

        // The remote runspace keeps every event it receives, remove ours so
        // they don't build up.
        PSEventArgsCollection received = _remote.Events.ReceivedEvents;
        lock (received.SyncRoot)
        {
            for (int i = received.Count - 1; i >= 0; i--)
            {
                if (ReferenceEquals(received[i], e))
                {
                    received.RemoveAt(i);
                    break;
                }
            }
        }

        try
        {
            if (Unwrap(e.MessageData) is Hashtable message)
            {
                HandleInOrder(message);
            }
        }
        catch (Exception ex)
        {
            // This runs on the thread that receives data from the remote
            // session, an exception here would break it.
            WriteHostError($"Failed to process a message from the server: {ex.Message}");
        }
    }

    private void HandleInOrder(Hashtable message)
    {
        long sequence = LanguagePrimitives.ConvertTo<long>(message["Seq"]);
        lock (_orderLock)
        {
            if (sequence != _nextSequence)
            {
                ExtTrace.Write($"received {sequence} {message["Kind"]} early, waiting for {_nextSequence}");
                _earlyMessages[sequence] = message;
                return;
            }

            while (true)
            {
                HandleServerMessage(message);
                _nextSequence++;
                if (!_earlyMessages.TryGetValue(_nextSequence, out message!))
                {
                    break;
                }
                _earlyMessages.Remove(_nextSequence);
            }
        }
    }

    private void HandleServerMessage(Hashtable message)
    {
        string kind = LanguagePrimitives.ConvertTo<string>(message["Kind"]);
        string id = LanguagePrimitives.ConvertTo<string>(message["Id"]);
        ExtTrace.Write($"{id} handling {message["Seq"]} {kind}");
        if (kind == "Open")
        {
            HandleOpen(id, message);
            return;
        }

        if (!_channels.TryGetValue(id, out ExtChannel? channel))
        {
            ExtTrace.Write($"{id} is not open, ignored {kind}");
            return;
        }

        switch (kind)
        {
            case "Data":
                if (Unwrap(message["Items"]) is IEnumerable items)
                {
                    foreach (object? item in items)
                    {
                        channel.Receive(item);
                    }
                }
                break;

            case "End":
                channel.CompleteIncoming();
                break;

            case "Close":
                _channels.TryRemove(id, out _);
                channel.Close();
                break;
        }
    }

    private void HandleOpen(string id, Hashtable message)
    {
        string name = LanguagePrimitives.ConvertTo<string>(message["Name"]);
        if (!_callbacks.TryGetValue(name, out ExtCallback? callback))
        {
            // Shouldn't happen, the server only knows the callbacks it was
            // given. Fail it rather than leave it waiting.
            Enqueue(new(id, ExtMessageKind.Ack, null));
            Enqueue(new(id, ExtMessageKind.End, null, $"The client has no callback named '{name}'."));
            return;
        }

        List<object?> argumentList = [];
        if (Unwrap(message["ArgumentList"]) is IEnumerable args)
        {
            foreach (object? arg in args)
            {
                argumentList.Add(arg);
            }
        }
        IDictionary parameter = Unwrap(message["Parameter"]) as IDictionary ?? new Hashtable();
        bool expectingInput = LanguagePrimitives.IsTrue(message["ExpectingInput"]);

        ExtChannel channel = new(this, id, name, expectingInput);
        _channels[id] = channel;
        Enqueue(new(id, ExtMessageKind.Ack, null));

        ExtCallbackContext context = new(
            name,
            argumentList.ToArray(),
            parameter,
            channel,
            _remote.ConnectionInfo,
            _host);
        Action run = () => RunCallback(callback, context);

        if (callback.RunsOnLocalRunspace)
        {
            _local.Events.GenerateEvent(_dispatchIdentifier, null, null, new PSObject(run));
        }
        else
        {
            Thread thread = new(() => run())
            {
                IsBackground = true,
                Name = $"RemoteWrench.Ext callback {name}",
            };
            thread.Start();
        }
    }

    private void RunCallback(ExtCallback callback, ExtCallbackContext context)
    {
        string? failure = null;
        try
        {
            callback.InvokeClient(context);
        }
        catch (Exception e)
        {
            failure = FormatException(e);
        }

        ExtTrace.Write($"{context.Channel.Id} callback ended, failure: {failure ?? "none"}");
        if (_channels.TryRemove(context.Channel.Id, out _))
        {
            Enqueue(new(context.Channel.Id, ExtMessageKind.End, null, failure));
        }
        else if (failure is not null && !context.Channel.IsClosed)
        {
            WriteHostError($"Callback '{callback.Name}' failed: {failure}");
        }
    }

    internal static string FormatException(Exception e)
    {
        if (e is MethodInvocationException { InnerException: IContainsErrorRecord inner })
        {
            e = (Exception)inner;
        }

        string message = e is IContainsErrorRecord { ErrorRecord: ErrorRecord record }
            ? FormatErrorRecord(record)
            : e.Message;

        // Exceptions like a failed connection have a generic message, the
        // inner exceptions say what actually failed.
        for (Exception? innerEx = e.InnerException; innerEx is not null; innerEx = innerEx.InnerException)
        {
            if (!message.Contains(innerEx.Message))
            {
                message += $" {innerEx.Message}";
            }
        }
        return message;
    }

    private static string FormatErrorRecord(ErrorRecord record)
    {
        string? position = record.InvocationInfo?.PositionMessage;
        return string.IsNullOrWhiteSpace(position) ? record.ToString() : $"{record}\n{position}";
    }

    private void SendLoop()
    {
        List<ExtMessage> batch = [];
        while (true)
        {
            ExtMessage first;
            try
            {
                if (!_outgoing.TryTake(out first, PingIntervalMs))
                {
                    if (_outgoing.IsCompleted)
                    {
                        return;
                    }

                    PingOpenChannels();
                    continue;
                }
            }
            catch (ObjectDisposedException)
            {
                return;
            }

            batch.Clear();
            batch.Add(first);
            while (batch.Count < MaxBatchSize && _outgoing.TryTake(out ExtMessage next))
            {
                batch.Add(next);
            }

            int dataCount = 0;
            foreach (ExtMessage msg in batch)
            {
                if (msg.Kind is ExtMessageKind.Data or ExtMessageKind.Error)
                {
                    dataCount++;
                }
            }

            Stopwatch sw = Stopwatch.StartNew();
            try
            {
                Send(batch);
                ExtTrace.Write($"sent {batch.Count} messages ({dataCount} data) in {sw.ElapsedMilliseconds}ms");
            }
            catch (Exception e) when (IsPipelineStopped(e))
            {
                ExtTrace.Write($"send of {batch.Count} messages stopped: {e.Message}");
                // The command that called the callback was stopped, like with
                // Ctrl+C, which stops this too. The server closes the
                // callback.
            }
            catch (Exception e)
            {
                ExtTrace.Write($"send of {batch.Count} messages failed after {sw.ElapsedMilliseconds}ms: {e}");

                // The server stops waiting for the client after a while, the
                // callbacks are failed here so they stop too.
                HashSet<string> names = new(StringComparer.OrdinalIgnoreCase);
                foreach (ExtMessage msg in batch)
                {
                    if (_channels.TryRemove(msg.Id, out ExtChannel? channel))
                    {
                        names.Add(channel.Name);
                        channel.Close();
                    }
                }

                // Without an open channel the callbacks have ended and the
                // server isn't waiting for anything.
                if (names.Count > 0)
                {
                    WriteHostError(
                        $"Failed to send data for callback '{string.Join("', '", names)}' to the server: {e.Message}");
                }
            }
            finally
            {
                // Sent or failed, either way they no longer wait.
                if (dataCount > 0)
                {
                    _dataSlots.Release(dataCount);
                }
            }
        }
    }

    /// <summary>Closes the open channels whose command has ended on the server.</summary>
    /// <remarks>
    /// A callback is normally closed by the server, but not if the command that called it was stopped while another
    /// command in its pipeline was running, like Ctrl+C on Get-Content -Wait piped to a callback. The callback can
    /// wait forever for input then, and it blocks the runspace the next callback runs on.
    /// </remarks>
    private void PingOpenChannels()
    {
        string[] ids = [.. _channels.Keys];
        if (ids.Length == 0)
        {
            return;
        }

        IEnumerable<string> stopped;
        try
        {
            List<string> result = [];
            NestedPipeline.Invoke(_remote, PingScript, ids, out var output);
            foreach (PSObject? obj in output)
            {
                if (obj?.BaseObject is string id)
                {
                    result.Add(id);
                }
            }
            stopped = result;
            _pingFailures = 0;
            ExtTrace.Write($"pinged {ids.Length} channels, {result.Count} stopped");
        }
        catch (Exception e)
        {
            ExtTrace.Write($"ping of {ids.Length} channels failed ({_pingFailures + 1}): {e.Message}");
            // A nested pipeline can only run while a command runs, the
            // command that called them has ended if it keeps failing. The
            // exception doesn't say why it failed, other than in its message,
            // so a failure that doesn't repeat doesn't close the callbacks.
            if (++_pingFailures < MaxPingFailures)
            {
                return;
            }
            _pingFailures = 0;
            stopped = ids;
        }

        foreach (string id in stopped)
        {
            if (_channels.TryRemove(id, out ExtChannel? channel))
            {
                ExtTrace.Write($"{id} closed by the ping");
                channel.Close();
            }
        }
    }

    private static bool IsPipelineStopped(Exception e)
    {
        if (e is PipelineStoppedException)
        {
            return true;
        }

        // Stopped on the server, the exception is a RemoteException wrapping
        // the deserialized one.
        return e is RemoteException { SerializedRemoteException: PSObject remote } &&
            remote.TypeNames.Contains($"Deserialized.{typeof(PipelineStoppedException).FullName}");
    }

    private void Send(List<ExtMessage> batch)
    {
        // A Data or Error message is a header followed by its items so they
        // are serialized as top level objects. Consecutive items of the same
        // channel and kind share a header.
        List<object?> input = [];
        Hashtable? header = null;
        foreach (ExtMessage msg in batch)
        {
            if (msg.Kind is ExtMessageKind.Data or ExtMessageKind.Error)
            {
                if (header is null ||
                    (string)header["Id"]! != msg.Id ||
                    (string)header["Kind"]! != msg.Kind.ToString())
                {
                    header = new()
                    {
                        ["Id"] = msg.Id,
                        ["Kind"] = msg.Kind.ToString(),
                        ["Count"] = 0,
                    };
                    input.Add(header);
                }
                header["Count"] = (int)header["Count"]! + 1;
                input.Add(msg.Item);
            }
            else
            {
                header = null;
                input.Add(new Hashtable()
                {
                    ["Id"] = msg.Id,
                    ["Kind"] = msg.Kind.ToString(),
                    ["Failure"] = msg.Failure,
                    ["Count"] = msg.Kind == ExtMessageKind.Read ? msg.Item : null,
                });
            }
        }

        object? error = NestedPipeline.Invoke(_remote, NestedScript, input, out _);
        if (error is not null)
        {
            throw new InvalidOperationException($"The server failed to process the data: {Unwrap(error)}");
        }
    }

    /// <summary>Gets the object a PSObject wraps, or the value itself.</summary>
    internal static object? Unwrap(object? value) => value is PSObject psObj ? psObj.BaseObject : value;

    private void WriteHostError(string message)
    {
        try
        {
            _host.UI.WriteErrorLine($"RemoteWrench: {message}");
        }
        catch
        {
            // Nothing else can be done with it.
        }
    }

    private static string GetServerScript()
    {
        if (s_serverScript is null)
        {
            using Stream stream = typeof(ExtSession).Assembly.GetManifestResourceStream(ServerScriptResource)
                ?? throw new InvalidOperationException($"The embedded resource '{ServerScriptResource}' is missing.");
            using StreamReader reader = new(stream);
            s_serverScript = reader.ReadToEnd();
        }

        return s_serverScript;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 1)
        {
            return;
        }
        ExtTrace.Write($"disposing with {_channels.Count} open channels");

        // The events are gone once the runspace is disposed.
        if (_remote.Events is { } remoteEvents)
        {
            remoteEvents.ReceivedEvents.PSEventReceived -= OnRemoteEvent;
        }
        _remote.StateChanged -= OnRemoteStateChanged;
        foreach (PSEventSubscriber subscriber in _localSubscribers)
        {
            try
            {
                _local.Events.UnsubscribeEvent(subscriber);
            }
            catch
            {
                // The local runspace may be closing too.
            }
        }

        _outgoing.CompleteAdding();
        foreach (ExtChannel channel in _channels.Values)
        {
            channel.Close();
        }
        _channels.Clear();
    }
}

/// <summary>An error setting up an Enter-ExtSession session.</summary>
public sealed class ExtSessionException : RuntimeException
{
    internal ExtSessionException(string message, Exception? innerException)
        : base(message, innerException)
    { }
}
