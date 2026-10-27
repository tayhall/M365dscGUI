BeforeAll {
    Import-Module "$PSScriptRoot/../PEGui.psm1" -Force
    $script:T = 'abc123def456'
    function Test-Req {
        param($Method = 'GET', $Path = '/api/index', $HostHeader = 'localhost:8080', $Origin = '', $Cookie = '', $Query = '')
        Test-PEGuiRequestAllowed -Method $Method -Path $Path -HostHeader $HostHeader -Origin $Origin -CookieToken $Cookie -QueryToken $Query -Token $script:T -Port 8080
    }
}

Describe 'Test-PEGuiRequestAllowed' {
    It 'serves a request with the right host and the token cookie' {
        (Test-Req -Cookie $script:T).Allowed | Should -BeTrue
        (Test-Req -HostHeader '127.0.0.1:8080' -Cookie $script:T).Allowed | Should -BeTrue
    }

    It 'refuses without the token (401) and with a wrong token' {
        $r = Test-Req
        $r.Allowed | Should -BeFalse
        $r.StatusCode | Should -Be 401
        (Test-Req -Cookie 'wrong').Allowed | Should -BeFalse
        (Test-Req -Cookie ($script:T + 'x')).Allowed | Should -BeFalse
    }

    It 'refuses another host name even with the token (DNS rebinding)' {
        $r = Test-Req -HostHeader 'evil.example:8080' -Cookie $script:T
        $r.Allowed | Should -BeFalse
        $r.StatusCode | Should -Be 403
        (Test-Req -HostHeader 'localhost:9999' -Cookie $script:T).Allowed | Should -BeFalse
        (Test-Req -HostHeader '' -Cookie $script:T).Allowed | Should -BeFalse
    }

    It 'refuses a request from another origin, but allows our own' {
        (Test-Req -Method POST -Path '/api/requests' -Origin 'https://evil.example' -Cookie $script:T).StatusCode | Should -Be 403
        (Test-Req -Method POST -Path '/api/requests' -Origin 'http://localhost:8080' -Cookie $script:T).Allowed | Should -BeTrue
    }

    It 'hands out the cookie once, for the token in the query on the front page only' {
        $r = Test-Req -Path '/' -Query $script:T
        $r.Allowed | Should -BeTrue
        $r.SetCookie | Should -BeTrue
        (Test-Req -Path '/api/index' -Query $script:T).Allowed | Should -BeFalse
        (Test-Req -Path '/' -Query 'wrong').Allowed | Should -BeFalse
    }
}
