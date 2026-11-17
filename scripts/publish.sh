#!/usr/bin/env bash
# Usage: bash publish.sh --html checkout-live-panel.html --slug checkout-platform [--replace] [--skip-deploy]
#        [--site-dir DIR] [--app NAME] [--resource-group RG] [--subscription SUB]
# Unix-shell port of publish.ps1; same behaviour, same site layout.
# Batch: stage every panel but the last with --skip-deploy, then publish the last one normally; that one deploy carries
# them all (the service rate-limits back-to-back deploys). The final check proves only the last panel's build is served.
# Copies the panel into the local site folder as <slug>-<12 hex>/index.html and redeploys the whole
# site to Azure Static Web Apps (Free, public, unlisted). Prints the public URL.
# The site folder is the source of truth: `swa deploy` replaces the deployed site with its contents.
# Needs: az login with access to the Static Web App, node (npx), curl. The deployment token is fetched per run
# and only ever lives in an environment variable.
set -euo pipefail

html_path= slug= replace=0 skip_deploy=0
site_dir=${LIVE_PANELS_SITE:-$HOME/live-panels/site}
app=${LIVE_PANELS_APP:-live-panels} rg=${LIVE_PANELS_RESOURCE_GROUP:-} sub=${LIVE_PANELS_SUBSCRIPTION:-}
die() { echo "publish.sh: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case $1 in
    --html) html_path=$2; shift 2 ;;
    --slug) slug=$2; shift 2 ;;
    --site-dir) site_dir=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --resource-group) rg=$2; shift 2 ;;
    --subscription) sub=$2; shift 2 ;;
    --replace) replace=1; shift ;;         # reuse an existing <slug>-xxxx folder (keeps the URL) instead of minting a new suffix
    --skip-deploy) skip_deploy=1; shift ;; # only write the panel into the site folder; a later run without it deploys every staged panel at once
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$html_path" ] && [ -n "$slug" ] || die "--html and --slug are required"
[ -f "$html_path" ] || die "$html_path not found"
[ $skip_deploy = 1 ] || [ -n "$rg" ] || die "set LIVE_PANELS_RESOURCE_GROUP or pass --resource-group"
# A missing or partial site folder would deploy as the whole site and delete every other panel.
for required in staticwebapp.config.json index.html; do
  [ -f "$site_dir/$required" ] || die "$site_dir/$required not found; restore the site folder before publishing."
done
site_dir=$(cd "$site_dir" && pwd)

hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

shopt -s nullglob
existing=()
for d in "$site_dir/$slug"-*/; do
  name=$(basename "$d")
  [[ $name =~ ^.+-([0-9a-f]{4}|[0-9a-f]{12})$ && ${name%-*} == "$slug" ]] && existing+=("$name")
