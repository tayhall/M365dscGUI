function New-PEStateFromExport
{
    <#
    .SYNOPSIS
    Builds a State from an export folder (export.ps1 + export.log), with failed components in NotChecked. Used to
    create a blueprint from a full export (tools\New-PEBlueprint.ps1).

    .DESCRIPTION
    Same rules as Invoke-PEFullCheck, without a blueprint to compare with: the records are read with Read-PEExport and
    normalised (ConvertTo-PENormalizedRecord, so ignored properties such as ids and credentials are removed), and every
    component that export.log reports as Failed or Incomplete goes to NotChecked with its reason. Records of a Failed or
    Incomplete component are dropped, because they cannot be trusted.

    export.log is required: without it a failed component cannot be told from an empty one, and a blueprint taken from
    such an export would later report real objects as TargetOnly. Pass -AllowMissingLog to accept that (Meta.ExportLog
    is then 'missing').

    Meta: TenantId (default: the Reader app's TenantId), ExportedAt (the export file's write time, UTC), Source (the
    export folder), ExportLog ('present' or 'missing') and LogWarnings (parser warnings from Read-PEExportLog).
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$TenantId,

        [switch]$AllowMissingLog
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container))
    {
        throw "Export folder not found: $Path"
    }
    $exportFile = Find-PEExportFile -Path $Path
    $logPath = Join-Path $Path 'export.log'
    $hasLog = Test-Path -LiteralPath $logPath -PathType Leaf
    if (-not $hasLog -and -not $AllowMissingLog)
    {
        throw "No export.log in ${Path}: failed components cannot be told from empty ones. Re-export with tools\Export-M365DscTenant.ps1, or pass -AllowMissingLog."
    }

    if (-not $TenantId)
    {
        $TenantId = Get-PEReaderTenantId
    }
    if (-not $TenantId)
    {
        $TenantId = 'unknown'
    }

    $logWarnings = [System.Collections.Generic.List[string]]::new()
    $entries = if ($hasLog) { @(Read-PEExportLog -Path $logPath -Warnings $logWarnings) } else { @() }
    $notChecked = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries)
    {
        if ($entry.Status -in 'Failed', 'Incomplete')
        {
            if ($failed.Add([string]$entry.ResourceType))
            {
                $notChecked.Add([pscustomobject]@{ ResourceType = [string]$entry.ResourceType; Reason = $entry.Reason })
            }
        }
    }

    $exportedAt = (Get-Item -LiteralPath $exportFile).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $records = @(Read-PEExport -Path $exportFile -TenantId $TenantId |
            ForEach-Object { ConvertTo-PENormalizedRecord -Record $_ -ExportedAt $exportedAt } |
            Where-Object { -not $failed.Contains([string]$_.ResourceType) })

    $meta = @{
        TenantId    = $TenantId
        ExportedAt  = $exportedAt
        Source      = $Path
        ExportLog   = $(if ($hasLog) { 'present' } else { 'missing' })
        LogWarnings = @($logWarnings)
    }
    New-PEState -Records $records -NotChecked @($notChecked) -Meta $meta
}
