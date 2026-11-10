<#
.SYNOPSIS
    Changes the pinned Microsoft365DSC (and optionally Microsoft.Graph.Authentication) version in src\PolicyEngine\Data\Versions.psd1,
    and with -CreatePullRequest opens a pull request for it. The whole bump-pins pipeline step.
.DESCRIPTION
    Only the value on the pin line is replaced, so comments, the other pin and the line endings stay as they are. The versions are checked
    for their shape first, then against the PowerShell Gallery (unless -SkipGalleryCheck), and nothing is changed if either check fails.
    A version that is already pinned is "nothing to do". A lower version is allowed but reported as a DOWNGRADE (console and pull request).

    The only writes are a branch dsc-pin/<version> and a pull request into the default branch; it never pushes to the default branch and
    never overrides a pin at run time. In Azure DevOps it uses the build identity: checkout with persistCredentials for git, and
    SYSTEM_ACCESSTOKEN for the REST call. Run the pipeline from the default branch.
.EXAMPLE
    pwsh -NoProfile -File pipelines\scripts\Update-DscPin.ps1 -Version 2.26.1104.1 -SkipGalleryCheck
#>
param
(
    # Four numbers, for example 2.26.1104.1. Checked in the script body (a clear message) before anything is touched.
    [Parameter(Mandatory)]
    [string]$Version,

    # Three numbers, for example 2.41.1. Empty leaves the Graph pin alone.
    [string]$GraphAuthenticationVersion = '',

    [string]$PinPath = (Join-Path $PSScriptRoot '..\..\src\PolicyEngine\Data\Versions.psd1'),

    [switch]$SkipGalleryCheck,

    # Create branch dsc-pin/<version>, commit, push and open a pull request (Azure DevOps).
    [switch]$CreatePullRequest
)

$ErrorActionPreference = 'Stop'

function Get-PinLine
{
    # The one line "<Key> = '<value>'" of the pin file; refuses a file where it is not exactly once.
    param ([string]$Text, [string]$Key)
    $found = [regex]::Matches($Text, "(?m)^([ \t]*$Key[ \t]*=[ \t]*')([^'\r\n]*)(')")
    if ($found.Count -ne 1) { throw "Expected exactly one '$Key = ...' line in the pin file, found $($found.Count)." }
    $found[0]
}

function Set-PinValue
{
    param ([string]$Text, [string]$Key, [string]$Value)
    $line = Get-PinLine -Text $Text -Key $Key
    $Text.Substring(0, $line.Groups[2].Index) + $Value + $Text.Substring($line.Groups[2].Index + $line.Groups[2].Length)
}

function Test-GalleryHas
{
    param ([string]$Name, [string]$Version)
    $hit = Find-PSResource -Name $Name -Version $Version -Repository PSGallery -ErrorAction SilentlyContinue
    [bool]$hit
}

function Get-AdoSetting
{
    # What Azure DevOps provides to the step. Names every missing one at once.
    $names = 'SYSTEM_ACCESSTOKEN', 'SYSTEM_COLLECTIONURI', 'SYSTEM_TEAMPROJECT', 'BUILD_REPOSITORY_ID'
    $missing = @($names | Where-Object { -not [Environment]::GetEnvironmentVariable($_) })
    if ($missing)
    {
        throw "-CreatePullRequest needs these environment variables, which Azure DevOps sets in a pipeline run: $($missing -join ', '). (SYSTEM_ACCESSTOKEN must be mapped from `$(System.AccessToken) in the step's env.)"
    }
    @{
        Token  = $env:SYSTEM_ACCESSTOKEN
        Api    = '{0}/{1}/_apis/git/repositories/{2}' -f $env:SYSTEM_COLLECTIONURI.TrimEnd('/'), [uri]::EscapeDataString($env:SYSTEM_TEAMPROJECT), [uri]::EscapeDataString($env:BUILD_REPOSITORY_ID)
    }
}

