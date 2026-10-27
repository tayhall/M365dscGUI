# Server-side logic for the drift engine web GUI: reads the view-model files, works out which actions a finding
# allows, validates action requests and writes them, and advances mock jobs. Pode routes in server.ps1 only call
# these functions, so everything here can be tested without a web server.
Set-StrictMode -Version Latest

$script:ResourceTypes = Get-Content (Join-Path $PSScriptRoot 'ResourceTypes.json') -Raw | ConvertFrom-Json -AsHashtable
$script:ActionableKinds = @('Missing', 'Changed', 'TargetOnly', 'PossibleRename')
$script:ReasonRequired = @('Promote', 'Exclude', 'ExcludeProperty', 'ExcludePropertyForTenant', 'RevertBlueprint', 'PromoteUp', 'PullDown', 'Adopt')
# Standards: the request actions, and the shape a standard name must have (it becomes part of a path).
$script:StandardActions = 'StandardCheck', 'Adopt', 'AcceptRisk', 'RemoveRisk', 'ImportStandard', 'CheckStandardRelease'
$script:StandardNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
$script:ItemIdPattern = '^[A-Za-z0-9]+~[A-Za-z0-9_.%-]+$'
$script:TenantIdPattern = '^[a-z0-9-]{1,40}$'

function ConvertTo-PEGuiItemId {
    param([Parameter(Mandatory)][string]$ResourceType, [Parameter(Mandatory)][string]$Key)
    $encoded = foreach ($ch in $Key.ToCharArray()) {
        if ("$ch" -match '^[A-Za-z0-9_.-]$') { "$ch" }
        else { ([Text.Encoding]::UTF8.GetBytes("$ch") | ForEach-Object { '%{0:X2}' -f $_ }) -join '' }
    }
    "$ResourceType~$($encoded -join '')"
}

function Resolve-PEGuiRoot {
    # A relative data root is resolved against PowerShell's current location, not the process directory.
    param([Parameter(Mandatory)][string]$DataRoot)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DataRoot)
    [IO.Path]::GetFullPath($full).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
}

function Get-PEGuiPath {
    # Joins a relative path to the data root and refuses anything that resolves outside it.
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$RelativePath)
    $root = Resolve-PEGuiRoot -DataRoot $DataRoot
    $full = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $full.StartsWith($root, [StringComparison]::Ordinal)) { throw "Path '$RelativePath' is outside the data root." }
    $full
}

function Read-PEGuiFile {
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$RelativePath)
    $path = Get-PEGuiPath -DataRoot $DataRoot -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -NoEnumerate
}

function Write-PEGuiFile {
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)]$InputObject)
    $path = Get-PEGuiPath -DataRoot $DataRoot -RelativePath $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    # Write to a temporary file and rename it over the target, so a reader never sees a half-written file.
    $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $InputObject -Depth 20), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $path, $true)
}

function Invoke-PEGuiLocked {
    # Runs a script block while holding a lock on the data root. Pode serves requests on several threads and the mock
    # timer runs on another; anything that numbers or rewrites jobs goes through here.
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((Resolve-PEGuiRoot -DataRoot $DataRoot))))
    $mutex = [Threading.Mutex]::new($false, "PEGui-$($hash.Substring(0, 32))")
    $held = $false
    try {
        try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'The data folder is busy; try again.' }
        & $ScriptBlock
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-PEGuiIndex {
    param([Parameter(Mandatory)][string]$DataRoot)
    $index = Read-PEGuiFile -DataRoot $DataRoot -RelativePath 'index.json'
    if (-not $index) { throw "No index.json in '$DataRoot'." }
    $index
}

function Get-PEGuiTenant {
    # Returns the tenant entry for an id, or throws if the id is not one the index lists.
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$TenantId)
    if ($TenantId -cnotmatch $script:TenantIdPattern) { throw "Unknown tenant '$TenantId'." }
    $tenant = (Get-PEGuiIndex -DataRoot $DataRoot).tenants | Where-Object tenantId -EQ $TenantId
    if (-not $tenant) { throw "Unknown tenant '$TenantId'." }
    $tenant
}

function Get-PEGuiResourceType { $script:ResourceTypes }

function Get-PEGuiTypeName {
    param([string]$ResourceType)
    if ($script:ResourceTypes.ContainsKey($ResourceType)) { $script:ResourceTypes[$ResourceType].name } else { $ResourceType }
}

function Get-PEGuiTenantStatus {
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$TenantId)
    $null = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $TenantId
    Read-PEGuiFile -DataRoot $DataRoot -RelativePath "tenants/$TenantId/status.json"
}

function Get-PEGuiItemList {
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$TenantId)
    $null = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $TenantId
    $list = Read-PEGuiFile -DataRoot $DataRoot -RelativePath "tenants/$TenantId/items.json"
    if ($null -eq $list) { @() } else { @($list) }
}

function Get-PEGuiAllowedAction {
    # The actions the GUI may offer for a finding. Kinds the engine cannot act on get none.
    # -Offline: nothing can be written to the tenant, so no revert (Accept); its owner runs the generated configuration instead.
    param([Parameter(Mandatory)]$Finding, [switch]$Offline)
    if ($Finding.state -eq 'Unmanaged')
    {
        # Nothing is enforced because every difference is a property excluded for the tenant: those come back one by one (IncludePropertyForTenant).
        if ($Finding.PSObject.Properties['excludedDifferences'] -and @($Finding.excludedDifferences).Count -gt 0) { return , @() }
        return , @('Unexclude')
    }
    if ($Finding.kind -notin $script:ActionableKinds) { return , @() }
    # A type the engine refuses to revert (Data\RevertBlocked.psd1) can still be promoted or excluded.
    $actions = @('Accept', 'Promote', 'Exclude')
    if ($Offline -or ($Finding.PSObject.Properties['revertBlocked'] -and $Finding.revertBlocked)) { $actions = @('Promote', 'Exclude') }
    if ($Finding.kind -eq 'Changed') { $actions += 'ExcludeProperty', 'ExcludePropertyForTenant' }
    , $actions
}

function Get-PEGuiFinding {
    # Findings for one tenant, each with the actions it allows.
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$TenantId)
    $tenant = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $TenantId
    $offline = [bool](Get-PEGuiProperty $tenant 'offline')
    $findings = Read-PEGuiFile -DataRoot $DataRoot -RelativePath "tenants/$TenantId/findings.json"
    if ($null -eq $findings) { return @() }
    # An item excluded as a whole (an Unmanaged decision) can always be brought back, even when its settings are also excluded one by one.
    $unmanaged = @((Get-PEGuiExclusion -DataRoot $DataRoot).unmanaged | Where-Object { $_ -and $_.tenantId -eq $TenantId } | ForEach-Object { $_.itemId })
    $out = foreach ($f in @($findings)) {
        $actions = Get-PEGuiAllowedAction -Finding $f -Offline:$offline
        if ($f.state -eq 'Unmanaged' -and $f.itemId -and $f.itemId -in $unmanaged -and 'Unexclude' -notin $actions) { $actions = , @('Unexclude') }
        $f | Add-Member -NotePropertyName allowedActions -NotePropertyValue $actions -Force -PassThru
    }
    @($out)
}

function Get-PEGuiLayerFinding {
    # Findings of a tenant against a blueprint layer other than its own (written by Export-PEGuiData). The only thing a
    # row offers is updating the tenant blueprint from the master blueprint.
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$Layer)
    $null = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $TenantId
    if ($Layer -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $Layer.Contains('..')) { throw "Unknown layer '$Layer'." }
    $findings = Read-PEGuiFile -DataRoot $DataRoot -RelativePath "tenants/$TenantId/layers/$Layer/findings.json"
    if ($null -eq $findings) { return @() }
    @(foreach ($f in @($findings)) { $f | Add-Member -NotePropertyName allowedActions -NotePropertyValue @('PullDown') -Force -PassThru })
}

function Get-PEGuiItem {
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$ItemId)
    $null = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $TenantId
    if ($ItemId -cnotmatch $script:ItemIdPattern) { throw "Invalid item id '$ItemId'." }
    Read-PEGuiFile -DataRoot $DataRoot -RelativePath "tenants/$TenantId/items/$ItemId.json"
}

function Get-PEGuiBlueprintVersion {
    # The versions of the master blueprint, or of a tenant blueprint by name (blueprint/<name>/versions.json, written by Export-PEGuiData).
    param([Parameter(Mandatory)][string]$DataRoot, [string]$Name)
    $relative = 'blueprint/versions.json'
    if ($Name) {
        if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return @() }
        $relative = "blueprint/$Name/versions.json"
    }
    $versions = Read-PEGuiFile -DataRoot $DataRoot -RelativePath $relative
    if ($null -eq $versions) { @() } else { @($versions | Sort-Object version) }
}

function Get-PEGuiExclusion {
    param([Parameter(Mandatory)][string]$DataRoot)
    $ex = Read-PEGuiFile -DataRoot $DataRoot -RelativePath 'exclusions.json'
    if (-not $ex) { $ex = [pscustomobject]@{ unmanaged = @(); noise = @() } }
    $ex
}

function Get-PEGuiActivity {
    # All jobs, newest first.
    param([Parameter(Mandatory)][string]$DataRoot)
    $dir = Get-PEGuiPath -DataRoot $DataRoot -RelativePath 'activity'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $jobs = Get-ChildItem -LiteralPath $dir -Filter 'J-*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }
    @($jobs | Sort-Object { [int]($_.jobId -replace '\D', '') } -Descending)
}

