<#
.SYNOPSIS
    Finds the pipeline (definition) ids of the two export pipelines by their names, so no id has to be written into the settings.
.DESCRIPTION
    The ids only exist after the export pipelines are created in Azure DevOps, which is after the YAML is generated. This looks them up
    at run time (GET {collection}{project}/_apis/build/definitions?name=..., api-version 7.1) with the pipeline's own access token and
    writes the pipeline variables EXPORT_PREPROD_ID and EXPORT_DEV_ID for the next steps. Stops, saying why, if a name matches no
    pipeline or more than one. The token is never printed. Run it with SYSTEM_ACCESSTOKEN mapped into the step's environment.
#>
param
(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PreProdName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DevName,

    # Optional: the Prod export pipeline (only when Prod is set up).
    [string]$ProdName = ''
)

$ErrorActionPreference = 'Stop'
$collection = ([string]$env:SYSTEM_COLLECTIONURI).TrimEnd('/')
$project = [string]$env:SYSTEM_TEAMPROJECT
if (-not $collection -or -not $project -or -not $env:SYSTEM_ACCESSTOKEN) { throw 'SYSTEM_COLLECTIONURI, SYSTEM_TEAMPROJECT or the access token is not available (map System.AccessToken into the step).' }
$headers = @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" }

function Get-DefinitionId
{
    param ([string]$Name)
    $uri = "$collection/$([System.Uri]::EscapeDataString($project))/_apis/build/definitions?name=$([System.Uri]::EscapeDataString($Name))&api-version=7.1"
    try { $result = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers }
    catch
    {
        $text = ([string]$_.Exception.Message) -replace '\s+', ' '
        if ($text -match '\b(401|403)\b') { throw "Azure DevOps refused the pipeline's access token when looking up the pipeline '$Name'. Give the project's build service identity the View build definition permission. ($text)" }
        throw
    }
    $found = @($result.value | Where-Object { $_.name -ceq $Name })
    if ($found.Count -eq 0) { throw "No pipeline is named '$Name' in project $project. Create it in Azure DevOps with exactly that name (or change ExportPreProdPipeline / ExportDevPipeline in the settings and generate the YAML again)." }
    if ($found.Count -gt 1) { throw "More than one pipeline is named '$Name' in project $project." }
    [string][int]$found[0].id
}

$preProdId = Get-DefinitionId -Name $PreProdName
$devId = Get-DefinitionId -Name $DevName
$prodId = if ($ProdName) { Get-DefinitionId -Name $ProdName } else { '' }
"Export pipelines: '$PreProdName' is $preProdId, '$DevName' is $devId."
"##vso[task.setvariable variable=EXPORT_PREPROD_ID]$preProdId"
"##vso[task.setvariable variable=EXPORT_DEV_ID]$devId"
if ($prodId) { "##vso[task.setvariable variable=EXPORT_PROD_ID]$prodId" }
