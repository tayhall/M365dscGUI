Describe 'Module exports' {
    BeforeAll {
        $script:Copy = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-mod-' + [guid]::NewGuid())
        Copy-Item "$PSScriptRoot\..\src\PolicyEngine" $script:Copy -Recurse
        New-Item -ItemType Directory -Path (Join-Path $script:Copy 'Public') -Force | Out-Null
        Set-Content (Join-Path $script:Copy 'Public\Multi.ps1') @'
function Get-PEMultiOne { 'one' }
function Get-PEMultiTwo
{
    function Get-PEMultiNested { 'nested' }
    Get-PEMultiNested
}
'@
        Set-Content (Join-Path $script:Copy 'Public\Get-PETestPublic.ps1') 'function Get-PETestPublic { "pub" }'
        Import-Module (Join-Path $script:Copy 'PolicyEngine.psd1') -Force
    }

    AfterAll {
        Remove-Module PolicyEngine -Force -ErrorAction SilentlyContinue
        Remove-Item $script:Copy -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'exports Public functions' {
        (Get-Command -Module PolicyEngine).Name | Should -Contain 'Get-PETestPublic'
    }

    It 'exports every function in a multi-function Public file but not nested ones' {
        $names = (Get-Command -Module PolicyEngine).Name
        $names | Should -Contain 'Get-PEMultiOne'
        $names | Should -Contain 'Get-PEMultiTwo'
        $names | Should -Not -Contain 'Get-PEMultiNested'
    }

    It 'does not export Private functions' {
        (Get-Command -Module PolicyEngine).Name | Should -Not -Contain 'Write-PEJson'
    }
}
