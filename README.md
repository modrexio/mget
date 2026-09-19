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
   - On Linux, when a native package manager (apt/dnf/zypper) is detected and both a
     native package (`.deb`/`.rpm`) and an AppImage are available, it asks which to
     install (native is the default) — so updates can keep flowing through the system
     package manager, without silently deciding that for the user. The prompt is skipped
     — defaulting to the native package — when `-y`/`--yes` is passed or no terminal is
     reachable (e.g. CI, a non-interactive `curl | sh`). Pass `--appimage`, `--deb`, or
     `--rpm` to pick a format up front and skip the prompt entirely.
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
   - It registers a `.desktop`/icon entry for AppImage installs, with an absolute
     `Exec` path, so the app launches from the menu regardless of `PATH`.
   - It never edits shell startup files. After installing it reports what was
     installed, where, and whether the command resolves in the current environment —
     see [Terminal command](#terminal-command).

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
  "command_name": "modrex",
  "github_repo": "modrexio/modrex",
  "manifest_url": "https://github.com/modrexio/modrex/releases/latest/download/latest.json",
  "pubkey": "RWTX2KsFhWADAjKhVxTe/CxS/HT+S3iMqrQorXSP/QUE20RjzISVRUbV",
  "preferred_variant": {
    "darwin": "app"
  },
  "macos_bundle_name": "Modrex",
  "deb_package_name": "modrex",
  "rpm_package_name": "modrex",
  "install_dir": "$HOME/.local/bin",
  "post_install_cmd": "$HOME/.local/bin/modrex --version",
  "uninstall_manifest": "$HOME/.modrex/uninstall.json",
  "install_url": "https://modrex.net/install.sh"
}
```

| Field | Required | Notes |
|---|:---:|---|
| `schema_version` | ![yes](https://img.shields.io/badge/Yes-brightgreen) | Must currently be `1` — the engine hard-errors on anything else |
| `project_name` | ![yes](https://img.shields.io/badge/Yes-brightgreen) | Used for default install/uninstall paths, desktop-entry and icon file names, and log messages. Letters, digits, `.`, `_`, `-` only, and cannot be exactly `.` or `..` — it ends up directly in filesystem paths |
| `command_name` | ![no](https://img.shields.io/badge/No-red) | The command users type in a terminal (`modrex`, `refract`). Defaults to `project_name`; same character rules. It names the AppImage/macOS symlink in `install_dir` and is what the engine looks up on `PATH` to report availability. Native packages must ship it as `/usr/bin/{command_name}` themselves — the engine reports what a package actually provides, it never renames or aliases |
| `github_repo` | ![no](https://img.shields.io/badge/No-red) | `owner/repo`. Used to look up `.deb`/`.rpm` assets via the GitHub Releases API when apt/dnf/zypper is detected — without it, Linux package-manager users fall back to the AppImage |
| `manifest_url` | ![yes](https://img.shields.io/badge/Yes-brightgreen) | Tauri updater manifest URL, normally the `/releases/latest/download/latest.json` alias. Must be `https://` |
| `pubkey` | ![no](https://img.shields.io/badge/No-red) | The raw minisign public key string (starts with `RW...`), *not* the value stored directly in `tauri.conf.json`'s `plugins.updater.pubkey` — that field is itself base64-encoded content of a full minisign pubkey file (comment line + key line). Decode it once (`echo "$TAURI_PUBKEY" \| base64 -d`) and take only the second line. Once set, the engine requires `minisign` and a valid signature — it refuses to install rather than silently skip verification. Leave unset until the project has real signing configured |
| `preferred_variant` | ![no](https://img.shields.io/badge/No-red) | Per-OS suffix to prefer when the manifest has multiple platform-key variants for the same OS/arch (e.g. `linux-x86_64-deb` vs `linux-x86_64-appimage`). Takes priority over `.deb`/`.rpm` discovery via `github_repo` |
| `macos_bundle_name` | ![no](https://img.shields.io/badge/No-red) | The `.app` bundle's actual name (e.g. `Modrex`, not `modrex`) if it differs from `project_name`. Defaults to `project_name`. Uninstall only ever removes `$HOME/Applications/{macos_bundle_name}.app` exactly — never a wildcard — so this must match the real bundle name or uninstall won't find it |
| `macos_executable_name` | ![no](https://img.shields.io/badge/No-red) | Override for the executable inside `Contents/MacOS/`. Normally unnecessary: the engine reads `CFBundleExecutable` from the bundle's `Info.plist`. Kept for configs written before that; slated for removal in the next major (see [docs/planned-breaking-changes.md](docs/planned-breaking-changes.md)) |
| `deb_package_name`, `rpm_package_name` | ![no](https://img.shields.io/badge/No-red) | The real `Package`/`Name` identifier inside the built `.deb`/`.rpm`, if it differs from `project_name`. Defaults to `project_name`. See [why these exist](#why-deb_package_name-and-rpm_package_name-exist) below |
| `install_dir` | ![yes](https://img.shields.io/badge/Yes-brightgreen) | Must be an absolute path or start with the literal string `$HOME/`, e.g. `$HOME/.local/bin`. Restricted to `A-Za-z0-9_./+-` — see [why the character set is restricted](#why-install_dir-is-character-restricted) below |
| `add_to_path` | ![no](https://img.shields.io/badge/No-red) | Deprecated. Accepted and ignored: the engine no longer edits shell startup files (see [Terminal command](#terminal-command)). Slated for removal in the next major |
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

No spaces, no shell metacharacters, and notably no colon: the value is printed back to
the user as part of a `PATH` suggestion and a `ln -s` command they may copy into their
shell. An unrestricted value could plant a `$(...)` command or split into a second,
non-absolute `PATH` entry.

Config is never `eval`'d — only `$HOME/...` and absolute paths are accepted.

</details>

## Terminal command

The engine does not detect the user's shell and does not edit `.profile`, `.bashrc`,
`.zshrc`, fish configuration, or any other startup file. No portable, root-free way
exists to put a user directory on the `PATH` of every future terminal: the XDG spec only
says distributions *should* add `~/.local/bin`, and they do so per shell and per distro
(Debian/Ubuntu: bash login shells, only once the directory exists; Fedora: bash and zsh;
Arch: not at all). Pretending otherwise produced installs that silently did not work.

Instead the engine reports observed facts after every install:

- native package (`.deb`/`.rpm`): the package name, version, manager, and the
  executables it actually placed in `/usr/bin`. If the package does not provide
  `command_name`, that is stated — the engine never renames or aliases anything;
  packaging is the project's job (see [Consumer packaging check](#consumer-packaging-check)).
- AppImage/macOS: the exact installed path (`{install_dir}/{command_name}`), then
  exactly one of:
  - `'{command_name}' is available in this terminal` — it resolves to the file just
    installed;
  - `'{command_name}' currently runs <other path>` — another copy shadows it;
  - `'{command_name}' is not on your PATH in this terminal` — followed by the options:
    launch from the application menu (the `.desktop` entry uses the absolute path), add
    `{install_dir}` to your own shell's `PATH`, or expose it system-wide with
    `sudo ln -s {install_dir}/{command_name} /usr/local/bin/{command_name}`.
    `/usr/local/bin` is on the default `PATH` of every distribution and macOS, for every
    shell and session type; `ln -s` fails rather than overwriting an existing file. The
    engine prints this command, it never runs it.
- any other `{command_name}` on the current `PATH`, tagged as recorded by this installer
  or not.

Nothing is claimed about future terminals, because nothing about them can be observed.

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
- Lines that earlier engine releases appended to shell rc files are left in place; they
  are harmless and no longer written.

## Worker integration

Each project's Worker does three things:

1. Resolve an **engine pin** to a real tag of this repo's `install.sh` (never `@main`,
   so a bad push here can't break every project's install at once).
2. Fetch that project's `install.config.json`.
3. Concatenate them, with the config flattened into `CFG_*` assignments ahead of the
   engine body, and stream the result to `curl | sh`.

The flattening is generic: every top-level key matching `^[a-z][a-z0-9_]*$` whose value
is a string, number, or boolean becomes `CFG_<KEY UPPERCASED>=<quoted value>`; booleans
become `true`/`false`; `preferred_variant` (an object) is flattened to space-separated
`os:variant` pairs; anything else is skipped. Keep no list of field names in the
bootstrap — the engine ignores `CFG_*` it does not know, so new optional fields work
the day the engine supports them, and old engines keep working with new configs.

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
that catches the most common way that discipline slips. Changes that are deliberately
held back for the next major are listed in
[docs/planned-breaking-changes.md](docs/planned-breaking-changes.md).

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

const prelude = Object.entries(config)
  .filter(([key]) => /^[a-z][a-z0-9_]*$/.test(key))
  .map(([key, value]) =>
    key === "preferred_variant" && value && typeof value === "object"
      ? [key, Object.entries(value).map(([os, v]) => `${os}:${v}`).join(" ")]
      : [key, value]
  )
  .filter(([, value]) => ["string", "number", "boolean"].includes(typeof value))
  .map(([key, value]) => `CFG_${key.toUpperCase()}=${shellQuote(value)}`)
  .join("\n");
```

A static-hosting bootstrap without a Worker can do the same with `jq` on the client
(`@sh` produces the single-quoted literal) and pipe the prelude plus the engine into
`sh -s -- "$@"`.

## CI

- **Every push** runs syntax checks (`dash -n`, `bash --posix -n`, `shellcheck`) and
  `cfg-interface-diff`, which compares the set of `CFG_*` variables the script reads
  against the last tagged release and fails if any disappeared — the most common
  accidental-breaking-change shape for a config-driven script like this one.
- **Every push** also runs `tests/run.sh` on Ubuntu (apt) and in a Fedora container
  (dnf), against the real modrex release and a pinned Refract release: it proves no
  shell startup file is ever modified, that availability/shadowing/leftover reporting
  matches the environment, that recorded installs accumulate and uninstall together,
  that manifests written by earlier releases still uninstall, that a package lacking
  `command_name` is reported rather than rejected, and that `sudo` is refused and
  `--dry-run` never prompts.
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

### Consumer packaging check

`tests/check-consumer.sh <owner/repo> <command_name> [tag]` downloads a release's
Linux and macOS artifacts and fails unless every `.deb`, `.rpm`, `.AppImage` and
`.app.tar.gz` contains the executable named `command_name`. mget's CI runs it against
each consumer's latest release; a consumer can run the same check in its own release
workflow:

```yaml
jobs:
  packaging:
    uses: modrexio/mget/.github/workflows/consumer-check.yml@main
    with:
      repo: ${{ github.repository }}
      command_name: refract
      tag: ${{ github.ref_name }}
```

## Usage

```
curl -fsSL <project-install-url> | sh
curl -fsSL <project-install-url> | sh -s -- --dry-run
curl -fsSL <project-install-url> | sh -s -- --appimage
curl -fsSL <project-install-url> | sh -s -- --deb
curl -fsSL <project-install-url> | sh -s -- --rpm
curl -fsSL <project-install-url> | sh -s -- --uninstall
curl -fsSL <project-install-url> | sh -s -- --uninstall --purge
curl -fsSL <project-install-url> | sh -s -- --uninstall -y
```

- **`--appimage`/`--deb`/`--rpm`** (install only) picks the asset format up front instead
  of auto-detecting and, when a native package is available, prompting. Only one may be
  given. `--deb`/`--rpm` still work even without apt/dnf/zypper detected, as long as
  `dpkg`/`rpm` is installed and the project's release actually publishes that format.
- **`--purge`** (uninstall only) additionally removes `$HOME/.config/{project_name}`,
  `$HOME/.cache/{project_name}`, and `$HOME/.local/share/{project_name}`. The default
  uninstall only removes what mget itself installed, leaving user settings/cache/data
  in place.
- Installing a second format (say the AppImage after the `.deb`) keeps both: the engine
  records every install it makes, warns that both exist and which one the current
  `PATH` runs, and removes all of them on `--uninstall`. It never removes a copy it did
  not install; after uninstalling it lists any `{command_name}` still on `PATH`, and a
  `/usr/local/bin/{command_name}` symlink left pointing at the removed file, with the
  command to remove it.
- Running the installer under `sudo` is refused before anything is downloaded: it would
  install into root's home. Run it as yourself; it asks for `sudo` only when a package
  manager needs it. A real root account (no `SUDO_USER`) is accepted.
- **`-y`/`--yes`** skips both the install-time native-vs-AppImage prompt (defaulting to
  the native package) and the uninstall confirmation prompt. Both prompts read from
  `/dev/tty` directly, since stdin is the piped script source in the normal `curl | sh`
  invocation. For uninstall specifically, `-y` is required in a non-interactive shell
  with no controlling terminal — it refuses rather than guessing; the install-time prompt
  instead just defaults to the native package in that case, so a plain `curl | sh` in a
  script or CI never hangs.
- `--dry-run` never prompts; it takes the native default where a prompt would appear.
- A successful install prints the [terminal command report](#terminal-command) and,
  when the project sets `install_url` in its config, an accurate copy-pasteable
  uninstall command.

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
- Entries whose target is already gone are skipped, not errors. Each install prunes
  such entries and merges its own, so the file always lists every mget-owned install
  that still exists.

Uninstall requires the same `install.config.json` that was used to install. If that
config disappears, or changes `project_name`, `command_name`, `install_dir`,
`macos_bundle_name`, `deb_package_name`, or `rpm_package_name`, uninstall may refuse to
proceed rather than guess.

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

`sh tests/run.sh` runs the behaviour tests (needs `jq`, `minisign`, network access,
and either apt with passwordless `sudo` or dnf as root; each case uses a throwaway
`HOME`). `TESTS="t_sudo_is_refused_before_network"` selects individual cases.
