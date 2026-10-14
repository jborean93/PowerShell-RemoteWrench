using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Management.Automation.Runspaces;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteWrench.Formatting;

/// <summary>
/// The human readable parts of a PSRP message.
/// </summary>
/// <param name="Summary">A single line summary of the message.</param>
/// <param name="Fields">The interesting values of the message.</param>
/// <param name="Tree">The message data as a tree, set when the raw value is worth showing.</param>
/// <param name="IsError">The message represents an error or failure.</param>
internal sealed record DecodedMessage(
    string Summary,
    IReadOnlyList<KeyValuePair<string, string>> Fields,
    ClixmlNode? Tree,
    bool IsError);

internal static class MessageDecoder
{
    private const long NoResponseCallId = -100;

    // CLIXML can reference an earlier object so the deserialized value can
    // contain itself, the formatting of an argument stops at this depth.
    private const int MaxArgumentDepth = 8;

    private static readonly Regex s_lineBreaks = new(@"\r?\n\s*", RegexOptions.Compiled);


    // The Merge properties of a command and the redirection stream number,
    // which matches the PipelineResultTypes value of the stream.
    private static readonly (string Property, int Stream)[] s_mergeStreams =
    [
        ("MergeError", 2),
        ("MergeWarning", 3),
        ("MergeVerbose", 4),
        ("MergeDebug", 5),
        ("MergeInformation", 6),
    ];

    public static int MessageSize(PSRPMessage message)
        => 40 + Encoding.UTF8.GetByteCount(message.Data);

    public static DecodedMessage Decode(PSRPMessage message)
    {
        if (message.MessageType == PSRPMessageType.EndOfPipelineInput)
        {
            return new("end of input", [], null, false);
        }
        else if (message.MessageType == PSRPMessageType.ConnectRunspacePool && string.IsNullOrWhiteSpace(message.Data))
        {
            // The min and max runspaces are only sent when they change.
            return new("connect", [], null, false);
        }
        else if (string.IsNullOrWhiteSpace(message.Data))
        {
            return new("", [], null, false);
        }

        object? obj;
        try
        {
            obj = Clixml.Deserialize(message.Data);
        }
        catch (Exception e)
        {
            return RawMessage("invalid CLIXML", e, message);
        }

        try
        {
            Builder builder = new(obj);
            Decode(message.MessageType, obj, builder);
            return builder.Build();
        }
        catch (Exception e)
        {
            // A value the decoder can't handle, like an object with a ToString
            // that throws, is shown with the raw CLIXML instead.
            return RawMessage("unexpected data", e, message);
        }
    }

    private static DecodedMessage RawMessage(string reason, Exception exception, PSRPMessage message) => new(
        $"{reason}: {TextHelper.Sanitize(exception.Message)}",
        [new("Data", TextHelper.Sanitize(message.Data))],
        null,
        true);

