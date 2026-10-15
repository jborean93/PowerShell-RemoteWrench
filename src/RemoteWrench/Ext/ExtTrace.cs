using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;

namespace RemoteWrench.Ext;

/// <summary>A trace of what the client side of the sessions does, only kept when enabled.</summary>
/// <remarks>
/// It is for debugging, the tests enable it through reflection and show the end of it when a command doesn't
/// finish.
/// </remarks>
internal static class ExtTrace
{
    private const int MaxEntries = 1000;

    private static readonly ConcurrentQueue<string> s_entries = new();
    private static readonly Stopwatch s_clock = Stopwatch.StartNew();

    /// <summary>Whether entries are kept.</summary>
    public static bool Enabled { get; set; }

    /// <summary>Adds an entry if the trace is enabled.</summary>
    /// <param name="message">The entry.</param>
    public static void Write(string message)
    {
        if (!Enabled)
        {
            return;
        }

        s_entries.Enqueue(
            $"{s_clock.ElapsedMilliseconds,8} [{Thread.CurrentThread.ManagedThreadId,3}] {message}");
        while (s_entries.Count > MaxEntries)
        {
            s_entries.TryDequeue(out _);
        }
    }

    /// <summary>Removes and returns the entries.</summary>
    /// <returns>The entries, oldest first.</returns>
    public static string[] Flush()
    {
        string[] entries = s_entries.ToArray();
        while (s_entries.TryDequeue(out _))
        { }
        return entries;
    }
}
