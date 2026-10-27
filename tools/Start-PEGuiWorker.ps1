<#
.SYNOPSIS
Processes the action requests the web GUI queues, until stopped (Ctrl+C).

.DESCRIPTION
Run it next to `gui\Start-PEGui.ps1` (without -Mock). Every few seconds it calls Invoke-PEGuiRequest, which runs the
safe actions (exclusions, noise rules, blueprint promotes), fails Accept and Revert with an explanation, and refreshes
the view models. Reverts apply through the Local Configuration Manager, so start it elevated (PowerShell 7, Run as administrator). Use -Once to process what is queued and exit.

.EXAMPLE
pwsh -NoProfile -File tools\Start-PEGuiWorker.ps1 -BlueprintName main
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)]
    [string]$BlueprintName,

    [string]$DataRoot,

    [string]$GuiRoot,

    [ValidateRange(1, 300)]
    [int]$IntervalSeconds = 3,

    [switch]$Once
)

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -lt [version]'7.6')
{
    throw "The GUI worker needs PowerShell 7.6 or later (this is $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)). Start it from a PowerShell 7 window (elevated: Run as administrator): pwsh -NoProfile -File tools\Start-PEGuiWorker.ps1 -BlueprintName <name>"
}

Import-Module (Join-Path $PSScriptRoot '..\src\PolicyEngine\PolicyEngine.psd1') -Force -ErrorAction Stop

$arguments = @{ BlueprintName = $BlueprintName }
if ($DataRoot) { $arguments.DataRoot = $DataRoot }
if ($GuiRoot) { $arguments.GuiRoot = $GuiRoot }

Write-Host ('{0:HH:mm:ss} GUI worker running: blueprint ''{1}'', data {2}.' -f (Get-Date), $BlueprintName, ($(if ($GuiRoot) { $GuiRoot } else { 'data\gui' })))
Write-Host 'Waiting for requests from the GUI (Ctrl+C to stop). Each job is listed below as it runs.'
$passes = 0

do
{
    try
    {
        $result = Invoke-PEGuiRequest @arguments
        $passes++
        if ($result.Processed -eq 0 -and $passes % 20 -eq 0)
        {
            Write-Host ('{0:HH:mm:ss} still waiting for requests' -f (Get-Date))
        }
    }
    catch
    {
        Write-Warning "Worker pass failed: $($_.Exception.Message)"
    }
    if (-not $Once)
    {
        Start-Sleep -Seconds $IntervalSeconds
    }
}
while (-not $Once)
