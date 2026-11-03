<#
.SYNOPSIS
    Asks Azure DevOps to keep the two export runs an approved list names, so the same list can be applied again later (G7).
.DESCRIPTION
    Without this, retention could delete the export artifacts the list pins by hash and a re-run of the list would fail. One call creates a
    retention lease on each run (POST {collection}{project}/_apis/build/retention/leases, api-version 7.1) with the pipeline's own access
    token. If Azure DevOps refuses (the build identity may lack the permission to manage retention), it prints a warning and carries on:
    the run still works while the artifacts exist. The token is never printed. Run it after the artifacts were downloaded.
#>
param
(
    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,12}\z')]
    [string]$PreProdRun,

    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,12}\z')]
    [string]$DevRun,

    # The pipeline (definition) ids of the two export pipelines.
    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,9}\z')]
    [string]$PreProdDefinitionId,

    [Parameter(Mandatory)]
    [ValidatePattern('\A\d{1,9}\z')]
    [string]$DevDefinitionId,

    [ValidateRange(1, 3650)]
    [int]$DaysValid = 60
)

$ErrorActionPreference = 'Stop'
try
{
    $collection = ([string]$env:SYSTEM_COLLECTIONURI).TrimEnd('/')
    $project = [string]$env:SYSTEM_TEAMPROJECT
    if (-not $collection -or -not $project -or -not $env:SYSTEM_ACCESSTOKEN) { throw 'SYSTEM_COLLECTIONURI, SYSTEM_TEAMPROJECT or the access token is not available (map System.AccessToken into the step).' }
    $uri = "$collection/$([System.Uri]::EscapeDataString($project))/_apis/build/retention/leases?api-version=7.1"
    $body = ConvertTo-Json -InputObject @(
        [ordered]@{ daysValid = $DaysValid; definitionId = [int]$PreProdDefinitionId; ownerId = 'approved-apply'; protectPipeline = $false; runId = [int]$PreProdRun }
        [ordered]@{ daysValid = $DaysValid; definitionId = [int]$DevDefinitionId; ownerId = 'approved-apply'; protectPipeline = $false; runId = [int]$DevRun }
    ) -Compress
    Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/json' -Headers @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" } | Out-Null
    "Retention: export runs $PreProdRun and $DevRun are kept for $DaysValid days."
}
catch
{
    $reason = (([string]$_.Exception.Message) -split "`r?`n")[0]
    Write-Host "##vso[task.logissue type=warning]Could not keep export runs $PreProdRun and $DevRun (retention lease): $reason. Applying this list again later only works while Azure DevOps still has those artifacts."
}