function Get-PEGuiActiveJobId {
    # Ids of the jobs the GUI queued that have not finished, kept in activity/active.json so the mock timer and the
    # page's poll read a short list instead of every job.
    param([Parameter(Mandatory)][string]$DataRoot)
    $ids = Read-PEGuiFile -DataRoot $DataRoot -RelativePath 'activity/active.json'
    if ($null -eq $ids) { @() } else { @($ids | Where-Object { $_ -cmatch '^J-\d+$' }) }
}

function Get-PEGuiActiveJob {
    param([Parameter(Mandatory)][string]$DataRoot)
    @(Get-PEGuiActiveJobId -DataRoot $DataRoot | ForEach-Object { Read-PEGuiFile -DataRoot $DataRoot -RelativePath "activity/$_.json" } | Where-Object { $null -ne $_ })
}

function Get-PEGuiOwnBlueprint {
    # The blueprint a tenant is checked against and promoted into: its own (the last layer), or the master blueprint.
    param([Parameter(Mandatory)][string]$DataRoot, [string]$TenantId)
    $index = Get-PEGuiIndex -DataRoot $DataRoot
    $tenant = if ($TenantId) { $index.tenants | Where-Object tenantId -CEQ $TenantId | Select-Object -First 1 } else { $null }
    $layers = @(if ($tenant -and $tenant.PSObject.Properties['layers']) { $tenant.layers | Where-Object { $_ } })
    if ($layers.Count) { return [pscustomobject]@{ name = [string]$layers[-1].name; version = [int]$layers[-1].version } }
    [pscustomobject]@{ name = [string]$index.blueprint.name; version = [int]$index.blueprint.version }
}

function Get-PEGuiNextBlueprintVersion {
    # The version the next Promote or Revert creates in a blueprint (the tenant's own, or the master blueprint without a
    # tenant): after its current version and after any version a job that has not failed already claimed in that
    # blueprint, so two requests never record the same version.
    param([Parameter(Mandatory)][string]$DataRoot, [string]$TenantId)
    $own = Get-PEGuiOwnBlueprint -DataRoot $DataRoot -TenantId $TenantId
    $claimed = @(Get-PEGuiActivity -DataRoot $DataRoot | Where-Object {
            $_.PSObject.Properties['blueprintVersionAfter'] -and $_.blueprintVersionAfter -and $_.status -ne 'Failed' -and
            $(if ($_.PSObject.Properties['blueprintName'] -and $_.blueprintName) { [string]$_.blueprintName } else { [string](Get-PEGuiIndex -DataRoot $DataRoot).blueprint.name }) -ceq $own.name
        } | ForEach-Object { [int]$_.blueprintVersionAfter })
    ([int[]](@($own.version) + $claimed) | Measure-Object -Maximum).Maximum + 1
}

function Compare-PEGuiBlueprintVersion {
    <#
        The net change per item between version From and version To, in either direction. An item's first change in
        the range says whether it existed at the lower version (anything but Added) and its last change says whether
        it exists at the higher one (anything but Removed). Added then removed again is no change at all.
    #>
    param([Parameter(Mandatory)][object[]]$Versions, [Parameter(Mandatory)][int]$From, [Parameter(Mandatory)][int]$To)
    $low = [Math]::Min($From, $To)
    $high = [Math]::Max($From, $To)
    $first = [ordered]@{}
    $last = @{}
    foreach ($v in $Versions | Where-Object { $_.version -gt $low -and $_.version -le $high } | Sort-Object version) {
        foreach ($c in $v.changes) {
            if (-not $first.Contains($c.itemId)) { $first[$c.itemId] = $c }
            $last[$c.itemId] = $c
        }
    }
    $out = foreach ($id in $first.Keys) {
        $before = $first[$id].op -ne 'Added'
        $after = $last[$id].op -ne 'Removed'
        $op = if ($before -and $after) { 'Changed' } elseif ($after) { 'Added' } elseif ($before) { 'Removed' } else { $null }
        if (-not $op) { continue }
        if ($From -gt $To -and $op -ne 'Changed') { $op = if ($op -eq 'Added') { 'Removed' } else { 'Added' } }
        [pscustomobject]@{ op = $op; resourceType = $last[$id].resourceType; key = $last[$id].key; itemId = $id }
    }
    @($out)
}

function ConvertTo-PEGuiPsLiteral {
    param($Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [array]) { return '@(' + (($Value | ForEach-Object { ConvertTo-PEGuiPsLiteral $_ }) -join ', ') + ')' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return "$Value" }
    "'" + ("$Value" -replace "'", "''") + "'"
}

function New-PEGuiMockConfig {
    # Mock DSC configuration text for the preview and audit. Phase 2 replaces this with the engine's generated config.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][object[]]$Entries)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# Preview of $Name (approximate: the audited configuration is generated when the job runs), target: $Target")
    $lines.Add("Configuration PE_$($Name -replace '[^A-Za-z0-9]', '') {")
    $lines.Add('    Import-DscResource -ModuleName Microsoft365DSC -ModuleVersion 2.26.1015.1')
    $lines.Add('    Node localhost {')
    foreach ($e in $Entries) {
        $lines.Add("        $($e.ResourceType) $(ConvertTo-PEGuiPsLiteral $e.Key) {")
        $props = [ordered]@{}
        if ($e.Ensure -eq 'Absent' -or -not $e.Properties) {
            $keyProperty = if ($script:ResourceTypes.ContainsKey($e.ResourceType) -and $script:ResourceTypes[$e.ResourceType].keyProperty) { $script:ResourceTypes[$e.ResourceType].keyProperty } else { 'DisplayName' }
            $props[$keyProperty] = $e.Key
        } else {
            foreach ($p in $e.Properties.PSObject.Properties) { $props[$p.Name] = $p.Value }
        }
        $props['Ensure'] = $e.Ensure
        foreach ($k in $props.Keys) { $lines.Add('            ' + $k.PadRight(32) + ' = ' + (ConvertTo-PEGuiPsLiteral $props[$k])) }
        foreach ($k in 'ApplicationId', 'TenantId', 'CertificateThumbprint') {
            $lines.Add('            ' + $k.PadRight(32) + " = `$ConfigurationData.NonNodeData.$k")
        }
        $lines.Add('        }')
    }
    $lines.Add('    }')
    $lines.Add('}')
    $lines -join "`n"
}

function Get-PEGuiEffect {
    # One line saying what an action does to one finding, by tenant role. Mirrors the actions table in the GUI spec.
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)]$Finding, [Parameter(Mandatory)][string]$Role)
    $t = $Role.ToLowerInvariant()
    switch ($Action) {
        'Accept' {
            switch ($Finding.kind) {
                'Missing' { if ($Role -eq 'Master') { 'Re-create it in the master from the blueprint' } else { 'Create it in the replica from the blueprint' } }
                'Changed' { "Update the $t to match the blueprint" }
                'TargetOnly' { "Remove it from the $t" }
                'PossibleRename' { "Rename '$($Finding.other)' back to '$($Finding.key)' in the $t" }
            }
        }
        'Promote' {
            # Only the tenant's own blueprint changes; no tenant is written to.
            switch ($Finding.kind) {
                'Missing' { "Remove it from the blueprint (the $t already lacks it)" }
                'Changed' { "Update the blueprint to the $t's settings" }
                'TargetOnly' { 'Add it to the blueprint' }
                'PossibleRename' { "Rename it to '$($Finding.other)' in the blueprint" }
            }
        }
        'Exclude' { if ($Finding.kind -eq 'TargetOnly') { "Keep it in the $t as unmanaged" } else { "Stop managing it in the $t" } }
        'ExcludeProperty' { 'Ignore this value as noise; a different value still shows as drift' }
        'ExcludePropertyForTenant' { "Stop enforcing this setting in the ${t}: it stays visible, does not count as drift and a revert leaves it as it is" }
        'Unexclude' { 'Manage it again; it shows as drift if it differs' }
    }
}

function Test-PEGuiWritesMaster {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$Role)
    $Action -eq 'Accept' -and $Role -eq 'Master'
}

function Get-PEGuiConfigEntry {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)]$Finding, [Parameter(Mandatory)][string]$Role, $Item)
    $bp = if ($Item) { $Item.blueprint } else { $null }
    $tv = if ($Item) { $Item.target } else { $null }
    $rt = $Finding.resourceType
    $entry = { param($key, $ensure, $props) [pscustomobject]@{ ResourceType = $rt; Key = $key; Ensure = $ensure; Properties = $props } }
    if ($Action -eq 'Accept') {
        switch ($Finding.kind) {
            { $_ -in 'Missing', 'Changed' } { return @(& $entry $Finding.key 'Present' $bp) }
            'TargetOnly' { return @(& $entry $Finding.key 'Absent' $null) }
            'PossibleRename' { return @((& $entry $Finding.key 'Present' $bp), (& $entry $Finding.other 'Absent' $null)) }
        }
    }
    @()
}

function Get-PEGuiPreviewConfig {
    # The configuration text the dialog shows. For Revert it is the text the engine generated for these items (stored by
    # Export-PEGuiData with each item), so the preview is what will run; without engine output (the mock data set) it is
    # the approximate text from New-PEGuiMockConfig.
    param([string]$DataRoot, [string]$TenantId, [string]$Action, $RevertItems, $Entries, [string]$Target)
    if (-not @($Entries).Count) { return $null }
    $withEngine = @($RevertItems | Where-Object { $_.revert })
    $wrapper = if ($Action -eq 'Accept' -and $withEngine.Count -and $TenantId -cmatch $script:TenantIdPattern) { Read-PEGuiFile -DataRoot $DataRoot -RelativePath "tenants/$TenantId/revert-wrapper.json" } else { $null }
    if (-not $wrapper) { return New-PEGuiMockConfig -Name 'preview' -Target $Target -Entries $Entries }
    $blocks = foreach ($r in $RevertItems) {
        if ($r.revert -and $r.revert.block) { $r.revert.block }
        else { "        # $($r.label): no configuration could be generated$(if ($r.revert -and $r.revert.error) { ': ' + $r.revert.error })" }
    }
    $head = ($wrapper.Head -replace 'Resource instances: \d+', "Resource instances: $(@($RevertItems).Count)") -replace '(?m)^Configuration \S+', 'Configuration PE_preview'
    ($head, ($blocks -join "`n`n"), $wrapper.Tail) -join "`n"
}

