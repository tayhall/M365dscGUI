# Device-code sign-in done directly against Microsoft's endpoints, dot-sourced by New-PETenantApps.ps1.
# Why not Connect-MgGraph -UseDeviceAuthentication: in testing (SDK 2.41) it printed a second code after the administrator had
# already signed in with the first, then gave up after 120 seconds, so the sign-in never reached the script. Doing the
# device flow ourselves is about thirty lines, shows the prompt in a form the GUI worker recognises, and allows the full
# time Microsoft gives for the code (15 minutes) instead of two.

function Get-PEDeviceLoginToken
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        # The tenant to sign in to (domain or id).
        [Parameter(Mandatory)]
        [string]$TenantId,

        # Graph delegated permissions to ask for, for example 'Application.ReadWrite.All'.
        [Parameter(Mandatory)]
        [string[]]$Scope,

        # The public client 'Microsoft Graph Command Line Tools', the same application the Graph PowerShell SDK signs in with.
        [string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    )

    $authority = "https://login.microsoftonline.com/$([uri]::EscapeDataString($TenantId))/oauth2/v2.0"
    $scopeText = ($Scope | ForEach-Object { "https://graph.microsoft.com/$_" }) -join ' '
    $device = Invoke-RestMethod -Method POST -Uri "$authority/devicecode" -ContentType 'application/x-www-form-urlencoded' -Body @{ client_id = $ClientId; scope = $scopeText }
    # The prompt, in the words Microsoft supplies ("... open the page https://login.microsoft.com/device and enter the code ...").
    # (Write-Host, not Write-Output: the function's output is the token.)
    Write-Host $device.message

    $deadline = (Get-Date).AddSeconds([int]$device.expires_in)
    $interval = [Math]::Max(2, [int]$device.interval)
    while ((Get-Date) -lt $deadline)
    {
        Start-Sleep -Seconds $interval
        try
        {
            $token = Invoke-RestMethod -Method POST -Uri "$authority/token" -ContentType 'application/x-www-form-urlencoded' `
                -Body @{ grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; client_id = $ClientId; device_code = $device.device_code }
            return [string]$token.access_token
        }
        catch
        {
            $detail = $null
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { try { $detail = $_.ErrorDetails.Message | ConvertFrom-Json } catch { $detail = $null } }
            $code = if ($detail) { [string]$detail.error } else { '' }
            if ($code -eq 'authorization_pending') { continue }
            if ($code -eq 'slow_down') { $interval += 5; continue }
            $reason = if ($detail -and $detail.error_description) { ([string]$detail.error_description -split "`r?`n")[0] } else { $_.Exception.Message }
            throw "Sign-in failed: $reason"
        }
    }
    throw 'Sign-in expired: the code was not used within the time Microsoft allows (15 minutes). Run it again for a new code.'
}
