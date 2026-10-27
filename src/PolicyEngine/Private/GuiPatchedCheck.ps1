function New-PEPatchedCheck
{
    # After a clean apply and re-check: saves a new Full check equal to the old one, minus the findings that were fixed,
    # with the records of the fixed objects set to what was applied. ExportedAt stays the old export time (the rest of
    # the tenant has not been re-read); Meta.PatchedFrom says where it came from. A real full check replaces it.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        $Check,

        [Parameter(Mandatory)]
        [object[]]$Plan,

        [Parameter(Mandatory)]
        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $touched = {
        param ($entry)
        [bool](@($Plan | Where-Object { [string]$_.ResourceType -ieq [string]$entry.ResourceType -and [string]$_.Key -ieq [string]$entry.Key }).Count)
    }
    $findings = @(@($Check.Findings) | Where-Object { -not (& $touched $_) })
    $records = @(@($Check.State.Records) | Where-Object { -not (& $touched $_) })
    foreach ($item in $Plan | Where-Object { $_.Action -in 'Create', 'Update' })
    {
        $records += [pscustomobject]@{ ResourceType = [string]$item.ResourceType; Key = [string]$item.Key; Workload = [string]$item.Workload; Properties = $item.Record.Properties }
    }

    $meta = [ordered]@{}
    foreach ($property in $Check.State.Meta.PSObject.Properties)
    {
        $meta[$property.Name] = $property.Value
    }
    $meta['PatchedFrom'] = [string]$Check.CheckId
    $meta['PatchedAt'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    $moment = [datetime]::UtcNow
    while ($moment.ToString('yyyyMMdd-HHmmss') -le [string]$Check.CheckId -or (Test-Path -LiteralPath (Join-Path $root ('checks\' + $moment.ToString('yyyyMMdd-HHmmss')))))
    {
        $moment = $moment.AddSeconds(1)
    }
    $checkId = $moment.ToString('yyyyMMdd-HHmmss')
    $document = [ordered]@{}
    foreach ($property in $Check.PSObject.Properties)
    {
        $document[$property.Name] = $property.Value
    }
    $document['CheckId'] = $checkId
    $document['Findings'] = @($findings)
    $document['State'] = [ordered]@{ Records = @($records); NotChecked = @($Check.State.NotChecked); Meta = $meta }
    Write-PEJson -Path (Join-Path $root "checks\$checkId\result.json") -InputObject $document
    return $checkId
}
