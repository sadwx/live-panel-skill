# Usage: pwsh publish.ps1 -HtmlPath checkout-live-panel.html -Slug checkout-platform [-Replace] [-SkipDeploy]
# Batch: stage every panel but the last with -SkipDeploy, then publish the last one normally; that one deploy carries
# them all (the service rate-limits back-to-back deploys). The final check proves only the last panel's build is served.
# Copies the panel into the local site folder as <slug>-<12 hex>/index.html and redeploys the whole
# site to Azure Static Web Apps (Free, public, unlisted). Prints the public URL.
# The site folder is the source of truth: `swa deploy` replaces the deployed site with its contents.
# Needs: az login with access to the Static Web App, node (npx). The deployment token is fetched per run
# and only ever lives in an environment variable.
param(
  [Parameter(Mandatory)][string]$HtmlPath,
  [Parameter(Mandatory)][string]$Slug,
  [string]$SiteDir = ($env:LIVE_PANELS_SITE ?? (Join-Path $HOME 'live-panels/site')),
  [string]$AppName = ($env:LIVE_PANELS_APP ?? 'live-panels'),
  [string]$ResourceGroup = $env:LIVE_PANELS_RESOURCE_GROUP,
  [string]$Subscription = $env:LIVE_PANELS_SUBSCRIPTION,   # empty: the az default subscription
  [switch]$Replace,    # reuse an existing <slug>-xxxx folder (keeps the URL) instead of minting a new suffix
  [switch]$SkipDeploy  # only write the panel into the site folder; a later run without it deploys every staged panel at once
)
$ErrorActionPreference = 'Stop'
if (-not $SkipDeploy -and -not $ResourceGroup) { throw 'Set LIVE_PANELS_RESOURCE_GROUP or pass -ResourceGroup.' }
$azCmd = (Get-Command az.cmd).Source
# A missing or partial site folder would deploy as the whole site and delete every other panel.
foreach ($required in 'staticwebapp.config.json', 'index.html') {
  if (-not (Test-Path (Join-Path $SiteDir $required))) { throw "$SiteDir\$required not found; restore the site folder before publishing." }
}
$utf8 = [Text.UTF8Encoding]::new($false)

