<#
    Pode server for the drift engine GUI. Start it with Start-PEGui.ps1, which picks the data folder.
    Every route is a thin pass-through to Invoke-PEGuiApi (PEGui.psm1), so the API is tested without Pode.
#>
param(
    [Parameter(Mandatory)][string]$DataRoot,
    [int]$Port = 8080,
    [Parameter(Mandatory)][string]$Token,
    [switch]$Mock
)

$guiRoot = $PSScriptRoot

Start-PodeServer -Threads 4 -ScriptBlock {
    # localhost only: there is no sign-in yet.
    Add-PodeEndpoint -Address localhost -Port $Port -Protocol Http
    # An UploadSnapshot request carries the text of DSC export files (an Entra export can exceed 8 MB). Pode accepts a request
    # body of up to 100 MB by default (Server.Request.BodySize, Pode 2.14; server.psd1 can change it), so no limit is raised here.
    # A 10 MB POST to /api/requests was answered 201.

    Import-PodeModule -Path (Join-Path $guiRoot 'PEGui.psm1')
    Set-PodeState -Name 'Token' -Value $Token | Out-Null
    Set-PodeState -Name 'Port' -Value $Port | Out-Null

    # Every request first: right host, right origin, and the startup token (see Test-PEGuiRequestAllowed).
    Add-PodeMiddleware -Name 'PEGuiGuard' -ScriptBlock {
        $cookie = Get-PodeCookie -Name 'pe-gui'
        $decision = Test-PEGuiRequestAllowed -Method $WebEvent.Method -Path $WebEvent.Path `
            -HostHeader (Get-PodeHeader -Name 'Host') -Origin (Get-PodeHeader -Name 'Origin') `
            -CookieToken $(if ($cookie) { $cookie.Value } else { '' }) -QueryToken ([string]$WebEvent.Query['token']) `
            -Token (Get-PodeState -Name 'Token') -Port (Get-PodeState -Name 'Port')
        if ($decision.SetCookie) {
            Set-PodeCookie -Name 'pe-gui' -Value (Get-PodeState -Name 'Token') -HttpOnly -Discard | Out-Null
            Move-PodeResponseUrl -Url '/'
            return $false
        }
        if (-not $decision.Allowed) {
            Write-PodeTextResponse -Value $decision.Message -ContentType 'text/plain' -StatusCode $decision.StatusCode
            return $false
        }
        return $true
    }
    Set-PodeState -Name 'DataRoot' -Value $DataRoot | Out-Null
    Set-PodeState -Name 'IndexPage' -Value (Join-Path $guiRoot 'public/index.html') | Out-Null

    $api = {
        $r = Invoke-PEGuiApi -DataRoot (Get-PodeState -Name 'DataRoot') -Method $WebEvent.Method -Path $WebEvent.Path `
            -Query $WebEvent.Query -Body $WebEvent.Data
        if ($r.PSObject.Properties['Text']) {
            # A configuration download: its own content type, saved under the name the job gives it.
            Set-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=""$($r.FileName)"""
            Write-PodeTextResponse -Value $r.Text -ContentType $r.ContentType -StatusCode $r.StatusCode
            return
        }
        Write-PodeTextResponse -Value $r.Json -ContentType 'application/json' -StatusCode $r.StatusCode
    }
    foreach ($path in '/api/index', '/api/resource-types', '/api/blueprint', '/api/blueprint/compare', '/api/exclusions',
        '/api/activity', '/api/activity/active', '/api/tenant-setup',
        '/api/tenants/:tenantId/status', '/api/tenants/:tenantId/findings', '/api/tenants/:tenantId/layer-findings', '/api/tenants/:tenantId/items',
        '/api/tenants/:tenantId/item', '/api/jobs/:jobId/config/:file') {
        Add-PodeRoute -Method Get -Path $path -ScriptBlock $api
    }
    foreach ($path in '/api/requests/preview', '/api/requests', '/api/jobs/:jobId/cancel') {
        Add-PodeRoute -Method Post -Path $path -ScriptBlock $api
    }

    # Static files, and the app shell for every page URL so deep links and bookmarks work.
    Add-PodeStaticRoute -Path '/assets' -Source (Join-Path $guiRoot 'public/assets')
    $shell = { Write-PodeFileResponse -Path (Get-PodeState -Name 'IndexPage') -ContentType 'text/html' }
    foreach ($path in '/', '/tenants', '/drift', '/blueprint', '/blueprint/compare', '/blueprint/versions/:version', '/exclusions', '/queue',
        '/activity', '/activity/:jobId', '/tenants/:tenantId/workloads/:workload',
        '/tenants/:tenantId/workloads/:workload/types/:resourceType', '/tenants/:tenantId/items/:itemId') {
        Add-PodeRoute -Method Get -Path $path -ScriptBlock $shell
    }

    if ($Mock) {
        # Mock jobs move Queued -> Running -> Succeeded. Real job progress comes in phase 2.
        Add-PodeTimer -Name 'MockJobs' -Interval 1 -ScriptBlock {
            Update-PEGuiMockJob -DataRoot (Get-PodeState -Name 'DataRoot')
        }
    }
}
