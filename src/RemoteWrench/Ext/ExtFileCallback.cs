using System;
using System.Collections;
using System.IO;
using System.IO.Compression;
using System.Management.Automation;

namespace RemoteWrench.Ext;

/// <summary>The client directory the file transfer callbacks can read and write in.</summary>
internal sealed class ExtClientRoot
{
    private static readonly StringComparison s_pathComparison = Path.DirectorySeparatorChar == '\\'
        ? StringComparison.OrdinalIgnoreCase
        : StringComparison.Ordinal;

    public ExtClientRoot(string path)
    {
        FullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    public string FullPath { get; }

    /// <summary>Resolves a path from the server relative to the root.</summary>
    /// <exception cref="UnauthorizedAccessException">The path is outside the root.</exception>
    public string Resolve(string? path)
    {
        string full = string.IsNullOrEmpty(path)
            ? FullPath
            : Path.GetFullPath(Path.Combine(FullPath, path));
        string trimmed = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        // The root itself, or anything under it.
        if (trimmed.Equals(FullPath, s_pathComparison) ||
            full.StartsWith(FullPath + Path.DirectorySeparatorChar, s_pathComparison))
        {
            return full;
        }

        throw new UnauthorizedAccessException(
            $"'{path}' is outside of the client path '{FullPath}' the callback can use.");
    }
}

/// <summary>Compresses the chunks of a file with Deflate.</summary>
internal static class ExtFileCompression
{
    /// <summary>The largest chunk of a file, compressed or not.</summary>
    public const int ChunkSize = 65536;

    public static bool IsDeflate(object? compression)
        => string.Equals(LanguagePrimitives.ConvertTo<string>(compression), "Deflate", StringComparison.OrdinalIgnoreCase);

    public static byte[] Compress(byte[] data)
    {
        using MemoryStream output = new();
        using (DeflateStream deflate = new(output, CompressionLevel.Fastest, true))
        {
            deflate.Write(data, 0, data.Length);
        }
        return output.ToArray();
    }

    /// <summary>Decompresses a chunk from the server.</summary>
    /// <exception cref="InvalidDataException">The chunk is larger than a chunk once decompressed.</exception>
    public static byte[] Decompress(byte[] data)
    {
        // The server is untrusted, a small chunk could decompress to far more
        // than a chunk. Read one byte past the limit to know it did.
        using DeflateStream deflate = new(new MemoryStream(data), CompressionMode.Decompress);
        byte[] buffer = new byte[ChunkSize + 1];
        int total = 0;
        int read;
        while (total < buffer.Length && (read = deflate.Read(buffer, total, buffer.Length - total)) > 0)
        {
            total += read;
        }

        if (total > ChunkSize)
        {
            throw new InvalidDataException($"A compressed chunk from the server is larger than {ChunkSize} bytes.");
        }

        byte[] result = new byte[total];
        Array.Copy(buffer, result, total);
        return result;
    }
}

/// <summary>A callback that copies files from the remote session to the client.</summary>
public sealed class ExtSendFileCallback : ExtBuiltinCallback
{
    private readonly ExtClientRoot _root;

    internal ExtSendFileCallback(string name, string clientPath)
        : base(name, "param ([string]$Destination, [switch]$Force)", "SendFile.ps1")
    {
        _root = new(clientPath);
    }

    /// <summary>The client directory files are copied to, they can't be copied anywhere else.</summary>
    public string ClientPath => _root.FullPath;

