BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
}

Describe 'Convert-PEPermissionToRead' {
    It 'swaps ReadWrite for Read where Graph offers it, keeps the rest and reports what stayed ReadWrite' {
        $result = InModuleScope PolicyEngine {
            $in = @(
                @{ Api = 'graph'; PermissionName = 'Application.ReadWrite.All' }
                @{ Api = 'graph'; PermissionName = 'Application.Read.All' }
                @{ Api = 'graph'; PermissionName = 'Policy.ReadWrite.Authorization' }
                @{ Api = 'graph'; PermissionName = 'User.Read.All' }
                @{ Api = 'exchange'; PermissionName = 'Exchange.ManageAsApp' }
                @{ Api = 'sharepoint'; PermissionName = 'Sites.FullControl.ReadWrite.All' }
            )
            Convert-PEPermissionToRead -Permission $in -GraphRoleValue @('Application.Read.All', 'User.Read.All', 'Sites.FullControl.Read.All')
        }
        $names = @($result.Permissions | ForEach-Object { "$($_.Api):$($_.PermissionName)" })
        $names | Should -Contain 'graph:Application.Read.All'
        $names | Should -Not -Contain 'graph:Application.ReadWrite.All'
        $names | Should -Contain 'graph:Policy.ReadWrite.Authorization'
        $names | Should -Contain 'sharepoint:Sites.FullControl.ReadWrite.All'
        $names | Should -Contain 'exchange:Exchange.ManageAsApp'
        @($names | Where-Object { $_ -eq 'graph:Application.Read.All' }).Count | Should -Be 1
        $result.Narrowed | Should -Be 1
        $result.Remaining | Should -Be @('graph:Policy.ReadWrite.Authorization', 'sharepoint:Sites.FullControl.ReadWrite.All')
    }
}
