BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
    $script:Cat = 'AADEntitlementManagementAccessPackageCatalog'
    $script:Res = 'AADEntitlementManagementAccessPackageCatalogResource'
    $script:Pkg = 'AADEntitlementManagementAccessPackage'
    $script:Pol = 'AADEntitlementManagementAccessPackageAssignmentPolicy'
}

Describe 'apply order' {
    It 'puts parents before children by how many parents deep a type is' {
        InModuleScope PolicyEngine -Parameters @{ C = $script:Cat; R = $script:Res; P = $script:Pkg; L = $script:Pol } {
            Get-PEApplyDepth -ResourceType $C | Should -Be 0
            Get-PEApplyDepth -ResourceType $R | Should -Be 1
            Get-PEApplyDepth -ResourceType $P | Should -Be 2
            Get-PEApplyDepth -ResourceType $L | Should -Be 3
            Get-PEApplyDepth -ResourceType 'AADGroup' | Should -Be 0
            Get-PEApplyDepth -ResourceType 'AADConditionalAccessPolicy' | Should -Be 1
        }
    }

    It 'orders Create parents first, then Update, then Remove children first, keeping selection order for equals' {
        $order = InModuleScope PolicyEngine -Parameters @{ C = $script:Cat; R = $script:Res; P = $script:Pkg; L = $script:Pol } {
            $e = {
                param ($action, $type, $key) [pscustomobject]@{ Action = $action; Finding = [pscustomobject]@{ ResourceType = $type; Key = $key } }
            }
            $entries = @(
                (& $e 'Remove' $C 'oldcat'), (& $e 'Remove' $P 'oldpkg'),
                (& $e 'Create' $L 'pol'), (& $e 'Update' 'AADGroup' 'g'), (& $e 'Create' $P 'pkg'), (& $e 'Create' $C 'cat'), (& $e 'Create' 'AADGroup' 'g2'), (& $e 'Create' $R 'res')
            )
            @(Sort-PERevertEntry -Entry $entries | ForEach-Object { "$($_.Action) $($_.Finding.Key)" })
        }
        $order | Should -Be @('Create cat', 'Create g2', 'Create res', 'Create pkg', 'Create pol', 'Update g', 'Remove oldpkg', 'Remove oldcat')
    }
}

Describe 'GUID references' {
    It 'turns a catalog GUID into the catalog key using the Id in the same export, and leaves unknown GUIDs' {
        $result = InModuleScope PolicyEngine -Parameters @{ C = $script:Cat; R = $script:Res } {
            $records = @(
                [pscustomobject]@{ ResourceType = $C; Properties = [ordered]@{ DisplayName = 'DevCat1'; Id = '7D950B75-795B-4E51-A23F-9CAD961385A4' } },
                [pscustomobject]@{ ResourceType = $R; Properties = [ordered]@{ DisplayName = 'sg-IT'; CatalogId = '7d950b75-795b-4e51-a23f-9cad961385a4' } },
                [pscustomobject]@{ ResourceType = $R; Properties = [ordered]@{ DisplayName = 'other'; CatalogId = '11111111-1111-1111-1111-111111111111' } },
                [pscustomobject]@{ ResourceType = $R; Properties = [ordered]@{ DisplayName = 'named'; CatalogId = 'General' } }
            )
            $map = @{}
            Resolve-PEReferenceGuid -Record $records -ReferenceMap $map
            @($records[1].Properties.CatalogId, $records[2].Properties.CatalogId, $records[3].Properties.CatalogId, $map.Count)
        }
        $result | Should -Be @('DevCat1', '11111111-1111-1111-1111-111111111111', 'General', 1)
    }

    It 'carries ids across exports through the map' {
        $name = InModuleScope PolicyEngine -Parameters @{ C = $script:Cat; R = $script:Res } {
            $map = @{}
            Resolve-PEReferenceGuid -Record @([pscustomobject]@{ ResourceType = $C; Properties = [ordered]@{ DisplayName = 'General'; Id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } }) -ReferenceMap $map
            $later = [pscustomobject]@{ ResourceType = $R; Properties = [ordered]@{ DisplayName = 'x'; CatalogId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' } }
            Resolve-PEReferenceGuid -Record @($later) -ReferenceMap $map
            $later.Properties.CatalogId
        }
        $name | Should -Be 'General'
    }
}

Describe 'assignment policy key' {
    It 'is the access package and the name, so every package can have its own Initial Policy' {
        InModuleScope PolicyEngine -Parameters @{ L = $script:Pol } {
            Get-PEResourceKey -ResourceType $L -Properties ([ordered]@{ AccessPackageId = 'Pack A'; DisplayName = 'Initial Policy' }) | Should -Be 'Pack A | Initial Policy'
            Get-PEResourceKey -ResourceType $L -Properties ([ordered]@{ AccessPackageId = 'Pack B'; DisplayName = 'Initial Policy' }) | Should -Be 'Pack B | Initial Policy'
        }
    }
}
