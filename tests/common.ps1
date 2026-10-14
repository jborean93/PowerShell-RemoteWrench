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

    if (-not ('RemoteWrenchTests.WidthHost2' -as [type])) {
        Add-Type -TypeDefinition @'
#nullable enable
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

namespace RemoteWrenchTests
{
    public class WidthHost2 : PSHost
    {
        private readonly WidthHostUI? _ui;

        public WidthHost2(int width, bool throwOnBufferSize, bool noUI, bool noRawUI)
        {
            if (!noUI)
            {
                _ui = new WidthHostUI(noRawUI ? null : new WidthRawUI(width, throwOnBufferSize));
            }
        }

        public override string Name => "RemoteWrenchTestHost";
        public override Version Version => new Version(1, 0);
        public override Guid InstanceId { get; } = Guid.NewGuid();
        public override PSHostUserInterface? UI => _ui;
        public override CultureInfo CurrentCulture => CultureInfo.CurrentCulture;
        public override CultureInfo CurrentUICulture => CultureInfo.CurrentUICulture;
        public override void SetShouldExit(int exitCode) { }
        public override void EnterNestedPrompt() => throw new NotImplementedException();
        public override void ExitNestedPrompt() => throw new NotImplementedException();
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
    }

    public class WidthHostUI : PSHostUserInterface
    {
        private readonly PSHostRawUserInterface? _rawUI;

        public WidthHostUI(PSHostRawUserInterface? rawUI) => _rawUI = rawUI;

        public override PSHostRawUserInterface? RawUI => _rawUI;
        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) => throw new NotImplementedException();
        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) => throw new NotImplementedException();
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) => throw new NotImplementedException();
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) => throw new NotImplementedException();
        public override string ReadLine() => throw new NotImplementedException();
        public override SecureString ReadLineAsSecureString() => throw new NotImplementedException();
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

        public WidthRawUI(int width, bool throwOnBufferSize)
        {
            _width = width;
            _throwOnBufferSize = throwOnBufferSize;
        }

        public override Size BufferSize
        {
            get => _throwOnBufferSize ? throw new InvalidOperationException("No console") : new Size(_width, 50);
            set => throw new NotImplementedException();
        }

        public override ConsoleColor BackgroundColor { get; set; }
        public override ConsoleColor ForegroundColor { get; set; }
        public override Coordinates CursorPosition { get; set; }
        public override int CursorSize { get; set; }
        public override bool KeyAvailable => false;
        public override Size MaxPhysicalWindowSize => new Size(_width, 50);
        public override Size MaxWindowSize => new Size(_width, 50);
        public override Coordinates WindowPosition { get; set; }
        public override Size WindowSize { get; set; }
        public override string WindowTitle { get; set; } = "";
        public override void FlushInputBuffer() { }
        public override BufferCell[,] GetBufferContents(Rectangle rectangle) => throw new NotImplementedException();
        public override KeyInfo ReadKey(ReadKeyOptions options) => throw new NotImplementedException();
        public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) => throw new NotImplementedException();
        public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) => throw new NotImplementedException();
        public override void SetBufferContents(Rectangle rectangle, BufferCell fill) => throw new NotImplementedException();
    }
}
'@
    }

    $testHost = [RemoteWrenchTests.WidthHost2]::new($Width, $ThrowOnBufferSize, $NoUI, $NoRawUI)
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
