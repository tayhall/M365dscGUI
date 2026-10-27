<#
.SYNOPSIS
    Compiles a Microsoft365DSC configuration to MOF and applies it (or only tests it) from PowerShell 7, through the Local Configuration Manager.
.DESCRIPTION
    The apply sequence proven in docs\apply-mechanics.md (Task 11 step 1); Invoke-PERectify wraps or replaces it. The
    logic is in tools\PEApply.Common.ps1 (Invoke-PEApply).
    1. Guards: the app JSON for -Role is always read; a -ConfigurationDataPath must name the same tenant, app and
       certificate; a Reader run must be -TestOnly; a real apply needs -ExpectedResourceCount; -OutputPath must be
       outside the repo (also through junctions/symlinks; no UNC or \\?\ paths).
    2. Compile with Invoke-M365DSCConfigurationBuild -Engine Standard into a per-run work folder
       (<OutputPath or OS temp>\PEApply-<guid>, accessible only to the current user).
    3. Read the instances back from the MOF and refuse, before any Test or Set (fail closed): an instance that is not a
       Microsoft365DSC resource of the pinned version; TenantId, ApplicationId or CertificateThumbprint missing or not
       matching the app; any other authentication property (Credential, ApplicationSecret, CertificatePath,
       CertificatePassword, ManagedIdentity, AccessTokens, PsDscRunAsCredential); DependsOn; a count different from
       the configuration's resource blocks (AST) or from -ExpectedResourceCount.
    4. Hand the MOF to the Local Configuration Manager as Microsoft365DSC documents: Start-DscConfiguration -Wait -Force (or, with
       -TestOnly, Test-DscConfiguration -ReferenceConfiguration), run from Windows PowerShell 5.1 by tools\Invoke-PELcm.ps1; the LCM relays
       every resource call into PowerShell 7. Needs an elevated session, the same Microsoft365DSC version under Windows PowerShell
       and the PowerShell.7 WinRM endpoint (Enable-PSRemoting), and the app certificate in a store the LCM (SYSTEM) can read
       (Cert:\LocalMachine\My). Resources run in MOF order; the LCM carries on after a failed resource. Afterwards the configuration is
       removed from the LCM so it does not keep re-testing the tenant. Applies are serialised machine-wide (one LCM, one configuration).
       No Test after a Set: the drift re-check of the caller confirms the result.
    5. The work folder (generated configuration data and MOF, both carrying the certificate thumbprint) is deleted in
       a finally block, unless -KeepOutput (then its path is reported and the caller must delete it).
    Output: the result object, or with -Json the same as compact JSON. Success, TestOnly, PartiallyApplied,
    ResourceCount, ExpectedResourceCount, OutputFolder (with -KeepOutput), MofPath (with -KeepOutput), CompileSeconds,
    ApplySeconds, Error, Resources (ResourceId, ResourceType, Status = InDesiredState|WouldChange|Applied (in desired state after the apply)|Failed|NotRun,
    InDesiredStateBefore, SetInvoked, RebootRequired, InDesiredStateAfter, Seconds, Error). Error texts never contain
    the certificate thumbprint ('<thumbprint>').
    Exit code: 0 when Success, 2 when the compile or a resource failed, 1 when a guard threw.
    -ConfigPath is EXECUTED by the compile: pass only trusted, generated configurations.
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PEApply.ps1 -ConfigPath C:\temp\x\config.ps1 -ConfigurationName PERectify -ExpectedResourceCount 3 -Json
.EXAMPLE
    pwsh -NoProfile -File tools\Invoke-PEApply.ps1 -ConfigPath C:\temp\x\config.ps1 -ConfigurationName PERectify -TestOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [string]$ConfigurationDataPath,

    [ValidateSet('Reader', 'Writer')]
    [string]$Role = 'Writer',

    [Parameter(Mandatory)]
    [string]$ConfigurationName,

    # Parent of the per-run work folder; default the OS temp folder. Must be outside the repo.
    [string]$OutputPath,

    # Compile and Test only, never Set. -WhatIf does the same.
    [Alias('Preview')]
    [switch]$TestOnly,

    # Keep the work folder (MOF and generated configuration data, which carry the certificate thumbprint).
    [switch]$KeepOutput,

    # Emit the result as compact JSON (for callers using pwsh -File).
    [switch]$Json,

    # Standard validates property names against the resource schema; FastHost compiles faster but silently drops
    # unknown properties (observed with M365DSC.PSDesiredStateConfiguration 3.1.10).
    [ValidateSet('Standard', 'FastHost')]
    [string]$Engine = 'Standard',

    # Required for a real apply: the number of resource instances the configuration must contain.
    [ValidateRange(1, 10000)]
    [int]$ExpectedResourceCount,

    [string]$ModuleVersion = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\Versions.psd1')).Microsoft365DSC,

    [string]$EngineVersion = '3.1.10',

    # The app registration file of the tenant to apply to (a replica's own Writer app); default the master's.
    [string]$AppInfoPath
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -lt [version]'7.6')
{
    throw "Run this from PowerShell 7.6 or later (this is $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))."
}
. (Join-Path $PSScriptRoot 'PEApply.Common.ps1')

$scriptCmdlet = $PSCmdlet
$testOnly = Resolve-PEApplyMode -TestOnly $TestOnly.IsPresent -ShouldProcess {
    $scriptCmdlet.ShouldProcess($ConfigPath, "Apply configuration '$ConfigurationName' to the tenant")
}.GetNewClosure()
# -WhatIf / -Confirm are now expressed as $testOnly; the tool's own work folder must still be created and removed.
$WhatIfPreference = $false
$ConfirmPreference = 'High'

$arguments = @{
    ConfigPath          = $ConfigPath
    Role                = $Role
    ConfigurationName   = $ConfigurationName
    RepoRoot            = (Split-Path $PSScriptRoot -Parent)
    TestOnly            = $testOnly
    KeepOutput          = $KeepOutput
    Engine              = $Engine
    ModuleVersion       = $ModuleVersion
    EngineVersion       = $EngineVersion
}
if ($ConfigurationDataPath)
{
    $arguments['ConfigurationDataPath'] = $ConfigurationDataPath
}
if ($OutputPath)
{
    $arguments['OutputPath'] = $OutputPath
}
if ($AppInfoPath)
{
    $arguments['AppInfoPath'] = $AppInfoPath
}
if ($PSBoundParameters.ContainsKey('ExpectedResourceCount'))
{
    $arguments['ExpectedResourceCount'] = $ExpectedResourceCount
}
$result = Invoke-PEApply @arguments
$thumbprint = $null
try
{
    $appArguments = @{ Role = $Role }
    if ($AppInfoPath) { $appArguments['Path'] = $AppInfoPath }
    $thumbprint = (Get-PEApplyApp @appArguments).Thumbprint
}
catch
{
    $thumbprint = $null
}
$final = Complete-PEApplyOutput -Result $result -Json:$Json -Thumbprint $thumbprint
$final.Output
exit $final.ExitCode
