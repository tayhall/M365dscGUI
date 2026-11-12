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
    [string]$OutputPath = (Join-Path $PSScriptRoot '..'),
    # The one list of workloads (Prefix, Name, Default); the export and compare pipelines get one checkbox per entry.
    [string]$WorkloadsPath = (Join-Path $PSScriptRoot '..\..\src\PolicyEngine\Data\Workloads.psd1')
)

$ErrorActionPreference = 'Stop'
$pipelines = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath

# Setting name -> token in the YAML.
$tokens = [ordered]@{
    Pool                    = '__POOL__'
    DevServiceConnection    = '__DEV_SERVICE_CONNECTION__'
    PreProdServiceConnection = '__PREPROD_SERVICE_CONNECTION__'
    RepoFolder              = '__REPO_FOLDER__'
    DevEnvironment          = '__DEV_ENVIRONMENT__'
    ExportPreProdPipeline   = '__EXPORT_PREPROD_PIPELINE__'
    ExportDevPipeline       = '__EXPORT_DEV_PIPELINE__'
    ComparePipeline         = '__COMPARE_PIPELINE__'
    TenantChangesPipeline   = '__TENANT_CHANGES_PIPELINE__'
    # Only the approved-apply pipeline uses these three; the others generate without them.
    ExportPreProdPipelineId = '__EXPORT_PREPROD_PIPELINE_ID__'
    ExportDevPipelineId     = '__EXPORT_DEV_PIPELINE_ID__'
    DefaultBranch           = '__DEFAULT_BRANCH__'
    # Not a setting: built below from the two export pipeline ids, for the Tenant-Changes pipeline (it finds the runs itself at run time).
    TenantMap               = '__TENANT_MAP__'
}
$defaults = @{
    RepoFolder            = 'M365dscGUI'
    DevEnvironment        = 'm365-dev'
    ExportPreProdPipeline = 'M365DSC - Export PreProd tenant'
    ExportDevPipeline     = 'M365DSC - Export Dev tenant'
    ComparePipeline       = 'M365DSC - Compare PreProd to Dev and build MOFs'
    TenantChangesPipeline = 'M365DSC - Tenant changes'
    DefaultBranch         = 'main'
}
# Settings with no default that a template may leave unused: needed (and checked) only by the templates that contain their token.
$optional = @('ExportPreProdPipelineId', 'ExportDevPipelineId', 'TenantMap')

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
# Earlier versions had one ServiceConnection for both tenants. It still works as the default for whichever of the two is not set.
if ($kept.ContainsKey('ServiceConnection'))
{
    foreach ($specific in 'DevServiceConnection', 'PreProdServiceConnection') { if (-not $kept.ContainsKey($specific)) { $kept[$specific] = $kept['ServiceConnection'] } }
    Write-Warning 'ServiceConnection (one for both tenants) is used for any tenant without its own DevServiceConnection / PreProdServiceConnection.'
    $kept.Remove('ServiceConnection')
}
$settings = $kept
if ($settings.ContainsKey('TenantMap')) { throw 'TenantMap is not a setting: it is built from ExportDevPipelineId and ExportPreProdPipelineId.' }
$unknown = @($settings.Keys | Where-Object { -not $tokens.Contains($_) })
if ($unknown) { throw "Unknown setting(s): $($unknown -join ', '). Known: $($tokens.Keys -join ', ')." }

