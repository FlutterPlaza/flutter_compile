# CHANGE LOG

## 0.19.5

- fix: `fcp codepush patch --build` and `fcp codepush release --build` printed only `Finalization failed` with zero detail when the finalize step failed, even under `--verbose`. `CodePushBuildService.finalizeBuild` returned a bare `bool` and discarded the subprocess stderr, exit code, and command line — the caller had nothing to report. Introduces a `BuildStepResult` struct carrying `success`, `message`, `command`, `exitCode`, `stdout`, `stderr`, and a `formatDiagnostics()` helper that prints a multi-line dump (exit code, elided command, stderr, stdout) right after the progress line. Both `_codepush_patch.dart` and `_codepush_release.dart` now log these diagnostics on failure. The "tool not downloaded" precondition path now also returns an actionable message (`Run "fcp codepush setup" first to download it.`). Fixes #16.

## 0.19.4

- fix: `fcp codepush login` ignored the server URL stored in `~/.flutter_compilerc` and always tried to connect to the hardcoded dev default `http://localhost:8090`, so users saw a misleading `SocketException: Connection refused ... address = localhost, port = <random>` on every attempt (the random port is Dart's local ephemeral source port, not the destination). Root cause was `argParser.addOption('server', defaultsTo: ...)` which made the fallback unreachable. Now calls `CodePushClient.getServerUrl()` like every other codepush command. Fixes #15 (secondary symptom).

## 0.19.3

- fix: `lib/src/version.dart` had been frozen at `0.12.0` since the v0.12.0 release, so every published version from 0.12.0 → 0.19.2 reported the wrong version from `fcp --version` and made `fcp update` run a no-op activate on every invocation (never marking the CLI as up-to-date). Bumps the constant and replaces the hardcoded `ensure_build_test.dart` assertion with a dynamic pubspec-vs-version.dart comparison so future drift fails CI. Fixes #15.

## 0.19.2

- fix: drop the inaccurate "requires paid subscription" claim from the public README, from the `codepush` / `codepush release` / `codepush patch` command descriptions shown in `fcp --help`, and from the `docs/code-push.html` table. Free tier supports production `release` and `patch`; see [the pricing page](https://codepush.flutterplaza.com/#pricing) for plan limits.
- fix: `release` and `patch` HTTP 403 error handlers now surface the server's actual error message instead of hardcoding "Paid subscription required".

## 0.19.1

- docs: add a Code Push section to the README with a link to [codepush.flutterplaza.com/docs](https://codepush.flutterplaza.com/docs)
- chore: apply `dart format` to two files that tripped the `--set-exit-if-changed` CI check (pure whitespace, no behavior change)

## 0.19.0

- security: patch signing is now enforced by default — pass `--unsigned` to bypass
- security: source uploads to the compile endpoint use RSA+AES hybrid encryption; server public key cached in `.flutter_compilerc`
- security: `fcp codepush init` writes `FLTCodePushPublicKey` to `Info.plist`
- feat: `fcp codepush init` generates native setup automatically — `CodePushApp.kt`, `codepush.yaml`, `AndroidManifest.xml`, and `Info.plist`; flavored apps get manual integration instructions
- feat: `fcp codepush release --build` and `patch --build` now produce release-ready artifacts end to end (fixes #5)
- feat: build steps are delegated to a private `fcp-tool` binary that the CLI downloads on first use
- feat: Flutter SDK version auto-detected from `flutter --version --machine` (with plain-text fallback) and sent on `POST /api/v1/releases` — required for server-side patch compilation
- feat: `fcp codepush versions --json` — list supported/installed Flutter versions
- feat: `fcp codepush account --json` and `codepush status --json` now emit structured output (status supports `--release-id` filtering and `total_patches`)
- chore: remove internal implementation details from public code and docs
- chore: remove `fcp codepush seed-secrets` — moved to the private admin CLI

## 0.18.0

- fix: `fcp codepush patch --build` now uses `flutter build` instead of raw Dart kernel compiler — fixes dart:ui missing types
- feat: `fcp codepush patch --platform` flag to specify target platform
- feat: `appbundle` added as supported platform for Android App Bundle builds

## 0.17.0

- feat: `fcp codepush register` — browser OAuth flow, auto-creates account (alias for login)
- feat: `fcp switch` now copies Dart SDK to contribution repo (fixes broken download)
- feat: budget alerts UI in Console settings (threshold selector + save)
- feat: `--api-key` fallback on both register and login for headless/CI use

## 0.16.0

- feat: `fcp codepush login` — browser-based authentication (no API key in terminal)
- feat: `fcp codepush apps list` — list all apps on your account
- feat: `fcp codepush apps create` — create a new app from CLI
- feat: `fcp codepush billing usage` — view plan, installs, and usage percentage
- feat: 39 codepush subcommand tests (343 total)

## 0.15.0

- feat: `fcp codepush init` now generates RSA signing key pair automatically
- feat: `fcp codepush patch` auto-detects stored signing key — patches are signed by default
- feat: warning displayed when patching without a signing key
- security: signing is now the default workflow, not opt-in

## 0.14.0

- feat: `fcp codepush patch --channel beta|production` — deploy patches to specific channels for safer rollouts
- feat: `fcp codepush setup` now ensures the Dart SDK is available in the contribution Flutter repo, fixing the corrupt download issue
- fix: `fcp codepush release --build` no longer reports failure after a successful build
- fix: improved APK snapshot path detection for different Gradle output layouts
- fix: improved error messages for missing tools

## 0.13.0

- feat: `fcp codepush seed-secrets` command — push .env secrets into GCP Secret Manager for server deployment
- feat: multi-platform engine artifact support — Android, iOS, macOS, Linux, Windows build targets
- feat: platform-specific build artifact resolution for code push
- feat: cross-platform build artifact lookup with optional `platform` parameter
- fix: resolved all `dart analyze` errors
- fix: formatted all source files to pass `dart format` checks

## 0.12.0

- feat: `FLUTTER_COMPILE_SDK` environment variable — IDE terminals now use the project-pinned SDK instead of always falling back to the global default
- feat: shell env file (`~/.flutter_compile_env`) SDK block is now conditional: defers to IDE-provided SDK path when set, uses global default in regular terminals
- feat: VS Code extension sets `FLUTTER_COMPILE_SDK` + `applyAtShellIntegration` so project-pinned SDKs survive shell init
- feat: IntelliJ plugin sets `FLUTTER_COMPILE_SDK` via `LocalTerminalCustomizer` for the same behavior
- feat: auto-migration on extension/plugin activation — rewrites old env file SDK blocks with the new guarded template
- feat: `migrate` command rewrites SDK blocks with `FLUTTER_COMPILE_SDK` guard for existing CLI users
- fix: SDK validation now checks for `bin/flutter` instead of `.git/HEAD`, so SDKs installed from release archives (no `.git`) work correctly
- fix: whitespace-tolerant SDK path resolution — directories with trailing spaces are now matched via fallback scan
- fix: `sdk global`, `sdk use`, and `sdk remove` all trim version names and use resolved paths
- feat: VS Code & IntelliJ extensions v0.3.1

## 0.11.1

- fix: switch CI to GitHub-hosted runners (ubuntu-latest, windows-latest, macos-latest)
- fix: correct build matrix — replace duplicate macOS entry with Ubuntu for coverage uploads
- deps: upgrade `json_rpc_2` to ^4.1.0 and `lints` to ^6.1.0

## 0.11.0

- feat: engine now builds from within the Flutter contributor checkout (monorepo alignment with flutter/flutter)
- feat: `install engine` requires `install flutter` first — engine lives inside the Flutter checkout
- feat: add `--force` flag to `install engine` and `sync engine` for forced `gclient sync` with automatic retry
- feat: `build engine` now prepends depot_tools to PATH automatically (no manual PATH setup needed)
- feat: `install flutter --ide vscode|intellij` flag — skip or auto-accept IDE-specific prompts when called from extensions
- feat: `doctor` now probes known depot_tools locations for gclient beyond PATH
- fix: `doctor` strips trailing `/bin` from rc config paths for correct repo root detection
- fix: idempotent git remote setup in `install flutter`, `install devtools`, and `install engine` (safe to re-run)
- fix: `install devtools` now saves path to rc config before modifying shell config
- fix: gclient template updated for monorepo (`name: "."`, `{{flutter_url}}`)
- fix: engine upstream URLs changed from flutter/engine to flutter/flutter
- fix: better error messages and manual recovery instructions for gclient sync failures
- feat: VS Code extension v0.3.0 — dual SDK backend (Native + FVM), SDK Manager toggle button, doctor install actions
- feat: IntelliJ plugin v0.3.0 — mode dropdown for Native vs FVM backend, enhanced CLI integration

## 0.10.1

- fix: rc config read/write now splits on first colon only, fixing Windows drive-letter paths (e.g. `C:\Users\...`)
- fix: file watcher path matching now handles Windows backslash separators
- fix: add `TempHome` isolation to `sdk exec` and `sdk global` tests to prevent failures on machines with a configured SDK
- fix: remove unused import in `sdk_exec_command_test.dart`
- fix: increase file watcher test timeouts for Windows CI reliability
- chore: add `.kotlin/` to IntelliJ extension `.gitignore`
- chore: add `.DS_Store` to root `.gitignore`

## 0.10.0

- feat: add `daemon` command — JSON-RPC 2.0 daemon for real-time IDE communication over stdin/stdout
- feat: daemon supports `sdk.list`, `sdk.global.get/set`, `sdk.use.get/set`, `doctor`, `config.list/get/set`, `status`, `version`, `shutdown` methods
- feat: daemon sends `sdk.changed` and `config.changed` notifications on file system changes
- feat: add `ui` command — interactive terminal UI dashboard for SDK management
- feat: TUI provides four tabs: SDKs (with install/set global), Environments, Builds, Doctor
- feat: TUI keyboard navigation with arrow keys, number keys for tab switching, and action keys
- feat: extract `gatherSdkList()`, `gatherDoctorChecks()`, `gatherStatus()`, `gatherConfig()` helpers for daemon/TUI reuse
- feat: add file watcher with 500ms debounce for `.flutter_compilerc` and `.flutter-version` changes
- deps: add `json_rpc_2` and `stream_channel` dependencies
- test: add tests for daemon peer, file watcher, TUI key parser, TUI renderer, and new commands
- feat: add VS Code extension MVP (`extensions/vscode/`) — status bar SDK version, quick pick switcher, Install SDK / Switch SDK / Doctor commands
- feat: VS Code extension auto-updates `dart.flutterSdkPath` workspace setting on SDK switch
- feat: VS Code extension watches `.flutter-version` for external changes and updates status bar + settings automatically
- feat: add `--force` flag to `sdk install` to remove and re-install an existing SDK
- feat: add `isValidGitRepo()` validation — detect and recover from partial/corrupted clones
- feat: harden `cloneRepository()` with force mode and partial clone cleanup on failure
- feat: `isSdkInstalled()` now validates `.git/HEAD` instead of just directory existence
- feat: idempotent PATH management — `switch`, `uninstall`, and `sdk global` use regex-based block detection to prevent duplicate entries
- feat: add `homeDirOverride` to `F` class for test isolation
- feat: add shell completions documentation to README
- ci: expand GitHub Actions to matrix strategy (Ubuntu, Windows, macOS)
- test: add `TempHome` test helper for isolated filesystem tests
- test: add behavioral tests for `config`, `clean`, `status`, and `sdk install` commands
- test: add unit tests for `Constants`, `ConsoleColor` extension, `isValidGitRepo`, `writeKeyValueToRcConfig`, `readGlobalSdkVersion`
- feat: add Android Studio / IntelliJ plugin MVP (`extensions/intellij/`) — toolbar combo box SDK switcher, tool window with SDK list and doctor output
- feat: IntelliJ plugin auto-updates Flutter SDK path in project settings on SDK switch via `FlutterSdkUtil`
- feat: IntelliJ plugin settings panel for configuring `flutter_compile` CLI path

## 0.9.0

- feat: add `sync` command to sync contributor environments with upstream (`sync flutter`, `sync engine`, `sync devtools`)
- feat: add `sy` alias for `sync` command
- feat: bare `sync` (no subcommand) runs all three environments sequentially
- feat: add `fcp` executable alias — `fcp` works everywhere `flutter_compile` does
- feat: add `--json` flag to `sdk list`, `doctor`, `config list`, and `status` for machine-readable output
- feat: add Windows support — cross-platform PATH management, shell config detection, and host architecture resolution
- feat: add `F.homeDir()` cross-platform helper (HOME on Unix, USERPROFILE on Windows)
- feat: `isCommandAvailable()` now uses `where` on Windows, `which` on Unix
- feat: `getHostCpuArch()` uses PROCESSOR_ARCHITECTURE env var on Windows
- feat: `getShellConfigPath()` returns PowerShell profile path on Windows
- feat: add platform-aware PATH export templates for PowerShell
- feat: `doctor` now checks for Visual Studio (cl.exe) on Windows
- feat: `install flutter` and `install engine` now accept Windows as a supported platform
- feat: `du` commands replaced with PowerShell equivalents on Windows for `status` and `clean`

## 0.8.0

- feat: add `sdk exec` command to run commands through the resolved SDK (project `.flutter-version` → global default)
- feat: `sdk install` auto-sets global default when installing the first SDK
- feat: `sdk remove` now allows removing the global SDK and cleans up rc config and shell PATH block

## 0.7.0

- feat: add `sdk global` command to set or show the global default Flutter SDK version
- feat: add `sdk use` command to pin a Flutter SDK version per project (`.flutter-version`)
- feat: PUB_CACHE isolation — each installed SDK uses its own `.pub-cache` directory
- feat: `sdk list` now annotates entries with `(global)` and `(project)` markers
- feat: `sdk remove` now guards against removing the global default or project-pinned SDK
- feat: add SDK resolution helpers (`sdkPubCachePath`, `sdkEnvironment`, `sdkVersionPath`, `isSdkInstalled`, `readProjectSdkVersion`, `readGlobalSdkVersion`, `resolveActiveSdkVersion`)
- feat: add `environment` parameter to `F.runCommand()` and `F.runFlutterCommand()`
- feat: add `global_sdk` alias to `config` command

## 0.6.0

- feat: add `sdk` command to install and manage multiple Flutter SDK versions (`sdk install`, `sdk list`, `sdk remove`)
- feat: add `dr` alias for `doctor` and `up` alias for `update`
- refactor: replace all `exit()` calls in shared utilities with `FlutterCompileException`
- refactor: add centralized exception handling in command runner
- refactor: extract shell config detection to shared `F.getShellConfigPath()` utility
- refactor: replace `exit()` calls with return exit codes in install/build commands
- fix: rename `uninstall devtool` → `uninstall devtools` for consistency (old name kept as alias)
- test: extract shared test helpers to reduce boilerplate across 12 test files
- test: add tests for exception handling, `sdk` command, `install`, `uninstall`, and `switch` commands

## 0.5.1

- chore: upgrade mason_logger to ^0.3.3 and pub_updater to ^0.5.0

## 0.5.0

- feat: add `clean` command to remove engine build output directories (alias: `c`)
- feat: add `config` command to view and modify `.flutter_compilerc` from CLI (alias: `cf`)
- fix: `uninstall flutter` now removes PATH exports from shell config and cleans `.flutter_compilerc`

## 0.4.0

- feat: add `test` command to run Flutter tests with a local engine build (`--local-engine`)
- feat: add `status` command to show engine configuration and available builds
- feat: add `t` alias for `test` command and `st` alias for `status` command

## 0.3.1

- ci: add code coverage reporting and Codecov integration
- docs: update README badges (build, codecov, pub version, Dart SDK)

## 0.3.0

- feat: add `run` command to launch Flutter apps with a local engine build (`--local-engine`)
- feat: add `--gn` and `--no-gn` flags to `build engine` for incremental rebuilds (auto-skips GN when `build.ninja` exists)
- feat: add `r` alias for `run` command

## 0.2.0

- feat: automate Flutter engine setup (`install engine`) — depot_tools, gclient sync, git remotes
- feat: add `build engine` command with GN flag resolution and ninja builds
- feat: support all platforms — android, ios, macos, linux, web, host
- feat: extend `doctor` with depot_tools, ninja, Xcode, and engine environment checks
- feat: implement `uninstall engine` with optional depot_tools cleanup
- feat: add `workingDirectory` support to `runCommand()`, `getHostCpuArch()`, `writeFile()` utilities

## 0.1.0

- feat: add `doctor` command for environment health checks
- feat: implement `uninstall devtool` with PATH and config cleanup
- fix: bug fixes and dead code cleanup

## 0.0.1

- Initial release

## 0.0.2

- Fix: broken links

## 0.0.2+1

- fix: tests

## 0.0.2+2

- fix: version index
- chore: update 

## 0.0.3

- feat: (breaking) added support for compiling devTools