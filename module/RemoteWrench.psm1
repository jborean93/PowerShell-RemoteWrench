# Copyright: (c) 2026, Jordan Borean (@jborean93) <jborean93@gmail.com>
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

using namespace System.IO
using namespace System.Management.Automation
using namespace System.Reflection

# Resolve the cmdlet through $ExecutionContext to ensure we don't load a
# shadowed version of Import-Module.
$importModule = $ExecutionContext.InvokeCommand.GetCommand(
    'Microsoft.PowerShell.Core\Import-Module',
    [CommandTypes]::Cmdlet)

$moduleName = [Path]::GetFileNameWithoutExtension($PSCommandPath)

$innerMod = if ($PSVersionTable.PSEdition -eq 'Desktop') {
    # Windows PowerShell has no AssemblyLoadContext, the module assembly is
    # imported directly and its dependencies load in the same context as
    # every other module. Avoiding conflicts with them is best effort.
    $modulePath = [Path]::Combine($PSScriptRoot, 'bin', 'net472', "$moduleName.dll")
    & $importModule -Name $modulePath -ErrorAction Stop -PassThru
}
else {
    $loaderName = "$moduleName.Loader.LoadContext"
    $loaderPath = [Path]::Combine($PSScriptRoot, 'bin', 'net8.0', "$moduleName.Loader.dll")

    $isReload = $true
    $loaderType = $loaderName -as [type]
    if (-not $loaderType) {
        $isReload = $false

        $null = [Assembly]::LoadFrom($loaderPath)
        $loaderType = $loaderName -as [type]
    }
    elseif ($loaderType.Assembly.Location -ne $loaderPath) {
        # Assemblies cannot be unloaded so once a version of this module is loaded
        # in the process it is the only one that can be used.
        $msg = "Cannot import $moduleName from '$PSScriptRoot' as a different copy is already loaded in this process " +
        "from '$($loaderType.Assembly.Location)'. Start a new PowerShell process to use this copy."
        $err = [ErrorRecord]::new(
            [InvalidOperationException]::new($msg),
            'ModuleAlreadyLoadedFromDifferentPath',
            [ErrorCategory]::ResourceExists,
            $PSScriptRoot)
        throw $err
    }

    $mainModule = $loaderType::Initialize($moduleName)
    & $importModule -Assembly $mainModule -PassThru:$isReload
}

if ($innerMod) {
    # The cmdlets of a module imported in this script are not exported from
    # this module unless added here. On pwsh this is only needed on a reload,
    # Import-Module in an assembly will pick up a cached instance and not call
    # the same path to set the nested module's cmdlets to the current module
    # scope.
    # https://github.com/PowerShell/PowerShell/issues/20710
    $addExportedCmdlet = [PSModuleInfo].GetMethod(
        'AddExportedCmdlet',
        [BindingFlags]'Instance, NonPublic')
    $addExportedAlias = [PSModuleInfo].GetMethod(
        'AddExportedAlias',
        [BindingFlags]'Instance, NonPublic')
    foreach ($cmd in $innerMod.ExportedCmdlets.Values) {
        $addExportedCmdlet.Invoke($ExecutionContext.SessionState.Module, @(, $cmd))
    }
    foreach ($alias in $innerMod.ExportedAliases.Values) {
        $addExportedAlias.Invoke($ExecutionContext.SessionState.Module, @(, $alias))
    }
}
