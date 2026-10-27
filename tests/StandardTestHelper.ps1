# Shared by the standard tests (dot-sourced in BeforeAll): a tenant blueprint for the asd-mini fixture, and a fake git.

function New-TestTenantBlueprint
{
    # A tenant blueprint to compare with the asd-mini standard: the named location with the given countries (when wanted), an object the
    # standard does not define, and optionally a type the blueprint has no data for (NotChecked). Written as version 1 of -Name.
    # The tenant follows it as the master blueprint (Invoke-PEStandardCheck -BlueprintName <Name>).
    param ([string]$Root, [string]$Name = 'main', [string[]]$Countries = @('AU', 'NZ'), [switch]$NoNamedLocation, [switch]$TeamsNotChecked, [switch]$SecondDifference)
    $records = [System.Collections.Generic.List[object]]::new()
    if (-not $NoNamedLocation)
    {
        $properties = [ordered]@{
            CountriesAndRegions               = @($Countries)
            CountryLookupMethod               = $(if ($SecondDifference) { 'authenticatorAppGps' } else { 'clientIpAddress' })
            DisplayName                       = 'Allowed Countries'
            Ensure                            = 'Present'
            IncludeUnknownCountriesAndRegions = $false
            OdataType                         = '#microsoft.graph.countryNamedLocation'
        }
        $records.Add([pscustomobject]@{ ResourceType = 'AADNamedLocationPolicy'; Key = 'Allowed Countries'; Workload = 'Entra ID'; TenantId = 't'; Properties = $properties })
    }
    $records.Add([pscustomobject]@{ ResourceType = 'AADNamedLocationPolicy'; Key = 'Other'; Workload = 'Entra ID'; TenantId = 't'; Properties = [ordered]@{ DisplayName = 'Other'; Ensure = 'Present'; IpRanges = '2.2.2.2/32'; IsTrusted = $true } })
    $notChecked = @(if ($TeamsNotChecked) { [pscustomobject]@{ ResourceType = 'TeamsMessagingPolicy'; Reason = 'access denied' } })
    $state = & (Get-Module PolicyEngine) {
        param ($r, $n)
        New-PEState -Records $r -NotChecked $n -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z'; Source = 'test' }
    } $records.ToArray() $notChecked
    Initialize-PEBlueprint -Name $Name -State $state -DataRoot $Root | Out-Null
}
function New-FakeGit
{
    # A fake git: records every argument list, answers ls-remote with the given tags, and on a sparse checkout fills the DSC folder
    # from the fixture. -FailOn makes the call whose first argument matches return exit code 128.
    param ([string[]]$Tags = @('v1.3.13', 'v1.4.0', 'v1.4.0-rc', 'preview'), [string]$FailOn)
    $calls = [System.Collections.Generic.List[object]]::new()
    $fixture = $script:Fixture
    $git = {
        param ($Arguments)
        $calls.Add(@($Arguments))
        $verb = if ($Arguments[0] -eq '-C') { $Arguments[2] } else { $Arguments[0] }
        if ($FailOn -and $verb -eq $FailOn) { return [pscustomobject]@{ ExitCode = 128; Output = @('fatal: boom') } }
        switch ($verb)
        {
            'ls-remote'
            {
                $lines = foreach ($tag in $Tags) { "abc123`trefs/tags/$tag"; "def456`trefs/tags/$tag^{}" }
                return [pscustomobject]@{ ExitCode = 0; Output = @($lines) }
            }
            'clone' { New-Item -ItemType Directory -Path $Arguments[-1] -Force | Out-Null }
            'sparse-checkout'
            {
                $target = Join-Path $Arguments[1] ($Arguments[-1] -replace '/', '\')
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                Copy-Item -Path (Join-Path $fixture '*') -Destination $target
            }
        }
        [pscustomobject]@{ ExitCode = 0; Output = @() }
    }.GetNewClosure()
    [pscustomobject]@{ Git = $git; Calls = $calls }
}

