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

# 2. Skip if already mirrored
if [ -n "$REPO" ] && [ "$DRY_RUN" != "1" ]; then
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log "release $TAG already exists in $REPO, nothing to do"
    exit 0
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

  fname="${url##*/}"
  log "fetching $target: $fname"
  curl -fsSL -o "assets/$fname" "$url" || fail "download failed: $url"

  got="$(sha256 "assets/$fname")"
  [ "$got" = "$want" ] || fail "sha256 mismatch for $fname (manifest $want, got $got)"
  log "sha256 OK: $fname"

  echo "$got  $fname" >> SHA256SUMS.txt
  echo "$target <- $url" >> SOURCES.txt
done

# 4. The app also ships a macOS DMG for website downloads, outside the manifest.
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
  exit 0
fi

[ -n "$REPO" ] || fail "GITHUB_REPOSITORY is not set; refusing to create release"

# 5. Release notes with provenance
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

# 6. Create the release and upload assets
log "creating release $TAG in $REPO"
gh release create "$TAG" \
  --repo "$REPO" \
  --title "$TITLE" \
  --notes-file notes.md \
  assets/* SHA256SUMS.txt

log "mirror complete: $TAG"
