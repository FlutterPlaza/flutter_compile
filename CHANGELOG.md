# CHANGE LOG

## Unreleased

- `fcp codepush patch` now warns when the target iOS release was built without widget guarding or without the interface freeze; `--allow-unguarded-release` acknowledges and silences it. Releases created by older versions are not affected.
  - **Behavior change:** invalid `--rollout` values (for example `50%` or `fifty`), unrecognized or empty `--platform` values (on both `release` and `patch` — any casing of the six documented values is now accepted and normalized), and an empty `--signing-key` are now rejected up front instead of being silently misread; argument mistakes are reported before any build work runs. An iOS release uploaded via `--snapshot` now requires `--baseline-id` or `--allow-missing-baseline` regardless of how `--platform ios` is cased.

- Fixed an issue where simple iOS patches (for example, a patch whose body is a single logging call) could crash or misbehave at run time.
- Patches can now declare new `StatelessWidget` / `StatefulWidget` / `State` subclasses — for example, a patch that adds a new screen. The capability is applied at release build time: apps already in the field need one fresh `fcp codepush release --build` to benefit.
  - The preparation adds a small dispatch cost on the widget base classes; `--no-extendable-widgets` opts a release out of it (patches that add new screens will fail on such a release).
  - **Behavior change:** if the build unexpectedly cannot apply this preparation, `fcp codepush release --build` for iOS now fails with guidance instead of continuing silently.
  - When the app's set of Dart libraries changes between releases (or the widget-guarding option is toggled), the next iOS release build compiles from scratch instead of incrementally; unchanged apps keep reusing the previous compile, and `flutter clean` reclaims old build directories.
  - The local per-release archive now also stores the interface files the build used, and its `manifest.json` is format version 2: new keys record what the release build included. Keys absent in older v1 manifests mean unknown, not false; within v2, `has_interface_report` can also be `null`, meaning the build reused an unchanged compile.

- iOS releases now upload the app binary that devices verify against; very large apps no longer fail the upload.
- **Behavior change:** `fcp codepush release` for iOS now requires a baseline identity. `--build` stamps one automatically; when releasing a pre-built app, pass `--baseline-id` (it is read from the built app automatically when available), or opt out with `--allow-missing-baseline`. Releases without an identity are never delivered to devices, so the command now fails fast instead of creating one silently. In projects with both `android/` and `ios/`, `fcp codepush release` now asks for `--platform` whenever neither `--platform` nor `--build` is given — including `--snapshot` releases, whose platform determines which checks apply.
- Fixed device installs being rejected after the build-time engine check repairs the built app: the repair now re-signs what it touched.

## 0.19.15-rc.11

- `fcp codepush versions` and `fcp codepush setup` now show and check code push support per platform, so a Flutter version can be supported for Android and iOS independently.

## 0.19.15-rc.10

- Fix: `fcp codepush release --build` and `fcp codepush patch --build` now verify the built Android app before continuing, and fail with a clear error if it is not code-push capable.

## 0.19.15-rc.9

- Fix: Android apps now pick up code push configuration changes shipped in an app update. Re-run `fcp codepush init` in existing projects to apply. If you integrated the copy step into a custom `Application` class manually, remove the exists-check around the copy so it runs on every launch.
- Feature: `fcp codepush release --build` on Android now writes the release version into the app's code push configuration before building, so installed patches are cleanly discarded after an app store update.

## 0.19.15-rc.8

- Fix: `fcp codepush setup --force` now always refreshes engine artifacts instead of reusing a stale local cache.

## 0.19.15-rc.7

- Feature: `fcp codepush release --build` now writes a distribution-proof baseline identity into `ios/Runner/Info.plist` before building. This UUID survives App Store processing (App Thinning, re-signing, encryption) — unlike the binary hash which Apple's processing invalidates. TestFlight and App Store devices now receive patches correctly.
- Pairs with `flutterplaza_code_push 0.1.11-rc.4` (reads the UUID on device) and a server update deployed alongside.

## 0.19.15-rc.6

- Fix: `fcp codepush patch --build` now uses the release's stored baseline identity from the server instead of computing it locally.

## 0.19.15-rc.5

- `fcp codepush login` now prints the authorization URL in the terminal so you can open it in a specific browser.

## 0.19.15-rc.4