$values = @{}
$problems = @()
foreach ($name in $tokens.Keys)
{
    $value = if ($settings.ContainsKey($name)) { [string]$settings[$name] } else { [string]$defaults[$name] }
    if (-not $value -and $optional -contains $name) { continue }
    if (-not $value) { $problems += "$name is missing"; continue }
    if ($value -match 'CHANGE-ME') { $problems += "$name still has the example value (CHANGE-ME)"; continue }
    if ($value -match '[\r\n]') { $problems += "$name must be one line"; continue }
    # The folder of this project inside the repo, with forward slashes ('.' when the project is at the repo root): no '..', no drive or leading slash.
    if ($name -eq 'RepoFolder' -and $value -cnotmatch '\A(\.|[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*)\z') { $problems += "$name must be a folder path such as M365dscGUI or tools/M365dscGUI (forward slashes), or . for the repo root"; continue }
    # Pipeline (definition) ids are digits; the branch is a plain branch name (it ends up in a command line).
    if ($name -in 'ExportPreProdPipelineId', 'ExportDevPipelineId' -and $value -cnotmatch '\A\d{1,9}\z') { $problems += "$name must be the number of the pipeline (digits only, from its address in Azure DevOps)"; continue }
    if ($name -eq 'DefaultBranch' -and $value -cnotmatch '\A[A-Za-z0-9._/-]{1,100}\z') { $problems += "$name must be a branch name such as main"; continue }
    # The value goes inside a single-quoted YAML string.
    $values[$name] = $value -replace "'", "''"
}
if ($problems) { throw "Fix $SettingsPath first:`n  $($problems -join "`n  ")" }
# The tenant map is only there when both ids are (the ids were checked to be digits above).
if ($values.ContainsKey('ExportDevPipelineId') -and $values.ContainsKey('ExportPreProdPipelineId'))
{
    $values['TenantMap'] = "Dev=$($values['ExportDevPipelineId']);PreProd=$($values['ExportPreProdPipelineId'])"
}

# The workload checkboxes: a token alone on a line in a template is replaced by one entry per workload of Workloads.psd1.
# Names and prefixes end up inside single-quoted YAML strings and names of variables, so they are checked here.
if (-not (Test-Path -LiteralPath $WorkloadsPath)) { throw "No workload list at $WorkloadsPath." }
$workloadList = @((Import-PowerShellDataFile -Path $WorkloadsPath).Workloads)
if ($workloadList.Count -eq 0) { throw "No workloads in $WorkloadsPath." }
foreach ($w in $workloadList)
{
    if ([string]$w.Prefix -cnotmatch '\A[A-Za-z0-9]+\z') { throw "A workload Prefix in $WorkloadsPath must be letters and digits only (got '$($w.Prefix)')." }
    if ([string]$w.Name -match '[
]') { throw "The Name of workload $($w.Prefix) in $WorkloadsPath must be one line." }
}
function Get-WorkloadParameterLines
{
    param ([string]$LabelPrefix)
    foreach ($w in $workloadList)
    {
        $label = ($LabelPrefix + $w.Name + ' (' + $w.Prefix + ')') -replace "'", "''"
        "- name: $($w.Prefix)"
        "  displayName: '$label'"
        '  type: boolean'
        "  default: $(if ($w.Default) { 'true' } else { 'false' })"
    }
}
$expansions = [ordered]@{
    # The values of the workload picker of the export and Tenant-Changes pipelines: Full (the default workloads) and each workload by prefix.
    '__WORKLOAD_CHOICES__'             = @('- Full') + @($workloadList | ForEach-Object { "- $($_.Prefix)" })
    '__COMPLETE_WORKLOAD_PARAMETERS__' = @(Get-WorkloadParameterLines -LabelPrefix 'Complete in the Dev export: ')
    '__WORKLOAD_ENV__'                 = @($workloadList | ForEach-Object { "PE_WL_$($_.Prefix): `${{ parameters.$($_.Prefix) }}" })
}

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath

# Only the files this script generates are written (X.yaml from X.yaml.template); nothing in the output folder is deleted.
$sources = @(Get-ChildItem -LiteralPath $pipelines -Filter '*.yaml.template' -File)
if ($sources.Count -eq 0) { throw "No *.yaml.template files in $pipelines." }
$failed = @()
foreach ($file in $sources)
{
    $text = [IO.File]::ReadAllText($file.FullName)
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    foreach ($token in $expansions.Keys)
    {
        # The whole token line becomes the expanded lines, each with the token line's own indentation.
        $lines = $expansions[$token]
        $text = [regex]::Replace($text, "(?m)^([ 	]*)$token[ 	]*(?=?$)", { param ($m) ($lines | ForEach-Object { $m.Groups[1].Value + $_ }) -join $eol })
    }
    foreach ($name in $tokens.Keys) { if ($values.ContainsKey($name)) { $text = $text.Replace($tokens[$name], $values[$name]) } }
    $left = [regex]::Matches($text, '__[A-Z][A-Z_]*__') | ForEach-Object { $_.Value } | Sort-Object -Unique
    if ($left)
    {
        # One template that cannot be filled does not stop the others from being written; the problems are reported at the end.
        $needs = @($optional | Where-Object { $left -contains $tokens[$_] } | ForEach-Object { if ($_ -eq 'TenantMap') { 'ExportDevPipelineId'; 'ExportPreProdPipelineId' } else { $_ } } | Select-Object -Unique)
        $failed += $(if ($needs) { "$($file.Name) needs the setting(s) $($needs -join ', ') in $SettingsPath (the number of each export pipeline, from its address in Azure DevOps)." }
            else { "$($file.Name) still has token(s) $($left -join ', '): add them to the token table in this script." })
        continue
    }
    $targetName = $file.Name -replace '\.template$', ''
    $text = "# Generated from $($file.Name) by scripts/New-PipelineYaml.ps1. Change the template or the settings and generate again, not this file.`n" + $text
    [IO.File]::WriteAllText((Join-Path $OutputPath $targetName), $text, [Text.UTF8Encoding]::new($false))
    "wrote $targetName"
}
if ($failed) { throw "Not written:`n  $($failed -join "`n  ")" }
"Done: the pipeline YAML is in $OutputPath. Create the pipelines in Azure DevOps from these *.yaml files."
