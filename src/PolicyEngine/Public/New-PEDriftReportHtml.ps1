function New-PEDriftReportHtml
{
    <#
    .SYNOPSIS
    Writes the drift report as one self-contained HTML file (inline CSS and JavaScript, no network, works from file://).

    .DESCRIPTION
    -Data is the object of Get-PEDriftReportData. It is embedded as JSON in <script type="application/json" id="report-data"> with
    every <, > and & written as a \u escape (and U+2028 / U+2029 too), so no tenant value can close the script block, start a
    comment or inject markup. The page script (Data\DriftReport.js) and the template are read from the module's Data folder.
    The file is UTF-8 without a BOM, LF line endings, and an existing file is never overwritten. Returns the path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [object]$Data,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Title = 'Drift report: PreProd to Dev'
    )

    foreach ($required in 'Meta', 'Totals', 'Items')
    {
        if (-not $Data.PSObject.Properties[$required]) { throw "The report data has no $required (expected the object from Get-PEDriftReportData)." }
    }
    if (Test-Path -LiteralPath $Path) { throw "Drift report ${Path}: already exists; it is not overwritten." }

    $dataFolder = Join-Path $PSScriptRoot '..\Data'
    $template = [System.IO.File]::ReadAllText((Join-Path $dataFolder 'DriftReport.template.html'))
    $script = [System.IO.File]::ReadAllText((Join-Path $dataFolder 'DriftReport.js'))
    if ($script -match '(?i)</script') { throw 'DriftReport.js must not contain a closing script tag.' }

    $json = ConvertTo-Json -InputObject $Data -Depth 12 -Compress
    $slashU = [string][char]92 + 'u'
    $json = $json.Replace('<', $slashU + '003c').Replace('>', $slashU + '003e').Replace('&', $slashU + '0026').Replace([string][char]0x2028, $slashU + '2028').Replace([string][char]0x2029, $slashU + '2029')
    $encodedTitle = [System.Net.WebUtility]::HtmlEncode($Title)

    # One pass over the template, so text inside the inserted pieces is never scanned for placeholders.
    $values = @{ TITLE = $encodedTitle; DATA = $json; SCRIPT = $script.TrimEnd() }
    $html = [regex]::Replace($template, '__PE_(TITLE|DATA|SCRIPT)__', { param ($m) $values[$m.Groups[1].Value] })
    $html = $html -replace "`r`n", "`n"

    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $html, [System.Text.UTF8Encoding]::new($false))
    (Resolve-Path -LiteralPath $Path).ProviderPath
}