function Get-PEGuiProperty {
    # Reads a property that may be absent from a request object or hashtable.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Assert-PEGuiStandardName {
    param([string]$Name)
    if ($Name -cnotmatch $script:StandardNamePattern) { throw "Invalid standard name '$Name'." }
}

function Get-PEGuiStandardIndex {
    param([Parameter(Mandatory)][string]$DataRoot)
    $list = Read-PEGuiFile -DataRoot $DataRoot -RelativePath 'standards/index.json'
    if ($null -eq $list) { @() } else { @($list) }
}

function Get-PEGuiStandardCoverage {
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$Name)
    Assert-PEGuiStandardName -Name $Name
    $file = Read-PEGuiFile -DataRoot $DataRoot -RelativePath "standards/$Name/coverage.json"
    if ($null -eq $file) { throw "Unknown standard '$Name'." }
    $file
}

function Get-PEGuiTenantStandard {
    # One tenant's latest check against one standard (tenants/<id>/standards/<name>.json).
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$Name)
    $null = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $TenantId
    Assert-PEGuiStandardName -Name $Name
    $file = Read-PEGuiFile -DataRoot $DataRoot -RelativePath "tenants/$TenantId/standards/$Name.json"
    if ($null -eq $file) { throw "Unknown standard '$Name'." }
    $file
}

