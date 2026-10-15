# Copyright: (c) 2026, Jordan Borean (@jborean93) <jborean93@gmail.com>
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

# Run by Enter-ExtSession in the remote session to define the functions from
# New-ExtFunction and New-ExtCallback. The remote session can be Windows
# PowerShell 5.1, keep this compatible with it and ASCII only.
#
# Every function is an advanced function with the param block from the
# client, see ScriptParser.GetParamBlock. A function with a script runs it
# through a steppable pipeline so pipeline input and output stream through
# it. A callback's client script is run through a proxy with the client
# script's param block, it is the function itself for a callback without a
# server script, otherwise it is Invoke-ExtCallback in the server script.
#
# Messages to the client are engine events forwarded to it, the client
# subscribes to them on its runspace. Messages from the client are nested
# pipelines that call Receive-ExtClientInput. A nested pipeline only runs
# between the statements of the pipeline that is currently running, every
# wait in here is a loop with a short sleep so they run promptly.

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]
    $SourceIdentifier,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]]
    $Definitions,

    [Parameter(Mandatory)]
    [int]
    $AckTimeoutMs
)

$null = $ExecutionContext.Events.SubscribeEvent(
    $null,              # source
    $SourceIdentifier,  # eventName
    $SourceIdentifier,  # sourceIdentifier
    $null,              # data
    $null,              # action
    $true,              # supportEvent
    $true)              # forwardEvent

