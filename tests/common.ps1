using namespace System.Buffers.Binary
using namespace System.IO
using namespace System.Text

# Helpers shared by the Pester tests. Dot source it in a BeforeAll block, the
# module is imported by the "using module" statement of each test file.

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 only runs on Windows and does not define $IsWindows.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $IsWindows = $true
}

# The characters used by Format-PSRPPacket. Windows PowerShell reads a file
# without a BOM with the ANSI code page, keep the test files ASCII and use
# these instead of the literal characters.
$Esc = [string][char]0x1B
$Bar = [string][char]0x2502
$Line = [string][char]0x2500
$Tee = [string][char]0x251C
$Elbow = [string][char]0x2514
$ToServer = [string][char]0x25B6
$ToClient = [string][char]0x25C0
$Bullet = [string][char]0x2022
$RightArrow = [string][char]0x2192
$Return = [string][char]0x21B5
$Dot = [string][char]0x00B7
$Ellipsis = [string][char]0x2026
$LAngle = [string][char]0x2039
$RAngle = [string][char]0x203A
$EnDash = [string][char]0x2013
$RQuote = [string][char]0x2019

# Builds a PSRP message, the 40 byte header followed by the data.
Function New-PSRPMessage {
    [OutputType([byte[]])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [RemoteWrench.PSRPDestination]
        $Destination,

        [Parameter(Mandatory)]
        [RemoteWrench.PSRPMessageType]
        $MessageType,

        [Parameter()]
        [AllowEmptyString()]
        [string]
        $Data = '',

        [Parameter()]
        [Guid]
        $RunspacePoolId = [Guid]::Empty,

        [Parameter()]
        [Guid]
        $PipelineId = [Guid]::Empty
    )

    $dataBytes = [Encoding]::UTF8.GetBytes($Data)
    $msgBytes = [byte[]]::new(40 + $dataBytes.Length)
    [BinaryPrimitives]::WriteInt32LittleEndian(
        [ArraySegment[byte]]::new($msgBytes, 0, 4),
        $Destination)
    [BinaryPrimitives]::WriteInt32LittleEndian(
        [ArraySegment[byte]]::new($msgBytes, 4, 4),
        $MessageType)
    $RunspacePoolId.ToByteArray().CopyTo($msgBytes, 8)
    $PipelineId.ToByteArray().CopyTo($msgBytes, 24)
    [Array]::Copy($dataBytes, 0, $msgBytes, 40, $dataBytes.Length)

    , $msgBytes
}

# Builds a PSRP fragment, the 21 byte header followed by the blob.
Function New-PSRPFragment {
    [OutputType([byte[]])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]
        $Blob,

        [Parameter()]
        [long]
        $ObjectId = 1,

        [Parameter()]
        [long]
        $FragmentId = 0,

        [Parameter()]
        [switch]
        $Start,

        [Parameter()]
        [switch]
        $End,

        [Parameter()]
        [int]
        $BlobLength = $Blob.Length
    )

    $fragBytes = [byte[]]::new(21 + $Blob.Length)
    [BinaryPrimitives]::WriteInt64BigEndian(
        [ArraySegment[byte]]::new($fragBytes, 0, 8),
        $ObjectId)
    [BinaryPrimitives]::WriteInt64BigEndian(
        [ArraySegment[byte]]::new($fragBytes, 8, 8),
        $FragmentId)
    $flags = 0
    if ($Start) {
        $flags = $flags -bor 1
    }
    if ($End) {
        $flags = $flags -bor 2
    }
    $fragBytes[16] = $flags
    [BinaryPrimitives]::WriteInt32BigEndian(
        [ArraySegment[byte]]::new($fragBytes, 17, 4),
        $BlobLength)
    [Array]::Copy($Blob, 0, $fragBytes, 21, $Blob.Length)

    , $fragBytes
}

# Wraps the fragment bytes in an OutOfProc Data packet line.
Function ConvertTo-DataPacket {
    [OutputType([string])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]
        $Bytes,

        [Parameter()]
        [Guid]
        $PSGuid = [Guid]::Empty
    )

    "<Data Stream='Default' PSGuid='$PSGuid'>$([Convert]::ToBase64String($Bytes))</Data>"
}

