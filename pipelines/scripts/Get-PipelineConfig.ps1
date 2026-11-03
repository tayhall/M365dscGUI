<#
.SYNOPSIS
    Reads and validates the config file of an environment (pipelines\config\<Environment>.psd1) and returns it as a hashtable.
.DESCRIPTION
    The files hold identifiers only (tenant domain, Key Vault name, short name, application ids), never a secret: certificates stay in Key
    Vault and the thumbprint is taken from the certificate. The file is read as data (Import-PowerShellDataFile runs no code). Only the
    keys below are allowed, each value must match its pattern, and a value that still says CHANGE-ME is refused, so a typo or a pasted
    secret stops the run instead of reaching a script. -Require names the keys the caller needs.
.EXAMPLE
    $config = & .\Get-PipelineConfig.ps1 -Environment Dev -Require TenantDomain, KeyVault, ShortName, ReaderAppId
#>
param
(
    [Parameter(Mandatory)]
    [ValidateSet('Dev', 'PreProd')]
    [string]$Environment,

    [string[]]$Require = @(),

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config')
)

$ErrorActionPreference = 'Stop'

# Key -> pattern its value must match (whole value, no newlines).
$rules = [ordered]@{
    TenantDomain     = '\A[A-Za-z0-9][A-Za-z0-9.-]{0,200}\.[A-Za-z]{2,}\z'
    OrganizationName = '\A[A-Za-z0-9][A-Za-z0-9.-]{0,200}\.[A-Za-z]{2,}\z'
    KeyVault         = '\A[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]\z'
    ShortName        = '\A[A-Za-z0-9-]{1,24}\z'
    ReaderAppId      = '\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z'
    WriterAppId      = '\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z'
}

$path = Join-Path $ConfigPath "$Environment.psd1"
if (-not (Test-Path -LiteralPath $path)) { throw "No config file at $path." }
$data = Import-PowerShellDataFile -Path $path

$unknown = @($data.Keys | Where-Object { -not $rules.Contains($_) })
if ($unknown) { throw "$Environment.psd1 has setting(s) that are not allowed: $($unknown -join ', '). Allowed: $($rules.Keys -join ', '). (Secrets never go in this file.)" }

$problems = @()
foreach ($key in $Require) { if (-not $rules.Contains($key)) { throw "Unknown required setting '$key'." } }
foreach ($key in $rules.Keys)
{
    $required = $Require -contains $key
    if (-not $data.ContainsKey($key)) { if ($required) { $problems += "$key is missing" }; continue }
    $value = [string]$data[$key]
    if ($value -match 'CHANGE-ME') { if ($required) { $problems += "$key still says CHANGE-ME" }; continue }
    if ($value -cnotmatch $rules[$key]) { $problems += "$key does not look right (a value of the wrong kind?)"; continue }
}
if ($problems) { throw "Fix $path first:`n  $($problems -join "`n  ")" }

$result = @{}
foreach ($key in $data.Keys) { $result[$key] = [string]$data[$key] }
$result