    private static void Decode(PSRPMessageType messageType, object? obj, Builder b)
    {
        switch (messageType)
        {
            case PSRPMessageType.SessionCapability:
                object? protocol = b.Add("Protocol", Clixml.Property(obj, "protocolversion"));
                object? psVersion = b.Add("PSVersion", Clixml.Property(obj, "PSVersion"));
                object? serialization = b.Add("Serialization", Clixml.Property(obj, "SerializationVersion"));
                b.Summary = $"protocol {Clixml.Text(protocol)}, PS {Clixml.Text(psVersion)}, serialization {Clixml.Text(serialization)}";
                break;

            case PSRPMessageType.InitRunspacePool:
            case PSRPMessageType.RunspacePoolInitData:
            case PSRPMessageType.ConnectRunspacePool:
                object? min = b.Add("MinRunspaces", Clixml.Property(obj, "MinRunspaces"));
                object? max = b.Add("MaxRunspaces", Clixml.Property(obj, "MaxRunspaces"));
                b.AddIfSet("ThreadOptions", Clixml.Property(obj, "PSThreadOptions"));
                b.AddIfSet("ApartmentState", Clixml.Property(obj, "ApartmentState"));

                object? clientVersion = DictionaryValue(
                    DictionaryValue(Clixml.Property(obj, "ApplicationArguments"), "PSVersionTable"),
                    "PSVersion");
                b.AddIfSet("ClientPSVersion", clientVersion);
                b.Summary = $"min {Clixml.Text(min)}, max {Clixml.Text(max)}" +
                    (clientVersion is null ? "" : $", client PS {Clixml.Text(clientVersion)}");
                break;

            case PSRPMessageType.ApplicationPrivateData:
                object? privateData = Clixml.Unwrap(Clixml.Property(obj, "ApplicationPrivateData"));
                List<string> parts = [];
                if (privateData is IDictionary dict)
                {
                    foreach (DictionaryEntry entry in dict)
                    {
                        string key = Clixml.Text(entry.Key);
                        if (key == "PSVersionTable")
                        {
                            object? serverVersion = DictionaryValue(entry.Value, "PSVersion");
                            b.Add("ServerPSVersion", serverVersion);
                            parts.Insert(0, $"server PS {Clixml.Text(serverVersion)}");
                        }
                        else
                        {
                            b.Add(key, entry.Value);
                            parts.Add($"{key}={Clixml.Text(entry.Value)}");
                        }
                    }
                }
                b.Summary = string.Join(", ", parts);
                break;

            case PSRPMessageType.RunspacePoolState:
                DecodeState<RunspacePoolState>(obj, "RunspaceState", b);
                break;

            case PSRPMessageType.PipelineState:
                DecodeState<PSInvocationState>(obj, "PipelineState", b);
                break;

            case PSRPMessageType.CreatePipeline:
                List<string> statements = FormatStatements(Clixml.Property(obj, "PowerShell"));
                b.AddMultiline("Command", string.Join("\n", statements));
                b.AddIfSet("NoInput", Clixml.Property(obj, "NoInput"));
                b.AddIfSet("AddToHistory", Clixml.Property(obj, "AddToHistory"));
                b.AddIfSet("IsNested", Clixml.Property(obj, "IsNested"));
                b.AddIfSet("StreamOptions", Clixml.Property(obj, "RemoteStreamOptions"));
                b.Summary = string.Join("; ", statements.Select(st => s_lineBreaks.Replace(st, "↵")));
                break;

            case PSRPMessageType.PipelineInput:
            case PSRPMessageType.PipelineOutput:
                b.Summary = Clixml.Preview(obj);
                b.ShowTree = true;
                break;

            case PSRPMessageType.ErrorRecord:
                string message = Clixml.Text(obj);
                b.Add("Message", message);
                b.AddIfSet("ErrorId", Clixml.Property(obj, "FullyQualifiedErrorId"));
                b.AddIfSet("Category", Clixml.Property(obj, "ErrorCategory_Message"));
                b.AddIfSet("Exception", Clixml.TypeName(Clixml.Property(obj, "Exception")));
                b.AddIfSet("TargetObject", Clixml.Property(obj, "TargetObject"));
                b.Summary = message;
                b.IsError = true;
                break;

            case PSRPMessageType.WarningRecord:
            case PSRPMessageType.VerboseRecord:
            case PSRPMessageType.DebugRecord:
                b.Summary = Clixml.Text(b.Add("Message", Clixml.Property(obj, "InformationalRecord_Message")));
                break;

            case PSRPMessageType.InformationRecord:
                object? messageData = b.Add("MessageData", Clixml.Property(obj, "MessageData"));
                string tags = string.Join(", ", Clixml.Enumerate(Clixml.Property(obj, "Tags")).Select(Clixml.Text));
                b.AddIfSet("Tags", tags);
                b.AddIfSet("Source", Clixml.Property(obj, "Source"));
                b.Summary = Clixml.Text(messageData) + (tags.Length > 0 ? $" [{tags}]" : "");
                break;

            case PSRPMessageType.ProgressRecord:
                b.Summary = FormatProgress(obj, b);
                break;

            case PSRPMessageType.RunspacePoolHostCall:
            case PSRPMessageType.PipelineHostCall:
                object? callId = Clixml.Property(obj, "ci");
                string method = Clixml.Text(b.Add("Method", Clixml.Property(obj, "mi")));
                b.Add("CallId", Clixml.Unwrap(callId) is long id && id == NoResponseCallId
                    ? $"{id} (no response)"
                    : Clixml.Text(callId));

                List<string> args = [];
                int i = 0;
                foreach (object? param in Clixml.Enumerate(Clixml.Property(obj, "mp")))
                {
                    string preview = Clixml.Preview(param);
                    b.Add($"Arg[{i++}]", preview);
                    args.Add(TextHelper.Truncate(preview, 40));
                }
                b.Summary = $"{method}({string.Join(", ", args)})";
                break;

            case PSRPMessageType.RunspacePoolHostResponse:
            case PSRPMessageType.PipelineHostResponse:
                string responseMethod = Clixml.Text(b.Add("Method", Clixml.Property(obj, "mi")));
                b.Add("CallId", Clixml.Property(obj, "ci"));
                object? exception = Clixml.Property(obj, "me");
                if (exception is not null)
                {
                    string error = Clixml.Text(exception);
                    b.Add("Error", error);
                    b.Summary = $"{responseMethod} failed: {error}";
                    b.IsError = true;
                }
                else
                {
                    object? result = Clixml.Property(obj, "mr");
                    b.Add("Result", Clixml.Preview(result));
                    b.Summary = $"{responseMethod} → {Clixml.Preview(result)}";
                }
                break;

            case PSRPMessageType.PublicKey:
                b.Summary = $"RSA public key, {Base64Length(Clixml.Property(obj, "PublicKey"))} bytes";
                break;

            case PSRPMessageType.EncryptedSessionKey:
                b.Summary = $"encrypted session key, {Base64Length(Clixml.Property(obj, "EncryptedSessionKey"))} bytes";
                break;

            case PSRPMessageType.PublicKeyRequest:
                b.Summary = "request for the client public key";
                break;

            case PSRPMessageType.SetMaxRunspaces:
                b.Summary = $"max {Clixml.Text(b.Add("MaxRunspaces", Clixml.Property(obj, "MaxRunspaces")))}{CallIdSuffix(obj, b)}";
                break;

            case PSRPMessageType.SetMinRunspaces:
                b.Summary = $"min {Clixml.Text(b.Add("MinRunspaces", Clixml.Property(obj, "MinRunspaces")))}{CallIdSuffix(obj, b)}";
                break;

            case PSRPMessageType.GetAvailableRunspaces:
            case PSRPMessageType.ResetRunspaceState:
                b.Summary = CallIdSuffix(obj, b).Trim();
                break;

            case PSRPMessageType.RunspaceAvailability:
                // The response to a set or reset is a bool, to
                // GetAvailableRunspaces the number of runspaces.
                object? response = Clixml.Unwrap(Clixml.Property(obj, "SetMinMaxRunspacesResponse"));
                string availability = response switch
                {
                    true => "succeeded",
                    false => "failed",
                    _ => $"{Clixml.Text(response)} available",
                };
                b.Add("Response", response);
                b.Summary = availability + CallIdSuffix(obj, b);
                b.IsError = response is false;
                break;

            case PSRPMessageType.GetCommandMetadata:
                StringBuilder getCommand = new("Get-Command");
                foreach (string name in new[] { "Name", "CommandType", "Namespace", "ArgumentList" })
                {
                    object? value = Clixml.Property(obj, name);
                    if (value is not null)
                    {
                        string formatted = FormatArgument(value);
                        b.Add(name, formatted);
                        getCommand.Append($" -{name} {formatted}");
                    }
                }
                b.Summary = getCommand.ToString();
                break;

            case PSRPMessageType.UserEvent:
                string source = Clixml.Text(b.Add("SourceIdentifier", Clixml.Property(obj, "PSEventArgs.SourceIdentifier")));
                object? eventData = Clixml.Property(obj, "PSEventArgs.MessageData");
                b.Add("MessageData", Clixml.Preview(eventData));
                b.AddIfSet("Sender", Clixml.Property(obj, "PSEventArgs.Sender"));
                List<string> sourceArgs = [.. Clixml.Enumerate(Clixml.Property(obj, "PSEventArgs.SourceArgs")).Select(Clixml.Preview)];
                if (sourceArgs.Count > 0)
                {
                    b.Add("SourceArgs", string.Join(", ", sourceArgs));
                }
                b.AddIfSet("EventIdentifier", Clixml.Property(obj, "PSEventArgs.EventIdentifier"));
                b.AddIfSet("ComputerName", Clixml.Property(obj, "PSEventArgs.ComputerName"));
                b.AddIfSet("RunspaceId", Clixml.Property(obj, "PSEventArgs.RunspaceId"));
                b.Summary = eventData is null ? source : $"{source}: {Clixml.Preview(eventData)}";
                break;

            default:
                b.Summary = GenericSummary(obj, b);
                b.ShowTree = true;
                break;
        }
    }

