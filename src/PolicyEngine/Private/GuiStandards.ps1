# The view models of standards for the web GUI (gui\README.md). Everything is read from the engine's own data (standard.json, coverage files,
# Standard checks, decisions, blueprints): nothing is recomputed that the engine already says. Written by Export-PEGuiData.

function ConvertTo-PEGuiStandardRow
{
    # One row per Missing or Changed finding of a Standard check. Other kinds (NotChecked and so on) are not rows: they are counted in
    # the headline as not readable, never as differences and never as matching.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Finding,

        # itemId -> source version of the standard it was adopted from, for the items the tenant's own blueprint adopted.
        [Parameter(Mandatory)]
        [hashtable]$Adopted
    )

    $itemId = ConvertTo-PEGuiItemId -ResourceType ([string]$Finding.ResourceType) -Key ([string]$Finding.Key)
    $accepted = [string]$Finding.State -eq 'Accepted'
    $stale = [bool]$Finding.AcceptanceStale
    $status = if ($accepted) { 'accepted' } elseif ($stale) { 'lookAgain' } elseif ([string]$Finding.Kind -eq 'Missing') { 'missing' } else { 'differs' }
    $values = {
        param ($list)
        @(foreach ($difference in @($list | Where-Object { $null -ne $_ })) { [ordered]@{ property = [string]$difference.Property; standard = $difference.Blueprint; tenant = $difference.Target } })
    }
    $isAdopted = $Adopted.ContainsKey($itemId)
    $actions = switch ($status)
    {
        'accepted' { @('RemoveRisk') }
        'lookAgain' { @('Adopt', 'AcceptRisk', 'RemoveRisk') }
        default { @('Adopt', 'AcceptRisk') }
    }
    if ($isAdopted)
    {
        $actions = @($actions | Where-Object { $_ -ne 'Adopt' })
    }
    $property = { param ($name) if ($Finding.PSObject.Properties[$name]) { $Finding.$name } else { $null } }
    [ordered]@{
        itemId              = $itemId
        resourceType        = [string]$Finding.ResourceType
        key                 = [string]$Finding.Key
        workload            = [string]$Finding.Workload
        kind                = [string]$Finding.Kind
        status              = $status
        # @(): a scriptblock's single result would be unrolled into an object, and an empty one into null; the page needs arrays.
        differences         = @(& $values $Finding.Differences)
        acceptedDifferences = @(& $values $Finding.AcceptedDifferences)
        approvedBy          = & $property 'ApprovedBy'
        acceptedReason      = & $property 'AcceptedReason'
        acceptedAt          = & $property 'AcceptedAt'
        hint                = $(if ($Finding.Hint) { [string]$Finding.Hint } else { $null })
        adopted             = $isAdopted
        adoptedFrom         = $(if ($isAdopted) { $Adopted[$itemId] } else { $null })
        allowedActions      = @($actions)
    }
}

function Get-PEGuiStandardTenantView
{
    # The view of one tenant against one standard: { standard, tenantId, checked } and, when checked, the headline, the per-workload
    # table, the adoption line and the rows.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Standard,

        [Parameter(Mandatory)]
        [string]$TenantSlug,

        [Parameter(Mandatory)]
        [string]$MasterBlueprint,

        [Parameter(Mandatory)]
        [int]$LatestVersion,

        [Parameter(Mandatory)]
        [string]$DataRoot
    )

    $check = $null
    try { $check = Get-PECheck -Latest -Kind Standard -Standard $Standard -Tenant $TenantSlug -DataRoot $DataRoot } catch { $check = $null }
    if ($null -eq $check)
    {
        return [ordered]@{ standard = $Standard; tenantId = $TenantSlug; checked = $false }
    }

    $own = @(Get-PETenantBlueprint -Tenant $TenantSlug -MasterBlueprint $MasterBlueprint -DataRoot $DataRoot)[-1]
    $adoption = @(Get-PEStandardAdoption -Standard $Standard -Blueprint $own -DataRoot $DataRoot)
    $adopted = @{}
    foreach ($entry in $adoption | Where-Object Adopted)
    {
        $adopted[(ConvertTo-PEGuiItemId -ResourceType $entry.ResourceType -Key $entry.Key)] = [string]$entry.SourceVersion
    }

    $rows = @(@($check.Findings) | Where-Object { [string]$_.Kind -in 'Missing', 'Changed' } | ForEach-Object { ConvertTo-PEGuiStandardRow -Finding $_ -Adopted $adopted })
    $coverage = $check.Coverage
    $differ = @($rows | Where-Object { $_.status -ne 'accepted' }).Count
    $acceptedCount = @($rows | Where-Object { $_.status -eq 'accepted' }).Count
    $notCovered = [int]$coverage.Total - [int]$coverage.Covered
    $headline = [ordered]@{
        total       = [int]$coverage.Total
        covered     = [int]$coverage.Covered
        checked     = [int]$coverage.Checked
        match       = [Math]::Max(0, [int]$coverage.Checked - $differ - $acceptedCount)
        differ      = $differ
        accepted    = $acceptedCount
        lookAgain   = @($rows | Where-Object { $_.status -eq 'lookAgain' }).Count
        notReadable = [int]$coverage.NotReadable
        notCovered  = $notCovered
    }
    $byReason = [ordered]@{}
    foreach ($reason in $coverage.NotCovered.PSObject.Properties)
    {
        $byReason[$reason.Name] = [int]$reason.Value
    }
    $byWorkload = @(foreach ($workload in $coverage.ByWorkload.PSObject.Properties)
    {
        $figures = $workload.Value
        $workloadRows = @($rows | Where-Object { $_.workload -eq $workload.Name })
        $workloadDiffer = @($workloadRows | Where-Object { $_.status -ne 'accepted' }).Count
        $workloadAccepted = @($workloadRows | Where-Object { $_.status -eq 'accepted' }).Count
        [ordered]@{
            workload    = $workload.Name
            total       = [int]$figures.Total
            checked     = [int]$figures.Checked
            match       = [Math]::Max(0, [int]$figures.Checked - $workloadDiffer - $workloadAccepted)
            differ      = $workloadDiffer
            accepted    = $workloadAccepted
            notReadable = [int]$figures.Covered - [int]$figures.Checked
            notCovered  = [int]$figures.Total - [int]$figures.Covered
        }
    })
    $checkedAt = $check.State.Meta.ExportedAt
    [ordered]@{
        standard             = $Standard
        tenantId             = $TenantSlug
        checked              = $true
        checkId              = [string]$check.CheckId
        checkedAt            = $(if ($checkedAt -is [datetime]) { $checkedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$checkedAt })
        standardVersion      = [int]$check.StandardVersion
        sourceVersion        = [string]$check.SourceVersion
        patched              = [bool]($check.State.Meta.PSObject.Properties['PatchedFrom'] -and $check.State.Meta.PatchedFrom)
        newerVersionImported = $LatestVersion -gt [int]$check.StandardVersion
        headline             = $headline
        notCoveredByReason   = $byReason
        byWorkload           = $byWorkload
        adoption             = [ordered]@{ blueprint = $own; adopted = @($adoption | Where-Object Adopted).Count; covered = $adoption.Count }
        rows                 = @($rows)
    }
}