done
if [ $replace = 1 ] && [ ${#existing[@]} -eq 1 ]; then folder=${existing[0]}
elif [ $replace = 1 ] && [ ${#existing[@]} -gt 1 ]; then die "Several folders match $slug-xxxx; pass the full folder name as --slug."
else folder="$slug-$(hex 6)"   # the suffix is the only access control
fi
target="$site_dir/$folder"
mkdir -p "$target"

# Wrap the template's bare <title>/<style>/<div> fragment in a full document with noindex, and add a per-run
# marker so the check below proves this build is served (with --replace the old page already answers 200).
nonce=$(hex 16)
node - "$html_path" "$target/index.html" "$nonce" <<'EOF'
const fs = require('fs');
const [src, dst, nonce] = process.argv.slice(2);
let html = fs.readFileSync(src, 'utf8');
if (!/<!doctype/i.test(html)) {
  const headEnd = html.indexOf('</style>') + '</style>'.length;
  html = '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">\n' +
    '<meta name="robots" content="noindex,nofollow">\n' + html.slice(0, headEnd) +
    '\n</head>\n<body>' + html.slice(headEnd).trimEnd() + '\n</body>\n</html>\n';
}
html = html.replace(/<\/head>/gi, `<meta name="deploy" content="${nonce}">\n</head>`);
fs.writeFileSync(dst, html);
EOF
if [ $skip_deploy = 1 ]; then echo "staged $folder (not deployed)"; exit 0; fi

sub_args=()
[ -z "$sub" ] || sub_args=(--subscription "$sub")
host=$(az staticwebapp show -n "$app" -g "$rg" ${sub_args[@]+"${sub_args[@]}"} --query defaultHostname -o tsv | tr -d '\r')
SWA_CLI_DEPLOYMENT_TOKEN=$(az staticwebapp secrets list -n "$app" -g "$rg" ${sub_args[@]+"${sub_args[@]}"} --query properties.apiKey -o tsv | tr -d '\r')
export SWA_CLI_DEPLOYMENT_TOKEN
trap 'unset SWA_CLI_DEPLOYMENT_TOKEN' EXIT

# The service rate-limits deploys: back-to-back runs get "Too many deployments have been requested, please try again
# later" (only visible with --verbose=silly; otherwise swa prints a misleading "missing shared libraries" hint). Wait that
# out with a growing backoff; any other failure stops at once with the service's reason. For a batch, use --skip-deploy.
attempt=1
while :; do
  rc=0
  log=$(cd "$(dirname "$site_dir")" &&   # swa scans the working directory for its config file
        npx -y @azure/static-web-apps-cli@2.0.10 deploy "$(basename "$site_dir")" --env production --no-use-keychain --verbose=silly 2>&1) || rc=$?
  log=$(printf '%s\n' "$log" | grep -viE 'token|apikey' || true)
  if [ $rc -eq 0 ]; then printf '%s\n' "$log" | grep 'deployed to' | tail -n1 || true; break; fi
  reason=$(printf '%s\n' "$log" | grep -E 'rejected|Reason:' | sed 's/^[[:space:]]*//' | tr '\n' ' ' || true)
  if [[ $reason != *'Too many deployments'* ]] || [ $attempt -ge 4 ]; then
    die "swa deploy failed ($rc) on attempt $attempt: ${reason:-$(printf '%s\n' "$log" | tail -n5)}"
  fi
  echo "warning: deploy rate-limited, attempt $attempt of 4; retrying in $((60 * attempt)) s" >&2
  sleep $((60 * attempt))
  attempt=$((attempt + 1))
done
unset SWA_CLI_DEPLOYMENT_TOKEN

url="https://$host/$folder/"
# The CDN can serve a 404 or the previous build for a few seconds after the deploy reports success, so poll for this run's marker.
deadline=$(( $(date +%s) + 60 ))
while :; do
  body=$(curl -s -H 'Cache-Control: no-cache' -w '\n%{http_code}' "$url" || true)
  status=${body##*$'\n'}
  if [ "$status" = 200 ] && [[ $body == *"$nonce"* ]]; then break; fi
  [ "$(date +%s)" -lt $deadline ] || die "Deployed, but $url is not serving this build after 60 s (last status $status)"
  sleep 3
done

# Back up what is now live: commit the site folder and push it to its repo (if it is one).
# The deploy already succeeded, so a git failure only warns.
backup_site() {
  git -C "$repo_root" add -A -- "$site_dir" || return 1
  git -C "$repo_root" diff --cached --quiet || git -C "$repo_root" commit -q -m "Publish $folder" || return 1
  local auth=() token out rc=0
  if [[ $(git -C "$repo_root" remote get-url origin 2>/dev/null) == *dev.azure.com* ]]; then
    token=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv | tr -d '\r') || return 1
    auth=(-c "http.extraHeader=Authorization: Bearer $token")
  fi
  out=$(git -C "$repo_root" ${auth[@]+"${auth[@]}"} push -q origin HEAD 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | grep -vi bearer >&2 || true
  return $rc
}
if repo_root=$(git -C "$site_dir" rev-parse --show-toplevel 2>/dev/null); then
  backup_site || echo "warning: deployed, but committing or pushing $repo_root failed; do it by hand." >&2
else
  echo "warning: $site_dir is not in a git repo; the live site has no backup." >&2
fi
echo "$url"
