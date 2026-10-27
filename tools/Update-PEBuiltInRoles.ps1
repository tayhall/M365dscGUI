<#
.SYNOPSIS
    Refreshes the list of built-in Entra roles in src\PolicyEngine\Data\BuiltInResources.psd1 from Graph.
.DESCRIPTION
    Entra: reads /directoryRoleTemplates with the Reader app, Microsoft's own list of built-in roles (same ids in every
    tenant; custom roles are never in it). Shows what was added, removed or renamed and rewrites the Ids of
    AADRoleDefinition. Intune built-in roles need no list: DSC exports IsBuiltIn. Run it
    when Microsoft adds roles; a role missing from a list is still compared in full, so a stale list only means a little
    more noise. -WhatIf shows the change without writing.
.EXAMPLE
    pwsh -NoProfile -File tools\Update-PEBuiltInRoles.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param ()

$ErrorActionPreference = 'Stop'
$file = Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\BuiltInResources.psd1'
$data = Import-PowerShellDataFile -Path $file

$app = Get-Content (Join-Path $HOME '.m365dsc-policy\M365DSC-Policy-Reader.json') -Raw | ConvertFrom-Json
Import-Module Microsoft.Graph.Authentication -WarningAction SilentlyContinue
Connect-MgGraph -ClientId $app.ApplicationId -TenantId $app.TenantId -CertificateThumbprint $app.Thumbprint -NoWelcome -ErrorAction Stop

function Read-GraphPages
{
    param ([string]$Uri)
    while ($Uri)
    {
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri
        $page.value
        $Uri = $page.'@odata.nextLink'
    }
}

function Update-IdBlock
{
    # Rewrites the Ids = @{ ... } block of "<Type> = @{" in the data file; returns nothing when the list is unchanged.
    param ([string]$Type, [System.Collections.Specialized.OrderedDictionary]$Pairs, [int]$MinimumCount)

    if ($Pairs.Count -lt $MinimumCount) { throw "Only $($Pairs.Count) built-in $Type entries came back; refusing to overwrite the list." }
    $current = $data[$Type].Ids
    $new = @($Pairs.Keys | Sort-Object)
    $old = @($current.Keys | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $newLower = @($new | ForEach-Object { $_.ToLowerInvariant() })
    $added = @($new | Where-Object { $old -notcontains $_.ToLowerInvariant() })
    $removed = @($old | Where-Object { $newLower -notcontains $_ })
    $renamed = @($new | Where-Object { $old -contains $_.ToLowerInvariant() -and $current[$_] -cne $Pairs[$_] })
    "${Type}: $($new.Count) built-in (was $($old.Count)); added $($added.Count), removed $($removed.Count), renamed $($renamed.Count)"
    $added | ForEach-Object { "  + $_ $($Pairs[$_])" }
    $removed | ForEach-Object { "  - $_" }
    $renamed | ForEach-Object { "  ~ $_ $($current[$_]) -> $($Pairs[$_])" }
    if ($added.Count -eq 0 -and $removed.Count -eq 0 -and $renamed.Count -eq 0) { return }

    $text = [IO.File]::ReadAllText((Resolve-Path $file))
    $typeStart = $text.IndexOf("    $Type = @{")
    $start = $text.IndexOf('@{', $text.IndexOf('Ids', $typeStart))
    $end = $text.IndexOf("`n        }", $start) + 1
    $block = '@{' + "`n" + (($new | ForEach-Object { "            '{0}' = '{1}'" -f ($_ -replace "'", "''"), ($Pairs[$_] -replace "'", "''") }) -join "`n") + "`n        "
    if ($PSCmdlet.ShouldProcess($file, "Rewrite $($new.Count) built-in $Type entries"))
    {
        [IO.File]::WriteAllText((Resolve-Path $file), $text.Substring(0, $start) + $block + $text.Substring($end), [Text.UTF8Encoding]::new($false))
    }
}

# Entra: id -> name
$entra = [ordered]@{}
foreach ($template in @(Read-GraphPages -Uri 'https://graph.microsoft.com/v1.0/directoryRoleTemplates'))
{
    $entra[([string]$template.id).ToLowerInvariant()] = [string]$template.displayName
}
Update-IdBlock -Type 'AADRoleDefinition' -Pairs $entra -MinimumCount 50