# A Data packet with a single message in a single fragment.
Function Get-PSRPPacket {
    [OutputType([string])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [RemoteWrench.PSRPDestination]
        $Destination,

        [Parameter(Mandatory)]
        [RemoteWrench.PSRPMessageType]
        $MessageType,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]
        $Data,

        [Parameter()]
        [Guid]
        $PSGuid = [Guid]::Empty,

        [Parameter()]
        [Guid]
        $RunspacePoolId = [Guid]::Empty,

        [Parameter()]
        [Guid]
        $PipelineId = [Guid]::Empty,

        [Parameter()]
        [long]
        $ObjectId = 1
    )

    $msgParams = @{
        Destination = $Destination
        MessageType = $MessageType
        Data = $Data
        RunspacePoolId = $RunspacePoolId
        PipelineId = $PipelineId
    }
    $msg = New-PSRPMessage @msgParams
    $frag = New-PSRPFragment -Blob $msg -ObjectId $ObjectId -Start -End
    ConvertTo-DataPacket -Bytes $frag -PSGuid $PSGuid
}

Function Get-TestData {
    param ([string[]]$Name)
    foreach ($n in $Name) {
        Get-Content -LiteralPath ([Path]::Combine($PSScriptRoot, 'data', $n))
    }
}

# Builds the CLIXML of a CreatePipeline message with the commands given,
# each the MS content of a command object.
Function New-CreatePipelineData {
    param ([string[]]$Command)

    $cmds = foreach ($c in $Command) { "<Obj><MS>$c</MS></Obj>" }
    "<Obj RefId=`"0`"><MS><Obj N=`"PowerShell`"><MS><Obj N=`"Cmds`"><LST>$($cmds -join '')</LST></Obj></MS></Obj><B N=`"NoInput`">true</B></MS></Obj>"
}

# Gets the message type and summary of each message from the Grouped
# view, which has a single line per message. All the lines are formatted
# together as messages can span packets.
Function Get-MessageSummary {
    param ([Parameter(ValueFromPipeline)][string[]]$Line)

    begin {
        $lines = [System.Collections.Generic.List[string]]::new()
    }
    process {
        $lines.AddRange($Line)
    }
    end {
        $lines | ConvertTo-PSRPPacket -ErrorAction Stop |
            Format-PSRPPacket -View Grouped -NoColor -Width 1000 |
            ForEach-Object {
                if ($_ -match "([${ToServer}${ToClient}${Bullet}]) (\w+)\s+(.*)`$") {
                    [PSCustomObject]@{
                        Arrow = $Matches[1]
                        MessageType = $Matches[2]
                        Summary = $Matches[3]
                    }
                }
            }
    }
}

