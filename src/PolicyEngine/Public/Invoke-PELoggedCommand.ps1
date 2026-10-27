function Invoke-PELoggedCommand
{
    <#
    .SYNOPSIS
    Runs a script block and writes everything it emits to a log file as well as to the console.

    .DESCRIPTION
    Captures all streams with *>&1, so Write-Host (information stream), Write-Verbose, warnings and errors are logged as
    plain text without ANSI codes. Start-Transcript is avoided on purpose: it adds headers and decoration. Write-Host
    -NoNewline is honoured so progress lines keep their original shape. Output objects are logged by their string form
    and passed through. The log is UTF-8 without BOM and flushed per message.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [string]$LogPath
    )

    $parent = Split-Path -Parent $LogPath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container))
    {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $writer = [System.IO.StreamWriter]::new($LogPath, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    try
    {
        & $ScriptBlock *>&1 | ForEach-Object {
            $item = $_
            if ($item -is [System.Management.Automation.InformationRecord])
            {
                $data = $item.MessageData
                if ($data -is [System.Management.Automation.HostInformationMessage])
                {
                    $flat = ConvertTo-PELogText -Text $data.Message
                    $writer.Write($flat)
                    if (-not $data.NoNewLine)
                    {
                        $writer.WriteLine()
                    }
                    $splat = @{ Object = $data.Message; NoNewline = [bool]$data.NoNewLine }
                    if ($null -ne $data.ForegroundColor -and [int]$data.ForegroundColor -ge 0)
                    {
                        $splat.ForegroundColor = $data.ForegroundColor
                    }
                    Write-Host @splat
                }
                else
                {
                    $writer.WriteLine((ConvertTo-PELogText -Text ([string]$data)))
                    Write-Information -MessageData $data
                }
            }
            elseif ($item -is [System.Management.Automation.VerboseRecord])
            {
                $writer.WriteLine((ConvertTo-PELogText -Text ([string]$item.Message)))
                $PSCmdlet.WriteVerbose($item.Message)
            }
            elseif ($item -is [System.Management.Automation.WarningRecord])
            {
                $writer.WriteLine((ConvertTo-PELogText -Text ('WARNING: ' + $item.Message)))
                $PSCmdlet.WriteWarning($item.Message)
            }
            elseif ($item -is [System.Management.Automation.ErrorRecord])
            {
                $writer.WriteLine((ConvertTo-PELogText -Text ('ERROR: ' + $item.ToString())))
                $PSCmdlet.WriteError($item)
            }
            elseif ($item -is [System.Management.Automation.DebugRecord])
            {
                $writer.WriteLine((ConvertTo-PELogText -Text ([string]$item.Message)))
            }
            else
            {
                $writer.WriteLine((ConvertTo-PELogText -Text ([string]$item)))
                $item
            }
        }
    }
    catch
    {
        # A terminating error is logged too, then raised again.
        $writer.WriteLine((ConvertTo-PELogText -Text ('ERROR: ' + $_.ToString())))
        throw
    }
    finally
    {
        $writer.Dispose()
    }
}
