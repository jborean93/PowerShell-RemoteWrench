<#
.SYNOPSIS
Edits a file in this session with the client's editor.

.DESCRIPTION
Edits a remote file with the editor of the client. The file is copied to the
client, edited there and written back if it changed when the editor exits. A
file that doesn't exist is created when it is saved.

.PARAMETER Path
The file to edit.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory, Position = 0)]
    [string]
    $Path
)

$fullPath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
if ([System.IO.Directory]::Exists($fullPath)) {
    $err = [System.Management.Automation.ErrorRecord]::new(
        [System.IO.IOException]::new("'$fullPath' is a directory, only a file can be edited."),
        'DirectoryNotSupported',
        [System.Management.Automation.ErrorCategory]::InvalidArgument,
        $fullPath)
    $PSCmdlet.ThrowTerminatingError($err)
}

$content = [byte[]]@()
if ([System.IO.File]::Exists($fullPath)) {
    $content = [System.IO.File]::ReadAllBytes($fullPath)
}

# The client outputs the new content if the file was changed and saved.
$newContent = Invoke-ExtCallback -Name ([System.IO.Path]::GetFileName($fullPath)) -Content $content
if ($null -eq $newContent) {
    Write-Host "No changes made to '$fullPath'"
    return
}

[System.IO.File]::WriteAllBytes($fullPath, $newContent)
