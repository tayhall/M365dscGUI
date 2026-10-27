<#
.SYNOPSIS
Creates, drifts and removes the PE-DEMO-* objects used to demo the drift engine on a dummy tenant.

.DESCRIPTION
Uses the Writer app (certificate auth, ~\.m365dsc-policy\M365DSC-Policy-Writer.json) and direct Graph calls. Run it
only against a tenant you can afford to change.
  Setup    creates group PE-DEMO-Finance, group PE-DEMO-Sales and the report-only, memberless Conditional Access policy
           PE-DEMO-CA-ReportOnly (cannot block anyone). Take the blueprint after this.
  Drift    changes the tenant away from that blueprint: edits PE-DEMO-Sales (description), disables the CA policy,
           deletes PE-DEMO-Finance and adds PE-DEMO-Rogue.
  Cleanup  deletes every PE-DEMO-* group (and purges them from the recycle bin) and the CA policy.

.EXAMPLE
pwsh -NoProfile -File tools\PEDemoTenant.ps1 -Action Setup
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)]
    [ValidateSet('Setup', 'Drift', 'Cleanup')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$app = Get-Content (Join-Path $HOME '.m365dsc-policy\M365DSC-Policy-Writer.json') -Raw | ConvertFrom-Json
Import-Module Microsoft.Graph.Authentication -WarningAction SilentlyContinue
Connect-MgGraph -ClientId $app.ApplicationId -TenantId $app.TenantId -CertificateThumbprint $app.Thumbprint -NoWelcome -ErrorAction Stop

$policyName = 'PE-DEMO-CA-ReportOnly'

function Get-DemoGroup
{
    param ([string]$Name)
    $filter = [uri]::EscapeDataString("displayName eq '$Name'")
    @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$filter").value)
}

function New-DemoGroup
{
    param ([string]$Name, [string]$Description)
    if (Get-DemoGroup -Name $Name)
    {
        Write-Host "exists   group $Name"
        return
    }
    $body = @{ displayName = $Name; mailNickname = ($Name -replace '[^A-Za-z0-9]', ''); mailEnabled = $false; securityEnabled = $true; description = $Description }
    Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Body ($body | ConvertTo-Json) -ContentType 'application/json' | Out-Null
    Write-Host "created  group $Name"
}

function Get-DemoPolicy
{
    @((Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies').value | Where-Object { $_.displayName -eq $policyName })
}

switch ($Action)
{
    'Setup'
    {
        New-DemoGroup -Name 'PE-DEMO-Finance' -Description 'Policy engine demo: finance'
        New-DemoGroup -Name 'PE-DEMO-Sales' -Description 'Policy engine demo: sales'
        if (Get-DemoPolicy)
        {
            Write-Host "exists   policy $policyName"
        }
        else
        {
            # A new group can take a few seconds to show up in a filtered read.
            $found = @()
            for ($try = 0; $try -lt 12 -and $found.Count -eq 0; $try++)
            {
                $found = @(Get-DemoGroup -Name 'PE-DEMO-Sales')
                if ($found.Count -eq 0) { Start-Sleep -Seconds 5 }
            }
            if ($found.Count -eq 0) { throw 'PE-DEMO-Sales is not readable yet; run Setup again.' }
            $sales = $found[0].id
            $body = @{
                displayName   = $policyName
                state         = 'enabledForReportingButNotEnforced'
                conditions    = @{ users = @{ includeGroups = @($sales) }; applications = @{ includeApplications = @('All') }; clientAppTypes = @('all') }
                grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
            }
            Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json' | Out-Null
            Write-Host "created  policy $policyName"
        }
    }
    'Drift'
    {
        $sales = @(Get-DemoGroup -Name 'PE-DEMO-Sales')
        if ($sales) { Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/groups/$($sales[0].id)" -Body (@{ description = 'Edited outside the policy engine' } | ConvertTo-Json) -ContentType 'application/json' | Out-Null; Write-Host 'changed  group PE-DEMO-Sales (description)' }
        $policy = @(Get-DemoPolicy)
        if ($policy) { Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($policy[0].id)" -Body (@{ state = 'disabled' } | ConvertTo-Json) -ContentType 'application/json' | Out-Null; Write-Host "changed  policy $policyName (disabled)" }
        $finance = @(Get-DemoGroup -Name 'PE-DEMO-Finance')
        if ($finance) { Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$($finance[0].id)" | Out-Null; Write-Host 'deleted  group PE-DEMO-Finance' }
        New-DemoGroup -Name 'PE-DEMO-Rogue' -Description 'Not in the blueprint'
    }
    'Cleanup'
    {
        foreach ($name in 'PE-DEMO-Finance', 'PE-DEMO-Sales', 'PE-DEMO-Rogue')
        {
            foreach ($group in Get-DemoGroup -Name $name)
            {
                Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)" | Out-Null
                Write-Host "deleted  group $name"
            }
        }
        foreach ($policy in Get-DemoPolicy)
        {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($policy.id)" | Out-Null
            Write-Host "deleted  policy $policyName"
        }
        $deleted = @((Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.group').value | Where-Object { $_.displayName -like 'PE-DEMO-*' })
        foreach ($group in $deleted)
        {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/directory/deletedItems/$($group.id)" | Out-Null
            Write-Host "purged   group $($group.displayName)"
        }
    }
}
