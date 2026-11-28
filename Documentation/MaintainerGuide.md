# Maintainer Guide

## Architecture invariants

- `CodeCoverage` is the only host-facing owner.
- `CoverageCollector` is the serialization boundary for runtime, Store, records, receipts and batch commits. The preparation worker handles immutable offline LLVM/gzip computation; no Store or mutable batch state crosses to it.
- `CoverageSnapshotStore` is not a general repository and must remain collector-owned.
- UI state is main-actor isolated; network and storage orchestration do not move into the view controller.
- Lifecycle capture never uploads. User intent is required for every Run upload batch.
- A record's Cycle/Build identity is immutable across installations.
- Run multipart and strict response matching remain aligned with the server contract. Every new SDK Run request is gzip regardless of network; use system zlib consistently in SwiftPM and CocoaPods. Decode-only transport changes must not affect raw size/SHA or identity.
- `CoverageUploadPlan` keeps same-launch representative selection separate from cross-launch grouping. Latest-only substitution defaults off after concurrent hit-equivalence counterexamples; do not enable it from sequence ordering alone. All raw sources remain eligible until directly or receipt-confirmed delivered.
- The single CodeCoverageKit product includes its versioned LLVM XCFramework in both dependency systems. The facade installs/enables the internal engine with SDK-owned provisional budgets; hosts do not reference a provider, SPI or second dependency. Keep the SDK physically excluded from unauthorized configurations; see `OfflineProfileMerge.md`.
- Raw profiles/manifests, fixed aggregate artifacts and strict receipts have explicit sync/rename/directory/full-flush commits. Save/confirmation failure cannot complete obligations. Recovery rechecks every binding and re-syncs before using completed evidence.
- A new aggregate is a new Run; never batch-mark original manifests uploaded, recursively merge prior products, or let a source declaration authorize server deletion. Preserve all original material.
- Freeze inputs/engine/budgets at the user action, commit only current-batch worker results, prepare one group at a time, and retry the same encoded object at most three transport/5xx attempts. Wait for a worker to finish before fallback.
- Compare complete multipart gzip bytes including provenance. Resource, maximum-request/growth, stopping-delay and savings thresholds require actual device/host data; no production defaults are approved.
- Strict indexed acknowledgements bind format and Python-compatible canonical metadata SHA. Persist receipt before reporting delivered sources; keep original direct-upload counts distinct.
- Permanent aggregate rejection binds exact source identities and indexed payload size/SHA across restart. Do not blacklist its raw sources: changed-source/content groups may proceed, while unchanged combinations cannot acquire a fresh envelope. An unchanged historical match fails only that group and advances to later frozen groups, including other Builds; newly received permanent errors retain their batch-stop behavior. Preserve original Run permanent-failure semantics.
- Disabling merge preserves receipts and restores raw gzip for unconfirmed original sources. The facade enables a new process by default for internal device acceptance; no received-object withdrawal or repair system is included.
- The restricted Run token never enters UI, UserDefaults, logs, errors or test snapshots.

## Host-neutrality policy

Host-specific constants, historical filenames, storage roots and UserDefaults keys do not belong in the SDK. A host that later requires data migration should own that requirement explicitly; do not add speculative compatibility paths to the shared metadata, configuration or storage modules.

## Changing public API

Keep the facade small and callback delivery on the main thread. Document whether each new entry point snapshots, persists, reads secrets, performs networking and changes durable failure state. Prefer immutable `Sendable` result summaries over exposing internal records.

## Required validation

Run `swift test --enable-code-coverage` for Package Debug tests with a real `coveragectl` metadata fixture when available, Package Release, an iOS Simulator build, and the host's ordinary Debug, Coverage Debug and Release builds. Verify ordinary Debug/Release contain no dynamic metadata or token. Verify vendor artifact checksums and licenses. Run the production C-bridge synthetic equivalence/error tool, persistence fault tests and frozen-batch tests. These do not replace target-device sudden-reboot, equality, memory/time/stop-latency and weak-network acceptance. Run source hygiene scans and inspect host project references for duplicate implementations.

True-device regression is required for lifecycle snapshots, overwrite-install persistence, local-network permission, health/probe, manual upload and analyzability. Automated simulator builds do not prove those behaviors.

## Repository and release

`CodeCoverageKit` is an independent Git repository distributed from `https://github.com/cx-z/CodeCoverageKit`. The platform parent is an organizational directory, not a monorepo. Keep SwiftPM and CocoaPods source ownership aligned, pin reviewed host integrations, and define semantic-version/tag ownership before publishing a stable release.
