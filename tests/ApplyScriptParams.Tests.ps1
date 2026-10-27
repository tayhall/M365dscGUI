Describe 'Invoke-PEApply.ps1 parameters' {
    It 'accepts the app file of the tenant that Invoke-PERectify passes for a replica (-AppInfoPath)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\tools\Invoke-PEApply.ps1'), [ref]$null, [ref]$null)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Contain 'AppInfoPath'
        $source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\src\PolicyEngine\Private\InvokeRectify.ps1')
        $source | Should -Match "'-AppInfoPath'"
    }
}
