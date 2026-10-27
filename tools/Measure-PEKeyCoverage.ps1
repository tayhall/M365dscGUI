<#
.SYNOPSIS
Measures key coverage of a Microsoft365DSC export. Prints a per-type table; writes nothing to the repo.

.DESCRIPTION
Parses the export, normalises every record and tabulates per ResourceType: records, Unkeyed, distinct keys and
Ambiguous (records sharing a key). Singleton ('(singleton)') records are keyed. The last section lists the types
that still have Ambiguous groups (the allow-list that tests/KeyCoverage.Tests.ps1 checks against).

.PARAMETER Path
Path to full-export.ps1.

.PARAMETER PassThru
Also return the per-type rows as objects.
#>
[CmdletBinding()]
param
(
    [string]$Path = (Join-Path $PSScriptRoot '..\data\exports\first-full-reader\full-export.ps1'),

    [switch]$PassThru
)

Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force
$rows = & (Get-Module PolicyEngine) {
    param ($ExportPath)
    $records = @(Read-PEExport -Path $ExportPath | ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ })
    foreach ($group in ($records | Group-Object ResourceType | Sort-Object Name))
    {
        $seen = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $unkeyed = 0
        foreach ($record in $group.Group)
        {
            if ([string]::IsNullOrEmpty($record.Key))
            {
                $unkeyed++
                continue
            }
            $count = 0
            [void]$seen.TryGetValue($record.Key, [ref]$count)
            $seen[$record.Key] = $count + 1
        }
        $ambiguousGroups = 0
        $ambiguousRecords = 0
        foreach ($count in $seen.Values)
        {
            if ($count -gt 1)
            {
                $ambiguousGroups++
                $ambiguousRecords += $count
            }
        }
        [pscustomobject]@{
            ResourceType     = $group.Name
            Records          = $group.Count
            Unkeyed          = $unkeyed
            DistinctKeys     = $seen.get_Count()
            AmbiguousGroups  = $ambiguousGroups
            AmbiguousRecords = $ambiguousRecords
        }
    }
} $Path

$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$total = [pscustomobject]@{
    Records          = ($rows | Measure-Object Records -Sum).Sum
    Unkeyed          = ($rows | Measure-Object Unkeyed -Sum).Sum
    AmbiguousRecords = ($rows | Measure-Object AmbiguousRecords -Sum).Sum
}
Write-Host "TOTAL records=$($total.Records) unkeyed=$($total.Unkeyed) ambiguousRecords=$($total.AmbiguousRecords)"
Write-Host 'Ambiguous allow-list (types):'
$rows | Where-Object { $_.AmbiguousGroups -gt 0 } | ForEach-Object { Write-Host "  $($_.ResourceType)" }

if ($PassThru)
{
    $rows
}