# Runs Format-PSRPPacket in a runspace with a host that reports the buffer
# width given, throws when asked for it, or has no UI or raw UI, to test how
# the width is chosen.
Function Invoke-FormatInTestHost {
    param (
        [Parameter(Mandatory)]
        [object[]]
        $Packet,

        [Parameter()]
        [int]
        $Width = 80,

        [Parameter()]
        [switch]
        $ThrowOnBufferSize,

        [Parameter()]
        [switch]
        $NoUI,

        [Parameter()]
        [switch]
        $NoRawUI
    )

    if (-not ('RemoteWrenchTests.WidthHost' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

// Windows PowerShell compiles this with C# 5, avoid newer syntax.
namespace RemoteWrenchTests
{
    public class WidthHost : PSHost
    {
        private readonly WidthHostUI _ui;
        private readonly Guid _instanceId = Guid.NewGuid();

        public WidthHost(int width, bool throwOnBufferSize, bool noUI, bool noRawUI)
        {
            if (!noUI)
            {
                _ui = new WidthHostUI(noRawUI ? null : new WidthRawUI(width, throwOnBufferSize));
            }
        }

        public override string Name { get { return "RemoteWrenchTestHost"; } }
        public override Version Version { get { return new Version(1, 0); } }
        public override Guid InstanceId { get { return _instanceId; } }
        public override PSHostUserInterface UI { get { return _ui; } }
        public override CultureInfo CurrentCulture { get { return CultureInfo.CurrentCulture; } }
        public override CultureInfo CurrentUICulture { get { return CultureInfo.CurrentUICulture; } }
        public override void SetShouldExit(int exitCode) { }
        public override void EnterNestedPrompt() { throw new NotImplementedException(); }
        public override void ExitNestedPrompt() { throw new NotImplementedException(); }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
    }

    public class WidthHostUI : PSHostUserInterface
    {
        private readonly PSHostRawUserInterface _rawUI;

        public WidthHostUI(PSHostRawUserInterface rawUI)
        {
            _rawUI = rawUI;
        }

        public override PSHostRawUserInterface RawUI { get { return _rawUI; } }
        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) { throw new NotImplementedException(); }
        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) { throw new NotImplementedException(); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) { throw new NotImplementedException(); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) { throw new NotImplementedException(); }
        public override string ReadLine() { throw new NotImplementedException(); }
        public override SecureString ReadLineAsSecureString() { throw new NotImplementedException(); }
        public override void Write(string value) { }
        public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { }
        public override void WriteDebugLine(string message) { }
        public override void WriteErrorLine(string value) { }
        public override void WriteLine(string value) { }
        public override void WriteProgress(long sourceId, ProgressRecord record) { }
        public override void WriteVerboseLine(string message) { }
        public override void WriteWarningLine(string message) { }
    }

    public class WidthRawUI : PSHostRawUserInterface
    {
        private readonly int _width;
        private readonly bool _throwOnBufferSize;
        private string _windowTitle = "";

        public WidthRawUI(int width, bool throwOnBufferSize)
        {
            _width = width;
            _throwOnBufferSize = throwOnBufferSize;
        }

        public override Size BufferSize
        {
            get
            {
                if (_throwOnBufferSize)
                {
                    throw new InvalidOperationException("No console");
                }
                return new Size(_width, 50);
            }
            set { throw new NotImplementedException(); }
        }

        public override ConsoleColor BackgroundColor { get; set; }
        public override ConsoleColor ForegroundColor { get; set; }
        public override Coordinates CursorPosition { get; set; }
        public override int CursorSize { get; set; }
        public override bool KeyAvailable { get { return false; } }
        public override Size MaxPhysicalWindowSize { get { return new Size(_width, 50); } }
        public override Size MaxWindowSize { get { return new Size(_width, 50); } }
        public override Coordinates WindowPosition { get; set; }
        public override Size WindowSize { get; set; }
        public override string WindowTitle { get { return _windowTitle; } set { _windowTitle = value; } }
        public override void FlushInputBuffer() { }
        public override BufferCell[,] GetBufferContents(Rectangle rectangle) { throw new NotImplementedException(); }
        public override KeyInfo ReadKey(ReadKeyOptions options) { throw new NotImplementedException(); }
        public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) { throw new NotImplementedException(); }
        public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) { throw new NotImplementedException(); }
        public override void SetBufferContents(Rectangle rectangle, BufferCell fill) { throw new NotImplementedException(); }
    }
}
'@
    }

    $testHost = [RemoteWrenchTests.WidthHost]::new($Width, $ThrowOnBufferSize, $NoUI, $NoRawUI)
    $runspace = [runspacefactory]::CreateRunspace($testHost)
    $runspace.Open()
    $ps = [powershell]::Create()
    try {
        $ps.Runspace = $runspace
        $null = $ps.AddScript({
            param ($ModulePath, $Packet)
            Import-Module -Name $ModulePath
            $Packet | Format-PSRPPacket -NoColor
        }).AddArgument([Path]::Combine((Get-Module -Name RemoteWrench).ModuleBase, 'RemoteWrench.psd1')).AddArgument($Packet)
        $ps.Invoke()
        if ($ps.Streams.Error) {
            throw $ps.Streams.Error[0]
        }
    }
    finally {
        $ps.Dispose()
        $runspace.Dispose()
    }
}

