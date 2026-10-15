using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using RemoteWrench.Ext;

namespace RemoteWrench.Commands;

/// <summary>Enters a remote session with extension functions.</summary>
/// <remarks>
/// Besides -SessionFactory, it has the parameters of New-PSSession that create a session as dynamic parameters so
/// they follow the installed PowerShell, like the SSH parameters only PowerShell 7 has.
/// </remarks>
[Cmdlet(
    VerbsCommon.Enter, "ExtSession",
    DefaultParameterSetName = "ComputerName"
)]
[OutputType(typeof(void))]
public sealed class EnterExtSession : PSCmdlet, IDynamicParameters
{
    private const string FactoryParameterSet = "SessionFactory";
    private const string NewPSSessionCommand = "Microsoft.PowerShell.Core\\New-PSSession";

    // New-PSSession parameters that don't apply to the one session this
    // creates. -Session makes a new session like an existing one, not entering
    // that session.
    private static readonly HashSet<string> s_excludedParameters = new(StringComparer.OrdinalIgnoreCase)
    {
        "Name",
        "Session",
        "ThrottleLimit",
    };

    // The parameter sets of the excluded parameters, other parameters in them
    // aren't in them here.
    private static readonly HashSet<string> s_excludedParameterSets = new(StringComparer.OrdinalIgnoreCase)
    {
        "Session",
    };

    // The New-PSSession parameters that say what to connect to, each one
    // creates a session per value.
    private static readonly string[] s_targetParameters =
    [
        "ComputerName",
        "ConnectionUri",
        "ContainerId",
        "HostName",
        "SSHConnection",
        "VMId",
        "VMName",
    ];

    private static readonly HashSet<string> s_commonParameters = new(StringComparer.OrdinalIgnoreCase)
    {
        "Verbose", "Debug", "ErrorAction", "WarningAction", "InformationAction", "ProgressAction", "ErrorVariable",
        "WarningVariable", "InformationVariable", "OutVariable", "OutBuffer", "PipelineVariable", "WhatIf", "Confirm",
        "UseTransaction",
    };

    private readonly List<ExtDefinition> _definitions = [];
    private readonly HashSet<string> _names = new(StringComparer.OrdinalIgnoreCase);
    private RuntimeDefinedParameterDictionary? _sessionParameters;

    [Parameter(
        Mandatory = true,
        Position = 0,
        ParameterSetName = FactoryParameterSet
    )]
    public ScriptBlock SessionFactory { get; set; } = default!;

    [Parameter(
        ValueFromPipeline = true
    )]
    public object[] Function { get; set; } = [];

    protected override void ProcessRecord()
    {
        foreach (object? value in Function)
        {
            ExtDefinition? definition;
            try
            {
                definition = ExtSession.Unwrap(value) switch
                {
                    ExtDefinition d => d,
                    FunctionInfo f => ExtFunction.FromFunctionInfo(f, SessionState),
                    // An alias is defined with its own name, it is the name
                    // the user asked for.
                    string name => ExtFunction.FromFunctionInfo(GetFunction(name), SessionState, name),
                    _ => throw new ArgumentException(
                        $"-Function must be a definition from New-ExtFunction or New-ExtCallback, a function from " +
                        $"Get-Command, or the name of a function, not " +
                        $"{ExtSession.Unwrap(value)?.GetType().FullName ?? "null"}."),
                };
            }
            catch (ArgumentException e)
            {
                WriteError(new(
                    e,
                    "InvalidExtFunction",
                    ErrorCategory.InvalidArgument,
                    value));
                continue;
            }

            if (!_names.Add(definition.Name))
            {
                WriteError(new(
                    new ArgumentException($"A function named '{definition.Name}' was already provided, ignoring this one."),
                    "DuplicateExtFunctionName",
                    ErrorCategory.InvalidArgument,
                    value));
                continue;
            }
            _definitions.Add(definition);
        }
    }

    public object GetDynamicParameters()
    {
        _sessionParameters = new();
        if (InvokeCommand.GetCommand(NewPSSessionCommand, CommandTypes.Cmdlet) is not CmdletInfo newPSSession)
        {
            return _sessionParameters;
        }

