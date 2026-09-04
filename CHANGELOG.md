# Changelog

All notable changes to CodeCoverageKit will be documented here after versioning begins.

## Unreleased

- Added CocoaPods source distribution for hosts that must physically exclude the SDK from Release.
- Extracted the iOS LLVM runtime bridge, metadata, snapshot store, collector, upload clients, configuration and UIKit console into an independent Swift Package.
- Added the small Swift-only `CodeCoverage` facade and Debug/Release compile boundary.
- Added neutral metadata, storage, request identifiers and documentation for multi-project hosts.
- Kept metadata, storage and configuration identifiers host-neutral without historical host fallbacks.
- Added contract, concurrency-boundary, networking and LLVM profile analyzability tests.

No package version or remote repository has been published yet.