# Wrap the template's bare <title>/<style>/<div> fragment in a full document with noindex.
$html = [IO.File]::ReadAllText((Resolve-Path $HtmlPath), $utf8)
if ($html -notmatch '(?i)<!doctype') {
  $headEnd = $html.IndexOf('</style>') + '</style>'.Length
  $html = "<!doctype html>`n<html lang=`"en`">`n<head>`n<meta charset=`"utf-8`">`n" +
          "<meta name=`"viewport`" content=`"width=device-width,initial-scale=1`">`n" +
          "<meta name=`"robots`" content=`"noindex,nofollow`">`n" + $html.Substring(0, $headEnd) +
          "`n</head>`n<body>" + $html.Substring($headEnd).TrimEnd() + "`n</body>`n</html>`n"
}
# A per-run marker, so the check below proves this build is served (with -Replace the old page already answers 200).
$nonce = [guid]::NewGuid().ToString('n')
$html = $html -replace '(?i)</head>', "<meta name=`"deploy`" content=`"$nonce`">`n</head>"

$existing = @(Get-ChildItem $SiteDir -Directory -Filter "$Slug-*" -ErrorAction SilentlyContinue | Where-Object Name -match "^$([regex]::Escape($Slug))-([0-9a-f]{4}|[0-9a-f]{12})$")
if ($Replace -and $existing.Count -eq 1) { $folder = $existing[0].Name }
elseif ($Replace -and $existing.Count -gt 1) { throw "Several folders match $Slug-xxxx; pass the full folder name as -Slug." }
else { $folder = "$Slug-" + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(6)).ToLower() }   # the suffix is the only access control
$target = Join-Path $SiteDir $folder
New-Item -ItemType Directory -Force $target | Out-Null
[IO.File]::WriteAllText((Join-Path $target 'index.html'), $html, $utf8)
if ($SkipDeploy) { "staged $folder (not deployed)"; return }

$subArgs = if ($Subscription) { '--subscription', $Subscription } else { @() }
$host_ = (& $azCmd staticwebapp show -n $AppName -g $ResourceGroup @subArgs -o json | ConvertFrom-Json).defaultHostname
$env:SWA_CLI_DEPLOYMENT_TOKEN = (& $azCmd staticwebapp secrets list -n $AppName -g $ResourceGroup @subArgs -o json | ConvertFrom-Json).properties.apiKey
Push-Location (Split-Path $SiteDir -Parent)   # swa scans the working directory for its config file
try {
  # The service rate-limits deploys: back-to-back runs get "Too many deployments have been requested, please try again
  # later" (only visible with --verbose=silly; otherwise swa prints a misleading "missing shared libraries" hint). Wait that
  # out with a growing backoff; any other failure stops at once with the service's reason. For a batch, use -SkipDeploy.
  for ($attempt = 1; ; $attempt++) {
    $log = @(npx -y @azure/static-web-apps-cli@2.0.10 deploy (Split-Path $SiteDir -Leaf) --env production --no-use-keychain --verbose=silly 2>&1 |
      ForEach-Object { "$_" } | Where-Object { $_ -notmatch '(?i)token|apikey' })
    if ($LASTEXITCODE -eq 0) { $log | Select-String 'deployed to' | Select-Object -Last 1; break }
    $reason = ($log | Select-String 'rejected|Reason:' | ForEach-Object { $_.Line.Trim() }) -join ' '
    if ($reason -notmatch 'Too many deployments' -or $attempt -ge 4) { throw "swa deploy failed ($LASTEXITCODE) on attempt ${attempt}: $(if ($reason) { $reason } else { $log | Select-Object -Last 5 })" }
    Write-Warning "deploy rate-limited, attempt $attempt of 4; retrying in $(60 * $attempt) s"
    Start-Sleep -Seconds (60 * $attempt)
  }
} finally { Remove-Item Env:SWA_CLI_DEPLOYMENT_TOKEN -ErrorAction SilentlyContinue; Pop-Location }

$url = "https://$host_/$folder/"
# The CDN can serve a 404 or the previous build for a few seconds after the deploy reports success, so poll for this run's marker.
$deadline = (Get-Date).AddSeconds(60)
do {
  $resp = Invoke-WebRequest $url -UseBasicParsing -SkipHttpErrorCheck -Headers @{ 'Cache-Control' = 'no-cache' }
  if ($resp.StatusCode -eq 200 -and $resp.Content -match $nonce) { break }
  if ((Get-Date) -ge $deadline) { throw "Deployed, but $url is not serving this build after 60 s (last status $($resp.StatusCode))" }
  Start-Sleep -Seconds 3
} while ($true)

# Back up what is now live: commit the site folder and push it to its repo (if it is one).
# The deploy already succeeded, so a git failure only warns.
$repoRoot = git -C $SiteDir rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0) {
  git -C $repoRoot add -A -- $SiteDir
  git -C $repoRoot diff --cached --quiet
  if ($LASTEXITCODE -ne 0) { git -C $repoRoot commit -q -m "Publish $folder" }
  $pushArgs = @()
  if ((git -C $repoRoot remote get-url origin) -match 'dev\.azure\.com') {
    $adoToken = & $azCmd account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
    $pushArgs = '-c', "http.extraHeader=Authorization: Bearer $adoToken"
  }
  git -C $repoRoot @pushArgs push -q origin HEAD 2>&1 | Where-Object { "$_" -notmatch '(?i)bearer' }
  if ($LASTEXITCODE -ne 0) { Write-Warning "Deployed, but pushing $repoRoot failed; commit and push it by hand." }
} else { Write-Warning "$SiteDir is not in a git repo; the live site has no backup." }
$url
