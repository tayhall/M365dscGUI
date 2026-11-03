<#
.SYNOPSIS
    Writes the pipeline YAML with your environment values filled in, ready to copy into Azure DevOps.
.DESCRIPTION
    The pipelines\*.yaml.template files hold tokens such as __POOL__ instead of real values. This reads pipeline.settings.psd1 (git-ignored;
    start from pipeline.settings.example.psd1), replaces every token and writes the real pipelines\*.yaml next to the templates. Azure DevOps
    does not list the .template files when you pick an existing YAML file, only the generated ones. It stops if a required setting is
    missing or a token is left over, and it never deletes anything.
.EXAMPLE
    pwsh -NoProfile -File pipelines\scripts\New-PipelineYaml.ps1
#>
param
(
    [string]$SettingsPath = (Join-Path $PSScriptRoot '..\pipeline.settings.psd1'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$pipelines = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath

# Setting name -> token in the YAML.
$tokens = [ordered]@{
    Pool                    = '__POOL__'
    ServiceConnection       = '__SERVICE_CONNECTION__'
    RepoFolder              = '__REPO_FOLDER__'
    DevEnvironment          = '__DEV_ENVIRONMENT__'
    ExportPreProdPipeline   = '__EXPORT_PREPROD_PIPELINE__'
    ExportDevPipeline       = '__EXPORT_DEV_PIPELINE__'
    ComparePipeline         = '__COMPARE_PIPELINE__'
}
$defaults = @{
    RepoFolder            = 'M365dscGUI'
    DevEnvironment        = 'm365-dev'
    ExportPreProdPipeline = 'M365DSC - Export PreProd tenant'
    ExportDevPipeline     = 'M365DSC - Export Dev tenant'
    ComparePipeline       = 'M365DSC - Compare PreProd to Dev and build MOFs'
}

if (-not (Test-Path -LiteralPath $SettingsPath))
{
    throw "No settings file at $SettingsPath. Copy pipelines\pipeline.settings.example.psd1 to pipelines\pipeline.settings.psd1 and fill it in."
}
$settings = Import-PowerShellDataFile -Path $SettingsPath
# Earlier versions of this file also held the tenant identifiers. They now live in pipelines\config\<Environment>.psd1, read at run time.
$moved = @($settings.Keys | Where-Object { $_ -match '^(Dev|PreProd)(TenantDomain|OrganizationName|KeyVault|ShortName|ReaderAppId|WriterAppId|ReaderCertSecret|WriterCertSecret|WriterThumbprint)$' })
if ($moved) { Write-Warning "Ignored (these now belong in pipelines\config\Dev.psd1 / PreProd.psd1, and you can delete them here): $($moved -join ', ')" }
$kept = @{}
foreach ($key in $settings.Keys) { if ($key -notin $moved) { $kept[$key] = $settings[$key] } }
$settings = $kept
$unknown = @($settings.Keys | Where-Object { -not $tokens.Contains($_) })
if ($unknown) { throw "Unknown setting(s): $($unknown -join ', '). Known: $($tokens.Keys -join ', ')." }

$values = @{}
$problems = @()
foreach ($name in $tokens.Keys)
{
    $value = if ($settings.ContainsKey($name)) { [string]$settings[$name] } else { [string]$defaults[$name] }
    if (-not $value) { $problems += "$name is missing"; continue }
    if ($value -match 'CHANGE-ME') { $problems += "$name still has the example value (CHANGE-ME)"; continue }
    if ($value -match '[\r\n]') { $problems += "$name must be one line"; continue }
    # The folder of this project inside the repo, with forward slashes ('.' when the project is at the repo root): no '..', no drive or leading slash.
    if ($name -eq 'RepoFolder' -and $value -cnotmatch '\A(\.|[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*)\z') { $problems += "$name must be a folder path such as M365dscGUI or tools/M365dscGUI (forward slashes), or . for the repo root"; continue }
    # The value goes inside a single-quoted YAML string.
    $values[$name] = $value -replace "'", "''"
}
if ($problems) { throw "Fix $SettingsPath first:`n  $($problems -join "`n  ")" }

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath

# Only the files this script generates are written (X.yaml from X.yaml.template); nothing in the output folder is deleted.
$sources = @(Get-ChildItem -LiteralPath $pipelines -Filter '*.yaml.template' -File)
if ($sources.Count -eq 0) { throw "No *.yaml.template files in $pipelines." }
foreach ($file in $sources)
{
    $text = [IO.File]::ReadAllText($file.FullName)
    foreach ($name in $tokens.Keys) { $text = $text.Replace($tokens[$name], $values[$name]) }
    $left = [regex]::Matches($text, '__[A-Z][A-Z_]*__') | ForEach-Object { $_.Value } | Sort-Object -Unique
    if ($left) { throw "$($file.Name) still has token(s) $($left -join ', '): add them to the token table in this script." }
    $targetName = $file.Name -replace '\.template$', ''
    $text = "# Generated from $($file.Name) by scripts/New-PipelineYaml.ps1. Change the template or the settings and generate again, not this file.`n" + $text
    [IO.File]::WriteAllText((Join-Path $OutputPath $targetName), $text, [Text.UTF8Encoding]::new($false))
    "wrote $targetName"
}
"Done: the pipeline YAML is in $OutputPath. Create the pipelines in Azure DevOps from these *.yaml files."
