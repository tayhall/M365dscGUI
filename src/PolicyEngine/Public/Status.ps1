function Get-PEStatus
{
    # Per-workload status. Aligned + Drifted can exceed Total because TargetOnly objects are not blueprint records. Total = blueprint records. Drifted = distinct (type,key) among Open Missing, Changed,
    # TargetOnly, PossibleRename and Ambiguous findings. TargetOnly (Open) is also reported in its own column, because
    # such objects are not blueprint records. Aligned = Total - distinct blueprint records that are drifted or unkeyed,
    # never below zero (only blueprint-side findings, i.e. with a BlueprintRecord, and blueprint records of NotChecked or
    # NotAvailable types are subtracted). Unmanaged findings are only counted under Unmanaged. NotChecked = distinct resource types that
    # were NotChecked or NotAvailable. Excluded = distinct resource types with an Excluded finding (Data\ExcludedTypes.psd1):
    # their blueprint records are left out of Total, Aligned and Drifted (the findings decide, so a compare run with
    # -IncludeTypes counts those types normally). For a type with a RecordRule (EXOManagementRoleEntry) only the records
    # the rule excludes are left out, evaluated on the blueprint as Compare-PEState does. Workloads with no records and
    # no findings are omitted.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Blueprint,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Findings = @()
    )

    $Findings = @($Findings | Where-Object { $null -ne $_ })

    # Types the comparison excluded: their records were never compared, so they are not counted at all.
    $excludedTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($finding in $Findings)
    {
        if ($finding.Kind -eq 'Excluded' -and -not [string]::IsNullOrEmpty([string]$finding.ResourceType))
        {
            [void]$excludedTypes.Add([string]$finding.ResourceType)
        }
    }

    $order = @('Entra ID', 'Intune', 'Exchange Online', 'Teams', 'Security and Compliance', 'Other')
    $stats = @{}
    $get = {
        param ($name)
        if (-not $stats.ContainsKey($name))
        {
            $stats[$name] = @{
                Total = 0; Blueprint = [System.Collections.Generic.HashSet[string]]::new(); Drifted = [System.Collections.Generic.HashSet[string]]::new()
                TargetOnly = [System.Collections.Generic.HashSet[string]]::new(); Unmanaged = [System.Collections.Generic.HashSet[string]]::new()
                Unkeyed = [System.Collections.Generic.HashSet[string]]::new(); BpUnkeyed = [System.Collections.Generic.HashSet[string]]::new(); Records = [System.Collections.Generic.List[object]]::new(); AmbIdx = [System.Collections.Generic.HashSet[int]]::new(); Types = [System.Collections.Generic.HashSet[string]]::new()
                Excluded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }
        $stats[$name]
    }

    # The exclusion entries of the excluded types (a type the data file no longer lists is excluded whole).
    $exclusion = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($excludedTypes.Count -gt 0)
    {
        $map = Get-PEExcludedTypeMap
        foreach ($type in $excludedTypes)
        {
            $exclusion[$type] = if ($map.ContainsKey($type)) { $map[$type] } else { [pscustomobject]@{ Reason = $null; RecordRule = $null } }
        }
    }
    $counted = (Select-PEComparedRecord -Records @($Blueprint.Records) -Excluded $exclusion).Kept

    foreach ($record in $counted)
    {
        $name = if ($record.Workload) { $record.Workload } else { Get-PEWorkload -ResourceType $record.ResourceType }
        $s = & $get $name
        $s.Total++
        $s.Records.Add(@{ Type = $record.ResourceType; Index = $s.Records.Count; Id = "$($record.ResourceType)|$($record.Key)"; HasKey = ($null -ne $record.Key); Key = $record.Key })
    }

    $n = 0
    foreach ($finding in @($Findings))
    {
        $name = if ($finding.Workload) { $finding.Workload } else { Get-PEWorkload -ResourceType $finding.ResourceType }
        $s = & $get $name
        $n++
        # A null key (Unkeyed) gets a unique identity per finding so each is counted.
        $id = if ($null -eq $finding.Key) { "$($finding.ResourceType)|#$n" } else { "$($finding.ResourceType)|$($finding.Key)" }

        switch ($finding.Kind)
        {
            { $_ -in 'NotChecked', 'NotAvailable' } { [void]$s.Types.Add($finding.ResourceType); continue }
            'Excluded' { [void]$s.Excluded.Add($finding.ResourceType); continue }
        }
        if ($finding.Kind -in 'NotChecked', 'NotAvailable', 'Excluded')
        {
            continue
        }

        if ($finding.State -eq 'Unmanaged')
        {
            [void]$s.Unmanaged.Add($id)
            continue
        }

        if ($finding.Kind -eq 'Unkeyed')
        {
            [void]$s.Unkeyed.Add($id)
            if ($finding.BlueprintRecord)
            {
                [void]$s.BpUnkeyed.Add($id)
            }
            continue
        }

        if ($finding.Kind -in 'Missing', 'Changed', 'TargetOnly', 'PossibleRename', 'Ambiguous')
        {
            [void]$s.Drifted.Add($id)
            if ($finding.Kind -eq 'Ambiguous')
            {
                # Blueprint-side only (BlueprintCount > 0): every blueprint record matching type+key (case-insensitive).
                if ($finding.BlueprintCount -gt 0)
                {
                    foreach ($r in $s.Records)
                    {
                        if ($r.HasKey -and $r.Type -eq $finding.ResourceType -and $r.Key -eq $finding.Key)
                        {
                            [void]$s.AmbIdx.Add($r.Index)
                        }
                    }
                }
            }
            elseif ($finding.Kind -eq 'TargetOnly')
            {
                [void]$s.TargetOnly.Add($id)
            }
            elseif ($finding.BlueprintRecord)
            {
                # Only blueprint-side findings reduce Aligned; Ambiguous is handled above through BlueprintCount.
                [void]$s.Blueprint.Add($id)
            }
        }
    }

    foreach ($name in $order)
    {
        if (-not $stats.ContainsKey($name))
        {
            continue
        }

        $s = $stats[$name]
        # Blueprint records of a type that was not checked were never compared, so they are not aligned either.
        $notChecked = 0
        foreach ($r in $s.Records)
        {
            if ($s.Types.Contains($r.Type) -and -not $s.AmbIdx.Contains($r.Index) -and -not ($r.HasKey -and $s.Blueprint.Contains($r.Id)))
            {
                $notChecked++
            }
        }
        $notAligned = $s.Blueprint.Count + $s.BpUnkeyed.Count + $s.AmbIdx.Count + $notChecked
        [pscustomobject]@{
            Workload   = $name
            Total      = $s.Total
            Aligned    = [Math]::Max(0, $s.Total - $notAligned)
            Drifted    = $s.Drifted.Count
            TargetOnly = $s.TargetOnly.Count
            Unmanaged  = $s.Unmanaged.Count
            Unkeyed    = $s.Unkeyed.Count
            NotChecked = $s.Types.Count
            Excluded   = $s.Excluded.Count
        }
    }
}

