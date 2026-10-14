namespace RemoteWrench.Formatting;

/// <summary>
/// ANSI escape sequences for the plain text views, all empty when color is
/// disabled.
/// </summary>
internal sealed class Palette
{
    public string Reset { get; } = "";
    public string Bold { get; } = "";
    public string Dim { get; } = "";
    public string Red { get; } = "";
    public string Green { get; } = "";
    public string Yellow { get; } = "";
    public string Blue { get; } = "";
    public string Magenta { get; } = "";
    public string BrightYellow { get; } = "";
    public string BrightCyan { get; } = "";

    public Palette(bool noColor)
    {
        if (!noColor)
        {
            Reset = "\x1b[0m";
            Bold = "\x1b[1m";
            Dim = "\x1b[90m";
            Red = "\x1b[31m";
            Green = "\x1b[32m";
            Yellow = "\x1b[33m";
            Blue = "\x1b[34m";
            Magenta = "\x1b[35m";
            BrightYellow = "\x1b[93m";
            BrightCyan = "\x1b[96m";
        }
    }

    public string Direction(PSRPDestination? destination) => destination switch
    {
        PSRPDestination.Server => BrightCyan,
        PSRPDestination.Client => BrightYellow,
        _ => Dim,
    };

    public string Color(string color, string value) => $"{color}{value}{Reset}";
}
