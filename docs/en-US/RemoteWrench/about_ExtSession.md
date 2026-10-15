# about_ExtSession

## Short description

Describes the functions available in a session entered with `Enter-ExtSession` and how callbacks run code on the client.

## Long description

`Enter-ExtSession` enters a remote session like `Enter-PSSession` but with extension functions defined in that session.
A function from `New-ExtFunction`, or a local function given to `-Function` by name, only runs in the remote session.
A callback from `New-ExtCallback` is a function in the remote session that runs a script on the client.
`New-ExtFileTransferCallback` and `New-ExtEditCallback` create callbacks built into the module, to copy files between the client and the remote session and to edit a remote file with an editor on the client.

The functions are defined in a temporary in memory module named `RemoteWrench.Ext` in the remote session.
They behave like any other function, with the parameters, pipeline input and output of their script.

### The remote functions

Every function is defined in the remote session as an advanced function, so it also has the common parameters like `-Verbose` and `-ErrorAction`.
A user supplied script that isn't advanced keeps its behaviour:

- Its parameters can still be passed by position, in the order they are declared, like `Get-Thing value1 value2` for `param ($First, $Second)`.
  A `[switch]` parameter is skipped as it is never positional, so `param ($Name, [switch]$Force, $Path)` takes `Get-Thing name path -Force`.
- Arguments that don't bind to a parameter are passed to it as `$args`.
- Pipeline input is passed to it, its `process` block runs for each input, or it reads `$input`.

A filter, like `filter Get-Doubled { $_ * 2 }`, runs for each pipeline input like it does locally.
A script with a `dynamicparam` block isn't supported.

Each call runs the script in a new module, it can't see the variables of an earlier call and nothing it defines is left behind.

### Callbacks

A callback without a server script is the client script running on the client.
The remote function has the client script's parameters, its arguments and pipeline input are passed to the client script and the client script's output is the function's output, as it is written.

```powershell
$grid = New-ExtCallback Out-ClientGridView {
    param ([string]$Title = 'Remote')

    $input | Out-GridView -Title $Title -PassThru
}
```

In the remote session `Get-Process | Out-ClientGridView` shows the processes in a grid view on the client and outputs the selected ones.

A callback with a server script runs that in the remote session and the server script controls and how the client script is called.
The server script runs the client script with `Invoke-ExtCallback`, which has the client script's parameters, and pipeline input like the remote function of a callback without one.
Its output is the client script's output as it is written.

```powershell
$copy = New-ExtCallback Send-ClientFile -ServerScript {
    param ([Parameter(Mandatory)][string]$Path)

    $name = [System.IO.Path]::GetFileName($Path)
    , [System.IO.File]::ReadAllBytes($Path) | Invoke-ExtCallback -Name $name
} -ClientScript {
    param ([string]$Name)

    process {
        $dest = Join-Path ([Environment]::GetFolderPath('Desktop')) ([System.IO.Path]::GetFileName($Name))
        [System.IO.File]::WriteAllBytes($dest, $_)
        $dest
    }
}
```

In the remote session `Send-ClientFile C:\Logs\app.log` copies the remote file to the client's desktop and outputs the path it was saved to on the client.

`Invoke-ExtCallback` only exists in the server script of a callback, anywhere else, including a function the server script calls, it fails with an error saying so.

A byte array is sent as one object, but piping one sends each byte like any pipeline.
Pipe it with the unary comma, `, $bytes | Invoke-ExtCallback`, or pass it to a parameter.

Calling `Invoke-ExtCallback` in the `process` block of a server script runs the client script once for each input.
When the server script does something with each input before the client gets it, but all of them should go to one call of the client script, use a steppable pipeline.
This callback reads remote files on the server and writes them all to one archive on the client:

```powershell
$archive = New-ExtCallback Save-ClientArchive -ServerScript {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]
        $LiteralPath,

        [Parameter(Mandatory)]
        [string]
        $Destination
    )

    begin {
        # One client script call for every file piped in, it writes them
        # all to the one archive.
        $pipeline = { Invoke-ExtCallback -Destination $Destination }.GetSteppablePipeline()
        $pipeline.Begin($PSCmdlet)
    }
    process {
        # Read on the server, the client can't access the remote files.
        $pipeline.Process([PSCustomObject]@{
            Name = [System.IO.Path]::GetFileName($LiteralPath)
            Content = [System.IO.File]::ReadAllBytes($LiteralPath)
        })
    }
    end {
        $pipeline.End()
    }
} -ClientScript {
    param ([string]$Destination)

    begin {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
        $zip = [System.IO.Compression.ZipFile]::Open($path, 'Create')
    }
    process {
        # The name comes from the server, only keep the file name.
        $entry = $zip.CreateEntry([System.IO.Path]::GetFileName($_.Name))
        $stream = $entry.Open()
        try {
            $stream.Write($_.Content, 0, $_.Content.Length)
        }
        finally {
            $stream.Dispose()
        }
    }
    end {
        $zip.Dispose()
        $path
    }
}
```

In the remote session `Get-ChildItem C:\Logs\*.log | Save-ClientArchive -Destination logs.zip` creates `logs.zip` in the client's current directory with the remote log files and outputs its path on the client.

Errors the client script writes are written as errors of the remote function, or of `Invoke-ExtCallback`.
If the client script fails, it fails with "Callback '<Name>' failed on the client: <message>" and the position in the client script, which ends the statement that called it.

