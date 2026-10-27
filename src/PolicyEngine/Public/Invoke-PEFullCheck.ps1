function Invoke-PEFullCheck
{
    <#
    .SYNOPSIS
    Exports the tenant, compares it with a blueprint and saves the result as checks\<CheckId>\result.json.

    .DESCRIPTION
    -ExportScript produces the export and returns the path of the export folder; it is called with the named values
    Workloads and OutputPath. Checks always use the Reader app registration. The default runs tools\Export-M365DscTenant.ps1 in a child process, which writes
    export.ps1 and export.log into OutputPath (data\exports\<CheckId>).

    Components are classified from export.log (Read-PEExportLog): Failed ones go to the target's NotChecked list with the
    error, so they never produce Missing findings. An Ok component with no instances is genuinely empty, so the
    blueprint's records of that type become Missing. If export.log is missing the check is degraded: every blueprint
    type with no records in the export becomes NotChecked with the reason 'no export log' (State.Meta.ExportLog is
    'missing'). When the log exists, a blueprint type that the log never mentions becomes NotChecked 'not in export log'
    (for example a workload that was not exported).

    The state holds normalised records only (ignored properties such as ids and credentials are removed), so the result
    carries no secrets. result.json is written once.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$BlueprintName,

        [string[]]$Workloads = (Get-PEDefaultWorkload),

        [scriptblock]$ExportScript,

        # Tenant id of the exported (target) tenant. Default: TenantId of the Reader app registration; 'unknown' when
        # -ExportScript is used without this parameter. Never taken from the blueprint.
        [string]$TargetTenantId,

        # Run although the pinned Microsoft365DSC is not the version the blueprint was built with (to review the effect of an upgrade as drift).
        [switch]$AcceptModuleChange,

        # Which tenant to read (see Get-PETenant); the first tenant is 'master'.
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant = 'master',

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    Assert-PEBlueprintNotStandard -Name $BlueprintName -Action 'run a full check against it (use Invoke-PEStandardCheck)' -DataRoot $root
    $blueprint = Get-PEBlueprint -Name $BlueprintName -DataRoot $root
    Assert-PEModuleVersion -BlueprintName $BlueprintName -AcceptModuleChange:$AcceptModuleChange -DataRoot $root
    $blueprintVersion = @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $BlueprintName -DataRoot $root))[-1]

    $checkId = New-PECheckId -Root $root

    $exported = Get-PETenantExportState -Blueprint $blueprint -Workloads $Workloads -CheckId $checkId -Tenant $Tenant -Root $root -ExportScript $ExportScript -TargetTenantId $TargetTenantId
    $state = $exported.State
    $exportPath = $exported.ExportPath
    $tenantId = $exported.TenantId
    $logWarnings = $exported.LogWarnings

    $decisions = @(Get-PEDecision -DataRoot $root -Tenant $Tenant)
    $findings = @(Compare-PEState -Blueprint $blueprint -Target $state -Decisions $decisions)

    $document = [ordered]@{
        CheckId          = $checkId
        Kind             = 'Full'
        TenantSlug       = $Tenant
        BlueprintName    = $BlueprintName
        BlueprintTenantId = [string](Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId')
        CrossTenant      = (Test-PECrossTenant -BlueprintTenantId (Get-PEMetaValue -Meta $blueprint.Meta -Name 'TenantId') -TargetTenantId $tenantId)
        BlueprintVersion = $blueprintVersion
        Path             = $exportPath
        LogWarnings      = @($logWarnings)
        Findings         = $findings
        State            = $state
    }
    Write-PEJsonNew -Path (Join-Path $root "checks\$checkId\result.json") -InputObject $document

    [pscustomobject]@{
        CheckId  = $checkId
        Findings = $findings
        LogWarnings = @($logWarnings)
        State    = $state
        Path     = $exportPath
    }
}
