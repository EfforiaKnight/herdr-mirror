#!/usr/bin/env bash
#
# mirror.sh — Mirror herdr-core (hc) or the herdr app from releases.herdr.dev
# to GitHub releases.
#
# Upstream publishes each component through a flat manifest:
#   https://releases.herdr.dev/<component>/latest.json
#     {version, targets: {"<os>-<arch>": {url, sha256}}, ...}
# The official install.sh scripts read the same manifest. This script does too:
# it downloads every archive listed for the latest version, checks it against
# the manifest's sha256, and publishes it as a GitHub release asset. Archives are
# the unmodified upstream files, keeping their upstream names.
#
# Usage: mirror.sh core|app
#
# Env:
#   RELEASES_URL       upstream base (default: https://releases.herdr.dev)
#   DRY_RUN            set to 1 to download/verify without creating a release
#   GITHUB_REPOSITORY  owner/repo (set automatically in GitHub Actions)
#
set -euo pipefail

component="${1:?usage: mirror.sh core|app}"
case "$component" in
  core) title_prefix="herdr-core" ;;
  app) title_prefix="Herdr app" ;;
  *) echo "[mirror] ERROR: unknown component '$component' (want core or app)" >&2; exit 2 ;;
esac

RELEASES_URL="${RELEASES_URL:-https://releases.herdr.dev}"
RELEASES_URL="${RELEASES_URL%/}"
REPO="${GITHUB_REPOSITORY:-}"
DRY_RUN="${DRY_RUN:-0}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

