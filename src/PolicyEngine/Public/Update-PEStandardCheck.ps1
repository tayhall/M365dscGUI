function Update-PEStandardCheck
{
    <#
    .SYNOPSIS
    After decisions changed (a risk accepted or removed): saves a new Standard check equal to the tenant's latest one of the standard, with
    the findings compared again. No tenant is read. Returns the new CheckId.

    .DESCRIPTION
    The saved tenant state is compared with the same version of the standard (Compare-PEState -Subset) and the current decisions. The
    new check keeps the coverage and the export time of the old one; State.Meta.PatchedFrom says where it came from. A real
    Invoke-PEStandardCheck replaces it. The earlier check is not changed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Tenant,

        [Parameter(Mandatory)]
        [string]$StandardName,

        [string]$DataRoot
    )

    $root = Get-PEDataRoot -Override $DataRoot
    $check = Get-PECheck -Latest -Kind Standard -Standard $StandardName -Tenant $Tenant -DataRoot $root
    $standard = Get-PEBlueprint -Name $StandardName -Version ([string][int]$check.StandardVersion) -DataRoot $root
    $decisions = @(Get-PEStandardDecision -Tenant $Tenant -StandardName $StandardName -DataRoot $root)
    $findings = @(Compare-PEState -Blueprint $standard -Target $check.State -Decisions $decisions -Subset)

    $meta = [ordered]@{}
    foreach ($property in $check.State.Meta.PSObject.Properties)
    {
        $meta[$property.Name] = $property.Value
    }
    $meta['PatchedFrom'] = [string]$check.CheckId
    $meta['PatchedAt'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    $moment = [datetime]::UtcNow
    while ($moment.ToString('yyyyMMdd-HHmmss') -le [string]$check.CheckId -or (Test-Path -LiteralPath (Join-Path $root ('checks\' + $moment.ToString('yyyyMMdd-HHmmss')))))
    {
        $moment = $moment.AddSeconds(1)
    }
    $checkId = $moment.ToString('yyyyMMdd-HHmmss')

    $document = [ordered]@{}
    foreach ($property in $check.PSObject.Properties)
    {
        $document[$property.Name] = $property.Value
    }
    $document['CheckId'] = $checkId
    $document['Findings'] = $findings
    $document['State'] = [ordered]@{ Records = @($check.State.Records); NotChecked = @($check.State.NotChecked); Meta = $meta }
    Write-PEJsonNew -Path (Join-Path $root "checks\$checkId\result.json") -InputObject $document
    return $checkId
}
