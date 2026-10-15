using System;
using System.Management.Automation;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using RemoteWrench.Ext;

namespace RemoteWrench.Commands;

[Cmdlet(
    VerbsCommon.New, "ExtEditCallback"
)]
[OutputType(typeof(ExtEditCallback))]
public sealed class NewExtEditCallback : PSCmdlet
{
    private static readonly Regex s_quotedCommand = new(@"^""(?<exe>[^""]+)""\s*(?<args>.*)$", RegexOptions.Compiled);
    private static readonly Regex s_command = new(@"^(?<exe>\S+)\s*(?<args>.*)$", RegexOptions.Compiled);

    [Parameter(
        Position = 0
    )]
    public string Name { get; set; } = "PSEdit";

    [Parameter]
    public string? Editor { get; set; }

    protected override void EndProcessing()
    {
        string? editorPath;
        string? editorArguments;
        try
        {
            (editorPath, editorArguments) = ResolveEditor();
        }
        catch (ArgumentException e)
        {
            ThrowTerminatingError(new(
                e,
                "EditorNotFound",
                ErrorCategory.ObjectNotFound,
                Editor));
            return;
        }

        ExtEditCallback callback;
        try
        {
            callback = new(Name, editorPath, editorArguments);
        }
        catch (ArgumentException e)
        {
            ThrowTerminatingError(new(
                e,
                "InvalidExtEditCallback",
                ErrorCategory.InvalidArgument,
                Name));
            return;
        }

        WriteObject(callback);
    }

    /// <summary>Finds the editor, a missing one is an error now rather than when a file is edited.</summary>
    private (string? Path, string? Arguments) ResolveEditor()
    {
        string? command = FirstValue(
            Editor,
            Environment.GetEnvironmentVariable("VISUAL"),
            Environment.GetEnvironmentVariable("EDITOR"));
        if (command is not null)
        {
            command = command.Trim();

            // The whole value is the executable if it is one, like a path with
            // spaces. Otherwise it is a leading quoted value or the first word,
            // followed by its arguments.
            string exe = command;
            string arguments = "";
            if (FindApplication(command) is null)
            {
                Match match = s_quotedCommand.Match(command);
                if (!match.Success)
                {
                    match = s_command.Match(command);
                }
                exe = match.Groups["exe"].Value;
                arguments = match.Groups["args"].Value;
            }

            string path = FindApplication(exe)
                ?? throw new ArgumentException($"The editor '{exe}' from '{command}' could not be found.");
            return (path, arguments);
        }

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            // The edit verb depends on the file type, it is picked when the
            // file is edited.
            return (null, null);
        }

        foreach (string candidate in new[] { "editor", "nano", "vi" })
        {
            if (FindApplication(candidate) is string path)
            {
                return (path, "");
            }
        }

        throw new ArgumentException("No editor found, set $env:EDITOR or use -Editor.");
    }

    private string? FindApplication(string name)
        => InvokeCommand.GetCommand(name, CommandTypes.Application) is ApplicationInfo app ? app.Source : null;

    private static string? FirstValue(params string?[] values)
    {
        foreach (string? value in values)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return null;
    }
}
