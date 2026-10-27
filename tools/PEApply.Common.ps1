# Logic behind tools\Invoke-PEApply.ps1 (see docs\apply-mechanics.md), dot-sourced by the script and by
# tests\Apply.Tests.ps1. Everything that touches the modules, the tenant or the MOF parser lives in the small wrapper
# functions Import-PEApplyModules, Get-PEApplyResourceTypes, Invoke-PEApplyCompile, Get-PEMofResource and
# Invoke-PELcm; tests mock those.

$script:PEApplyMetaProperties = @('ModuleName', 'ModuleVersion', 'ResourceID', 'SourceInfo', 'ConfigurationName', 'DependsOn')

# Authentication properties other than the certificate trio: an instance carrying any of them is refused.
$script:PEApplyRefusedProperties = @(
    'Credential', 'ApplicationSecret', 'CertificatePath', 'CertificatePassword', 'ManagedIdentity', 'AccessTokens',
    'PsDscRunAsCredential'
)

function Get-PEApplyApp
{
    <#
    .SYNOPSIS
    Reads and validates the app registration JSON written by tools\New-PETenantApps.ps1 (or Connect-PETenant).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory)]
        [ValidateSet('Reader', 'Writer')]
        [string]$Role,

        [string]$Path = (Join-Path $HOME ".m365dsc-policy\M365DSC-Policy-$Role.json")
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw "App details for the $Role app not found at $Path."
    }
    $info = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $patterns = @{
        ApplicationId = '\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z'
        TenantId      = '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z'
        Thumbprint    = '\A[0-9A-Fa-f]{40}\z'
    }
    foreach ($name in 'ApplicationId', 'TenantId', 'Thumbprint')
    {
        $value = [string]$info.$name
        if ($value -notmatch $patterns[$name])
        {
            throw "$Path has no valid $name."
        }
    }
    return [pscustomobject]@{
        Role          = $Role
        ApplicationId = [string]$info.ApplicationId
        TenantId      = [string]$info.TenantId
        Thumbprint    = [string]$info.Thumbprint
    }
}

function Protect-PEApplyText
{
    # Replaces every occurrence of the certificate thumbprint (case-insensitive) with '<thumbprint>'.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Thumbprint
    )

    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Thumbprint))
    {
        return $Text
    }
    return [regex]::Replace($Text, [regex]::Escape($Thumbprint), '<thumbprint>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Resolve-PEApplyMode
{
    <#
    .SYNOPSIS
    True when the run must be test-only: -TestOnly, or ShouldProcess declined (-WhatIf, or -Confirm answered No).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [bool]$TestOnly,

        [Parameter(Mandatory)]
        [scriptblock]$ShouldProcess
    )

    if ($TestOnly)
    {
        return $true
    }
    return -not [bool](& $ShouldProcess)
}

function Complete-PEApplyOutput
{
    <#
    .SYNOPSIS
    The script's final output and exit code: the result object (or, with -Json, compact JSON with the thumbprint
    redacted) and 0 when Success, 2 otherwise.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object]$Result,

        [switch]$Json,

        [string]$Thumbprint
    )

    $output = if ($Json)
    {
        Protect-PEApplyText -Text ($Result | ConvertTo-Json -Depth 8 -Compress) -Thumbprint $Thumbprint
    }
    else
    {
        $Result
    }
    return [pscustomobject]@{
        Output   = $output
        ExitCode = $(if ($Result.Success) { 0 } else { 2 })
    }
}

function Assert-PEApplyRole
{
    # A Reader run may only test; it must never Set.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Role,

        [Parameter(Mandatory)]
        [bool]$TestOnly
    )

    if ($Role -ne 'Writer' -and -not $TestOnly)
    {
        throw "The $Role app can only be used with -TestOnly (or -WhatIf); applying needs the Writer app."
    }
}

