using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace RemoteWrench.Formatting;

internal static class TextHelper
{
    public const char Ellipsis = '…';

    /// <summary>
    /// Makes a value safe to show on a single line, newlines become a visible
    /// marker and other control characters are replaced.
    /// </summary>
    public static string Sanitize(string value)
    {
        if (value.Length == 0)
        {
            return "";
        }

        StringBuilder sb = new(value.Length);
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '\r')
            {
                if (i + 1 < value.Length && value[i + 1] == '\n')
                {
                    i++;
                }
                sb.Append('↵');
            }
            else if (c == '\n')
            {
                sb.Append('↵');
            }
            else if (c == '\t')
            {
                sb.Append(' ');
            }
            else if (char.IsControl(c))
            {
                sb.Append('·');
            }
            else
            {
                sb.Append(c);
            }
        }

        return sb.ToString();
    }

    public static string Truncate(string value, int width)
        => value.Length <= width ? value : value[..Math.Max(width - 1, 0)] + Ellipsis;

    /// <summary>
    /// Truncates or pads the value to exactly the width given.
    /// </summary>
    public static string Fit(string value, int width, bool alignRight = false)
    {
        string truncated = Truncate(value, width);
        return alignRight ? truncated.PadLeft(width) : truncated.PadRight(width);
    }

    /// <summary>
    /// Splits a value into lines of at most width characters, breaking at a
    /// space when there is one. Line breaks in the value are kept.
    /// </summary>
    public static IEnumerable<string> Wrap(string value, int width)
    {
        foreach (string line in value.Split('\n'))
        {
            foreach (string wrapped in WrapLine(line, Math.Max(width, 10)))
            {
                yield return wrapped;
            }
        }
    }

    private static IEnumerable<string> WrapLine(string value, int width)
    {
        int start = 0;
        while (value.Length - start > width)
        {
            int breakAt = value.LastIndexOf(' ', start + width, width);
            if (breakAt <= start)
            {
                yield return value.Substring(start, width);
                start += width;
            }
            else
            {
                yield return value[start..breakAt];
                start = breakAt + 1;
            }
        }

        yield return value[start..];
    }

    public static string FormatSize(long bytes) => bytes switch
    {
        < 1024 => $"{bytes}B",
        < 1024 * 1024 => (bytes / 1024.0).ToString("0.#", CultureInfo.InvariantCulture) + "KB",
        _ => (bytes / (1024.0 * 1024.0)).ToString("0.#", CultureInfo.InvariantCulture) + "MB",
    };

    public static string ShortGuid(Guid value) => value.ToString()[..8];

    public static string DirectionText(PSRPDestination? destination) => destination switch
    {
        PSRPDestination.Server => "C→S",
        PSRPDestination.Client => "S→C",
        _ => " ? ",
    };

    public static string Arrow(PSRPDestination? destination) => destination switch
    {
        PSRPDestination.Server => "▶",
        PSRPDestination.Client => "◀",
        _ => "•",
    };

    public static string FragmentText(PSRPFragment fragment)
        => $"{fragment.ObjectId}:{fragment.FragmentId} {(fragment.Start ? 'S' : ' ')}{(fragment.End ? 'E' : ' ')}".TrimEnd();
}