    private static void DecodeState<T>(object? obj, string propertyName, Builder b) where T : struct, Enum
    {
        object? raw = Clixml.Unwrap(Clixml.Property(obj, propertyName));
        string state = raw is int value
            ? Enum.ToObject(typeof(T), value).ToString()!
            : Clixml.Text(raw);
        b.Add("State", state);
        b.Summary = state;

        object? error = Clixml.Property(obj, "ExceptionAsErrorRecord");
        if (error is not null)
        {
            string errorMsg = Clixml.Text(error);
            b.Add("Error", errorMsg);
            b.AddIfSet("ErrorId", Clixml.Property(error, "FullyQualifiedErrorId"));
            b.Summary = $"{state}: {errorMsg}";
            b.IsError = true;
        }
    }

    private static string FormatProgress(object? obj, Builder b)
    {
        string activity = Clixml.Text(b.Add("Activity", Clixml.Property(obj, "Activity")));
        string status = Clixml.Text(b.Add("Status", Clixml.Property(obj, "StatusDescription"))).Trim();
        object? percent = b.Add("Percent", Clixml.Property(obj, "PercentComplete"));
        string type = Clixml.Text(b.Add("Type", Clixml.Property(obj, "Type")));
        b.AddIfSet("ActivityId", Clixml.Property(obj, "ActivityId"));

        StringBuilder sb = new(activity);
        if (status.Length > 0)
        {
            sb.Append(": ").Append(status);
        }
        if (Clixml.Unwrap(percent) is int pct && pct >= 0)
        {
            sb.Append($" ({pct}%)");
        }
        if (type == "Completed")
        {
            sb.Append(" (completed)");
        }

        return sb.ToString();
    }

