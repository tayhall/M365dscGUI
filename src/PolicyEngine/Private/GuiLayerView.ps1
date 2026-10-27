function Get-PEGuiLayerView
{
    # Drift of one tenant against each blueprint layer it follows, from its latest Full check state (no new tenant read).
    # Returns one object per layer: Name, Summary (what index.json carries) and Rows (findings.json rows of that layer,
    # each with its layer name). A layer whose blueprint cannot be read, or a tenant never checked, is not checked.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        $Tenant,

        [AllowNull()]
        $Check,

        [Parameter(Mandatory)]
        [string[]]$LayerNames,

        [string]$DataRoot,

        [string]$ExportedAt
    )

    $driftKinds = 'Missing', 'Changed', 'TargetOnly', 'PossibleRename', 'Ambiguous'
    $blueprintSideKinds = 'Missing', 'Changed', 'PossibleRename', 'Ambiguous'
    $decisions = @(Get-PEDecision -DataRoot $DataRoot -Tenant ([string]$Tenant.Slug))
    $last = $LayerNames.Count - 1
    for ($i = 0; $i -le $last; $i++)
    {
        $name = $LayerNames[$i]
        $summary = [ordered]@{
            name       = $name
            version    = $null
            role       = $(if ($i -eq $last -and $i -gt 0) { 'tenant' } elseif ($i -eq 0) { 'master' } else { 'layer' })
            sameAsOwn  = ($i -eq $last)
            checked    = $false
            problem    = $null
            drifted    = 0
            aligned    = 0
            changed    = 0
            missing    = 0
            targetOnly = 0
        }
        $rows = @()
        try
        {
            $blueprint = Get-PEBlueprint -Name $name -DataRoot $DataRoot
            $summary.version = @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $name -DataRoot $DataRoot))[-1]
            if ($null -ne $Check)
            {
                $findings = @(Compare-PEState -Blueprint $blueprint -Target $Check.State -Decisions $decisions)
                $converted = ConvertTo-PEGuiFindingList -Findings $findings -Records @($Check.State.Records) -NotChecked @($Check.State.NotChecked) -ExportedAt $ExportedAt
                $rows = @($converted.Findings | ForEach-Object { $_['layer'] = $name; $_ })
                $open = @($rows | Where-Object { $_.state -eq 'Open' -and $_.kind -in $driftKinds -and $_.itemId })
                $blueprintSide = @($open | Where-Object { $_.kind -in $blueprintSideKinds } | ForEach-Object { $_.itemId } | Sort-Object -Unique)
                $keyed = @(@($blueprint.Records) | Where-Object { -not [string]::IsNullOrEmpty([string]$_.Key) }).Count
                $summary.checked = $true
                $summary.drifted = $open.Count
                $summary.aligned = [Math]::Max(0, $keyed - $blueprintSide.Count)
                $summary.changed = @($open | Where-Object { $_.kind -eq 'Changed' }).Count
                $summary.missing = @($open | Where-Object { $_.kind -eq 'Missing' }).Count
                $summary.targetOnly = @($open | Where-Object { $_.kind -eq 'TargetOnly' }).Count
            }
        }
        catch
        {
            $summary.checked = $false
            $summary.problem = "Blueprint '$name' could not be read: $($_.Exception.Message)"
            $rows = @()
        }
        [pscustomobject]@{ Name = $name; Summary = $summary; Rows = $rows }
    }
}

function Get-PEGuiMoveList
{
    # What moving items between a tenant's two blueprints would change, for the GUI's preview (moves.json): Up is the
    # tenant blueprint into the master blueprint (promote up), Down the master blueprint into the tenant blueprint (update
    # tenant blueprint). Returns $null when either blueprint cannot be read.
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$MasterBlueprint,

        [Parameter(Mandatory)]
        [string]$OwnBlueprint,

        [string]$DataRoot
    )

    try
    {
        $version = { param ($name) @(Get-PEBlueprintVersionNumber -Directory (Get-PEBlueprintDirectory -Name $name -DataRoot $DataRoot))[-1] }
        $rows = {
            param ($from, $to)
            @(Get-PEBlueprintMovePreview -From $from -To $to -DataRoot $DataRoot | ForEach-Object {
                    [ordered]@{ itemId = ConvertTo-PEGuiItemId -ResourceType $_.ResourceType -Key $_.Key; resourceType = $_.ResourceType; key = $_.Key; op = $_.Op }
                })
        }
        [ordered]@{
            master = [ordered]@{ name = $MasterBlueprint; version = (& $version $MasterBlueprint) }
            own    = [ordered]@{ name = $OwnBlueprint; version = (& $version $OwnBlueprint) }
            up     = @(& $rows $OwnBlueprint $MasterBlueprint)
            down   = @(& $rows $MasterBlueprint $OwnBlueprint)
        }
    }
    catch
    {
        Write-Warning "Moves between '$MasterBlueprint' and '$OwnBlueprint' not listed: $($_.Exception.Message)"
        $null
    }
}