# Starts a PowerShell process of the same edition as this one for the
# Enter-ExtSession tests to connect to over its named pipe, the transport used
# by Enter-PSHostProcess. Stop it with Stop-Process.
Function Start-ExtTarget {
    [OutputType([System.Diagnostics.Process])]
    [CmdletBinding()]
    param ()

    $psi = [System.Diagnostics.ProcessStartInfo]::new(
        [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName,
        '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 600"')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [System.Diagnostics.Process]::Start($psi)
}

# Opens a runspace to a process from Start-ExtTarget. Its named pipe is only
# there once it has started, retry until it is.
Function New-ExtTargetRunspace {
    [OutputType([System.Management.Automation.Runspaces.Runspace])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]
        $Process
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $connInfo = [System.Management.Automation.Runspaces.NamedPipeConnectionInfo]::new($Process.Id)
        $connInfo.OpenTimeout = 5000
        $runspace = [RunspaceFactory]::CreateRunspace(
            $connInfo,
            $Host,
            [System.Management.Automation.Runspaces.TypeTable]::LoadDefaultTypeFiles())
        try {
            $runspace.Open()
            return $runspace
        }
        catch {
            $runspace.Dispose()
            if ($sw.Elapsed.TotalSeconds -gt 60) {
                throw
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

# Sets up the Enter-ExtSession functions in a runspace from
# New-ExtTargetRunspace without entering it. The tests can't push a runspace
# so this calls what Enter-ExtSession does before it pushes.
Function Initialize-ExtTestSession {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]
        $Runspace,

        [Parameter()]
        [AllowEmptyCollection()]
        [RemoteWrench.Ext.ExtDefinition[]]
        $Function = @(),

        [Parameter()]
        [int]
        $AckTimeoutMs = 10000
    )

    $sessionType = [RemoteWrench.Ext.ExtDefinition].Assembly.GetType('RemoteWrench.Ext.ExtSession')
    $definitions = [System.Collections.Generic.List[RemoteWrench.Ext.ExtDefinition]]::new()
    foreach ($f in $Function) {
        $definitions.Add($f)
    }
    try {
        $null = $sessionType.GetMethod('Create').Invoke($null, @(
            $Runspace,
            [Runspace]::DefaultRunspace,
            $Host,
            $definitions,
            $AckTimeoutMs))
    }
    catch [System.Reflection.TargetInvocationException] {
        throw $_.Exception.InnerException
    }
}

# Runs a command in the remote runspace the way the interactive prompt of an
# entered session does. It loops while it waits so this runspace runs the
# client scripts of callbacks, which it does when it is idle in a real
# session.
Function Invoke-ExtTestCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]
        $Runspace,

        [Parameter(Mandatory)]
        [string]
        $Command,

        [Parameter()]
        [int]
        $TimeoutSeconds = 30,

        # A global variable set to the running pipeline so a client script
        # can stop it.
        [Parameter()]
        [string]
        $PipelineName
    )

    # A remote command that writes an error and finishes straight away has
    # been seen to lose the error on slow CI runners. Waiting a little after
    # the command keeps it running until the error is sent.
    $pipeline = $Runspace.CreatePipeline("$Command`nStart-Sleep -Milliseconds 100")
    if ($PipelineName) {
        Set-Variable -Name $PipelineName -Value $pipeline -Scope Global
    }
    $pipeline.InvokeAsync()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($pipeline.PipelineStateInfo.State -in 'NotStarted', 'Running', 'Stopping') {
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            # Say how far it got, it helps to know where it stopped.
            $output = @($pipeline.Output.NonBlockingRead())
            $errors = @($pipeline.Error.NonBlockingRead() | ForEach-Object ToString)
            $pipeline.StopAsync()
            throw ("Command '$Command' did not finish within $TimeoutSeconds seconds, it output $($output.Count) " +
                "objects, the last was '$(if ($output) { $output[-1] })', and errors '$($errors -join "', '")'.")
        }
        Start-Sleep -Milliseconds 10
    }

    # The state can change before the last output and errors are added, they
    # are all there once the readers are closed.
    $sw.Restart()
    while (($pipeline.Output.IsOpen -or $pipeline.Error.IsOpen) -and $sw.Elapsed.TotalSeconds -lt 10) {
        Start-Sleep -Milliseconds 10
    }

    # A terminating error at the top level fails the pipeline rather than
    # being written to its error stream.
    $errorRecords = @($pipeline.Error.NonBlockingRead())
    if ($pipeline.PipelineStateInfo.State -eq 'Failed') {
        $reason = $pipeline.PipelineStateInfo.Reason
        if ($reason.ErrorRecord) {
            $errorRecords += $reason.ErrorRecord
        }
        else {
            $errorRecords += [System.Management.Automation.ErrorRecord]::new($reason, 'PipelineFailed', 'NotSpecified', $null)
        }
    }
    $errors = @($errorRecords | ForEach-Object { $_.ToString() })

    [PSCustomObject]@{
        Output = @($pipeline.Output.NonBlockingRead())
        Errors = $errors
        ErrorRecords = $errorRecords
        State = $pipeline.PipelineStateInfo.State
        Reason = $pipeline.PipelineStateInfo.Reason
    }
}
