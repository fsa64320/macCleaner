# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

macCleaner is a SwiftUI maintenance utility for macOS 14+, an independent reimplementation of CleanMyMac features. It must not contain MacPaw code, assets, text or rule databases, nor reuse their OAuth client IDs. UI strings, code comments and the README are in French.

## Commands

Only the Xcode Command Line Tools are installed, not Xcode.

```bash
swift test                                  # all tests
swift test --filter CoreTests               # one suite
swift test --filter testPolicyRejectsSensitiveLocations   # one test
MACCLEANER_INTEGRATION=1 swift test         # also runs RealSystemTests (real Trash and launchctl)
Scripts/build-app.sh                        # release build, icon, signature: build/macCleaner.app
open build/macCleaner.app
```

There is no linter configuration.

If `swift test` fails with `TestingMacros ... plugin ... could not be found`, it is a toolchain flake, not a code error: run `rm -rf .build` and retry.

## Toolchain constraints

- Tests use Swift Testing; XCTest is unavailable.
- The `SwiftUIMacros` plugin is unavailable, so the `@State` macro does not compile. Use `ObservableObject` with `@StateObject`/`@ObservedObject`.

## Architecture

Two targets: `MacCleanerCore` (library, no UI, everything testable) and `MacCleaner` (SwiftUI executable). All tests target Core.

**Scan then clean.** Each scanner in Core is a `Sendable` struct taking a `ScanEnvironment` and returning a `ScanResult` of `ScanCategory`/`ScanItem`. Scanning never modifies anything. An item's `Removal` says how it leaves: `moveToTrash`, `permanent`, `launchAgent`, `evictLocalCopy` or `dockerImage`.

**Every removal goes through `CleanupRunner`** (`Cleanup.swift`), which checks `locked`, `Exclusions` and `SafetyPolicy` on the item and its `companions`, then calls a `FileRemoving`, writes the log and appends to `CleanupHistory`. Tests inject a fake `FileRemoving`. Do not delete files outside this path, and add new sensitive locations to `SafetyPolicy`. `permanent` is only valid inside a trash, and `evictLocalCopy` only under the cloud folders.

**Progress and cancellation** travel through the task-local `ScanProgress.current`, so long loops check `ScanProgress.shouldStop` without any parameter being passed down.

**UI.** `Module` in `AppModel.swift` lists the sidebar screens; `ScanStore` runs a scan and its cleanup for a module, rendered generically by `ScanModuleView`. A new scanner usually needs only a `Module` case and its wiring. Screens with their own model have dedicated views (`CloudView`, `UpdatesView`, `SpaceLensView`, and so on).

**Remote cleanup** (`OAuth.swift`, `RemoteServices.swift`, `CloudView.swift`) uses OAuth 2 PKCE with a loopback receiver on `http://localhost:53682/callback`, tokens in the Keychain, and sends items to the service's trash, never permanently. `KeychainTokenStore.hasTokens` reads attributes only: reading token values at screen open triggers a password prompt because the ad-hoc signature changes on every build.

## Repository rules

- `main` is protected by a ruleset with no bypass, admins included: changes go through a branch and a pull request, and force-push and deletion are refused.
- `Config/OAuthClients.json` holds real OAuth identifiers. It is git-ignored and copied into the app bundle by `build-app.sh`; never commit it. `Config/OAuthClients.example.json` is the template.
- `docs/ANALYSE.md` is local only (excluded through `.git/info/exclude`) and must stay out of history.
- The repository is public: commit with the `noreply` address already set in the local Git config.
