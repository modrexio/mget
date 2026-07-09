# mget

Shared install engine for the Modrex ecosystem. One script, reused by any number
of projects — each project supplies its own config and its own short install URL.

Supports **Linux and macOS only**. Windows users install via the `.exe`/`.msi`
release asset directly. Requires `curl` and `jq` on the user's machine.

## How it works

1. This repo publishes a single `install.sh` (the engine). It knows nothing about
   any specific project — only how to read a Tauri updater `latest.json` manifest,
   pick the right platform asset, verify it, and install it.
2. Each project (`modrex`, `Refract_MC`, ...) keeps an `install.config.json` in its
   own repo (see schema below).
3. Each project runs a small Cloudflare Worker at its own short URL (e.g.
   `modrex.net/install.sh`) that fetches a pinned tag of this engine plus that
   project's config, flattens the config into `CFG_*` env vars, and streams the
   combined script to `curl | sh`.

```
curl -fsSL https://modrex.net/install.sh | sh
```

## install.config.json schema

Lives in each project's own repo, next to its `tauri.conf.json`.

```json
{
  "schema_version": 1,
  "project_name": "modrex",
  "github_repo": "modrexio/modrex",
  "manifest_url": "https://github.com/modrexio/modrex/releases/latest/download/latest.json",
  "pubkey": "dW50cnVzdGVkIGNvbW1lbnQ6...",
  "preferred_variant": {
    "linux": "appimage",
    "darwin": "app"
  },
  "install_dir": "$HOME/.modrex/bin",
  "add_to_path": true,
  "post_install_cmd": "modrex --version",
  "uninstall_manifest": "$HOME/.modrex/uninstall.json"
}
```

| Field | Required | Notes |
|---|---|---|
| `project_name` | yes | Used for binary naming, default install/uninstall paths, log messages |
| `github_repo` | no | `owner/repo`, informational only — not read by the engine today |
| `manifest_url` | yes | Tauri updater manifest URL, normally the `/releases/latest/download/latest.json` alias. Must be `https://` |
| `pubkey` | no | Tauri updater public key (`tauri.conf.json` → updater signing config), raw base64. Once set, the engine requires `minisign` and a valid signature — it will refuse to install rather than silently skip verification. Leave unset until the project has real signing configured |
| `preferred_variant` | no | Per-OS suffix to prefer when the manifest has multiple platform-key variants for the same OS/arch (e.g. `linux-x86_64-deb` vs `linux-x86_64-appimage`). Falls back to the bare `{os}-{arch}` key if the preferred variant isn't published |
| `install_dir` | yes | Must be an absolute path or start with the literal string `$HOME/`, e.g. `$HOME/.modrex/bin` — no other shell expansion is performed (config is never `eval`'d) |
| `add_to_path` | no | Default `true` |
| `post_install_cmd` | no | Run after a successful install; a non-zero exit is reported as a warning, not a fatal error |
| `uninstall_manifest` | no | Defaults to `$HOME/.{project_name}/uninstall.json` |

## Worker integration

Each project's Worker does three things: fetch a **pinned tag** of this repo's
`install.sh` (never `@main`, so a bad push here can't break every project's
install at once), fetch that project's `install.config.json`, and concatenate
them with the config flattened into `CFG_*` exports ahead of the engine body.

## Usage

```
curl -fsSL <project-install-url> | sh
curl -fsSL <project-install-url> | sh -s -- --dry-run
curl -fsSL <project-install-url> | sh -s -- --uninstall
```

## Local testing

The script also runs standalone by exporting `CFG_*` vars directly:

```sh
CFG_PROJECT_NAME=modrex \
CFG_GITHUB_REPO=modrexio/modrex \
CFG_MANIFEST_URL=https://github.com/modrexio/modrex/releases/latest/download/latest.json \
CFG_INSTALL_DIR='$HOME/.modrex/bin' \
sh install.sh --dry-run
```
