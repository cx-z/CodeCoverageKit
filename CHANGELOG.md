# Changelog

All notable changes to CodeCoverageKit are documented in this file.

## 0.1.3 - 2026-11-22

- Gzip-encode every Run multipart upload, including retries and historical pending records, in all network environments using system zlib.
- Select validated, ordered same-launch cumulative snapshots as upload representatives while retaining every original profile and manifest; legacy records remain independently uploadable.
- Preserve active upload ownership during foreground recovery and reject overlapping upload batches before capturing another snapshot.
- Keep original Run identity, raw size/SHA and strict acknowledgement checks; encoding failures retain retryable data and stop the batch without uncompressed fallback.
- Require the Coverage server's gzip upload support to be deployed before using this SDK version.

## 0.1.2 - 2026-11-04

- Added a console Header with a title and back button for hosts that hide the system navigation bar.
- Preserved system navigation when visible and kept host navigation-bar visibility unchanged.

## 0.1.1 - 2026-09-07

- Adopted the Apache License 2.0 for source distribution and contributions.
- Removed the packaged server-address placeholder configuration; the effective server URL now comes only from injected Build metadata or a user-saved override.
- Kept SwiftPM and CocoaPods documentation aligned with the resource-free SDK distribution.

## 0.1.0 - 2026-09-04

- Added CocoaPods source distribution for hosts that must physically exclude the SDK from Release.
- Extracted the iOS LLVM runtime bridge, metadata, snapshot store, collector, upload clients, configuration and UIKit console into an independent Swift Package.
- Added the small Swift-only `CodeCoverage` facade and Debug/Release compile boundary.
- Added neutral metadata, storage, request identifiers and documentation for multi-project hosts.
- Kept metadata, storage and configuration identifiers host-neutral without historical host fallbacks.
- Added contract, concurrency-boundary, networking and LLVM profile analyzability tests.