function Get-PEGuiStandardRequestPreview {
    <#
        Validates the standards requests (StandardCheck, Adopt, AcceptRisk, RemoveRisk, ImportStandard, CheckStandardRelease) and says
        what they would do; the same shape as Get-PEGuiRequestPreview returns. The rows come from the tenant's standard view model, so
        a request the page should not have offered (the row's allowedActions) is refused here. None of them writes a tenant.
    #>
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)]$Request)
    $errors = [Collections.Generic.List[string]]::new()
    $items = [Collections.Generic.List[object]]::new()
    $action = [string](Get-PEGuiProperty $Request 'action')
    $standard = [string](Get-PEGuiProperty $Request 'standard')
    $tenantId = [string](Get-PEGuiProperty $Request 'tenantId')
    $reason = [string](Get-PEGuiProperty $Request 'reason')
    $tag = [string](Get-PEGuiProperty $Request 'tag')
    $reqItems = @(Get-PEGuiProperty $Request 'items' | Where-Object { $null -ne $_ })
    $index = Get-PEGuiIndex -DataRoot $DataRoot
    $writesMaster = $false
    $role = $null
    $own = $null
    $versionAfter = $null

    if ($standard -cnotmatch $script:StandardNamePattern) {
        $errors.Add("Invalid standard name '$standard'.")
    } else {
        $known = if ($action -in 'ImportStandard', 'CheckStandardRelease') {
            @((Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\src\PolicyEngine\Data\StandardSources.psd1')).Keys)
        } else { @(Get-PEGuiStandardIndex -DataRoot $DataRoot | ForEach-Object { [string]$_.name }) }
        if ($standard -cnotin $known) { $errors.Add("Unknown standard '$standard'.") }
    }
    if ($action -in $script:ReasonRequired -and -not $reason.Trim()) { $errors.Add("A reason is required for $action.") }

    $tenant = $null
    if ($action -in 'StandardCheck', 'Adopt', 'AcceptRisk', 'RemoveRisk') {
        try { $tenant = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $tenantId } catch { $errors.Add($_.Exception.Message) }
        if ($tenant) { $role = [string]$tenant.role }
    }

    if ($action -eq 'StandardCheck') {
        if ($tenant -and [bool](Get-PEGuiProperty $tenant 'offline')) { $errors.Add("Tenant '$tenantId' is offline: a standard check reads the tenant.") }
        if (@(Get-PEGuiActiveJob -DataRoot $DataRoot | Where-Object { $_.action -eq 'StandardCheck' -and [string]$_.tenantId -ceq $tenantId }).Count) { $errors.Add('A standard check is already running for this tenant.') }
    } elseif ($action -eq 'ImportStandard') {
        if ($tag -and $tag -cnotmatch '^v\d+\.\d+\.\d+$') { $errors.Add("Release tag '$tag' is not of the form vX.Y.Z.") }
        if (@(Get-PEGuiActiveJob -DataRoot $DataRoot | Where-Object { $_.action -eq 'ImportStandard' }).Count) { $errors.Add('A standard import is already running.') }
    } elseif ($action -in 'Adopt', 'AcceptRisk', 'RemoveRisk') {
        if ($reqItems.Count -eq 0) { $errors.Add('A request needs at least one item.') }
        $view = $null
        if ($tenant -and $standard -cmatch $script:StandardNamePattern) { $view = Read-PEGuiFile -DataRoot $DataRoot -RelativePath "tenants/$tenantId/standards/$standard.json" }
        if ($tenant -and (-not $view -or -not [bool](Get-PEGuiProperty $view 'checked'))) { $errors.Add("Tenant '$tenantId' has no check against standard '$standard' yet.") }
        if ($action -eq 'Adopt' -and $tenant) {
            $own = Get-PEGuiOwnBlueprint -DataRoot $DataRoot -TenantId $tenantId
            $writesMaster = $own.name -ceq [string]$index.blueprint.name
            # A replica with no blueprint of its own would resolve to the master blueprint: never write that from a replica.
            if ($role -eq 'Replica' -and $writesMaster) { $errors.Add("Replica '$tenantId' has no blueprint of its own, so Adopt would change the master blueprint. Give it one first (Initialize-PETenantBlueprint).") }
            $versionAfter = Get-PEGuiNextBlueprintVersion -DataRoot $DataRoot -TenantId $tenantId
        }
        if ($view -and [bool](Get-PEGuiProperty $view 'checked')) {
            $allowed = @{ Adopt = 'Adopt'; AcceptRisk = 'AcceptRisk'; RemoveRisk = 'RemoveRisk' }[$action]
            foreach ($ri in $reqItems) {
                $itemId = [string](Get-PEGuiProperty $ri 'itemId')
                $row = @($view.rows) | Where-Object { $_.itemId -ceq $itemId } | Select-Object -First 1
                if (-not $row) { $errors.Add("No row for '$itemId' in the check of tenant '$tenantId' against '$standard'."); continue }
                if ($allowed -notin @($row.allowedActions)) { $errors.Add("$action is not allowed on '$($row.key)' ($($row.status))."); continue }
                $label = "$(Get-PEGuiTypeName $row.resourceType) · $($row.key)"
                $resolved = [ordered]@{ itemId = $itemId; resourceType = [string]$row.resourceType; key = [string]$row.key; label = $label; effect = '' }
                if ($action -eq 'Adopt') {
                    $resolved.effect = "Copies the standard's setting into blueprint $($own.name). The tenant is not changed."
                } elseif ($action -eq 'RemoveRisk') {
                    $resolved.effect = 'The difference counts again.'
                } else {
                    $by = ([string](Get-PEGuiProperty $ri 'approvedBy')).Trim()
                    $why = ([string](Get-PEGuiProperty $ri 'why')).Trim()
                    if (-not $by) { $errors.Add("Accept risk needs 'approved by' for '$($row.key)'.") }
                    if (-not $why) { $errors.Add("Accept risk needs 'why' for '$($row.key)'.") }
                    $properties = @(@(Get-PEGuiProperty $ri 'properties') | Where-Object { $_ } | ForEach-Object { [string]$_ })
                    $differing = @(@($row.differences) | ForEach-Object { [string]$_.property })
                    foreach ($property in $properties) { if ($property -cnotin $differing) { $errors.Add("'$property' does not differ on '$($row.key)'.") } }
                    $resolved.approvedBy = $by
                    $resolved.why = $why
                    $resolved.properties = $properties
                    $resolved.effect = "Records that $by accepted this difference: $why."
                    if ($properties.Count) { $resolved.label = "$label · $($properties -join ', ')" }
                }
                $items.Add([pscustomobject]$resolved)
            }
        }
    }
    if ($writesMaster -and -not [bool](Get-PEGuiProperty $Request 'confirmedMasterWrite')) { $errors.Add('This writes to the master tenant and needs confirmedMasterWrite.') }
    [pscustomobject]@{
        valid                 = $errors.Count -eq 0
        errors                = @($errors)
        action                = $action
        tenantId              = $(if ($tenantId) { $tenantId } else { $null })
        standard              = $standard
        tag                   = $(if ($tag) { $tag } else { $null })
        role                  = $role
        items                 = @($items)
        writesMaster          = $writesMaster
        destructive           = $writesMaster
        reasonRequired        = $action -in $script:ReasonRequired
        blueprintName         = $(if ($own) { [string]$own.name } else { $null })
        blueprintVersionAfter = $versionAfter
        targetBlueprint       = $null
        targetVersion         = $null
        sourceVersion         = $null
        config                = $null
    }
}
function Get-PEGuiRequestPreview {
    <#
        Validates a draft request and says what it would do. The same checks run again in New-PEGuiRequest, so a
        request the page should not have offered is refused here, not only hidden in the page.
        Request: @{ action; tenantId; items = @(@{ itemId; property; resourceType; value }); reason;
                    confirmedMasterWrite; targetVersion }
    #>
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)]$Request)
    if ([string](Get-PEGuiProperty $Request 'action') -in $script:StandardActions) { return Get-PEGuiStandardRequestPreview -DataRoot $DataRoot -Request $Request }
    $errors = [Collections.Generic.List[string]]::new()
    $items = [Collections.Generic.List[object]]::new()
    $entries = [Collections.Generic.List[object]]::new()
    $revertItems = [Collections.Generic.List[object]]::new()
    $changes = @()
    $writesMaster = $false
    $destructive = $false
    $role = $null
    $tenantId = $null
    $targetBlueprint = $null
    $targetVersion = $null
    $sourceVersion = $null
    $index = Get-PEGuiIndex -DataRoot $DataRoot
    $current = [int]$index.blueprint.version
    $action = [string](Get-PEGuiProperty $Request 'action')
    $reason = [string](Get-PEGuiProperty $Request 'reason')
    $reqItems = @(Get-PEGuiProperty $Request 'items' | Where-Object { $null -ne $_ })
    $known = 'Accept', 'Promote', 'Exclude', 'ExcludeProperty', 'ExcludePropertyForTenant', 'IncludePropertyForTenant', 'Unexclude', 'RevertBlueprint', 'Recheck', 'ConnectTenant', 'RenameTenant', 'ReviewModule', 'PromoteUp', 'PullDown', 'UploadSnapshot', 'GenerateConfig'

    if ($action -notin $known) { $errors.Add("Unknown action '$action'.") }
    if ($action -in $script:ReasonRequired -and -not $reason.Trim()) { $errors.Add("A reason is required for $action.") }

    $noiseUnexclude = $action -eq 'Unexclude' -and $reqItems.Count -gt 0 -and (Get-PEGuiProperty $reqItems[0] 'property')
    if ($action -in 'Accept', 'Promote', 'Exclude', 'ExcludeProperty', 'ExcludePropertyForTenant' -or ($action -eq 'Unexclude' -and -not $noiseUnexclude)) {
        $tenantId = [string](Get-PEGuiProperty $Request 'tenantId')
        $tenant = $null
        try { $tenant = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $tenantId } catch { $errors.Add($_.Exception.Message) }
        if ($reqItems.Count -eq 0) { $errors.Add('A request needs at least one item.') }
        # A replica with no blueprint of its own would resolve to the master blueprint: never write that from a replica.
        if ($action -eq 'Promote' -and $tenant -and [string](Get-PEGuiProperty $tenant 'role') -eq 'Replica' -and (Get-PEGuiOwnBlueprint -DataRoot $DataRoot -TenantId $tenantId).name -ieq [string]$index.blueprint.name) {
            $errors.Add("Replica '$tenantId' has no blueprint of its own, so Promote would change the master blueprint. Give it one first (Initialize-PETenantBlueprint).")
        }
        if ($action -eq 'ExcludeProperty' -and $reqItems.Count -ne 1) { $errors.Add('A noise rule applies to exactly one property of one item.') }
        if ($action -eq 'ExcludePropertyForTenant' -and $reqItems.Count -ne 1) { $errors.Add('A property exclusion applies to exactly one property of one item.') }
        if ($tenant) {
            $role = $tenant.role
            $findings = Get-PEGuiFinding -DataRoot $DataRoot -TenantId $tenantId
            foreach ($ri in $reqItems) {
                $itemId = [string](Get-PEGuiProperty $ri 'itemId')
                $f = $findings | Where-Object { $_.itemId -and $_.itemId -eq $itemId } | Select-Object -First 1
                if (-not $f) { $errors.Add("No finding for '$itemId' in the $($role.ToLowerInvariant())."); continue }
                if ($action -notin $f.allowedActions)
                {
                    $why = if ($action -eq 'Accept' -and $f.PSObject.Properties['revertBlocked'] -and $f.revertBlocked) { ' ' + $f.revertBlocked } else { '' }
                    $errors.Add("$action is not allowed on '$($f.key)' ($($f.kind), $($f.state)).$why")
                    continue
                }
                if ($action -eq 'Exclude' -and $f.kind -ne 'TargetOnly' -and $role -ne 'Replica') { $errors.Add("'$($f.key)' is $($f.kind.ToLowerInvariant()) on the master: only a replica can stop managing an item that is missing or changed."); continue }
                $item = Get-PEGuiItem -DataRoot $DataRoot -TenantId $tenantId -ItemId $itemId
                $label = "$(Get-PEGuiTypeName $f.resourceType) · $($f.key)"
                $resolved = [ordered]@{ itemId = $itemId; resourceType = $f.resourceType; key = $f.key; findingKind = $f.kind; label = $label; effect = Get-PEGuiEffect -Action $action -Finding $f -Role $role }
                if ($action -eq 'ExcludeProperty') {
                    $prop = [string](Get-PEGuiProperty $ri 'property')
                    $diff = @($f.differences) | Where-Object property -EQ $prop | Select-Object -First 1
                    if (-not $diff) { $errors.Add("'$prop' does not differ on '$($f.key)'."); continue }
                    $resolved.property = $prop
                    $resolved.value = $diff.target
                    $resolved.scope = if (Get-PEGuiProperty $ri 'scopeItem') { 'item' } else { 'type' }
                    $resolved.label = "$label · $prop = $($diff.target -join ', ')"
                }
                if ($action -eq 'ExcludePropertyForTenant') {
                    $prop = [string](Get-PEGuiProperty $ri 'property')
                    if (-not (@($f.differences) | Where-Object property -EQ $prop | Select-Object -First 1)) { $errors.Add("'$prop' does not differ on '$($f.key)'."); continue }
                    $resolved.property = $prop
                    $resolved.scope = if (Get-PEGuiProperty $ri 'scopeItem') { 'item' } else { 'type' }
                    $resolved.label = "$label · $prop"
                }
                $items.Add([pscustomobject]$resolved)
                if (Test-PEGuiWritesMaster -Action $action -Role $role) { $writesMaster = $true }
                foreach ($e in (Get-PEGuiConfigEntry -Action $action -Finding $f -Role $role -Item $item)) { $entries.Add($e) }
                if ($action -eq 'Accept') { $revertItems.Add([pscustomobject]@{ label = $label; revert = (Get-PEGuiProperty $item 'revert') }) }
            }
        }
    } elseif ($noiseUnexclude) {
        $rules = @((Get-PEGuiExclusion -DataRoot $DataRoot).noise)
        foreach ($ri in $reqItems) {
            $rt = [string](Get-PEGuiProperty $ri 'resourceType'); $prop = [string](Get-PEGuiProperty $ri 'property')
            $val = ConvertTo-Json -InputObject (Get-PEGuiProperty $ri 'value') -Compress -Depth 5
            $rule = $rules | Where-Object { $_.resourceType -eq $rt -and $_.property -eq $prop -and (ConvertTo-Json -InputObject $_.value -Compress -Depth 5) -eq $val } | Select-Object -First 1
            if (-not $rule) { $errors.Add("No noise rule for $rt.$prop with that value."); continue }
            $items.Add([pscustomobject]@{ resourceType = $rt; property = $prop; value = $rule.value; label = "$(Get-PEGuiTypeName $rt) · $prop = $($rule.value -join ', ')"; effect = 'Stop ignoring this value' })
        }
    } elseif ($action -eq 'IncludePropertyForTenant') {
        # Brings an excluded property back: the rule is looked up in the exported list, so only an existing exclusion of this tenant can be removed.
        $tenantId = [string](Get-PEGuiProperty $Request 'tenantId')
        $rules = @((Get-PEGuiExclusion -DataRoot $DataRoot).propertyExclusions | Where-Object { $_ })
        if ($reqItems.Count -eq 0) { $errors.Add('A request needs at least one item.') }
        foreach ($ri in $reqItems) {
            $rt = [string](Get-PEGuiProperty $ri 'resourceType'); $prop = [string](Get-PEGuiProperty $ri 'property'); $rid = [string](Get-PEGuiProperty $ri 'itemId')
            $rule = $rules | Where-Object { $_.tenantId -eq $tenantId -and $_.resourceType -eq $rt -and $_.property -eq $prop -and [string]$_.itemId -eq $rid } | Select-Object -First 1
            if (-not $rule) { $errors.Add("No exclusion of $rt.$prop for tenant '$tenantId'."); continue }
            $items.Add([pscustomobject]@{ resourceType = $rt; key = $rule.key; itemId = $rule.itemId; property = $prop; label = "$(Get-PEGuiTypeName $rt) · $prop"; effect = 'Enforce this setting again; it shows as drift if it differs' })
        }
    } elseif ($action -eq 'ConnectTenant') {
        # Registers a tenant whose Reader (and Writer) app was created with DSC's own commands. Everything is checked again
        # in the engine; the shapes are checked here so a bad request never becomes a job.
        $c = Get-PEGuiProperty $Request 'connect'
        $slug = [string](Get-PEGuiProperty $c 'slug')
        $guid = '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
        if ($slug -cnotmatch '^[a-z0-9][a-z0-9-]{0,39}$') { $errors.Add('The short name must be 1 to 40 lower-case letters, digits or hyphens.') }
        elseif ($slug -eq 'master') { $errors.Add("'master' is the tenant the blueprint is taken from; connect that one from PowerShell.") }
        if ([string](Get-PEGuiProperty $c 'tenantDomain') -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$') { $errors.Add('Enter the tenant domain, for example contoso.onmicrosoft.com.') }
        $create = ([string](Get-PEGuiProperty $c 'mode') -eq 'create')
        if (-not $create -and [string](Get-PEGuiProperty $c 'readerApplicationId') -notmatch $guid) { $errors.Add('The Reader application (client) id must be a GUID.') }
        if (-not $create -and [string](Get-PEGuiProperty $c 'readerThumbprint') -notmatch '^[0-9A-Fa-f]{40}$') { $errors.Add('The Reader certificate thumbprint must be 40 hex characters.') }
        $wid = [string](Get-PEGuiProperty $c 'writerApplicationId'); $wth = [string](Get-PEGuiProperty $c 'writerThumbprint')
        if (-not $create -and ($wid -or $wth)) {
            if ($wid -notmatch $guid) { $errors.Add('The Writer application (client) id must be a GUID.') }
            if ($wth -notmatch '^[0-9A-Fa-f]{40}$') { $errors.Add('The Writer certificate thumbprint must be 40 hex characters.') }
        }
        $dn = [string](Get-PEGuiProperty $c 'displayName')
        if ($dn.Length -gt 80 -or $dn -match '[\x00-\x1f]') { $errors.Add('The display name must be at most 80 characters, without control characters.') }
    } elseif ($action -in 'PromoteUp', 'PullDown') {
        # Blueprint to blueprint: only the target blueprint changes, never a tenant. Promote up takes the tenant blueprint's
        # differences into the master blueprint; update tenant blueprint takes the master blueprint's into the tenant's own.
        $tenantId = [string](Get-PEGuiProperty $Request 'tenantId')
        $moves = $null
        try {
            $moveTenant = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $tenantId
            $layers = @(@(Get-PEGuiProperty $moveTenant 'layers') | Where-Object { $_ })
            if ($layers.Count -lt 2) { $errors.Add("Tenant '$tenantId' follows one blueprint layer, so there is nothing to move between layers.") }
            else { $moves = Read-PEGuiFile -DataRoot $DataRoot -RelativePath "tenants/$tenantId/moves.json" }
            if ($layers.Count -ge 2 -and -not $moves) { $errors.Add("The differences between the blueprints of '$tenantId' have not been exported yet; refresh the data and try again.") }
        } catch { $errors.Add($_.Exception.Message) }
        if ($moves) {
            $up = $action -eq 'PromoteUp'
            $target = if ($up) { $moves.master } else { $moves.own }
            $targetBlueprint = [string]$target.name
            $targetVersion = [int]$target.version
            $sourceVersion = [int]$(if ($up) { $moves.own.version } else { $moves.master.version })
            $rows = @($(if ($up) { $moves.up } else { $moves.down }) | Where-Object { $_ })
            $named = @($reqItems | ForEach-Object { [string](Get-PEGuiProperty $_ 'itemId') })
            if ($named.Count) {
                foreach ($id in $named) {
                    if (-not ($rows | Where-Object itemId -CEQ $id)) { $errors.Add("'$id' is not a difference between the blueprints; nothing to move for it.") }
                }
                $rows = @($rows | Where-Object { $_.itemId -cin $named })
            }
            if ($rows.Count -eq 0 -and -not $errors.Count) { $errors.Add('The blueprints do not differ; there is nothing to move.') }
            $verb = @{ Added = "Add it to blueprint '$targetBlueprint'"; Changed = "Update it in blueprint '$targetBlueprint'"; Removed = "Remove it from blueprint '$targetBlueprint'" }
            foreach ($r in $rows) {
                $items.Add([pscustomobject]@{ itemId = $r.itemId; resourceType = $r.resourceType; key = $r.key; op = $r.op; label = "$(Get-PEGuiTypeName $r.resourceType) · $($r.key)"; effect = $verb[[string]$r.op] })
            }
        }
    } elseif ($action -eq 'ReviewModule') {
        # Records the installed Microsoft365DSC version for the blueprints built with another one (Set-PEBlueprintModule). Writes to no tenant.
        if ($index.dsc.match -ne $false) { $errors.Add('Every blueprint was built with the installed Microsoft365DSC version already.') }
    } elseif ($action -eq 'RenameTenant') {
        # Changes only the friendly name in tenants.json; the slug stays the id. Writes to no tenant.
        $tenantId = [string](Get-PEGuiProperty $Request 'tenantId')
        try { Get-PEGuiTenant -DataRoot $DataRoot -TenantId $tenantId | Out-Null } catch { $errors.Add($_.Exception.Message) }
        $newName = ([string](Get-PEGuiProperty $Request 'displayName')).Trim()
        if (-not $newName) { $errors.Add('A name is required.') }
        elseif ($newName.Length -gt 80 -or $newName -match '[ -]') { $errors.Add('The name is longer than 80 characters or contains control characters.') }
    } elseif ($action -eq 'Recheck') {
        # A tenant-level request: read the tenant again and compare it with the blueprint. No items, no write to a tenant.
        $tenantId = [string](Get-PEGuiProperty $Request 'tenantId')
        $recheckTenant = $null
        try { $recheckTenant = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $tenantId } catch { $errors.Add($_.Exception.Message) }
        $scopeName = [string](Get-PEGuiProperty $Request 'scope')
        if ($scopeName -and $recheckTenant -and $scopeName -cnotin @(@(@(Get-PEGuiProperty $recheckTenant 'scopes') | Where-Object { $_ } | ForEach-Object { [string]$_.name }) + @(@(Get-PEGuiProperty $recheckTenant 'typeScopes') | Where-Object { $_ } | ForEach-Object { [string]$_.type }))) { $errors.Add("Unknown scope '$scopeName'.") }
        # Use the snapshot as the tenant's blueprint: only a replica (the master blueprint changes through Promote) and only a whole snapshot, not a refresh of one scope.
        if ([bool](Get-PEGuiProperty $Request 'baseline')) {
            if ($tenantId -eq 'master') { $errors.Add('The master tenant has no blueprint of its own: the master blueprint changes through Promote.') }
            if ($scopeName) { $errors.Add('A refresh of one scope cannot become the blueprint: take a whole snapshot.') }
        }
        if (@(Get-PEGuiActiveJob -DataRoot $DataRoot | Where-Object { $_.action -eq 'Recheck' }).Count) { $errors.Add('A snapshot or refresh is already running.') }
    } elseif ($action -eq 'UploadSnapshot') {
        # DSC export files of an offline tenant, with the text in the request. Everything is checked again in the engine
        # (New-PEUploadCheck); the shapes are checked here so a bad request never becomes a job. No tenant is written to.
        $tenantId = [string](Get-PEGuiProperty $Request 'tenantId')
        $newTenant = Get-PEGuiProperty $Request 'newTenant'
        $files = @(Get-PEGuiProperty $Request 'files' | Where-Object { $null -ne $_ })
        if ($files.Count -eq 0) { $errors.Add('Choose at least one file.') }
        elseif ($files.Count -gt 50) { $errors.Add('At most 50 files can be uploaded at once.') }
        foreach ($f in $files) {
            $fileName = [string](Get-PEGuiProperty $f 'name')
            if (-not $fileName.Trim() -or $fileName.Length -gt 200 -or $fileName -match '[\x00-\x1f]') { $errors.Add('Every file needs a name of at most 200 characters, without control characters.') }
            elseif (-not [string](Get-PEGuiProperty $f 'text')) { $errors.Add("The file '$fileName' has no text.") }
        }
        if ($newTenant) {
            $newSlug = [string](Get-PEGuiProperty $newTenant 'slug')
            if ($newSlug -cnotmatch '^[a-z0-9][a-z0-9-]{0,39}\z') { $errors.Add('The short name must be 1 to 40 lower-case letters, digits or hyphens.') }
            elseif ($newSlug -eq 'master') { $errors.Add("'master' is the tenant the blueprint is taken from; it cannot be an uploaded tenant.") }
            elseif (@($index.tenants | Where-Object { $_.tenantId -ceq $newSlug }).Count) { $errors.Add("A tenant with the short name '$newSlug' is already registered.") }
            if ($newSlug -cne $tenantId) { $errors.Add('The tenant id of a new tenant is its short name.') }
            $newName = [string](Get-PEGuiProperty $newTenant 'displayName')
            if ($newName.Length -gt 80 -or $newName -match '[\x00-\x1f]') { $errors.Add('The display name must be at most 80 characters, without control characters.') }
        } else {
            try { Get-PEGuiTenant -DataRoot $DataRoot -TenantId $tenantId | Out-Null } catch { $errors.Add($_.Exception.Message) }
            if ($tenantId -eq 'master') { $errors.Add('The master tenant is read live; there is nothing to upload for it.') }
        }
        $domain = [string](Get-PEGuiProperty $Request 'tenantDomain')
        if ($domain -and $domain -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z') { $errors.Add('The tenant domain must look like contoso.onmicrosoft.com.') }
        elseif (-not $domain -and $newTenant) { $errors.Add('Enter the tenant domain, for example contoso.onmicrosoft.com.') }
    } elseif ($action -eq 'GenerateConfig') {
        # The configuration the tenant's owner runs to bring it in line with its own blueprint (New-PEOfflineConfig). It reads the
        # latest check and writes three files for the job; nothing is written to a tenant, a blueprint or the decisions.
        $tenantId = [string](Get-PEGuiProperty $Request 'tenantId')
        $genTenant = $null
        try { $genTenant = Get-PEGuiTenant -DataRoot $DataRoot -TenantId $tenantId } catch { $errors.Add($_.Exception.Message) }
        if ($tenantId -eq 'master') { $errors.Add('The master tenant is the master blueprint; there is no configuration to generate for it.') }
        elseif ($genTenant -and @(@(Get-PEGuiProperty $genTenant 'layers') | Where-Object { $_ }).Count -lt 2) { $errors.Add("Tenant '$tenantId' has no blueprint of its own yet. Save an upload as its blueprint first, or move the wanted items into it.") }
    } elseif ($action -eq 'RevertBlueprint') {
        $versions = Get-PEGuiBlueprintVersion -DataRoot $DataRoot
        $target = Get-PEGuiProperty $Request 'targetVersion'
        if (-not ($target -as [int]) -or -not ($versions | Where-Object version -EQ ([int]$target))) { $errors.Add("Unknown blueprint version '$target'.") }
        elseif ([int]$target -eq $current) { $errors.Add("v$target is already the current version.") }
        else {
            $changes = Compare-PEGuiBlueprintVersion -Versions $versions -From $current -To ([int]$target)
            if ($reqItems.Count -gt 1) { $errors.Add('Restore one item at a time, or revert the whole blueprint.') }
            if ($reqItems.Count -eq 1) {
                $itemId = [string](Get-PEGuiProperty $reqItems[0] 'itemId')
                $changes = @($changes | Where-Object itemId -EQ $itemId)
            }
            if ($changes.Count -eq 0) { $errors.Add("v$target does not differ from v$current for this scope.") }
            foreach ($c in $changes) { $items.Add([pscustomobject]@{ itemId = $c.itemId; resourceType = $c.resourceType; key = $c.key; label = "$(Get-PEGuiTypeName $c.resourceType) · $($c.key)"; effect = "$($c.op) in the blueprint" }) }
        }
    }

    if ($writesMaster -and -not [bool](Get-PEGuiProperty $Request 'confirmedMasterWrite')) {
        $errors.Add('This writes to the master tenant and needs confirmedMasterWrite.')
    }
    $valid = $errors.Count -eq 0
    # Destructive: anything that writes to the master, or any config that deletes something (Ensure = 'Absent').
    $destructive = $writesMaster -or [bool]($entries | Where-Object Ensure -EQ 'Absent')
    $targetTenant = if ($tenantId) { $index.tenants | Where-Object tenantId -CEQ $tenantId } else { $null }
    $configTarget = if ($targetTenant) { "$($targetTenant.tenantId) ($($targetTenant.displayName))" } else { '' }
    [pscustomobject]@{
        valid                 = $errors.Count -eq 0
        errors                = @($errors)
        action                = $action
        tenantId              = $tenantId
        role                  = $role
        items                 = @($items)
        writesMaster          = $writesMaster
        destructive           = $destructive
        reasonRequired        = $action -in $script:ReasonRequired
        blueprintName         = if ($action -eq 'Promote') { (Get-PEGuiOwnBlueprint -DataRoot $DataRoot -TenantId $tenantId).name } elseif ($action -eq 'RevertBlueprint') { [string]$index.blueprint.name } elseif ($targetBlueprint -and $valid) { $targetBlueprint } else { $null }
        blueprintVersionAfter = if ($action -eq 'Promote') { Get-PEGuiNextBlueprintVersion -DataRoot $DataRoot -TenantId $tenantId } elseif ($action -eq 'RevertBlueprint') { Get-PEGuiNextBlueprintVersion -DataRoot $DataRoot } elseif ($action -eq 'PullDown' -and $valid) { Get-PEGuiNextBlueprintVersion -DataRoot $DataRoot -TenantId $tenantId } elseif ($action -eq 'PromoteUp' -and $valid) { Get-PEGuiNextBlueprintVersion -DataRoot $DataRoot } else { $null }
        targetBlueprint       = $targetBlueprint
        targetVersion         = $targetVersion
        sourceVersion         = $sourceVersion
        config                = Get-PEGuiPreviewConfig -DataRoot $DataRoot -TenantId $tenantId -Action $action -RevertItems $revertItems -Entries $entries -Target $configTarget
    }
}

function New-PEGuiRequest {
    # Writes requests/<requestId>.json and a queued job in activity/. Returns the preview with errors when invalid.
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)]$Request, [datetime]$Now = [datetime]::UtcNow)
    $preview = Get-PEGuiRequestPreview -DataRoot $DataRoot -Request $Request
    if (-not $preview.valid) { return [pscustomobject]@{ created = $false; errors = $preview.errors } }
    Invoke-PEGuiLocked -DataRoot $DataRoot -ScriptBlock { Add-PEGuiRequest -DataRoot $DataRoot -Request $Request -Preview $preview -Now $Now }
}

