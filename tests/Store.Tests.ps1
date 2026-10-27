BeforeAll {
    Import-Module "$PSScriptRoot\..\src\PolicyEngine\PolicyEngine.psd1" -Force
}

Describe 'JSON store' {
    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
    }

    AfterEach {
        if (Test-Path $script:Temp)
        {
            Remove-Item $script:Temp -Recurse -Force
        }
    }

    # Store functions are private, so the assertions run inside the module scope.
    It 'Write-PEJson then Read-PEJson round-trips nested objects' {
        InModuleScope PolicyEngine -Parameters @{ Temp = $script:Temp } {
            param ($Temp)
            $path = Join-Path $Temp 'a\b\doc.json'
            $doc = @{ name = 'x'; items = @(1, 2, 3); child = @{ enabled = $true; label = 'y' } }
            Write-PEJson -Path $path -InputObject $doc
            $read = Read-PEJson -Path $path
            $read.name | Should -Be 'x'
            $read.items | Should -Be @(1, 2, 3)
            $read.child.enabled | Should -BeTrue
            $read.child.label | Should -Be 'y'
        }
    }

    It 'Read-PEJson returns null for a missing file' {
        InModuleScope PolicyEngine -Parameters @{ Temp = $script:Temp } {
            param ($Temp)
            Read-PEJson -Path (Join-Path $Temp 'missing.json') | Should -BeNull
        }
    }

    It 'Get-PEDataRoot honours -Override and creates the folder' {
        InModuleScope PolicyEngine -Parameters @{ Temp = $script:Temp } {
            param ($Temp)
            Get-PEDataRoot -Override $Temp | Should -Be $Temp
            Test-Path $Temp -PathType Container | Should -BeTrue
        }
    }
}

Describe 'JSON store dates and create-new' {
    It 'Read-PEJson keeps ISO date strings as strings' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.json')
        try
        {
            InModuleScope PolicyEngine -Parameters @{ Path = $path } {
                param ($Path)
                Write-PEJson -Path $Path -InputObject @{ when = '2026-01-02T03:04:05Z' }
                $v = (Read-PEJson -Path $Path).when
                $v | Should -BeOfType [string]
                $v | Should -Be '2026-01-02T03:04:05Z'
            }
        }
        finally
        {
            Remove-Item $path -ErrorAction SilentlyContinue
        }
    }

    It 'Write-PEJsonNew refuses to overwrite' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid() + '.json')
        try
        {
            InModuleScope PolicyEngine -Parameters @{ Path = $path } {
                param ($Path)
                Write-PEJsonNew -Path $Path -InputObject @{ a = 1 }
                { Write-PEJsonNew -Path $Path -InputObject @{ a = 2 } } | Should -Throw '*already exists*'
                (Read-PEJson -Path $Path).a | Should -Be 1
            }
        }
        finally
        {
            Remove-Item $path -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Write-PEJsonNew robustness' {
    It 'moves a fully written temp file into place; the final path does not exist until the move' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
        try
        {
            InModuleScope PolicyEngine -Parameters @{ Dir = $dir } {
                param ($Dir)
                $p = Join-Path $Dir 'm.json'
                $script:seen = $null
                Mock Move-PEFileNoOverwrite {
                    $script:seen = [pscustomobject]@{
                        FinalExists = Test-Path -LiteralPath $Destination
                        SourceIsTmp = $Source.EndsWith('.tmp')
                        Content     = [System.IO.File]::ReadAllText($Source)
                    }
                    [System.IO.File]::Move($Source, $Destination)
                }
                Write-PEJsonNew -Path $p -InputObject @{ a = 1; b = 'two' }
                $script:seen.FinalExists | Should -BeFalse
                $script:seen.SourceIsTmp | Should -BeTrue
                ($script:seen.Content | ConvertFrom-Json).b | Should -Be 'two'
                (Read-PEJson -Path $p).a | Should -Be 1
            }
        }
        finally
        {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'leaves no tmp file and the final path holds complete JSON' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("pe-" + [guid]::NewGuid())
        try
        {
            InModuleScope PolicyEngine -Parameters @{ Dir = $dir } {
                param ($Dir)
                $p = Join-Path $Dir 'a.json'
                Write-PEJsonNew -Path $p -InputObject @{ a = 1 }
                @(Get-ChildItem $Dir -Filter '*.tmp').Count | Should -Be 0
                (Read-PEJson -Path $p).a | Should -Be 1
            }
        }
        finally
        {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rethrows IO errors other than an existing file' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("pe-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try
        {
            InModuleScope PolicyEngine -Parameters @{ Dir = $dir } {
                param ($Dir)
                $file = Join-Path $Dir 'f.txt'
                Set-Content $file 'x'
                $err = $null
                try { Write-PEJsonNew -Path (Join-Path $file 'child.json') -InputObject @{ a = 1 } } catch { $err = $_ }
                $err | Should -Not -BeNull
                $err.Exception.Message | Should -Not -BeLike '*already exists*'
            }
        }
        finally
        {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Default data root' {
    BeforeAll {
        $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }

    It 'resolves to <repo>\data' {
        $root = InModuleScope PolicyEngine { Resolve-PEDefaultDataRoot }
        $root | Should -Be (Join-Path $script:Repo 'data')
    }

    It 'is not under src' {
        $root = InModuleScope PolicyEngine { Resolve-PEDefaultDataRoot }
        $root | Should -Not -BeLike (Join-Path $script:Repo 'src\*')
    }

    It 'has no side effects when resolving' {
        $before = Test-Path (Join-Path $script:Repo 'src\data')
        InModuleScope PolicyEngine { Resolve-PEDefaultDataRoot } | Out-Null
        Test-Path (Join-Path $script:Repo 'src\data') | Should -Be $before
    }

    It 'Get-PEDataRoot uses the resolved default when no override is given' {
        $expected = Join-Path $script:Repo 'data'
        $root = InModuleScope PolicyEngine -Parameters @{ Expected = $expected } {
            param ($Expected)
            Mock Test-Path { $true } -ParameterFilter { $PathType -eq 'Container' }
            Mock New-Item { }
            Get-PEDataRoot
            Should -Invoke New-Item -Times 0
        }
        $root | Should -Be $expected
    }

    It '-Override still wins' {
        $override = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
        try
        {
            InModuleScope PolicyEngine -Parameters @{ O = $override } { param ($O) Get-PEDataRoot -Override $O } | Should -Be $override
        }
        finally
        {
            Remove-Item $override -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'throws a clear error when no repo root is found' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pe-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try
        {
            { InModuleScope PolicyEngine -Parameters @{ D = $dir } { param ($D) Resolve-PEDefaultDataRoot -StartPath $D } } | Should -Throw '*repository root*'
        }
        finally
        {
            Remove-Item $dir -Recurse -Force
        }
    }
}