    /// <summary>
    /// The statements of a PowerShell object, each a pipeline of commands.
    /// </summary>
    private static List<string> FormatStatements(object? powershell)
    {
        // With multiple statements ExtraCmds has every statement and Cmds is a
        // copy of the first one.
        List<object?> extraCmds = [.. Clixml.Enumerate(Clixml.Property(powershell, "ExtraCmds"))];
        IEnumerable<object?> statements = extraCmds.Count > 0 ? extraCmds : [powershell];

        return [.. statements.Select(st =>
        {
            List<object?> commands = [.. Clixml.Enumerate(Clixml.Property(st, "Cmds"))];
            return string.Join(" | ", commands.Select(c => FormatCommand(c, commands.Count > 1)));
        })];
    }

    /// <param name="cmd">The command to format.</param>
    /// <param name="inPipeline">The command is one of several in a pipeline.</param>
    private static string FormatCommand(object? cmd, bool inPipeline)
    {
        string name = Clixml.Text(Clixml.Property(cmd, "Cmd"));

        List<string> suffix = [];
        foreach (object? arg in Clixml.Enumerate(Clixml.Property(cmd, "Args")))
        {
            object? argName = Clixml.Unwrap(Clixml.Property(arg, "N"));
            object? argValue = Clixml.Property(arg, "V");
            if (argName is string n && n.Length > 0)
            {
                // A switch is sent as a bool value, only an explicit false
                // needs the value shown.
                object? baseValue = Clixml.Unwrap(argValue);
                suffix.Add(baseValue switch
                {
                    false => $"-{n}:$false",
                    true => $"-{n}",
                    _ => $"-{n} {FormatArgument(argValue)}",
                });
            }
            else
            {
                suffix.Add(FormatArgument(argValue));
            }
        }
        suffix.AddRange(FormatRedirections(cmd));

        // UseLocalScope is unset unless the caller chose one. An unset script
        // runs in the current scope like it was dot sourced while an unset
        // command, like a function, gets its own scope. Only the one that
        // differs from how it would normally be written is marked.
        object? localScope = Clixml.Unwrap(Clixml.Property(cmd, "UseLocalScope"));
        string command;
        if (Clixml.Unwrap(Clixml.Property(cmd, "IsScript")) is true)
        {
            string script = name.Trim();
            if (localScope is true)
            {
                command = $"& {ScriptBlock(script)}";
            }
            else if (suffix.Count > 0 || inPipeline)
            {
                // Without the braces the arguments, redirections, or pipe
                // would read as part of the script's last statement.
                command = $". {ScriptBlock(script)}";
            }
            else
            {
                command = string.Join("\n", script.Split('\n').Select(l => l.TrimEnd('\r')));
            }
        }
        else
        {
            command = localScope is false ? $". {name}" : name;
        }

        return suffix.Count == 0 ? command : $"{command} {string.Join(" ", suffix)}";
    }