function Resolve-PETenantGuid
{
    # The tenant's GUID, which the export writes into some values as $($ConfigurationData.NonNodeData.TenantGuid). The app details hold the tenant as a
    # domain or a GUID; a domain is resolved from Microsoft's public OpenID metadata for the tenant (no sign-in). $null when it cannot be resolved.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$TenantId
    )

    $guid = [guid]::Empty
    if ([guid]::TryParse($TenantId, [ref]$guid))
    {
        return $guid.ToString()
    }
    try
    {
        $metadata = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$([uri]::EscapeDataString($TenantId))/v2.0/.well-known/openid-configuration" -TimeoutSec 20 -ErrorAction Stop
        if ($metadata.issuer -match '/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/')
        {
            return $Matches[1].ToLowerInvariant()
        }
    }
    catch
    {
        return $null
    }
    return $null
}
function New-PEApplyConfigurationDataText
{
    # The configuration data the generated configuration expects, built from the app details.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [object]$App
    )

    $tenantGuid = Resolve-PETenantGuid -TenantId ([string]$App.TenantId)
    return @(
        '@{'
        "    AllNodes    = @(@{ NodeName = 'localhost' })"
        '    NonNodeData = @{'
        "        OrganizationName      = '$($App.TenantId)'"
        "        TenantGuid            = '$tenantGuid'"
        "        TenantId              = '$($App.TenantId)'"
        "        ApplicationId         = '$($App.ApplicationId)'"
        "        CertificateThumbprint = '$($App.Thumbprint)'"
        '    }'
        '}'
        ''
    ) -join "`n"
}

function Assert-PEApplyConfigurationData
{
    # The configuration data must name the same tenant, app and certificate as the app JSON for the role.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Data,

        [Parameter(Mandatory)]
        [object]$App
    )

    $nonNode = $Data['NonNodeData']
    if ($nonNode -isnot [System.Collections.IDictionary])
    {
        throw 'The configuration data has no NonNodeData table.'
    }
    $expected = [ordered]@{
        TenantId              = $App.TenantId
        ApplicationId         = $App.ApplicationId
        CertificateThumbprint = $App.Thumbprint
    }
    foreach ($name in $expected.Keys)
    {
        $value = [string]$nonNode[$name]
        if ([string]::IsNullOrWhiteSpace($value) -or $value -ine $expected[$name])
        {
            throw "The configuration data's NonNodeData.$name does not match the $($App.Role) app (tenant $($App.TenantId)); refusing to apply."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$nonNode['OrganizationName']))
    {
        throw 'The configuration data has no NonNodeData.OrganizationName.'
    }
}

