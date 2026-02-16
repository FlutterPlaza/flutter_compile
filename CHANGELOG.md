# CHANGE LOG

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