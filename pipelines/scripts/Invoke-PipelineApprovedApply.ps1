<#
.SYNOPSIS
    Applies (or only tests) an approved list (approvals\*.json) on Dev: builds the MOF files for exactly the approved items and runs them through the LCM.
.DESCRIPTION
    The whole approved-apply step. Run it from an AzurePowerShell task on the Dev service connection. In this order:
      G9   the run must be on the default branch and the list must be inside the approvals folder, checked before any tenant access
      1    Dev's identifiers come from pipelines\config\Dev.psd1; the Writer certificate's thumbprint is read from Key Vault (nothing is imported yet)
      2    tools\Invoke-PEApprovedBuild.ps1 compiles one MOF per resource type and phase for the approved items only, behind its own guards
           (G1 complete exports, G7 the exports are the ones the list names, G8 the Dev export is not too old). The counts per type and action
           (for example "Create 10 AADGroup") are printed here, and the outcomes the build already knows (NoActionRequired, Skipped, NotGenerated)
      3    the Writer certificate is imported (it must be the one the MOFs were compiled with) and always removed again
      4    the LCM test runs for every configuration first: it is the preview of what will change, not a gate (items about to be created are
           expected not to be in the desired state)
      5    in Apply mode every configuration is applied in order (all Changes, then Removals only with -IncludeRemovals True). The run carries on
           after a failed resource or configuration: it applies what it can and reports what is left
      6    result.json gives every approved item exactly one outcome: Applied, NoActionRequired, NotGenerated, Failed or Skipped. Apply mode ends
           with issues (never green) while any item is not Applied or NoActionRequired; running the same list again finishes the job, because
           what is already in the desired state when the LCM tests it is NoActionRequired. There is no rollback (DSC has none).
    The LCM only runs from Windows PowerShell 5.1, so tools\Invoke-PELcm.ps1 is run with powershell.exe.
#>
param
(
    # The approved list, inside the approvals folder of the project.
    [Parameter(Mandatory)]
    [string]$ListPath,

    # The PreProdExport / DevExport artifact folders of the export runs the list names.
    [Parameter(Mandatory)]
    [string]$PreProdExportPath,

    [Parameter(Mandatory)]
    [string]$DevExportPath,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    # Test (default): only the LCM test, nothing is written to Dev. Apply: changes Dev.
    [ValidateSet('Test', 'Apply')]
    [string]$Mode = 'Test',

    # Approved Remove items are only applied when this is True (G6).
    [ValidateSet('True', 'False')]
    [string]$IncludeRemovals = 'False',

    # G8: the Dev export named in the list must not be older than this.
    [ValidateRange(1, 365)]
    [int]$MaxAgeDays = 7,

    # G9: the branch the run must come from.
    [ValidatePattern('\A[A-Za-z0-9._/-]{1,100}\z')]
    [string]$DefaultBranch = 'main',

    # ---- Test hooks: the defaults are the real scripts. The pipeline never sets these. ----
    [string]$ApprovalsRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'approvals'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config'),
    [string]$BuildScript = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools\Invoke-PEApprovedBuild.ps1'),
    [string]$LcmScript = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools\Invoke-PELcm.ps1'),
    [string]$LcmHost = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),
    [string]$ConnectScript = (Join-Path $PSScriptRoot 'Connect-PipelineTenant.ps1'),
    [string]$DisconnectScript = (Join-Path $PSScriptRoot 'Disconnect-PipelineTenant.ps1')
)

$ErrorActionPreference = 'Stop'
$withRemovals = ($IncludeRemovals -eq 'True')

# G9: only from the default branch, only a list that was committed to the approvals folder. Before any tenant access.
$listFull = & (Join-Path $PSScriptRoot 'Test-ApprovalLocation.ps1') -ListPath $ListPath -ApprovalsRoot $ApprovalsRoot -DefaultBranch $DefaultBranch

