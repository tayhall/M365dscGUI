<#
.SYNOPSIS
    G9: the approved list may only be used from the default branch, and only if it sits inside the project's approvals folder.
.DESCRIPTION
    Returns the full path of the list, or throws. Run before any tenant access and before artifacts are downloaded. A branch policy that
    requires a pull request review on approvals\ is an Azure DevOps setting and is recommended; this script cannot enforce it, but it does make
    sure a list from a feature branch, or from a path outside approvals\, is never applied.
#>
param
(
    [Parameter(Mandatory)]
    [string]$ListPath,

    [string]$ApprovalsRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'approvals'),

    [ValidatePattern('\A[A-Za-z0-9._/-]{1,100}\z')]
    [string]$DefaultBranch = 'main'
)

$ErrorActionPreference = 'Stop'
$defaultRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'approvals'
if ([System.IO.Path]::GetFullPath($ApprovalsRoot).TrimEnd('\', '/') -ine [System.IO.Path]::GetFullPath($defaultRoot).TrimEnd('\', '/') -and $env:PE_TEST_HOOKS -ne '1')
{
    throw "A different approvals folder ($ApprovalsRoot) is a test hook and is only accepted when PE_TEST_HOOKS is 1. Nothing was done."
}
$branch = [string]$env:BUILD_SOURCEBRANCH
if ($branch -cne "refs/heads/$DefaultBranch")
{
    throw "The approved apply only runs from the default branch ($DefaultBranch), not from '$branch'. Merge the approved list first (a pull request on approvals\ is the review). Nothing was done."
}
$listFull = [System.IO.Path]::GetFullPath($ListPath)
$approvalsFull = [System.IO.Path]::GetFullPath($ApprovalsRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $listFull.StartsWith($approvalsFull, [System.StringComparison]::OrdinalIgnoreCase))
{
    throw "The approved list must be inside the approvals folder ($ApprovalsRoot), but it is $listFull. Nothing was done."
}
if (-not (Test-Path -LiteralPath $listFull -PathType Leaf)) { throw "No approved list at $listFull." }
$listFull