function Invoke-AdoRest
{
    param ([hashtable]$Ado, [string]$Method, [string]$Path, $Body)
    $uri = $Ado.Api + $Path
    $parameters = @{ Uri = $uri; Method = $Method; Headers = @{ Authorization = "Bearer $($Ado.Token)" }; ContentType = 'application/json' }
    if ($null -ne $Body) { $parameters.Body = ($Body | ConvertTo-Json -Depth 5) }
    Invoke-RestMethod @parameters
}

function Get-DefaultBranch
{
    # PE_DEFAULT_BRANCH (from the pipeline's DefaultBranch setting) wins; otherwise the repository's own default.
    param ([hashtable]$Ado)
    $name = $env:PE_DEFAULT_BRANCH
    if (-not $name) { $name = (Invoke-AdoRest -Ado $Ado -Method Get -Path '?api-version=7.1').defaultBranch }
    if (-not $name) { throw 'Could not find the default branch of the repository. Set PE_DEFAULT_BRANCH.' }
    $name = $name -replace '^refs/heads/', ''
    if ($name -cnotmatch '\A[A-Za-z0-9._/-]{1,100}\z') { throw "The default branch name '$name' is not a plain branch name." }
    $name
}

function Invoke-Git
{
    # The one place git is called. Arguments are separate strings (never a command line built from text).
    param ([string]$RepoPath, [string[]]$GitArguments)
    $output = & git -C $RepoPath @GitArguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArguments -join ' ') failed (exit $LASTEXITCODE): $($output -join ' ')" }
    $output
}

function Get-OpenPullRequestAddress
{
    param ([hashtable]$Ado, [string]$Branch)
    $ref = [uri]::EscapeDataString("refs/heads/$Branch")
    $found = Invoke-AdoRest -Ado $Ado -Method Get -Path "/pullrequests?searchCriteria.sourceRefName=$ref&searchCriteria.status=active&api-version=7.1"
    $first = @($found.value) | Select-Object -First 1
    if ($first) { "$($first.repository.webUrl)/pullrequest/$($first.pullRequestId)" }
}

# 1. Shape of the arguments, before anything is touched or any command is built.
if ($Version -cnotmatch '\A\d+\.\d+\.\d+\.\d+\z') { throw "Version '$Version' must be four numbers separated by dots, for example 2.26.1104.1." }
if ($GraphAuthenticationVersion -and $GraphAuthenticationVersion -cnotmatch '\A\d+\.\d+\.\d+\z') { throw "GraphAuthenticationVersion '$GraphAuthenticationVersion' must be three numbers separated by dots, for example 2.41.1 (or empty to keep it)." }
if (-not (Test-Path -LiteralPath $PinPath -PathType Leaf)) { throw "No pin file at $PinPath." }
$PinPath = (Resolve-Path -LiteralPath $PinPath).ProviderPath

# 2. What changes.
$bytes = [IO.File]::ReadAllBytes($PinPath)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$text = [IO.File]::ReadAllText($PinPath)
$oldDsc = (Get-PinLine -Text $text -Key 'Microsoft365DSC').Groups[2].Value
$oldGraph = (Get-PinLine -Text $text -Key 'MicrosoftGraphAuthentication').Groups[2].Value
$dscChanges = $Version -ne $oldDsc
$graphChanges = [bool]$GraphAuthenticationVersion -and $GraphAuthenticationVersion -ne $oldGraph
if (-not $dscChanges -and -not $graphChanges)
{
    Write-Host "Nothing to do: Microsoft365DSC $oldDsc is already pinned$(if ($GraphAuthenticationVersion) { " and Microsoft.Graph.Authentication $oldGraph" }). The file is unchanged."
    return
}

# 3. The gallery must have what is asked for.
if (-not $SkipGalleryCheck)
{
    if ($dscChanges -and -not (Test-GalleryHas -Name 'Microsoft365DSC' -Version $Version)) { throw "The PowerShell Gallery has no Microsoft365DSC $Version. Nothing was changed." }
    if ($graphChanges -and -not (Test-GalleryHas -Name 'Microsoft.Graph.Authentication' -Version $GraphAuthenticationVersion)) { throw "The PowerShell Gallery has no Microsoft.Graph.Authentication $GraphAuthenticationVersion. Nothing was changed." }
}

