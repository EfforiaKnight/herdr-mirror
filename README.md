# herdr-mirror

Unofficial mirror of **herdr-core** (\`hc\`) and the **Herdr desktop app**. It stores release archives as GitHub Release assets and publishes the update files that Herdr's installers and background updater expect.

- Upstream core: <https://github.com/herdrdev/herdr-core>
- Upstream app: <https://github.com/herdrdev/herdr-app>
- This mirror: <https://github.com/EfforiaKnight/herdr-mirror>

## Use this as a replacement for releases.herdr.dev

The feed base URL is:

\`\`\`text
https://raw.githubusercontent.com/EfforiaKnight/herdr-mirror/main
\`\`\`

The repository publishes these paths:

- \`app/latest.json\` — latest app version and platform downloads.
- \`core/latest.json\` — latest core version, generation, and platform downloads.
- \`core/<version>/manifest.json\` — a version-specific core manifest.
- \`app/install.sh\`, \`app/install.ps1\`, \`core/install.sh\`, \`core/install.ps1\` — the upstream installers.

The JSON manifests preserve the upstream version, generation, target names, and SHA-256 values. Only the archive URLs change. They point to the matching GitHub Release assets.

### Windows PowerShell

Set the variable for your Windows user. Also set it in the current PowerShell process before you run the installer:

\`\`\`powershell
$mirror = "https://raw.githubusercontent.com/EfforiaKnight/herdr-mirror/main"
[Environment]::SetEnvironmentVariable("HERDR_RELEASES_URL", $mirror, "User")
$env:HERDR_RELEASES_URL = $mirror

# Install or update the Herdr desktop app. It installs herdr-core if needed.
irm "$mirror/app/install.ps1" | iex

# Or install/update only herdr-core:
# irm "$mirror/core/install.ps1" | iex
\`\`\`

Close and reopen Herdr after setting the user variable. Windows apps that were already running do not receive a changed environment.

### Linux and WSL

Set the variable in your shell profile so commands and app processes started from that login can use the mirror:

\`\`\`sh
export HERDR_RELEASES_URL="https://raw.githubusercontent.com/EfforiaKnight/herdr-mirror/main"
curl -fsSL "$HERDR_RELEASES_URL/app/install.sh" | sh
\`\`\`

For a core-only install, use \`$HERDR_RELEASES_URL/core/install.sh\`.

### Check the feeds

\`\`\`sh
MIRROR=https://raw.githubusercontent.com/EfforiaKnight/herdr-mirror/main
curl -fsSL "$MIRROR/app/latest.json" | jq .
curl -fsSL "$MIRROR/core/latest.json" | jq .
\`\`\`

The repository must remain public for unauthenticated installers to download its feeds and release assets.

## Release tags

- \`core-v<version>\`: herdr-core (for example, \`core-v0.2.0\`).
- \`app-v<version>\`: the Herdr desktop app (for example, \`app-v0.1.11\`).

Archive names are kept from upstream, such as \`herdr-core-linux-x86_64.tar.gz\` and \`herdr-app-windows-x86_64.tar.gz\`. App releases may also include the macOS DMG.

## How it works

- \`.github/workflows/mirror.yml\` runs every 6 hours. You can also run it from **Actions → Mirror herdr releases → Run workflow**.
- \`scripts/mirror.sh core|app\` reads the upstream latest manifest, downloads every target, and verifies its SHA-256.
- The mirror adds \`feed-manifest.json\` to each GitHub Release. It keeps the upstream metadata and rewrites target URLs to that release's assets.
- The \`publish-feeds\` job writes the latest app/core JSON files and the versioned core manifests to this repository. It also copies the current upstream installer scripts.
- Existing releases are skipped after their feed manifest exists. An older release without that asset is backfilled without replacing its archives.

To check a release without publishing, set \`GITHUB_REPOSITORY=EfforiaKnight/herdr-mirror\` and run \`DRY_RUN=1 bash scripts/mirror.sh core\`.

## Telemetry

This mirror and its GitHub Actions workflow do not add telemetry. The official Herdr app release has usage telemetry enabled by default. You can disable it in **Settings → Privacy** in the app.

## Disclaimer

Unofficial mirror, not affiliated with the Herdr team. Release archives are copies of the official builds. Use at your own discretion.