function Resolve-PEApplyRealPath
{
    <#
    .SYNOPSIS
    The full path with every existing junction or symbolic link along it replaced by its final target.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($full)
    $current = $root
    $segments = $full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($segment in $segments)
    {
        $candidate = Join-Path $current $segment
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and $item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) -and $null -ne $item.LinkTarget)
        {
            $target = $item.ResolveLinkTarget($true)
            $candidate = if ($null -ne $target) { $target.FullName } else { [System.IO.Path]::GetFullPath($item.LinkTarget, $current) }
            if ($candidate.StartsWith('\\?\'))
            {
                $candidate = $candidate.Substring(4)
            }
        }
        $current = $candidate
    }
    return $current.TrimEnd('\', '/')
}

function Test-PEApplyPathInside
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $comparison = if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $p = $Path.TrimEnd('\', '/')
    $r = $Root.TrimEnd('\', '/')
    return ($p.Equals($r, $comparison) -or $p.StartsWith($r + '\', $comparison) -or $p.StartsWith($r + '/', $comparison))
}

function Assert-PEApplyOutputPath
{
    # A caller-supplied output folder must not be inside the repository (the MOF carries the certificate thumbprint):
    # not literally, not through a junction or symbolic link, and not as a \\?\ or UNC path.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    if ($Path.StartsWith('\\') -or $Path.StartsWith('//'))
    {
        throw "OutputPath '$Path' is a UNC or \\?\ path; use a local folder outside the repository."
    }
    $refuse = "OutputPath '$Path' is inside the repository ($RepoRoot); use a folder outside it, such as the OS temp folder."
    $full = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($RepoRoot)
    $rootReal = Resolve-PEApplyRealPath -Path $rootFull
    $real = Resolve-PEApplyRealPath -Path $full
    foreach ($candidate in $full, $real)
    {
        foreach ($root in $rootFull, $rootReal)
        {
            if (Test-PEApplyPathInside -Path $candidate -Root $root)
            {
                throw $refuse
            }
        }
    }
}

function New-PEApplyWorkFolder
{
    <#
    .SYNOPSIS
    Creates <Parent>\PEApply-<guid> for one run; on Windows only the current user can access it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Parent
    )

    if (-not (Test-Path -LiteralPath $Parent -PathType Container))
    {
        New-Item -ItemType Directory -Path $Parent -Force -Confirm:$false -WhatIf:$false | Out-Null
    }
    $folder = Join-Path $Parent ('PEApply-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -ErrorAction Stop -Confirm:$false -WhatIf:$false | Out-Null
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')
    {
        try
        {
            $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = [System.Security.AccessControl.DirectorySecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                    $user,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow))
            [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new($folder), $acl)
        }
        catch
        {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false -WhatIf:$false
            throw "Could not restrict access to the work folder $folder`: $($_.Exception.Message)"
        }
    }
    return $folder
}

function Get-PEConfigResourceCount
{
    <#
    .SYNOPSIS
    Counts the resource blocks declared inside the Node blocks of a configuration script (via the AST). Parsing a
    configuration loads the resource schemas (a few seconds).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0)
    {
        throw "The configuration script $Path does not parse: $($errors[0].Message)"
    }
    $definitions = @($ast.FindAll({ param ($n) $n -is [System.Management.Automation.Language.ConfigurationDefinitionAst] }, $true))
    if ($definitions.Count -ne 1)
    {
        throw "The configuration script $Path must declare exactly one Configuration (found $($definitions.Count))."
    }
    # The compile executes the whole file, so nothing but comments may sit around the Configuration (an exported header whose text
    # broke out of its comment line would otherwise run).
    $outside = @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.ConfigurationDefinitionAst] })
    if ($outside.Count -gt 0 -or $null -ne $ast.ParamBlock -or $null -ne $ast.BeginBlock -or $null -ne $ast.ProcessBlock -or $null -ne $ast.DynamicParamBlock)
    {
        $first = $(if ($outside.Count -gt 0) { ($outside[0].Extent.Text -split "`n")[0] } else { 'a param or named block' })
        throw "The configuration script $Path has code outside the Configuration (only comments are allowed there): $first"
    }
    $count = 0
    $nodes = @($definitions[0].Body.ScriptBlock.FindAll({
                param ($n)
                $n -is [System.Management.Automation.Language.DynamicKeywordStatementAst] -and
                [string]$n.CommandElements[0].Value -ieq 'Node'
            }, $true))
    if ($nodes.Count -eq 0)
    {
        throw "The configuration script $Path has no Node block."
    }
    foreach ($node in $nodes)
    {
        $body = $node.CommandElements[$node.CommandElements.Count - 1]
        if ($body -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst])
        {
            throw "Unexpected Node block in $Path."
        }
        foreach ($statement in $body.ScriptBlock.EndBlock.Statements)
        {
            if ($statement -is [System.Management.Automation.Language.DynamicKeywordStatementAst] -and
                $statement.CommandElements[$statement.CommandElements.Count - 1] -is [System.Management.Automation.Language.HashtableAst])
            {
                $count++
            }
            else
            {
                throw "Unexpected statement in a Node block of $Path`: $(($statement.Extent.Text -split "`n")[0])"
            }
        }
    }
    return $count
}

function ConvertFrom-PEMofValue
{
    # Embedded CIM instances become hashtables (Invoke-DscResource converts hashtables to the resource's classes).
    param ($Value)

    if ($Value -is [Microsoft.Management.Infrastructure.CimInstance])
    {
        $table = @{}
        foreach ($property in $Value.CimInstanceProperties)
        {
            if ($null -ne $property.Value)
            {
                $table[$property.Name] = ConvertFrom-PEMofValue $property.Value
            }
        }
        return $table
    }
    if ($Value -is [System.Array] -and $Value.Count -gt 0 -and $Value[0] -is [Microsoft.Management.Infrastructure.CimInstance])
    {
        return , [hashtable[]]@($Value | ForEach-Object { ConvertFrom-PEMofValue $_ })
    }
    return , $Value
}

function Get-PEMofResource
{
    <#
    .SYNOPSIS
    Reads the resource instances of a compiled MOF: ResourceId, ResourceType, Module, Properties (without the DSC meta
    properties) and DependsOn.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$MofPath
    )

    # 4 = MofDeserializerSchemaValidationOption.Ignore.
    $instances = [Microsoft.PowerShell.DesiredStateConfiguration.Internal.DscClassCache]::ImportInstances($MofPath, 4)
    foreach ($instance in $instances)
    {
        if ($instance.CimClass.CimClassName -eq 'OMI_ConfigurationDocument')
        {
            continue
        }
        $properties = @{}
        foreach ($property in $instance.CimInstanceProperties)
        {
            if ($property.Name -notin $script:PEApplyMetaProperties -and $null -ne $property.Value)
            {
                $properties[$property.Name] = ConvertFrom-PEMofValue $property.Value
            }
        }
        $dependsOn = $instance.CimInstanceProperties['DependsOn']
        $moduleName = $instance.CimInstanceProperties['ModuleName']
        $moduleVersion = $instance.CimInstanceProperties['ModuleVersion']
        [pscustomobject]@{
            ResourceId   = [string]$instance.CimInstanceProperties['ResourceID'].Value
            ResourceType = [string]$instance.CimClass.CimClassName
            Module       = @{
                ModuleName    = $(if ($null -ne $moduleName) { [string]$moduleName.Value } else { $null })
                ModuleVersion = $(if ($null -ne $moduleVersion) { [string]$moduleVersion.Value } else { $null })
            }
            Properties   = $properties
            DependsOn    = $(if ($null -ne $dependsOn) { @($dependsOn.Value) } else { @() })
        }
    }
}

function Get-PEApplyResourceTypes
{
    # The DSC resources the pinned Microsoft365DSC exports (DscResourcesToExport of its manifest).
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ModuleVersion
    )

    $module = Get-Module -ListAvailable -Name Microsoft365DSC | Where-Object { $_.Version -eq [version]$ModuleVersion } | Select-Object -First 1
    if ($null -eq $module)
    {
        throw "Microsoft365DSC $ModuleVersion is not installed."
    }
    $manifest = Import-PowerShellDataFile -LiteralPath $module.Path
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($name in @($manifest.DscResourcesToExport))
    {
        [void]$set.Add([string]$name)
    }
    return , $set
}

function Assert-PEMofResource
{
    <#
    .SYNOPSIS
    Refuses a compiled MOF before anything runs. Fails closed: every instance must be a Microsoft365DSC resource of the
    pinned version, carry TenantId, ApplicationId and CertificateThumbprint equal to the app's, carry no other
    authentication property and no DependsOn; the count must equal the configuration's resource blocks and
    -ExpectedResourceCount when given.
    #>
    [CmdletBinding()]
    param
    (
        [AllowEmptyCollection()]
        [object[]]$Resources = @(),

        [Parameter(Mandatory)]
        [object]$App,

        [Parameter(Mandatory)]
        [int]$ConfigResourceCount,

        [int]$ExpectedResourceCount = -1,

        [Parameter(Mandatory)]
        [string]$ModuleVersion,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$ResourceTypes
    )

    $count = @($Resources).Count
    if ($count -eq 0)
    {
        throw 'The MOF contains no resource instances.'
    }
    if ($count -ne $ConfigResourceCount)
    {
        throw "The MOF has $count resource instances but the configuration declares $ConfigResourceCount resource blocks; refusing to apply."
    }
    if ($ExpectedResourceCount -ge 0 -and $count -ne $ExpectedResourceCount)
    {
        throw "The MOF has $count resource instances, expected $ExpectedResourceCount; refusing to apply."
    }
    $expected = [ordered]@{
        TenantId              = $App.TenantId
        ApplicationId         = $App.ApplicationId
        CertificateThumbprint = $App.Thumbprint
    }
    foreach ($resource in $Resources)
    {
        $id = $resource.ResourceId
        if ([string]$resource.Module.ModuleName -cne 'Microsoft365DSC')
        {
            throw "$id comes from module '$($resource.Module.ModuleName)', not Microsoft365DSC; refusing to apply."
        }
        if ([string]$resource.Module.ModuleVersion -cne $ModuleVersion)
        {
            throw "$id uses Microsoft365DSC $($resource.Module.ModuleVersion), not the pinned $ModuleVersion; refusing to apply."
        }
        if (-not $ResourceTypes.Contains([string]$resource.ResourceType))
        {
            throw "$id is not a Microsoft365DSC $ModuleVersion resource ($($resource.ResourceType)); refusing to apply."
        }
        if (@($resource.DependsOn | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)
        {
            throw "$id has DependsOn, which this apply does not honour; refusing to apply."
        }
        foreach ($name in $script:PEApplyRefusedProperties)
        {
            if ($resource.Properties.ContainsKey($name))
            {
                throw "$id carries $name; only certificate authentication with the $($App.Role) app is allowed; refusing to apply."
            }
        }
        foreach ($name in $expected.Keys)
        {
            if (-not $resource.Properties.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$resource.Properties[$name]))
            {
                throw "$id has no $name; refusing to apply."
            }
            if ([string]$resource.Properties[$name] -ine $expected[$name])
            {
                throw "$id has a $name that does not match the $($App.Role) app (tenant $($App.TenantId)); refusing to apply."
            }
        }
    }
}

function Import-PEApplyModules
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ModuleVersion,

        [Parameter(Mandatory)]
        [string]$EngineVersion
    )

    Import-Module Microsoft365DSC -RequiredVersion $ModuleVersion -WarningAction SilentlyContinue -Global
    Import-Module M365DSC.PSDesiredStateConfiguration -RequiredVersion $EngineVersion -Global
}

function Invoke-PEApplyCompile
{
    # Returns the MOF path. Throws on a compile error.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$ConfigurationDataPath,

        [Parameter(Mandatory)]
        [string]$ConfigurationName,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$Engine
    )

    $mof = Invoke-M365DSCConfigurationBuild -Path $ConfigPath -ConfigurationDataPath $ConfigurationDataPath `
        -ConfigurationName $ConfigurationName -OutputPath $OutputPath -Engine $Engine
    $file = @($mof | Where-Object { $null -ne $_ })
    if ($file.Count -ne 1)
    {
        throw "Compile produced $($file.Count) MOF files; expected 1."
    }
    return [string]$file[0].FullName
}

function Test-PEApplyElevated
{
    # Start-DscConfiguration and Test-DscConfiguration (the LCM) only work from an elevated session.
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-PELcm
{
    # Applies (or only tests) the compiled configuration through the LCM: Windows PowerShell 5.1 running tools\Invoke-PELcm.ps1,
    # as Microsoft365DSC documents (Start-DscConfiguration / Test-DscConfiguration; the LCM relays the resources into PowerShell 7).
    # The LCM holds one configuration at a time, so applies are serialised machine-wide with a named mutex. Returns the script's
    # JSON as an object { Error; InDesiredState; NotInDesiredState }.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$MofPath,

        [Parameter(Mandatory)]
        [ValidateSet('Apply', 'Test')]
        [string]$Mode,

        [ValidateRange(1, 720)]
        [int]$WaitMinutes = 60
    )

    $script = Join-Path $PSScriptRoot 'Invoke-PELcm.ps1'
    # The lock is created for Administrators and SYSTEM only, and an existing one owned by anyone else is refused, so another
    # process cannot take the name first and stall every apply.
    $security = [System.Security.AccessControl.MutexSecurity]::new()
    $trusted = foreach ($sidType in [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, [System.Security.Principal.WellKnownSidType]::LocalSystemSid)
    {
        [System.Security.Principal.SecurityIdentifier]::new($sidType, $null)
    }
    foreach ($sid in $trusted)
    {
        $security.AddAccessRule([System.Security.AccessControl.MutexAccessRule]::new($sid, [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow))
    }
    $createdNew = $false
    try
    {
        $mutex = [System.Threading.MutexAcl]::Create($false, 'Global\PolicyEngineLcm', [ref]$createdNew, $security)
    }
    catch [System.UnauthorizedAccessException]
    {
        throw 'The apply lock (Global\PolicyEngineLcm) exists but this account cannot use it: it was not created by an administrator or SYSTEM. Not applying.'
    }
    if (-not $createdNew)
    {
        $owner = [System.Threading.ThreadingAclExtensions]::GetAccessControl($mutex).GetOwner([System.Security.Principal.SecurityIdentifier])
        if ($trusted -notcontains $owner)
        {
            $mutex.Dispose()
            throw "The apply lock (Global\PolicyEngineLcm) is owned by $owner, not by an administrator or SYSTEM. Not applying."
        }
    }    $held = $false
    try
    {
        try
        {
            $held = $mutex.WaitOne([TimeSpan]::FromMinutes($WaitMinutes))
        }
        catch [System.Threading.AbandonedMutexException]
        {
            $held = $true
        }
        if (-not $held)
        {
            throw "Another apply has held the Local Configuration Manager for $WaitMinutes minutes; this one was not started."
        }
        $lines = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -MofPath $MofPath -Mode $Mode 2>&1 | ForEach-Object { [string]$_ })
        $json = @($lines | Where-Object { $_ -match '^\{.*\}$' }) | Select-Object -Last 1
        if (-not $json)
        {
            throw "The LCM script printed no result (exit code $LASTEXITCODE): $($lines -join ' ')"
        }
        return ($json | ConvertFrom-Json)
    }
    finally
    {
        if ($held)
        {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function ConvertTo-PEApplyRow
{
    # One row per MOF resource, in MOF order, from what the LCM reported. Apply: in desired state afterwards = Applied (the LCM does
    # not say whether it had to change anything), not in desired state = Failed with the LCM's error, not mentioned = NotRun.
    # Test: in desired state = InDesiredState, otherwise WouldChange.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [object[]]$Resource,

        [Parameter(Mandatory)]
        [object]$Lcm,

        [switch]$TestOnly,

        [string]$Thumbprint
    )

    $inDesired = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Lcm.InDesiredState | Where-Object { $_ }), [System.StringComparer]::OrdinalIgnoreCase)
    $failed = @{}
    foreach ($entry in @($Lcm.NotInDesiredState | Where-Object { $null -ne $_ }))
    {
        $failed[([string]$entry.ResourceId).ToLowerInvariant()] = $entry
    }
    # A test that came back as a plain True/False (no per-resource lists) says nothing about which resource differs: with True every
    # resource is in the desired state, with False each one is reported WouldChange (the state is not known per resource).
    if ($TestOnly -and $null -ne $Lcm.PSObject.Properties['Detailed'] -and $Lcm.Detailed -eq $false)
    {
        foreach ($item in $Resource)
        {
            [pscustomobject][ordered]@{
                ResourceId = $item.ResourceId; ResourceType = $item.ResourceType; Status = $(if ($Lcm.Overall -eq $true) { 'InDesiredState' } else { 'WouldChange' })
                InDesiredStateBefore = $null; SetInvoked = $null; RebootRequired = $null; InDesiredStateAfter = $null
                Seconds = 0; Error = $null
            }
        }
        return
    }
    foreach ($item in $Resource)
    {
        $status = 'NotRun'
        $errorText = $null
        if ($inDesired.Contains($item.ResourceId))
        {
            $status = $(if ($TestOnly) { 'InDesiredState' } else { 'Applied' })
        }
        elseif ($failed.ContainsKey(([string]$item.ResourceId).ToLowerInvariant()))
        {
            $status = $(if ($TestOnly) { 'WouldChange' } else { 'Failed' })
            if (-not $TestOnly)
            {
                $entry = $failed[([string]$item.ResourceId).ToLowerInvariant()]
                $errorText = $(if ($entry.Error) { Protect-PEApplyText -Text ([string]$entry.Error) -Thumbprint $Thumbprint } else { 'The Local Configuration Manager reports the resource is not in the desired state.' })
            }
        }
        [pscustomobject][ordered]@{
            ResourceId = $item.ResourceId; ResourceType = $item.ResourceType; Status = $status
            InDesiredStateBefore = $null; SetInvoked = $null; RebootRequired = $null; InDesiredStateAfter = $null
            Seconds = 0; Error = $errorText
        }
    }
}
function Invoke-PEApply
{
    <#
    .SYNOPSIS
    The whole apply (see tools\Invoke-PEApply.ps1 for the parameters). Returns the result object.

    .DESCRIPTION
    In-process callers must pass -TestOnly explicitly for a preview: this function has no -WhatIf (the script maps
    -WhatIf to -TestOnly). A real apply (not -TestOnly) requires -ExpectedResourceCount (Invoke-PERectify passes the
    plan's item count).
    Throws, before any Test or Set, for: a role/mode mismatch, a missing -ExpectedResourceCount, configuration data or
    MOF instances that do not match the app JSON (fail-closed, see Assert-PEMofResource), an OutputPath inside the repo,
    a resource count mismatch, DependsOn. Compile and apply failures are reported in the result instead. Every error
    text has the certificate thumbprint replaced by '<thumbprint>'. The per-run work folder (generated configuration
    data and MOF, which carry the thumbprint) is always removed in a finally block unless -KeepOutput; with
    -KeepOutput its path is in the result's OutputFolder, in a warning, and in the message of any exception thrown.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [string]$ConfigurationDataPath,

        [ValidateSet('Reader', 'Writer')]
        [string]$Role = 'Writer',

        [Parameter(Mandatory)]
        [string]$ConfigurationName,

        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [switch]$TestOnly,

        [switch]$KeepOutput,

        [ValidateSet('Standard', 'FastHost')]
        [string]$Engine = 'Standard',

        [int]$ExpectedResourceCount = -1,

        [Parameter(Mandatory)]
        [string]$ModuleVersion,

        [string]$EngineVersion = '3.1.10',

        [string]$AppInfoPath
    )

    # The tool's own folder operations never prompt, whatever -Confirm/-WhatIf the caller set.
    $ConfirmPreference = 'High'
    $WhatIfPreference = $false

    Assert-PEApplyRole -Role $Role -TestOnly $TestOnly.IsPresent
    if (-not (Test-PEApplyElevated))
    {
        throw 'The Local Configuration Manager (Start-DscConfiguration, Test-DscConfiguration) needs an elevated session: run this from an elevated PowerShell 7 console (and the GUI worker elevated).'
    }
    if (-not $TestOnly -and $ExpectedResourceCount -lt 0)
    {
        throw '-ExpectedResourceCount is required for a real apply (Invoke-PERectify passes the number of plan items); use -TestOnly for a preview.'
    }
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
    $appArguments = @{ Role = $Role }
    if ($AppInfoPath)
    {
        $appArguments['Path'] = $AppInfoPath
    }
    $app = Get-PEApplyApp @appArguments
    $thumbprint = $app.Thumbprint
    try
    {
        if ($ConfigurationDataPath)
        {
            $ConfigurationDataPath = (Resolve-Path -LiteralPath $ConfigurationDataPath -ErrorAction Stop).ProviderPath
            Assert-PEApplyConfigurationData -Data (Import-PowerShellDataFile -LiteralPath $ConfigurationDataPath) -App $app
        }
        $parent = if ($OutputPath)
        {
            Assert-PEApplyOutputPath -Path $OutputPath -RepoRoot $RepoRoot
            $OutputPath
        }
        else
        {
            [System.IO.Path]::GetTempPath()
        }
    }
    catch
    {
        throw (Protect-PEApplyText -Text $_.Exception.Message -Thumbprint $thumbprint)
    }
    if ($Engine -eq 'FastHost')
    {
        Write-Warning 'The FastHost compile silently drops properties the resource does not have; use -Engine Standard unless the configuration was validated against the schema.'
    }

    $result = [ordered]@{
        Success               = $false
        TestOnly              = $TestOnly.IsPresent
        PartiallyApplied      = $false
        ResourceCount         = 0
        ExpectedResourceCount = $(if ($ExpectedResourceCount -ge 0) { $ExpectedResourceCount } else { $null })
        OutputFolder          = $null
        MofPath               = $null
        CompileSeconds        = 0
        ApplySeconds          = 0
        Error                 = $null
        Resources             = @()
    }

    $work = New-PEApplyWorkFolder -Parent $parent
    if ($KeepOutput)
    {
        $result.OutputFolder = $work
    }
    try
    {
        if (-not $ConfigurationDataPath)
        {
            $ConfigurationDataPath = Join-Path $work 'ConfigurationData.psd1'
            [System.IO.File]::WriteAllText($ConfigurationDataPath, (New-PEApplyConfigurationDataText -App $app), [System.Text.UTF8Encoding]::new($true))
        }
        $configCount = Get-PEConfigResourceCount -Path $ConfigPath
        Import-PEApplyModules -ModuleVersion $ModuleVersion -EngineVersion $EngineVersion
        $resourceTypes = Get-PEApplyResourceTypes -ModuleVersion $ModuleVersion

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $mofPath = $null
        try
        {
            $mofPath = Invoke-PEApplyCompile -ConfigPath $ConfigPath -ConfigurationDataPath $ConfigurationDataPath `
                -ConfigurationName $ConfigurationName -OutputPath (Join-Path $work 'mof') -Engine $Engine
        }
        catch
        {
            $result.Error = Protect-PEApplyText -Text "Compile failed: $($_.Exception.Message)" -Thumbprint $thumbprint
        }
        $result.CompileSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
        if ($null -eq $mofPath)
        {
            return [pscustomobject]$result
        }
        if ($KeepOutput)
        {
            $result.MofPath = $mofPath
        }

        $resources = @(Get-PEMofResource -MofPath $mofPath)
        $result.ResourceCount = $resources.Count
        Assert-PEMofResource -Resources $resources -App $app -ConfigResourceCount $configCount `
            -ExpectedResourceCount $ExpectedResourceCount -ModuleVersion $ModuleVersion -ResourceTypes $resourceTypes

        $watch.Restart()
        $lcm = Invoke-PELcm -MofPath $mofPath -Mode $(if ($TestOnly) { 'Test' } else { 'Apply' })
        $result.ApplySeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
        $result.Resources = @(ConvertTo-PEApplyRow -Resource $resources -Lcm $lcm -TestOnly:$TestOnly -Thumbprint $thumbprint)
        $applied = @($result.Resources | Where-Object Status -EQ 'Applied').Count
        $notDone = @($result.Resources | Where-Object { $_.Status -in 'Failed', 'NotRun' }).Count
        $result.PartiallyApplied = $applied -gt 0 -and $notDone -gt 0
        # NotRun after an apply means the LCM never reported the resource, so its state is unknown: not a success.
        $failed = $notDone -gt 0 -or ($TestOnly -and [bool]$lcm.Error)
        $result.Success = -not $failed
        if ($failed)
        {
            $result.Error = 'One or more resources failed: ' + (($result.Resources | Where-Object Status -EQ 'Failed' | ForEach-Object { $_.ResourceId }) -join ', ') + $(if ($lcm.Error) { " (LCM: $(Protect-PEApplyText -Text ([string]$lcm.Error) -Thumbprint $thumbprint))" } else { '' })
        }
        return [pscustomobject]$result
    }
    catch
    {
        $message = Protect-PEApplyText -Text $_.Exception.Message -Thumbprint $thumbprint
        if ($KeepOutput)
        {
            $message += " (work folder kept: $work)"
        }
        throw $message
    }
    finally
    {
        if ($KeepOutput)
        {
            Write-Warning "Work folder kept: $work. It holds the certificate thumbprint (MOF, configuration data); delete it when done."
        }
        else
        {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false -WhatIf:$false
            if (Test-Path -LiteralPath $work)
            {
                Write-Warning "Could not remove the work folder $work; it holds the certificate thumbprint. Delete it."
            }
        }
    }
}
