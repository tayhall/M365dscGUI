BeforeAll {
    $script:Css = Get-Content -LiteralPath "$PSScriptRoot/../public/assets/app.css" -Raw
    $script:Js = Get-Content -LiteralPath "$PSScriptRoot/../public/assets/app.js" -Raw
}

Describe 'Long text in the GUI assets' {
    It 'lets grid children shrink and defines the truncate and wrap rules' {
        $script:Css | Should -Match '\.gr\s*>\s*\*\s*\{[^}]*min-width:\s*0'
        $script:Css | Should -Match '\.trunc\s*\{[^}]*text-overflow:\s*ellipsis'
        $script:Css | Should -Match '\.wrap\s*\{[^}]*overflow-wrap:\s*anywhere'
        $script:Css | Should -Match '\.clamp2\s*\{[^}]*-webkit-line-clamp:\s*2'
    }

    It 'defines the tooltip helpers and clips long values' {
        $script:Js | Should -Match 'const tt = '
        $script:Js | Should -Match 'const fv = '
        $script:Js | Should -Match 'const fmt = \(v, max = 80\)'
    }

    It 'defines .tabs once and keeps the cards from forcing a wide page' {
        ([regex]::Matches($script:Css, '(?m)^\.tabs\{')).Count | Should -Be 1
        $script:Css | Should -Not -Match 'minmax\(min\(100%,520px\)'
    }
}

Describe 'Selected tenant in the GUI assets' {
    It 'defines the context strip, the tenant label and the shared selection' {
        $script:Js | Should -Match 'const tenantLabel = '
        $script:Js | Should -Match 'function contextStrip\('
        $script:Js | Should -Match 'function setTenant\('
        $script:Js | Should -Match 'id="tenant-pick"'
    }

    It 'keeps the selection in the URL and in browser storage, guarded for blocked storage' {
        $script:Js | Should -Match "get\('tenant'\)"
        $script:Js | Should -Match "searchParams\.set\('tenant'"
        $script:Js | Should -Match 'try \{ return localStorage\.getItem'
        $script:Js | Should -Match 'try \{ localStorage\.setItem'
    }

    It 'shows the tenant name, not its role, as the label in crumbs, switcher and filters' {
        $script:Js | Should -Not -Match "\[role\(r\.t\), '/'\]"
        $script:Js | Should -Not -Match 'esc\(role\(t\)\)</a>'
        $script:Js | Should -Not -Match 'opt\(t, role\(t\)'
        $script:Js | Should -Not -Match "title: role\(t\) \+"
    }

    It 'counts only the selected tenant in the Drift review badge' {
        $script:Js | Should -Match 'const open = findingsOf\(curTenant\(\)\)\.filter\(isOpenDrift\)\.length'
    }
}

