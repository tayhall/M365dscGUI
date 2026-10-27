BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    Import-Module "$PSScriptRoot\..\gui\PEGui.psm1" -Force
    $script:Stand = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-standin-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:Stand | Out-Null
    $script:Ok = Join-Path $script:Stand 'ok.ps1'
    $script:Bad = Join-Path $script:Stand 'bad.ps1'
    $params = 'param ([string]$Slug, [string]$TenantId, [string]$DisplayName, [switch]$NoWriter, [string]$WriterRoles, [switch]$Json)'
    @"
$params
'Resources in scope: 431'
'Sign in as an administrator of ' + `$TenantId
'To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code ABCD1234 to authenticate.'
Start-Sleep -Seconds 4
'Signed in.'
'[Reader] M365DSC-Policy-x-Reader'
'{"Slug":"' + `$Slug + '","TenantId":"' + `$TenantId + '","Reader":{"ApplicationId":"11111111-2222-3333-4444-555555555555","Thumbprint":"AA"},"Writer":null,"Unresolved":["x:y"],"Args":"' + `$WriterRoles + '"}'
"@ | Set-Content -LiteralPath $script:Ok
    @"
$params
'Sign in as an administrator of ' + `$TenantId
Write-Error 'AADSTS50076: multi-factor authentication required' -ErrorAction Continue
exit 3
"@ | Set-Content -LiteralPath $script:Bad
}

AfterAll {
    Remove-Item $script:Stand -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-PETenantAppsProcess' {
    It 'passes the device-code prompt on while the script is still running, then returns its JSON result' {
        $script:Seen = [System.Collections.Generic.List[string]]::new()
        $progress = { param ($text) $script:Seen.Add($text) }
        $run = & (Get-Module PolicyEngine) { param ($tool, $p) Invoke-PETenantAppsProcess -Slug 'dev' -TenantDomain 'contoso-dev.onmicrosoft.com' -DisplayName 'Dev' -WriterRoles 'Exchange Administrator', 'Teams Administrator' -Progress $p -ToolPath $tool } $script:Ok $progress
        $run.ExitCode | Should -Be 0
        $run.Result.Slug | Should -Be 'dev'
        $run.Result.Reader.ApplicationId | Should -Be '11111111-2222-3333-4444-555555555555'
        $run.Result.Args | Should -Be 'Exchange Administrator,Teams Administrator'
        @($script:Seen | Where-Object { $_ -like '*https://login.microsoft.com/device*ABCD1234*' }).Count | Should -BeGreaterThan 0
    }

    It 'reports a failure with its exit code and output, and no result' {
        $run = & (Get-Module PolicyEngine) { param ($tool) Invoke-PETenantAppsProcess -Slug 'dev' -TenantDomain 'x.onmicrosoft.com' -ToolPath $tool } $script:Bad
        $run.ExitCode | Should -Be 3
        $run.Result | Should -BeNullOrEmpty
        ($run.Output -join ' ') | Should -Match 'AADSTS50076'
    }

    It 'refuses a slug or domain that could be anything but a name' {
        { & (Get-Module PolicyEngine) { Invoke-PETenantAppsProcess -Slug 'a b; calc' -TenantDomain 'x.onmicrosoft.com' -ToolPath 'x' } } | Should -Throw
        { & (Get-Module PolicyEngine) { Invoke-PETenantAppsProcess -Slug 'dev' -TenantDomain 'x y' -ToolPath 'x' } } | Should -Throw
    }
}

Describe 'Connect tenant through the worker (create mode)' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-conncreate-' + [guid]::NewGuid())
        $script:Gui = Join-Path $script:Temp 'gui'
        $group = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'Sales'; Workload = 'Entra ID'; Properties = [ordered]@{ DisplayName = 'Sales' } }
        $state = InModuleScope PolicyEngine -Parameters @{ R = @($group) } { New-PEState -Records $R -NotChecked @() -Meta @{ TenantId = 't'; ExportedAt = '2026-10-21T01:02:03Z' } }
        Initialize-PEBlueprint -Name 'main' -State $state -DataRoot $script:Temp | Out-Null
        $directory = Join-Path $script:Temp 'checks\20261021-020000'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [ordered]@{ CheckId = '20261021-020000'; Kind = 'Full'; BlueprintName = 'main'; BlueprintVersion = 1; Findings = @(); State = $state } | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $directory 'result.json') -Encoding utf8
        Mock -ModuleName PolicyEngine Get-PEGuiRevertConfig { @{ Wrapper = $null; Items = @{} } }
        Export-PEGuiData -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
    }

    AfterEach {
        Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'accepts create mode without app ids, runs the creation with the writer options and reports success' {
        Mock -ModuleName PolicyEngine Invoke-PETenantAppsProcess { & $Progress 'Sign in: open https://microsoft.com/devicelogin and enter the code ABCD1234.'; [pscustomobject]@{ ExitCode = 0; Output = @('x'); Result = [pscustomobject]@{ Reader = @{ ApplicationId = 'a' }; Writer = @{ ApplicationId = 'b' }; Unresolved = @('a:b', 'c:d') } } }
        $body = [pscustomobject]@{ action = 'ConnectTenant'; connect = [pscustomobject]@{ mode = 'create'; slug = 'dev'; displayName = 'Dev'; tenantDomain = 'contoso-dev.onmicrosoft.com'; createWriter = $true; writerRoles = $true } }
        $reply = Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body $body
        $reply.StatusCode | Should -Be 201 -Because $reply.Json
        $id = ($reply.Json | ConvertFrom-Json).jobId
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-Content (Join-Path $script:Gui "activity\$id.json") -Raw | ConvertFrom-Json
        $job.status | Should -Be 'Succeeded' -Because $job.result
        $job.result | Should -BeLike "Tenant 'dev' connected: Reader app and Writer app created*2 permission(s)*"
        Should -Invoke -ModuleName PolicyEngine Invoke-PETenantAppsProcess -Times 1 -ParameterFilter { $Slug -eq 'dev' -and $TenantDomain -eq 'contoso-dev.onmicrosoft.com' -and ($WriterRoles -join ',') -eq 'Exchange Administrator,Teams Administrator' -and $null -ne $Progress -and -not $NoWriter }
    }

    It 'creates a Reader only when the Writer is not wanted, and shows why a failed creation failed' {
        Mock -ModuleName PolicyEngine Invoke-PETenantAppsProcess { [pscustomobject]@{ ExitCode = 3; Output = @('Sign in as an administrator', 'AADSTS50076: multi-factor authentication required'); Result = $null } }
        $body = [pscustomobject]@{ action = 'ConnectTenant'; connect = [pscustomobject]@{ mode = 'create'; slug = 'dev'; tenantDomain = 'contoso-dev.onmicrosoft.com'; createWriter = $false } }
        $id = ((Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body $body).Json | ConvertFrom-Json).jobId
        Invoke-PEGuiRequest -BlueprintName 'main' -DataRoot $script:Temp -GuiRoot $script:Gui | Out-Null
        $job = Get-Content (Join-Path $script:Gui "activity\$id.json") -Raw | ConvertFrom-Json
        $job.status | Should -Be 'Failed'
        $job.result | Should -BeLike '*exit code 3*AADSTS50076*'
        Should -Invoke -ModuleName PolicyEngine Invoke-PETenantAppsProcess -Times 1 -ParameterFilter { $NoWriter }
    }

    It 'still refuses create mode for the master and for a bad name or domain' {
        foreach ($bad in @(@{ slug = 'master' }, @{ slug = 'Bad Slug' }, @{ tenantDomain = 'x y' }))
        {
            $connect = @{ mode = 'create'; slug = 'dev'; tenantDomain = 'contoso-dev.onmicrosoft.com'; createWriter = $true }
            foreach ($k in $bad.Keys) { $connect[$k] = $bad[$k] }
            (Invoke-PEGuiApi -DataRoot $script:Gui -Method POST -Path '/api/requests' -Body ([pscustomobject]@{ action = 'ConnectTenant'; connect = [pscustomobject]$connect })).StatusCode | Should -Be 400
        }
    }
}
