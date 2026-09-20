# Planned breaking changes

Changes deliberately deferred to the next major release because shipping them now would
break a consumer pinned to `v1`, a published consumer release, or an existing install.
They are executed together, in one major, under a single `schema_version` bump when
config semantics change. This is not a TODO list: an entry belongs here only if it
cannot ship in a `1.x` release.

Each entry records the current behaviour, why it is kept, the intended behaviour, what
gets removed, the migration, and the condition that makes it safe to execute.

## Remove `add_to_path`

- **Now:** read and ignored. The engine no longer edits shell startup files.
- **Kept because:** removing a `CFG_*` variable is this repository's definition of a
  breaking change (enforced by `cfg-interface-diff`); consumer configs may still carry
  the key.
- **Then:** the key is unknown to the engine and absent from the schema.
- **Removes:** one assignment in `install.sh`, one row in the README.
- **Migration:** consumers delete the key; nothing else changes.
- **Safe when:** the next major is cut.

## Remove `github_repo`

- **Now:** read and ignored. Native packages are taken from the manifest's
  `linux-{arch}-deb`/`-rpm` keys; the GitHub Releases API is never queried.
- **Kept because:** removing a `CFG_*` variable is a breaking change by this
  repository's rule, and both consumer configs still set the key.
- **Then:** the key is unknown to the engine and absent from the schema.
- **Removes:** one assignment in `install.sh`, one row in the README.
- **Migration:** consumers delete the key; nothing else changes.
- **Safe when:** the next major is cut.

## Remove `macos_executable_name`

- **Now:** optional override; the engine reads `CFBundleExecutable` from the bundle's
  `Info.plist` when it is unset.
- **Kept because:** same `cfg-interface-diff` rule, and Refract's published config sets
  it while the release it describes still ships an executable named differently from
  `command_name`.
- **Then:** the executable name comes only from the bundle.
- **Removes:** the override branch and its validation.
- **Migration:** consumers delete the key after their bundle's executable equals
  `command_name`.
- **Safe when:** no consumer config sets it.

## Refuse native packages that do not provide `/usr/bin/<command_name>`

- **Now:** the package is installed and the report states which executables it
  provides and that `command_name` is not among them. `tests/check-consumer.sh` and the
  reusable `consumer-check.yml` workflow enforce the invariant in CI instead.
- **Kept because:** a published consumer release (Refract 1.4.0) does not satisfy it;
  refusing at runtime would break its installs until a fixed release is `latest`.
- **Then:** the engine checks the package's file list before installing and fails with
  a message naming the missing executable.
- **Removes:** nothing; adds one pre-install check. Breaking because a consumer whose
  packaging regresses loses installs instead of getting a warning.
- **Migration:** none for users; consumers must run the packaging check in their release
  workflow.
- **Safe when:** every consumer's latest release passes `check-consumer.sh`.

## Replace the previous mget-owned install on an unattended format switch

- **Now:** installing a second format records both, warns, and reports which copy the
  current `PATH` runs; `--uninstall` removes all recorded installs. Nothing is removed
  during an install.
- **Kept because:** removing a package or file during `-y` that the previous release
  left in place changes what unattended installs delete.
- **Then:** `-y` removes the recorded install of the other format before installing, so
  a machine converges on one format without a separate `--uninstall`.
- **Removes:** the "both recorded" warning path.
- **Migration:** none; documented change to `-y`.
- **Safe when:** the uninstall path has run in CI across releases and a major is cut.

## `schema_version: 2`

- **Now:** the engine accepts only `1`; every field added since is optional and
  defaulted, so `1` covers all current configs.
- **Kept because:** bumping the version makes every older engine reject the config.
- **Then:** the version that removes the fields above; bootstraps forward every scalar
  key generically, so no bootstrap change is needed.
- **Removes:** the compatibility rows above in one step.
- **Migration:** consumers update `schema_version` and delete removed keys in the same
  commit as their bootstrap pin moves to the new major.
- **Safe when:** both consumers' bootstraps pin the new major.