# The download task may put the artifact's files straight into the target folder or into a folder named after the artifact: accept both.
$resolveExport = {
    param ([string]$path, [string]$artifact, [string]$label)
    if (Test-Path -LiteralPath (Join-Path $path 'export.ps1')) { return $path }
    $inner = Join-Path $path $artifact
    if (Test-Path -LiteralPath (Join-Path $inner 'export.ps1')) { return $inner }
    throw "No export.ps1 in the $label export download folder $path (or in $inner). Check the download step for the $artifact artifact. Nothing was done."
}
$PreProdExportPath = & $resolveExport $PreProdExportPath 'PreProdExport' 'PreProd'
$DevExportPath = & $resolveExport $DevExportPath 'DevExport' 'Dev'

$dev = & (Join-Path $PSScriptRoot 'Get-PipelineConfig.ps1') -Environment Dev -Require TenantDomain, OrganizationName, WriterAppId -ConfigPath $ConfigPath
$thumbprint = & $ConnectScript -Environment Dev -Role Writer -ThumbprintOnly -ConfigPath $ConfigPath

# The output folder is created by the build, after its guards have held: a run that is stopped leaves nothing behind.
$buildPath = Join-Path $OutputPath 'build'
& $BuildScript -ListPath $listFull -SourceExportPath $PreProdExportPath -TargetExportPath $DevExportPath -TargetTenantDomain $dev.TenantDomain `
    -OutputPath $buildPath -MaxAgeDays $MaxAgeDays -ApplicationId $dev.WriterAppId -CertificateThumbprint $thumbprint -OrganizationName $dev.OrganizationName

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath
$summary = Get-Content -LiteralPath (Join-Path $buildPath 'summary.json') -Raw | ConvertFrom-Json
$outcomes = @(Get-Content -LiteralPath (Join-Path $buildPath 'outcomes.json') -Raw | ConvertFrom-Json)
"Approved list: $(Split-Path $listFull -Leaf); mode $Mode; removals $IncludeRemovals"
'Approved items (the same counts the report showed):'
@($summary.Lines) | ForEach-Object { "  $_" }

# The configurations to run, in order: all Changes, then Removals only when asked for (G6).
$configs = @($summary.Configs | Where-Object { $_.Name -notlike '*-Removals' -or $withRemovals })
$runLcm = {
    param ([string]$mofPath, [string]$lcmMode)
    $output = @(& $LcmHost -NoProfile -File $LcmScript -MofPath $mofPath -Mode $lcmMode 2>&1)
    $exit = $LASTEXITCODE
    $json = $output | Where-Object { "$_" -match '^\s*\{' } | Select-Object -Last 1
    if ($exit -ne 0 -or -not $json) { throw "The LCM step ($lcmMode) did not return a result (exit code $exit). Output:`n$($output -join "`n")" }
    $json | ConvertFrom-Json
}
$configResults = [System.Collections.Generic.List[object]]::new()
$testFailures = [System.Collections.Generic.List[string]]::new()
$testInDesired = @{}

