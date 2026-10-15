using module ../output/RemoteWrench
using namespace System.IO

BeforeAll { . ([Path]::Combine($PSScriptRoot, 'common.ps1')) }

Describe "New-ExtCallback" {
    It "Creates a callback definition" {
        $actual = New-ExtCallback Get-Thing -ClientScript { 'client' } -ServerScript { Invoke-ExtCallback }

        $actual | Should-HaveType ([RemoteWrench.Ext.ExtScriptCallback])
        $actual.Name | Should-Be Get-Thing
        $actual.ClientScript.ToString() | Should-Be " 'client' "
        $actual.ServerScript | Should-Be ' Invoke-ExtCallback '
    }

    It "Fails with a using variable in the client script" {
        $value = 1
        { New-ExtCallback Get-Thing -ClientScript { $using:value } } |
            Should-Throw -ExceptionMessage "The client script of callback 'Get-Thing' uses '`$using:value' but it runs on the client*"
    }
}