function Add-PEGuiRequest {
    # The part of New-PEGuiRequest that runs under the lock: numbers the job, claims a blueprint version and writes.
    param([string]$DataRoot, $Request, $Preview, [datetime]$Now)
    $preview = $Preview
    if ($preview.blueprintVersionAfter) { $preview.blueprintVersionAfter = Get-PEGuiNextBlueprintVersion -DataRoot $DataRoot -TenantId $(if ($preview.action -in 'Promote', 'PullDown', 'Adopt') { $preview.tenantId } else { '' }) }
    $requestId = $Now.ToString('yyyy-MM-ddTHH-mm-ss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $dir = Get-PEGuiPath -DataRoot $DataRoot -RelativePath 'activity'
    # @(if ...) keeps an empty folder an empty array; "$x = if ... { @() }" would assign $null and fail on .Count.
    $numbers = @(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Filter 'J-*.json' | ForEach-Object { [int]($_.BaseName -replace '\D', '') } })
    $jobNumber = if ($numbers.Count) { ($numbers | Measure-Object -Maximum).Maximum + 1 } else { 1 }
    $jobId = "J-$jobNumber"
    $stamp = $Now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $items = @($preview.items | ForEach-Object { $_ | Select-Object * -ExcludeProperty label, effect })
    $saved = [ordered]@{
        requestId            = $requestId
        requestedAt          = $stamp
        tenantId             = $preview.tenantId
        action               = $preview.action
        items                = $items
        reason               = [string](Get-PEGuiProperty $Request 'reason')
        confirmedMasterWrite = [bool]$preview.writesMaster
    }
    if ($preview.action -eq 'RevertBlueprint') {
        $saved.targetVersion = [int](Get-PEGuiProperty $Request 'targetVersion')
        # The saved items are everything the restore changes; this says whether the user asked for one item or the whole version.
        $saved.restoreItem = (@(Get-PEGuiProperty $Request 'items' | Where-Object { $null -ne $_ }).Count -eq 1)
    }
    if ($preview.action -eq 'ConnectTenant') {
        $c = Get-PEGuiProperty $Request 'connect'
        $saved.connect = [ordered]@{
            mode = $(if ([string](Get-PEGuiProperty $c 'mode') -eq 'create') { 'create' } else { 'register' }); createWriter = [bool](Get-PEGuiProperty $c 'createWriter'); writerRoles = [bool](Get-PEGuiProperty $c 'writerRoles')
            slug = [string](Get-PEGuiProperty $c 'slug'); displayName = [string](Get-PEGuiProperty $c 'displayName'); tenantDomain = [string](Get-PEGuiProperty $c 'tenantDomain')
            readerApplicationId = [string](Get-PEGuiProperty $c 'readerApplicationId'); readerThumbprint = [string](Get-PEGuiProperty $c 'readerThumbprint')
            writerApplicationId = [string](Get-PEGuiProperty $c 'writerApplicationId'); writerThumbprint = [string](Get-PEGuiProperty $c 'writerThumbprint')
        }
    }
    if ($preview.action -eq 'Recheck' -and (Get-PEGuiProperty $Request 'scope')) { $saved.scope = [string](Get-PEGuiProperty $Request 'scope') }
    if ($preview.action -eq 'Recheck' -and [bool](Get-PEGuiProperty $Request 'baseline')) { $saved.baseline = $true }
    if ($preview.action -in 'PromoteUp', 'PullDown') { $saved.expectedVersion = $(if ($null -ne (Get-PEGuiProperty $Request 'expectedVersion')) { [int](Get-PEGuiProperty $Request 'expectedVersion') } else { [int]$preview.targetVersion }); $saved.expectedSourceVersion = $(if ($null -ne (Get-PEGuiProperty $Request 'expectedSourceVersion')) { [int](Get-PEGuiProperty $Request 'expectedSourceVersion') } else { [int]$preview.sourceVersion }) }
    if ($preview.action -eq 'UploadSnapshot') {
        $nt = Get-PEGuiProperty $Request 'newTenant'
        $saved.files = @(@(Get-PEGuiProperty $Request 'files') | ForEach-Object { [ordered]@{ name = [string](Get-PEGuiProperty $_ 'name'); text = [string](Get-PEGuiProperty $_ 'text') } })
        $saved.tenantDomain = [string](Get-PEGuiProperty $Request 'tenantDomain')
        $saved.completeWorkloads = @(@(Get-PEGuiProperty $Request 'completeWorkloads') | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $saved.saveAsBlueprint = [bool](Get-PEGuiProperty $Request 'saveAsBlueprint')
        $saved.newTenant = $(if ($nt) { [ordered]@{ slug = [string](Get-PEGuiProperty $nt 'slug'); displayName = ([string](Get-PEGuiProperty $nt 'displayName')).Trim() } } else { $null })
    }
    if ($preview.action -in $script:StandardActions) {
        $saved.standard = [string]$preview.standard
        if ($preview.action -eq 'ImportStandard' -and $preview.tag) { $saved.tag = [string]$preview.tag }
    }
    if ($preview.action -eq 'RenameTenant') { $saved.displayName = ([string](Get-PEGuiProperty $Request 'displayName')).Trim() }
    Write-PEGuiFile -DataRoot $DataRoot -RelativePath "requests/$requestId.json" -InputObject $saved
    $config = if ($preview.config) { $preview.config -replace '^# Preview of preview', "# Preview of $jobId" -replace 'PE_preview', "PE_$($jobId -replace '-', '')" } else { $null }
    $job = [ordered]@{
        jobId = $jobId; requestId = $requestId; action = $preview.action; tenantId = $preview.tenantId
        items = @($preview.items | ForEach-Object { [ordered]@{ itemId = Get-PEGuiProperty $_ 'itemId'; resourceType = $_.resourceType; key = Get-PEGuiProperty $_ 'key'; label = $_.label } })
        status = 'Queued'; requestedAt = $stamp; updatedAt = $stamp; reason = $saved.reason; result = $null; config = $config
        blueprintName = $preview.blueprintName; blueprintVersionAfter = $preview.blueprintVersionAfter; targetVersion = $saved['targetVersion']; mock = $null -ne (Get-PEGuiIndex -DataRoot $DataRoot).PSObject.Properties['mockNow']
    }
    Write-PEGuiFile -DataRoot $DataRoot -RelativePath "activity/$jobId.json" -InputObject $job
    Write-PEGuiFile -DataRoot $DataRoot -RelativePath 'activity/active.json' -InputObject @(@(Get-PEGuiActiveJobId -DataRoot $DataRoot) + $jobId)
    [pscustomobject]@{ created = $true; requestId = $requestId; jobId = $jobId; errors = @() }
}

function Stop-PEGuiJob {
    <#
        Cancels a job; returns @{ StatusCode; Body }.
        - Queued: marked Cancelled at once (the worker only takes Queued jobs).
        - Running: only a Recheck (it reads a tenant and writes nothing to it). Anything else changes a tenant or a blueprint
          and stopping it halfway could leave it half-done, so it is refused with that explanation.
        - A running Recheck whose worker is alive and running it (activity/worker.json: that process exists, wrote the file in
          the last 10 minutes and names this job) is asked to stop (cancelRequested) and the worker stops the export within a
          second. Otherwise (no worker, a worker that was restarted, one busy with another job) nothing would ever honour the
          request, so the job is marked Cancelled here.
    #>
    param([Parameter(Mandatory)][string]$DataRoot, [Parameter(Mandatory)][string]$JobId)
    $answer = { param($code, $body) [pscustomobject]@{ StatusCode = $code; Body = $body } }
    if ($JobId -cnotmatch '^J-\d+$') { return & $answer 404 @{ error = 'No such job.' } }
    Invoke-PEGuiLocked -DataRoot $DataRoot -ScriptBlock {
        $readRaw = { param($relative) $p = Get-PEGuiPath -DataRoot $DataRoot -RelativePath $relative; if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -NoEnumerate -DateKind String } }
        $job = & $readRaw "activity/$JobId.json"
        if ($null -eq $job) { return & $answer 404 @{ error = "No such job: $JobId." } }
        if ($job.status -notin 'Queued', 'Running') { return & $answer 400 @{ error = "Job $JobId has already finished ($($job.status))." } }
        $stamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $finish = {
            param($text)
            $job.status = 'Cancelled'; $job.result = $text; $job.updatedAt = $stamp
            Write-PEGuiFile -DataRoot $DataRoot -RelativePath "activity/$JobId.json" -InputObject $job
            Write-PEGuiFile -DataRoot $DataRoot -RelativePath 'activity/active.json' -InputObject @(Get-PEGuiActiveJobId -DataRoot $DataRoot | Where-Object { $_ -ne $JobId })
            & $answer 200 @{ jobId = $JobId; status = 'Cancelled'; message = $text }
        }
        if ($job.status -eq 'Queued') { return & $finish 'Cancelled before it started.' }
        # Everything but Recheck, UploadSnapshot included (it registers a tenant and writes a check and a blueprint), is refused here;
        # so is GenerateConfig, whose files are written once and must not be left half-written.
        if ($job.action -ne 'Recheck') {
            return & $answer 400 @{ error = "A running $($job.action) cannot be cancelled: it changes things, and stopping it halfway could leave it half-done. Wait for it to finish." }
        }
        $beat = & $readRaw 'activity/worker.json'
        $alive = $false
        if ($null -ne $beat) {
            $at = [datetime]::MinValue
            $fresh = [datetime]::TryParse([string]$beat.at, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$at) -and (([datetime]::UtcNow - $at).TotalMinutes -le 10)
            $worker = Get-Process -Id ([int]$beat.pid) -ErrorAction SilentlyContinue
            $alive = $fresh -and $null -ne $worker -and $worker.ProcessName -in 'pwsh', 'powershell'
            $mine = [string]$beat.jobId -ceq $JobId
        }
        if (-not $alive) { return & $finish 'Cancelled: the worker was not running, so nothing was stopped (a worker that was running this job has been closed).' }
        if (-not $mine) { return & $finish 'Cancelled: the worker is not running this job (it was closed or restarted while the job ran), so nothing was stopped.' }
        $job | Add-Member -NotePropertyName cancelRequested -NotePropertyValue $true -Force
        $job.updatedAt = $stamp
        Write-PEGuiFile -DataRoot $DataRoot -RelativePath "activity/$JobId.json" -InputObject $job
        & $answer 200 @{ jobId = $JobId; status = 'Running'; message = 'Cancelling: the worker stops the export within a few seconds.' }
    }
}