        foreach (KeyValuePair<string, ParameterMetadata> kvp in newPSSession.Parameters)
        {
            if (s_excludedParameters.Contains(kvp.Key) || s_commonParameters.Contains(kvp.Key))
            {
                continue;
            }

            // The attributes have the parameter sets, aliases and validation
            // of New-PSSession's parameter, they make the same sets here.
            Collection<Attribute> attributes = [];
            bool inParameterSet = false;
            foreach (Attribute attribute in kvp.Value.Attributes)
            {
                if (attribute is ParameterAttribute parameterAttribute)
                {
                    if (s_excludedParameterSets.Contains(parameterAttribute.ParameterSetName))
                    {
                        continue;
                    }
                    inParameterSet = true;

                    // Pipeline input is for -Function, an object with a
                    // property like ComputerName would bind to it too. The
                    // attribute is New-PSSession's own so a copy is changed.
                    ParameterAttribute copy = new()
                    {
                        ParameterSetName = parameterAttribute.ParameterSetName,
                        Position = parameterAttribute.Position,
                        Mandatory = parameterAttribute.Mandatory,
                        ValueFromRemainingArguments = parameterAttribute.ValueFromRemainingArguments,
                        DontShow = parameterAttribute.DontShow,
                    };
                    // The setter rejects an empty message.
                    if (!string.IsNullOrEmpty(parameterAttribute.HelpMessage))
                    {
                        copy.HelpMessage = parameterAttribute.HelpMessage;
                    }
                    attributes.Add(copy);
                    continue;
                }
                attributes.Add(attribute);
            }
            if (inParameterSet)
            {
                _sessionParameters.Add(kvp.Key, new(kvp.Key, kvp.Value.ParameterType, attributes));
            }
        }

        return _sessionParameters;
    }

    private FunctionInfo GetFunction(string name)
    {
        CommandInfo? command = InvokeCommand.GetCommand(name, CommandTypes.All);
        string description = $"'{name}'";
        if (command is AliasInfo alias)
        {
            command = alias.ResolvedCommand;
            if (command is null)
            {
                throw new ArgumentException(
                    $"'{name}' is an alias to '{alias.Definition}' which was not found, -Function must be the name " +
                    "of a function or an alias to one.");
            }
            description = $"'{name}' is an alias to '{command.Name}' which";
        }

        return command switch
        {
            FunctionInfo function => function,
            null => throw new ArgumentException(
                $"No function named '{name}' was found, -Function must be the name of a function or an alias to one."),
            _ => throw new ArgumentException(
                $"{description} is a {command.CommandType}, -Function must be the name of a function or an alias to " +
                "one."),
        };
    }

    protected override void EndProcessing()
    {
        // The host of a cmdlet always implements the interface, it throws if
        // the actual host doesn't support it. Check before creating the
        // session rather than fail when entering it.
        IHostSupportsInteractiveSession? interactiveHost = Host as IHostSupportsInteractiveSession;
        try
        {
            _ = interactiveHost?.IsRunspacePushed;
        }
        catch (Exception)
        {
            interactiveHost = null;
        }
        if (interactiveHost is null)
        {
            ThrowTerminatingError(new(
                new PSNotSupportedException(
                    $"The host '{Host.Name}' does not support entering a remote session, run Enter-ExtSession " +
                    "from an interactive host like the PowerShell console."),
                "HostIsNotInteractive",
                ErrorCategory.InvalidOperation,
                null));
            return;
        }

        (Runspace runspace, PSSession? session) = ParameterSetName == FactoryParameterSet
            ? InvokeSessionFactory()
            : NewSession();
        try
        {
            ExtSession.Create(runspace, Runspace.DefaultRunspace, Host, _definitions);
        }
        catch (Exception e)
        {
            runspace.Dispose();
            ThrowTerminatingError(new(
                e,
                "ExtSessionSetupFailed",
                ErrorCategory.OpenError,
                null));
            return;
        }

        // The session is created for this cmdlet, close it when the user exits
        // it like Enter-PSSession -ComputerName does. There is no public API
        // for this.
        PropertyInfo? closeOnPop = runspace.GetType().GetProperty(
            "ShouldCloseOnPop",
            BindingFlags.Instance | BindingFlags.NonPublic);
        if (closeOnPop is null)
        {
            WriteWarning(
                "Failed to mark the remote session to close on exit, it stays open after exiting it. Close it " +
                "with Remove-PSSession or by disposing of its Runspace.");
        }
        else
        {
            closeOnPop.SetValue(runspace, true);
        }

        try
        {
            interactiveHost.PushRunspace(runspace);
        }
        catch (Exception e)
        {
            runspace.Dispose();
            ThrowTerminatingError(new(
                e,
                "PushRunspaceFailed",
                ErrorCategory.InvalidOperation,
                null));
        }

        if (session is not null)
        {
            RemoveOnClose(session);
        }
    }

