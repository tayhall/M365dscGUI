function Invoke-PETenantAppsProcess
{
    # Runs tools\New-PETenantApps.ps1 in a child pwsh and follows its output while it runs, so the device-code prompt reaches
    # the GUI (through -Progress) long before the script ends. Returns @{ ExitCode; Result; Output } where Result is the
    # script's final JSON line (or $null). A thin wrapper so tests can replace it; the real sign-in cannot run unattended.
    # The output is read by polling (ReadLineAsync): a script block used as a .NET event handler runs on a thread without a
    # runspace and takes the whole host down.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidatePattern('(?-i)\A[a-z0-9][a-z0-9-]{0,39}\z')]
        [string]$Slug,

        [Parameter(Mandatory)]
        [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z')]
        [string]$TenantDomain,

        [string]$DisplayName,

        [switch]$NoWriter,

        [string[]]$WriterRoles = @(),

        [scriptblock]$Progress,

        [ValidateRange(1, 60)]
        [int]$TimeoutMinutes = 20,

        # Tests run a stand-in script here; the default is the real tool.
        [string]$ToolPath
    )

    $tool = if ($ToolPath) { $ToolPath } else { Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\New-PETenantApps.ps1' }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Get-PERectifyPwshPath))
    foreach ($a in '-NoProfile', '-NonInteractive', '-File', $tool, '-Slug', $Slug, '-TenantId', $TenantDomain, '-Json') { $startInfo.ArgumentList.Add($a) }
    if ($DisplayName) { $startInfo.ArgumentList.Add('-DisplayName'); $startInfo.ArgumentList.Add($DisplayName) }
    if ($NoWriter) { $startInfo.ArgumentList.Add('-NoWriter') }
    if (@($WriterRoles).Count -gt 0) { $startInfo.ArgumentList.Add('-WriterRoles'); $startInfo.ArgumentList.Add((@($WriterRoles) -join ',')) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $all = [System.Collections.Generic.List[string]]::new()
    $last = ''
    try
    {
        [void]$process.Start()
        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        $outOpen = $true
        $errOpen = $true
        $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
        while ($outOpen -or $errOpen)
        {
            $progressed = $false
            if ($outOpen -and $outTask.IsCompleted)
            {
                $line = $outTask.Result
                if ($null -eq $line) { $outOpen = $false } else { $all.Add($line); $outTask = $process.StandardOutput.ReadLineAsync() }
                $progressed = $true
            }
            if ($errOpen -and $errTask.IsCompleted)
            {
                $line = $errTask.Result
                if ($null -eq $line) { $errOpen = $false } else { $all.Add($line); $errTask = $process.StandardError.ReadLineAsync() }
                $progressed = $true
            }
            if ($progressed)
            {
                $text = $all -join "`n"
                $message = if ($text -match 'open the page (https://\S+) and enter the code ([A-Z0-9]{6,16})') { "Sign in as an administrator of the new tenant: open $($Matches[1]) and enter the code $($Matches[2]) within 15 minutes (submit again for a new code if it expires)." }
                elseif ($text -match 'Signed in') { "Signed in. Creating the apps: $($all[-1])" }
                else { '' }
                if ($message -and $message -ne $last -and $Progress) { $last = $message; & $Progress $message }
                continue
            }
            if ([DateTime]::UtcNow -gt $deadline)
            {
                try { $process.Kill($true) } catch { $null = $_ }
                throw "Nothing finished within $TimeoutMinutes minutes (was the sign-in completed?); the attempt was stopped."
            }
            Start-Sleep -Milliseconds 300
        }
        $process.WaitForExit()
        $json = @($all | Where-Object { $_ -match '^\{.*\}$' }) | Select-Object -Last 1
        [pscustomobject]@{ ExitCode = $process.ExitCode; Result = $(if ($json) { $json | ConvertFrom-Json } else { $null }); Output = @($all) }
    }
    finally
    {
        $process.Dispose()
    }
}
