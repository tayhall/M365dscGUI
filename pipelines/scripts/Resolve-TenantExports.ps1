<#
.SYNOPSIS
    Finds the two export runs of one tenant that a Tenant-Changes run compares: the latest and the one before it, or the ones named.
.DESCRIPTION
    Uses the pipeline's own access token over the Azure DevOps REST API (the same mechanism as New-ExportRetentionLease.ps1) to list the
    completed runs of the tenant's export pipeline. Blank versions mean "the newest successful run that still has its artifact" and "the
    successful run just before the latest". A version is a friendly name (v9, the counter in the run name 'Dev-export-v9') or, for an old
    run whose name has no counter, a numeric run id. "Previous" is looked up, never calculated as the number minus one, because the
    counter also counts failed and cancelled runs.
    Refuses, saying why: a name that does not exist, a run that did not succeed, a run of another pipeline, a run whose artifact retention
    deleted, an "after" that is not newer than the "before", and a tenant with no earlier successful export.
    With -SetVariables it also writes pipeline variables for the next steps: DEFINITION_ID, ARTIFACT_NAME, LATEST_RUN, PREVIOUS_RUN,
    LATEST_NAME, PREVIOUS_NAME. The token is never printed. Run it with SYSTEM_ACCESSTOKEN mapped into the step's environment.
#>
param
(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'PreProd')]
    [string]$Tenant,

    # Tenant name to export pipeline (definition) id, for example 'Dev=22;PreProd=21'.
    [Parameter(Mandatory)]
    [ValidatePattern('\A[A-Za-z0-9]+=\d{1,9}(;[A-Za-z0-9]+=\d{1,9})*\z')]
    [string]$TenantMap,

    # The "after" export: blank (latest), a friendly name such as v9, or a numeric run id.
    [ValidatePattern('\A(v\d{1,6}|\d{1,12})?\z')]
    [string]$ExportVersion = '',

    # The "before" export, same forms. Blank: the successful run just before the "after" one.
    [ValidatePattern('\A(v\d{1,6}|\d{1,12})?\z')]
    [string]$PreviousVersion = '',

    [switch]$SetVariables
)

$ErrorActionPreference = 'Stop'

$definitionId = $null
foreach ($pair in $TenantMap -split ';') { $name, $value = $pair -split '=', 2; if ($name -ceq $Tenant) { $definitionId = [int]$value } }
if (-not $definitionId) { throw "The tenant map has no export pipeline id for $Tenant. Add it to the settings (ExportDevPipelineId / ExportPreProdPipelineId) and generate the YAML again." }
$artifactName = "${Tenant}Export"

$collection = ([string]$env:SYSTEM_COLLECTIONURI).TrimEnd('/')
$project = [string]$env:SYSTEM_TEAMPROJECT
if (-not $collection -or -not $project -or -not $env:SYSTEM_ACCESSTOKEN) { throw 'SYSTEM_COLLECTIONURI, SYSTEM_TEAMPROJECT or the access token is not available (map System.AccessToken into the step).' }
$base = "$collection/$([System.Uri]::EscapeDataString($project))/_apis/build/builds"
$headers = @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" }

function Invoke-Ado
{
    # One GET. A refusal of the token gets a message that says what to grant; a 404 returns $null.
    param ([string]$Uri)
    try { Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -ResponseHeadersVariable responseHeaders }
    catch
    {
        $text = [string]$_.Exception.Message
        if ($text -match '\b404\b') { return $null }
        if ($text -match '\b(401|403)\b') { throw "Azure DevOps refused the pipeline's access token when reading the runs of the $Tenant export pipeline. Give the project's build service identity the View builds permission on that pipeline. ($($text -replace '\s+', ' '))" }
        throw
    }
    $script:LastHeaders = $responseHeaders
}

# All completed runs of the export pipeline, newest first, up to ten pages of a hundred.
$builds = [System.Collections.Generic.List[object]]::new()
$token = ''
for ($page = 0; $page -lt 10; $page++)
{
    $uri = "$base`?definitions=$definitionId&statusFilter=completed&queryOrder=queueTimeDescending&`$top=100&api-version=7.1"
    if ($token) { $uri += "&continuationToken=$token" }
    $script:LastHeaders = $null
    $response = Invoke-Ado $uri
    if ($response) { foreach ($build in @($response.value)) { $builds.Add($build) } }
    $token = ''
    if ($script:LastHeaders -and $script:LastHeaders['x-ms-continuationtoken']) { $token = [string]@($script:LastHeaders['x-ms-continuationtoken'])[0] }
    if (-not $token) { break }
}
$builds = @($builds | Sort-Object { -[int]$_.id })

