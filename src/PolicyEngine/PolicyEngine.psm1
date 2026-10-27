$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public))
{
    . $file.FullName
}

# Export every function defined at the top level of the Public files.
$exports = foreach ($file in $public)
{
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    $ast.FindAll({ param ($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false).Name
}

Export-ModuleMember -Function @($exports)
