# AGENTS.md

Guidance for AI agents and other automation working in this repository.
Humans should read it too; it is the shortest accurate description of how the
project is built and tested.

## What this project is

RemoteWrench is a cross platform PowerShell 7.4+ and Windows PowerShell 5.1 binary module written in C#.
It currently provides `ConvertTo-PSRPPacket` and `Format-PSRPPacket` to parse
and display the packets of the PowerShell Remoting Protocol (PSRP) OutOfProc
transport.

## Repository layout

| Path | Purpose |
| --- | --- |
| `build.ps1` | Entry point for every build and test action. Wraps InvokeBuild. |
| `manifest.psd1` | Pinned versions of the PowerShell build/test modules (InvokeBuild, Pester, Microsoft.PowerShell.PlatyPS, PSResourceGet, OpenAuthenticode). |
| `global.json` | Pins the .NET SDK (10.0.x) and selects `Microsoft.Testing.Platform` as the `dotnet test` runner. |
| `RemoteWrench.slnx` | Solution file listing the `src/` projects. |
| `src/RemoteWrench/` | The PowerShell module assembly. Cmdlets live in `Commands/`. `OutOfProcPacket.cs` parses the OutOfProc packets and reassembles the PSRP fragments, `Formatting/` decodes the messages (`MessageDecoder.cs`) and renders the `Format-PSRPPacket` views (`Views/`). Targets `net8.0` for PowerShell 7.4+ and `net472` for Windows PowerShell 5.1, compiling against the `System.Management.Automation` reference assembly of each, PowerShell provides it at runtime. |
| `src/RemoteWrench.Loader/` | Tiny `AssemblyLoadContext` used by `module/RemoteWrench.psm1` to isolate the module's dependencies from the host process. It resolves them from `bin/<tfm>/RemoteWrench.deps.json`, see "Dependencies and the load context". `tests/Alc.Tests.ps1` checks what lands in which context. |
| `src/Directory.Build.props` | Shared compiler settings (nullable enabled, unsafe allowed, code style enforced). |
| `src/Directory.Packages.props` | Central package management. All NuGet versions live here; `.csproj` files reference packages without a `Version`. |
| `module/` | The `.psd1` manifest and `.psm1` loader script copied verbatim into the built module. `ModuleVersion` here is the single source of truth for the version. |
| `docs/en-US/RemoteWrench/` | Microsoft.PowerShell.PlatyPS markdown help. Cmdlet pages are compiled to MAML at build time. An `about_*.md` page would be copied as `about_*.help.txt`, only add one for conceptual docs too long for the cmdlet pages. Run `tools/UpdateDocs.ps1` to sync the syntax and parameter metadata. |
| `tests/*.Tests.ps1` | Pester tests that run against the built module. |
| `tests/common.ps1` | Helper functions shared by the Pester files, like building PSRP messages, fragments, and Data packets or reading `tests/data/`. Dot-sourced by every Pester file, it does not import the module. |
| `tests/data/` | OutOfProc logs the PSRP tests share. `large-psrp-packet.txt` is a captured message split across three Data packets. `psrp-session.txt` is a captured `Start-Job` session with every output stream and a stopped job. `psrp-message-types.txt` is captured runspace pool operations, scope and quoting cases, user events and command metadata, plus synthetic `ConnectRunspacePool`, `RunspacePoolInitData` and runspace pool host call messages that cannot be produced over OutOfProc. `psrp-create-pipeline.txt` is captured `CreatePipeline` messages of the `[PowerShell]` API permutations. `psrp-fragments.txt` is the session re-fragmented into 1.4KB fragments packed several to a packet, with a concurrent pipeline and runspace pool messages interleaved. The user and host names in the captures were replaced. |
| `tests/units/<Project>/` | .NET unit test projects (TUnit), none yet. Each directory is discovered and run automatically by the `Test` task. |
| `tools/` | Scripts used by `build.ps1`. `InvokeBuild.ps1` defines the tasks; `common.ps1` holds the `Manifest` class and helpers. `UpdateDocs.ps1` regenerates the markdown help from the built module. `ReplayPSRPLog.ps1` replays an OutOfProc log line by line with a delay, to see how `Format-PSRPPacket` handles a session in progress. |
| `output/` | Git-ignored. Built module, nupkg, downloaded PowerShell versions, cached build modules, and test results all land here. Never commit or hand-edit it. |
| `CHANGELOG.md` | Update under the top (unreleased) heading for any user-visible change. |