$summary = @()
$downgrade = $false
if ($dscChanges) { $summary += "Microsoft365DSC $oldDsc -> $Version"; if ([version]$Version -lt [version]$oldDsc) { $downgrade = $true } }
if ($graphChanges) { $summary += "Microsoft.Graph.Authentication $oldGraph -> $GraphAuthenticationVersion"; if ([version]$GraphAuthenticationVersion -lt [version]$oldGraph) { $downgrade = $true } }

# The branch for the same version is the one pull request for it (a Graph-only or combined bump gets its own name).
$branch = "dsc-pin/$Version"
if ($graphChanges) { $branch += "-graph-$GraphAuthenticationVersion" }

# 4. Pull request path: check everything it needs, and whether the branch is already there, before editing.
if ($CreatePullRequest)
{
    $ado = Get-AdoSetting
    $repoPath = (Invoke-Git -RepoPath (Split-Path $PinPath -Parent) -GitArguments @('rev-parse', '--show-toplevel') | Select-Object -First 1).ToString()
    $remoteHas = Invoke-Git -RepoPath $repoPath -GitArguments @('ls-remote', '--heads', 'origin', "refs/heads/$branch")
    if ($remoteHas)
    {
        $address = Get-OpenPullRequestAddress -Ado $ado -Branch $branch
        Write-Host "Branch $branch already exists on the remote, so nothing new was created."
        Write-Host $(if ($address) { "Pull request: $address" } else { "No pull request is open for it; look at the branch $branch in the repository." })
        return
    }
    $target = Get-DefaultBranch -Ado $ado
}

# 5. The edit: only the value on the pin line.
$newText = $text
if ($dscChanges) { $newText = Set-PinValue -Text $newText -Key 'Microsoft365DSC' -Value $Version }
if ($graphChanges) { $newText = Set-PinValue -Text $newText -Key 'MicrosoftGraphAuthentication' -Value $GraphAuthenticationVersion }
[IO.File]::WriteAllText($PinPath, $newText, [Text.UTF8Encoding]::new($hasBom))
foreach ($line in $summary) { Write-Host $line }
if ($downgrade) { Write-Host 'DOWNGRADE: the new version is lower than the one pinned now. Check that this is intended.' }

if (-not $CreatePullRequest) { return }

# 6. Branch, commit, push, pull request. The only writes: this branch and this pull request.
$message = "chore: pin $($summary -join ', ')"
Invoke-Git -RepoPath $repoPath -GitArguments @('checkout', '-b', $branch) | Out-Null
Invoke-Git -RepoPath $repoPath -GitArguments @('add', '--', $PinPath) | Out-Null
Invoke-Git -RepoPath $repoPath -GitArguments @('-c', 'user.name=M365DSC pin pipeline', '-c', 'user.email=pin-pipeline@localhost', 'commit', '-m', $message) | Out-Null
Invoke-Git -RepoPath $repoPath -GitArguments @('push', 'origin', "refs/heads/${branch}:refs/heads/$branch") | Out-Null

$description = @("Moves the pinned versions: $($summary -join '; ').")
if ($downgrade) { $description += 'DOWNGRADE: the new version is lower than the one pinned now.' }
$description += 'Opened by the Bump DSC pins pipeline. After merging: take fresh exports (an export made with another pin is refused) and run the install step on the agents.'
$body = @{
    sourceRefName = "refs/heads/$branch"
    targetRefName = "refs/heads/$target"
    title         = $(if ($downgrade) { "DOWNGRADE: $message" } else { $message })
    description   = ($description -join "`n`n")
}
$pr = Invoke-AdoRest -Ado $ado -Method Post -Path '/pullrequests?api-version=7.1' -Body $body
Write-Host "Pull request: $($pr.repository.webUrl)/pullrequest/$($pr.pullRequestId)"
