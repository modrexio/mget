# mget

Shared install engine for the Modrex ecosystem. One script, reused by any number
of projects — each project supplies its own config and its own short install URL.

Supports **Linux and macOS only**. Windows users install via the `.exe`/`.msi`
release asset directly. Requires `curl` and `jq` unconditionally; `minisign`
and `base64` when a project configures `pubkey`; `dpkg-deb`/`rpm` to inspect
`.deb`/`.rpm` packages before installing them; `tar` for macOS `.app.tar.gz`
installs; `sudo` and the relevant package manager (apt/dnf/zypper, or
`dpkg`/`rpm` directly) for native package installs.

## How it works

1. This repo publishes a single `install.sh` (the engine). It knows nothing about
   any specific project — only how to choose the right manifest platform entry
   or inspect a GitHub-discovered package candidate, verify what it can, and
   install it. On Linux it prefers a native package manager (apt/dnf/zypper):
   it looks up `.deb`/`.rpm` assets via the GitHub Releases API rather than
   requiring an exact filename to be configured. When a release ships more
   than one package of the same format, it uses common architecture tokens
   (`amd64`/`x86_64`/`arm64`/etc.) in filenames as a preference among
   candidates, then validates the selected package's embedded architecture
   metadata — it does not download and inspect every candidate, so an
   unconventional filename with no recognizable arch token can still pick the
   wrong one before that validation catches it. It falls back to the AppImage
   only when no `.deb`/`.rpm` URL is found at all, not when a selected
   candidate fails validation. Before installing a `.deb`/`.rpm`, it reads
   the package's own embedded architecture, name, and version metadata
   (`dpkg-deb`/`rpm`) rather than trusting the GitHub asset list blindly —
   this catches a wrong-architecture asset, records the real package
   identifier for uninstall (and refuses to later remove anything else, even
   if the uninstall record is modified), and warns if the package's version
   doesn't match the release manifest's. It also registers a `.desktop`/icon
   entry for AppImage installs — same behavior as modrex's existing
   `scripts/install.sh`, which continues to exist independently for modrex
   (the two aren't meant to replace each other).
2. Each project (`modrex`, `Refract_MC`, ...) keeps an `install.config.json` in its
   own repo (see schema below).
3. Each project runs a small Cloudflare Worker at its own short URL (e.g.
   `modrex.net/install.sh`) that fetches a pinned tag of this engine plus that
   project's config, flattens the config into `CFG_*` env vars, and streams the
   combined script to `curl | sh`.

```sh
curl -fsSL https://modrex.net/install.sh | sh
```

## install.config.json schema

Lives at the root of each project's own repo.

```json
{
  "schema_version": 1,
  "project_name": "modrex",
  "github_repo": "modrexio/modrex",
  "manifest_url": "https://github.com/modrexio/modrex/releases/latest/download/latest.json",
  "pubkey": "RWTX2KsFhWADAjKhVxTe/CxS/HT+S3iMqrQorXSP/QUE20RjzISVRUbV",
  "preferred_variant": {
    "darwin": "app"
  },
  "macos_bundle_name": "Modrex",
  "macos_executable_name": "modrex",
  "deb_package_name": "modrex",
  "rpm_package_name": "modrex",
  "install_dir": "$HOME/.local/bin",
  "add_to_path": true,
  "post_install_cmd": "modrex --version",
  "uninstall_manifest": "$HOME/.modrex/uninstall.json",
  "install_url": "https://modrex.net/install.sh"
}
```

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | Must currently be `1` — the engine hard-errors on anything else |
| `project_name` | yes | Used for binary naming, default install/uninstall paths, and log messages. Letters, digits, `.`, `_`, `-` only, and cannot be exactly `.` or `..` — it ends up directly in filesystem paths |
| `github_repo` | no | `owner/repo`. Used to look up `.deb`/`.rpm` assets via the GitHub Releases API when apt/dnf/zypper is detected — without it, Linux package-manager users fall back to the AppImage |
| `manifest_url` | yes | Tauri updater manifest URL, normally the `/releases/latest/download/latest.json` alias. Must be `https://` |
| `pubkey` | no | The raw minisign public key string (starts with `RW...`), *not* the value stored directly in `tauri.conf.json`'s `plugins.updater.pubkey` — that field is itself base64-encoded content of a full minisign pubkey file (comment line + key line). Decode it once (`echo "$TAURI_PUBKEY" \| base64 -d`) and take only the second line. Once `pubkey` is set, the engine requires `minisign` and a valid signature — it will refuse to install rather than silently skip verification. Leave unset until the project has real signing configured |
| `preferred_variant` | no | Per-OS suffix to prefer when the manifest has multiple platform-key variants for the same OS/arch (e.g. `linux-x86_64-deb` vs `linux-x86_64-appimage`). Takes priority over `.deb`/`.rpm` discovery via `github_repo` |
| `macos_bundle_name` | no | The `.app` bundle's actual name (e.g. `Modrex`, not `modrex`) if it differs from `project_name`. Defaults to `project_name`. Uninstall only ever removes `$HOME/Applications/{macos_bundle_name}.app` exactly — never a wildcard — so this must match the real bundle name or uninstall won't find it |
| `macos_executable_name` | no | The name of the actual executable inside `Contents/MacOS/` in the `.app` bundle, if it differs from `project_name`. Defaults to `project_name`. Install fails with a clear error if it's wrong, rather than creating a symlink to a file that doesn't exist |
| `deb_package_name`, `rpm_package_name` | no | The real `Package`/`Name` identifier inside the built `.deb`/`.rpm`, if it differs from `project_name`. Debian Policy hard-requires lowercase and forbids underscores in package names (enforced by the tooling, not just a convention) — a `project_name` like `Refract_MC` can never literally equal its own `.deb` package name. RPM/Fedora naming is a softer, non-enforced convention but can still diverge. Defaults to `project_name` (confirmed to be the real value for modrex: `Package: modrex`). Install verifies the downloaded package's own metadata matches this value before installing, and uninstall will only ever remove a package with this exact name — even if the uninstall record is modified, this bounds it to at most this specific package, not an arbitrary one |
| `install_dir` | yes | Must be an absolute path or start with the literal string `$HOME/`, e.g. `$HOME/.local/bin` — no other shell expansion is performed (config is never `eval`'d). Restricted to `A-Za-z0-9_./+-` — no spaces, no shell metacharacters, and notably **no colon**: this value is inserted directly into `PATH`, where an embedded `:` would silently create a second, non-absolute (hijackable) `PATH` entry. It's also later written into a line appended to the user's shell rc file, so an unrestricted value could otherwise plant a `$(...)` command that runs the next time they open a shell |
| `add_to_path` | no | Default `true`. Never applied after a `.deb`/`.rpm` install, since the package manager already puts the binary on the system `PATH` |
| `post_install_cmd` | no | A trusted shell command run via `sh -c` after install; a non-zero exit is reported as a warning, not fatal. This is executable code, not data — only trusted project maintainers should be able to set it, same trust level as the project's build pipeline or signing key |
| `uninstall_manifest` | no | Defaults to `$HOME/.{project_name}/uninstall.json`. Same `$HOME/...`-or-absolute-path rule as `install_dir`, but *does* allow colons — this path is never inserted into `PATH` |
| `install_url` | no | The project's own public install URL (e.g. `https://modrex.net/install.sh`). Used only to print an accurate `curl \| sh -s -- --uninstall` hint after a successful install — the engine has no way to know its own public URL otherwise. Without it, the hint falls back to `sh $0 --uninstall`, which only makes sense when run from a local file, not piped from curl |

## Known limitations

- `.deb`/`.rpm` installs, discovered via the GitHub Releases API, are never
  signature-verified — those assets aren't part of the signed Tauri updater
  manifest, so mget doesn't currently consume any separate integrity metadata
  (hash or detached signature) for them (same posture `scripts/install.sh`
  already has). Only the manifest-sourced asset (normally the AppImage) gets
  minisign verification when a project configures `pubkey`. The downloaded
  package's own architecture/name metadata *is* checked before install, which
  catches a wrong-architecture asset and rejects packages whose metadata can't
  be read, but that's not the same guarantee as verifying it's the artifact
  the maintainer actually intended to release.
- The GitHub Releases API is unauthenticated and rate-limited to 60
  requests/hour per IP — fine for individual installs, but worth knowing.
- PATH entries added to a shell rc file are left behind on uninstall; remove
  them manually if desired.

## Worker integration

Each project's Worker does three things: resolve an **engine pin** to a real
tag of this repo's `install.sh` (never `@main`, so a bad push here can't break
every project's install at once), fetch that project's `install.config.json`,
and concatenate them with the config flattened into `CFG_*` exports ahead of
the engine body.

The pin can take three forms, in increasing order of auto-update convenience
and decreasing order of safety:

| Pin | Resolves to | Extra API call |
|---|---|---|
| `v1.1.0` (exact tag) | exactly that tag, always | no |
| `v1` (bare major) | the latest `v1.x.x` tag | yes, on every request |
| `latest` | GitHub's newest release overall, including majors | yes, on every request |

A bare major auto-picks up patches/minors (bug fixes, new optional config
fields) without anyone touching the Worker, but never jumps to a breaking
major — the same convention as GitHub Actions' `@v4`-style tags. This only
holds if mget's own SemVer discipline (major = breaking, minor = new
capability, patch = fix) is actually followed; the `cfg-interface-diff` CI
check (below) catches the most common accidental-breaking-change shape for
this discipline. `latest` has no such guardrail — a bad `mget` release
reaches every consumer pinned to `latest` immediately, no review step. Prefer
`v1` over `latest` unless you specifically want full auto-update over safety.
The two API-resolved forms add a third fetch (GitHub tags/releases API) on
top of the two the Worker already makes, subject to the same 60 req/hour/IP
limit noted above.

## CI

Every push runs syntax checks (`dash -n`, `bash --posix -n`, `shellcheck`)
and `cfg-interface-diff`, which compares the set of `CFG_*` variables the
script reads against the last tagged release and fails if any disappeared —
the most common accidental-breaking-change shape for a config-driven script
like this one. Tag pushes additionally run full install+uninstall integration
tests against modrex's real release: one forcing the AppImage path, one
exercising the native `.deb`/apt-get path (Ubuntu runners have `apt-get`
natively, so this needs no forcing), and one exercising the native `.rpm`/dnf
path inside a Fedora container (no GitHub-hosted runner ships dnf/rpm
natively). None of this proves a change is *intentionally* non-breaking —
that's still a human call when deciding the version bump — but it catches
accidental regressions before a tag becomes
eligible for `v1`/`latest` auto-pickup.

**Every flattened value must be a properly quoted shell literal.** The engine
removed `eval` from its own path handling, but that only protects against
config data being *reinterpreted* as shell — it does nothing if the Worker
itself emits an unescaped value into the script it generates. Naively
interpolating `CFG_X='${value}'` breaks (and is injectable) the moment
`value` contains a single quote. Use single-quote escaping like:

```js
function shellQuote(value) {
  return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

// preferred_variant is a nested object in the config but a flat
// "os:variant os:variant" string in the engine's CFG_PREFERRED_VARIANT —
// flatten it explicitly, don't pass the object straight through
// (Object.entries + template-literal stringification silently produces
// the literal text "[object Object]").
const flatConfig = {
  schema_version: config.schema_version,
  project_name: config.project_name,
  github_repo: config.github_repo ?? "",
  manifest_url: config.manifest_url,
  pubkey: config.pubkey ?? "",
  preferred_variant: Object.entries(config.preferred_variant ?? {})
    .map(([os, variant]) => `${os}:${variant}`)
    .join(" "),
  macos_bundle_name: config.macos_bundle_name ?? "",
  macos_executable_name: config.macos_executable_name ?? "",
  deb_package_name: config.deb_package_name ?? "",
  rpm_package_name: config.rpm_package_name ?? "",
  install_dir: config.install_dir,
  add_to_path: config.add_to_path ?? true,
  post_install_cmd: config.post_install_cmd ?? "",
  uninstall_manifest: config.uninstall_manifest ?? "",
  install_url: config.install_url ?? "",
};

const prelude = Object.entries(flatConfig)
  .map(([key, value]) => `CFG_${key.toUpperCase()}=${shellQuote(value)}`)
  .join("\n");
```

## Usage

```
curl -fsSL <project-install-url> | sh
curl -fsSL <project-install-url> | sh -s -- --dry-run
curl -fsSL <project-install-url> | sh -s -- --uninstall
curl -fsSL <project-install-url> | sh -s -- --uninstall --purge
curl -fsSL <project-install-url> | sh -s -- --uninstall -y
```

`--purge` (uninstall only) additionally removes `$HOME/.config/{project_name}`,
`$HOME/.cache/{project_name}`, and `$HOME/.local/share/{project_name}` — the
default uninstall only removes what mget itself installed, leaving user
settings/cache/data in place. `-y`/`--yes` skips the confirmation prompt
uninstall otherwise asks (reads from `/dev/tty` directly, since stdin is the
piped script source in the normal `curl | sh` invocation — without `-y` in a
non-interactive shell with no controlling terminal, it refuses rather than
guessing).

A successful install prints a launch hint and, when the project sets
`install_url` in its config, an accurate copy-pasteable uninstall command.

Uninstall reads the state file written during install (`uninstall_manifest`,
per-project). It validates that file records this same `project_name` and
`install_dir` before touching anything, then removes each recorded path
exactly (never a manifest path outside `install_dir`, the project's exact
macOS bundle, or its own desktop entry/icon — any mismatch is a hard error,
not a silently-skipped no-op) or, for `.deb`/`.rpm` installs, invokes the
same package manager used to install it, restricted to the configured
`deb_package_name`/`rpm_package_name` (defaulting to `project_name`).
Requires the same `install.config.json` that was used to install — if that
config disappears, or changes `project_name`, `install_dir`,
`macos_bundle_name`, `deb_package_name`, or `rpm_package_name`, uninstall may
refuse to proceed rather than guess.

## Local testing

The script also runs standalone by exporting `CFG_*` vars directly:

```sh
CFG_SCHEMA_VERSION=1 \
CFG_PROJECT_NAME=modrex \
CFG_GITHUB_REPO=modrexio/modrex \
CFG_MANIFEST_URL=https://github.com/modrexio/modrex/releases/latest/download/latest.json \
CFG_INSTALL_DIR='$HOME/.local/bin' \
sh install.sh --dry-run
```
