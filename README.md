# CodeCoverageKit

`CodeCoverageKit` is a source Swift Package for collecting LLVM coverage profiles from internal iOS builds. It snapshots `.profraw` data locally, survives app restarts and overwrite installs, uploads only after an explicit user action, and includes an optional UIKit diagnostics console.

## Package layout

```text
CodeCoverageKit/
  Package.swift
  Sources/
    CodeCoverageRuntimeBridge/  Internal Objective-C/Clang LLVM bridge
    CodeCoverageKit/            Swift runtime, storage, upload, configuration and UI
  Tests/CodeCoverageKitTests/   Host-independent contract and runtime tests
```

The package, library product and Swift module are all named `CodeCoverageKit`. `CodeCoverageRuntimeBridge` is an implementation-only target and is not a separate product.

Supported package platforms are iOS 15+ and macOS 12+. The host-facing facade and console require UIKit/iOS; macOS support exists so host-independent Package tests can run without an app.

## Host API

```swift
#if INTERNAL_COVERAGE // Host-defined for its internal Coverage Debug configuration.
import CodeCoverageKit

CodeCoverage.start()

if CodeCoverage.isAvailable {
    let console = CodeCoverage.makeConsoleViewController()
    navigationController?.pushViewController(console, animated: true)
}
#endif
```

Hosts that provide their own UI can call `CodeCoverage.snapshot(completion:)` and `CodeCoverage.uploadPending(completion:)`. The host does not access the collector, store, upload client or LLVM bridge directly.

Lifecycle collection is local-only. `start()` captures at launch, backgrounding captures again, and returning to the foreground restores persisted state. Uploading happens only through `uploadPending` or the console button; that action first creates a fresh snapshot and then uploads all pending Runs serially.

## Integration overview

1. Add this directory as a local Swift Package and link the `CodeCoverageKit` product to the app target.
2. Enable LLVM coverage mapping on the app target for the intended internal Debug configuration.
3. Call `CodeCoverage.start()` once and expose the optional console behind the host's existing debug-only condition.
4. Use `coveragectl prepare` before Archive and inject its generated `CodeCoverageBuildMetadata.json` through a build phase.
5. Use `coveragectl register` on that same Archive before signing or distribution completes.

After a company repository and version policy exist, the equivalent manifest declaration will use placeholders such as `.package(url: "<GitLab-package-URL>", from: "<approved-version>")`. Neither value is assigned in the current local baseline.

The metadata contains a restricted Run token. It can call only probe and Run-upload endpoints, is never displayed by the SDK, and must never be confused with an operator token. It can still be extracted from an IPA, so Coverage builds remain internal artifacts.

See [Getting Started](Documentation/GettingStarted.md), [Build and Metadata](Documentation/BuildAndMetadata.md), and [Runtime Behavior](Documentation/RuntimeBehavior.md) for executable setup details.

## Build boundaries

- Debug compiles the implementation behind `CODE_COVERAGE_KIT_ENABLED`.
- Release does not expose the `CodeCoverage` facade or compile the self-managed collection, storage, upload, UI and runtime behavior.
- The SDK does not enable coverage mapping for the host, inject metadata, sign an app, register a Build or distribute an IPA.
- The SDK accepts only private/link-local IPv4 or `.local` server roots and never uploads automatically.

## Quick acceptance

- The Coverage Debug app contains neutral Build metadata and shows the expected Cycle/Build.
- Launch and backgrounding create pending profiles without increasing the server Run count.
- An overwrite install preserves URL and pending records.
- Health and the no-business-data probe succeed on a reachable LAN.
- One explicit upload drains pending, reports no failures and creates an analyzable Run.
- Ordinary Debug and Release contain neither dynamic metadata nor a restricted token.

## Development

Use the build machine's selected Xcode by default:

```bash
cd /path/to/CodeCoverageKit

xcrun swift test --enable-code-coverage

xcrun swift build -c release

xcodebuild -scheme CodeCoverageKit \
    -destination 'generic/platform=iOS Simulator' build
```

Set `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer` for all commands when a host project or build machine requires a specific Xcode installation.

More references:

- [Configuration](Documentation/Configuration.md)
- [Troubleshooting](Documentation/Troubleshooting.md)
- [Maintainer Guide](Documentation/MaintainerGuide.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## Current scope

This repository does not include the Coverage server, `coveragectl`, a sample app, Objective-C host APIs, ProjectRegistry, or a binary distribution. A company GitLab package URL and versioning policy have not yet been assigned; use a local package dependency until those are established.
