# Reads the console log of a Microsoft365DSC export (export.log, written next to the export by
# tools\Export-M365DscTenant.ps1).
#
# Log shape, derived from Export-M365DSCConfiguration (Modules\M365DSCReverse.psm1) and Write-M365DSCHost, which writes the
# pieces of a progress line with Write-Host -NoNewline. VERIFIED against real runs of tools\Export-M365DscTenant.ps1 against the
# test tenant (sequential mode, PowerShell 7, Write-Host captured through the information stream: plain text, CRLF line
# ends, no ANSI codes). Shape seen in those runs:
#   [3/120] Extracting [AADGroup] using {CertificateThumbprint}...      <- one line per component, start of a block
#       |---[1/2] Sales<check mark>                                      <- instance lines: tree marker, then [i/n] and a display name
#       |---[2/2] Finance<check mark>                                    <- the last instance ([n/n]) carries the completion mark
#   [4/120] Extracting [EXOAcceptedDomain] using {CertificateThumbprint}...<check mark>   <- Ok with zero instances
#   [1/1] Extracting [AADGroup] using {CertificateThumbprint}...\r\n    |---[1/27] Sales<check mark>
#                                                                       <- through Invoke-PELoggedCommand the line break
#       |---[2/27] Finance<check mark>                                     before instance 1 is a literal \r\n, so
#                                                                          instance 1 ends the Extracting line
#   [5/120] Extracting [EXOFocusedInbox] using {CertificateThumbprint}...
#       |---[1/28] user@contoso.example<red X>                          <- the red X lands on the instance line being processed
#       An error occurred while exporting resource {EXOFocusedInbox}: <message, may continue on following lines>
# Full exports add three shapes (Write-M365DSCHost defers the Extracting text until the component's first commit):
#   [52/429] Extracting [A] using {...}...\r\n[53/429] Extracting [B] using {...}...<red X>
#                                     <- A logged nothing, so B's commit flushed both (also joined without the \r\n);
#                                        A is Incomplete, the tail of the line belongs to B
#       |---[1/145] Role One          <- an outer loop printed at once (not deferred), BEFORE its own Extracting line
#   [84/429] Extracting [C] using {...}...\r\n        |---[1/17] Role One_Rule<check mark>
#       |---[2/145] Role Two          <- nested counters: one per indentation depth; also '> [k/m]' / '- [i/n]' markers
#           |---[1/17] Role Two_Rule<check mark>
#
# Status per component:
#   Failed     an error line for it (also after its completion mark), or a red X on one of its instance lines (or
#              ending its Extracting line)
#   Ok         a completion mark on the Extracting line (zero instances) or on its last instance line: [n/n] at the
#              innermost depth with every outer counter at [m/m]
#   Incomplete started but neither completed nor failed (log cut off, next component began without a mark from this
#              one, or marks that cannot be attributed, for example out-of-sequence instance numbers from parallel
#              workers)
#
# SECURITY: instance lines carry tenant data (display names) that someone with directory write access controls. Instance
# lines (after optional whitespace they start with the '|---' tree marker or '- [i/n]', '> [i/n]', '* [i/n]') are
# therefore never matched against the Extracting or error patterns, both patterns are anchored to the line start, an
# Extracting line is read only as far as its DSC-written chain of entries (text after an instance marker is never read as
# an entry), and an error line only counts for the component currently being extracted. The remaining forgeable signal
# is a name that ends in a mark character on an instance line; the worst case is a component becoming Failed or
# NotChecked, or the last innermost instance line looking complete. Unmarked instance lines after a closed block go to
# the next component only when its Extracting line follows directly; otherwise to the closed one, which loses its mark.
# An instance line that holds another component's Extracting entry (DSC flushed a never-committed instance line with a
# later commit, so the mark is not its owner's) makes the owner Incomplete; a display name with that text can do no more.
# When the log's FIRST line is DSC's component list ('Exporting Microsoft 365 configuration for Components: A, B'), a
# listed component with no Extracting entry is Incomplete 'not in export log' (hidden behind an instance marker, or
# skipped by DSC for the authentication method).
#
# Known safe-direction coverage loss: SharePoint, Planner and Security & Compliance resources print instance lines
# without a marker ('    [i/n] name'), so they read Incomplete (they are outside the default workloads).
# EXOMailboxPermission writes 'outer\r\n    inner' as one record, which hides the first inner counter of each mailbox,
# so it reads Incomplete (out-of-sequence) whenever it is visible.