function Update-PEGuiMockJob {
    # Mock only: a job the GUI queued runs after 1 s and succeeds after 4 s. View-model files are not changed;
    # the next real check would show the result.
    param([Parameter(Mandatory)][string]$DataRoot, [datetime]$Now = [datetime]::UtcNow)
    if (-not @(Get-PEGuiActiveJobId -DataRoot $DataRoot).Count) { return }
    Invoke-PEGuiLocked -DataRoot $DataRoot -ScriptBlock { Step-PEGuiMockJob -DataRoot $DataRoot -Now $Now }
}

function Step-PEGuiMockJob {
    param([string]$DataRoot, [datetime]$Now)
    $active = [Collections.Generic.List[string]]::new()
    foreach ($job in Get-PEGuiActiveJob -DataRoot $DataRoot) {
        if (-not $job.mock -or $job.status -notin 'Queued', 'Running') { continue }
        $active.Add($job.jobId)
        $requested = if ($job.requestedAt -is [datetime]) { $job.requestedAt.ToUniversalTime() } else {
            [datetime]::Parse($job.requestedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        }
        $age = ($Now - $requested).TotalSeconds
        $next = if ($age -ge 4) { 'Succeeded' } elseif ($age -ge 1) { 'Running' } else { $null }
        if (-not $next -or $next -eq $job.status) { continue }
        if ($next -eq 'Succeeded') { $null = $active.Remove($job.jobId) }
        $job.status = $next
        $job.updatedAt = $Now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $job.result = if ($next -eq 'Running') { 'Applying (mock)' } else {
            switch ($job.action) {
                'Accept' { 'Applied (mock). Shows as aligned after the next check.' }
                'Promote' { "Applied (mock). Blueprint v$($job.blueprintVersionAfter) recorded. Shows as aligned after the next check." }
                'RevertBlueprint' { "Blueprint v$($job.blueprintVersionAfter) recorded as a copy of v$($job.targetVersion) (mock). No tenant was changed." }
                'Exclude' { 'Exclusion recorded (mock).' }
                'ExcludeProperty' { 'Noise rule recorded (mock).' }
                'ExcludePropertyForTenant' { 'Property exclusion recorded (mock).' }
                'IncludePropertyForTenant' { 'Property enforced again (mock).' }
                'Unexclude' { 'Back under management (mock).' }
                'StandardCheck' { 'Standard check finished (mock). The data is unchanged.' }
                'Adopt' { "Applied (mock). Blueprint v$($job.blueprintVersionAfter) recorded. No tenant was changed." }
                'AcceptRisk' { 'Accepted risk recorded (mock).' }
                'RemoveRisk' { 'Accepted risk removed (mock).' }
                'ImportStandard' { 'Standard imported (mock).' }
                'CheckStandardRelease' { 'Latest release found (mock).' }
                'Recheck' { 'Snapshot finished (mock). The data is unchanged.' }
                'ConnectTenant' { 'Tenant registered (mock).' }
                'UploadSnapshot' { 'Snapshot uploaded (mock).' }
                'GenerateConfig' { 'Configuration generated (mock); no files are written in mock mode.' }
                default { 'Done (mock).' }
            }
        }
        Write-PEGuiFile -DataRoot $DataRoot -RelativePath "activity/$($job.jobId).json" -InputObject $job
    }
    Write-PEGuiFile -DataRoot $DataRoot -RelativePath 'activity/active.json' -InputObject @($active)
}

function Get-PEGuiConfigFile {
    <#
        One file a GenerateConfig job wrote (configs/<jobId>/): Changes and Removals as text, Manual as JSON. A file reply is
        @{ StatusCode = 200; Json = $null; Text; ContentType; FileName }. The file name comes from a fixed list, never from the
        request, and the job must be a GenerateConfig job that succeeded; anything else is 404.
    #>
    param([Parameter(Mandatory)][string]$DataRoot, [string]$JobId, [string]$File)
    $notFound = [pscustomobject]@{ StatusCode = 404; Json = (ConvertTo-Json -InputObject @{ error = 'No such configuration file.' }) }
    # Pode adds '; charset=utf-8' to the content type itself.
    $files = @{ Changes = 'Changes.ps1', 'text/plain'; Removals = 'Removals.ps1', 'text/plain'; Manual = 'Manual.json', 'application/json' }
    if ($JobId -cnotmatch '\AJ-[0-9]+\z' -or $File -cnotin 'Changes', 'Removals', 'Manual') { return $notFound }
    $name, $type = $files[$File]
    $job = Read-PEGuiFile -DataRoot $DataRoot -RelativePath "activity/$JobId.json"
    if ($null -eq $job -or [string]$job.action -cne 'GenerateConfig' -or [string]$job.status -cne 'Succeeded') { return $notFound }
    $path = Get-PEGuiPath -DataRoot $DataRoot -RelativePath "configs/$JobId/$name"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $notFound }
    # ReadAllText drops the byte order mark the worker writes.
    [pscustomobject]@{ StatusCode = 200; Json = $null; Text = [IO.File]::ReadAllText($path); ContentType = $type; FileName = "$JobId-$name" }
}

