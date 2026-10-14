using module ../output/RemoteWrench
using namespace System.IO

BeforeAll {
    . ([Path]::Combine($PSScriptRoot, 'common.ps1'))

    $rpid = [Guid]'11111111-1111-1111-1111-111111111111'
    $pipeId = [Guid]'22222222-2222-2222-2222-222222222222'

    # A pipeline output between a Command and DataAck packet.
    $simple = @(
        "<Command PSGuid='$pipeId' />"
        Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data '<S>value</S>' -PSGuid $pipeId -RunspacePoolId $rpid -PipelineId $pipeId -ObjectId 5
        "<DataAck PSGuid='$pipeId' />"
    )
}

Describe "Format-PSRPPacket" {
    It "Defaults to the Timeline view" {
        $packets = $simple | ConvertTo-PSRPPacket
        $default = $packets | Format-PSRPPacket -NoColor -Width 120
        $timeline = $packets | Format-PSRPPacket -View Timeline -NoColor -Width 120

        $default | Should-BeCollection $timeline
    }

    It "Accepts packets as an argument" {
        $packets = $simple | ConvertTo-PSRPPacket
        $byPipeline = $packets | Format-PSRPPacket -NoColor -Width 120
        $byArgument = Format-PSRPPacket -Packet $packets -NoColor -Width 120

        $byArgument | Should-BeCollection $byPipeline
    }

    It "Outputs color with the <View> view unless -NoColor is set" -ForEach @(
        @{ View = 'Timeline' }
        @{ View = 'Grouped' }
        @{ View = 'GroupedDetail' }
    ) {
        $packets = $simple | ConvertTo-PSRPPacket

        ($packets | Format-PSRPPacket -View $View -Width 120) -join "`n" | Should-MatchString "`e\["
        ($packets | Format-PSRPPacket -View $View -Width 120 -NoColor) -join "`n" | Should-NotMatchString "`e"
    }

    It "Supports the NoColour alias" {
        $packets = $simple | ConvertTo-PSRPPacket
        ($packets | Format-PSRPPacket -NoColour -Width 120) -join "`n" | Should-NotMatchString "`e"
    }

    It "Uses the buffer width of a host" {
        $packets = $simple | ConvertTo-PSRPPacket
        $actual = Invoke-FormatInTestHost -Packet $packets -Width 150

        $actual[1] | Should-Be ('─' * 150)
    }

    It "Uses 120 when the host cannot get the buffer width" {
        $packets = $simple | ConvertTo-PSRPPacket
        $actual = Invoke-FormatInTestHost -Packet $packets -ThrowOnBufferSize

        $actual[1] | Should-Be ('─' * 120)
    }

    It "Uses 120 when the host <Name>" -ForEach @(
        # PowerShell wraps the host, reading the width of one without a UI
        # throws.
        @{ Name = 'has no UI'; HostParams = @{ NoUI = $true } }
        @{ Name = 'has no raw UI'; HostParams = @{ NoRawUI = $true } }
        @{ Name = 'reports a width of 0'; HostParams = @{ Width = 0 } }
    ) {
        $packets = $simple | ConvertTo-PSRPPacket
        $actual = Invoke-FormatInTestHost -Packet $packets @HostParams

        $actual[1] | Should-Be ('─' * 120)
    }

    It "Uses the host buffer width by default" {
        # The test host may not have a console, the cmdlet falls back to 120.
        $expected = try { $Host.UI.RawUI.BufferSize.Width } catch { 0 }
        if ($expected -le 0) {
            $expected = 120
        }

        $actual = $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -NoColor

        $actual[1] | Should-Be ('─' * $expected)
    }

    It "Does not warn about the console encoding outside of Windows" -Skip:$IsWindows {
        $warn = $null
        $null = $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -NoColor -Width 120 -WarningVariable warn -WarningAction SilentlyContinue

        $warn | Should-BeCollection -Count 0
    }

    It "Warns when the Windows console encoding is not UTF-8" -Skip:(-not $IsWindows) {
        $original = [Console]::OutputEncoding
        try {
            try {
                [Console]::OutputEncoding = [Text.Encoding]::ASCII
            }
            catch {
                Set-ItResult -Skipped -Because "the console encoding cannot be set in this process: $_"
                return
            }

            $warn = $null
            $null = $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -NoColor -Width 120 -WarningVariable warn -WarningAction SilentlyContinue

            $warn | Should-BeCollection -Count 1
            [string]$warn[0] | Should-BeLikeString '*encoding is us-ascii (code page 20127) and not UTF-8*`[Console`]::OutputEncoding = `[Text.UTF8Encoding`]::new()*'

            [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
            $warn = $null
            $null = $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -NoColor -Width 120 -WarningVariable warn -WarningAction SilentlyContinue

            $warn | Should-BeCollection -Count 0
        }
        finally {
            [Console]::OutputEncoding = $original
        }
    }

    It "Does not warn about the console encoding in a remote session" -Skip:(-not $IsWindows) {
        # A remote session sets the global $PSSenderInfo, its output is sent
        # back to the client so the server console encoding does not matter.
        $identity = [System.Management.Automation.Remoting.PSIdentity]::new('', $true, 'user', $null)
        $principal = [System.Management.Automation.Remoting.PSPrincipal]::new($identity, $null)
        $senderInfo = [System.Management.Automation.Remoting.PSSenderInfo]::new($principal, 'http://localhost')

        $original = [Console]::OutputEncoding
        try {
            try {
                [Console]::OutputEncoding = [Text.Encoding]::ASCII
            }
            catch {
                Set-ItResult -Skipped -Because "the console encoding cannot be set in this process: $_"
                return
            }
            Set-Variable -Name PSSenderInfo -Value $senderInfo -Scope Global

            $warn = $null
            $null = $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -NoColor -Width 120 -WarningVariable warn -WarningAction SilentlyContinue

            $warn | Should-BeCollection -Count 0
        }
        finally {
            Remove-Variable -Name PSSenderInfo -Scope Global -ErrorAction Ignore
            [Console]::OutputEncoding = $original
        }
    }

    It "Rejects a width of <_>" -ForEach 39, 1001 {
        { $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -Width $_ } |
            Should-Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }

    It "Renders <Name> with every view" -ForEach @(
        @{ Name = 'psrp-session.txt' }
        @{ Name = 'psrp-fragments.txt' }
        @{ Name = 'psrp-message-types.txt' }
        @{ Name = 'psrp-create-pipeline.txt' }
        @{ Name = 'large-psrp-packet.txt' }
    ) {
        $packets = Get-TestData $Name | ConvertTo-PSRPPacket -ErrorAction Stop
        foreach ($view in [Enum]::GetNames([RemoteWrench.PSRPPacketView])) {
            $out = $packets | Format-PSRPPacket -View $view -Width 120 -ErrorAction Stop
            $out | Should-NotBeNull -Because "the $view view should output something"
        }
    }
}

Describe "Format-PSRPPacket -View Timeline" {
    It "Formats a line per packet" {
        $actual = $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -View Timeline -NoColor -Width 120

        $actual | Should-BeCollection @(
            '   # Dir Packet     PSGuid   Message                  Obj:Frag       Size Summary'
            '─' * 120
            '   1 C→S Command    22222222                                              create pipeline'
            '   2 S→C Data       22222222 PipelineOutput           5:0 SE          52B "value"'
            '   3 S→C DataAck    22222222'
        )
    }

    It "Drops the PSGuid and Size columns below 110 characters" {
        $actual = $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -View Timeline -NoColor -Width 100

        $actual | Should-BeCollection @(
            '   # Dir Packet     Message                  Obj:Frag    Summary'
            '─' * 100
            '   1 C→S Command                                         create pipeline'
            '   2 S→C Data       PipelineOutput           5:0 SE      "value"'
            '   3 S→C DataAck'
        )
    }

    It "Truncates the summary to the width" {
        $packet = Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data "<S>$('a' * 200)</S>"
        $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View Timeline -NoColor -Width 120

        $actual[2].Length | Should-Be 120
        $actual[2] | Should-BeLikeString '* "aaa*a…'
    }

    It "Formats a row per fragment" {
        $actual = Get-TestData large-psrp-packet.txt | ConvertTo-PSRPPacket |
            Format-PSRPPacket -View Timeline -NoColor -Width 160 |
            Select-Object -Skip 2

        $actual | Should-BeCollection -Count 3
        $actual[0] | Should-BeLikeString '   1 S→C Data       c8cf479a ‹fragment›               327:0 S        32KB start of a fragmented message'
        $actual[1] | Should-BeLikeString '   2 S→C Data       c8cf479a ‹fragment›               327:1          32KB continued'
        $actual[2] | Should-BeLikeString '   3 S→C Data       c8cf479a PipelineOutput           327:2  E       65KB "aaaa*'
    }

    It "Formats a row per message with the packet details on the first" {
        $actual = Get-TestData psrp-session.txt | Select-Object -First 1 | ConvertTo-PSRPPacket |
            Format-PSRPPacket -View Timeline -NoColor -Width 120 |
            Select-Object -Skip 2

        $actual | Should-BeCollection @(
            '   1 C→S Data       00000000 SessionCapability        1:0 SE         199B protocol 2.4, PS 2.0, serialization 1.1.0.1'
            '     C→S                     InitRunspacePool         2:0 SE        3.7KB min 1, max 1, client PS 7.6.6'
        )
    }

    It "Colors an error summary red" {
        $session = Get-TestData psrp-session.txt | ConvertTo-PSRPPacket
        $actual = $session | Format-PSRPPacket -View Timeline -Width 120 | Where-Object { $_ -match 'ErrorRecord' }

        $actual.Contains("`e[31man error") | Should-BeTrue
    }
}

Describe "Format-PSRPPacket -View Grouped" {
    It "Groups messages under their runspace pool and pipeline" {
        $actual = $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -View Grouped -NoColor -Width 120

        $actual | Should-BeCollection @(
            'RunspacePool 11111111-1111-1111-1111-111111111111'
            '├─ Pipeline 22222222-2222-2222-2222-222222222222'
            '│  │ ◀ PipelineOutput           "value"'
        )
    }

    It "Writes a continued header when concurrent pipelines interleave" {
        $actual = Get-TestData psrp-fragments.txt | ConvertTo-PSRPPacket |
            Format-PSRPPacket -View Grouped -NoColor -Width 120 |
            Where-Object { $_ -notlike '│  │*' } |
            ForEach-Object { $_ -replace '\s{2,}.*' }

        $actual | Should-BeCollection @(
            'RunspacePool 83ec94f1-f56d-4de7-b4c9-db80ee3bf554'
            '│ ▶ SessionCapability'
            '│ ▶ InitRunspacePool'
            '│ ◀ SessionCapability'
            '│ ◀ PipelineState'
            '│ ◀ ApplicationPrivateData'
            '│ ◀ RunspacePoolState'
            '├─ Pipeline 6a8eb54b-1d71-434e-a4c6-a862e94df370'
            '├─ Pipeline ec459654-0832-4d7f-9760-b2b384519afb'
            '├─ Pipeline 203d3125-97cc-491d-aaf8-79efbe5a86bd'
            '├─ Pipeline ec459654-0832-4d7f-9760-b2b384519afb (continued)'
            '│ ▶ GetAvailableRunspaces'
            '│ ◀ RunspaceAvailability'
            '│ ◀ UserEvent'
            '├─ Pipeline ec459654-0832-4d7f-9760-b2b384519afb (continued)'
            '├─ Pipeline 203d3125-97cc-491d-aaf8-79efbe5a86bd (continued)'
            '├─ Pipeline ec459654-0832-4d7f-9760-b2b384519afb (continued)'
            '│ ▶ Close (close runspace pool)'
            '│ ◀ RunspacePoolState'
            '│ ◀ RunspacePoolState'
        )
    }

    It "Shows the stop and close requests of a pipeline" {
        $actual = Get-TestData psrp-session.txt | ConvertTo-PSRPPacket |
            Format-PSRPPacket -View Grouped -NoColor -Width 120

        $start = [Array]::IndexOf([string[]]$actual, '├─ Pipeline 203d3125-97cc-491d-aaf8-79efbe5a86bd')
        $actual[($start + 1)..($start + 4)] | Should-BeCollection @(
            '│  │ ▶ CreatePipeline           Start-Sleep 30'
            '│  │ ▶ Signal (stop pipeline)'
            '│  │ ◀ PipelineState            Stopped: The pipeline has been stopped.'
            '│  │ ▶ Close (close pipeline)'
        )
    }

    It "Puts a server message without a runspace pool id in the current pool" {
        # The server's SessionCapability has an empty runspace pool id.
        $actual = Get-TestData psrp-session.txt | ConvertTo-PSRPPacket |
            Format-PSRPPacket -View Grouped -NoColor -Width 120

        $actual | Where-Object { $_ -like 'RunspacePool 00000000*' } | Should-BeNull
        $actual[3] | Should-BeLikeString '│ ◀ SessionCapability*'
    }

}

Describe "Format-PSRPPacket -View GroupedDetail" {
    It "Adds the packet details and decoded fields under each message" {
        $actual = $simple | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 120

        $actual | Should-BeCollection @(
            'RunspacePool 11111111-1111-1111-1111-111111111111'
            '├─ Pipeline 22222222-2222-2222-2222-222222222222'
            '│  │ ◀ PipelineOutput           "value"'
            '│  │     #2 · Data · Obj 5:0 SE · 52B'
            '│  │     value'
        )
    }

    It "Lists every fragment of a message" {
        $actual = Get-TestData large-psrp-packet.txt | ConvertTo-PSRPPacket |
            Format-PSRPPacket -View GroupedDetail -NoColor -Width 120

        $actual[3..5] | Should-BeCollection @(
            '│  │     #1 · Data · Obj 327:0 S · 32KB'
            '│  │     #2 · Data · Obj 327:1 · 32KB'
            '│  │     #3 · Data · Obj 327:2  E · 1.1KB · 65KB total'
        )
    }

    It "Lists the fragments of a message received between other packets" {
        # The 12KB output is received while another pipeline is started, its
        # fragments are packed two to a packet.
        $actual = Get-TestData psrp-fragments.txt | ConvertTo-PSRPPacket |
            Format-PSRPPacket -View GroupedDetail -NoColor -Width 120
        $start = [Array]::FindIndex([string[]]$actual, [Predicate[string]] { param($l) $l -like '*PipelineOutput*"xxx*' })

        $actual[($start + 1)..($start + 9)] | Should-BeCollection @(
            '│  │     #20 · Data · Obj 1:0 S · 1.4KB'
            '│  │     #20 · Data · Obj 1:1 · 1.4KB'
            '│  │     #22 · Data · Obj 1:2 · 1.4KB'
            '│  │     #22 · Data · Obj 1:3 · 1.4KB'
            '│  │     #24 · Data · Obj 1:4 · 1.4KB'
            '│  │     #24 · Data · Obj 1:5 · 1.4KB'
            '│  │     #26 · Data · Obj 1:6 · 1.4KB'
            '│  │     #26 · Data · Obj 1:7 · 1.4KB'
            '│  │     #28 · Data · Obj 1:8  E · 1.1KB · 12KB total'
        )
    }

    It "Lists the fragments of a message that ends in a packet starting another" {
        $actual = Get-TestData psrp-fragments.txt | ConvertTo-PSRPPacket |
            Format-PSRPPacket -View GroupedDetail -NoColor -Width 120
        $start = [Array]::FindIndex([string[]]$actual, [Predicate[string]] { param($l) $l -like '*PipelineOutput*"yyy*' })

        $actual[($start + 1)..($start + 3)] | Should-BeCollection @(
            '│  │     #30 · Data · Obj 10:0 S · 1.4KB'
            '│  │     #30 · Data · Obj 10:1 · 1.4KB'
            '│  │     #31 · Data · Obj 10:2  E · 322B · 3KB total'
        )
    }

    It "Keeps the line breaks of a multi-line script" {
        $actual = Get-TestData psrp-create-pipeline.txt | Select-Object -Last 1 | ConvertTo-PSRPPacket |
            Format-PSRPPacket -View GroupedDetail -NoColor -Width 120

        $actual[4..8] | Should-BeCollection @(
            '│  │     Command        $a = 1'
            '│  │                    $b = 2'
            '│  │                    if ($a) {'
            '│  │                        $a + $b'
            '│  │                    }'
        )
    }

    It "Wraps values at 120 characters on a wider terminal" {
        $packet = Get-PSRPPacket -Destination Client -MessageType WarningRecord -Data "<Obj RefId=`"0`"><MS><S N=`"InformationalRecord_Message`">$('word ' * 60)</S></MS></Obj>"
        $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 300

        # The summary line uses the full width, the fields wrap at 120.
        $actual | Select-Object -Skip 2 | Where-Object { $_.Length -gt 120 } | Should-BeNull
        $actual | Where-Object { $_ -like '│     Message*' } | Should-BeCollection -Count 1
        @($actual | Where-Object { $_ -like '│              word*' }).Count | Should-BeGreaterThan 0
    }

    It "Wraps a value without spaces at the width" {
        $packet = Get-PSRPPacket -Destination Client -MessageType WarningRecord -Data "<Obj RefId=`"0`"><MS><S N=`"InformationalRecord_Message`">$('a' * 150)</S></MS></Obj>"
        $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 80

        $actual[3..5] | Should-BeCollection @(
            "│     Message  $('a' * 65)"
            "│              $('a' * 65)"
            "│              $('a' * 20)"
        )
    }
}

Describe "Format-PSRPPacket message decoding" {
    Context "CreatePipeline" {
        BeforeAll {
            $summaries = Get-TestData psrp-create-pipeline.txt | Get-MessageSummary
        }

        It "Formats <Name>" -ForEach @(
            @{ Index = 0; Name = 'a single command'; Expected = 'Get-Date' }
            @{ Index = 1; Name = 'named parameters and a switch'; Expected = 'Get-ChildItem -Path /tmp -Force -Depth 1' }
            @{ Index = 2; Name = 'an explicit false switch'; Expected = 'Get-ChildItem -Force:$false' }
            @{ Index = 3; Name = 'positional arguments'; Expected = 'Write-Output ''a b'' 1 $null' }
            @{ Index = 4; Name = 'a pipeline with an array argument'; Expected = 'Get-Process | Where-Object -Property Id -GT -Value 0 | Select-Object Name, Id -First 2' }
            @{ Index = 5; Name = 'multiple statements'; Expected = 'Get-Date; Write-Output second; "third"' }
            @{ Index = 6; Name = 'a script with arguments'; Expected = '. { param($a, $b) "$a $b" } x -b y' }
            @{ Index = 7; Name = 'a script with its own scope'; Expected = '& { $x = 1 }' }
            @{ Index = 8; Name = 'error redirected to output'; Expected = '. { Write-Error err; "out" } 2>&1' }
            @{ Index = 9; Name = 'every stream redirected to output'; Expected = '. { Write-Warning w; "out" } *>&1' }
            # The hashtable entries are in hash order.
            @{ Index = 10; Name = 'a hashtable argument'; Expected = '^Write-Output -InputObject @\{(Key = ''value''; Num = 2|Num = 2; Key = ''value'')\} -NoEnumerate$' }
            @{ Index = 11; Name = 'a multi-line script'; Expected = '$a = 1↵$b = 2↵if ($a) {↵$a + $b↵}' }
        ) {
            $summaries[$Index].MessageType | Should-Be CreatePipeline
            if ($Expected.StartsWith('^')) {
                $summaries[$Index].Summary | Should-MatchString $Expected
            }
            else {
                $summaries[$Index].Summary | Should-Be $Expected
            }
        }

        It "Formats <Name>" -ForEach @(
            @{ Name = 'array items that need quotes'; Expected = 'Write-Output Name, ''My Prop'', ''a,b'', ''it''''s''' }
            @{ Name = 'a command with its scope unset or true'; Expected = 'Test-Scope' }
            @{ Name = 'a command with its scope false'; Expected = '. Test-Scope' }
            @{ Name = 'a script with its scope unset or false'; Expected = '$y = 1' }
            @{ Name = 'a script with its scope true'; Expected = '& { $y = 1 }' }
            @{ Name = 'a script in a pipeline'; Expected = '. { Write-Error e; 1 } 2>&1 | Out-String' }
        ) {
            $actual = Get-TestData psrp-message-types.txt | Get-MessageSummary |
                Where-Object MessageType -EQ CreatePipeline |
                ForEach-Object Summary
            $actual | Should-ContainCollection $Expected
        }

        It "Formats <Name>" -ForEach @(
            @{
                Name = 'a multi-line script with its own scope'
                Command = '<S N="Cmd">$a = 1_x000A_$b</S><B N="IsScript">true</B><B N="UseLocalScope">true</B>'
                Expected = '& {↵$a = 1↵$b↵}'
            }
            @{
                Name = 'an older client merging the error stream'
                Command = '<S N="Cmd">Get-Item</S><B N="IsScript">false</B><Obj N="MergeMyResult"><I32>2</I32></Obj><Obj N="MergeToResult"><I32>1</I32></Obj>'
                Expected = 'Get-Item 2>&1'
            }
            @{
                Name = 'an older client merging every stream'
                Command = '<S N="Cmd">Get-Item</S><B N="IsScript">false</B><Obj N="MergeMyResult"><I32>7</I32></Obj><Obj N="MergeToResult"><I32>1</I32></Obj>'
                Expected = 'Get-Item *>&1'
            }
            @{
                Name = 'streams redirected to null'
                Command = '<S N="Cmd">Get-Item</S><B N="IsScript">false</B><Obj N="MergeError"><I32>8</I32></Obj><Obj N="MergeVerbose"><I32>1</I32></Obj>'
                Expected = 'Get-Item 2>$null 4>&1'
            }
            @{
                Name = 'positional bool and single item array arguments'
                Command = '<S N="Cmd">Write-Output</S><B N="IsScript">false</B><Obj N="Args"><LST><Obj><MS><Nil N="N" /><B N="V">true</B></MS></Obj><Obj><MS><Nil N="N" /><Obj N="V"><TN RefId="0"><T>System.Object[]</T><T>System.Object</T></TN><LST><S>a</S></LST></Obj></MS></Obj></LST></Obj>'
                Expected = 'Write-Output $true @(a)'
            }
            @{
                Name = 'an object argument'
                Command = '<S N="Cmd">Write-Output</S><B N="IsScript">false</B><Obj N="Args"><LST><Obj><MS><S N="N">InputObject</S><Obj N="V"><TN RefId="0"><T>System.Management.Automation.PSCustomObject</T><T>System.Object</T></TN><MS><S N="A">x y</S><I32 N="B">1</I32></MS></Obj></MS></Obj></LST></Obj>'
                Expected = "Write-Output -InputObject [PSCustomObject]@{A = 'x y'; B = 1}"
            }
            @{
                Name = 'an empty string argument'
                Command = '<S N="Cmd">Write-Output</S><B N="IsScript">false</B><Obj N="Args"><LST><Obj><MS><Nil N="N" /><S N="V"></S></MS></Obj></LST></Obj>'
                Expected = "Write-Output ''"
            }
            @{
                Name = 'a positional false argument'
                Command = '<S N="Cmd">Write-Output</S><B N="IsScript">false</B><Obj N="Args"><LST><Obj><MS><Nil N="N" /><B N="V">false</B></MS></Obj></LST></Obj>'
                Expected = 'Write-Output $false'
            }
            @{
                Name = 'a stream redirected to another stream'
                Command = '<S N="Cmd">Get-Item</S><B N="IsScript">false</B><Obj N="MergeWarning"><I32>2</I32></Obj>'
                Expected = 'Get-Item 3>&2'
            }
            @{
                Name = 'an object argument with only a ToString'
                Command = '<S N="Cmd">Write-Output</S><B N="IsScript">false</B><Obj N="Args"><LST><Obj><MS><Nil N="N" /><Obj N="V"><TN RefId="0"><T>Test.Thing</T><T>System.Object</T></TN><ToString>value</ToString></Obj></MS></Obj></LST></Obj>'
                Expected = 'Write-Output value'
            }
            @{
                # The parser decides if a string needs quotes, a dash would
                # make it a parameter and a number would not be a string.
                Name = 'string arguments that need quotes to be read back as the same string'
                Command = '<S N="Cmd">Write-Output</S><B N="IsScript">false</B><Obj N="Args"><LST><Obj><MS><Nil N="N" /><S N="V">-x</S></MS></Obj><Obj><MS><Nil N="N" /><S N="V">–x</S></MS></Obj><Obj><MS><Nil N="N" /><S N="V">1</S></MS></Obj><Obj><MS><Nil N="N" /><S N="V">10kb</S></MS></Obj><Obj><MS><Nil N="N" /><S N="V">a=b</S></MS></Obj></LST></Obj>'
                Expected = "Write-Output '-x' '–x' '1' '10kb' a=b"
            }
            @{
                # PowerShell also treats typographic quotes as single quotes,
                # the one in the XML is doubled to escape it in this string.
                Name = 'a string argument with a typographic quote'
                Command = '<S N="Cmd">Write-Output</S><B N="IsScript">false</B><Obj N="Args"><LST><Obj><MS><Nil N="N" /><S N="V">it’’s</S></MS></Obj></LST></Obj>'
                Expected = "Write-Output 'it’’s'"
            }
        ) {
            $packet = Get-PSRPPacket -Destination Server -MessageType CreatePipeline -Data (New-CreatePipelineData $Command)
            $actual = $packet | Get-MessageSummary

            $actual.Summary | Should-Be $Expected
        }

        It "Formats each scope setting of a command and script" {
            # The captures run Test-Scope and '$y = 1' with the scope unset,
            # true, then false.
            $actual = Get-TestData psrp-message-types.txt | Get-MessageSummary |
                Where-Object { $_.MessageType -eq 'CreatePipeline' -and $_.Summary -match '^(\. |& \{ )?(Test-Scope|\$y = 1)' } |
                ForEach-Object Summary

            $actual | Should-BeCollection @(
                'Test-Scope'
                'Test-Scope'
                '. Test-Scope'
                '$y = 1'
                '& { $y = 1 }'
                '$y = 1'
            )
        }
    }

    Context "Captured messages" {
        BeforeAll {
            $summaries = Get-TestData psrp-message-types.txt, psrp-session.txt | Get-MessageSummary
        }

        It "Formats <MessageType>" -ForEach @(
            @{ MessageType = 'SessionCapability'; Arrow = '▶'; Expected = 'protocol 2.4, PS 2.0, serialization 1.1.0.1' }
            @{ MessageType = 'InitRunspacePool'; Arrow = '▶'; Expected = 'min 1, max 1, client PS 7.6.6' }
            @{ MessageType = 'RunspacePoolState'; Arrow = '◀'; Expected = 'Opened' }
            @{ MessageType = 'PipelineState'; Arrow = '◀'; Expected = 'Completed' }
            @{ MessageType = 'ResetRunspaceState'; Arrow = '▶'; Expected = '(ci 1)' }
            @{ MessageType = 'RunspaceAvailability'; Arrow = '◀'; Expected = 'succeeded (ci 1)' }
            @{ MessageType = 'SetMaxRunspaces'; Arrow = '▶'; Expected = 'max 3 (ci 2)' }
            @{ MessageType = 'SetMinRunspaces'; Arrow = '▶'; Expected = 'min 2 (ci 3)' }
            @{ MessageType = 'GetAvailableRunspaces'; Arrow = '▶'; Expected = '(ci 4)' }
            @{ MessageType = 'GetCommandMetadata'; Arrow = '▶'; Expected = 'Get-Command -Name Get-Date, Get-Item -CommandType Cmdlet' }
            @{ MessageType = 'UserEvent'; Arrow = '◀'; Expected = 'RWForward: "event data"' }
            @{ MessageType = 'PipelineHostCall'; Arrow = '◀'; Expected = 'WriteLine2("from event action")' }
            @{ MessageType = 'ConnectRunspacePool'; Arrow = '▶'; Expected = 'connect' }
            @{ MessageType = 'RunspacePoolInitData'; Arrow = '◀'; Expected = 'min 1, max 5' }
            @{ MessageType = 'RunspacePoolHostCall'; Arrow = '◀'; Expected = 'WriteWarningLine("a warning")' }
            @{ MessageType = 'RunspacePoolHostResponse'; Arrow = '▶'; Expected = 'PromptForCredential2 → [PSCredential] @{UserName=foo; Password=[SecureString]}' }
            @{ MessageType = 'PipelineInput'; Arrow = '▶'; Expected = '"piped"' }
            @{ MessageType = 'EndOfPipelineInput'; Arrow = '▶'; Expected = 'end of input' }
            @{ MessageType = 'ErrorRecord'; Arrow = '◀'; Expected = 'an error' }
            @{ MessageType = 'WarningRecord'; Arrow = '◀'; Expected = 'a warning' }
            @{ MessageType = 'VerboseRecord'; Arrow = '◀'; Expected = 'verbose msg' }
            @{ MessageType = 'DebugRecord'; Arrow = '◀'; Expected = 'debug msg' }
            @{ MessageType = 'InformationRecord'; Arrow = '◀'; Expected = 'info msg [tag1]' }
            @{ MessageType = 'ProgressRecord'; Arrow = '◀'; Expected = 'Act: Working (50%)' }
        ) {
            $actual = $summaries | Where-Object MessageType -EQ $MessageType | Select-Object -First 1
            $actual.Arrow | Should-Be $Arrow
            $actual.Summary | Should-Be $Expected
        }

        It "Formats ApplicationPrivateData" {
            # The entries are in hashtable order.
            $actual = ($summaries | Where-Object MessageType -EQ ApplicationPrivateData | Select-Object -First 1).Summary

            $actual | Should-BeLikeString 'server PS 7.6.6, *'
            foreach ($entry in 'DebugMode=1', 'BreakAll=False', 'DebugStop=False', 'DebugBreakpointCount=0', 'UnhandledBreakpointMode=1') {
                $actual | Should-BeLikeString "*$entry*"
            }
        }

        It "Formats the response to GetAvailableRunspaces" {
            $summaries.Summary | Should-ContainCollection '3 available (ci 4)'
        }

        It "Hides a SecureString" {
            $summaries | Where-Object { $_.MessageType -eq 'PipelineOutput' -and $_.Summary -eq '[SecureString]' } |
                Should-NotBeNull
        }

        It "Formats a stopped pipeline with its error" {
            $summaries.Summary | Should-ContainCollection 'Stopped: The pipeline has been stopped.'
        }
    }

    Context "Crafted messages" {
        It "Formats <Name>" -ForEach @(
            @{
                Name = 'a broken runspace pool'
                MessageType = 'RunspacePoolState'
                Data = '<Obj RefId="0"><MS><I32 N="RunspaceState">5</I32><Obj N="ExceptionAsErrorRecord" RefId="1"><TN RefId="0"><T>System.Management.Automation.ErrorRecord</T><T>System.Object</T></TN><ToString>boom</ToString><MS><S N="FullyQualifiedErrorId">BoomId</S></MS></Obj></MS></Obj>'
                Expected = 'Broken: boom'
            }
            @{
                Name = 'a failed host response'
                MessageType = 'PipelineHostResponse'
                Data = '<Obj RefId="0"><MS><Obj N="me" RefId="1"><TN RefId="0"><T>System.Management.Automation.ErrorRecord</T><T>System.Object</T></TN><ToString>host failed</ToString></Obj><I64 N="ci">5</I64><Obj N="mi" RefId="2"><TN RefId="1"><T>System.Management.Automation.Remoting.RemoteHostMethodId</T><T>System.Enum</T><T>System.ValueType</T><T>System.Object</T></TN><ToString>ReadLine</ToString><I32>11</I32></Obj></MS></Obj>'
                Expected = 'ReadLine failed: host failed'
            }
            @{
                Name = 'a failed runspace availability'
                MessageType = 'RunspaceAvailability'
                Data = '<Obj RefId="0"><MS><B N="SetMinMaxRunspacesResponse">false</B><I64 N="ci">7</I64></MS></Obj>'
                Expected = 'failed (ci 7)'
            }
            @{
                Name = 'a progress record without a percentage'
                MessageType = 'ProgressRecord'
                Data = '<Obj RefId="0"><MS><S N="Activity">Act</S><S N="StatusDescription">Status</S><I32 N="PercentComplete">-1</I32></MS></Obj>'
                Expected = 'Act: Status'
            }
            @{
                Name = 'output of a list'
                MessageType = 'PipelineOutput'
                Data = '<Obj RefId="0"><TN RefId="0"><T>System.Object[]</T><T>System.Array</T><T>System.Object</T></TN><LST><I32>1</I32><I32>2</I32></LST></Obj>'
                Expected = '[Object[]] 1 2'
            }
            @{
                Name = 'a message without data'
                MessageType = 'PipelineOutput'
                Data = ''
                Expected = ''
            }
            @{
                Name = 'a completed progress record'
                MessageType = 'ProgressRecord'
                Data = '<Obj RefId="0"><MS><S N="Activity">Act</S><S N="StatusDescription"> </S><I32 N="PercentComplete">100</I32><Obj N="Type" RefId="1"><TN RefId="0"><T>System.Management.Automation.ProgressRecordType</T><T>System.Enum</T><T>System.ValueType</T><T>System.Object</T></TN><ToString>Completed</ToString><I32>1</I32></Obj></MS></Obj>'
                Expected = 'Act (100%) (completed)'
            }
            @{
                Name = 'a runspace pool request without a call id'
                MessageType = 'SetMaxRunspaces'
                Data = '<Obj RefId="0"><MS><I32 N="MaxRunspaces">4</I32></MS></Obj>'
                Expected = 'max 4'
            }
            @{
                Name = 'a user event without message data'
                MessageType = 'UserEvent'
                Data = '<Obj RefId="0"><MS><S N="PSEventArgs.SourceIdentifier">src</S><Obj N="PSEventArgs.SourceArgs" RefId="1"><LST><S>a</S><I32>1</I32></LST></Obj></MS></Obj>'
                Expected = 'src'
            }
            @{
                Name = 'a string with control characters'
                MessageType = 'PipelineOutput'
                Data = '<S>a_x000D__x000A_b_x000D_c_x0009_d_x0001_</S>'
                Expected = '"a↵b↵c d·"'
            }
            @{
                Name = 'a data shape that does not match the message type'
                MessageType = 'InitRunspacePool'
                Data = '<S>value</S>'
                Expected = 'min $null, max $null'
            }
            @{
                Name = 'a public key with two padding characters'
                MessageType = 'PublicKey'
                Data = '<Obj RefId="0"><MS><S N="PublicKey">AAAAAA==</S></MS></Obj>'
                Expected = 'RSA public key, 4 bytes'
            }
            @{
                Name = 'a public key without padding'
                MessageType = 'PublicKey'
                Data = '<Obj RefId="0"><MS><S N="PublicKey">AAAA</S></MS></Obj>'
                Expected = 'RSA public key, 3 bytes'
            }
            @{
                Name = 'an encrypted session key with one padding character'
                MessageType = 'EncryptedSessionKey'
                Data = '<Obj RefId="0"><MS><S N="EncryptedSessionKey">AAAAAAA=</S></MS></Obj>'
                Expected = 'encrypted session key, 5 bytes'
            }
            @{
                Name = 'a public key request'
                MessageType = 'PublicKeyRequest'
                Data = '<S></S>'
                Expected = 'request for the client public key'
            }
            @{
                Name = 'an information record without tags'
                MessageType = 'InformationRecord'
                Data = '<Obj RefId="0"><MS><S N="MessageData">msg</S></MS></Obj>'
                Expected = 'msg'
            }
            @{
                Name = 'a host call without a call id'
                MessageType = 'PipelineHostCall'
                Data = '<Obj RefId="0"><MS><S N="mi">WriteLine1</S></MS></Obj>'
                Expected = 'WriteLine1()'
            }
            @{
                Name = 'a state that is not a number'
                MessageType = 'RunspacePoolState'
                Data = '<Obj RefId="0"><MS><S N="RunspaceState">Custom</S></MS></Obj>'
                Expected = 'Custom'
            }
            @{
                Name = 'a string ending with a carriage return'
                MessageType = 'PipelineOutput'
                Data = '<S>a_x000D_</S>'
                Expected = '"a↵"'
            }
            @{
                Name = 'output of a byte array'
                MessageType = 'PipelineOutput'
                Data = '<BA>AQID</BA>'
                Expected = '[Byte[]] 1 2 3'
            }
            @{
                Name = 'output with a ToString that has its own type prefix'
                MessageType = 'PipelineOutput'
                Data = '<Obj RefId="0"><TN RefId="0"><T>Test.Thing</T><T>System.Object</T></TN><ToString>[already]</ToString><MS><S N="A">1</S></MS></Obj>'
                Expected = '[already]'
            }
            @{
                Name = 'output of an empty string'
                MessageType = 'PipelineOutput'
                Data = '<S></S>'
                Expected = '""'
            }
            @{
                Name = 'an error record without an exception'
                MessageType = 'ErrorRecord'
                Data = '<Obj RefId="0"><TN RefId="0"><T>System.Management.Automation.ErrorRecord</T><T>System.Object</T></TN><ToString>oops</ToString><MS><S N="FullyQualifiedErrorId">Id</S></MS></Obj>'
                Expected = 'oops'
            }
        ) {
            $packet = Get-PSRPPacket -Destination Client -MessageType $MessageType -Data $Data
            $actual = $packet | Get-MessageSummary

            $actual.MessageType | Should-Be $MessageType
            $actual.Summary | Should-Be $Expected
        }

        It "Colors <Name> as an error" -ForEach @(
            @{ Name = 'a failed runspace availability'; MessageType = 'RunspaceAvailability'; Data = '<Obj RefId="0"><MS><B N="SetMinMaxRunspacesResponse">false</B><I64 N="ci">7</I64></MS></Obj>' }
            @{ Name = 'invalid CLIXML'; MessageType = 'PipelineOutput'; Data = '<Obj>' }
        ) {
            $packet = Get-PSRPPacket -Destination Client -MessageType $MessageType -Data $Data
            $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View Timeline -Width 120 | Select-Object -Last 1

            $actual.Contains("`e[31m") | Should-BeTrue
        }

        It "Formats invalid CLIXML" {
            $packet = Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data '<Obj>'
            $actual = $packet | Get-MessageSummary

            $actual.Summary | Should-BeLikeString 'invalid CLIXML: *'
        }

        It "Formats an unknown message type with its properties" {
            $messageType = [Enum]::ToObject([RemoteWrench.PSRPMessageType], 0x00099999)
            $packet = Get-PSRPPacket -Destination Client -MessageType $messageType -Data '<Obj RefId="0"><MS><S N="A">1</S><I32 N="B">2</I32></MS></Obj>'
            $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View Timeline -NoColor -Width 120 | Select-Object -Last 1

            $actual | Should-BeLikeString '*629145 * A="1", B=2'
        }

        It "Shows the source arguments of a user event" {
            $data = '<Obj RefId="0"><MS><S N="PSEventArgs.SourceIdentifier">src</S><Obj N="PSEventArgs.SourceArgs" RefId="1"><LST><S>a</S><I32>1</I32></LST></Obj></MS></Obj>'
            $packet = Get-PSRPPacket -Destination Client -MessageType UserEvent -Data $data
            $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 120

            $actual | Should-ContainCollection '│     SourceArgs        "a", 1'
        }

        It "Limits the children of the data tree" {
            $items = (1..60 | ForEach-Object { "<I32>$_</I32>" }) -join ''
            $packet = Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data "<Obj RefId=`"0`"><TN RefId=`"0`"><T>System.Object[]</T><T>System.Object</T></TN><LST>$items</LST></Obj>"
            $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 120

            $actual | Should-ContainCollection '│     ├─ [49]: 50'
            $actual | Should-ContainCollection '│     └─ … 10 more'
        }

        It "Formats the size of a message over 1MB" {
            $packet = Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data "<S>$('a' * 1.2MB)</S>"
            $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View Timeline -NoColor -Width 120 | Select-Object -Last 1

            $actual | Should-BeLikeString '* 1.2MB "aaa*'
        }

        It "Formats a packet of an unknown type" {
            $actual = "<Unknown PSGuid='$pipeId' />" | ConvertTo-PSRPPacket | Format-PSRPPacket -View Timeline -NoColor -Width 120 | Select-Object -Last 1

            $actual | Should-Be '   1  ?  Unknown    22222222'
        }

        It "Formats a message type that is not known with its value" {
            $messageType = [Enum]::ToObject([RemoteWrench.PSRPMessageType], 0x00099999)
            $packet = Get-PSRPPacket -Destination Client -MessageType $messageType -Data '<S>x</S>'
            $actual = $packet | Get-MessageSummary

            $actual.MessageType | Should-Be '629145'
            $actual.Summary | Should-Be '"x"'
        }

        It "Formats a message with a destination that is not known" {
            $destination = [Enum]::ToObject([RemoteWrench.PSRPDestination], 3)
            $packet = Get-PSRPPacket -Destination $destination -MessageType PipelineOutput -Data '<S>x</S>'
            $actual = $packet | Get-MessageSummary

            $actual.Arrow | Should-Be '•'
            $actual.Summary | Should-Be '"x"'

            $timeline = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -NoColor -Width 120 | Select-Object -Last 1
            $timeline | Should-BeLikeString '   1  ?  Data*'
        }

        It "Shows each item of a byte array" {
            $packet = Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data '<BA>AQID</BA>'
            $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 120

            $actual[3..6] | Should-BeCollection @(
                '│     [Byte[]]'
                '│     ├─ [0]: 1'
                '│     ├─ [1]: 2'
                '│     └─ [2]: 3'
            )
        }

        It "Stops the data tree of an object that contains itself" {
            # CLIXML can reference an earlier object, deserialized the object is
            # its own property.
            $packet = Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data '<Obj RefId="0"><MS><S N="Name">a</S><Ref N="Self" RefId="0" /></MS></Obj>'
            $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 120

            $actual[-1] | Should-BeLikeString '*└─ Self: …'
        }

        It "Stops the formatting of an argument that contains itself" {
            # Formatting this without a depth limit overflowed the stack and
            # crashed the process.
            $argument = '<Obj><MS><S N="N">InputObject</S><Obj N="V" RefId="9"><TN RefId="0"><T>System.Collections.Hashtable</T><T>System.Object</T></TN><DCT><En><S N="Key">Self</S><Ref N="Value" RefId="9" /></En></DCT></Obj></MS></Obj>'
            $command = "<S N=`"Cmd`">Write-Output</S><B N=`"IsScript`">false</B><Obj N=`"Args`"><LST>$argument</LST></Obj>"
            $packet = Get-PSRPPacket -Destination Server -MessageType CreatePipeline -Data (New-CreatePipelineData $command)
            $actual = $packet | Get-MessageSummary

            $actual.Summary | Should-BeLikeString 'Write-Output -InputObject @{Self = @{Self = *@{… = …}*'
        }

        Context "Objects with type extensions that throw" {
            BeforeAll {
                $badToString = 'RemoteWrench.Test.BadToString'
                $badProperty = 'RemoteWrench.Test.BadProperty'
                Update-TypeData -TypeName "Deserialized.$badToString" -MemberType ScriptMethod -MemberName ToString -Value { throw 'bad ToString' } -Force
                Update-TypeData -TypeName "Deserialized.$badProperty" -MemberType ScriptProperty -MemberName FullyQualifiedErrorId -Value { throw 'bad property' } -Force

                Function New-ObjectData {
                    param ([string]$TypeName, [switch]$WithToString)

                    $toString = $WithToString ? '<ToString>oops</ToString>' : ''
                    "<Obj RefId=`"0`"><TN RefId=`"0`"><T>$TypeName</T><T>System.Object</T></TN>$toString<MS><S N=`"A`">1</S></MS></Obj>"
                }
            }

            AfterAll {
                Remove-TypeData -TypeName "Deserialized.$badToString"
                Remove-TypeData -TypeName "Deserialized.$badProperty"
            }

            It "Shows the raw CLIXML when the message cannot be decoded" {
                $data = New-ObjectData $badToString
                $packet = Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data $data
                $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 1000

                $actual[1] | Should-BeLikeString '│ ◀ PipelineOutput*unexpected data: *bad ToString*'
                # The raw value is wrapped like any other field.
                $actual[3] | Should-BeLikeString '│     Data  <Obj RefId="0"><TN RefId="0"><T>RemoteWrench.Test.BadToString</T>*'
                ($actual[3..4] -replace '^│ +Data  |^│ +') -join ' ' | Should-Be $data
            }

            It "Skips a field with a property that throws" {
                $packet = Get-PSRPPacket -Destination Client -MessageType ErrorRecord -Data (New-ObjectData $badProperty -WithToString)
                $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 120

                $actual[1..3] | Should-BeCollection @(
                    '│ ◀ ErrorRecord                 oops'
                    '│     #1 · Data · Obj 1:0 SE · 184B'
                    '│     Message  oops'
                )
            }

            It "Skips a property that throws in the data tree" {
                $packet = Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data (New-ObjectData $badProperty -WithToString)
                $actual = $packet | ConvertTo-PSRPPacket | Format-PSRPPacket -View GroupedDetail -NoColor -Width 120

                $actual[3..4] | Should-BeCollection @(
                    '│     [BadProperty] oops'
                    '│     └─ A: 1'
                )
            }
        }

        It "Marks a host call that expects no response" {
            $actual = Get-TestData psrp-session.txt | ConvertTo-PSRPPacket |
                Format-PSRPPacket -View GroupedDetail -NoColor -Width 120
            $start = [Array]::FindIndex([string[]]$actual, [Predicate[string]] { param($l) $l -like '*PipelineHostCall*WriteWarningLine*' })

            $actual[($start + 2)..($start + 4)] | Should-BeCollection @(
                '│  │     Method  WriteWarningLine'
                '│  │     CallId  -100 (no response)'
                '│  │     Arg[0]  "a warning"'
            )
        }
    }
}