try
{
    if ($configs.Count -gt 0)
    {
        & $ConnectScript -Environment Dev -Role Writer -ExpectedThumbprint $thumbprint -ConfigPath $ConfigPath

        # The preview: every configuration is tested first. Not a gate.
        foreach ($config in $configs)
        {
            $mof = Get-ChildItem -LiteralPath (Join-Path (Join-Path $buildPath 'MOF') $config.Name) -Filter *.mof -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $mof) { throw "No MOF for $($config.Name) in the build output; the build said it generated it." }
            "== Test $($config.Name)"
            try
            {
                $test = & $runLcm $mof.FullName 'Test'
                "In desired state: $(@($test.InDesiredState).Count); not in desired state: $(@($test.NotInDesiredState).Count) (a create is expected to be not in the desired state yet)"
                $testInDesired[[string]$config.ConfigurationName] = @($test.InDesiredState)
                if ($test.Error) { $testFailures.Add("$($config.Name): $($test.Error)") }
            }
            catch { $testFailures.Add("$($config.Name): $($_.Exception.Message)") }
        }

        if ($Mode -eq 'Apply')
        {
            foreach ($config in $configs)
            {
                $mof = Get-ChildItem -LiteralPath (Join-Path (Join-Path $buildPath 'MOF') $config.Name) -Filter *.mof | Select-Object -First 1
                "== Apply $($config.Name)"
                $entry = [pscustomobject]@{ ConfigurationName = [string]$config.ConfigurationName; Ran = $false; Error = $null; InDesiredState = @(); NotInDesiredState = @() }
                try
                {
                    $applied = & $runLcm $mof.FullName 'Apply'
                    $entry.Ran = $true
                    $entry.InDesiredState = @($applied.InDesiredState)
                    $entry.NotInDesiredState = @($applied.NotInDesiredState)
                    if ($applied.Error) { $entry.Error = [string]$applied.Error }
                    "In desired state: $(@($applied.InDesiredState).Count); not in desired state: $(@($applied.NotInDesiredState).Count)"
                    @($applied.NotInDesiredState) | ForEach-Object { "  $($_.ResourceId) $($_.Error)" }
                }
                catch
                {
                    $entry.Error = $_.Exception.Message
                    "  $($config.Name) failed: $($entry.Error)"
                }
                # Carry on with the next configuration: apply what can be applied, then report what is left.
                $configResults.Add($entry)
            }
        }
    }
}
finally
{
    & $DisconnectScript -Slug dev -Role Writer
}

# What the LCM test found already in the desired state travels with each configuration (a stub when nothing was applied).
$byName = @{}
foreach ($entry in $configResults) { $byName[[string]$entry.ConfigurationName] = $entry }
foreach ($config in $configs)
{
    $name = [string]$config.ConfigurationName
    if (-not $byName.ContainsKey($name))
    {
        $stub = [pscustomobject]@{ ConfigurationName = $name; Ran = $false; Error = $null; InDesiredState = @(); NotInDesiredState = @() }
        $configResults.Add($stub)
        $byName[$name] = $stub
    }
    $byName[$name] | Add-Member -NotePropertyName TestInDesiredState -NotePropertyValue @($testInDesired[$name]) -Force
}
$result = & (Join-Path $PSScriptRoot 'Get-ApplyResult.ps1') -Item $outcomes -ConfigResult $configResults.ToArray() -Mode $Mode -IncludeRemovals:$withRemovals
[ordered]@{
    Mode            = $Mode
    IncludeRemovals = $withRemovals
    List            = (Split-Path $listFull -Leaf)
    GeneratedAtUtc  = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    Totals          = $result.Totals
    Complete        = $result.Complete
    Items           = $result.Items
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputPath 'result.json') -Encoding utf8

$t = $result.Totals
'Outcomes: Applied {0}, NoActionRequired {1}, NotGenerated {2}, Failed {3}, Skipped {4}{5} (of {6} approved items)' -f $t.Applied, $t.NoActionRequired, $t.NotGenerated, $t.Failed, $t.Skipped, $(if ($Mode -eq 'Test') { ", would apply $($t.ToApply)" } else { '' }), $t.Items
foreach ($row in @($result.Left)) { "  $($row.Outcome): $($row.Action) $($row.ResourceType) '$($row.Key)'$(if ($row.Reason) { ': ' + $row.Reason })" }

if ($testFailures.Count -gt 0)
{
    $testFailures | ForEach-Object { Write-Host "##vso[task.logissue type=warning]LCM test did not run cleanly: $_" }
}
if ($Mode -eq 'Test')
{
    "Test only: nothing was written to Dev. Run again with mode Apply (behind the environment approval) to apply $($t.ToApply) item(s)."
    if ($testFailures.Count -gt 0) { throw "The LCM test failed for: $($testFailures -join ' | ')" }
}
elseif (-not $result.Complete)
{
    Write-Host '##vso[task.complete result=SucceededWithIssues;]Not every approved item is done: see result.json. Running the same list again only has the rest to do.'
}
else
{
    'Every approved item is Applied or NoActionRequired.'
}