$module = New-Module -Name RemoteWrench.Ext -ArgumentList $SourceIdentifier, $Definitions, $AckTimeoutMs -ScriptBlock {
    param ($SourceIdentifier, $Definitions, $AckTimeoutMs)

    $script:SourceIdentifier = $SourceIdentifier
    $script:AckTimeoutMs = $AckTimeoutMs
    $script:DefinitionTable = @{}
    $script:Channels = @{}

    # How long a wait sleeps before checking again, this is also the delay
    # before a message from the client is processed.
    $script:PollMs = 10

    # How many pipeline input objects a proxy sends ahead of what the client
    # script has read. It keeps a lot of input, like a large file, from being
    # queued in memory. The client says how many it has read every 16.
    $script:InputWindow = 64

    # The parameters added to a param block that isn't advanced, they are
    # never passed on as named parameters.
    $script:ExtParameters = @('__ExtInputObject', '__ExtArgumentList')
    $script:CommonParameters = @(
        [System.Management.Automation.Cmdlet]::CommonParameters
        [System.Management.Automation.Cmdlet]::OptionalCommonParameters
    )

    # Forwarded events can be handled out of order on the client, it uses
    # this to put them back in order.
    $script:Sequence = 0

    Function Send-ExtClientMessage {
        param ([hashtable]$Message)

        $script:Sequence++
        $Message.Seq = $script:Sequence
        $null = $ExecutionContext.Events.GenerateEvent(
            $script:SourceIdentifier,  # sourceIdentifier
            $null,                     # sender
            $null,                     # args
            [PSObject]$Message)        # extraData
    }

    # The Data or Error message whose items are still to be received.
    $script:PendingItems = $null

    Function Receive-ExtClientInput {
        # Called through a nested pipeline from the client for each object of
        # the messages it has queued, in the order they were sent. A message
        # is a hashtable, the items of a Data or Error message are sent as
        # the objects after it so they are serialized as top level objects,
        # like any other remoting output, and not nested in the message.
        param ($InputObject)

        if ($script:PendingItems) {
            $pending = $script:PendingItems
            $pending.Remaining--
            if ($pending.Remaining -le 0) {
                $script:PendingItems = $null
            }

            # The channel is gone if it was closed here before the client
            # knew about it, the item is dropped.
            $channel = $script:Channels[$pending.Id]
            if ($channel) {
                if ($pending.Kind -eq 'Error') {
                    $InputObject = [PSCustomObject]@{
                        PSTypeName = 'RemoteWrench.ExtClientError'
                        Message = $InputObject
                    }
                }
                $channel.Queue.Add($InputObject)
            }
            return
        }

        $msg = $InputObject
        if ($msg.Kind -in 'Data', 'Error') {
            if ($msg.Count -gt 0) {
                $script:PendingItems = @{
                    Id = $msg.Id
                    Kind = $msg.Kind
                    Remaining = $msg.Count
                }
            }
            return
        }

        $channel = $script:Channels[$msg.Id]
        if (-not $channel) {
            return
        }
        if ($msg.Kind -eq 'Ack') {
            $channel.Acked = $true
        }
        elseif ($msg.Kind -eq 'Read') {
            $channel.Read = [long]$msg.Count
        }
        elseif ($msg.Kind -eq 'End') {
            $channel.Failure = $msg.Failure
            $channel.Queue.CompleteAdding()
        }
    }

    Function Get-ExtStoppedChannel {
        # Called through a nested pipeline from the client while it has open
        # channels. Outputs the ids of those whose command was stopped
        # without closing them, which happens when it is stopped while
        # another command in its pipeline runs. No block of the proxy runs
        # after that so the client has to ask.
        param ([string[]]$Id)

        foreach ($channelId in $Id) {
            $channel = $script:Channels[$channelId]
            if (-not $channel) {
                $channelId
            }
            elseif ($channel.Cmdlet.Stopping) {
                $script:Channels.Remove($channelId)
                $channelId
            }
        }
    }

    Function New-ExtErrorRecord {
        param ([string]$Message, [string]$ErrorId, [string]$Category = 'NotSpecified', $TargetObject)

        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new($Message),
            $ErrorId,
            $Category,
            $TargetObject)
    }

    Function Get-ExtNamedArgument {
        # The bound parameters to pass on by name. The parameters added to a
        # param block that isn't advanced are left out, and the common
        # parameters if the script it is passed to isn't advanced.
        param ($BoundParameters, [switch]$NoCommon, [switch]$Serialize)

        $named = @{}
        foreach ($kvp in $BoundParameters.GetEnumerator()) {
            if ($kvp.Key -in $script:ExtParameters -or ($NoCommon -and $kvp.Key -in $script:CommonParameters)) {
                continue
            }

            $value = $kvp.Value
            if ($Serialize -and $value -is [switch]) {
                # A deserialized SwitchParameter is always truthy.
                $value = $value.IsPresent
            }
            $named[$kvp.Key] = $value
        }
        $named
    }

    Function Get-ExtArgumentList {
        param ($BoundParameters)

        if ($BoundParameters.ContainsKey('__ExtArgumentList')) {
            , @($BoundParameters['__ExtArgumentList'])
        }
        else {
            , @()
        }
    }

    Function Close-ExtProxyChannel {
        # Closes the channel if the client hasn't ended it, the client script
        # is stopped.
        param ($Channel)

        if ($Channel -and $script:Channels.ContainsKey($Channel.Id)) {
            $script:Channels.Remove($Channel.Id)
            Send-ExtClientMessage @{
                Kind = 'Close'
                Id = $Channel.Id
            }
        }
    }

    Function Read-ExtProxyOutput {
        # Outputs the client script's output that has arrived, or with -Wait
        # all of it until the client script ends. Its errors are written for
        # the proxy, $Cmdlet is its $PSCmdlet.
        param ($Channel, $Cmdlet, [switch]$Wait)

        $waitMs = 0
        if ($Wait) {
            $waitMs = $script:PollMs
        }

        while (-not $Channel.Queue.IsCompleted) {
            $item = $null
            if ($Channel.Queue.TryTake([ref]$item, $waitMs)) {
                if ($null -ne $item -and $item.PSObject.TypeNames -contains 'RemoteWrench.ExtClientError') {
                    $Cmdlet.WriteError((New-ExtErrorRecord -ErrorId 'ExtCallbackClientError' -TargetObject $Channel.Name `
                        -Message "Callback '$($Channel.Name)' error on the client: $($item.Message)"))
                }
                else {
                    # The unary comma outputs a collection, like a byte array,
                    # as one object.
                    , $item
                }
            }
            elseif (-not $Wait) {
                return
            }
        }

        # The client script has ended.
        $script:Channels.Remove($Channel.Id)
        if ($Channel.Failure) {
            $Cmdlet.ThrowTerminatingError((New-ExtErrorRecord -ErrorId 'ExtCallbackClientFailure' -TargetObject $Channel.Name `
                -Message "Callback '$($Channel.Name)' failed on the client: $($Channel.Failure)"))
        }
    }

    Function Invoke-ExtProxyBegin {
        # The begin block of a proxy, it starts the client script and returns
        # the channel to exchange data with it.
        param ($Name, $BoundParameters, [bool]$ExpectingInput, $Cmdlet)

        $channel = [PSCustomObject]@{
            Id = [Guid]::NewGuid().ToString()
            Name = $Name
            Queue = [System.Collections.Concurrent.BlockingCollection[object]]::new()
            Acked = $false
            Failure = $null
            # The pipeline input objects sent and how many the client script
            # has read.
            Sent = [long]0
            Read = [long]0
            # The proxy's $PSCmdlet, Stopping is set once its command is
            # stopped, see Get-ExtStoppedChannel.
            Cmdlet = $Cmdlet
        }
        $script:Channels[$channel.Id] = $channel

        $ok = $false
        try {
            Send-ExtClientMessage @{
                Kind = 'Open'
                Id = $channel.Id
                Name = $Name
                ArgumentList = Get-ExtArgumentList -BoundParameters $BoundParameters
                Parameter = Get-ExtNamedArgument -BoundParameters $BoundParameters -NoCommon -Serialize
                ExpectingInput = $ExpectingInput
            }

            # The client acknowledges the open as soon as it gets it. It can
            # only reply while the function runs from the interactive prompt
            # of the entered session, anything else would wait here forever.
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $channel.Acked -and -not $channel.Queue.IsAddingCompleted) {
                if ($sw.ElapsedMilliseconds -ge $script:AckTimeoutMs) {
                    $msg = "The client did not respond to callback '$Name' within $($script:AckTimeoutMs / 1000) seconds. " +
                        "Callbacks only work when run from the prompt of a session entered with Enter-ExtSession, " +
                        "not through Invoke-Command, a job, or another runspace."
                    $Cmdlet.ThrowTerminatingError((New-ExtErrorRecord -ErrorId 'ExtCallbackNoResponse' `
                        -Category OperationTimeout -TargetObject $Name -Message $msg))
                }
                Start-Sleep -Milliseconds $script:PollMs
            }
            $ok = $true
        }
        finally {
            if (-not $ok) {
                Close-ExtProxyChannel -Channel $channel
            }
        }

        $channel
    }

    Function Invoke-ExtProxyProcess {
        # The process block of a proxy, it sends the pipeline input to the
        # client script and outputs what it has output so far.
        param ($Channel, $InputObject, [bool]$ExpectingInput, $Cmdlet)

        $ok = $false
        try {
            if ($ExpectingInput -and $script:Channels.ContainsKey($Channel.Id)) {
                # Wait for the client script to read what was sent, writing
                # its output meanwhile. It stops waiting if the client script
                # ends.
                while ($Channel.Sent - $Channel.Read -ge $script:InputWindow -and -not $Channel.Queue.IsAddingCompleted) {
                    Read-ExtProxyOutput -Channel $Channel -Cmdlet $Cmdlet
                    Start-Sleep -Milliseconds $script:PollMs
                }

                if (-not $Channel.Queue.IsAddingCompleted) {
                    Send-ExtClientMessage @{
                        Kind = 'Data'
                        Id = $Channel.Id
                        Items = @(, $InputObject)
                    }
                    $Channel.Sent++
                }
            }
            Read-ExtProxyOutput -Channel $Channel -Cmdlet $Cmdlet
            $ok = $true
        }
        finally {
            # Stopped, or the client script failed.
            if (-not $ok) {
                Close-ExtProxyChannel -Channel $Channel
            }
        }
    }

    Function Invoke-ExtProxyEnd {
        # The end block of a proxy, it tells the client script there is no
        # more input and outputs the rest of its output until it ends.
        param ($Channel, $Cmdlet)

        try {
            if ($script:Channels.ContainsKey($Channel.Id)) {
                Send-ExtClientMessage @{
                    Kind = 'End'
                    Id = $Channel.Id
                }
            }
            Read-ExtProxyOutput -Channel $Channel -Cmdlet $Cmdlet -Wait
        }
        finally {
            Close-ExtProxyChannel -Channel $Channel
        }
    }

    Function New-ExtScriptPipeline {
        # A steppable pipeline that runs the script of a definition with the
        # parameters of the function it was called through.
        param ($Name, $BoundParameters, $CommandOrigin)

        $definition = $script:DefinitionTable[$Name]
        $splat = Get-ExtNamedArgument -BoundParameters $BoundParameters -NoCommon:(-not $definition.ScriptIsAdvanced)
        $arguments = Get-ExtArgumentList -BoundParameters $BoundParameters

        # The -% parameter is how PowerShell passes the $using: values to a
        # script, the same as Invoke-Command does.
        if ($definition.UsingValues.Count) {
            $splat['-%'] = $definition.UsingValues
        }

        # The script runs in a new module so it can't see or clobber the
        # variables in here and nothing carries over to the next call. It is
        # a function there with the name of the function it was called
        # through so its errors are shown with that name. The server script
        # of a callback gets Invoke-ExtCallback there too, the proxy for its
        # client script. The module's script uses $args so it defines no
        # variables the server script could see.
        # -Verbose on the function would show New-Module exporting and
        # importing the functions.
        $scope = New-Module -Verbose:$false -ArgumentList $Name, $definition.Script, $definition.Proxy -ScriptBlock {
            Set-Item -LiteralPath "function:script:$($args[0])" -Value $ExecutionContext.SessionState.Module.NewBoundScriptBlock($args[1])
            if ($args[2]) {
                Set-Item -LiteralPath function:script:Invoke-ExtCallback -Value $args[2]
            }
        }
        $command = $scope.ExportedFunctions[$Name]

        # A steppable pipeline gets the variables from the scope it is
        # created in, this one.
        $wrapped = { & $command @splat @arguments }
        , $wrapped.GetSteppablePipeline($CommandOrigin)
    }

    Function Invoke-ExtCallback {
        <#
        .SYNOPSIS
        Runs the client script of a callback, only in its server script.
        #>
        [CmdletBinding()]
        param (
            [Parameter(ValueFromPipeline)]
            $InputObject,

            [Parameter(ValueFromRemainingArguments)]
            $ArgumentList
        )

        begin {
            # The server script of a callback has its own Invoke-ExtCallback,
            # this is only found anywhere else.
            $PSCmdlet.ThrowTerminatingError((New-ExtErrorRecord -ErrorId 'NotInExtCallback' -Category InvalidOperation `
                -Message 'Invoke-ExtCallback can only be used in the server script of a callback defined with New-ExtCallback.'))
        }
    }

    Function New-ExtProxy {
        # A function that runs the client script of a callback. The name is
        # checked by the client, it can only be letters, digits, _ and -.
        param ($Name, $ParamBlock)

        $ExecutionContext.SessionState.Module.NewBoundScriptBlock([ScriptBlock]::Create(@"
$ParamBlock
begin {
    `$__extChannel = Invoke-ExtProxyBegin -Name '$Name' -BoundParameters `$PSBoundParameters -ExpectingInput `$MyInvocation.ExpectingInput -Cmdlet `$PSCmdlet
}
process {
    Invoke-ExtProxyProcess -Channel `$__extChannel -InputObject `$_ -ExpectingInput `$MyInvocation.ExpectingInput -Cmdlet `$PSCmdlet
}
end {
    Invoke-ExtProxyEnd -Channel `$__extChannel -Cmdlet `$PSCmdlet
}
"@))
    }

    Function New-ExtScriptFunction {
        # A function that runs the script of a definition.
        param ($Name, $ParamBlock)

        $ExecutionContext.SessionState.Module.NewBoundScriptBlock([ScriptBlock]::Create(@"
$ParamBlock
begin {
    `$__extPipeline = New-ExtScriptPipeline -Name '$Name' -BoundParameters `$PSBoundParameters -CommandOrigin `$MyInvocation.CommandOrigin
    `$__extPipeline.Begin(`$PSCmdlet)
}
process {
    if (`$MyInvocation.ExpectingInput) {
        `$__extPipeline.Process(`$_)
    }
    else {
        `$__extPipeline.Process()
    }
}
end {
    `$__extPipeline.End()
}
"@))
    }

    foreach ($d in $Definitions) {
        $definition = @{
            Name = $d.Name
            Kind = $d.Kind
            Script = $null
            ScriptIsAdvanced = $d.ScriptIsAdvanced
            UsingValues = $d.UsingValues
            Proxy = $null
        }
        $script:DefinitionTable[$d.Name] = $definition

        if ($d.Script) {
            $definition.Script = [ScriptBlock]::Create($d.Script)
            if ($d.Kind -eq 'Callback') {
                $definition.Proxy = New-ExtProxy -Name $d.Name -ParamBlock $d.ClientParamBlock
            }
            $function = New-ExtScriptFunction -Name $d.Name -ParamBlock $d.ParamBlock
        }
        else {
            # A callback without a server script is the proxy itself.
            $function = New-ExtProxy -Name $d.Name -ParamBlock $d.ClientParamBlock
        }

        # script: defines it in this module, without it Set-Item would replace
        # a function with the same name in the global scope.
        Set-Item -LiteralPath "function:script:$($d.Name)" -Value $function
    }

    Export-ModuleMember -Function @(
        'Invoke-ExtCallback'
        $Definitions | ForEach-Object Name
    )
}
$module | Import-Module -Global