function Invoke-PEGuiApi {
    <#
        Answers one API call: returns @{ StatusCode; Json }. The Pode routes in server.ps1 pass the method, path, query
        and parsed body straight through, so the whole API can be tested without a web server. A configuration download
        (Get-PEGuiConfigFile) also carries Text, ContentType and FileName, and the server writes Text instead of Json.
    #>
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Query = @{},
        $Body = $null
    )
    $json = {
        param($value, $array)
        if (-not $array) { return ConvertTo-Json -InputObject $value -Depth 20 }
        # An empty list reaches here as $null; it must still be [] and never [null].
        $list = @($value | Where-Object { $null -ne $_ })
        if ($list.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $list -Depth 20 }
    }
    $reply = { param($code, $text) [pscustomobject]@{ StatusCode = $code; Json = $text } }
    try {
        $m = $Method.ToUpperInvariant()
        $p = $Path.TrimEnd('/')
        if ($m -eq 'GET') {
            switch -Regex ($p) {
                '^/api/index$' { return & $reply 200 (& $json (Get-PEGuiIndex -DataRoot $DataRoot)) }
                '^/api/tenant-setup$' {
                    $setup = Read-PEGuiFile -DataRoot $DataRoot -RelativePath 'tenant-setup.json'
                    return & $reply 200 (& $json $(if ($setup) { $setup } else { @{ script = '' } }))
                }
                '^/api/resource-types$' { return & $reply 200 (& $json (Get-PEGuiResourceType)) }
                '^/api/blueprint$' { return & $reply 200 (& $json (Get-PEGuiBlueprintVersion -DataRoot $DataRoot -Name ([string](Get-PEGuiProperty $Query 'name'))) $true) }
                '^/api/exclusions$' { return & $reply 200 (& $json (Get-PEGuiExclusion -DataRoot $DataRoot)) }
                '^/api/activity$' { return & $reply 200 (& $json (Get-PEGuiActivity -DataRoot $DataRoot) $true) }
                '^/api/activity/active$' { return & $reply 200 (& $json (Get-PEGuiActiveJob -DataRoot $DataRoot) $true) }
                '^/api/blueprint/compare$' {
                    $from = Get-PEGuiProperty $Query 'from'; $to = Get-PEGuiProperty $Query 'to'
                    if (-not ($from -as [int]) -or -not ($to -as [int])) { return & $reply 400 (& $json @{ error = 'from and to must be version numbers.' }) }
                    $versions = Get-PEGuiBlueprintVersion -DataRoot $DataRoot -Name ([string](Get-PEGuiProperty $Query 'name'))
                    return & $reply 200 (& $json (Compare-PEGuiBlueprintVersion -Versions $versions -From ([int]$from) -To ([int]$to)) $true)
                }
                '^/api/standards$' { return & $reply 200 (& $json (Get-PEGuiStandardIndex -DataRoot $DataRoot) $true) }
                '^/api/standards/([^/]+)/coverage$' { return & $reply 200 (& $json (Get-PEGuiStandardCoverage -DataRoot $DataRoot -Name $Matches[1])) }
                '^/api/tenants/([^/]+)/standards/([^/]+)$' { return & $reply 200 (& $json (Get-PEGuiTenantStandard -DataRoot $DataRoot -TenantId $Matches[1] -Name $Matches[2])) }
                '^/api/tenants/([^/]+)/status$' { return & $reply 200 (& $json (Get-PEGuiTenantStatus -DataRoot $DataRoot -TenantId $Matches[1])) }
                '^/api/tenants/([^/]+)/findings$' { return & $reply 200 (& $json (Get-PEGuiFinding -DataRoot $DataRoot -TenantId $Matches[1]) $true) }
                '^/api/tenants/([^/]+)/layer-findings$' { return & $reply 200 (& $json (Get-PEGuiLayerFinding -DataRoot $DataRoot -TenantId $Matches[1] -Layer ([string](Get-PEGuiProperty $Query 'layer'))) $true) }
                '^/api/tenants/([^/]+)/items$' { return & $reply 200 (& $json (Get-PEGuiItemList -DataRoot $DataRoot -TenantId $Matches[1]) $true) }
                '^/api/jobs/([^/]+)/config/([^/]+)$' { return Get-PEGuiConfigFile -DataRoot $DataRoot -JobId $Matches[1] -File $Matches[2] }
                '^/api/tenants/([^/]+)/item$' {
                    $item = Get-PEGuiItem -DataRoot $DataRoot -TenantId $Matches[1] -ItemId ([string](Get-PEGuiProperty $Query 'id'))
                    if (-not $item) { return & $reply 404 (& $json @{ error = 'No such item.' }) }
                    return & $reply 200 (& $json $item)
                }
            }
        } elseif ($m -eq 'POST') {
            if ($null -eq $Body) { return & $reply 400 (& $json @{ error = 'A JSON body is required.' }) }
            switch -Regex ($p) {
                '^/api/requests/preview$' { return & $reply 200 (& $json (Get-PEGuiRequestPreview -DataRoot $DataRoot -Request $Body)) }
                '^/api/requests$' {
                    $r = New-PEGuiRequest -DataRoot $DataRoot -Request $Body
                    return & $reply ($(if ($r.created) { 201 } else { 400 })) (& $json $r)
                }
                '^/api/jobs/([^/]+)/cancel$' {
                    $r = Stop-PEGuiJob -DataRoot $DataRoot -JobId $Matches[1]
                    return & $reply $r.StatusCode (& $json $r.Body)
                }
            }
        }
        & $reply 404 (& $json @{ error = "No API route for $Method $Path." })
    } catch {
        & $reply 400 (& $json @{ error = $_.Exception.Message })
    }
}

