BeforeAll {
    . "$PSScriptRoot\..\tools\PEDeviceLogin.ps1"
    $script:Device = [pscustomobject]@{ device_code = 'DEVICECODE'; user_code = 'ABCD1234'; interval = 5; expires_in = 900; message = 'To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code ABCD1234 to authenticate.' }
    function New-PendingError
    {
        param ([string]$Code, [string]$Description = '')
        $record = [System.Management.Automation.ErrorRecord]::new([Exception]::new('400'), 'oauth', 'NotSpecified', $null)
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new((@{ error = $Code; error_description = $Description } | ConvertTo-Json -Compress))
        $record
    }
}

Describe 'Get-PEDeviceLoginToken' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        Mock Start-Sleep { }
    }

    It 'asks for a code, shows Microsoft''s own prompt, waits while the sign-in is pending and returns the token' {
        $script:Polls = 0
        Mock Invoke-RestMethod {
            if ($Uri -like '*/devicecode') { return $script:Device }
            $script:Polls++
            if ($script:Polls -lt 3) { throw (New-PendingError -Code 'authorization_pending') }
            [pscustomobject]@{ access_token = 'THE.TOKEN' }
        }
        $shown = Get-PEDeviceLoginToken -TenantId 'contoso.onmicrosoft.com' -Scope 'Directory.Read.All' 6>&1
        ($shown | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join ' ' | Should -Match 'login.microsoft.com/device and enter the code ABCD1234'
        @($shown | Where-Object { $_ -is [string] })[-1] | Should -Be 'THE.TOKEN'
        $script:Polls | Should -Be 3
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*/devicecode' -and $Body.scope -eq 'https://graph.microsoft.com/Directory.Read.All' -and $Uri -like '*contoso.onmicrosoft.com*' } -Times 1
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -like '*/token' -and $Body.grant_type -eq 'urn:ietf:params:oauth:grant-type:device_code' -and $Body.device_code -eq 'DEVICECODE' }
    }

    It 'slows down when told to and stops with Microsoft''s reason on a real failure' {
        $script:Polls = 0
        Mock Invoke-RestMethod {
            if ($Uri -like '*/devicecode') { return $script:Device }
            $script:Polls++
            if ($script:Polls -eq 1) { throw (New-PendingError -Code 'slow_down') }
            throw (New-PendingError -Code 'access_denied' -Description "AADSTS65004: The user declined to consent.`r`nTrace ID: x")
        }
        { Get-PEDeviceLoginToken -TenantId 'contoso.onmicrosoft.com' -Scope 'Directory.Read.All' 6>$null } | Should -Throw '*Sign-in failed: AADSTS65004: The user declined to consent.*'
        $script:Polls | Should -Be 2
    }

    It 'says the code expired when it is not used in time' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*/devicecode') { return [pscustomobject]@{ device_code = 'D'; interval = 5; expires_in = 0; message = 'prompt' } }
            throw (New-PendingError -Code 'authorization_pending')
        }
        { Get-PEDeviceLoginToken -TenantId 'contoso.onmicrosoft.com' -Scope 'Directory.Read.All' 6>$null } | Should -Throw '*expired*'
    }
}