Describe 'Overview in the GUI assets' {
    It 'shows each blueprint layer in a panel with its own actions' {
        $script:Js | Should -Match 'function layerPanel\('
        $script:Js | Should -Match 'Update tenant blueprint'
        $script:Js | Should -Match 'Promote to master blueprint'
        $script:Js | Should -Match "pickAll\('Promote', promoteIds\)"
        $script:Js | Should -Match 'Not checked yet'
    }

    It 'says drifted, never guessing at why' {
        $script:Js | Should -Not -Match '(?i)experiment'
        $script:Js | Should -Not -Match '(?i)backfill'
    }

    It 'has no rename on the Overview, only on the Tenants page' {
        $overview = [regex]::Match($script:Js, '(?s)function overview\(\).*?
function workload\(').Value
        $overview.Length | Should -BeGreaterThan 200
        $overview | Should -Not -Match 'rename'
    }

    It 'sends the reviewed target version with a blueprint move' {
        $script:Js | Should -Match 'expectedVersion'
        $script:Js | Should -Match 'layer-findings'
    }
}

Describe 'Responsive layout in the GUI assets' {
    It 'defines one spacing scale and uses it' {
        foreach ($n in 1..6) { $script:Css | Should -Match "--s$($n):\s*\d+px" }
        ([regex]::Matches($script:Css, 'var\(--s\d\)')).Count | Should -BeGreaterThan 25
    }

    It 'stacks the table rows as cards on a narrow screen' {
        $script:Css | Should -Match '@media \(max-width:\s*900px\)\s*\{[^@]*\.gr\s*\{'
    }

    It 'has no fixed minimum widths on tables' {
        $script:Js | Should -Not -Match 'style="min-width:(980|1180|1000|900|860|760|720|700)px"'
        $script:Css | Should -Not -Match '\.gt\s*\{[^}]*min-width:\s*[1-9]'
    }

    It 'keeps Type and First seen out of the Drift columns' {
        $header = [regex]::Match($script:Js, 'class="gr h drift">(.*?)</div>').Groups[1].Value
        $header | Should -Match '<span>Item</span><span>Kind</span><span>Detail</span><span>Actions</span>'
        $header | Should -Not -Match 'Type|First seen'
    }

    It 'gives each Tenants row its drift per layer and Open, Check and Rename' {
        $script:Js | Should -Match 'data-act="recheck-tenant"'
        $script:Js | Should -Match "'Open', 'btn sm'"
        $script:Js | Should -Match 'data-act="rename-start"'
    }

    It 'offers Revert, Promote and Exclude on a drifted item, each with a tooltip, and adds them to the selection list' {
        $script:Js | Should -Match "const PICKS = \[\['Revert', 'Accept'\], \['Promote', 'Promote'\], \['Exclude', 'Exclude'\]\]"
        foreach ($name in 'Revert', 'Promote', 'Exclude') { $script:Js | Should -Match "(?m)^\s+$name`: '$name`: " }
        $script:Js | Should -Match 'data-act="pick" data-pick="\$\{name\}"'
        $script:Js | Should -Not -Match 'Add to queue|Add to cart|revert queue'
    }

    It 'lets the Drift page deep link to the Selection list' {
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\server.ps1') -Raw) | Should -Match "'/queue'"
    }

    It 'exports the Revert items as a .ps1 and a .psd1 of placeholders, with no apply tool command and no guard in them' {
        $script:Js | Should -Match 'async function queueExport'
        $script:Js | Should -Match "stem \+ '\.ps1'"
        $script:Js | Should -Match "stem \+ '\.psd1'"
        foreach ($name in 'ApplicationId', 'CertificateThumbprint', 'OrganizationName', 'TenantGuid', 'TenantId') { $script:Js | Should -Match "$name\s+= ""<$name>""" }
        $script:Js | Should -Match 'NonNodeData = @\('
        $script:Js | Should -Not -Match 'Invoke-PEApply|ExpectedResourceCount|PESelection|Invoke-PESelection|new Blob\(\[JSON'
    }

    It 'turns line breaks in tenant values into spaces before they go into the header comments of an exported file' {
        $script:Js | Should -Match 'const oneLine = .*u2028.*u2029'
        foreach ($value in "f.key", "f.resourceType", "meta.displayName", "own.name", "meta.lastFullCheck") {
            $script:Js | Should -Match ([regex]::Escape("oneLine($value"))
        }
    }
}

Describe 'Item page layer in the GUI assets' {
    It 'carries the layer of the Drift review into the item link and reads it from the URL' {
        $script:Js | Should -Match 'item: \(t, id, tab, layer\)'
        $script:Js | Should -Match "layer: q\.get\('layer'\) \|\| ''\s*\};?\s*\n"
        $script:Js | Should -Match 'path\.item\(t, f\.itemId, undefined, viewLayer\)'
    }

    It 'shows the blueprint side and the finding of the layer being viewed' {
        $script:Js | Should -Match 'item\.layerBlueprints'
        $script:Js | Should -Match 'const bpLabel = '
    }
}

Describe 'Aligned percentage in the GUI assets' {
    It 'never shows 100% while something has drifted' {
        $script:Js | Should -Match 'const alignedPct = '
        $script:Js | Should -Not -Match 'Math\.round\(\(own\.aligned'
        $script:Js | Should -Not -Match 'Math\.round\(\(layer\.aligned'
        # the function itself, run in node, when node is available
        $node = Get-Command node -ErrorAction SilentlyContinue
        if ($node) {
            $line = ($script:Js -split "`n" | Where-Object { $_ -match '^const alignedPct = ' } | Select-Object -First 1)
            $out = & node -e "$line; console.log([alignedPct(4457,20), alignedPct(100,0), alignedPct(0,0), alignedPct(1,999), alignedPct(99999,1)].join(','))"
            $out | Should -Be '99,100,100,0,99'
        }
    }
}

Describe 'Check from the item page in the GUI assets' {
    It 'offers a check of the item''s resource type for the item''s own tenant' {
        $script:Js | Should -Match 'data-act="recheck-scope" data-scope="\$\{esc\(rt\)\}" data-tenant="\$\{esc\(r\.t\)\}"'
        $script:Js | Should -Match "act === 'recheck-scope'\) recheck\(el\.dataset\.scope, el\.dataset\.tenant\)"
    }
}

Describe 'Cancelling a job in the GUI assets' {
    It 'offers Cancel for a queued job and a running Recheck, and posts to the cancel route' {
        $script:Js | Should -Match "const canCancelJob = \(j\) => j\.status === 'Queued' \|\| \(j\.status === 'Running' && j\.action === 'Recheck' && !j\.cancelRequested\)"
        $script:Js | Should -Match 'data-act="cancel-job" data-job='
        $script:Js | Should -Match "act === 'cancel-job'\) cancelJob\(el\.dataset\.job\)"
        $script:Js | Should -Match "api\('/api/jobs/' \+ enc\(jobId\) \+ '/cancel', \{\}\)"
    }

    It 'shows a cancelled job in grey and a requested cancel as Cancelling' {
        $script:Js | Should -Match "s === 'Cancelled' \? 'c-grey'"
        $script:Js | Should -Match "j\.cancelRequested \? 'Cancelling"
    }
}
Describe 'Offline tenants, snapshot labels and the upload form in the GUI assets' {
    It 'offers an upload form that reads the chosen files as text and posts an UploadSnapshot request' {
        $script:Js | Should -Match 'data-act="connect-mode" data-mode="upload"'
        $script:Js | Should -Match 'data-act="upload-snapshot"'
        $script:Js | Should -Match 'new FileReader\(\)'
        $script:Js | Should -Match 'readAsText\(file, ''utf-8''\)'
        $script:Js | Should -Match "action: 'UploadSnapshot'"
        $script:Js | Should -Match 'completeWorkloads'
        $script:Js | Should -Match 'saveAsBlueprint'
    }

    It 'reads the Microsoft365DSC version from the first line and holds the upload back when it is not the pinned one' {
        $script:Js | Should -Match 'Generated with Microsoft365DSC version'
        # the same rule as the server: a version of digits and dots that ends the first line; indentation never matches newlines
        $script:Js | Should -Match 'version\\s\+\(\[0-9\]\[0-9\.\]\*\)\\s\*\$/;'
        $script:Js | Should -Match 'INSTANCE_LINE = /\^\[ \\t\]\*\('
        $script:Js | Should -Match 'esc\(f\.name\)'
        $script:Js | Should -Match 'D\.index\.dsc\.pin'
        $script:Js | Should -Match 'uploadProblem'
    }

    It 'finds the workload of an uploaded type from the engine''s workload prefixes, with the type list as fallback' {
        # Security and Compliance and every type gui\ResourceTypes.json does not list must get the "workload is complete" tick too.
        $script:Js | Should -Match 'const workloadOfType = \(rt\) => \{[^\n]*D\.index\.workloadPrefixes[^\n]*D\.types\[rt\]'
        $script:Js | Should -Match 'const w = workloadOfType\(hit\[1\]\)'
        $script:Js | Should -Not -Match 'const w = D\.types\[hit\[1\]\]'
    }

    It 'offers no Revert for the drifted items of a scope of an offline tenant' {
        $scope = [regex]::Match($script:Js, '(?s)function scopeActions\(s\).*?\n\}').Value
        $scope | Should -Match "name !== 'Revert' \|\| !curTenantMeta\(\)\.offline"
    }

    It 'offers the blueprint tick only for a tenant without an own blueprint' {
        $script:Js | Should -Match 'hasOwnBlueprint'
    }

    It 'hides the Recheck buttons of an offline tenant and offers an upload of a newer snapshot instead' {
        $script:Js | Should -Match '!curTenantMeta\(\)\.offline'
        $script:Js | Should -Match "data-act=""open-upload"" data-tenant="
        $script:Js | Should -Match 'Upload newer snapshot'
        $script:Js | Should -Match "act === 'open-upload'"
        # per-type and per-scope buttons and the tenant row's Check are guarded too
        # each guarded site on its own: the top bar, the tenant page's Check now, the per-type row, the per-scope row, the per-type list, the Tenants list
        $script:Js | Should -Match '\$\{!curTenantMeta\(\)\.offline \? `<button class="jobsb recheckb" data-act="recheck"'
        $script:Js | Should -Match '\$\{own && !meta\.offline \? `<div class="btns"><button class="btn pri" data-act="recheck"'
        $script:Js | Should -Match '\$\{isOffline\(r\.t\) \? '''' : `<button class="btn" data-act="recheck-scope" data-scope="\$\{esc\(rt\)\}"'
        $script:Js | Should -Match '\$\{!curTenantMeta\(\)\.offline \? `<button class="btn sm" data-act="recheck-scope" data-scope="\$\{esc\(s\.name\)\}"'
        $script:Js | Should -Match '\$\{!curTenantMeta\(\)\.offline \? `<button class="btn sm" data-act="recheck-scope" data-scope="\$\{esc\(t\.type\)\}"'
        $script:Js | Should -Match '\$\{t\.offline \? `<button class="btn sm" data-act="open-upload" .*:`<button class="btn sm" data-act="recheck-tenant"'
    }

    It 'labels a snapshot as Exported live or Uploaded, per tenant and per workload, with the age of the oldest' {
        $script:Js | Should -Match "'Uploaded '"
        $script:Js | Should -Match "'Exported live '"
        $script:Js | Should -Match 'snapshotLabel'
        $script:Js | Should -Match 'oldest'
    }

    It 'never writes file contents to the page or the console' {
        $script:Js | Should -Not -Match 'console\.(log|info|debug)\([^)]*\.text'
    }
}

Describe 'Generate configuration in the GUI assets' {
    It 'defines one Generate configuration button that names its tenant escaped and is disabled without an own blueprint' {
        $script:Js | Should -Match 'const genConfigBtn = \(meta, cls\) => `<button class="\$\{cls\}" data-act="generate-config" data-tenant="\$\{esc\(meta\.tenantId\)\}"\$\{hasOwnBlueprint\(meta\) \? '''' : '' disabled'
        $script:Js | Should -Match '>Generate configuration</button>`;'
    }

    It 'offers it only for an offline tenant on the tenant page' {
        $script:Js | Should -Match '\$\{meta\.offline \? `<div class="btns"><button class="btn pri" data-act="open-upload" data-tenant="\$\{esc\(meta\.tenantId\)\}">Upload newer snapshot</button>\$\{genConfigBtn\(meta, ''btn''\)\}</div>` : ''''\}'
    }

    It 'offers it only for an offline tenant in the top bar, next to Upload newer snapshot' {
        $script:Js | Should -Match '!curTenantMeta\(\)\.offline \? `<button class="jobsb recheckb" data-act="recheck"'
        $script:Js | Should -Match 'data-act="open-upload" data-tenant="\$\{esc\(curTenant\(\)\)\}">Upload newer snapshot</button>\$\{genConfigBtn\(curTenantMeta\(\), ''jobsb''\)\}`\}'
    }

    It 'offers it only for an offline tenant in the Tenants list' {
        $script:Js | Should -Match '\$\{t\.offline \? `<button class="btn sm" data-act="open-upload" data-tenant="\$\{esc\(t\.tenantId\)\}">Upload newer snapshot</button>\$\{genConfigBtn\(t, ''btn sm''\)\}` :`<button class="btn sm" data-act="recheck-tenant"'
    }

    It 'posts a GenerateConfig request for the button''s tenant' {
        $script:Js | Should -Match "act === 'generate-config'\) generateConfig\(el\.dataset\.tenant\)"
        $script:Js | Should -Match "api\('/api/requests', \{ action: 'GenerateConfig', tenantId \}\)"
        $script:Js | Should -Match "GenerateConfig: 'Generate configuration'"
    }

    It 'links a finished job to its files through the download route, with a download name, escaped' {
        $script:Js | Should -Match "const configUrl = \(jobId, file\) => '/api/jobs/' \+ enc\(jobId\) \+ '/config/' \+ file;"
        $script:Js | Should -Match "const CONFIG_FILES = \[\['Changes', '\.ps1', 'changes'\], \['Removals', '\.ps1', 'removals'\], \['Manual', '\.json', 'manual'\]\];"
        $script:Js | Should -Match '<a class="lnk" href="\$\{esc\(configUrl\(j\.jobId, name\)\)\}" download="\$\{esc\(j\.jobId \+ ''-'' \+ name \+ ext\)\}">\$\{esc\(name \+ ext\)\}</a>'
        # Only for a GenerateConfig job that succeeded and says what it wrote; a file with no items is not linked (Manual always is).
        $script:Js | Should -Match "j\.action === 'GenerateConfig' && j\.status === 'Succeeded' && j\.files \? configFiles\(j\)"
        $script:Js | Should -Match "name === 'Manual' \|\| j\.files\[k\] > 0"
    }

    It 'shows the manual list with each item''s reason, escaped, loaded from the Manual file' {
        $script:Js | Should -Match "await api\(configUrl\(jobId, 'Manual'\)\)"
        $script:Js | Should -Match '<b>\$\{esc\(typeName\(m\.ResourceType\)\)\} · \$\{esc\(m\.Key\)\}</b>'
        $script:Js | Should -Match '<span class="muted">\$\{esc\(m\.Action\)\}</span>'
        $script:Js | Should -Match '<div class="muted wrap">\$\{esc\(m\.Reason\)\}</div>'
        $script:Js | Should -Match 'Array\.isArray\(rows\) \? rows : \[\]'
        $script:Js | Should -Match 'list\.error \? `<div class="err">\$\{esc\(list\.error\)\}</div>`'
        # an error is not kept for good: the next render asks again
        $script:Js | Should -Match 'if \(!list \|\| list\.retry\) loadManual\(j\.jobId\)'
        $script:Js | Should -Match 'Nothing needs manual action\.'
        $script:Js | Should -Match 'manual: \{\}'
    }
}

Describe 'Heat helpers in the GUI assets' {
    It 'loads heat.js before app.js' {
        $html = Get-Content -LiteralPath "$PSScriptRoot/../public/index.html" -Raw
        $html | Should -Match 'heat\.js"></script>\s*<script src="/assets/app\.js'
    }
}

Describe 'Alignment by workload placement' {
    It 'is its own function, placed above Refresh by resource type, with clickable segments' {
        $script:Js | Should -Match 'function workloadBars\('
        $script:Js | Should -Match '(?s)\$\{workloadBars\(t\)\}.*?Refresh by resource type'
        $script:Js | Should -Match '<a class="seg \$\{cls\}" href='
    }
}

Describe 'Tenant card heat cells' {
    It 'defines the headline layer, the cell row and the cells, and the cards use them' {
        $script:Js | Should -Match 'function headlineLayer\('
        $script:Js | Should -Match 'function heatRow\('
        $script:Js | Should -Match 'function heatCells\('
        $script:Js | Should -Match '(?s)function tenantCards\(.*?heatCells\(m\.tenantId\)'
    }

    It 'takes colour and counts from PEHeat and loads the master layer once' {
        $script:Js | Should -Match 'PEHeat\.tone\('
        $script:Js | Should -Match 'PEHeat\.countByWorkload\('
        $script:Js | Should -Match "loadLayer\(t, layer\.name\)"
    }

    It 'styles every tone' {
        foreach ($tone in 'ok', 'w1', 'w2', 'w3', 'nc', 'ld') { $script:Css | Should -Match "\.hm-$tone" }
        $script:Css | Should -Match '\.hm-cell'
    }
}

Describe 'Compare view in the GUI assets' {
    It 'has a matrix, a row-per-layer helper and a Cards / Compare toggle' {
        $script:Js | Should -Match 'function compareMatrix\('
        $script:Js | Should -Match 'function layerRowsFor\('
        $script:Js | Should -Match 'data-act="overview-view"'
        $script:Js | Should -Match "act === 'overview-view'"
    }

    It 'remembers the view in browser storage, guarded for blocked storage' {
        $script:Js | Should -Match "try \{ return localStorage\.getItem\('pe\.overviewView'\)"
        $script:Js | Should -Match "try \{ localStorage\.setItem\('pe\.overviewView'"
    }

    It 'links a workload header to the Drift review of every tenant and styles the matrix and toggle' {
        $script:Js | Should -Match "path\.drift\(\{ tenant: 'all', workload: wl \}\)"
        $script:Css | Should -Match '\.vt-toggle'
        $script:Css | Should -Match '\.hm-matrix'
    }
}

Describe 'Workload page click-throughs' {
    It 'links each kind in the legend to the Drift review of that workload and kind' {
        $script:Js | Should -Match 'path\.drift\(\{ tenant: r\.t, workload: r\.wl, kind: k\.k \}\)'
    }

    It 'makes the per-type bar itself a link to the type page' {
        $script:Js | Should -Match '<a class="hbar" href='
    }
}

Describe 'Item page filter in the GUI assets' {
    It 'replaces the identical-settings toggle with an All / Drifted / Matching filter' {
        $script:Js | Should -Not -Match 'showSame'
        $script:Js | Should -Not -Match 'toggle-same'
        $script:Js | Should -Match 'data-act="item-show"'
        $script:Js | Should -Match "act === 'item-show'"
        $script:Js | Should -Match 'ui\.itemShow'
    }

    It 'opens on Drifted when something differs, else on Matching, and shows the counts' {
        $script:Js | Should -Match "ui\.itemShow \|\| \(diffs\.length \? 'drifted' : 'matching'\)"
        $script:Js | Should -Match 'All \$\{rows\.length\}'
        $script:Js | Should -Match 'Drifted \$\{diffs\.length\}'
        $script:Js | Should -Match 'Matching \$\{same\.length\}'
    }

    It 'styles matching rows' {
        $script:Css | Should -Match '\.setg\.ok'
    }
}

Describe 'Compare matrix on narrow screens' {
    It 'scrolls inside its own wrapper instead of widening the page' {
        $script:Js | Should -Match '<section class="card"><div class="tw"><div class="hm-matrix"'
        $script:Css | Should -Match '\.hm-matrix\{[^}]*min-width:\s*\d+px'
    }
}

Describe 'Review fixes in the GUI assets' {
    It 'never shows a master layer that failed to load as all-green' {
        $script:Js | Should -Match 'catch \(e\) \{ D\.layerRows\[key\] = Object\.assign\(\[\], \{ failed: true \}\)'
        $script:Js | Should -Match 'rows && rows\.failed'
        $script:Js | Should -Match 'could not load'
    }

    It 'gives the view and item filter buttons an id so focus survives a render' {
        $script:Js | Should -Match 'id="ov-view-\$\{v\}"'
        $script:Js | Should -Match 'id="item-show-\$\{v\}"'
    }

    It 'leaves out zero-width bar segments' {
        $script:Js | Should -Match 'const seg = \(cls, n, href, what\) => n \?'
    }
}

Describe 'Refresh by resource type drills down' {
    It 'links the type name and the drifted chip to the type page' {
        $script:Js | Should -Match "link\(path\.type\(curTenant\(\), t\.workload \|\| 'Other', t\.type\), prettyType\(t\.type\)"
        $script:Js | Should -Match "path\.type\(curTenant\(\), t\.workload \|\| 'Other', t\.type, 'drifted'\)"
    }

    It 'offers Check now on the type page header, hidden for an offline tenant' {
        $script:Js | Should -Match '(?s)function typePage\(.*?data-act="recheck-scope" data-scope="\$\{esc\(r\.rt\)\}" data-tenant="\$\{esc\(r\.t\)\}".*?\n\}'
        $script:Js | Should -Match '(?s)function typePage\(.*?isOffline\(r\.t\)'
    }
}

Describe 'The Microsoft365DSC version banner in the GUI assets' {
    It 'tells the user the steps, links the Drift review and the DSC changelog, and marks the blueprint reviewed from the page' {
        $script:Js | Should -Match "Microsoft365DSC was updated from"
        $script:Js | Should -Not -Match "The blueprint is unchanged"
        $script:Js | Should -Match "link\('/drift', 'Drift review'\)"
        $script:Js | Should -Match 'github\.com/Microsoft365DSC/Microsoft365DSC/blob/Dev/CHANGELOG\.md'
        $script:Js | Should -Match "action: 'ReviewModule'"
        $script:Js | Should -Not -Match 'Set-PEBlueprintModule'
    }

    It 'labels a Changed item whose tenant has a setting the blueprint lacks, only while the module version differs' {
        $script:Js | Should -Match 'const dscChanged = \(\) => D\.ready && D\.index\.dsc && D\.index\.dsc\.match === false'
        $script:Js | Should -Match "const newInModule = \(f\) => \(dscChanged\(\) && f\.kind === 'Changed' \? addedProps\(f\) : \[\]\)"
    }
}

Describe 'The words of the GUI assets' {
    It 'names a Promote version, a tenant Revert and a blueprint restore the way the buttons do' {
        $script:Js | Should -Match "const SOURCE_LABEL = \{ Accept: 'Promote', Revert: 'Restore' \}"
        $script:Js | Should -Match "Accept: 'Revert tenant', RevertBlueprint: 'Restore blueprint version'"
        $script:Js | Should -Not -Match "Revert blueprint"
    }
}

Describe 'The top bar blueprint label in the GUI assets' {
    It 'shows the blueprints the selected tenant follows as plain text, not the master blueprint alone' {
        $script:Js | Should -Match 'class="bpchip" title="[^"]*">Follows \$\{followsText\(curTenantMeta\(\)\)\}</span>'
        $script:Js | Should -Not -Match 'Blueprint “\$\{esc\(D\.index\.blueprint\.name\)\}” v\$\{currentVersion\(\)\}</span>'
    }
}

Describe 'The tenant against its blueprints on the Overview, in the GUI assets' {
    It 'says in one line how fresh the snapshot is, instead of a full check line and an exported line' {
        $script:Js | Should -Match 'function snapshotSummary\(meta\)'
        $script:Js | Should -Match 'every workload read in the same run'
        $script:Js | Should -Match '\$\{snapshotSummary\(m\)\}'
        $script:Js | Should -Not -Match 'oldest workload:'
    }

    It 'says how many items the master blueprint and the tenant blueprint treat differently' {
        $script:Js | Should -Match 'function blueprintGap\(t\)'
        $script:Js | Should -Match "solo \? '' : blueprintGap\(t\)"
        $script:Js | Should -Match 'treat every item of this tenant the same'
    }

    It 'lets the workload cells follow either blueprint, and counts them from the findings so they add up to the rings' {
        $script:Js | Should -Match 'data-act="tile-layer"'
        $script:Js | Should -Match "ui\.tileLayer !== 'own'"
        $script:Js | Should -Match 'const rows = own \? findingsOf\(t\)'
        $script:Js | Should -Not -Match 'own \? w\.drifted'
    }

    It 'uses the word Target-only, as the Drift review does, and not extra' {
        $script:Js | Should -Match '\$\{layer\.targetOnly\} target-only'
        $script:Js | Should -Not -Match 'targetOnly\} extra'
    }
}

Describe 'Snapshot and refresh wording in the GUI assets' {
    It 'calls a full read of a tenant a snapshot, a partial read a refresh, and no longer a check' {
        $script:Js | Should -Match "'↻ New snapshot of '"
        $script:Js | Should -Match "'Taking snapshot…'"
        $script:Js | Should -Match '>Take snapshot</button>'
        $script:Js | Should -Match '>Refresh</button>'
        $script:Js | Should -Match '<h2>Refresh by resource type</h2>'
        $script:Js | Should -Match "Snapshot \$\{esc\(ago\(meta\.lastFullCheck\)\)\}"
        $script:Js | Should -Not -MatchExactly 'Check now|Re-check|Full check|last full check|not checked yet'
    }
}

Describe 'The Blueprint page in the GUI assets' {
    It 'says what the blueprint is, what it holds, how the master tenant differs, and lists the versions with Restore, newest first' {
        $script:Js | Should -Match 'Master blueprint “\$\{esc\(masterName\)\}”'
        $script:Js | Should -Match '<h2>What it holds · v\$\{cur \|\| ''…''\}</h2>'
        $script:Js | Should -Match 'against this blueprint</h2>'
        $script:Js | Should -Match 'Review in Drift review'
        $script:Js | Should -Match 'Show \$\{plural\(older\.length, ''older version''\)\}'
        $script:Js | Should -Match 'Restore v\$\{v\.version\}…'
        $script:Js | Should -Not -Match 'Pending master changes'
        $script:Js | Should -Not -Match 'Revert to v'
    }
}

Describe 'Tenant blueprint pages in the GUI assets' {
    It 'names a tenant blueprint in ?name=, offers the blueprints the tenant follows as tabs, and loads their versions' {
        $script:Js | Should -Match "blueprint: \(name\) => '/blueprint' \+ \(name \? '\?name=' \+ enc\(name\) : ''\)"
        $script:Js | Should -Match "screen: 'blueprint', name: q\.get\('name'\) \|\| ''"
        $script:Js | Should -Match "api\('/api/blueprint\?name=' \+ enc\(name\)\)"
        $script:Js | Should -Match 'aria-label="Blueprint of '
        $script:Js | Should -Match 'Tenant blueprint “'
    }

    It 'offers Restore only on the master blueprint, which is the only one the engine can restore' {
        $script:Js | Should -Match '\$\{!name && v\.version !== cur \?'
        $script:Js | Should -Match '\$\{!r\.name && v\.version !== cur \?'
        $script:Js | Should -Match '\$\{!r\.name && r\.to === cur && r\.from !== cur \?'
    }
}

Describe 'New snapshot options in the GUI assets' {
    It 'asks before a replica snapshot, offers "use as blueprint", and sends baseline only when ticked' {
        $script:Js | Should -Match "function askSnapshot\(tenantId\)"
        $script:Js | Should -Match "if \(role\(tenantId\) === 'Master'\) \{ recheck\(undefined, tenantId\); return; \}"
        $script:Js | Should -Match 'id="snap-baseline" data-snap="baseline"'
        $script:Js | Should -Match 'Also use this snapshot as '
        $script:Js | Should -Match 'including types and items that are new in the installed version'
        $script:Js | Should -Match 'baseline \? \{ baseline: true \} : \{\}'
        $script:Js | Should -Match "act === 'snapshot-go'"
        $script:Js | Should -Match 'dialogView\(\) \+ snapshotDialogView\(\) \+ toast'
    }
}
