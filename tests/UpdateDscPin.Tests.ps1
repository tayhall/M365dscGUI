BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\pipelines\scripts\Update-DscPin.ps1'

    function New-PinFile
    {
        param ([string]$NewLine = "`n", [string]$Dsc = '2.26.1104.1', [string]$Graph = '2.41.1')
        $lines = @('@{', '    # Single source for pinned dependency versions.', '    # Always import these modules by explicit version.',
            "    Microsoft365DSC              = '$Dsc'", "    MicrosoftGraphAuthentication = '$Graph'", '}')
        $path = Join-Path ([IO.Path]::GetTempPath()) ('pe-pin-' + [guid]::NewGuid().ToString('N') + '.psd1')
        [IO.File]::WriteAllText($path, ($lines -join $NewLine), [Text.UTF8Encoding]::new($false))
        $path
    }
    # Runs the script in-process (so mocks apply); returns what it printed.
    function Invoke-Pin
    {
        param ([hashtable]$Arguments)
        $out = & $script:Script @Arguments 6>&1 | ForEach-Object { "$_" }
        $out -join "`n"
    }
}

Describe 'pipelines\scripts\Update-DscPin.ps1' {
    BeforeEach { Mock Find-PSResource { [pscustomobject]@{ Name = 'x' } } }

    It 'refuses a version that is not four numbers (<Bad>)' -ForEach @(
        @{ Bad = '2.26' }, @{ Bad = '2.26.1104' }, @{ Bad = 'v2.26.1104.1' }, @{ Bad = '2.26.1104.1; rm' }, @{ Bad = "2.26.1104."+[char]0xFF11 }) {
        $path = New-PinFile
        $before = [IO.File]::ReadAllText($path)
        { Invoke-Pin @{ Version = $Bad; PinPath = $path } } | Should -Throw '*four*'
        Should -Invoke Find-PSResource -Times 0 -Exactly
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }

    It 'refuses a Graph version that is not three numbers, before touching anything' {
        $path = New-PinFile
        $before = [IO.File]::ReadAllText($path)
        { Invoke-Pin @{ Version = '2.26.1105.1'; GraphAuthenticationVersion = '2.41'; PinPath = $path; SkipGalleryCheck = $true } } | Should -Throw '*three*'
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }

    It 'leaves the file untouched and says so when the version is already pinned' {
        $path = New-PinFile
        $before = [IO.File]::ReadAllText($path)
        $text = Invoke-Pin @{ Version = '2.26.1104.1'; PinPath = $path }
        $text | Should -Match 'already'
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }

    It 'changes only the Microsoft365DSC value and keeps comments, the other pin and the line endings' -ForEach @(
        @{ NL = "`n" }, @{ NL = "`r`n" }) {
        $path = New-PinFile -NewLine $NL
        $text = Invoke-Pin @{ Version = '2.26.1105.1'; PinPath = $path }
        $text | Should -Match 'Microsoft365DSC 2\.26\.1104\.1 -> 2\.26\.1105\.1'
        $expected = [IO.File]::ReadAllText((New-PinFile -NewLine $NL)).Replace("'2.26.1104.1'", "'2.26.1105.1'")
        [IO.File]::ReadAllText($path) | Should -BeExactly $expected
        [IO.File]::ReadAllText($path) | Should -Match "MicrosoftGraphAuthentication = '2\.41\.1'"
        [IO.File]::ReadAllText($path).Contains('# Single source for pinned') | Should -BeTrue
    }

    It 'changes the Graph pin only when asked' {
        $path = New-PinFile
        Invoke-Pin @{ Version = '2.26.1104.1'; PinPath = $path } | Out-Null
        (Import-PowerShellDataFile $path).MicrosoftGraphAuthentication | Should -Be '2.41.1'
        $text = Invoke-Pin @{ Version = '2.26.1104.1'; GraphAuthenticationVersion = '2.42.0'; PinPath = $path }
        $text | Should -Match 'Microsoft.Graph.Authentication 2\.41\.1 -> 2\.42\.0'
        $data = Import-PowerShellDataFile $path
        $data.MicrosoftGraphAuthentication | Should -Be '2.42.0'
        $data.Microsoft365DSC | Should -Be '2.26.1104.1'
    }

    It 'the result parses with Import-PowerShellDataFile and has both keys' {
        $path = New-PinFile -NewLine "`r`n"
        Invoke-Pin @{ Version = '2.26.1200.1'; GraphAuthenticationVersion = '2.50.0'; PinPath = $path } | Out-Null
        $data = Import-PowerShellDataFile $path
        $data.Microsoft365DSC | Should -Be '2.26.1200.1'
        $data.MicrosoftGraphAuthentication | Should -Be '2.50.0'
    }

    It 'refuses a version the gallery does not have and changes nothing' {
        Mock Find-PSResource { }
        $path = New-PinFile
        $before = [IO.File]::ReadAllText($path)
        { Invoke-Pin @{ Version = '2.26.1105.1'; PinPath = $path } } | Should -Throw '*PowerShell Gallery*'
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }

    It 'accepts a version the gallery has' {
        $path = New-PinFile
        Invoke-Pin @{ Version = '2.26.1105.1'; PinPath = $path } | Out-Null
        Should -Invoke Find-PSResource -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft365DSC' -and $Version -eq '2.26.1105.1' -and $Repository -eq 'PSGallery' }
        (Import-PowerShellDataFile $path).Microsoft365DSC | Should -Be '2.26.1105.1'
    }

    It 'says it is a downgrade when the new version is lower' {
        $path = New-PinFile
        $text = Invoke-Pin @{ Version = '2.26.1021.1'; PinPath = $path }
        $text | Should -Match 'DOWNGRADE'
        (Import-PowerShellDataFile $path).Microsoft365DSC | Should -Be '2.26.1021.1'
    }

    It 'does not say downgrade for an upgrade' {
        (Invoke-Pin @{ Version = '2.26.1105.1'; PinPath = (New-PinFile) }) | Should -Not -Match 'DOWNGRADE'
    }

    It 'under -CreatePullRequest names the missing Azure DevOps variable and changes nothing' {
        $path = New-PinFile
        $before = [IO.File]::ReadAllText($path)
        $names = 'SYSTEM_ACCESSTOKEN', 'SYSTEM_COLLECTIONURI', 'SYSTEM_TEAMPROJECT', 'BUILD_REPOSITORY_ID'
        $saved = @{}
        foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
        try { { Invoke-Pin @{ Version = '2.26.1105.1'; PinPath = $path; CreatePullRequest = $true } } | Should -Throw '*SYSTEM_ACCESSTOKEN*' }
        finally { foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }

    Context 'with a real git clone and no Azure DevOps (the branch must come from the default branch)' {
        BeforeAll {
            $script:Root = Join-Path ([IO.Path]::GetTempPath()) ('pe-git-' + [guid]::NewGuid().ToString('N'))
            $origin = Join-Path $script:Root 'origin.git'
            $script:Clone = Join-Path $script:Root 'clone'
            New-Item -ItemType Directory -Path $script:Root | Out-Null
            $quiet = { & git @args 2>&1 | Out-Null }
            & $quiet init --bare -b main $origin
            & $quiet clone $origin $script:Clone
            & $quiet -C $script:Clone config user.name t
            & $quiet -C $script:Clone config user.email t@t
            & $quiet -C $script:Clone checkout -b main
            $script:Pin = Join-Path $script:Clone 'Versions.psd1'
            Copy-Item (New-PinFile) $script:Pin
            & $quiet -C $script:Clone add -A
            & $quiet -C $script:Clone commit -m base
            & $quiet -C $script:Clone push origin main
            $script:Quiet = $quiet
            $script:EnvNames = 'SYSTEM_ACCESSTOKEN', 'SYSTEM_COLLECTIONURI', 'SYSTEM_TEAMPROJECT', 'BUILD_REPOSITORY_ID', 'BUILD_REPOSITORY_NAME', 'PE_DEFAULT_BRANCH'
            $script:SavedEnv = @{}
            foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
            # An address nothing listens on: any REST call fails fast instead of reaching a server.
            $values = @{ SYSTEM_ACCESSTOKEN = 'x'; SYSTEM_COLLECTIONURI = 'http://127.0.0.1:9/'; SYSTEM_TEAMPROJECT = 'P'; BUILD_REPOSITORY_ID = 'r'; BUILD_REPOSITORY_NAME = 'R'; PE_DEFAULT_BRANCH = 'main' }
            foreach ($n in $values.Keys) { [Environment]::SetEnvironmentVariable($n, $values[$n]) }
        }
        AfterAll {
            foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) }
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'refuses to run from a commit that is not the tip of origin/main, before any REST call or edit' {
            & $script:Quiet -C $script:Clone checkout -b feature
            Set-Content (Join-Path $script:Clone 'extra.txt') 'x'
            & $script:Quiet -C $script:Clone add -A
            & $script:Quiet -C $script:Clone commit -m extra
            $before = [IO.File]::ReadAllText($script:Pin)
            { Invoke-Pin @{ Version = '2.26.1105.1'; PinPath = $script:Pin; CreatePullRequest = $true } } | Should -Throw '*default branch*origin/main*'
            [IO.File]::ReadAllText($script:Pin) | Should -BeExactly $before
            (& git -C $script:Clone branch --list 'dsc-pin/*') | Should -BeNullOrEmpty
        }

        It 'passes the branch check at the tip of origin/main, and a leftover local branch does not block checkout' {
            & $script:Quiet -C $script:Clone checkout main
            # A leftover local branch of the name, on another commit (a failed earlier push).
            & $script:Quiet -C $script:Clone branch dsc-pin/2.26.1105.1 feature
            $message = try { Invoke-Pin @{ Version = '2.26.1105.1'; PinPath = $script:Pin; CreatePullRequest = $true }; '' } catch { $_.Exception.Message }
            # It gets as far as the push or the REST call (nothing listens there), never the branch refusal or an "already exists".
            $message | Should -Not -Match 'default branch'
            $message | Should -Not -Match 'already exists'
            # The branch was reset to main and the pin commit sits on top of it (not on top of the leftover commit).
            (& git -C $script:Clone rev-parse 'dsc-pin/2.26.1105.1~1') | Should -Be (& git -C $script:Clone rev-parse main)
        }
    }
}