    internal override void InvokeClient(ExtCallbackContext context)
    {
        string? destination = GetParameter<string>(context, "Destination");
        bool force = GetParameter<bool>(context, "Force");
        string destinationPath = _root.Resolve(destination);

        // The server sends a header for each file followed by its bytes.
        FileStream? stream = null;
        string? target = null;
        string? source = null;
        long remaining = 0;
        long length = 0;
        bool skip = false;
        bool compressed = false;

        void Finish()
        {
            stream?.Dispose();
            stream = null;
            if (!skip && target is not null)
            {
                PSObject result = new();
                result.TypeNames.Insert(0, "RemoteWrench.ExtFileTransfer");
                result.Properties.Add(new PSNoteProperty("Source", source));
                result.Properties.Add(new PSNoteProperty("Destination", target));
                result.Properties.Add(new PSNoteProperty("Length", length));
                context.Channel.Write(result);
            }
            target = null;
        }

        try
        {
            foreach (object? item in context.Channel.ReadInput())
            {
                object? value = ExtSession.Unwrap(item);
                if (remaining == 0 && value is Hashtable header)
                {
                    source = LanguagePrimitives.ConvertTo<string>(header["Source"]);
                    compressed = ExtFileCompression.IsDeflate(header["Compression"]);
                    length = LanguagePrimitives.ConvertTo<long>(header["Length"]);
                    remaining = length;
                    skip = false;

                    // Only the file name of the server's path is used.
                    string name = Path.GetFileName(LanguagePrimitives.ConvertTo<string>(header["Name"]));
                    target = Directory.Exists(destinationPath)
                        ? Path.Combine(destinationPath, name)
                        : destinationPath;

                    try
                    {
                        target = _root.Resolve(target);
                        if (!force && File.Exists(target))
                        {
                            throw new IOException(
                                $"The client file '{target}' already exists, use -Force to overwrite it.");
                        }
                        stream = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None);
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                    {
                        context.Channel.WriteError($"Failed to copy '{source}': {e.Message}");
                        skip = true;
                    }

                    if (remaining == 0)
                    {
                        Finish();
                    }
                }
                else if (remaining > 0 && value is byte[] chunk)
                {
                    if (compressed)
                    {
                        chunk = ExtFileCompression.Decompress(chunk);
                    }

                    if (!skip)
                    {
                        try
                        {
                            stream!.Write(chunk, 0, chunk.Length);
                        }
                        catch (IOException e)
                        {
                            context.Channel.WriteError($"Failed to write '{target}': {e.Message}");
                            stream!.Dispose();
                            stream = null;
                            skip = true;
                        }
                    }

                    remaining -= chunk.Length;
                    if (remaining <= 0)
                    {
                        remaining = 0;
                        Finish();
                    }
                }
                else
                {
                    throw new InvalidOperationException(
                        $"Received unexpected data from the server: {value?.GetType().FullName ?? "null"}.");
                }
            }
        }
        finally
        {
            // A file that didn't finish is left incomplete, remove it.
            if (stream is not null)
            {
                stream.Dispose();
                if (target is not null)
                {
                    File.Delete(target);
                }
            }
        }
    }
}

/// <summary>A callback that copies files from the client to the remote session.</summary>
public sealed class ExtReceiveFileCallback : ExtBuiltinCallback
{
    private readonly ExtClientRoot _root;

    internal ExtReceiveFileCallback(string name, string clientPath)
        : base(name, "param ([string[]]$Path, [string]$Compression)", "ReceiveFile.ps1")
    {
        _root = new(clientPath);
    }

    /// <summary>The client directory files are copied from, they can't be copied from anywhere else.</summary>
    public string ClientPath => _root.FullPath;

    internal override void InvokeClient(ExtCallbackContext context)
    {
        string[] paths = GetParameter<string[]>(context, "Path") ?? [];
        bool compress = ExtFileCompression.IsDeflate(GetParameter<string>(context, "Compression"));
        foreach (string path in paths)
        {
            string full;
            try
            {
                full = _root.Resolve(path);
                if (!File.Exists(full))
                {
                    throw new FileNotFoundException(Directory.Exists(full)
                        ? $"The client path '{path}' is a directory, only files can be copied."
                        : $"The client file '{path}' does not exist.");
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                context.Channel.WriteError(e.Message);
                continue;
            }

            using FileStream stream = new(full, FileMode.Open, FileAccess.Read, FileShare.Read);
            long length = stream.Length;
            context.Channel.Write(new Hashtable()
            {
                ["Name"] = Path.GetFileName(full),
                ["Length"] = length,
                ["Source"] = full,
                ["Compression"] = compress ? "Deflate" : "None",
            });

            // Exactly the length in the header is sent, even if the file
            // changes while it is read.
            long remaining = length;
            while (remaining > 0)
            {
                context.CancellationToken.ThrowIfCancellationRequested();
                byte[] chunk = new byte[(int)Math.Min(ExtFileCompression.ChunkSize, remaining)];
                int read = 0;
                while (read < chunk.Length)
                {
                    int count = stream.Read(chunk, read, chunk.Length - read);
                    if (count == 0)
                    {
                        // The file got shorter, pad it so the server gets the
                        // length it expects and tell it.
                        context.Channel.WriteError($"The client file '{path}' changed while it was copied.");
                        break;
                    }
                    read += count;
                }
                remaining -= chunk.Length;
                context.Channel.Write(compress ? ExtFileCompression.Compress(chunk) : chunk);
            }
        }
    }
}
