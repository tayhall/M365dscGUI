BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Policy = 'AADEntitlementManagementAccessPackageAssignmentPolicy'
}

Describe 'Resolve-PEUserReference' {
    It 'swaps a user principal name for the id the resolver gives, and leaves group sets, GUIDs and unknown users alone' {
        $result = InModuleScope PolicyEngine -Parameters @{ T = $script:Policy } {
            $record = [pscustomobject]@{
                ResourceType = $T; Key = 'P | Initial Policy'; Workload = 'Entra ID'; TenantId = 't'
                Properties   = [ordered]@{
                    DisplayName             = 'Initial Policy'
                    RequestApprovalSettings = [ordered]@{
                        ApprovalStages = @([ordered]@{
                                PrimaryApprovers    = @(
                                    [ordered]@{ odataType = '#microsoft.graph.singleUser'; Id = 'AdeleV@contoso.com'; IsBackup = $false },
                                    [ordered]@{ odataType = '#microsoft.graph.singleUser'; Id = '11111111-1111-1111-1111-111111111111'; IsBackup = $false },
                                    [ordered]@{ odataType = '#microsoft.graph.singleUser'; Id = 'Nobody@contoso.com'; IsBackup = $false },
                                    [ordered]@{ odataType = '#microsoft.graph.groupMembers'; Id = 'Approvers'; IsBackup = $false }
                                )
                                EscalationApprovers = @([ordered]@{ odataType = '#microsoft.graph.singleUser'; Id = 'Boss@contoso.com'; IsBackup = $true })
                            })
                    }
                }
            }
            $resolver = { param ($upn) switch -Wildcard ($upn) { 'AdeleV@*' { 'aaaaaaaa-0000-0000-0000-000000000001' } 'Boss@*' { 'bbbbbbbb-0000-0000-0000-000000000002' } default { $null } } }
            $out = Resolve-PEUserReference -Record $record -Resolver $resolver
            $stage = $out.Properties.RequestApprovalSettings.ApprovalStages[0]
            [pscustomobject]@{
                Ids        = @($stage.PrimaryApprovers | ForEach-Object { $_.Id })
                Escalation = $stage.EscalationApprovers[0].Id
                Original   = $record.Properties.RequestApprovalSettings.ApprovalStages[0].PrimaryApprovers[0].Id
            }
        }
        $result.Ids | Should -Be @('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Nobody@contoso.com', 'Approvers')
        $result.Escalation | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
        $result.Original | Should -Be 'AdeleV@contoso.com'
    }

    It 'returns a record of another type as it is, without calling the resolver' {
        InModuleScope PolicyEngine {
            $record = [pscustomobject]@{ ResourceType = 'AADGroup'; Key = 'G'; Properties = [ordered]@{ DisplayName = 'G' } }
            $called = $false
            $out = Resolve-PEUserReference -Record $record -Resolver { $script:called = $true; 'x' }
            [object]::ReferenceEquals($out, $record) | Should -BeTrue
        }
    }
}

Describe 'New-PEUserIdResolver' {
    BeforeEach {
        Mock -ModuleName PolicyEngine Get-PEReaderApp { [pscustomobject]@{ ApplicationId = 'a'; TenantId = 't'; Thumbprint = 'b' } }
        Mock -ModuleName PolicyEngine Connect-PEGraph { }
        Mock -ModuleName PolicyEngine Disconnect-PEGraph { }
        Mock -ModuleName PolicyEngine Invoke-PEGraphPage {
            if ($Uri -like '*AdeleV*') { return @{ value = @(@{ id = 'id-adele' }) } }
            if ($Uri -like '*Twin*') { return @{ value = @(@{ id = 'one' }, @{ id = 'two' }) } }
            @{ value = @() }
        }
    }

    It 'finds exactly one user, ignores none or several, remembers answers, connects once and disconnects on Close' {
        $out = InModuleScope PolicyEngine {
            $r = New-PEUserIdResolver -Tenant contoso
            $a = $r.Resolve('AdeleV@contoso.onmicrosoft.com')
            $again = $r.Resolve('AdeleV@other.com')
            $none = $r.Resolve('Nobody@contoso.onmicrosoft.com')
            $twin = $r.Resolve('Twin@contoso.onmicrosoft.com')
            $r.Close()
            [pscustomobject]@{ A = $a; Again = $again; None = $none; Twin = $twin }
        }
        $out.A | Should -Be 'id-adele'
        $out.Again | Should -Be 'id-adele'
        $out.None | Should -BeNullOrEmpty
        $out.Twin | Should -BeNullOrEmpty
        Should -Invoke -ModuleName PolicyEngine Invoke-PEGraphPage -Times 3 -Exactly
        Should -Invoke -ModuleName PolicyEngine Connect-PEGraph -Times 1 -Exactly
        Should -Invoke -ModuleName PolicyEngine Disconnect-PEGraph -Times 1 -Exactly
    }
}