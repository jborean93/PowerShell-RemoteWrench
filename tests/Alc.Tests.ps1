using module ../output/RemoteWrench
using namespace System.IO
using namespace System.Runtime.Loader

BeforeAll { . ([Path]::Combine($PSScriptRoot, 'common.ps1')) }

# Tests for module loading behavior in .NET Core (PowerShell 7+).
Describe "Module loading" -Skip:(-not $IsCoreCLR) {
    BeforeAll {
        $moduleBase = (Get-Module RemoteWrench).ModuleBase

        # Copies the built module to a new folder so a child process can change or import it without touching the
        # module this process loaded. Only one copy of the module can be loaded in a process.
        Function Copy-TestModule {
            param ([string]$Name)

            $destination = [Path]::Combine($TestDrive, $Name, 'RemoteWrench')
            $null = New-Item $destination -ItemType Directory -Force
            Copy-Item -Path ([Path]::Combine($moduleBase, '*')) -Destination $destination -Recurse
            $destination
        }

        # Runs a script in a new pwsh process and returns its output parsed from JSON.
        Function Invoke-ChildPwsh {
            param ([string]$Script)

            $out = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -Command $Script 2>&1
            $LASTEXITCODE | Should-Be 0 -Because ($out -join "`n")
            ($out -join "`n") | ConvertFrom-Json
        }
    }

    It "Loads the module assembly in the RemoteWrench load context" {
        [AssemblyLoadContext]::GetLoadContext([RemoteWrench.Commands.ConvertToPSRPPacket].Assembly).Name |
            Should-Be RemoteWrench
    }

    It "Loads the loader in the default load context" {
        $loader = [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { $_.GetName().Name -eq 'RemoteWrench.Loader' }

        $loader | Should-NotBeNull
        [AssemblyLoadContext]::GetLoadContext($loader) | Should-BeSame ([AssemblyLoadContext]::Default)
    }

    It "Uses the System.Management.Automation of PowerShell" {
        # The module references it without bundling it, so the load context falls back to PowerShell's copy.
        $actual = [RemoteWrench.Commands.ConvertToPSRPPacket].BaseType.Assembly

        $actual | Should-BeSame ([PSObject].Assembly)
        [AssemblyLoadContext]::GetLoadContext($actual) | Should-BeSame ([AssemblyLoadContext]::Default)
    }

    It "Only loads dependencies listed in RemoteWrench.deps.json" {
        # A file next to the module that is not a runtime asset in RemoteWrench.deps.json must not be loaded. The build
        # puts PowerShell's System.Management.Automation.dll there for the coverage instrumenter, this one is not a
        # valid assembly so loading it from the module folder would fail.
        $copy = Copy-TestModule decoy
        [File]::WriteAllText([Path]::Combine($copy, 'bin', 'net8.0', 'System.Management.Automation.dll'), 'not an assembly')

        $actual = Invoke-ChildPwsh @"
`$ErrorActionPreference = 'Stop'
Import-Module '$copy'
`$output = ("<DataAck PSGuid='00000000-0000-0000-0000-000000000000' />" | ConvertTo-PSRPPacket).Type
`$sma = [RemoteWrench.Commands.ConvertToPSRPPacket].BaseType.Assembly
[PSCustomObject]@{
    Output = `$output
    SmaIsPwsh = [object]::ReferenceEquals(`$sma, [System.Management.Automation.PSObject].Assembly)
    SmaLocation = `$sma.Location
} | ConvertTo-Json
"@

        $actual.Output | Should-Be 'DataAck'
        $actual.SmaIsPwsh | Should-BeTrue
        $actual.SmaLocation | Should-NotBeLikeString "$copy*"
    }

    It "Refuses to import a copy from another path in the same process" {
        $first = Copy-TestModule first
        $second = Copy-TestModule second

        $actual = Invoke-ChildPwsh @"
Import-Module '$first'
try {
    Import-Module '$second' -ErrorAction Stop
    `$errorId = `$null
}
catch {
    `$errorId = `$_.FullyQualifiedErrorId
}
[PSCustomObject]@{
    ErrorId = `$errorId
    Loaded = (Get-Module RemoteWrench).ModuleBase
} | ConvertTo-Json
"@

        $actual.ErrorId | Should-BeLikeString 'ModuleAlreadyLoadedFromDifferentPath*'
        $actual.Loaded | Should-BeLikeString "$first*"
    }
}