function Read-PEExportLog
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path,

        # Receives log anomalies (ignored error lines, out-of-sequence instances). Optional; the output shape is unchanged.
        [System.Collections.Generic.List[string]]$Warnings
    )

    if ($null -eq $Warnings)
    {
        $Warnings = [System.Collections.Generic.List[string]]::new()
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return @()
    }

    $redX = [string][char]0x274C
    $check = [string][char]0x2705
    $maxReason = 500
    $order = [System.Collections.Generic.List[string]]::new()
    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    $failed = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $done = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $suspect = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $reason = [System.Collections.Generic.Dictionary[string, string]]::new($comparer)
    # Per type: the counters seen so far per indentation depth (depth -> [index, count]); a line at a depth drops the
    # counters of deeper levels, so a nested [1/n] restarts in sequence under each outer line.
    $levels = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.SortedDictionary[int, int[]]]]::new($comparer)
    # Per type: the deepest indentation seen. Only a mark at that depth (the innermost loop) can complete a block.
    $leafDepth = [System.Collections.Generic.Dictionary[string, int]]::new($comparer)
    # Types whose merged first instance [1/n] (n > 1) ended the Extracting line with a completion mark and nothing has
    # followed yet: Ok only once a DSC-written line closes the block (the next Extracting line or the export summary).
    $provisional = [System.Collections.Generic.HashSet[string]]::new($comparer)
    # Types whose Extracting entry was directly followed by the next one on the same line: they logged nothing.
    $silent = [System.Collections.Generic.HashSet[string]]::new($comparer)
    # Unmarked instance lines seen after the current block closed (completion mark or red X). Either the outer loop of
    # the NEXT component (printed before its deferred Extracting text is flushed) or more of the current one: they go
    # to the next component if its Extracting line comes next, otherwise (a marked instance line, the export summary,
    # the end of the log) to the current one, which withdraws its completion.
    $pending = [System.Collections.Generic.List[object]]::new()

    # An instance line: tree marker '|---', or '- [i/n]' / '> [i/n]' / '* [i/n]' (TeamsUser and similar). Everything
    # after the marker is tenant data.
    $instancePattern = '^(\s*)(?:\|---|[-*>] (?=\[\d+/\d+\]))'
    $segmentPattern = '\[\d+/\d+\]\s*Extracting \[(\w+)\] using \{[^}]*\}\.\.\.'
    $embeddedEntry = '\[\d+/\d+\]\s*Extracting \[\w+\] using \{'
    # Types with another component's Extracting entry inside one of their instance lines (see $addInstance).
    $foreign = [System.Collections.Generic.HashSet[string]]::new($comparer)
    # Components listed on the log's first line (DSC-written 'Exporting ... for Components: A, B, C'), if present.
    $listed = [System.Collections.Generic.List[string]]::new()
    $firstLine = $true
    $firstSegment = [regex]::new('^\s*' + $segmentPattern)
    $nextSegment = [regex]::new('\G(?:\\r\\n)?' + $segmentPattern)

    $addInstance = {
        param ([string]$Type, [int]$Depth, [string]$Body, [string]$Line, [bool]$Merged)

        # Completion is decided by the LAST instance line of a block: an earlier mark is withdrawn by any instance line.
        [void]$done.Remove($Type)
        [void]$provisional.Remove($Type)
        if (-not $levels.ContainsKey($Type))
        {
            $levels[$Type] = [System.Collections.Generic.SortedDictionary[int, int[]]]::new()
        }
        $stack = $levels[$Type]
        foreach ($deeper in @($stack.Keys | Where-Object { $_ -gt $Depth }))
        {
            [void]$stack.Remove($deeper)
        }
        if (-not $leafDepth.ContainsKey($Type) -or $Depth -gt $leafDepth[$Type])
        {
            $leafDepth[$Type] = $Depth
        }
        $index = 0
        $count = 0
        $hasIndex = $Body -match '^\[(\d+)/(\d+)\]'
        if ($hasIndex)
        {
            $index = [int]$Matches[1]
            $count = [int]$Matches[2]
            $previous = if ($stack.ContainsKey($Depth)) { $stack[$Depth][0] } else { 0 }
            if ($index -ne $previous + 1 -and $suspect.Add($Type))
            {
                $Warnings.Add("Out-of-sequence instance number for '$Type' (possible interleaved parallel output).")
            }
            $stack[$Depth] = @($index, $count)
        }
        else
        {
            [void]$suspect.Add($Type)
        }

        # An instance line that its component deferred but never committed is written by a LATER component's commit:
        # that component's Extracting entry follows the name and the line ends with that component's mark (live:
        # '|---[1/0] [58/429] Extracting [...]...'). Such a mark is not this component's. A display name holding the
        # same text can only make the component Incomplete.
        if ($Body -match $embeddedEntry)
        {
            [void]$foreign.Add($Type)
        }

        if ($Line.EndsWith($redX))
        {
            [void]$failed.Add($Type)
        }
        elseif ($foreign.Contains($Type))
        {
            # No completion can be read from this component's lines any more.
        }
        elseif ($Line.EndsWith($check) -and $hasIndex)
        {
            $outer = @($stack.Keys | Where-Object { $_ -lt $Depth })
            $outerOpen = @($outer | Where-Object { $stack[$_][0] -ne $stack[$_][1] }).Count -gt 0
            if ($index -eq $count -and $Depth -eq $leafDepth[$Type] -and -not $outerOpen)
            {
                [void]$done.Add($Type)
            }
            elseif ($Merged -and $index -eq 1 -and $count -gt 1 -and $outer.Count -eq 0)
            {
                # Merged first instance of n > 1: provisional. More instance lines withdraw it (completion is then the
                # last [n/n] line); otherwise it needs the next Extracting line or the export summary (a single
                # filtered object is printed as [1/15], so n alone cannot tell). A log that just ends is Incomplete.
                [void]$provisional.Add($Type)
            }
        }
    }
    $flushPending = {
        param ([string]$Type)
        foreach ($item in $pending)
        {
            & $addInstance $Type $item.Depth $item.Body $item.Line $false
        }
        $pending.Clear()
    }

    $current = $null
    $errorType = $null
    foreach ($raw in [System.IO.File]::ReadLines($Path))
    {
        $line = [regex]::Replace($raw, '\x1B\[[0-9;?]*[ -/]*[@-~]', '').TrimEnd()

        # The component list is only read from the first physical line, which DSC writes before any tenant data.
        if ($firstLine)
        {
            $firstLine = $false
            if ($line.TrimStart([char]0xFEFF) -match '^Exporting Microsoft 365 configuration for Components: (.+)$')
            {
                foreach ($name in $Matches[1] -split ',')
                {
                    $name = $name.Trim()
                    if ($name -match '^\w+$' -and -not $listed.Contains($name))
                    {
                        $listed.Add($name)
                    }
                }
                continue
            }
        }

        # Instance lines first, so nothing inside a display name can reach the other patterns.
        if ($line -match $instancePattern)
        {
            $errorType = $null
            $item = [pscustomobject]@{ Depth = $Matches[1].Length; Body = $line.Substring($Matches[0].Length); Line = $line }
            $marked = $line.EndsWith($check) -or $line.EndsWith($redX)
            if ($null -eq $current -or (-not $marked -and ($done.Contains($current) -or $failed.Contains($current))))
            {
                $pending.Add($item)
                continue
            }
            & $flushPending $current
            & $addInstance $current $item.Depth $item.Body $item.Line $false
            continue
        }

        if ($line -match '^\s*\[\d+/\d+\]\s*Extracting \[(\w+)\]')
        {
            $errorType = $null
            # Seen live through Invoke-PELoggedCommand: a component that logs nothing leaves its deferred Extracting text
            # (and its deferred line break, flattened to a literal '\r\n') in the buffer, and the next component's write
            # flushes both, so one physical line can hold several Extracting entries. Only the DSC-written chain at the
            # start of the line is read ('[n/m] Extracting [X] using {...}...' entries, each directly followed by the next
            # or by '\r\n' and the next): no tenant data can sit in it. The text after the chain (the tail) belongs to the
            # last entry; anything after an instance marker in it is a display name and is never read as an entry.
            $types = [System.Collections.Generic.List[string]]::new()
            $tail = $null
            $legacyType = $Matches[1]
            $match = $firstSegment.Match($line)
            if ($match.Success)
            {
                $types.Add($match.Groups[1].Value)
                $position = $match.Length
                while (($match = $nextSegment.Match($line, $position)).Success)
                {
                    $types.Add($match.Groups[1].Value)
                    $position = $match.Index + $match.Length
                }
                $tail = $line.Substring($position)
            }
            else
            {
                $types.Add($legacyType)
            }

            for ($k = 0; $k -lt $types.Count; $k++)
            {
                # The next component's Extracting entry closes the previous block.
                if ($null -ne $current -and $provisional.Remove($current))
                {
                    [void]$done.Add($current)
                }
                $current = $types[$k]
                if (-not $order.Contains($current))
                {
                    $order.Add($current)
                }
                if ($k -lt $types.Count - 1)
                {
                    # No completion mark: it may have returned nothing, or failed with a notice that names no type.
                    [void]$silent.Add($current)
                }
            }
            # Unmarked instance lines printed since the previous block closed: this component's outer loop.
            & $flushPending $current

            if ($null -eq $tail)
            {
                # Entry without the 'using {...}...' prefix (not seen live): the line's last character decides.
                if ($line.EndsWith($redX))
                {
                    [void]$failed.Add($current)
                }
                elseif ($line.EndsWith($check) -and -not $levels.ContainsKey($current))
                {
                    [void]$done.Add($current)
                }
            }
            elseif ($line.EndsWith($redX))
            {
                [void]$failed.Add($current)
            }
            elseif ($tail -eq $check)
            {
                # Ok with zero instances (an outer loop printed before it would need its own inner block).
                if (-not $levels.ContainsKey($current))
                {
                    [void]$done.Add($current)
                }
            }
            elseif ($tail -match ('^(?:\\r\\n)?' + $instancePattern.Substring(1)))
            {
                # The first instance on the Extracting line ('...\r\n    |---[1/n] name'): the line break before it was
                # flattened to a literal '\r\n'.
                & $addInstance $current $Matches[1].Length $tail.Substring($Matches[0].Length) $line $true
            }
            # Any other tail (a yellow 'not registered' notice, the export summary written by a later commit) carries
            # no completion mark.
            continue
        }

        # The export summary (DSC-written; display names cannot start a line, Invoke-PELoggedCommand flattens line
        # breaks) closes the current block.
        if ($null -ne $current -and $line -match ('^\s*(' + [char]0x231B + '\s*)?Export took |^\s*Successful exports'))
        {
            # Instance lines left over after the last block closed were that block's own: it did not finish.
            & $flushPending $current
            if ($provisional.Remove($current))
            {
                [void]$done.Add($current)
            }
        }

        if ($line -match '^\s*An error occurred while exporting resource \{(\w+)\}:?\s*(.*)$')
        {
            $type = $Matches[1]
            $message = $Matches[2].Trim()
            # Only the component currently being extracted can report an error; one that comes after its completion
            # mark (Export threw late) still means it failed.
            if ($type -ne $current)
            {
                $why = if ($order.Contains($type)) { 'which is not the component being extracted' } else { 'which has no Extracting entry' }
                $Warnings.Add("Ignored an error line for '$type', $why.")
                $errorType = $null
                continue
            }
            [void]$failed.Add($type)
            $errorType = $type
            if (-not $reason.ContainsKey($type) -and $message)
            {
                $reason[$type] = $message
            }
            continue
        }

        # Continuation of a multi-line error message, until a blank line, summary line or the next block.
        if ($null -ne $errorType)
        {
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^Error Log created|Export took|^(Successful|Failed) exports|Export completed')
            {
                $errorType = $null
            }
            elseif ($reason.ContainsKey($errorType))
            {
                $reason[$errorType] = $reason[$errorType] + ' ' + $line.Trim()
            }
            else
            {
                $reason[$errorType] = $line.Trim()
            }
        }
    }

    # Instance lines after the last closed block, with no Extracting line after them: the last block did not finish.
    if ($pending.Count -gt 0)
    {
        if ($null -ne $current)
        {
            & $flushPending $current
        }
        else
        {
            $Warnings.Add('Instance line before any Extracting line; ignored.')
            $pending.Clear()
        }
    }

    foreach ($type in $order)
    {
        $text = $null
        if ($failed.Contains($type))
        {
            $status = 'Failed'
            $text = if ($reason.ContainsKey($type)) { $reason[$type] } else { 'failed (no error text)' }
            if ($text.Length -gt $maxReason)
            {
                $text = $text.Substring(0, $maxReason)
            }
        }
        elseif ($done.Contains($type) -and -not $suspect.Contains($type) -and -not $foreign.Contains($type))
        {
            $status = 'Ok'
        }
        else
        {
            $status = 'Incomplete'
            $text = if ($foreign.Contains($type))
            {
                'export log incomplete (another component''s output on its instance line)'
            }
            elseif ($suspect.Contains($type))
            {
                'export log incomplete (out-of-sequence instances)'
            }
            elseif ($silent.Contains($type))
            {
                'export log incomplete (no completion mark before the next component started)'
            }
            else
            {
                'export log incomplete'
            }
        }
        [pscustomobject]@{
            ResourceType = $type
            Status       = $status
            Reason       = $text
        }
    }

    # Listed components the log never shows an Extracting entry for (for example hidden behind an instance marker, where
    # the text cannot be told from a display name): their status is unknown.
    $seen = [System.Collections.Generic.HashSet[string]]::new([string[]]$order.ToArray(), $comparer)
    foreach ($type in $listed)
    {
        if ($seen.Add($type))
        {
            [pscustomobject]@{
                ResourceType = $type
                Status       = 'Incomplete'
                Reason       = 'not in export log'
            }
        }
    }
}

