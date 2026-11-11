#!/usr/bin/env bash
#
# Publish static Herdr update feeds from verified GitHub Release manifests.
# The feed files are served from raw.githubusercontent.com/<owner>/<repo>/main.
#
set -euo pipefail

REPO="$GITHUB_REPOSITORY"
if [ -z "$REPO" ]; then
  echo "[feeds] ERROR: GITHUB_REPOSITORY is not set" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { echo "[feeds] $*" >&2; }
fail() { echo "[feeds] ERROR: $*" >&2; exit 1; }

release_tags() {
  local prefix="$1"
  gh release list --repo "$REPO" --limit 1000 --json tagName,publishedAt |
    jq -r --arg prefix "$prefix" '
      [.[] | select(.tagName | startswith($prefix))]
      | sort_by(.publishedAt)
      | reverse
      | .[].tagName
    '
}

download_manifest() {
  local component="$1"
  local tag="$2"
  local expected_version="$3"
  local out_dir="$WORKDIR/$component-$expected_version"
  local prefix="https://github.com/$REPO/releases/download/$tag/"

  mkdir -p "$out_dir"
  if ! gh release download "$tag" --repo "$REPO" \
      --pattern feed-manifest.json --dir "$out_dir" >/dev/null 2>&1; then
    return 1
  fi

  local file="$out_dir/feed-manifest.json"
  [ -s "$file" ] || return 1

  if [ "$component" = "core" ]; then
    jq -e --arg version "$expected_version" --arg prefix "$prefix" '
      .version == $version
      and (.generation | type == "number")
      and (.targets | type == "object" and length > 0)
      and all(.targets[]; ((.url | startswith($prefix)) and (.sha256 | test("^[0-9a-fA-F]{64}$"))))
    ' "$file" >/dev/null || return 1
  else
    jq -e --arg version "$expected_version" --arg prefix "$prefix" '
      .version == $version
      and (.targets | type == "object" and length > 0)
      and all(.targets[]; ((.url | startswith($prefix)) and (.sha256 | test("^[0-9a-fA-F]{64}$"))))
    ' "$file" >/dev/null || return 1
  fi

  printf '%s\n' "$file"
}

# The upstream installer scripts also use HERDR_RELEASES_URL. Mirror them
# beside the manifests, so the app installer can find the core installer too.
fetch_installer() {
  local upstream_repo="$1"
  local upstream_path="$2"
  local destination="$3"
  local url="https://raw.githubusercontent.com/$upstream_repo/master/$upstream_path"

  mkdir -p "$(dirname "$destination")"
  curl -fsSL "$url" -o "$destination" || fail "cannot fetch installer $url"
  grep -Fq 'HERDR_RELEASES_URL' "$destination" || fail "installer does not support HERDR_RELEASES_URL: $url"
}

# Find the newest published app release and publish app/latest.json.
app_tags="$(release_tags "app-v")"
[ -n "$app_tags" ] || fail "no mirrored app releases exist yet; run the mirror workflow for all components"
latest_app_tag="$(printf '%s\n' "$app_tags" | head -n 1)"
latest_app_version="$(printf '%s\n' "$latest_app_tag" | sed 's/^app-v//')"
app_manifest="$(download_manifest app "$latest_app_tag" "$latest_app_version")" ||
  fail "latest app release $latest_app_tag has no valid feed-manifest.json"
mkdir -p app
cp "$app_manifest" app/latest.json
log "prepared app/latest.json from $latest_app_tag"

# Publish one versioned core manifest for each release that carries valid
# metadata. Keep old feeds in place; never delete a previously published version.
core_tags="$(release_tags "core-v")"
[ -n "$core_tags" ] || fail "no mirrored core releases exist yet; run the mirror workflow for all components"
latest_core_tag="$(printf '%s\n' "$core_tags" | head -n 1)"
latest_core_version="$(printf '%s\n' "$latest_core_tag" | sed 's/^core-v//')"
latest_core_manifest=""

while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  version="$(printf '%s\n' "$tag" | sed 's/^core-v//')"
  if manifest="$(download_manifest core "$tag" "$version")"; then
    mkdir -p "core/$version"
    cp "$manifest" "core/$version/manifest.json"
    log "prepared core/$version/manifest.json"
    if [ "$tag" = "$latest_core_tag" ]; then
      latest_core_manifest="$manifest"
    fi
  elif [ "$tag" = "$latest_core_tag" ]; then
    fail "latest core release $tag has no valid feed-manifest.json"
  else
    log "skipping old release $tag: no valid feed-manifest.json"
  fi
done <<EOF
$core_tags
EOF

[ -n "$latest_core_manifest" ] || fail "latest core manifest was not prepared"
cp "$latest_core_manifest" core/latest.json
log "prepared core/latest.json from $latest_core_tag"

fetch_installer herdrdev/herdr-app distribution/install.sh app/install.sh
fetch_installer herdrdev/herdr-app distribution/install.ps1 app/install.ps1
fetch_installer herdrdev/herdr-core distribution/install.sh core/install.sh
fetch_installer herdrdev/herdr-core distribution/install.ps1 core/install.ps1
log "copied the current upstream app and core installers"

# The update feeds are ordinary text files in this repository. A commit makes
# them available at the raw.githubusercontent.com URLs without a Pages build.
git add app core
if git diff --cached --quiet; then
  log "feeds and installer scripts are already current"
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git commit -m "Publish mirrored Herdr update feeds"
git push origin HEAD:main
log "published update feeds to $REPO main"