function Test-PEGuiRequestAllowed {
    <#
        Decides whether a request may be served. The GUI can change blueprints and decisions and will be able to create
        app registrations, so it is not open to whatever can reach the port:
        - the Host header must be this server on localhost (a web page that rebinds a name to 127.0.0.1 sends its own host);
        - an Origin header, which browsers add to cross-site and POST requests, must be this server too;
        - the request must carry the startup token: in a cookie, or once in the query string, which hands out the cookie.
        Returns Allowed, StatusCode, Message and SetCookie (true for the one-time token handshake).
    #>
    param(
        [string]$Method, [string]$Path, [string]$HostHeader, [string]$Origin,
        [string]$CookieToken, [string]$QueryToken,
        [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][int]$Port
    )
    $hosts = @("localhost:$Port", "127.0.0.1:$Port", "[::1]:$Port")
    $deny = { param($code, $text) [pscustomobject]@{ Allowed = $false; StatusCode = $code; Message = $text; SetCookie = $false } }
    $same = {
        param($a, $b)
        if ([string]::IsNullOrEmpty($a) -or [string]::IsNullOrEmpty($b)) { return $false }
        [Security.Cryptography.CryptographicOperations]::FixedTimeEquals([Text.Encoding]::UTF8.GetBytes($a), [Text.Encoding]::UTF8.GetBytes($b))
    }
    if ([string]::IsNullOrEmpty($HostHeader) -or $hosts -notcontains $HostHeader.ToLowerInvariant()) { return & $deny 403 'Wrong host name. Use http://localhost:<port>.' }
    if (-not [string]::IsNullOrEmpty($Origin) -and (@($hosts | ForEach-Object { "http://$_" }) -notcontains $Origin.ToLowerInvariant())) { return & $deny 403 'Request from another origin.' }
    if (($Method -eq 'GET') -and ($Path -eq '/') -and (& $same $QueryToken $Token)) {
        return [pscustomobject]@{ Allowed = $true; StatusCode = 200; Message = ''; SetCookie = $true }
    }
    if (& $same $CookieToken $Token) { return [pscustomobject]@{ Allowed = $true; StatusCode = 200; Message = ''; SetCookie = $false } }
    & $deny 401 'This page needs the sign-in address. Look in the PowerShell window where you started Start-PEGui.ps1: it printed a line starting http://localhost:<port>/?token=. Open that whole line once (the token changes every time the server starts).'
}

Export-ModuleMember -Function Test-PEGuiRequestAllowed, ConvertTo-PEGuiItemId, Get-PEGuiIndex, Get-PEGuiTenant, Get-PEGuiResourceType, Get-PEGuiTenantStatus,
    Get-PEGuiItemList, Get-PEGuiAllowedAction, Get-PEGuiFinding, Get-PEGuiLayerFinding, Get-PEGuiItem, Get-PEGuiBlueprintVersion, Get-PEGuiExclusion,
    Get-PEGuiActivity, Get-PEGuiActiveJob, Compare-PEGuiBlueprintVersion, Get-PEGuiRequestPreview, New-PEGuiRequest, Stop-PEGuiJob, Update-PEGuiMockJob, Invoke-PEGuiApi
