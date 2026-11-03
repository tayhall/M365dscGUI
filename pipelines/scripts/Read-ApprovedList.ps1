<#
.SYNOPSIS
    Checks an approved list early and tells the pipeline which two export runs to download.
.DESCRIPTION
    Runs before the export artifacts are downloaded: G9 (default branch, inside approvals\), then the strict format rules of
    Read-PEApprovedList, then it sets the pipeline variables PREPROD_RUN and DEV_RUN (digits only, already validated) that the
    DownloadPipelineArtifact steps use, and prints what the list holds.
#>
param
(
    [Parameter(Mandatory)]
    [string]$ListPath,

    [string]$ApprovalsRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'approvals'),

    [string]$DefaultBranch = 'main'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$full = & (Join-Path $PSScriptRoot 'Test-ApprovalLocation.ps1') -ListPath $ListPath -ApprovalsRoot $ApprovalsRoot -DefaultBranch $DefaultBranch
Import-Module (Join-Path $repoRoot 'src\PolicyEngine\PolicyEngine.psd1') -Force -WarningAction SilentlyContinue
$list = Read-PEApprovedList -Path $full

"Approved list $(Split-Path $full -Leaf): approved by $($list.ApprovedBy) at $($list.CreatedUtc); tenant $($list.Tenant); $(@($list.Items).Count) item(s)"
@($list.Counts) | ForEach-Object { "  $($_.Action) $($_.Count) $($_.ResourceType)" }
"PreProd export run $($list.Source.Run) (exported $($list.Source.ExportedAt)); Dev export run $($list.Target.Run) (exported $($list.Target.ExportedAt))"
Write-Host "##vso[task.setvariable variable=PREPROD_RUN]$($list.Source.Run)"
Write-Host "##vso[task.setvariable variable=DEV_RUN]$($list.Target.Run)"
