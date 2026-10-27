BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\asd-mini'

    . "$PSScriptRoot\StandardTestHelper.ps1"
}

Describe 'Standard releases' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-release-' + [guid]::NewGuid())
    }

    AfterEach {
        if (Test-Path $script:Temp) { Remove-Item $script:Temp -Recurse -Force }
    }

    Context 'Get-PEStandardLatestTag' {
        It 'takes the highest vX.Y.Z tag and ignores peeled lines and other tags' {
            $fake = New-FakeGit
            Get-PEStandardLatestTag -Standard asd -Git $fake.Git | Should -Be 'v1.4.0'
            $fake.Calls[0][0] | Should -Be 'ls-remote'
        }

        It 'compares versions as numbers, not text' {
            $fake = New-FakeGit -Tags @('v1.9.0', 'v1.10.0', 'v1.2.9')
            Get-PEStandardLatestTag -Standard asd -Git $fake.Git | Should -Be 'v1.10.0'
        }

        It 'throws when no release tag exists, or the standard is unknown' {
            { Get-PEStandardLatestTag -Standard asd -Git (New-FakeGit -Tags @('preview')).Git } | Should -Throw '*No release tag*'
            { Get-PEStandardLatestTag -Standard nist -Git (New-FakeGit).Git } | Should -Throw "*Unknown standard 'nist'*"
        }
    }

    Context 'Save-PEStandardRelease' {
        It 'refuses a tag that is not vX.Y.Z before it calls git' {
            foreach ($tag in 'v1.4', 'main', 'v1.4.0; calc', '--upload-pack=x', '')
            {
                $fake = New-FakeGit
                { Save-PEStandardRelease -Standard asd -Tag $tag -DataRoot $script:Temp -Git $fake.Git } | Should -Throw
                $fake.Calls.Count | Should -Be 0
            }
        }

        It 'clones only the DSC folder, with exactly these arguments' {
            $fake = New-FakeGit
            $release = Save-PEStandardRelease -Standard asd -Tag v1.4.0 -DataRoot $script:Temp -Git $fake.Git
            $clone = Join-Path $script:Temp 'sources\asd-v1.4.0'
            $fake.Calls[0] | Should -Be @('clone', '--depth', '1', '--branch', 'v1.4.0', '--filter=blob:none', '--sparse', 'https://github.com/ASD-Blueprint/ASD-Blueprint-for-Secure-Cloud.git', $clone)
            $fake.Calls[1] | Should -Be @('-C', $clone, 'sparse-checkout', 'set', 'static/content/files/automation/dsc')
            $release.Tag | Should -Be 'v1.4.0'
            $release.Path | Should -Be (Join-Path $clone 'static\content\files\automation\dsc')
            $release.SourceName | Should -Be 'ASD Blueprint for Secure Cloud'
            Test-Path (Join-Path $release.Path 'Entra.txt') | Should -BeTrue
        }

        It 'does not clone again when the folder exists' {
            $fake = New-FakeGit
            Save-PEStandardRelease -Standard asd -Tag v1.4.0 -DataRoot $script:Temp -Git $fake.Git | Out-Null
            Save-PEStandardRelease -Standard asd -Tag v1.4.0 -DataRoot $script:Temp -Git $fake.Git | Out-Null
            @($fake.Calls | Where-Object { $_[0] -eq 'clone' }).Count | Should -Be 1
        }

        It 'throws a message that names the failing step' {
            { Save-PEStandardRelease -Standard asd -Tag v1.4.0 -DataRoot $script:Temp -Git (New-FakeGit -FailOn clone).Git } | Should -Throw '*git clone*'
        }
    }

    Context 'Import-PEStandardRelease' {
        It 'imports the latest release when no tag is given' {
            $fake = New-FakeGit
            $summary = Import-PEStandardRelease -Standard asd -DataRoot $script:Temp -Git $fake.Git -WarningAction SilentlyContinue 6>$null
            $summary.Total | Should -Be 5
            $summary.SourceVersion | Should -Be 'v1.4.0'
            (Get-PEStandard -Name asd -DataRoot $script:Temp).Attribution | Should -BeLike '*Australian Signals Directorate*'
        }

        It 'imports from a folder that is already there without calling git' {
            $fake = New-FakeGit
            $summary = Import-PEStandardRelease -Standard asd -Tag v1.4.0 -Path $script:Fixture -DataRoot $script:Temp -Git $fake.Git -WarningAction SilentlyContinue 6>$null
            $summary.Total | Should -Be 5
            $fake.Calls.Count | Should -Be 0
            { Import-PEStandardRelease -Standard asd -Path $script:Fixture -DataRoot $script:Temp -Git $fake.Git } | Should -Throw '*needs -Tag*'
        }

        It 'imports a named tag' {
            $fake = New-FakeGit
            (Import-PEStandardRelease -Standard asd -Tag v1.3.13 -DataRoot $script:Temp -Git $fake.Git -WarningAction SilentlyContinue 6>$null).SourceVersion | Should -Be 'v1.3.13'
        }
    }
}
