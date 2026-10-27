# Helpers for Export-PEDelta.

# Types for which a delta export may use a DSC Filter, and the OData property that holds the PolicyEngine key. Only
# types whose key is exactly that property (KeyMap Default, DisplayName first, no override) and whose DSC Export()
# passes the filter to a Graph $filter are listed. Every other type is exported whole and filtered afterwards.
# AADGroup: Export() runs Get-MgBetaGroup -Filter $this.Filter (Classes\Part01.psm1, class AADGroup).
$script:PEDeltaFilterProperty = @{
    AADGroup = 'DisplayName'
}

function Find-PEExportFile
{
    # export.ps1 in the folder, or the only *.ps1 there.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $exportFile = Join-Path $Path 'export.ps1'
    if (-not (Test-Path -LiteralPath $exportFile -PathType Leaf))
    {
        $candidates = @(Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
        if ($candidates.Count -ne 1)
        {
            throw "No export file (export.ps1) found in $Path."
        }
        $exportFile = $candidates[0].FullName
    }
    return $exportFile
}

function Test-PEResourceFilterSupport
{
    # ResourceType -> whether Microsoft365DSC's export accepts a Filter for it, from Test-M365DSCResourceProperty (the
    # same check Export-M365DSCConfiguration makes before it passes a filter on). Runs in a child process so the
    # Microsoft365DSC module (and its Graph module versions) never load into this session.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$ResourceType
    )

    $map = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($type in $ResourceType)
    {
        if ($type -notmatch '^[A-Za-z0-9]+$')
        {
            throw "Invalid resource type name '$type'."
        }
    }
    $list = ($ResourceType | ForEach-Object { "'$_'" }) -join ','
    $command = "`$ErrorActionPreference = 'Stop'; Import-Module Microsoft365DSC -RequiredVersion $(Get-PEPinnedVersion -Name Microsoft365DSC) -WarningAction SilentlyContinue; " +
        "`$r = [ordered]@{}; foreach (`$t in @($list)) { `$r[`$t] = [bool](Test-M365DSCResourceProperty -ResourceName `$t -PropertyName 'Filter') }; " +
        "`$r | ConvertTo-Json -Compress"
    $output = & pwsh -NoProfile -NonInteractive -Command $command
    if ($LASTEXITCODE -ne 0)
    {
        throw "Could not check Filter support (exit code $LASTEXITCODE)."
    }
    $result = ($output | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable
    foreach ($type in $ResourceType)
    {
        $map[$type] = [bool]$result[$type]
    }
    return , $map
}

function Get-PEDeltaFilter
{
    # OData filter selecting one key of a type, or $null when no safe filter exists for the type.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ResourceType,

        [Parameter(Mandatory)]
        [string]$Key
    )

    if (-not $script:PEDeltaFilterProperty.ContainsKey($ResourceType))
    {
        return $null
    }
    # Guard: the KeyMap must still derive this type's key from the filter property alone.
    $map = Get-PEKeyMap
    if ($map.Singletons -contains $ResourceType -or $map.Overrides.ContainsKey($ResourceType) -or @($map.Default)[0] -ne $script:PEDeltaFilterProperty[$ResourceType])
    {
        return $null
    }
    return "{0} eq '{1}'" -f $script:PEDeltaFilterProperty[$ResourceType], $Key.Replace("'", "''")
}

function Invoke-PEDeltaExportTool
{
    # Default export for Export-PEDelta: tools\Export-M365DscTenant.ps1 (Reader app, export.log captured through
    # Invoke-PELoggedCommand) in a child process. Filters go through a filters.json file next to the export.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$Components,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable]$Filters,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$Tenant = 'master'
    )

    # pwsh -File binds one string per parameter, so one component per call (Export-PEDelta exports per type anyway).
    if ($Components.Count -ne 1)
    {
        throw 'Invoke-PEDeltaExportTool exports exactly one component per call.'
    }
    $tool = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\Export-M365DscTenant.ps1'
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    $arguments = @('-NoProfile', '-File', $tool, '-Role', 'Reader', '-Components', $Components[0], '-OutputPath', $OutputPath)
    if ($Tenant -ne 'master') { $arguments += @('-Tenant', $Tenant) }
    if ($Filters.Count -gt 0)
    {
        $filtersPath = Join-Path $OutputPath 'filters.json'
        Write-PEJson -Path $filtersPath -InputObject $Filters
        $arguments += @('-FiltersPath', $filtersPath)
    }
    & pwsh @arguments | Out-Host
    if ($LASTEXITCODE -ne 0)
    {
        throw "Delta export failed with exit code $LASTEXITCODE."
    }
    return $OutputPath
}