function Test-Artifact
{
    param ([int]$RunId)
    return [bool](Invoke-Ado "$base/$RunId/artifacts?artifactName=$artifactName&api-version=7.1")
}

function Resolve-Version
{
    # A named run: friendly name or numeric id -> the build, after checking it is a successful run of this pipeline with its artifact.
    param ([string]$Version)
    if ($Version -cmatch '\Av\d{1,6}\z')
    {
        $found = @($builds | Where-Object { [string]$_.buildNumber -cmatch "(\A|-)$Version\z" }) | Select-Object -First 1
        if (-not $found) { throw "There is no completed run named $Version of the $Tenant export pipeline (run names look like $Tenant-export-v9)." }
    }
    else
    {
        $found = @($builds | Where-Object { [string]$_.id -eq $Version }) | Select-Object -First 1
        if (-not $found)
        {
            $found = Invoke-Ado "$base/$Version`?api-version=7.1"
            if (-not $found) { throw "There is no run $Version in this project." }
            if ([int]$found.definition.id -ne $definitionId) { throw "Run $Version belongs to another pipeline than the $Tenant export pipeline." }
        }
    }
    if ([string]$found.result -ne 'succeeded') { throw "Run $($found.buildNumber) (id $($found.id)) of the $Tenant export did not succeed (result: $($found.result))." }
    if (-not (Test-Artifact ([int]$found.id))) { throw "Run $($found.buildNumber) (id $($found.id)) of the $Tenant export no longer has its artifact $artifactName (retention deleted it). Pick another run." }
    return $found
}

# Successful runs that still have their artifact, newest first, checked one at a time and only as far as needed.
function Get-Candidate
{
    param ([int]$BelowId = [int]::MaxValue, [int]$Skip = 0)
    $count = 0
    foreach ($build in $builds | Where-Object { [string]$_.result -eq 'succeeded' -and [int]$_.id -lt $BelowId })
    {
        if (-not (Test-Artifact ([int]$build.id))) { continue }
        if ($count -ge $Skip) { return $build }
        $count++
    }
    return $null
}

$latest = if ($ExportVersion) { Resolve-Version $ExportVersion } else { Get-Candidate }
if (-not $latest) { throw "There is no successful export of $Tenant with its artifact still available; take a fresh export first." }

if ($PreviousVersion)
{
    $previous = Resolve-Version $PreviousVersion
    if ([int]$previous.id -eq [int]$latest.id) { throw "The previous and the latest export are the same run ($($latest.buildNumber), id $($latest.id)); pick two different exports." }
    if ([int]$previous.id -gt [int]$latest.id) { throw "The previous export ($($previous.buildNumber)) must be older than the latest ($($latest.buildNumber)), but it is newer. Swap them." }
}
else
{
    $previous = Get-Candidate -BelowId ([int]$latest.id)
    if (-not $previous) { throw "There is no earlier successful export of $Tenant; take a fresh export first (the latest is $($latest.buildNumber), id $($latest.id))." }
}

$result = [pscustomobject]@{
    DefinitionId = [string]$definitionId
    ArtifactName = $artifactName
    Latest       = [pscustomobject]@{ RunId = [string]$latest.id; Name = [string]$latest.buildNumber }
    Previous     = [pscustomobject]@{ RunId = [string]$previous.id; Name = [string]$previous.buildNumber }
}
Write-Host "$Tenant changes: previous $($result.Previous.Name) (run $($result.Previous.RunId)) -> latest $($result.Latest.Name) (run $($result.Latest.RunId))"
if ($SetVariables)
{
    $variables = [ordered]@{
        DEFINITION_ID = $result.DefinitionId
        ARTIFACT_NAME = $result.ArtifactName
        LATEST_RUN    = $result.Latest.RunId
        PREVIOUS_RUN  = $result.Previous.RunId
        LATEST_NAME   = $result.Latest.Name
        PREVIOUS_NAME = $result.Previous.Name
    }
    foreach ($key in $variables.Keys) { Write-Host "##vso[task.setvariable variable=$key]$($variables[$key])" }
}
$result