function Format-PEStatus
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Status,

        [datetime]$LastFullCheck
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $table = @($Status | Select-Object Workload, Total, Aligned, Drifted, TargetOnly, Unmanaged, Unkeyed, @{ n = 'NotChecked (types)'; e = { $_.NotChecked } }, @{ n = 'Excluded (types)'; e = { $_.Excluded } } |
            Format-Table -AutoSize | Out-String -Width 200)
    foreach ($line in (($table -join '') -split "`r?`n"))
    {
        if ($line.Trim())
        {
            $lines.Add($line.TrimEnd())
        }
    }

    $lines.Add('TargetOnly items are not blueprint records, so Aligned + Drifted can exceed Total.')

    if ($PSBoundParameters.ContainsKey('LastFullCheck'))
    {
        # A [datetime] of Kind Unspecified is treated as UTC (not local time).
        $utc = if ($LastFullCheck.Kind -eq 'Unspecified') { [datetime]::SpecifyKind($LastFullCheck, 'Utc') } else { $LastFullCheck.ToUniversalTime() }
        $age = [datetime]::UtcNow - $utc
        $minutes = [int][Math]::Max(0, [Math]::Floor($age.TotalMinutes))
        $text = 'Last full check: {0} h {1} min ago ({2:yyyy-MM-dd HH:mm} UTC)' -f [Math]::Floor($minutes / 60), ($minutes % 60), $utc
        if ($age.TotalHours -gt 36)
        {
            $text += ' - STALE'
        }
        $lines.Add($text)
    }
    else
    {
        $lines.Add('Last full check: never')
    }

    $lines -join [Environment]::NewLine
}
