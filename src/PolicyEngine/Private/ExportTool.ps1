function Get-PEExportToolArgument
{
    # The argument list for running tools\Export-M365DscTenant.ps1 in a child pwsh with -File. `pwsh -File` binds one
    # string per parameter value (an array becomes separate positional arguments, so 'Intune' would land in -Role), so
    # the workloads go as ONE comma-joined string; the tool splits it.
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$Workloads,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$Tenant = 'master'
    )

    $tool = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\Export-M365DscTenant.ps1'
    $arguments = [string[]]@('-NoProfile', '-File', $tool, '-Workloads', ($Workloads -join ','), '-OutputPath', $OutputPath)
    if ($Tenant -ne 'master') { $arguments += @('-Tenant', $Tenant) }
    return $arguments
}

# Set by the GUI worker around a job (Invoke-PEGuiRequest): a script block that returns $true when the user cancelled the job.
# The wait below calls it about twice a second, so a long export can be stopped.
$script:PEJobCancelCheck = $null

function Invoke-PEExportToolProcess
{
    # Runs the export tool in a child pwsh (this installation's) that shares this console, so its output still shows; throws on
    # a non-zero exit code. While it runs, $script:PEJobCancelCheck is asked whether the job was cancelled: if so the child and
    # everything it started are stopped and an OperationCanceledException is thrown.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    $info = [System.Diagnostics.ProcessStartInfo]::new((Get-PERectifyPwshPath))
    foreach ($argument in $ArgumentList) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($info)
    try
    {
        while (-not $process.WaitForExit(500))
        {
            if ($script:PEJobCancelCheck -and (& $script:PEJobCancelCheck))
            {
                $process.Kill($true)
                $process.WaitForExit()
                throw [System.OperationCanceledException]::new('Cancelled by request.')
            }
        }
    }
    finally
    {
        # Also when the caller is stopped (Ctrl+C in the worker): never leave an export running behind it.
        if (-not $process.HasExited) { $process.Kill($true) }
    }
    if ($process.ExitCode -ne 0)
    {
        throw "Export failed with exit code $($process.ExitCode)."
    }
}

function Split-PEExportComponent
{
    # Splits DSC component names into the ones one export process can read together (Main) and the ones of a workload that needs
    # a process of its own (Isolated, Data\Workloads.psd1 OwnProcess). The order inside each list is kept.
    [CmdletBinding()]
    param
    (
        [string[]]$Component
    )

    $prefixes = @(Get-PEOwnProcessPrefix)
    $main = [System.Collections.Generic.List[string]]::new()
    $isolated = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($Component | Where-Object { $_ }))
    {
        $own = $false
        foreach ($prefix in $prefixes)
        {
            if ($name.StartsWith($prefix, [System.StringComparison]::Ordinal) -and $name.Length -gt $prefix.Length -and [char]::IsUpper($name[$prefix.Length])) { $own = $true }
        }
        if ($own) { $isolated.Add($name) } else { $main.Add($name) }
    }
    [pscustomobject]@{ Main = [string[]]$main.ToArray(); Isolated = [string[]]$isolated.ToArray() }
}

function Merge-PEExportPart
{
    # Puts the resources of a second export (a folder with export.ps1 and export.log, taken in its own process) into the main
    # export folder: the resource blocks go into the Node block of the main export.ps1 and the part's export.log is appended,
    # so everything that reads an export folder sees one export. Both files must be in the layout Microsoft365DSC writes (a
    # `Node localhost` block closed by the end of the configuration), and the merged file must hold exactly the resource
    # blocks of the two files together; otherwise it throws and nothing is changed.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$PartPath,

        # The name of the export file in both folders.
        [string]$FileName = 'export.ps1'
    )

    $mainFile = Join-Path $Path $FileName
    $partFile = Join-Path $PartPath $FileName
    $mainText = Get-Content -LiteralPath $mainFile -Raw
    $partText = Get-Content -LiteralPath $partFile -Raw
    $shape = '(?s)\A(?<head>.*?\r?\n[ ]{4}Node localhost\r?\n[ ]{4}\{\r?\n)(?<body>.*)(?<tail>\r?\n[ ]{4}\}\r?\n\}\r?\n.*)\z'
    $main = [regex]::Match($mainText, $shape)
    $part = [regex]::Match($partText, $shape)
    if (-not $main.Success -or -not $part.Success)
    {
        throw "The export is not in the layout Microsoft365DSC writes (a 'Node localhost' block closed by the end of the configuration); the parts of ${Path} were not merged."
    }
    $blockPattern = '(?m)^[ ]{8}[A-Za-z0-9]+ "[^"]*"[ ]*\r?$'
    $expected = [regex]::Matches($mainText, $blockPattern).Count + [regex]::Matches($partText, $blockPattern).Count
    $newline = if ($mainText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $mainBody = $main.Groups['body'].Value
    $merged = $main.Groups['head'].Value + $(if ($mainBody.Trim().Length -gt 0) { $mainBody + $newline }) + $part.Groups['body'].Value + $main.Groups['tail'].Value
    if ([regex]::Matches($merged, $blockPattern).Count -ne $expected)
    {
        throw "Merging the export of ${PartPath} into ${Path} would lose resources; nothing was merged."
    }

    $temp = "$mainFile.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temp, $merged, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($temp, $mainFile, $true)
    $partLog = Join-Path $PartPath 'export.log'
    if (Test-Path -LiteralPath $partLog -PathType Leaf)
    {
        Add-Content -LiteralPath (Join-Path $Path 'export.log') -Value (Get-Content -LiteralPath $partLog -Raw) -Encoding utf8
    }
}

function Test-PEExportPartFailed
{
    # Whether the export in a folder reports failed components ("Failed exports: {N}" with N above 0 in its export.log).
    # Microsoft365DSC exits 0 either way, and after one failed connect it skips every later resource of that workload
    # ("failed earlier in this session"), so one timeout in the Security and Compliance process loses the rest of it.
    # A missing log or summary counts as failed: the export did not finish.
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [string]$PartPath
    )

    $log = Join-Path $PartPath 'export.log'
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return $true }
    $match = [regex]::Match((Get-Content -LiteralPath $log -Raw), 'Failed exports: \{(?<n>\d+)\}')
    return (-not $match.Success) -or ([int]$match.Groups['n'].Value -gt 0)
}

function Remove-PEExportPart
{
    # Deletes the folder of a part that has been merged. The merge is done and the export is complete, so failing to delete a
    # temporary folder must never fail the export: a file that was just written is often held for a moment by antivirus or the
    # search indexer (seen after a 10 minute Security and Compliance export), so it is tried again, and if it still cannot be
    # removed the folder is left and a warning says so. Returns whether it was removed.
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [string]$PartPath,

        [int]$Attempts = 10,

        [int]$DelayMilliseconds = 1000
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++)
    {
        try
        {
            Remove-Item -LiteralPath $PartPath -Recurse -Force -ErrorAction Stop
            return $true
        }
        catch
        {
            if ($attempt -lt $Attempts)
            {
                Start-Sleep -Milliseconds $DelayMilliseconds
            }
            else
            {
                Write-Warning "The merged part folder was not removed ($($_.Exception.Message)); it is harmless and can be deleted by hand: $PartPath"
            }
        }
    }
    return $false
}