- Fix: `fcp codepush release --build` on larger iOS apps no longer fails with `HTTP 413`. The release upload now uses the same compact transport the patch upload already uses. Requires a server with the matching handler — the production service was updated alongside this release.

## 0.19.15-rc.3

- `fcp codepush setup` now completes the install on iOS. Fresh setups work end to end; on existing machines, re-run `fcp codepush setup --force`.
- Fixes a "No host specified in URI" crash on clean installs.
- Note: running `flutter precache --ios` or `flutter upgrade` after setup resets your Flutter install. Re-run `fcp codepush setup --force` afterwards.

## 0.19.15-rc.2

- **Retracted.** Use 0.19.15-rc.3 or later.

## 0.19.15-rc.1

- **Retracted.** Use 0.19.15-rc.3 or later.

## 0.19.14

- Fix: iOS patches built via `fcp codepush patch --build` now ship in the correct format. Earlier 0.19.x releases produced a format iOS couldn't load.
- Fix: the update-available banner no longer appears when your local CLI is newer than the latest pub.dev version.
- Pairs with `flutterplaza_code_push 0.1.10`.

## 0.19.13

- Fix: iOS patch build pipeline corrected. Older releases produced patches the device couldn't load.
- Pairs with `flutterplaza_code_push 0.1.9`.

## 0.19.12

- Fix: `fcp codepush patch --build` upload no longer fails on larger iOS patches. Uploads are now gzipped with metadata in the query string.
- Fix: server error responses surface a structured message instead of a JSON parse error.

## 0.19.11

- Fix: iOS patch pipeline now packages the correct artifact. Earlier releases produced a file the device couldn't load.
- Pre-upload format guard rejects wrong-format payloads with an actionable error.
- Pairs with `flutterplaza_code_push 0.1.8`.

## 0.19.10

- Feat: `fcp codepush patch --build` computes a baseline content hash and sends it with the upload so the SDK can refuse patches that don't match the device's running binary. Prevents a crash-loop on baseline drift.

## 0.19.9

- Docs: adds a Signing & Migration section to the shipped documentation.

## 0.19.8

- **Security**: end-to-end patch signing with a migration path for existing apps.
  - New subcommand group `fcp codepush keys` with `generate` and `register` actions.
  - `fcp codepush init` now creates and registers a signing keypair automatically.
  - `fcp codepush patch` sends a signature with every upload.
- A migration banner nudges users on legacy unsigned apps to run `fcp codepush keys register`.

### 🛠 Migration guide for existing users

**Pre-0.15.0 users** (apps created before auto-keygen existed):
```
fcp codepush keys generate      # generate local keypair
fcp codepush keys register      # upload public key to server for your app
fcp codepush patch --build ...  # signed from here on; server verifies
```

**0.15.0–0.19.7 users** (apps created with auto-keygen but no server registration):
```
fcp codepush keys register      # local key already exists, just upload it
```

**0.19.8+ new installs**: no migration needed — `fcp codepush init` registers the public key automatically.

**What happens if you do nothing?** Existing unsigned patches keep working. The server logs a warning per upload and the CLI prints a migration banner. Future releases will eventually remove the grandfather path.

## 0.19.7

- Fix: `fcp codepush patch --build` and `fcp codepush release --build` no longer fail at the finalize step. Adds a `--flutter-version` flag on `patch` to match `release`.

## 0.19.6

- Fix: `flutter_compile update` could report "already at the latest version" while a newer release was live. Version checks now bust the pub.dev cache.

## 0.19.5

- Fix: `fcp codepush patch --build` and `release --build` now print detailed diagnostics on finalize failures instead of the bare "Finalization failed" message.

## 0.19.4

- Fix: `fcp codepush login` honors the server URL stored in `~/.flutter_compilerc` instead of falling back to localhost.

## 0.19.3

- Fix: `fcp --version` now reports the actual installed version.

## 0.19.2

- Fix: remove the inaccurate "requires paid subscription" claim from docs and help text. Free tier supports `release` and `patch`.
- Fix: HTTP 403 errors now surface the server's actual message.

## 0.19.1

- Docs: add a Code Push section to the README.
- Chore: formatting cleanup.

## 0.19.0

