# A standard is a blueprint (Private\Standard.ps1) whose records come from published DSC configuration files, parsed with DSC's
# own parser (Read-PEExport). Items that use a placeholder, or a property the pinned module does not have, are not stored: they are
# listed in coverage\vNNNN.json with the reason, so a check can say how much of the standard it covered.

function Import-PEStandard
{
    <#
    .SYNOPSIS
    Imports the DSC configuration files in -Path as a version of the standard -Name (version 1 creates it). Returns a summary.

    .DESCRIPTION
    The files are only parsed, never run (they are copied to a temporary folder as .ps1 first). Each version is a new blueprint version
    with a change record; -SourceVersion (the upstream release tag) must be new. A record's Provenance.SourceVersion is the source
    version in which its value was last set.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SourceName,

        [Parameter(Mandatory)]
        [string]$SourceUrl,

        [Parameter(Mandatory)]
        [string]$SourceVersion,

        [string]$License = 'CC BY 4.0',

        [string]$Attribution,

        [string]$Reason,

        [string]$DataRoot
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container))
    {
        throw "Standard source folder not found: $Path"
    }
    $root = Get-PEDataRoot -Override $DataRoot
    $directory = Get-PEBlueprintDirectory -Name $Name -DataRoot $root
    $exists = @(Get-PEBlueprintVersionNumber -Directory $directory).Count -gt 0
    $info = Get-PEStandardInfo -Name $Name -DataRoot $root
    if ($exists -and $null -eq $info)
    {
        throw "Blueprint '$Name' exists and is not a standard."
    }
    if ($null -ne $info -and @($info.Versions | Where-Object { $_.SourceVersion -ceq $SourceVersion }).Count -gt 0)
    {
        throw "Source version '$SourceVersion' is already imported into standard '$Name'."
    }
    $files = @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Extension -in '.txt', '.ps1' -and $_.BaseName -notlike 'ConfigurationData*' } | Sort-Object Name)
    if ($files.Count -eq 0)
    {
        throw "No DSC configuration files (.txt or .ps1) found in $Path."
    }

    $importedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-standard-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    $covered = [System.Collections.Generic.List[object]]::new()
    $notCovered = [System.Collections.Generic.List[object]]::new()
    try
    {
        foreach ($file in $files)
        {
            $copy = Join-Path $work ($file.BaseName + '.ps1')
            Copy-Item -LiteralPath $file.FullName -Destination $copy
            try
            {
                $parsedRecords = @(Read-PEExport -Path $copy -TenantId 'standard' -WarningAction SilentlyContinue)
            }
            catch
            {
                throw "Cannot parse $($file.FullName): $($_.Exception.Message)"
            }
            foreach ($parsed in $parsedRecords)
            {
                $record = ConvertTo-PENormalizedRecord -Record $parsed
                $class = Get-PEStandardItemClass -Record $record
                if ($null -ne $class)
                {
                    $notCovered.Add([pscustomobject]@{ ResourceType = [string]$record.ResourceType; Key = [string]$record.Key; Workload = [string]$record.Workload; Reason = $class.Reason; Detail = $class.Detail })
                    continue
                }
                $record | Add-Member -NotePropertyName Provenance -NotePropertyValue ([ordered]@{ Standard = $Name; SourceVersion = $SourceVersion; ControlId = $null })
                $covered.Add($record)
            }
        }
    }
    finally
    {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    $meta = @{ TenantId = 'standard'; Source = $SourceName; SourceVersion = $SourceVersion; Kind = 'Standard'; ImportedAt = $importedAt }
    $state = New-PEState -Records $covered.ToArray() -NotChecked @() -Meta $meta
    $added = 0
    $changed = 0
    $removed = 0
    if (-not $exists)
    {
        $version = Initialize-PEBlueprint -Name $Name -State $state -DataRoot $root
        $added = $covered.Count
    }
    else
    {
        $applicable = @(Get-PEBlueprintChange -Name $Name -MasterState $state -DataRoot $root | Where-Object { $_.Kind -in 'Missing', 'TargetOnly', 'Changed' })
        $added = @($applicable | Where-Object Kind -EQ 'Missing').Count
        $changed = @($applicable | Where-Object Kind -EQ 'Changed').Count
        $removed = @($applicable | Where-Object Kind -EQ 'TargetOnly').Count
        $lock = Enter-PEBlueprintLock -Directory $directory
        try
        {
            $text = if ($Reason) { $Reason } else { "Import $SourceName $SourceVersion" }
            $version = Write-PEBlueprintVersion -Name $Name -MasterState $state -Accepted $applicable -Reason $text -DataRoot $root -MetaOverride @{ SourceVersion = $SourceVersion; Kind = 'Standard'; ImportedAt = $importedAt }
        }
        finally
        {
            Exit-PEBlueprintLock -Lock $lock
        }
    }

    $total = $covered.Count + $notCovered.Count
    Write-PEJsonNew -Path (Join-Path (Join-Path $directory 'coverage') ('v{0:D4}.json' -f $version)) -InputObject @($notCovered)
    $versions = @(@($info.Versions) | Where-Object { $null -ne $_ }) + [ordered]@{ Version = $version; SourceVersion = $SourceVersion; ImportedAt = $importedAt; Total = $total; Covered = $covered.Count }
    $attributionText = if ($Attribution) { $Attribution } elseif ($info) { [string]$info.Attribution } else { '' }
    Write-PEJson -Path (Join-Path $directory 'standard.json') -InputObject ([ordered]@{
            Kind        = 'Standard'
            Name        = $Name
            SourceName  = $SourceName
            SourceUrl   = $SourceUrl
            License     = $License
            Attribution = $attributionText
            Versions    = @($versions)
        })
    if ($attributionText)
    {
        Write-Host "Source: $SourceName $SourceVersion ($SourceUrl), $License. $attributionText"
    }

    $byReason = @{}
    foreach ($group in ($notCovered | Group-Object Reason))
    {
        $byReason[$group.Name] = $group.Count
    }
    [pscustomobject]@{
        Name          = $Name
        Version       = $version
        SourceVersion = $SourceVersion
        Total         = $total
        Covered       = $covered.Count
        NotCovered    = $notCovered.Count
        ByReason      = $byReason
        Added         = $added
        Changed       = $changed
        Removed       = $removed
    }
}