    private static string ScriptBlock(string script) => script.Contains('\n')
        ? $"{{\n{string.Join("\n", script.Split('\n').Select(l => $"    {l.TrimEnd('\r')}"))}\n}}"
        : $"{{ {script} }}";

    private static IEnumerable<string> FormatRedirections(object? cmd)
    {
        List<(int Stream, int Target)> merges = [];
        foreach ((string property, int stream) in s_mergeStreams)
        {
            int target = MergeValue(Clixml.Property(cmd, property));
            if (target != 0)
            {
                merges.Add((stream, target));
            }
        }

        // Older clients only set MergeMyResult and MergeToResult, they can only
        // merge the error stream or all of them.
        if (merges.Count == 0)
        {
            int from = MergeValue(Clixml.Property(cmd, "MergeMyResult"));
            int to = MergeValue(Clixml.Property(cmd, "MergeToResult"));
            if (from != 0 && to != 0)
            {
                merges.AddRange(from == 7
                    ? s_mergeStreams.Select(m => (m.Stream, to))
                    : [(from, to)]);
            }
        }

        if (merges.Count == s_mergeStreams.Length && merges.All(m => m.Target == merges[0].Target))
        {
            yield return $"*>{RedirectTarget(merges[0].Target)}";
            yield break;
        }

        foreach ((int stream, int target) in merges)
        {
            yield return $"{stream}>{RedirectTarget(target)}";
        }
    }

    /// <summary>
    /// Whether a string argument needs quotes to be read back as the same
    /// string. PowerShell's parser decides, a value it doesn't read as a single
    /// bare word, like one with a space, a leading dash that makes it a
    /// parameter, or one that looks like a number, is quoted.
    /// </summary>
    private static bool NeedsQuotes(string value)
    {
        if (value.Length == 0)
        {
            return true;
        }

        ScriptBlockAst ast = Parser.ParseInput($"x {value}", out _, out ParseError[] errors);
        return errors.Length > 0 ||
            ast.EndBlock?.Statements is not [PipelineAst { PipelineElements: [CommandAst { CommandElements: [_, StringConstantExpressionAst arg] }] }] ||
            arg.StringConstantType != StringConstantType.BareWord ||
            arg.Value != value;
    }

    private static int MergeValue(object? value) => Clixml.Unwrap(value) is int i ? i : 0;

    // PipelineResultTypes Output is 1 and Null is 8.
    private static string RedirectTarget(int target) => target switch
    {
        1 => "&1",
        8 => "$null",
        _ => $"&{target}",
    };