## Prerequisites

- .NET SDK 10.0.x (see `global.json`; `rollForward` is `latestFeature`).
- PowerShell 7.4 or newer, or Windows PowerShell 5.1, to run the module. The
  build scripts themselves need PowerShell 7.2. The Windows PowerShell build
  is not covered by the tests or CI yet.
- Network access on first run. The build script downloads the pinned
  PowerShell modules into `output/Modules` via ModuleFast, and `dotnet`
  restores NuGet packages into the usual NuGet cache.
- Global dotnet tools `dotnet-coverage` and `dotnet-reportgenerator-globaltool`
  are installed automatically by the `Test` task if missing.

## Building and testing

```powershell
pwsh -File ./build.ps1 -Configuration Debug|Release -Task Build|Test
```

`-Configuration` defaults to `Debug` and `-Task` defaults to `Build`. `Test`
does not build, run `Build` first. Before calling a change done, run
`-Task Build` followed by `-Task Test` and report the result.

The `Build` task runs `Clean`, `BuildManaged` (`dotnet publish` of
`src/RemoteWrench`), `BuildModule` (copy `module/`), `BuildDocs` (PlatyPS MAML)
and `Package` (produces `output/RemoteWrench.<version>.nupkg`). The built
module is at `output/RemoteWrench/<version>/`.

The `Test` task runs `TestSetup` (coverage settings), `UnitTests` (each
`tests/units/*` project with coverage), `PesterTests` (a separate `pwsh`,
downloaded into `output/` if `-PowerShellVersion` differs from the current
one, under `dotnet-coverage collect`) and `CoverageReport` (merged into
`output/TestResults/Coverage.cobertura.xml`).

`-Task Sign -ModuleNupkg <path>` signs an already built nupkg with Azure
Trusted Signing. It needs an `az login` session and the `AZURE_TS_NAME`,
`AZURE_TS_PROFILE` and `AZURE_TS_ENDPOINT` env vars.

Quick Pester run while iterating, in a fresh process as binary modules cannot
be unloaded:

```powershell
pwsh -NoProfile -Command {
    Import-Module ./output/Modules/Pester
    Invoke-Pester -Path ./tests/Format-PSRPPacket.Tests.ps1 -Output Detailed
}
```

Gotchas:

- Binary modules cannot be unloaded. After rebuilding, always start a fresh
  `pwsh` process before importing the module again.
- Adding a NuGet dependency means adding a `PackageVersion` to
  `src/Directory.Packages.props` and an unversioned `PackageReference` in the
  `.csproj`.
- Target frameworks are read from the `<TargetFrameworks>` element of
  `src/RemoteWrench/RemoteWrench.csproj` by the build script. Keep that element
  on the first `PropertyGroup`.
- `build.ps1 -Task Test` instruments the built module for coverage. Do not
  run it while another `pwsh` process has `output/RemoteWrench` imported.

## Test conventions

- Every Pester file starts with `using module ../output/RemoteWrench`, which
  imports the built module when the file is parsed so its types can be used
  anywhere in the file, followed by a file level
  `BeforeAll { . ([Path]::Combine($PSScriptRoot, 'common.ps1')) }`. Helper
  functions used by more than one test go in `common.ps1` rather than the test
  file, test specific setup goes in the `BeforeAll` of the file or `Describe`.
- Assertions use the Pester 6 `Should-*` commands (`Should-Be`, `Should-Throw -ExceptionMessage`, ...). The
  classic `Should -Be` form is disabled in the test run and fails.
- Write test files through the file system path in `$TestDrive`, not a
  `TestDrive:` path.
- The tests also run on Windows PowerShell 5.1. Avoid PowerShell 7 only
  syntax like the ternary `?:`, `??`, `?.`, `&&`, `||` and the `` `e `` or
  `` `u{} `` escapes.
- Keep the `.ps1` files ASCII, without a BOM. Windows PowerShell reads them
  with the ANSI code page. Use the character variables in `common.ps1`, like
  `$Bar` or `$Esc`, or `[char]0x2502` for a non-ASCII character. A file
  using them in `-ForEach` test cases also dot-sources `common.ps1` in
  `BeforeDiscovery`.
- New .NET unit test projects go in `tests/units/<Name>/` using TUnit, with
  `<OutputType>Exe</OutputType>`.

## Continuous integration