function Get-PEStandard
{
    <#
    .SYNOPSIS
    The standards held under data\blueprints (those with a standard.json): source, licence and imported versions.
    #>
    [CmdletBinding()]
    param
    (
        [string]$Name,

        [string]$DataRoot
    )

    $names = if ($Name) { @($Name) } else
    {
        $folder = Join-Path (Get-PEDataRoot -Override $DataRoot) 'blueprints'
        @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    }
    foreach ($candidate in $names)
    {
        $info = Get-PEStandardInfo -Name $candidate -DataRoot $DataRoot
        if ($null -ne $info)
        {
            [pscustomobject]@{
                Name        = [string]$info.Name
                SourceName  = [string]$info.SourceName
                SourceUrl   = [string]$info.SourceUrl
                License     = [string]$info.License
                Attribution = [string]$info.Attribution
                Versions    = @($info.Versions)
            }
        }
    }
}

function Get-PEStandardCoverage
{
    <#
    .SYNOPSIS
    The items of a standard version that are not covered (Placeholder, UnknownProperty or Unkeyed), one row each with the reason.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [ValidatePattern('^(latest|\d+)$')]
        [string]$Version = 'latest',

        [string]$DataRoot
    )

    $directory = Get-PEBlueprintDirectory -Name $Name -DataRoot $DataRoot
    $numbers = @(Get-PEBlueprintVersionNumber -Directory $directory)
    if ($numbers.Count -eq 0 -or $null -eq (Get-PEStandardInfo -Name $Name -DataRoot $DataRoot))
    {
        throw "Standard '$Name' not found."
    }
    $number = if ($Version -eq 'latest') { $numbers[-1] } else { [int]$Version }
    $path = Join-Path (Join-Path $directory 'coverage') ('v{0:D4}.json' -f $number)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf))
    {
        throw "Standard '$Name' has no version $number."
    }
    return @(Read-PEJson -Path $path | Where-Object { $null -ne $_ })
}

function Get-PEStandardChange
{
    <#
    .SYNOPSIS
    What changed between two versions of a standard: Op Added, Changed or Removed per item.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$FromVersion,

        [Parameter(Mandatory)]
        [int]$ToVersion,

        [string]$DataRoot
    )

    $from = Get-PEBlueprint -Name $Name -Version $FromVersion -DataRoot $DataRoot
    $to = Get-PEBlueprint -Name $Name -Version $ToVersion -DataRoot $DataRoot
    $ops = @{ Missing = 'Added'; TargetOnly = 'Removed'; Changed = 'Changed' }
    foreach ($finding in @(Compare-PEState -Blueprint $to -Target $from | Where-Object { $ops.ContainsKey([string]$_.Kind) }))
    {
        [pscustomobject]@{ Op = $ops[[string]$finding.Kind]; ResourceType = [string]$finding.ResourceType; Key = [string]$finding.Key }
    }
}