function Export-PEGuiStandardData
{
    # Writes standards\index.json, standards\<name>\coverage.json and tenants\<id>\standards\<name>.json. A standard or a tenant that cannot be
    # read is a warning: it never stops the rest of the export.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Tenant,

        [Parameter(Mandatory)]
        [string]$MasterBlueprint,

        [Parameter(Mandatory)]
        [string]$DataRoot,

        # The atomic writer of Export-PEGuiData: called with a path relative to the GUI folder and an object.
        [Parameter(Mandatory)]
        [scriptblock]$Write
    )

    $standards = @(Get-PEStandard -DataRoot $DataRoot)
    $index = @(foreach ($standard in $standards)
    {
        $versions = @($standard.Versions | ForEach-Object { [ordered]@{ version = [int]$_.Version; sourceVersion = [string]$_.SourceVersion; importedAt = [string]$_.ImportedAt; total = [int]$_.Total; covered = [int]$_.Covered } })
        $release = $null
        $releasePath = Join-Path $DataRoot ('sources\' + $standard.Name + '-latest.json')
        if (Test-Path -LiteralPath $releasePath -PathType Leaf)
        {
            try
            {
                $found = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json -DateKind String
                $release = [ordered]@{ tag = [string]$found.tag; checkedAt = [string]$found.checkedAt }
            }
            catch { Write-Warning "The latest release of standard '$($standard.Name)' could not be read: $($_.Exception.Message)" }
        }
        [ordered]@{
            name          = $standard.Name
            sourceName    = $standard.SourceName
            sourceUrl     = $standard.SourceUrl
            license       = $standard.License
            attribution   = $standard.Attribution
            versions      = $versions
            latest        = $(if ($versions.Count) { $versions[-1] } else { $null })
            latestRelease = $release
        }
    })
    & $Write 'standards/index.json' $index

    foreach ($standard in $standards)
    {
        $name = [string]$standard.Name
        try
        {
            $latest = @($standard.Versions)[-1]
            $rows = @(Get-PEStandardCoverage -Name $name -DataRoot $DataRoot)
            $byReason = [ordered]@{}
            foreach ($group in $rows | Group-Object Reason) { $byReason[$group.Name] = $group.Count }
            & $Write "standards/$name/coverage.json" ([ordered]@{
                    standard      = $name
                    version       = [int]$latest.Version
                    sourceVersion = [string]$latest.SourceVersion
                    total         = [int]$latest.Total
                    covered       = [int]$latest.Covered
                    byReason      = $byReason
                    rows          = @($rows | ForEach-Object { [ordered]@{ resourceType = [string]$_.ResourceType; key = [string]$_.Key; workload = [string]$_.Workload; reason = [string]$_.Reason; detail = [string]$_.Detail } })
                })
            foreach ($entry in $Tenant)
            {
                $slug = [string]$entry.Slug
                try
                {
                    & $Write "tenants/$slug/standards/$name.json" (Get-PEGuiStandardTenantView -Standard $name -TenantSlug $slug -MasterBlueprint $MasterBlueprint -LatestVersion ([int]$latest.Version) -DataRoot $DataRoot)
                }
                catch { Write-Warning "Standard '$name' for tenant '$slug' was not exported: $($_.Exception.Message)" }
            }
        }
        catch { Write-Warning "Standard '$name' was not exported: $($_.Exception.Message)" }
    }
}