- Security: patch signing is enforced by default — pass `--unsigned` to bypass.
- Security: source uploads use RSA+AES hybrid encryption.
- Security: `fcp codepush init` writes the public key to `Info.plist`.
- Feat: `fcp codepush init` generates native setup automatically; flavored apps get manual integration instructions.
- Feat: `fcp codepush release --build` and `patch --build` produce release-ready artifacts end to end.
- Feat: Flutter SDK version auto-detected and sent with the release upload.
- Feat: `fcp codepush versions --json`, `account --json`, `status --json` (with `--release-id` filter).
- Chore: remove experimental commands from the public CLI.

## 0.18.0

- Fix: `fcp codepush patch --build` now uses `flutter build` internally for correct type resolution.
- Feat: `--platform` flag on `fcp codepush patch`.
- Feat: `appbundle` added as a supported Android platform.

## 0.17.0

- Feat: `fcp codepush register` — browser OAuth flow, auto-creates an account (alias for login).
- Feat: `fcp switch` now copies the Dart SDK to the contribution repo.
- Feat: budget alerts UI in the Console settings.
- Feat: `--api-key` fallback on `register` and `login` for headless/CI use.

## 0.16.0

- Feat: `fcp codepush login` — browser-based authentication.
- Feat: `fcp codepush apps list` / `apps create`.
- Feat: `fcp codepush billing usage` — view plan, installs, and usage percentage.
- Test: expanded test coverage for codepush subcommands.

## 0.15.0

- Feat: `fcp codepush init` now generates an RSA signing keypair automatically.
- Feat: `fcp codepush patch` auto-detects the stored signing key — patches are signed by default.
- Feat: warning displayed when patching without a signing key.
- Security: signing is now the default workflow, not opt-in.

## 0.14.0

- Feat: `fcp codepush patch --channel beta|production` for safer rollouts.
- Feat: `fcp codepush setup` ensures the Dart SDK is available in the contribution Flutter repo.
- Fix: `fcp codepush release --build` no longer reports failure after a successful build.
- Fix: improved APK snapshot path detection for different Gradle layouts.
- Fix: clearer error messages for missing tools.

## 0.13.0

- Feat: multi-platform engine artifact support — Android, iOS, macOS, Linux, Windows.
- Feat: platform-specific build artifact resolution for code push.
- Fix: analyzer and formatter cleanups.

## 0.12.0

- Feat: `FLUTTER_COMPILE_SDK` environment variable — IDE terminals now use the project-pinned SDK instead of always falling back to the global default.
- Feat: shell env file is now conditional — defers to the IDE-provided SDK path when set, uses the global default otherwise.
- Feat: VS Code extension and IntelliJ plugin set `FLUTTER_COMPILE_SDK` so project-pinned SDKs survive shell init.
- Feat: auto-migration on extension/plugin activation; `migrate` command for CLI users.
- Fix: SDK validation checks for `bin/flutter` so SDKs installed from release archives work correctly.
- Fix: whitespace-tolerant SDK path resolution.
- Fix: `sdk global`, `sdk use`, and `sdk remove` trim version names and use resolved paths.
- Feat: VS Code and IntelliJ extensions v0.3.1.

## 0.11.1

- Fix: switch CI to GitHub-hosted runners.
- Deps: upgrade `json_rpc_2` and `lints`.

## 0.11.0

- Feat: engine now builds from within the Flutter contributor checkout.
- Feat: `install engine` requires `install flutter` first — engine lives inside the Flutter checkout.
- Feat: `--force` flag on `install engine` and `sync engine`.
- Feat: `build engine` prepends `depot_tools` to PATH automatically.
- Feat: `install flutter --ide vscode|intellij` flag.
- Feat: `doctor` probes known `depot_tools` locations beyond PATH.
- Fix: idempotent git remote setup in install commands (safe to re-run).
- Fix: `install devtools` saves path to rc config before modifying shell config.
- Feat: VS Code extension v0.3.0 — dual SDK backend (Native + FVM), SDK Manager toggle, doctor install actions.
- Feat: IntelliJ plugin v0.3.0 — mode dropdown for Native vs FVM backend, enhanced CLI integration.

## 0.10.1

- Fix: rc config parsing now supports Windows drive-letter paths.
- Fix: file watcher path matching handles Windows backslash separators.
- Fix: test isolation improvements for `sdk exec` and `sdk global`.
- Chore: `.gitignore` cleanups.

## 0.10.0