    /// <summary>
    /// Formats an argument value like it would be written in PowerShell.
    /// Strings can be bare words as a command argument but need quotes as a
    /// value in a hashtable or object.
    /// </summary>
    private static string FormatArgument(object? value, bool quoteStrings = false, int depth = 0)
    {
        if (depth >= MaxArgumentDepth)
        {
            return TextHelper.Ellipsis.ToString();
        }

        object? baseObj = Clixml.Unwrap(value);
        switch (baseObj)
        {
            case null:
                return "$null";

            case string s:
                return quoteStrings || NeedsQuotes(s)
                    ? $"'{CodeGeneration.EscapeSingleQuotedStringContent(s)}'"
                    : s;

            case bool b:
                return b ? "$true" : "$false";

            case IDictionary dict:
                IEnumerable<string> entries = dict.Cast<DictionaryEntry>()
                    .Select(e => $"{FormatArgument(e.Key, depth: depth + 1)} = {FormatArgument(e.Value, true, depth + 1)}");
                return $"@{{{string.Join("; ", entries)}}}";

            case IEnumerable enumerable:
                List<string> items = [.. enumerable.Cast<object?>().Select(i => FormatArgument(i, quoteStrings, depth + 1))];
                return items.Count == 1 ? $"@({items[0]})" : string.Join(", ", items);

            case PSObject pso when pso.BaseObject is PSCustomObject && pso.Properties.Any():
                IEnumerable<string> props = pso.Properties
                    .Select(p => $"{p.Name} = {FormatArgument(Clixml.Property(pso, p.Name), true, depth + 1)}");
                return $"[{Clixml.TypeName(pso)}]@{{{string.Join("; ", props)}}}";

            default:
                return Clixml.Text(value);
        }
    }

    private static string GenericSummary(object? obj, Builder b)
    {
        if (obj is PSObject pso && pso.BaseObject is PSCustomObject)
        {
            List<string> parts = [];
            foreach (PSPropertyInfo prop in pso.Properties)
            {
                object? value = Clixml.Property(obj, prop.Name);
                b.Add(prop.Name, Clixml.Preview(value));
                parts.Add($"{prop.Name}={Clixml.Preview(value)}");
            }

            return string.Join(", ", parts);
        }

        return Clixml.Preview(obj);
    }

    private static string CallIdSuffix(object? obj, Builder b)
    {
        object? callId = Clixml.Property(obj, "ci");
        if (callId is null)
        {
            return "";
        }

        b.Add("CallId", callId);
        return $" (ci {Clixml.Text(callId)})";
    }

    private static object? DictionaryValue(object? dict, string key)
        => Clixml.Unwrap(dict) is IDictionary d && d.Contains(key) ? d[key] : null;

    private static int Base64Length(object? value)
    {
        string text = Clixml.Text(value);
        return text.Length * 3 / 4 - (text.EndsWith("==", StringComparison.Ordinal) ? 2 : text.EndsWith("=", StringComparison.Ordinal) ? 1 : 0);
    }

    private sealed class Builder(object? obj)
    {
        private readonly List<KeyValuePair<string, string>> _fields = [];

        public string Summary { get; set; } = "";
        public bool ShowTree { get; set; }
        public bool IsError { get; set; }

        public object? Add(string name, object? value)
        {
            _fields.Add(new(name, value is string s ? TextHelper.Sanitize(s) : TextHelper.Sanitize(Clixml.Text(value))));
            return value;
        }

        /// <summary>
        /// Adds a value that keeps its line breaks, for the views that can show
        /// more than one line.
        /// </summary>
        public void AddMultiline(string name, string value)
        {
            IEnumerable<string> lines = value.Split('\n').Select(l => TextHelper.Sanitize(l.TrimEnd('\r')));
            _fields.Add(new(name, string.Join("\n", lines)));
        }

        public void AddIfSet(string name, object? value)
        {
            if (value is not null && !(value is string s && s.Length == 0))
            {
                Add(name, value);
            }
        }

        public DecodedMessage Build() => new(
            TextHelper.Sanitize(Summary),
            _fields,
            ShowTree ? Clixml.BuildTree(null, obj) : null,
            IsError);
    }
}
