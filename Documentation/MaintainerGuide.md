# Maintainer Guide

## Architecture invariants

- `CodeCoverage` is the only host-facing owner.
- `CoverageCollector` is the single serialization boundary for runtime, files, records and batch state.
- `CoverageSnapshotStore` is not a general repository and must remain collector-owned.
- UI state is main-actor isolated; network and storage orchestration do not move into the view controller.
- Lifecycle capture never uploads. User intent is required for every Run upload batch.
- A record's Cycle/Build identity is immutable across installations.
- Run multipart and strict response matching remain aligned with the server contract.
- The restricted Run token never enters UI, UserDefaults, logs, errors or test snapshots.

## Host-neutrality policy

Host-specific constants, historical filenames, storage roots and UserDefaults keys do not belong in the SDK. A host that later requires data migration should own that requirement explicitly; do not add speculative compatibility paths to the shared metadata, configuration or storage modules.

## Changing public API

Keep the facade small and callback delivery on the main thread. Document whether each new entry point snapshots, persists, reads secrets, performs networking and changes durable failure state. Prefer immutable `Sendable` result summaries over exposing internal records.

## Required validation

Run Package Debug tests with a real `coveragectl` metadata fixture when available, Package Release, an iOS Simulator build, and the host's ordinary Debug, Coverage Debug and Release builds. Verify ordinary Debug/Release contain no dynamic metadata or token. Run source hygiene scans and inspect host project references for duplicate implementations.

True-device regression is required for lifecycle snapshots, overwrite-install persistence, local-network permission, health/probe, manual upload and analyzability. Automated simulator builds do not prove those behaviors.

## Repository and release

`CodeCoverageKit` is an independent Git repository distributed from `https://github.com/cx-z/CodeCoverageKit`. The platform parent is an organizational directory, not a monorepo. Keep SwiftPM and CocoaPods source ownership aligned, pin reviewed host integrations, and define semantic-version/tag ownership before publishing a stable release.