    private (Runspace, PSSession?) NewSession()
    {
        CmdletInfo newPSSession = (CmdletInfo)InvokeCommand.GetCommand(NewPSSessionCommand, CommandTypes.Cmdlet);
        Dictionary<string, object?> parameters = new(StringComparer.OrdinalIgnoreCase);
        foreach (RuntimeDefinedParameter parameter in (IEnumerable<RuntimeDefinedParameter>?)_sessionParameters?.Values ?? [])
        {
            if (!parameter.IsSet)
            {
                continue;
            }

            // New-PSSession creates a session for each value, this enters one.
            if (Array.IndexOf(s_targetParameters, parameter.Name) >= 0 &&
                parameter.Value is ICollection { Count: > 1 } values)
            {
                ThrowTerminatingError(new(
                    new ArgumentException(
                        $"-{parameter.Name} has {values.Count} values, Enter-ExtSession enters one session."),
                    "MultipleSessionTargets",
                    ErrorCategory.InvalidArgument,
                    parameter.Value));
            }
            parameters[parameter.Name] = parameter.Value;
        }

        Collection<PSObject> output;
        ErrorRecord? error = null;
        using (PowerShell ps = PowerShell.Create(RunspaceMode.CurrentRunspace))
        {
            ps.AddCommand(newPSSession).AddParameters(parameters);
            try
            {
                output = ps.Invoke();
            }
            catch (RuntimeException e)
            {
                output = [];
                error = e.ErrorRecord;
            }
            if (error is null && ps.Streams.Error.Count > 0)
            {
                error = ps.Streams.Error[0];
            }
        }

        if (error is not null)
        {
            ThrowTerminatingError(new(
                error.Exception,
                "NewPSSessionFailed",
                ErrorCategory.OpenError,
                error.TargetObject)
            {
                ErrorDetails = new($"Failed to create the session: {error}"),
            });
        }

        return GetSessionRunspace(output, "New-PSSession");
    }

    /// <summary>Removes a session from Get-PSSession once it is closed when the user exits it.</summary>
    /// <remarks>
    /// New-PSSession adds the session it creates to the sessions of the runspace, so it would stay in Get-PSSession
    /// as closed after exiting it. Remove-PSSession has to run in the local runspace, it runs as the action of an
    /// event, which the runspace runs once it is idle.
    /// </remarks>
    private static void RemoveOnClose(PSSession session)
    {
        Runspace local = Runspace.DefaultRunspace;
        string sourceIdentifier = $"RemoteWrench.Ext.RemoveSession.{session.InstanceId}";
        local.Events.SubscribeEvent(
            null,
            null,
            sourceIdentifier,
            null,
            ScriptBlock.Create(
                $"Microsoft.PowerShell.Core\\Remove-PSSession -InstanceId '{session.InstanceId}' -ErrorAction Ignore\n" +
                $"Microsoft.PowerShell.Utility\\Unregister-Event -SourceIdentifier '{sourceIdentifier}' -Force"),
            true,
            false);

        int removed = 0;
        session.Runspace.StateChanged += (_, e) =>
        {
            if (e.RunspaceStateInfo.State is RunspaceState.Closed or RunspaceState.Broken &&
                Interlocked.Exchange(ref removed, 1) == 0)
            {
                local.Events.GenerateEvent(sourceIdentifier, null, null, null);
            }
        };
    }

    private (Runspace, PSSession?) InvokeSessionFactory()
    {
        Collection<PSObject> output;
        try
        {
            output = SessionFactory.Invoke();
        }
        catch (RuntimeException e)
        {
            ThrowTerminatingError(new(
                new ExtSessionException($"The -SessionFactory scriptblock failed: {ExtSession.FormatException(e)}", e),
                "SessionFactoryFailed",
                ErrorCategory.OpenError,
                null));
            throw; // Unreachable, ThrowTerminatingError always throws.
        }

        return GetSessionRunspace(output, "The -SessionFactory scriptblock");
    }

    private (Runspace, PSSession?) GetSessionRunspace(Collection<PSObject> output, string source)
    {
        List<object> values = [];
        foreach (PSObject? obj in output)
        {
            if (obj is not null)
            {
                values.Add(obj.BaseObject);
            }
        }

        if (values.Count != 1)
        {
            ThrowTerminatingError(new(
                new ArgumentException(
                    $"{source} must output one PSSession or remote Runspace but it output {values.Count} objects. " +
                    "If it failed to create the session, the error above says why."),
                "InvalidSessionFactoryOutput",
                ErrorCategory.InvalidResult,
                values));
        }

        PSSession? session = values[0] as PSSession;
        Runspace? runspace = session?.Runspace ?? values[0] as Runspace;
        if (runspace is null || !runspace.RunspaceIsRemote)
        {
            ThrowTerminatingError(new(
                new ArgumentException(
                    $"{source} must output a PSSession or remote Runspace but it output " +
                    $"{(runspace is null ? values[0].GetType().FullName : "a local Runspace")}."),
                "InvalidSessionFactoryOutput",
                ErrorCategory.InvalidResult,
                values[0]));
        }

        return (runspace!, session);
    }
}
