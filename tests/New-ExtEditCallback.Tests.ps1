using module ../output/RemoteWrench
using namespace System.IO

BeforeAll { . ([Path]::Combine($PSScriptRoot, 'common.ps1')) }

Describe "New-ExtEditCallback" {
    BeforeAll {
        $serverPath = [Path]::Combine($TestDrive, 'server')
        $null = New-Item -Path $serverPath -ItemType Directory

        # The editors are PowerShell scripts, a real editor needs a person.
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        Function New-TestEditor {
            param ([string]$Name, [string]$Script)

            $scriptPath = [Path]::Combine($TestDrive, "$Name.ps1")
            Set-Content -LiteralPath $scriptPath -Value $Script
            "`"$exe`" -NoProfile -NonInteractive -File `"$scriptPath`""
        }

        $editLog = [Path]::Combine($TestDrive, 'edited-path.txt')
        $editEditor = New-TestEditor edit @"
param (`$Path)
Set-Content -LiteralPath '$editLog' -Value `$Path
[System.IO.File]::AppendAllText(`$Path, 'edited')
"@
        $noopEditor = New-TestEditor noop 'param ($Path)'
        $cancelEditor = New-TestEditor cancel @'
param ($Path)
[System.IO.File]::AppendAllText($Path, 'cancelled')
exit 1
'@

        $target = Start-ExtTarget
        $runspace = New-ExtTargetRunspace -Process $target
        $functions = @(
            New-ExtEditCallback -Editor $editEditor
            New-ExtEditCallback Edit-Noop -Editor $noopEditor
            New-ExtEditCallback Edit-Cancel -Editor $cancelEditor
        )
        Initialize-ExtTestSession -Runspace $runspace -Function $functions
    }

    AfterAll {
        if ($runspace) {
            $runspace.Dispose()
        }
        if ($target) {
            $target | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        Get-ChildItem -LiteralPath $serverPath | Remove-Item -Recurse -Force
        Remove-Item -LiteralPath $editLog -ErrorAction SilentlyContinue
    }

    It "Creates the callback with the editor" {
        $actual = New-ExtEditCallback -Editor $editEditor

        $actual | Should-HaveType ([RemoteWrench.Ext.ExtEditCallback])
        $actual.Name | Should-Be PSEdit
        $actual.EditorPath | Should-Be $exe
        $actual.EditorArguments | Should-BeLikeString '-NoProfile -NonInteractive -File "*edit.ps1"'
    }

    It "Uses `$env:EDITOR without -Editor" {
        $oldVisual = $env:VISUAL
        $oldEditor = $env:EDITOR
        try {
            $env:VISUAL = $null
            $env:EDITOR = $noopEditor
            $actual = New-ExtEditCallback
        }
        finally {
            $env:VISUAL = $oldVisual
            $env:EDITOR = $oldEditor
        }

        $actual.EditorPath | Should-Be $exe
        $actual.EditorArguments | Should-BeLikeString '*noop.ps1"'
    }

    It "Fails when the editor isn't found" {
        { New-ExtEditCallback -Editor 'extTestMissingEditor --wait' } |
            Should-Throw -ExceptionMessage "The editor 'extTestMissingEditor' from 'extTestMissingEditor --wait' could not be found."
    }

    It "Edits a remote file" {
        $file = [Path]::Combine($serverPath, 'config.txt')
        [File]::WriteAllText($file, 'original ')

        $actual = Invoke-ExtTestCommand $runspace "PSEdit '$file'"

        $actual.Errors | Should-BeCollection @()
        [File]::ReadAllText($file) | Should-Be 'original edited'

        # The editor gets a client copy with the same file name.
        $edited = (Get-Content -LiteralPath $editLog).Trim()
        [Path]::GetFileName($edited) | Should-Be 'config.txt'
        $edited | Should-NotBe $file
        Test-Path -LiteralPath $edited | Should-BeFalse
    }

    It "Creates a remote file that doesn't exist" {
        $file = [Path]::Combine($serverPath, 'new.txt')

        $actual = Invoke-ExtTestCommand $runspace "PSEdit '$file'"

        $actual.Errors | Should-BeCollection @()
        [File]::ReadAllText($file) | Should-Be 'edited'
    }

    It "Leaves the file when it is <Description>" -TestCases @(
        @{ Description = 'not changed'; Command = 'Edit-Noop' }
        @{ Description = 'cancelled with a failing exit code'; Command = 'Edit-Cancel' }
    ) {
        param ($Command)

        $file = [Path]::Combine($serverPath, 'config.txt')
        [File]::WriteAllText($file, 'original')

        $actual = Invoke-ExtTestCommand $runspace "$Command '$file'"

        $actual.Errors | Should-BeCollection @()
        [File]::ReadAllText($file) | Should-Be 'original'
    }

    It "Fails to edit a directory" {
        $actual = Invoke-ExtTestCommand $runspace "PSEdit '$serverPath'"

        $actual.Errors | Should-BeCollection @("'$serverPath' is a directory, only a file can be edited.")
    }
}
