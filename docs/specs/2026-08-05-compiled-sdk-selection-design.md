# Design: select the contributor (`compiled`) environment as a Flutter SDK

**Date:** 2026-08-05
**Status:** Approved (design review in session)
**Scope:** `flutter_compile` CLI + VS Code extension

## Problem

`fcp sdk list` and the VS Code SDK picker already *display* the contributor
environment — the from-source Flutter checkout at `~/flutter_compile/flutter`
created by `fcp install flutter` — as a `compiled` entry with a beaker icon.
But selecting it fails: `sdk use`, `sdk global`, `sdk exec`, and the
extension's pick handler all resolve SDK names through helpers that only look
under `~/flutter_compile/versions/`. Contributors who work on Flutter or
engine source cannot switch their tool to the from-source checkout without
hand-editing PATH or using a second machine; ordinary SDK-manager users are
unaffected but the dead-end picker entry is a trap.

## Goals

- `compiled` (input alias: `engine`) is selectable everywhere a versioned SDK
  is: `fcp sdk use compiled`, `fcp sdk global compiled`,
  `fcp sdk exec …` (via pin/global resolution), and a click in the VS Code
  picker.
- Users who never ran `fcp install flutter` see no behavior change at all:
  the entry keeps its existing existence gate (the checkout directory).
- Selecting `compiled` states the boundary honestly: app builds from the
  checkout use the prebuilt engine pinned by `bin/internal/engine.version`
  unless `--local-engine` flags or engine-artifact overlays are used.

## Non-goals

- No linked-SDK registry (arbitrary external checkout paths). One contributor
  environment, fixed path, matching the existing `install flutter` layout.
- No changes to the legacy `fcp switch normal|compiled` command.
- No IntelliJ plugin changes in this iteration (tracked follow-up; extension
  versions publish in lockstep when both are ready).
- The SDK manager never creates, deletes, or mutates the checkout — it only
  points at it.

## Design

### Canonical name and alias

`compiled` is the canonical identifier — it is what `sdk list` already emits,
what the `.flutter-version` pin file records, and what
`global_sdk_version` in `~/.flutter_compilerc` records. `engine` is accepted
as input anywhere a version name is typed and normalized to `compiled` before
any file is written. The UI shows the entry as `compiled` with the existing
beaker icon and an `(engine dev)` description suffix.

### CLI: one resolution choke point

`F.getSdkPath(version)` in `lib/src/shared/functions.dart`:

1. Normalize: trim; map `engine` → `compiled`.
2. If the name is `compiled`: return `~/flutter_compile/flutter` when that
   directory exists, else `null`. Skip the versions-dir scan.
3. Otherwise: existing behavior (canonical path, whitespace-tolerant scan).

`F.isSdkInstalled` already delegates to `getSdkPath` + `isFlutterSdk`
(`bin/flutter` presence), so validation works unchanged.

Call-site changes:

- `sdk use` (`_sdk_use.dart`): normalize the alias before validation and
  before writing `.flutter-version`, so the pin file always contains
  `compiled`. Print the engine caveat (below) when pinning `compiled`.
- `sdk global` (`_sdk_global.dart`): same normalization; existing plumbing
  (rc-config write, shell PATH block, `default` symlink) is path-based and
  needs no change. Print the caveat when the target is `compiled`.
- `sdk exec` (`_sdk_exec.dart`): replace the raw `sdkVersionPath(version)`
  path construction with `getSdkPath(version)` — this fixes an existing
  inconsistency (validation uses the resolver, execution bypassed it) and
  makes `compiled` work with no further change.
- `sdk remove` (`_sdk_remove.dart`): refuse `compiled`/`engine` with:
  `"compiled" is the contributor environment managed by
  "flutter_compile install flutter" / "flutter_compile uninstall flutter" —
  sdk remove does not manage it.`
- `sdk list` (`_sdk_list.dart`): contributor section line gains the hint
  `(selectable: sdk use compiled | sdk global compiled)`. The `--json` shape
  is unchanged.

Caveat text (shared constant, printed by `use`/`global` on `compiled`):

> Note: app builds from the contributor checkout use the prebuilt engine
> pinned by bin/internal/engine.version. To run your locally built engine,
> pass --local-engine / --local-engine-host, or install your engine
> artifacts into this SDK's cache.

### VS Code extension

- `nativeSdkBackend.ts` `getSdkPath(version)`: mirror the special case —
  `compiled` → `<home>/flutter_compile/flutter` when it exists. This is the
  only resolution gap; `setGlobalSdk` and the project-pin path both flow
  through it.
- `commands.ts` (pick handler): after a successful select/pin of a
  `contributor` entry, show one non-modal info toast with the caveat text.
  QuickPick entries for contributor SDKs gain the `(engine dev)` description
  suffix.
- `fvmSdkBackend.ts`: untouched — contributor entries are only produced by
  the native backend.
- Status bar: no change needed; it renders whatever name is active.
- Version: `0.3.6` → `0.3.7`; changelog entry:
  `The Flutter contributor checkout (from "fcp install flutter") can now be
  selected as an SDK from the picker.`

### Error handling

- Checkout absent: `getSdkPath` returns `null` → existing "not installed"
  error path, with the install hint reading `fcp install flutter` for the
  `compiled` name (small message branch in `use`/`global`).
- Checkout present but incomplete (no `bin/flutter`): existing
  `isFlutterSdk` failure, same message as any broken SDK.
- No new error surfaces or exit codes.

### Testing

CLI (`test/src/commands/sdk_commands/`, `test/src/shared/`):

1. `getSdkPath('compiled')` → checkout path when the directory exists, null
   when absent; `getSdkPath('engine')` normalizes identically.
2. `sdk use engine` writes `.flutter-version` containing `compiled` and
   prints the caveat.
3. `sdk global compiled` errors with the install hint when the checkout is
   absent.
4. `sdk remove compiled` refuses with the management message.
5. `sdk exec` resolves the pinned `compiled` version through `getSdkPath`
   (regression for the resolver bypass).

Extension: `npm run compile` + existing lint in CI; manual QA checklist —
pick `compiled`, verify pin file content, status bar, toast, and that a
machine without the checkout shows no entry.

### Rollout

Single PR to `main` containing spec + implementation. CLI ships with the
next `flutter_compile` release (no standalone release required — the feature
is inert without the contributor checkout). Extension `0.3.7` publishes via
the usual `vscode-v*` tag when convenient; IntelliJ parity is a tracked
follow-up and the two extensions tag in lockstep at that point.