function ConvertTo-PELogText
{
    # Flattens control characters so one logged record is one physical line: tenant data (display names) cannot start a
    # new line that looks like an Extracting or error line. CR, LF and other C0 controls (not tab), DEL, NEL and the
    # Unicode line/paragraph separators become visible escapes. Exception: the record DSC writes for a failed component
    # (a red X, a line break, then 'An error occurred while exporting resource {X}: message') keeps that one real line
    # break, because the parser expects the error text on its own line; line breaks inside the message become spaces.
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text))
    {
        return ''
    }

    $escape = {
        param ($m)
        switch ([int][char]$m.Value)
        {
            13 { '\r' }
            10 { '\n' }
            { $_ -gt 255 } { '\u{0:X4}' -f $_ }
            default { '\x{0:X2}' -f $_ }
        }
    }
    $controls = '[\x00-\x08\x0A-\x1F\x7F\u0085  ]'

    if ($Text -match '(?s)\A([^\x00-\x7F]?)\r?\n([ \t]*An error occurred while exporting resource \{\w+\}:.*)\z')
    {
        $head = [regex]::Replace($Matches[1], $controls, $escape)
        $message = [regex]::Replace($Matches[2], '\s*[\r\n\u0085  ]+\s*', ' ')
        $message = [regex]::Replace($message, $controls, $escape)
        return $head + "`r`n" + $message
    }

    return [regex]::Replace($Text, $controls, $escape)
}
