using System;
using System.Collections;
using System.Collections.Generic;
using System.Management.Automation;
using System.Text.RegularExpressions;

namespace RemoteWrench.Ext;

/// <summary>A function Enter-ExtSession defines in the remote session.</summary>
public abstract class ExtDefinition
{
    private static readonly Regex s_validName = new(@"^[\w-]+$", RegexOptions.Compiled);

    private protected ExtDefinition(string name, ParsedScript? serverScript)
    {
        if (!s_validName.IsMatch(name))
        {
            throw new ArgumentException(
                $"'{name}' is not a valid function name, it can only contain letters, digits, underscores and dashes.");
        }

        Name = name;
        ServerParsed = serverScript;
    }

    /// <summary>The name of the function in the remote session.</summary>
    public string Name { get; }

    /// <summary>The script that runs in the remote session, if any.</summary>
    internal ParsedScript? ServerParsed { get; }

    /// <summary>How the remote script treats the definition.</summary>
    internal abstract string Kind { get; }

    /// <summary>The definition sent to the remote session.</summary>
    internal virtual Hashtable ToServerDefinition() => new()
    {
        ["Name"] = Name,
        ["Kind"] = Kind,
        ["Script"] = ServerParsed?.Text,
        ["ParamBlock"] = ServerParsed?.ParamBlock,
        ["ScriptIsAdvanced"] = ServerParsed?.IsAdvanced ?? false,
        ["UsingValues"] = ServerParsed?.UsingValues ?? new Hashtable(),
    };
}

/// <summary>A function that only runs in the remote session.</summary>
public sealed class ExtFunction : ExtDefinition
{
    internal ExtFunction(string name, ParsedScript script)
        : base(name, script)
    { }

    /// <summary>Defines a local function in the remote session.</summary>
    /// <param name="function">The function to define.</param>
    /// <param name="usingState">The session state to get its $using: values from.</param>
    /// <param name="name">The name to define it as, defaults to the function's name.</param>
    /// <returns>The function definition.</returns>
    /// <exception cref="ArgumentException">The function can't be defined remotely.</exception>
    internal static ExtFunction FromFunctionInfo(FunctionInfo function, SessionState usingState, string? name = null)
    {
        string description = name is null || name == function.Name
            ? $"function '{function.Name}'"
            : $"function '{function.Name}' of alias '{name}'";
        return new(name ?? function.Name, ScriptParser.Parse(function.ScriptBlock, usingState, description));
    }

    /// <summary>The script of the function.</summary>
    public string Definition => ServerParsed!.Text;

    internal override string Kind => "Function";
}

/// <summary>A function in the remote session that runs code on the client.</summary>
/// <remarks>
/// The client code is run like a command whose pipeline input comes from the server, its output is sent back as
/// it is written. Without a server script the remote function is a proxy for it with the same parameters. With one,
/// the server script calls the client code through Invoke-ExtCallback, a proxy with the same parameters.
/// </remarks>
public abstract class ExtCallback : ExtDefinition
{
    private protected ExtCallback(string name, ParsedScript client, ParsedScript? serverScript)
        : base(name, serverScript)
    {
        ClientParsed = client;
    }

    /// <summary>The param block of the client code, the remote proxy for it uses it.</summary>
    internal ParsedScript ClientParsed { get; }

    internal override string Kind => "Callback";

    /// <summary>
    /// Whether the client code runs on the runspace that entered the session, a script needs to. Otherwise it runs
    /// on its own thread.
    /// </summary>
    internal abstract bool RunsOnLocalRunspace { get; }

    /// <summary>Runs the client code. Its output is sent to the server with the context's channel.</summary>
    /// <param name="context">The details of the call.</param>
    internal abstract void InvokeClient(ExtCallbackContext context);

    internal override Hashtable ToServerDefinition()
    {
        Hashtable definition = base.ToServerDefinition();
        definition["ClientParamBlock"] = ClientParsed.ParamBlock;
        definition["ClientIsAdvanced"] = ClientParsed.IsAdvanced;
        return definition;
    }
}

/// <summary>A callback whose client code is a scriptblock.</summary>
public sealed class ExtScriptCallback : ExtCallback
{
    // Invoke the client script with its arguments, and the pipeline input
    // from the server if it has any, and send each output to the server as it
    // is written. Non-terminating errors are merged in so they are sent too.
    private const string InvokerScript =
        "{ & $__ExtClientScript @__ExtParameter @__ExtArgumentList 2>&1 | ForEach-Object { $__ExtSink.Invoke($_) } }";

    private const string InputInvokerScript =
        "{ $__ExtInput | & $__ExtClientScript @__ExtParameter @__ExtArgumentList 2>&1 | " +
        "ForEach-Object { $__ExtSink.Invoke($_) } }";

    private readonly ScriptBlock _invoker;
    private readonly ScriptBlock _inputInvoker;

    internal ExtScriptCallback(
        string name,
        ScriptBlock clientScript,
        SessionState callerState,
        ParsedScript? serverScript)
        : base(
            name,
            ScriptParser.Parse(clientScript, null, $"client script of callback '{name}'"),
            serverScript)
    {
        ClientScript = clientScript;

        // A scriptblock runs in the session state it was created in, so the
        // invoker has to be in the same one to pass it the variables it uses.
        // That is its module or otherwise the caller's. Evaluating the
        // scriptblock literal there gives an invoker bound to it, nothing is
        // defined in it.
        SessionState sessionState = clientScript.Module?.SessionState ?? callerState;
        _invoker = CreateInvoker(sessionState, InvokerScript);
        _inputInvoker = CreateInvoker(sessionState, InputInvokerScript);
    }

    /// <summary>The script that runs on the client.</summary>
    public ScriptBlock ClientScript { get; }

    /// <summary>The script that runs in the remote session, if any.</summary>
    public string? ServerScript => ServerParsed?.Text;

    internal override bool RunsOnLocalRunspace => true;

    internal override void InvokeClient(ExtCallbackContext context)
    {
        ExtChannel channel = context.Channel;
        Action<object?> sink = value =>
        {
            if (value is PSObject { BaseObject: ErrorRecord } psObj)
            {
                value = psObj.BaseObject;
            }

            if (value is ErrorRecord errorRecord)
            {
                channel.WriteError(errorRecord.ToString());
            }
            else
            {
                channel.Write(value);
            }
        };

        // The client script runs in a child scope of the invoker, the
        // invoker's own variables are private so it can't see them. The
        // ForEach-Object script block runs in the invoker's scope so it can.
        List<PSVariable> variables =
        [
            new("ExtCallbackContext", context),
            new("__ExtClientScript", ClientScript, ScopedItemOptions.Private),
            new("__ExtParameter", context.Parameter, ScopedItemOptions.Private),
            new("__ExtArgumentList", context.ArgumentList, ScopedItemOptions.Private),
            new("__ExtSink", sink, ScopedItemOptions.Private),
        ];

        if (channel.ExpectingInput)
        {
            variables.Add(new("__ExtInput", channel.ReadInput(), ScopedItemOptions.Private));
            _inputInvoker.InvokeWithContext(null, variables);
        }
        else
        {
            _invoker.InvokeWithContext(null, variables);
        }
    }

    private static ScriptBlock CreateInvoker(SessionState sessionState, string script)
        => (ScriptBlock)sessionState.InvokeCommand.InvokeScript(
            sessionState,
            ScriptBlock.Create(script))[0].BaseObject;
}