- Feat: `daemon` command — JSON-RPC 2.0 daemon for real-time IDE communication over stdin/stdout.
- Feat: daemon supports SDK list/get/set, doctor, config, status, version, and shutdown methods, with change notifications.
- Feat: `ui` command — interactive terminal UI dashboard for SDK management.
- Feat: file watcher with 500 ms debounce for `.flutter_compilerc` and `.flutter-version` changes.
- Feat: VS Code extension MVP — status bar SDK version, quick pick switcher, install/switch/doctor commands.
- Feat: Android Studio / IntelliJ plugin MVP — toolbar combo box SDK switcher, tool window with SDK list and doctor output.
- Feat: `--force` on `sdk install`, partial/corrupt clone detection, `TempHome` test helper.
- Feat: idempotent PATH management across `switch`, `uninstall`, and `sdk global`.
- Test: expanded behavioral test coverage.
- CI: matrix strategy across Ubuntu, Windows, macOS.

## 0.9.0

- Feat: `sync` command (`sync flutter`, `sync engine`, `sync devtools`) with `sy` alias.
- Feat: `fcp` executable alias — `fcp` works everywhere `flutter_compile` does.
- Feat: `--json` flag on `sdk list`, `doctor`, `config list`, and `status`.
- Feat: Windows support — cross-platform PATH management, shell config detection, host architecture resolution.
- Feat: `doctor` checks for Visual Studio on Windows.
- Feat: `install flutter` and `install engine` accept Windows as a supported platform.

## 0.8.0

- Feat: `sdk exec` — run commands through the resolved SDK (project `.flutter-version` → global default).
- Feat: `sdk install` auto-sets the global default when installing the first SDK.
- Feat: `sdk remove` can remove the global SDK and cleans up rc config and shell PATH block.

## 0.7.0

- Feat: `sdk global` — set or show the global default Flutter SDK version.
- Feat: `sdk use` — pin a Flutter SDK version per project (`.flutter-version`).
- Feat: `PUB_CACHE` isolation per installed SDK.
- Feat: `sdk list` annotates entries with `(global)` and `(project)` markers.
- Feat: `sdk remove` guards against removing the global default or project-pinned SDK.

## 0.6.0

- Feat: `sdk` command group — install and manage multiple Flutter SDK versions (`sdk install`, `sdk list`, `sdk remove`).
- Feat: `dr` alias for `doctor`, `up` alias for `update`.
- Refactor: centralized exception handling in the command runner.
- Fix: rename `uninstall devtool` → `uninstall devtools` (old name kept as alias).

## 0.5.1

- Chore: upgrade `mason_logger` and `pub_updater`.

## 0.5.0

- Feat: `clean` command — remove engine build output directories (alias: `c`).
- Feat: `config` command — view and modify `.flutter_compilerc` from the CLI (alias: `cf`).
- Fix: `uninstall flutter` removes PATH exports and cleans `.flutter_compilerc`.

## 0.4.0

- Feat: `test` command — run Flutter tests with a local engine build (`--local-engine`).
- Feat: `status` command — show engine configuration and available builds.
- Feat: `t` and `st` aliases.

## 0.3.1

- CI: add code coverage reporting and Codecov integration.
- Docs: update README badges.

## 0.3.0

- Feat: `run` command — launch Flutter apps with a local engine build (`--local-engine`).
- Feat: `--gn` / `--no-gn` flags on `build engine` for incremental rebuilds.
- Feat: `r` alias for `run`.

## 0.2.0

- Feat: automate Flutter engine setup (`install engine`) — depot_tools, gclient sync, git remotes.
- Feat: `build engine` command with platform-aware flag resolution.
- Feat: support for all platforms — android, ios, macos, linux, web, host.
- Feat: extend `doctor` with depot_tools, ninja, Xcode, and engine environment checks.
- Feat: `uninstall engine` with optional depot_tools cleanup.

## 0.1.0

- Feat: `doctor` command — environment health checks.
- Feat: `uninstall devtool` with PATH and config cleanup.
- Fix: bug fixes and dead code cleanup.

## 0.0.3

- Fix: minor cleanups.

## 0.0.2+2

- Fix: version index.
- Chore: update.

## 0.0.2+1

- Fix: tests.

## 0.0.2

- Fix: broken links.

## 0.0.1

- Initial release.
