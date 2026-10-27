BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    function New-St($records, $tenantId) { [pscustomobject]@{ Records = @($records); NotChecked = @(); Meta = @{ TenantId = $tenantId } } }
    function New-Rec($key, $description) { [pscustomobject]@{ ResourceType = 'AADGroup'; Key = $key; Workload = 'Entra ID'; TenantId = $null; Properties = [ordered]@{ DisplayName = $key; Description = $description } } }
    $script:Blueprint = New-St @((New-Rec 'Gone' 'a'), (New-Rec 'Moved' 'a')) 'prod'
    $script:Target = New-St @((New-Rec 'Moved' 'b')) 'dev'
    function New-Decision($tenant) { [pscustomobject]@{ Kind = 'Unmanaged'; ResourceType = 'AADGroup'; Key = $null; Tenant = $tenant } }
}

Describe 'Unmanaged decisions on Missing and Changed findings' {
    It 'a decision naming a replica tenant takes a Missing and a Changed item out of the drift' {
        $decisions = foreach ($key in 'Gone', 'Moved') { $d = New-Decision 'dev'; $d.Key = $key; $d }
        $f = @(Compare-PEState -Blueprint $script:Blueprint -Target $script:Target -Decisions @($decisions))
        @($f | Where-Object { $_.State -eq 'Open' }).Count | Should -Be 0
        @($f | Where-Object { $_.State -eq 'Unmanaged' }).Count | Should -Be 2
    }

    It 'a decision for the master, or for no tenant, never hides a Missing or Changed item' {
        foreach ($tenant in 'master', $null, '') {
            $decisions = foreach ($key in 'Gone', 'Moved') { $d = New-Decision $tenant; $d.Key = $key; $d }
            $f = @(Compare-PEState -Blueprint $script:Blueprint -Target $script:Target -Decisions @($decisions))
            @($f | Where-Object { $_.State -eq 'Open' }).Count | Should -Be 2 -Because "tenant '$tenant'"
        }
    }
}
