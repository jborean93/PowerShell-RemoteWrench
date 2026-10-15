using System;
using System.Collections;
using System.IO;
using System.Management.Automation;

namespace RemoteWrench.Ext;

/// <summary>A callback built into the module, its client code is C# that runs on its own thread.</summary>
/// <remarks>
/// The server script is an embedded resource. The client param block is only used for Invoke-ExtCallback, the
/// proxy of the client code in the server script.
/// </remarks>
public abstract class ExtBuiltinCallback : ExtCallback
{
    private protected ExtBuiltinCallback(string name, string clientParamBlock, string serverScriptResource)
        : base(
            name,
            ScriptParser.Parse(
                ScriptBlock.Create(clientParamBlock),
                null,
                $"client parameters of callback '{name}'"),
            ScriptParser.Parse(
                ScriptBlock.Create(GetResource(serverScriptResource)),
                null,
                $"server script of callback '{name}'"))
    { }

    internal override bool RunsOnLocalRunspace => false;

    /// <summary>Gets a named argument from the server, converted to the type.</summary>
    private protected static T? GetParameter<T>(ExtCallbackContext context, string name)
    {
        foreach (DictionaryEntry entry in context.Parameter)
        {
            if (string.Equals(entry.Key as string, name, StringComparison.OrdinalIgnoreCase))
            {
                return LanguagePrimitives.ConvertTo<T>(ExtSession.Unwrap(entry.Value));
            }
        }

        return default;
    }

    /// <summary>Whether the server passed a named argument.</summary>
    private protected static bool HasParameter(ExtCallbackContext context, string name)
    {
        foreach (DictionaryEntry entry in context.Parameter)
        {
            if (string.Equals(entry.Key as string, name, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    internal static string GetResource(string name)
    {
        string resource = $"RemoteWrench.Ext.{name}";
        using Stream stream = typeof(ExtBuiltinCallback).Assembly.GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException($"The embedded resource '{resource}' is missing.");
        using StreamReader reader = new(stream);
        return reader.ReadToEnd();
    }
}
