using System;
using System.Collections.Generic;

namespace RemoteWrench.Formatting;

/// <summary>
/// Renders a ClixmlNode with box drawing branches.
/// </summary>
internal static class PlainTree
{
    public static IEnumerable<string> Render(ClixmlNode root, int width, Palette palette)
    {
        yield return TextHelper.Truncate(root.Label, width);
        foreach (string line in RenderChildren(root, "", width, palette))
        {
            yield return line;
        }
    }

    private static IEnumerable<string> RenderChildren(ClixmlNode node, string prefix, int width, Palette palette)
    {
        for (int i = 0; i < node.Children.Count; i++)
        {
            ClixmlNode child = node.Children[i];
            bool last = i == node.Children.Count - 1;
            string branch = prefix + (last ? "└─ " : "├─ ");
            yield return palette.Color(palette.Dim, branch) +
                TextHelper.Truncate(child.Label, Math.Max(width - branch.Length, 10));

            foreach (string line in RenderChildren(child, prefix + (last ? "   " : "│  "), width, palette))
            {
                yield return line;
            }
        }
    }
}