log() { echo "[mirror:$component] $*" >&2; }
fail() { echo "[mirror:$component] ERROR: $*" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# 1. Read the latest manifest
log "fetching $RELEASES_URL/$component/latest.json"
curl -fsSL "$RELEASES_URL/$component/latest.json" -o latest.json || fail "cannot fetch latest.json"
VERSION="$(jq -r '.version // empty' latest.json)"
[ -n "$VERSION" ] || fail "no version in latest.json"
TAG="$component-v$VERSION"
TITLE="$title_prefix $VERSION"
log "latest version $VERSION (release tag $TAG)"

# 2. Check whether this release already exists. Older mirror releases predate
# feed-manifest.json; backfill that asset once without replacing the archives.
release_exists=0
if [ -n "$REPO" ] && [ "$DRY_RUN" != "1" ]; then
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    release_exists=1
    if gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -Fxq 'feed-manifest.json'; then
      log "release $TAG already exists and includes its update feed, nothing to do"
      exit 0
    fi
    log "release $TAG exists without feed-manifest.json; will add it"
  fi
fi

# 3. Download and verify every target archive
mkdir -p assets
: > SHA256SUMS.txt
: > SOURCES.txt

mapfile -t targets < <(jq -r '.targets | keys[]' latest.json)
[ "${#targets[@]}" -gt 0 ] || fail "no targets in latest.json"

for target in "${targets[@]}"; do
  url="$(jq -r --arg t "$target" '.targets[$t].url // empty' latest.json)"
  want="$(jq -r --arg t "$target" '.targets[$t].sha256 // empty' latest.json)"
  [ -n "$url" ] && [ -n "$want" ] || fail "missing url or sha256 for $target"

  # Only follow manifest URLs on the release server we expect
  case "$url" in
    "$RELEASES_URL"/*) ;;
    *) fail "unexpected url for $target: $url" ;;
  esac

  # A query or fragment is not part of the asset filename.
  fname="$(printf '%s' "$url" | sed 's/[?#].*$//' | sed 's#.*/##')"
  [ -n "$fname" ] || fail "cannot determine asset filename for $target"
  log "fetching $target: $fname"
  curl -fsSL -o "assets/$fname" "$url" || fail "download failed: $url"

  got="$(sha256 "assets/$fname")"
  [ "$got" = "$want" ] || fail "sha256 mismatch for $fname (manifest $want, got $got)"
  log "sha256 OK: $fname"

  echo "$got  $fname" >> SHA256SUMS.txt
  echo "$target <- $url" >> SOURCES.txt
done

# 4. Keep a copy of the upstream metadata for Herdr's updater. The only
# change is each target URL: it now points to this release's identical asset.
[ -n "$REPO" ] || fail "GITHUB_REPOSITORY is not set; refusing to publish a feed"
release_base="https://github.com/$REPO/releases/download/$TAG"
jq --arg base "$release_base" '
  .targets |= with_entries(
    .value.url = ($base + "/" + (.value.url | sub("[?#].*$"; "") | split("/")[-1]))
  )
' latest.json > assets/feed-manifest.json

jq -e --arg version "$VERSION" --arg prefix "$release_base/" '
  .version == $version
  and (.targets | type == "object" and length > 0)
  and all(.targets[]; ((.url | startswith($prefix)) and (.sha256 | test("^[0-9a-fA-F]{64}$"))))
' assets/feed-manifest.json >/dev/null || fail "generated feed-manifest.json is invalid"
if [ "$component" = "core" ]; then
  jq -e '.generation | type == "number"' assets/feed-manifest.json >/dev/null || fail "core manifest has no numeric generation"
fi
echo "$(sha256 assets/feed-manifest.json)  feed-manifest.json" >> SHA256SUMS.txt
log "generated feed-manifest.json with GitHub Release asset URLs"

# 5. The app also ships a macOS DMG for website downloads, outside the manifest.
#    Best effort: its sha256 is not in the manifest, so it is listed but not verified against one.
if [ "$component" = "app" ]; then
  dmg="Herdr-$VERSION.dmg"
  if curl -fsSL -o "assets/$dmg" "$RELEASES_URL/app/$VERSION/Herdr.dmg"; then
    echo "$(sha256 "assets/$dmg")  $dmg" >> SHA256SUMS.txt
    echo "macos-dmg <- $RELEASES_URL/app/$VERSION/Herdr.dmg" >> SOURCES.txt
    log "staged $dmg (not in manifest, unverified)"
  else
    rm -f "assets/$dmg"
    log "no DMG at app/$VERSION/Herdr.dmg, skipping"
  fi
fi

[ -s SHA256SUMS.txt ] || fail "no assets were staged"

if [ "$DRY_RUN" = "1" ]; then
  log "dry run complete, assets:"
  ls -la assets/
  cat SHA256SUMS.txt
  cat assets/feed-manifest.json
  exit 0
fi

[ -n "$REPO" ] || fail "GITHUB_REPOSITORY is not set; refusing to create release"

# 6. Release notes with provenance
{
  echo "Unofficial mirror of **$title_prefix $VERSION**, copied from the release server the official installers use."
  echo
  echo "Each archive below is the unmodified upstream file, checked against the sha256 in the upstream"
  echo "\`latest.json\` manifest before upload. Verify your download against \`SHA256SUMS.txt\`."
  echo
  echo "## Provenance"
  echo
  echo "- Mirrored: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Upstream: https://github.com/herdrdev/$([ "$component" = core ] && echo herdr-core || echo herdr-app)"
  echo "- Manifest: $RELEASES_URL/$component/latest.json"
  echo "- Official install: $RELEASES_URL/$component/install.sh"
  echo
  echo "## Sources"
  echo
  sed 's/^/- /' SOURCES.txt
  echo
  echo "## SHA256"
  echo
  echo '```'
  cat SHA256SUMS.txt
  echo '```'
} > notes.md

# 7. Create the release and upload assets
log "creating release $TAG in $REPO"
if [ "$release_exists" = "1" ]; then
  gh release upload "$TAG" \
    --repo "$REPO" \
    --clobber \
    assets/feed-manifest.json SHA256SUMS.txt
else
  gh release create "$TAG" \
    --repo "$REPO" \
    --title "$TITLE" \
    --notes-file notes.md \
    assets/* SHA256SUMS.txt
fi

log "mirror complete: $TAG"