`.github/workflows/ci.yml` builds once on Ubuntu, uploads the nupkg, then runs
`build.ps1 -Task Test -ModuleNupkg` on a matrix of Windows PowerShell 5.1 and
PowerShell 7.4, 7.5 and 7.6. Pushes to `main` and version tags (`v*`) build in
`Release`; pull requests build `Debug`.

Releases are immutable, the tag and assets of a published release cannot
change, so a release is made in two steps:

1. Pushing a version tag (`git tag v1.0.0 && git push origin v1.0.0`) runs
   `ci.yml`, which signs the module in the `signing` environment, tests the
   signed nupkg, then creates a draft release for the tag with the nupkg
   attached. Re-running it replaces the asset of the draft.
2. Publishing the draft in the GitHub UI, after reviewing it and its notes,
   locks the tag and nupkg and runs `.github/workflows/publish.yml`. It
   downloads the nupkg from the release and pushes it to the PowerShell
   Gallery in the `publish` environment. The release must be published by a
   person, one published with the `GITHUB_TOKEN` does not trigger workflows.

A failure before the draft is published is fixed by deleting the draft and the
tag and pushing the tag again. Once published, the tag name cannot be reused
even if the release is deleted, and a version pushed to the PowerShell Gallery
cannot be replaced, a fix after that point is a new version.

Actions are pinned to a full commit SHA with the version as a trailing comment,
`uses: actions/checkout@<sha>  # v7.0.1`. Dependabot
(`.github/dependabot.yml`) opens a weekly pull request that updates the SHA and
comment of every action together, only once a release is 7 days old. Pin any
new action the same way.

## Code conventions

- Both target frameworks use C# 12 (`LangVersion` in `src/Directory.Build.props`,
  the default of `net8.0`). PolySharp generates the compiler types and
  attributes .NET Framework lacks at build time (`IsExternalInit` for records
  and `SkipLocalsInit` today), nothing from it is shipped. `System.Memory`
  provides the span types and `PowerShellStandard.Library` the Windows
  PowerShell `System.Management.Automation` reference assembly. APIs missing from .NET Framework,
  like the `char` overloads of `StartsWith` or `Enum.GetNames<T>`, are avoided
  in favour of ones both have. Use `#if NET` only where the .NET API is
  meaningfully better, like the span based parsing in `OutOfProcPacket.cs`.
  Build both frameworks in `Release` before calling a change done, a .NET only
  API shows up as a `net472` compile error.
- `Nullable` enabled, file-scoped namespaces, 4-space indent, private static
  fields use `s_`, private instance fields use `_`.
- Line endings are LF everywhere. Trim trailing whitespace and end files with
  a newline.
- `.editorconfig` raises a set of IDE rules to warnings, which are errors in
  `Release` and CI builds (`TreatWarningsAsErrors`). Run
  `dotnet format <project> --severity warn` on each `src/` project to fix most
  of them.
- Adding a cmdlet means adding it to `src/RemoteWrench/Commands/`, to
  `CmdletsToExport` in `module/RemoteWrench.psd1` and writing
  `docs/en-US/RemoteWrench/<Verb-Noun>.md`. After building,
  `pwsh -File ./tools/UpdateDocs.ps1` syncs the markdown with the built
  cmdlets. Fill in any `{{ ... }}` placeholders it adds. Every cmdlet page
  needs a `HelpUri` and at least one related link.
- Add a line to `CHANGELOG.md` under the unreleased heading for anything a
  user would notice.

### Dependencies and the load context

This section is about PowerShell 7. Windows PowerShell has no
`AssemblyLoadContext`, `RemoteWrench.psm1` imports `bin/net472/RemoteWrench.dll`
directly and its dependencies, like `System.Memory`, load in the same context
as every other module. Avoiding conflicts there is best effort.

`RemoteWrench.dll` and its dependencies live in a private `AssemblyLoadContext`
created by `RemoteWrench.Loader`. PowerShell can resolve types in
`RemoteWrench.dll` by name because the module imports that assembly directly,
it cannot resolve types from the dependencies. So:

- Cmdlet parameter types must be built-in types (BCL or
  `System.Management.Automation`) or types defined in `RemoteWrench.dll`.
- Never write a dependency's object directly to the pipeline or expose one as
  a property type, wrap it in a `RemoteWrench` type.
- Only one copy of the module can be loaded per process;
  `RemoteWrench.psm1` refuses to import a copy from a different path.
- To bundle a dependency use a plain `PackageReference`. Do not add
  `PrivateAssets="all"`, the SDK then does not publish the assembly.
