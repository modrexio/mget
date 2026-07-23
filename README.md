# mget

[![Latest Tag](https://img.shields.io/github/v/tag/modrexio/mget?style=flat-square&label=version)](https://github.com/modrexio/mget/tags)
[![CI](https://img.shields.io/github/actions/workflow/status/modrexio/mget/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/modrexio/mget/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/modrexio/mget?style=flat-square)](LICENSE)

Shared install engine for the Modrex ecosystem — one script, reused by any number of
projects. Each project supplies its own config and gets its own short install URL.

```sh
curl -fsSL https://modrex.net/install.sh | sh
```

Supports **Linux and macOS only**. Windows users install via the `.exe`/`.msi` release
asset directly.

### Requirements

- `curl` and `jq` — always
- `minisign` and `base64` — only when the project configures `pubkey`
- `dpkg-deb`/`rpm` — to inspect `.deb`/`.rpm` packages before installing
- `tar` — for macOS `.app.tar.gz` installs
- `sudo` and the relevant package manager (apt/dnf/zypper, or `dpkg`/`rpm` directly) —
  for native package installs

## How it works

1. **The engine** (`install.sh`, this repo) knows nothing about any specific project.

   - It reads the project's Tauri updater manifest to pick the right platform asset, or
     looks up a `.deb`/`.rpm` on the GitHub Releases API directly — no exact filename
     needs to be configured anywhere.
   - On Linux it prefers a native package manager (apt/dnf/zypper) over a plain
     AppImage, so updates keep flowing through the system package manager.
   - On macOS it preserves valid app signatures and refuses bundles with broken
     signatures. An unsigned bundle receives a local ad-hoc signature before install,
     which satisfies macOS code-integrity checks without an Apple Developer account.
     Ad-hoc signing does not identify the publisher or notarize the app, so macOS may
     still require one-time approval in **System Settings > Privacy & Security**.
   - When a release ships more than one package of the same format, it prefers a
     filename mentioning this machine's architecture (`amd64`/`x86_64`/`arm64`/etc.),
     then double-checks the chosen package's own embedded architecture metadata before
     installing. That catches a wrong-arch pick even if the filename guess missed.
   - It falls back to the AppImage only when no `.deb`/`.rpm` is found at all — not when
     a chosen candidate later fails validation.
   - Before installing a `.deb`/`.rpm`, it reads the package's own name, architecture,
     and version metadata rather than trusting the GitHub asset list blindly. This is
     also what makes uninstall safe: it records the real package identifier, and
     refuses to later remove anything else — even if the uninstall record itself is
     modified.
   - It registers a `.desktop`/icon entry for AppImage installs.

2. **Each project** (`modrex`, `Refract_MC`, ...) keeps an `install.config.json` in its
   own repo — see the schema below.

3. **Each project's Worker** resolves an engine tag, fetches that project's config, and
   streams the combined script to `curl | sh`. See [Worker integration](#worker-integration).

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
|---|:---:|---|
| `schema_version` | ![yes](https://img.shields.io/badge/Yes-brightgreen) | Must currently be `1` — the engine hard-errors on anything else |
| `project_name` | ![yes](https://img.shields.io/badge/Yes-brightgreen) | Used for binary naming, default install/uninstall paths, and log messages. Letters, digits, `.`, `_`, `-` only, and cannot be exactly `.` or `..` — it ends up directly in filesystem paths |
| `github_repo` | ![no](https://img.shields.io/badge/No-red) | `owner/repo`. Used to look up `.deb`/`.rpm` assets via the GitHub Releases API when apt/dnf/zypper is detected — without it, Linux package-manager users fall back to the AppImage |
| `manifest_url` | ![yes](https://img.shields.io/badge/Yes-brightgreen) | Tauri updater manifest URL, normally the `/releases/latest/download/latest.json` alias. Must be `https://` |
| `pubkey` | ![no](https://img.shields.io/badge/No-red) | The raw minisign public key string (starts with `RW...`), *not* the value stored directly in `tauri.conf.json`'s `plugins.updater.pubkey` — that field is itself base64-encoded content of a full minisign pubkey file (comment line + key line). Decode it once (`echo "$TAURI_PUBKEY" \| base64 -d`) and take only the second line. Once set, the engine requires `minisign` and a valid signature — it refuses to install rather than silently skip verification. Leave unset until the project has real signing configured |
| `preferred_variant` | ![no](https://img.shields.io/badge/No-red) | Per-OS suffix to prefer when the manifest has multiple platform-key variants for the same OS/arch (e.g. `linux-x86_64-deb` vs `linux-x86_64-appimage`). Takes priority over `.deb`/`.rpm` discovery via `github_repo` |
| `macos_bundle_name` | ![no](https://img.shields.io/badge/No-red) | The `.app` bundle's actual name (e.g. `Modrex`, not `modrex`) if it differs from `project_name`. Defaults to `project_name`. Uninstall only ever removes `$HOME/Applications/{macos_bundle_name}.app` exactly — never a wildcard — so this must match the real bundle name or uninstall won't find it |
| `macos_executable_name` | ![no](https://img.shields.io/badge/No-red) | The name of the actual executable inside `Contents/MacOS/` in the `.app` bundle, if it differs from `project_name`. Defaults to `project_name`. Install fails with a clear error if it's wrong, rather than creating a symlink to a file that doesn't exist |
| `deb_package_name`, `rpm_package_name` | ![no](https://img.shields.io/badge/No-red) | The real `Package`/`Name` identifier inside the built `.deb`/`.rpm`, if it differs from `project_name`. Defaults to `project_name`. See [why these exist](#why-deb_package_name-and-rpm_package_name-exist) below |
| `install_dir` | ![yes](https://img.shields.io/badge/Yes-brightgreen) | Must be an absolute path or start with the literal string `$HOME/`, e.g. `$HOME/.local/bin`. Restricted to `A-Za-z0-9_./+-` — see [why the character set is restricted](#why-install_dir-is-character-restricted) below |
| `add_to_path` | ![no](https://img.shields.io/badge/No-red) | Default `true`. Never applied after a `.deb`/`.rpm` install, since the package manager already puts the binary on the system `PATH` |
| `post_install_cmd` | ![no](https://img.shields.io/badge/No-red) | A trusted shell command run via `sh -c` after install; a non-zero exit is a warning, not fatal. This is executable code, not data — only trusted project maintainers should set it, same trust level as the project's build pipeline or signing key |
| `uninstall_manifest` | ![no](https://img.shields.io/badge/No-red) | Defaults to `$HOME/.{project_name}/uninstall.json`. Same `$HOME/...`-or-absolute-path rule as `install_dir`, but *does* allow colons — this path is never inserted into `PATH` |
| `install_url` | ![no](https://img.shields.io/badge/No-red) | The project's own public install URL (e.g. `https://modrex.net/install.sh`). Used only to print an accurate `curl \| sh -s -- --uninstall` hint after a successful install. Without it, the hint falls back to `sh $0 --uninstall`, which only makes sense when run from a local file, not piped from curl |

<a name="why-deb_package_name-and-rpm_package_name-exist"></a>
<details>
<summary><b>Why <code>deb_package_name</code> and <code>rpm_package_name</code> exist</b></summary>

Debian Policy hard-requires lowercase and forbids underscores in package names
(enforced by the tooling, not just a convention) — a `project_name` like `Refract_MC`
can never literally equal its own `.deb` package name. RPM/Fedora naming is a softer,
non-enforced convention but can still diverge.

Install verifies the downloaded package's own metadata matches this value before
installing. Uninstall will only ever remove a package with this exact name — even if
the uninstall record is modified, this bounds it to at most this specific package, not
an arbitrary one.

</details>

<a name="why-install_dir-is-character-restricted"></a>
<details>
<summary><b>Why <code>install_dir</code> is character-restricted</b></summary>

No spaces, no shell metacharacters, and notably no colon:

- This value is inserted directly into `PATH`. An embedded `:` would silently create a
  second, non-absolute (hijackable) `PATH` entry.
- It's also written into a line appended to the user's shell rc file. An unrestricted
  value could otherwise plant a `$(...)` command that runs the next time they open a
  shell.

Config is never `eval`'d — only `$HOME/...` and absolute paths are accepted.

</details>

## Known limitations

- `.deb`/`.rpm` installs, discovered via the GitHub Releases API, are never
  signature-verified — those assets aren't part of the signed Tauri updater manifest,
  so mget doesn't currently consume any separate integrity metadata (hash or detached
  signature) for them. Only the
  manifest-sourced asset (normally the AppImage) gets minisign verification when a
  project configures `pubkey`. The downloaded package's architecture/name metadata *is*
  checked before install — that catches a wrong-architecture asset and rejects packages
  whose metadata can't be read, but it's not the same guarantee as verifying it's the
  artifact the maintainer actually intended to release.
- The GitHub Releases API is unauthenticated and rate-limited to 60 requests/hour per
  IP — fine for individual installs, but worth knowing.
- PATH entries added to a shell rc file are left behind on uninstall; remove them
  manually if desired.

## Worker integration

Each project's Worker does three things:

1. Resolve an **engine pin** to a real tag of this repo's `install.sh` (never `@main`,
   so a bad push here can't break every project's install at once).
2. Fetch that project's `install.config.json`.
3. Concatenate them, with the config flattened into `CFG_*` exports ahead of the engine
   body, and stream the result to `curl | sh`.

### Engine pin modes

The pin can take three forms, in increasing order of auto-update convenience and
decreasing order of safety:

| Pin | Resolves to | Extra API call |
|---|---|:---:|
| `v1.1.0` (exact tag) | exactly that tag, always | ![no](https://img.shields.io/badge/No-red) |
| `v1` (bare major) | the latest `v1.x.x` tag | ![yes](https://img.shields.io/badge/Yes-brightgreen) |
| `latest` | GitHub's newest release overall, including majors | ![yes](https://img.shields.io/badge/Yes-brightgreen) |

A bare major auto-picks up patches/minors (bug fixes, new optional config fields)
without anyone touching the Worker, but never jumps to a breaking major — the same
convention as GitHub Actions' `@v4`-style tags. `latest` has no such guardrail: a bad
`mget` release reaches every consumer pinned to `latest` immediately, with no review
step. **Prefer `v1` over `latest`** unless full auto-update matters more than safety to
you.

This only holds if mget's own SemVer discipline (major = breaking, minor = new
capability, patch = fix) is actually followed — see [CI](#ci) for the automated check
that catches the most common way that discipline slips.

The two API-resolved forms add a third fetch (GitHub tags/releases API) on top of the
two the Worker already makes, subject to the same 60 req/hour/IP limit noted above.

### Quoting config values safely

**Every flattened value must be a properly quoted shell literal.** The engine removed
`eval` from its own path handling, but that only protects against config data being
*reinterpreted* as shell — it does nothing if the Worker itself emits an unescaped
value into the script it generates. Naively interpolating `` CFG_X='${value}' `` breaks
(and is injectable) the moment `value` contains a single quote.

Use single-quote escaping like this:

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

## CI

- **Every push** runs syntax checks (`dash -n`, `bash --posix -n`, `shellcheck`) and
  `cfg-interface-diff`, which compares the set of `CFG_*` variables the script reads
  against the last tagged release and fails if any disappeared — the most common
  accidental-breaking-change shape for a config-driven script like this one.
- **Tag pushes** additionally run full install+uninstall integration tests against
  modrex's real release:
  - one forcing the AppImage path
  - one exercising the native `.deb`/apt-get path (Ubuntu runners have `apt-get`
    natively, so this needs no forcing)
  - one exercising the native `.rpm`/dnf path inside a Fedora container (no
    GitHub-hosted runner ships dnf/rpm natively)

None of this proves a change is *intentionally* non-breaking — that's still a human
call when deciding the version bump — but it catches accidental regressions before a
tag becomes eligible for `v1`/`latest` auto-pickup.

## Usage

```
curl -fsSL <project-install-url> | sh
curl -fsSL <project-install-url> | sh -s -- --dry-run
curl -fsSL <project-install-url> | sh -s -- --uninstall
curl -fsSL <project-install-url> | sh -s -- --uninstall --purge
curl -fsSL <project-install-url> | sh -s -- --uninstall -y
```

- **`--purge`** (uninstall only) additionally removes `$HOME/.config/{project_name}`,
  `$HOME/.cache/{project_name}`, and `$HOME/.local/share/{project_name}`. The default
  uninstall only removes what mget itself installed, leaving user settings/cache/data
  in place.
- **`-y`/`--yes`** skips the confirmation prompt uninstall otherwise asks. That prompt
  reads from `/dev/tty` directly, since stdin is the piped script source in the normal
  `curl | sh` invocation — without `-y` in a non-interactive shell with no controlling
  terminal, it refuses rather than guessing.
- A successful install prints a launch hint and, when the project sets `install_url` in
  its config, an accurate copy-pasteable uninstall command.

### How uninstall stays safe

Uninstall reads the state file written during install (`uninstall_manifest`,
per-project) and validates it before touching anything:

- It must record this same `project_name` and `install_dir`.
- Every recorded path must exactly match what mget could have installed (never a path
  outside `install_dir`, the project's exact macOS bundle, or its own desktop
  entry/icon) — any mismatch is a hard error, not a silently-skipped no-op.
- For `.deb`/`.rpm` installs, removal is restricted to the configured
  `deb_package_name`/`rpm_package_name` (defaulting to `project_name`), via the same
  package manager used to install it.

Uninstall requires the same `install.config.json` that was used to install. If that
config disappears, or changes `project_name`, `install_dir`, `macos_bundle_name`,
`deb_package_name`, or `rpm_package_name`, uninstall may refuse to proceed rather than
guess.

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
