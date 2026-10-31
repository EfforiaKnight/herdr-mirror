# herdr-mirror

Unofficial mirror of the **herdr-core** (`hc`) and **herdr app** release archives as GitHub release assets.

The official installers (`releases.herdr.dev/core/install.sh` and `releases.herdr.dev/app/install.sh`)
serve builds from the upstream release host, not from GitHub releases. This repo polls the same
manifests the installers read, downloads each archive, checks it against the manifest's sha256,
and publishes it here with checksums.

- Upstream core: <https://github.com/herdrdev/herdr-core>
- Upstream app: <https://github.com/herdrdev/herdr-app>

Release tags:

- `core-v<version>`: herdr-core (`hc`), e.g. `core-v0.2.0`
- `app-v<version>`: the Herdr desktop app, e.g. `app-v0.1.11`

Archives keep their upstream names (e.g. `herdr-core-linux-x86_64.tar.gz`, `herdr-app-macos-aarch64.tar.gz`).
The app release also includes `Herdr-<version>.dmg` for macOS, which is not in the upstream manifest.

## Install

Download an archive from the [releases page](../../releases), check it, and extract it. Example: herdr-core on Linux x86_64:

```sh
VERSION=0.2.0   # pick the release you want
curl -fsSL -O "https://github.com/jaykv/herdr-mirror/releases/download/core-v$VERSION/herdr-core-linux-x86_64.tar.gz"
curl -fsSL -O "https://github.com/jaykv/herdr-mirror/releases/download/core-v$VERSION/SHA256SUMS.txt"
sha256sum -c SHA256SUMS.txt --ignore-missing
tar -xzf herdr-core-linux-x86_64.tar.gz
install -m 755 herdr-core ~/.local/bin/herdr-core
ln -sf herdr-core ~/.local/bin/hc
hc --version
```

For the official installer flow and update behavior, see the upstream READMEs linked above.

## How it works

- `.github/workflows/mirror.yml` runs every 6 hours (and on demand, for `all`, `core` or `app`).
- `scripts/mirror.sh core|app` reads `https://releases.herdr.dev/<component>/latest.json`,
  downloads every target archive, verifies its sha256 against the manifest, and creates
  a release named after the version with the archives plus `SHA256SUMS.txt`.
- Release notes record provenance: the manifest URL, the upstream repo and the mirror time.
- Already-mirrored versions are skipped automatically.

To check a version without publishing, run `DRY_RUN=1 bash scripts/mirror.sh core` locally.

## Disclaimer

Unofficial mirror, not affiliated with the herdr team. Archives are unmodified copies of the
official builds. Use at your own discretion.
