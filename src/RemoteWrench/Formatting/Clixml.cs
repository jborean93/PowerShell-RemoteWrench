using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Text.RegularExpressions;

namespace RemoteWrench.Formatting;

/// <summary>
/// A node of a deserialized CLIXML value, used by the views that show the
/// message data as a tree.
/// </summary>
internal sealed record ClixmlNode(string Label, IReadOnlyList<ClixmlNode> Children);

/// <summary>
/// Helpers to deserialize PSRP message data and read its properties.
/// </summary>
internal static class Clixml
{
    private const int MaxDepth = 8;
    private const int MaxChildren = 50;
    private const int MaxValueLength = 300;

    // A SecureString cannot be deserialized without the session key.
    private static readonly Regex s_secureString = new(@"<SS( N=""[^""]*"")?>[^<]*</SS>", RegexOptions.Compiled);

    /// <summary>
    /// The value shown in place of a SecureString. The value is not decoded,
    /// even when the transport sends it unencrypted.
    /// </summary>
    public const string SecureStringMarker = "[SecureString]";

    public static object? Deserialize(string data)
    {
        string clean = s_secureString.Replace(data, m => $"<S{m.Groups[1].Value}>{SecureStringMarker}</S>");
        string clixml = $"""<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">{clean}</Objs>""";
        return PSSerializer.Deserialize(clixml);
    }

    public static object? Property(object? obj, string name)
    {
        if (obj is not PSObject pso)
        {
            return null;
        }

        try
        {
            return pso.Properties[name]?.Value;
        }
        catch (GetValueException)
        {
            return null;
        }
    }

    public static object? Unwrap(object? value)
        => value is PSObject pso && pso.BaseObject is not PSCustomObject ? pso.BaseObject : value;

    public static IEnumerable<object?> Enumerate(object? value)
    {
        object? baseObj = Unwrap(value);
        if (baseObj is IEnumerable enumerable and not string and not IDictionary)
        {
            foreach (object? item in enumerable)
            {
                yield return item;
            }
        }
    }

    public static string Text(object? value) => value switch
    {
        null => "$null",
        PSObject pso => pso.ToString(),
        bool b => b ? "True" : "False",
        _ => LanguagePrimitives.ConvertTo<string>(value)!,
    };

    /// <summary>
    /// The short type name of the value, without the Deserialized prefix and
    /// namespace.
    /// </summary>
    public static string? TypeName(object? value)
    {
        string? fullName = value is PSObject pso
            ? pso.TypeNames.FirstOrDefault()
            : value?.GetType().FullName;
        if (fullName is null)
        {
            return null;
        }

        if (fullName.StartsWith("Deserialized.", StringComparison.Ordinal))
        {
            fullName = fullName["Deserialized.".Length..];
        }

        int genericIdx = fullName.IndexOfAny(['`', '[']);
        string baseName = genericIdx == -1 ? fullName : fullName[..genericIdx];
        string shortName = baseName[(baseName.LastIndexOf('.') + 1)..];
        return genericIdx == -1 ? shortName : $"{shortName}{(fullName[genericIdx] == '[' ? "[]" : "<>")}";
    }

    /// <summary>
    /// A single line preview of a value, strings are quoted and objects are
    /// prefixed with their type.
    /// </summary>
    public static string Preview(object? value)
    {
        object? baseObj = Unwrap(value);
        if (baseObj is null)
        {
            return "$null";
        }
        else if (baseObj is string s)
        {
            return s == SecureStringMarker ? s : $"\"{TextHelper.Sanitize(s)}\"";
        }
        else if (IsScalar(baseObj))
        {
            return TextHelper.Sanitize(Text(value));
        }

        string text = TextHelper.Sanitize(Text(value));

        // Objects without a useful ToString, like a PSCredential, show their
        // properties instead of the type name again.
        if (value is PSObject pso &&
            pso.Properties.Any() &&
            pso.TypeNames.Any(t => t.EndsWith(text, StringComparison.Ordinal)))
        {
            IEnumerable<string> props = pso.Properties.Select(p => $"{p.Name}={Text(Property(value, p.Name))}");
            text = TextHelper.Sanitize($"@{{{string.Join("; ", props)}}}");
        }

        string? typeName = TypeName(value);
        return typeName is null || text.StartsWith("[", StringComparison.Ordinal) ? text : $"[{typeName}] {text}";
    }

    public static ClixmlNode BuildTree(string? name, object? value, int depth = 0)
    {
        string prefix = name is null ? "" : $"{name}: ";
        object? baseObj = value is PSObject p ? p.BaseObject : value;

        if (value is null)
        {
            return Leaf($"{prefix}$null");
        }
        else if (IsScalar(baseObj))
        {
            string text = baseObj is string s && s.Length == 0 ? "\"\"" : Text(value);
            return Leaf(prefix + TextHelper.Truncate(TextHelper.Sanitize(text), MaxValueLength));
        }
        else if (depth >= MaxDepth)
        {
            return Leaf($"{prefix}{TextHelper.Ellipsis}");
        }

        string label = prefix + TypeLabel(value);
        List<ClixmlNode> children = [];
        if (baseObj is IDictionary dict)
        {
            foreach (DictionaryEntry entry in dict)
            {
                children.Add(BuildTree(Text(entry.Key), entry.Value, depth + 1));
            }
        }
        else if (baseObj is IEnumerable enumerable)
        {
            int i = 0;
            foreach (object? item in enumerable)
            {
                children.Add(BuildTree($"[{i++}]", item, depth + 1));
            }
        }
        else if (value is PSObject pso)
        {
            foreach (PSPropertyInfo prop in pso.Properties)
            {
                object? propValue;
                try
                {
                    propValue = prop.Value;
                }
                catch (GetValueException)
                {
                    continue;
                }

                children.Add(BuildTree(prop.Name, propValue, depth + 1));
            }
        }

        if (children.Count == 0)
        {
            return Leaf($"{prefix}{TextHelper.Sanitize(Text(value))}");
        }
        else if (children.Count > MaxChildren)
        {
            int extra = children.Count - MaxChildren;
            children = [.. children.Take(MaxChildren), Leaf($"{TextHelper.Ellipsis} {extra} more")];
        }

        return new(label, children);
    }

    private static ClixmlNode Leaf(string label) => new(label, []);

    private static string TypeLabel(object value)
    {
        string? typeName = TypeName(value);
        string text = TextHelper.Sanitize(Text(value));

        // Objects with a meaningful ToString, like an ErrorRecord, show it next
        // to the type. Property bags and collections don't have one.
        bool hasToString = value is PSObject pso &&
            pso.BaseObject is PSCustomObject &&
            !text.StartsWith("@{", StringComparison.Ordinal) &&
            !pso.TypeNames.Any(t => t.EndsWith(text, StringComparison.Ordinal));
        return hasToString
            ? $"[{typeName}] {TextHelper.Truncate(text, 80)}"
            : $"[{typeName}]";
    }

    private static bool IsScalar(object? value) => value is string or char or bool or Enum or decimal or
        DateTime or DateTimeOffset or TimeSpan or Guid or Version or Uri or
        sbyte or byte or short or ushort or int or uint or long or ulong or float or double
#if NET
        // SemanticVersion was added in PowerShell 6.
        or SemanticVersion
#endif
        ;
}
