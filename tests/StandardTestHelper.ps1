# Shared by the standard tests (dot-sourced in BeforeAll): a fake tenant export for the asd-mini fixture.

function New-TenantExport
{
    # A fake tenant export: the named location with the given countries (when given), an object the standard does not
    # define, and a log that says whether TeamsMessagingPolicy exported (Ok, empty) or failed.
    param ([string]$Root, [string]$Countries = '@("AU")', [switch]$TeamsFails, [switch]$NoNamedLocation)
    $check = [string][char]0x2705
    $cross = [string][char]0x274C
    $folder = Join-Path $Root ('export-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $named = ''
    if (-not $NoNamedLocation)
    {
        $named = @"
        AADNamedLocationPolicy "AADNamedLocationPolicy-Allowed Countries"
        {
            CountriesAndRegions               = $Countries;
            CountryLookupMethod               = "clientIpAddress";
            DisplayName                       = "Allowed Countries";
            Ensure                            = "Present";
            IncludeUnknownCountriesAndRegions = `$False;
            OdataType                         = "#microsoft.graph.countryNamedLocation";
        }
"@
    }
    @"
Configuration export
{
    Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '2.26.1021.1'
    Node localhost
    {
$named
        AADNamedLocationPolicy "AADNamedLocationPolicy-Other"
        {
            DisplayName = "Other";
            Ensure      = "Present";
            IpRanges    = "2.2.2.2/32";
            IsTrusted   = `$True;
            OdataType   = "#microsoft.graph.ipNamedLocation";
        }
    }
}
"@ | Set-Content -LiteralPath (Join-Path $folder 'export.ps1') -Encoding utf8
    $teamsLine = if ($TeamsFails) { "[2/2] Extracting [TeamsMessagingPolicy] using {CertificateThumbprint}...`n    |---[1/1] Global$cross`n    An error occurred while exporting resource {TeamsMessagingPolicy}: access denied" } else { "[2/2] Extracting [TeamsMessagingPolicy] using {CertificateThumbprint}...$check" }
    @"
Exporting Microsoft 365 configuration for Components: AADNamedLocationPolicy, TeamsMessagingPolicy

Starting export in sequential mode...
[1/2] Extracting [AADNamedLocationPolicy] using {CertificateThumbprint}...$check
$teamsLine
"@ | Set-Content -LiteralPath (Join-Path $folder 'export.log') -Encoding utf8
    return $folder
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