Only the client script's output and errors are sent to the server.
Its other streams, warnings, verbose, debug and information messages, `Write-Host` and progress, are written to the client's console directly.
They show in the same console, but:

- They follow the preferences of the client, not the remote function's common parameters. `-Verbose` on the remote function doesn't show the client script's verbose messages, set `$VerbosePreference` in the client script or the client session to show them.
- They can't be redirected or captured in the remote session, like with `3>$null` or `-WarningVariable`.
- They can show before output the remote session hasn't displayed yet.

A server script's streams are part of the remote command, they work like any other remote command's.

### The client script

The client script runs on the client in the session state it was created in, like any scriptblock.
It has the variable `$ExtCallbackContext` with these properties:

- `Name`: the name of the callback.
- `ConnectionInfo`: the connection info of the remote session.
- `CancellationToken`: cancelled when the remote function is stopped, like with Ctrl+C.

Ctrl+C in the remote session stops the remote function, not the client script.
A client script reading pipeline input fails when it is stopped.
A client script that runs a blocking function that accepts a `CancellationToken` should provide the value from `$ExtCallbackContext.CancellationToken`.

### Security

The client script of a callback runs on the client with the client's permissions, the input it receives comes from the remote session and must be treated as untrusted.

Due to the nature of how the callbacks are invoked, it is possible for a malicious server to invoke the callback outside of the defined server side script.
The messages the remote function sends are engine events, and any code in the remote session can raise them, including code run by another user or process that can reach it.
That code can call any callback by name with any arguments and send it any pipeline input.
It doesn't go through the remote function, so the parameter types and validation of its param block and any checks in its server script don't apply.

Validate the arguments and pipeline input in the client script itself:

- Don't use a path from the server without checking it, a name like `../../.bashrc` can write outside the directory you expect.
- Don't run the input as code or pass it to a command line without quoting it.
- Don't send the server more than it needs, like the contents of any file it asks for.
- Only define callbacks for sessions on computers you trust as much as the client.

### How it works

PowerShell remoting has no official way for a running remote command to exchange data with the client outside of pre-defined host methods, so a callback uses one mechanism for each direction:

- To the client, the remote function raises an engine event that is forwarded to the client, like `Register-EngineEvent -Forward` does.
- To the server, the client runs a nested command in the remote session.
  PowerShell runs it inside the command that called the callback, between its statements.
  The remote function waits in a loop that checks every 10 milliseconds, which lets the nested commands run.

```text
 Client                                 Remote session
+-----------------------------+        +-----------------------------+
| Console in the entered      |  runs  | Command at the prompt       |
| session                     | -----> |   calls the remote function |
+-----------------------------+        +-----------------------------+
| RemoteWrench                | <----- | RemoteWrench.Ext module     |
|  - handles the messages     | events |  - proxy of a client script |
|    from the server          |        |  - runs the server script   |
|  - sends the replies on     | -----> |  - Invoke-ExtCallback       |
|    its own thread           | nested |                             |
+-----------------------------+  cmds  +-----------------------------+
| Local runspace              |
|  - runs the client script   |
+-----------------------------+
```

One call of a callback, like `Get-Process | Out-ClientGridView`, goes like this:

```text
 Client                               Remote session
                                      begin:   sends Open with the
                       <-- Open --             arguments, waits for Ack
 Starts the client
 script on the local
 runspace              --- Ack --->   begin returns
                                      process: sends each input, writes
                       <-- Data ---            the client output so far
 Pipeline input to the
 client script, sends
 its output and errors --- Data --->
                                      end:     sends End, writes the
                       <-- End ----            client output until the
 Client script ends,                           client script ends
 sends End             --- End ---->  end returns
```

A failure on either side closes the call, the client script is stopped when the server sends Close.

A nested command can only run in a command that was started the way the interactive prompt starts one.
Callbacks only work from the prompt of the entered session, not in a job, through `Invoke-Command` or in another runspace.
The client acknowledges a callback as soon as it receives it, before the client script starts.
If the server doesn't get that within 10 seconds, the remote function fails with an error saying the client did not respond.
After that there is no time limit, the remote function waits for the client script for as long as it runs, like an editor left open.

A command can be stopped while another command in its pipeline runs, like Ctrl+C on `Get-Content -Wait app.log | Out-ClientPager` stops it while `Get-Content` waits.
None of the remote function's blocks run after that, so it can't tell the client, whose client script would otherwise wait for more input forever and keep later callbacks from starting.
Instead, while a callback runs the client asks the server every second whether the command that called it was stopped.
If it was, or no command is running anymore, the client stops the client script within a few seconds.
Reading its pipeline input fails so it stops there and its `end` block doesn't run, a client script not reading input sees `$ExtCallbackContext.CancellationToken` cancelled.

Pipeline input and output are limited in how far ahead of the other side they get.
The remote function sends at most 64 pipeline input objects ahead of what the client script has read, and the client script's output waits once 64 objects are waiting to be sent.
A callback with a lot of input or output, like a large file, doesn't hold it all in memory.

Values are serialized like any remoting output, objects lose their methods and nested properties are only kept to a limited depth.

## See also

- [Enter-ExtSession](./Enter-ExtSession.md)
- [New-ExtFunction](./New-ExtFunction.md)
- [New-ExtCallback](./New-ExtCallback.md)
