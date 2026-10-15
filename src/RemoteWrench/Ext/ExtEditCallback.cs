using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace RemoteWrench.Ext;

/// <summary>A callback that edits a remote file with an editor on the client.</summary>
public sealed class ExtEditCallback : ExtBuiltinCallback
{
    internal ExtEditCallback(string name, string? editorPath, string? editorArguments)
        : base(name, "param ([string]$Name, [byte[]]$Content)", "EditFile.ps1")
    {
        EditorPath = editorPath;
        EditorArguments = editorArguments ?? "";
    }

    /// <summary>The editor executable, null uses the edit verb of the file on Windows.</summary>
    public string? EditorPath { get; }

    /// <summary>The arguments before the file path, if any.</summary>
    public string EditorArguments { get; }

    internal override void InvokeClient(ExtCallbackContext context)
    {
        // The name comes from the server, only its file name is used. It
        // keeps the extension so the editor knows the type of the file.
        string name = Path.GetFileName(GetParameter<string>(context, "Name") ?? "");
        if (string.IsNullOrWhiteSpace(name))
        {
            name = "file";
        }
        byte[] content = GetParameter<byte[]>(context, "Content") ?? [];

        string tempDir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
        Directory.CreateDirectory(tempDir);
        try
        {
            string tempFile = Path.Combine(tempDir, name);
            File.WriteAllBytes(tempFile, content);

            // The editor uses the console, nothing is redirected. The remote
            // command waits so the console isn't reading input meanwhile.
            using Process process = Process.Start(GetStartInfo(tempFile))
                ?? throw new InvalidOperationException($"Failed to start the editor for '{tempFile}'.");
            process.WaitForExit();

            // A failing exit code, like :cq in vim, cancels the edit.
            if (process.ExitCode != 0)
            {
                return;
            }

            byte[] newContent = File.ReadAllBytes(tempFile);
            if (!newContent.SequenceEqual(content))
            {
                context.Channel.Write(newContent);
            }
        }
        finally
        {
            Directory.Delete(tempDir, true);
        }
    }

    private ProcessStartInfo GetStartInfo(string file)
    {
        if (EditorPath is not null)
        {
            return new(EditorPath, $"{EditorArguments} \"{file}\"".Trim())
            {
                UseShellExecute = false,
            };
        }

        // Windows without an editor command, the file type's edit verb or
        // otherwise notepad.
        ProcessStartInfo verbInfo = new(file);
        if (verbInfo.Verbs.Contains("edit", StringComparer.OrdinalIgnoreCase))
        {
            return new(file)
            {
                UseShellExecute = true,
                Verb = "edit",
            };
        }

        return new("notepad.exe", $"\"{file}\"")
        {
            UseShellExecute = false,
        };
    }
}
