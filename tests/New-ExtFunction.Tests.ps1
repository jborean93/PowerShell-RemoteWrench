using module ../output/RemoteWrench
using namespace System.IO

BeforeAll { . ([Path]::Combine($PSScriptRoot, 'common.ps1')) }

Describe "New-ExtFunction" {
    It "Creates a function definition" {
        $actual = New-ExtFunction Get-Thing { param ($Name) "thing $Name" }

        $actual | Should-HaveType ([RemoteWrench.Ext.ExtFunction])
        $actual.Name | Should-Be Get-Thing
        $actual.Definition | Should-Be ' param ($Name) "thing $Name" '
    }

    It "Fails with an invalid name" {
        { New-ExtFunction 'Get Thing' { } } |
            Should-Throw -ExceptionMessage "'Get Thing' is not a valid function name*"
    }

    It "Creates a function from a function's scriptblock" {
        Function Get-ExtTestInline([string]$Name, [int]$Count = 2) { "inline $Name $Count" }

        $actual = New-ExtFunction Get-Thing ${function:Get-ExtTestInline}

        $actual.Name | Should-Be Get-Thing
        $actual.Definition | Should-BeLikeString 'param(`[string`]$Name, `[int`]$Count = 2)*"inline $Name $Count"*'
    }

    It "Creates a function from a filter" {
        Filter Get-ExtTestFilter([int]$Add) { $_ + $Add }

        $actual = New-ExtFunction Get-Thing ${function:Get-ExtTestFilter}

        # The body runs for each pipeline input.
        $actual.Definition | Should-BeLikeString 'param(`[int`]$Add)*process {*$_ + $Add*}'
    }

    It "Fails with a filter that has begin or process blocks" {
        Filter Get-ExtTestFilterBlocks { begin { 1 } process { $_ } }

        { New-ExtFunction Get-Thing ${function:Get-ExtTestFilterBlocks} } |
            Should-Throw -ExceptionMessage "The script of function 'Get-Thing' is a filter with begin or process blocks*"
    }

    It "Fails with a dynamicparam block" {
        Function Get-ExtTestDynamic { [CmdletBinding()] param () dynamicparam { } end { } }

        { New-ExtFunction Get-Thing ${function:Get-ExtTestDynamic} } |
            Should-Throw -ExceptionMessage "The script of function 'Get-Thing' has a dynamicparam block*"
    }

    It "Fails when a using variable is not set" {
        { New-ExtFunction Get-Thing { $using:extTestMissing; $using:extTestMissing2 } } |
            Should-Throw -ExceptionMessage "*'`$using:extTestMissing', '`$using:extTestMissing2' in the script of function 'Get-Thing' cannot be retrieved*"
    }
}
