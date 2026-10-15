using module ../output/RemoteWrench
using namespace System.IO

BeforeAll { . ([Path]::Combine($PSScriptRoot, 'common.ps1')) }

Describe "Enter-ExtSession" {
    It "Fails when the session factory outputs <Description>" -TestCases @(
        @{ Description = 'nothing'; Factory = { }; Expected = '*must output one PSSession or remote Runspace but it output 0 objects*' }
        @{ Description = 'two objects'; Factory = { 1; 2 }; Expected = '*must output one PSSession or remote Runspace but it output 2 objects*' }
        @{ Description = 'another type'; Factory = { 'foo' }; Expected = '*must output a PSSession or remote Runspace but it output System.String*' }
        @{ Description = 'a local runspace'; Factory = { [RunspaceFactory]::CreateRunspace() }; Expected = '*but it output a local Runspace*' }
    ) {
        param ($Factory, $Expected)

        { Enter-ExtSession $Factory } | Should-Throw -ExceptionMessage $Expected
    }

    It "Has the parameters of New-PSSession" {
        $actual = Get-Command Enter-ExtSession

        foreach ($name in 'ComputerName', 'Credential', 'Port', 'UseSSL', 'ConnectionUri', 'SessionOption') {
            $actual.Parameters.Keys | Should-ContainCollection $name
        }
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            foreach ($name in 'HostName', 'UserName', 'KeyFilePath', 'SSHConnection') {
                $actual.Parameters.Keys | Should-ContainCollection $name
            }
        }

        # These don't apply to the one session it creates and enters.
        foreach ($name in 'Name', 'ThrottleLimit', 'Session') {
            $actual.Parameters.Keys | Should-NotContainCollection $name
        }
        $actual.ParameterSets.Name | Should-NotContainCollection 'Session'
        $actual.DefaultParameterSet | Should-Be ComputerName

        # Pipeline input is only for -Function, New-PSSession takes some of
        # these by property name.
        $pipelineParams = $actual.Parameters.Values | Where-Object {
            $_.ParameterSets.Values | Where-Object { $_.ValueFromPipeline -or $_.ValueFromPipelineByPropertyName }
        } | ForEach-Object Name
        $pipelineParams | Should-BeCollection @('Function')
    }

    It "Binds a positional scriptblock to -SessionFactory and a string to -ComputerName" {
        $commands = { Enter-ExtSession { 1 }; Enter-ExtSession server }.Ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst]
        }, $true)

        $factory = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($commands[0])
        $factory.BoundParameters.Keys | Should-BeCollection @('SessionFactory')
        $computerName = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($commands[1])
        $computerName.BoundParameters.Keys | Should-BeCollection @('ComputerName')
    }

    It "Fails when -<Name> has more than one value" -TestCases @(
        @{ Name = 'ComputerName'; Value = @('server1', 'server2') }
        @{ Name = 'ConnectionUri'; Value = @([Uri]'http://server1:5985/wsman', [Uri]'http://server2:5985/wsman') }
    ) {
        param ($Name, $Value)

        $params = @{ $Name = $Value }
        $err = { Enter-ExtSession @params } | Should-Throw

        $err.FullyQualifiedErrorId | Should-Be 'MultipleSessionTargets,RemoteWrench.Commands.EnterExtSession'
        [string]$err | Should-Be "-$Name has 2 values, Enter-ExtSession enters one session."
    }

    It "Fails with the error from New-PSSession" {
        # Nothing listens on the port, or there is no WSMan client, either way
        # it fails straight away.
        $err = { Enter-ExtSession -ConnectionUri http://127.0.0.1:1/wsman } | Should-Throw

        $err.FullyQualifiedErrorId | Should-Be 'NewPSSessionFailed,RemoteWrench.Commands.EnterExtSession'
        [string]$err | Should-BeLikeString 'Failed to create the session: *'
    }

    It "Fails before creating the session when the host can't enter one" {
        $ps = [PowerShell]::Create()
        try {
            # The default host of a PowerShell instance can't enter a session.
            $null = $ps.AddScript({
                param ($ModulePath)

                Import-Module -Name $ModulePath
                try {
                    Enter-ExtSession { throw 'the factory ran' }
                }
                catch {
                    $_
                }
            }).AddArgument((Get-Module -Name RemoteWrench).Path)
            $err = $ps.Invoke() | Select-Object -First 1
        }
        finally {
            $ps.Dispose()
        }

        $err.FullyQualifiedErrorId | Should-Be 'HostIsNotInteractive,RemoteWrench.Commands.EnterExtSession'
        [string]$err | Should-BeLikeString "The host '*' does not support entering a remote session, run Enter-ExtSession from an interactive host*"
    }

    It "Writes an error for a duplicate function name" {
        $functions = @(
            New-ExtFunction Get-Thing { 1 }
            New-ExtFunction Get-Thing { 2 }
        )
        try {
            Enter-ExtSession { } -Function $functions -ErrorAction SilentlyContinue -ErrorVariable err
        }
        catch {
            $_.FullyQualifiedErrorId | Should-Be 'InvalidSessionFactoryOutput,RemoteWrench.Commands.EnterExtSession'
        }

        # The error variable has the factory's error after it.
        $err[0].FullyQualifiedErrorId | Should-Be 'DuplicateExtFunctionName,RemoteWrench.Commands.EnterExtSession'
        [string]$err[0] | Should-Be "A function named 'Get-Thing' was already provided, ignoring this one."
    }

    It "Fails when the session can't be opened" {
        # A process without PowerShell has no named pipe to connect to.
        $process = if ($IsWindows) {
            Start-Process -FilePath ([Path]::Combine($env:SystemRoot, 'System32', 'ping.exe')) -ArgumentList '-n', '30', '127.0.0.1' -WindowStyle Hidden -PassThru
        }
        else {
            Start-Process -FilePath sleep -ArgumentList 30 -PassThru
        }
        try {
            $err = {
                Enter-ExtSession {
                    $connInfo = [System.Management.Automation.Runspaces.NamedPipeConnectionInfo]::new($process.Id)
                    $connInfo.OpenTimeout = 1000
                    [RunspaceFactory]::CreateRunspace($connInfo)
                }
            } | Should-Throw
        }
        finally {
            $process | Stop-Process -Force -ErrorAction SilentlyContinue
        }

        $err.FullyQualifiedErrorId | Should-Be 'ExtSessionSetupFailed,RemoteWrench.Commands.EnterExtSession'
        [string]$err | Should-BeLikeString 'Failed to open the remote session: *'
    }

    It "Fails when the session factory outputs a closed session" {
        # Disposing a runspace that was never opened closes it, it doesn't
        # need a connection.
        $closed = [RunspaceFactory]::CreateRunspace(
            [System.Management.Automation.Runspaces.NamedPipeConnectionInfo]::new($PID))
        $closed.Dispose()

        $err = { Enter-ExtSession { $closed } } | Should-Throw

        $err.FullyQualifiedErrorId | Should-Be 'ExtSessionSetupFailed,RemoteWrench.Commands.EnterExtSession'
        [string]$err | Should-Be 'The remote session is Closed, it must be open.'
    }

    It "Fails when the session factory throws" {
        { Enter-ExtSession { throw 'factory failure' } } |
            Should-Throw -ExceptionMessage 'The -SessionFactory scriptblock failed: factory failure*'
    }

    It "Writes an error for an invalid function" {
        try {
            Enter-ExtSession { } -Function 1 -ErrorAction SilentlyContinue -ErrorVariable err
        }
        catch {
            # Fails on the factory output after the -Function error.
            $_.FullyQualifiedErrorId | Should-Be 'InvalidSessionFactoryOutput,RemoteWrench.Commands.EnterExtSession'
        }

        $err[0].FullyQualifiedErrorId | Should-Be 'InvalidExtFunction,RemoteWrench.Commands.EnterExtSession'
        [string]$err[0] | Should-BeLikeString '-Function must be a definition from New-ExtFunction or New-ExtCallback*System.Int32.'
    }

    It "Writes an error when -Function is the name of <Description>" -TestCases @(
        @{ Description = 'a missing command'; Name = 'Get-ExtTestMissing'; Expected = "No function named 'Get-ExtTestMissing' was found, -Function must be the name of a function or an alias to one." }
        @{ Description = 'a cmdlet'; Name = 'Get-Item'; Expected = "'Get-Item' is a Cmdlet, -Function must be the name of a function or an alias to one." }
        @{ Description = 'an alias to a cmdlet'; Name = 'gi'; Expected = "'gi' is an alias to 'Get-Item' which is a Cmdlet, -Function must be the name of a function or an alias to one." }
        @{ Description = 'an alias to a missing command'; Name = 'ExtTestMissingAlias'; Expected = "'ExtTestMissingAlias' is an alias to 'Get-ExtTestMissing' which was not found*" }
        @{ Description = 'an alias to a function with a dynamicparam block'; Name = 'ExtTestDynamicAlias'; Expected = "The function 'Get-ExtTestDynamic' of alias 'ExtTestDynamicAlias' has a dynamicparam block*" }
    ) {
        param ($Name, $Expected)

        Set-Alias -Name ExtTestMissingAlias -Value Get-ExtTestMissing
        Set-Alias -Name ExtTestDynamicAlias -Value Get-ExtTestDynamic
        Function Get-ExtTestDynamic { [CmdletBinding()] param () dynamicparam { } end { } }
        try {
            Enter-ExtSession { } -Function $Name -ErrorAction SilentlyContinue -ErrorVariable err
        }
        catch {
            $_.FullyQualifiedErrorId | Should-Be 'InvalidSessionFactoryOutput,RemoteWrench.Commands.EnterExtSession'
        }

        $err[0].FullyQualifiedErrorId | Should-Be 'InvalidExtFunction,RemoteWrench.Commands.EnterExtSession'
        [string]$err[0] | Should-BeLikeString $Expected
    }

    It "Enters the session and closes it on exit" {
        # Entering pushes the runspace on the host, run it in a child process
        # reading commands from stdin like an interactive prompt.
        $target = Start-ExtTarget
        try {
            $modulePath = [Path]::Combine((Get-Module -Name RemoteWrench).ModuleBase, 'RemoteWrench.psd1')
            $commands = @(
                "Import-Module -Name '$modulePath'"
                'Function Get-LocalFunction { param ($Value) "local function $Value $PID" }'
                'Function Get-ByName { "by name $PID" }'
                'Function Get-AliasTarget { "alias target $PID" }'
                'Set-Alias -Name Get-ByAlias -Value Get-AliasTarget'
                '$functions = @(New-ExtCallback Get-ClientPid { $PID }; New-ExtCallback Get-ClientFailure { throw ''client failure'' }; Get-Command Get-LocalFunction; ''Get-ByName''; ''Get-ByAlias'')'
                '"client $PID"'
                "Enter-ExtSession { `$connInfo = [System.Management.Automation.Runspaces.NamedPipeConnectionInfo]::new($($target.Id)); `$connInfo.OpenTimeout = 30000; `$global:ExtTestRunspace = [RunspaceFactory]::CreateRunspace(`$connInfo, `$Host, [System.Management.Automation.Runspaces.TypeTable]::LoadDefaultTypeFiles()); `$global:ExtTestRunspace } -Function `$functions"
                '"remote $PID"'
                '"callback $(Get-ClientPid)"'
                'Get-LocalFunction foo'
                'Get-ByName'
                'Get-ByAlias'
                'Get-ClientFailure; "after failure"'
                '"target defined $([bool](Get-Command Get-AliasTarget -ErrorAction SilentlyContinue))"'
                'Exit-PSSession'
                # Windows PowerShell runs this locally after exiting, PowerShell
                # tries to run it in the closed session and says it's closed.
                '"state $PID $($global:ExtTestRunspace.RunspaceStateInfo.State)"'
            ) -join "`n"

            $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            # Windows PowerShell makes each stderr line of a native command an
            # error record, which would throw with the tests' Stop
            # preference. The child writes the callback failure to stderr.
            $out = & {
                $ErrorActionPreference = 'Continue'
                $commands | & $exe -NoProfile -NonInteractive -Command - 2>&1 | ForEach-Object ToString
            }
        }
        finally {
            $target | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        $outText = $out -join "`n"

        # The host can write escape sequences before the output.
        $clientPid = $out | Where-Object { $_ -match 'client (\d+)$' } | ForEach-Object { $Matches[1] }
        $clientPid | Should-NotBeNull -Because $outText
        $outText | Should-BeLikeString "*remote $($target.Id)*"
        $outText | Should-BeLikeString "*callback $clientPid*"
        $outText | Should-BeLikeString "*local function foo $($target.Id)*"
        $outText | Should-BeLikeString "*by name $($target.Id)*"
        # An alias is defined with its own name, not the function it points
        # to.
        $outText | Should-BeLikeString "*alias target $($target.Id)*"
        $outText | Should-BeLikeString "*target defined False*"
        # A failed callback ends its statement, the next one still runs. The
        # error is written to stderr so it isn't in order with the output.
        $outText | Should-BeLikeString "*Callback 'Get-ClientFailure' failed on the client: client failure*"
        $outText | Should-BeLikeString "*after failure*"
        $outText | Should-MatchString "state $clientPid Closed|the session in which it was intended to run was either closed or broken"
    }
}

Describe "Enter-ExtSession functions" {
    BeforeAll {
        $target = Start-ExtTarget
        $env:EXT_TEST_ENV = 'env value'
        $extTestValue = 'using value'
        $extTestObject = @{ Member = 'member value'; List = @(1, 2, 3) }
        Function Get-ExtTestInline([string]$Name, [int]$Count = 2) { "inline $Name $Count $using:extTestValue" }
        Filter Get-ExtTestFilter([int]$Add) { $_ + $Add }
        $functions = @(
            New-ExtFunction Get-RemoteFromFunction ${function:Get-ExtTestInline}
            New-ExtFunction Get-RemoteFilter ${function:Get-ExtTestFilter}
            New-ExtFunction Get-RemoteThing {
                param ($Name)
                "$Name $using:extTestValue $($using:extTestObject.Member) $($using:extTestObject.List[1])"
            }
            New-ExtFunction Get-RemoteAdvanced {
                [CmdletBinding()]
                param ([Parameter(Mandatory)][string]$Name)
                "advanced $Name $using:extTestValue"
            }
            New-ExtFunction Get-RemotePipeline {
                [CmdletBinding()]
                param ([Parameter(ValueFromPipeline)]$Item, [string]$Prefix = 'remote')
                begin { "$Prefix begin" }
                process { "$Prefix $Item" }
                end { "$Prefix end" }
            }
            New-ExtFunction Get-RemoteInput { "input $(@($input) -join ',')" }
            New-ExtFunction Get-RemoteParameterOnly {
                param ([Parameter(Mandatory)][string]$Name)
                "parameter only $Name"
            }
            New-ExtFunction Get-RemoteOutputType {
                [OutputType([string])]
                param ($Name)
                "output type $Name"
            }
            New-ExtFunction Get-RemoteUsingTwice {
                "$using:extTestValue $using:extTestValue $using:env:EXT_TEST_ENV"
            }
            New-ExtFunction Invoke-MissingCallback {
                # Calls the proxy of the remote module for a callback the
                # client doesn't have, like anything in the session could.
                [CmdletBinding()]
                param ()

                & (Get-Module -Name RemoteWrench.Ext) {
                    param ($Cmdlet)

                    $channel = Invoke-ExtProxyBegin -Name Get-Missing -BoundParameters @{} -ExpectingInput $false -Cmdlet $Cmdlet
                    Invoke-ExtProxyEnd -Channel $channel -Cmdlet $Cmdlet
                } $PSCmdlet
            }
            New-ExtFunction Get-RemoteError {
                [CmdletBinding()]
                param ([switch]$Terminating)

                $err = [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new('server error'), 'ServerError', 'NotSpecified', $null)
                if ($Terminating) {
                    $PSCmdlet.ThrowTerminatingError($err)
                }
                $PSCmdlet.WriteError($err)
            }
            New-ExtFunction Get-RemoteCallback { Invoke-ExtCallback }
            New-ExtCallback Get-ClientValue {
                param ($Positional, $Named, [switch]$Switch)
                "client $Positional $Named $Switch $($args -join ',')"
                $ExtCallbackContext.Name
            }
            New-ExtCallback Get-ClientVariables {
                process {
                    # Only the context, not the variables of the invoker.
                    @(Get-Variable -Name __Ext* -ErrorAction SilentlyContinue).Count
                    $null -ne $ExtCallbackContext
                }
            }
            New-ExtCallback Get-ClientPipeline {
                param ($Prefix = 'client')
                begin { "$Prefix begin" }
                process { "$Prefix $_" }
                end { "$Prefix end" }
            }
            New-ExtCallback Get-ClientAdvanced {
                [CmdletBinding()]
                param ([Parameter(Mandatory)][string]$Name)
                "client $Name"
            }
            New-ExtCallback Get-ClientError {
                # The client script runs in this runspace, the tests set this
                # to Stop.
                $ErrorActionPreference = 'Continue'
                'before'
                Write-Error 'client error'
                'after'
            } -ServerScript {
                Invoke-ExtCallback | ForEach-Object { "server $_" }
            }
            New-ExtCallback Get-ClientFailure { 'partial'; throw 'client failure' }
            New-ExtCallback Get-ClientFailureServer { throw 'client failure' } -ServerScript {
                Invoke-ExtCallback
                'not reached'
            }
            New-ExtCallback Get-ClientBytes {
                param ($Bytes)
                process {
                    if ($null -ne $_) {
                        $Bytes = $_
                    }
                    , ([byte[]]($Bytes | ForEach-Object { $_ + 1 }))
                }
            } -ServerScript {
                $byArgument = Invoke-ExtCallback -Bytes ([byte[]](1, 2, 3))
                $byPipeline = , [byte[]](4, 5) | Invoke-ExtCallback
                "$($byArgument.GetType().Name) $($byArgument -join ',') $using:extTestValue"
                "$($byPipeline.GetType().Name) $($byPipeline -join ',')"
            }
            New-ExtCallback Measure-Client -ClientScript {
                [CmdletBinding()]
                param ([Parameter(Mandatory)][string]$Label, [Parameter(ValueFromPipeline)][int]$Item)
                begin { $sum = 0 }
                process { $sum += $Item }
                end { "$Label $sum" }
            } -ServerScript {
                param ([int]$Count)
                1..$Count | Invoke-ExtCallback -Label "sum $using:extTestValue"
            }
            New-ExtCallback Get-ClientStream {
                process { "out $_" }
            } -ServerScript {
                # Each input waits so the output of the earlier ones arrives
                # while the input is still being sent.
                $log = [System.Collections.Generic.List[string]]::new()
                1..3 | ForEach-Object {
                    $log.Add("in $_")
                    $_
                    Start-Sleep -Milliseconds 300
                } | Invoke-ExtCallback | ForEach-Object { $log.Add($_) }
                $log
            }
            New-ExtCallback Get-ClientSpanning {
                process { "client $_" }
            } -ServerScript {
                [CmdletBinding()]
                param ([Parameter(ValueFromPipeline)]$Item)
                begin {
                    $pipeline = { Invoke-ExtCallback }.GetSteppablePipeline()
                    $pipeline.Begin($PSCmdlet)
                }
                process { $pipeline.Process($Item) }
                end { $pipeline.End() }
            }
            New-ExtCallback Wait-ClientStop {
                # Stopping the command is how Ctrl+C stops it. The client
                # script runs on the thread of the test that would otherwise
                # stop it.
                $global:ExtTestPipeline.StopAsync()
                $global:ExtTestClosed = $ExtCallbackContext.CancellationToken.WaitHandle.WaitOne(10000)
            }
            New-ExtCallback Wait-ClientStopInput {
                process {
                    $global:ExtTestPipeline.StopAsync()
                    $global:ExtTestClosed = $ExtCallbackContext.CancellationToken.WaitHandle.WaitOne(10000)
                }
            }
        )

        $runspace = New-ExtTargetRunspace -Process $target
        Initialize-ExtTestSession -Runspace $runspace -Function $functions -AckTimeoutMs 2000
    }

    AfterAll {
        $env:EXT_TEST_ENV = $null
        if ($runspace) {
            $runspace.Dispose()
        }
        if ($target) {
            $target | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        $global:ExtTestClosed = $null
        $global:ExtTestPipeline = $null
    }

    It "Runs a function with using values" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-RemoteThing -Name foo'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('foo using value member value 2')
    }

    It "Keeps a param block that is advanced through a Parameter attribute" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-RemoteParameterOnly -Name foo; (Get-Command Get-RemoteParameterOnly).Parameters.Keys -like "__Ext*"'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('parameter only foo')
    }

    It "Keeps the attributes of a param block that isn't advanced" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-RemoteOutputType foo; (Get-Command Get-RemoteOutputType).OutputType.Name'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('output type foo', 'System.String')
    }

    It "Passes a using value used twice and one from a drive" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-RemoteUsingTwice'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('using value using value env value')
    }

    It "Runs a function from a function's scriptblock" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-RemoteFromFunction foo; Get-RemoteFromFunction -Name bar -Count 3'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('inline foo 2 using value', 'inline bar 3 using value')
    }

    It "Runs a filter for each pipeline input" {
        $actual = Invoke-ExtTestCommand $runspace '1, 2 | Get-RemoteFilter -Add 10'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @(11, 12)
    }

    It "Keeps the param block of an advanced function" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-RemoteAdvanced -Name foo; (Get-Command Get-RemoteAdvanced).CmdletBinding'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('advanced foo using value', $true)
    }

    It "Passes pipeline input to a function" {
        $actual = Invoke-ExtTestCommand $runspace '1, 2 | Get-RemotePipeline -Prefix p; Get-RemotePipeline -Item 3'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('p begin', 'p 1', 'p 2', 'p end', 'remote begin', 'remote 3', 'remote end')
    }

    It "Passes pipeline input to a function that isn't advanced as `$input" {
        $actual = Invoke-ExtTestCommand $runspace '1, 2 | Get-RemoteInput'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('input 1,2')
    }

    It "Hides the parameters added to a function that isn't advanced" {
        $actual = Invoke-ExtTestCommand $runspace '(TabExpansion2 -inputScript "Get-ClientValue -" -cursorColumn 17).CompletionMatches.CompletionText'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-ContainCollection '-Positional'
        $actual.Output | Should-ContainCollection '-Switch'
        $actual.Output | Should-NotContainCollection '-__ExtInputObject'
        $actual.Output | Should-NotContainCollection '-__ExtArgumentList'
    }

    It "Writes a function's <Kind> error with its name" -TestCases @(
        @{ Kind = 'non-terminating'; Command = 'Get-RemoteError' }
        @{ Kind = 'terminating'; Command = 'Get-RemoteError -Terminating' }
    ) {
        param ($Command)

        $actual = Invoke-ExtTestCommand $runspace $Command

        $actual.Errors | Should-BeCollection @('server error')
        # A remote error keeps the command in these, its label when shown.
        $actual.ErrorRecords[0].CategoryInfo.Activity | Should-Be Get-RemoteError
        $actual.ErrorRecords[0].FullyQualifiedErrorId | Should-Be 'ServerError,Get-RemoteError'
    }

    It "Passes the arguments of a callback without a server script" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-ClientValue pos -Named named -Switch extra1 extra2'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('client pos named True extra1,extra2', 'Get-ClientValue')
    }

    It "Only gives the client script the context variable" {
        $actual = Invoke-ExtTestCommand $runspace "'a' | Get-ClientVariables"

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @(0, $true)
    }

    It "Passes pipeline input to a callback without a server script" {
        $actual = Invoke-ExtTestCommand $runspace "'a', 'b' | Get-ClientPipeline -Prefix p; Get-ClientPipeline"

        $actual.Errors | Should-BeCollection @()
        # Without input the process block runs once, like it does locally.
        $actual.Output | Should-BeCollection @('p begin', 'p a', 'p b', 'p end', 'client begin', 'client ', 'client end')
    }

    It "Passes every pipeline input in order" {
        # The server's messages can be handled out of order on the client, it
        # puts them back in order.
        $actual = Invoke-ExtTestCommand $runspace '1..200 | Get-ClientPipeline -Prefix p'

        $actual.Errors | Should-BeCollection @()
        $expected = @('p begin'; 1..200 | ForEach-Object { "p $_" }; 'p end')
        $actual.Output | Should-BeCollection $expected
    }

    It "Fails to pipe to an advanced client script without a pipeline parameter" {
        $actual = Invoke-ExtTestCommand $runspace "'a' | Get-ClientAdvanced -Name foo"

        $actual.Errors | Should-BeCollection -Count 1
        $actual.Errors[0] | Should-BeLikeString '*The input object cannot be bound to any parameters for the command*'
    }

    It "Uses the client script's parameters for Invoke-ExtCallback" {
        $actual = Invoke-ExtTestCommand $runspace 'Measure-Client -Count 4'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('sum using value 10')
    }

    It "Outputs the client script's output while it still sends input" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-ClientStream'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection -Count 6
        [Array]::IndexOf($actual.Output, 'out 1') | Should-BeLessThan ([Array]::IndexOf($actual.Output, 'in 3'))
    }

    It "Spans the blocks of a server script with a steppable pipeline" {
        $actual = Invoke-ExtTestCommand $runspace '1..3 | Get-ClientSpanning'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('client 1', 'client 2', 'client 3')
    }

    It "Writes the client errors" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-ClientError'

        $actual.Output | Should-BeCollection @('server before', 'server after')
        $actual.Errors | Should-BeCollection @("Callback 'Get-ClientError' error on the client: client error")
    }

    It "Fails when the client script fails without a server script" {
        # The entered session test checks the statement after it still runs,
        # a command run like this test does fails as a whole.
        $actual = Invoke-ExtTestCommand $runspace 'Get-ClientFailure'

        $actual.Output | Should-BeCollection @('partial')
        $actual.Errors | Should-BeCollection -Count 1
        $actual.Errors[0] | Should-BeLikeString "Callback 'Get-ClientFailure' failed on the client: client failure*throw 'client failure'*"
    }

    It "Fails when the client script fails with a server script" {
        $actual = Invoke-ExtTestCommand $runspace 'try { Get-ClientFailureServer } catch { "caught $_" }'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection -Count 1
        $actual.Output[0] | Should-BeLikeString "caught Callback 'Get-ClientFailureServer' failed on the client: client failure*"
    }

    It "Sends a byte array as one object" {
        $actual = Invoke-ExtTestCommand $runspace 'Get-ClientBytes'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('Byte[] 2,3,4 using value', 'Byte[] 5,6')
    }

    It "Keeps a callback open while it waits longer than the client checks on it" {
        # The client asks the server every second whether the command that
        # called a callback was stopped, it must not close one that wasn't.
        $actual = Invoke-ExtTestCommand $runspace '& { 1; Start-Sleep -Milliseconds 2500; 2 } | Get-ClientPipeline -Prefix p'

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection @('p begin', 'p 1', 'p 2', 'p end')
    }

    It "Fails a callback the client doesn't have" {
        $actual = Invoke-ExtTestCommand $runspace 'Invoke-MissingCallback'

        $actual.Errors | Should-BeCollection @("Callback 'Get-Missing' failed on the client: The client has no callback named 'Get-Missing'.")
    }

    It "Stops the client script when the command is stopped while it runs" {
        $actual = Invoke-ExtTestCommand $runspace 'Wait-ClientStop' -PipelineName ExtTestPipeline

        $actual.State | Should-Be Stopped
        $global:ExtTestClosed | Should-BeTrue
    }

    It "Stops the client script when the command is stopped while it waits for input" {
        # The command before the callback runs when it is stopped, nothing on
        # the server can tell the client. It finds out by asking.
        $actual = Invoke-ExtTestCommand $runspace '& { 1; Start-Sleep -Seconds 30 } | Wait-ClientStopInput' -PipelineName ExtTestPipeline

        $actual.State | Should-Be Stopped
        $global:ExtTestClosed | Should-BeTrue
    }

    It "Fails when Invoke-ExtCallback is used <Description>" -TestCases @(
        @{ Description = 'outside a callback'; Command = 'Invoke-ExtCallback' }
        @{ Description = 'in a function'; Command = 'Get-RemoteCallback' }
    ) {
        param ($Command)

        $actual = Invoke-ExtTestCommand $runspace $Command

        $actual.Errors | Should-BeCollection @('Invoke-ExtCallback can only be used in the server script of a callback defined with New-ExtCallback.')
    }

    It "Fails when the client can't respond" {
        # A nested pipeline can only run in a command started like the
        # interactive prompt does, not through the PowerShell API.
        $ps = [PowerShell]::Create()
        try {
            $ps.Runspace = $runspace
            $null = $ps.AddScript('Get-ClientValue')
            $ar = $ps.BeginInvoke()
            while (-not $ar.IsCompleted) {
                Start-Sleep -Milliseconds 10
            }
            $err = $null
            try {
                $null = $ps.EndInvoke($ar)
            }
            catch {
                $err = $_
            }
            if (-not $err) {
                $err = $ps.Streams.Error[0]
            }
        }
        finally {
            $ps.Dispose()
        }

        [string]$err | Should-BeLikeString "*The client did not respond to callback 'Get-ClientValue' within 2 seconds. Callbacks only work when run from the prompt of a session entered with Enter-ExtSession*"
    }

    It "Removes the events it receives" {
        $null = Invoke-ExtTestCommand $runspace "'a', 'b' | Get-ClientPipeline"

        $runspace.Events.ReceivedEvents.Count | Should-Be 0
    }
}
