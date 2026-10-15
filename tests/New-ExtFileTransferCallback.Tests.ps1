using module ../output/RemoteWrench
using namespace System.IO

BeforeAll { . ([Path]::Combine($PSScriptRoot, 'common.ps1')) }

Describe "New-ExtFileTransferCallback" {
    BeforeAll {
        $clientPath = [Path]::Combine($TestDrive, 'client')
        $serverPath = [Path]::Combine($TestDrive, 'server')
        $null = New-Item -Path $clientPath, $serverPath -ItemType Directory

        # Spans several 64KB chunks, half of it compresses.
        $largeBytes = [byte[]]::new(200KB)
        $random = [byte[]]::new(100KB)
        [Random]::new(1234).NextBytes($random)
        [Array]::Copy($random, $largeBytes, $random.Length)

        $target = Start-ExtTarget
        $runspace = New-ExtTargetRunspace -Process $target
        $functions = New-ExtFileTransferCallback -ClientPath $clientPath
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
        Get-ChildItem -LiteralPath $clientPath, $serverPath | Remove-Item -Recurse -Force
    }

    It "Creates the send and receive callbacks" {
        $actual = New-ExtFileTransferCallback -ClientPath $clientPath -SendName Copy-ToClient -ReceiveName Copy-FromClient

        $actual | Should-BeCollection -Count 2
        $actual[0] | Should-HaveType ([RemoteWrench.Ext.ExtSendFileCallback])
        $actual[0].Name | Should-Be Copy-ToClient
        $actual[0].ClientPath | Should-Be $clientPath
        $actual[1] | Should-HaveType ([RemoteWrench.Ext.ExtReceiveFileCallback])
        $actual[1].Name | Should-Be Copy-FromClient
    }

    It "Defaults the client path to the current location" {
        Push-Location -LiteralPath $clientPath
        try {
            $actual = New-ExtFileTransferCallback
        }
        finally {
            Pop-Location
        }

        $actual[0].ClientPath | Should-Be $clientPath
    }

    It "Fails when the client path doesn't exist" {
        $missing = [Path]::Combine($TestDrive, 'missing')

        { New-ExtFileTransferCallback -ClientPath $missing } |
            Should-Throw -ExceptionMessage "The client path '$missing' is not a directory that exists."
    }

    It "Sends files to the client with <Compression> compression" -TestCases @(
        @{ Compression = 'Deflate' }
        @{ Compression = 'None' }
    ) {
        param ($Compression)

        [File]::WriteAllBytes([Path]::Combine($serverPath, 'large.bin'), $largeBytes)
        [File]::WriteAllBytes([Path]::Combine($serverPath, 'empty.bin'), [byte[]]@())

        $actual = Invoke-ExtTestCommand $runspace "Send-ClientFile '$serverPath/*.bin' -Compression $Compression"

        $actual.Errors | Should-BeCollection @()
        $actual.Output | Should-BeCollection -Count 2
        $actual.Output | Sort-Object Length | ForEach-Object Length | Should-BeCollection @(0, 200KB)
        (Get-FileHash -LiteralPath ([Path]::Combine($clientPath, 'large.bin'))).Hash |
            Should-Be (Get-FileHash -LiteralPath ([Path]::Combine($serverPath, 'large.bin'))).Hash
        Test-Path -LiteralPath ([Path]::Combine($clientPath, 'empty.bin')) | Should-BeTrue
    }

    It "Sends a file to a client path" {
        $null = New-Item -Path ([Path]::Combine($clientPath, 'sub')) -ItemType Directory
        Set-Content -LiteralPath ([Path]::Combine($serverPath, 'a.txt')) -Value a

        $actual = Invoke-ExtTestCommand $runspace "Get-Item '$serverPath/a.txt' | Send-ClientFile -Destination sub; Send-ClientFile '$serverPath/a.txt' renamed.txt"

        $actual.Errors | Should-BeCollection @()
        $actual.Output.Destination | Should-BeCollection @(
            [Path]::Combine($clientPath, 'sub', 'a.txt')
            [Path]::Combine($clientPath, 'renamed.txt')
        )
    }

    It "Doesn't overwrite a client file without -Force" {
        Set-Content -LiteralPath ([Path]::Combine($serverPath, 'a.txt')) -Value new
        Set-Content -LiteralPath ([Path]::Combine($clientPath, 'a.txt')) -Value old

        $actual = Invoke-ExtTestCommand $runspace "Send-ClientFile '$serverPath/a.txt'"

        $actual.Output | Should-BeCollection @()
        $actual.Errors | Should-BeCollection -Count 1
        $actual.Errors[0] | Should-BeLikeString "*error on the client: Failed to copy '*a.txt': The client file '*a.txt' already exists, use -Force to overwrite it."
        Get-Content -LiteralPath ([Path]::Combine($clientPath, 'a.txt')) | Should-Be old

        $actual = Invoke-ExtTestCommand $runspace "Send-ClientFile '$serverPath/a.txt' -Force"

        $actual.Errors | Should-BeCollection @()
        Get-Content -LiteralPath ([Path]::Combine($clientPath, 'a.txt')) | Should-Be new
    }

    It "Fails to send outside of the client path" {
        Set-Content -LiteralPath ([Path]::Combine($serverPath, 'a.txt')) -Value a

        $actual = Invoke-ExtTestCommand $runspace "Send-ClientFile '$serverPath/a.txt' ../escape.txt"

        $actual.Errors | Should-BeCollection -Count 1
        $actual.Errors[0] | Should-BeLikeString "*'../escape.txt' is outside of the client path*"
        Test-Path -LiteralPath ([Path]::Combine($TestDrive, 'escape.txt')) | Should-BeFalse
    }

    It "Writes an error for a directory" {
        $actual = Invoke-ExtTestCommand $runspace "Send-ClientFile '$serverPath'"

        $actual.Errors | Should-BeCollection @("'$serverPath' is a directory, only files can be copied.")
    }

    It "Receives files from the client with <Compression> compression" -TestCases @(
        @{ Compression = 'Deflate' }
        @{ Compression = 'None' }
    ) {
        param ($Compression)

        [File]::WriteAllBytes([Path]::Combine($clientPath, 'large.bin'), $largeBytes)
        [File]::WriteAllBytes([Path]::Combine($clientPath, 'empty.bin'), [byte[]]@())

        $actual = Invoke-ExtTestCommand $runspace "Receive-ClientFile large.bin, empty.bin -Destination '$serverPath' -Compression $Compression"

        $actual.Errors | Should-BeCollection @()
        $actual.Output.Name | Should-BeCollection @('large.bin', 'empty.bin')
        (Get-FileHash -LiteralPath ([Path]::Combine($serverPath, 'large.bin'))).Hash |
            Should-Be (Get-FileHash -LiteralPath ([Path]::Combine($clientPath, 'large.bin'))).Hash
        (Get-Item -LiteralPath ([Path]::Combine($serverPath, 'empty.bin'))).Length | Should-Be 0
    }

    It "Receives a file to a remote file path" {
        Set-Content -LiteralPath ([Path]::Combine($clientPath, 'a.txt')) -Value a

        $actual = Invoke-ExtTestCommand $runspace "Receive-ClientFile a.txt '$serverPath/renamed.txt'"

        $actual.Errors | Should-BeCollection @()
        $actual.Output.Name | Should-BeCollection @('renamed.txt')
    }

    It "Doesn't overwrite a remote file without -Force" {
        Set-Content -LiteralPath ([Path]::Combine($clientPath, 'a.txt')) -Value new
        Set-Content -LiteralPath ([Path]::Combine($serverPath, 'a.txt')) -Value old

        $actual = Invoke-ExtTestCommand $runspace "Receive-ClientFile a.txt '$serverPath'"

        $actual.Output | Should-BeCollection @()
        $actual.Errors | Should-BeCollection -Count 1
        $actual.Errors[0] | Should-BeLikeString "Failed to copy '*a.txt': The file '*a.txt' already exists, use -Force to overwrite it."
        Get-Content -LiteralPath ([Path]::Combine($serverPath, 'a.txt')) | Should-Be old

        $actual = Invoke-ExtTestCommand $runspace "Receive-ClientFile a.txt '$serverPath' -Force"

        $actual.Errors | Should-BeCollection @()
        Get-Content -LiteralPath ([Path]::Combine($serverPath, 'a.txt')) | Should-Be new
    }

    It "Writes an error for <Description>" -TestCases @(
        @{ Description = 'a path outside of the client path'; Path = '../escape.txt'; Expected = "*'../escape.txt' is outside of the client path*" }
        @{ Description = 'a missing file'; Path = 'missing.txt'; Expected = "*The client file 'missing.txt' does not exist." }
        @{ Description = 'a directory'; Path = '.'; Expected = "*The client path '.' is a directory, only files can be copied." }
    ) {
        param ($Path, $Expected)

        $actual = Invoke-ExtTestCommand $runspace "Receive-ClientFile '$Path' '$serverPath'"

        $actual.Output | Should-BeCollection @()
        $actual.Errors | Should-BeCollection -Count 1
        $actual.Errors[0] | Should-BeLikeString $Expected
    }
}
