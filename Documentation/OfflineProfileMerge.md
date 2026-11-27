# Optional offline profile merge

Cross-launch merging is implemented but **off by default**. No device/toolchain combination is approved for production enablement yet. Ordinary `CodeCoverageKit` has no LLVM dependency. The optional component must be built separately and included only in a Coverage target/configuration. It is not a published binary dependency or a host dependency upgrade.

## Dependency and build

`Tools/ProfileMerge/build.py` pins official LLVM **20.1.8**, verifies both source archive SHA-256 values, and builds the `LLVMProfileData` static dependency closure. The closure includes Support, Core, Object and debug-information libraries; it is not the profile runtime. No LLVM source patches are applied. LLVM uses Apache-2.0 WITH LLVM-exception; the build copies its license beside the generated XCFramework.

Use CMake 3.31.6 and Ninja 1.11.1.4 for the validated build recipe. Supply a dedicated cache and a fresh output directory:

```sh
python3 Tools/ProfileMerge/build.py \
  --cache /path/to/isolated-llvm-cache \
  --output ProfileMergeSupport/Artifacts \
  --developer-dir /Applications/Xcode263.app/Contents/Developer
```

The default slices are iOS arm64, iOS Simulator arm64/x86_64, and macOS arm64/x86_64. Minimum deployment targets are explicitly set to iOS 15 and macOS 12 for every corresponding object, including the native arm64 host slice. The current build recipe is validated on an Apple Silicon build Mac. LLVM symbols use hidden visibility, so a final Debug dylib cannot retain unused command-line process helpers merely through default exports. LLVM assertions, backtraces and crash overrides are disabled; exception handling and RTTI are enabled so allocation exceptions can unwind to the C bridge. The bridge catches standard exceptions and returns a failure; it does not install process-wide LLVM handlers or access App counters. OS process termination or jetsam is not a catchable exception.

Generated `ProfileMergeSupport/Artifacts` is ignored by Git. Keep a fresh source cache for release reproducibility; do not use a cache modified for another experiment. Rebuild rather than silently replacing source versions. There is no vendored binary in the ordinary SDK checkout/product.

## Integration boundary

SwiftPM uses the **local** `ProfileMergeSupport/Package.swift` package and its `CodeCoverageKitOfflineMerge` product, after the artifact build. The root package remains unchanged. A future remote binary/package release is a separate distribution task.

CocoaPods defaults to `CodeCoverageKit/Core`. For commit-pinned Git integration, declare **both** `CodeCoverageKit` and `CodeCoverageKitOfflineMerge` from the same repository and exact commit, restricted to the authorized Debug/Coverage configuration. The standalone optional Pod builds the verified sources during CocoaPods preparation, before source pruning, and caches the prepared Pod normally. It bootstraps pinned CMake/Ninja in an isolated Python venv; first installation requires network, build time and disk space. `CCK_PROFILE_MERGE_CACHE` can select a dedicated reusable source/build cache. Core never invokes this build. CocoaPods cache reuse does not rerun preparation; rebuild/reinstall the optional Pod when changing the build recipe or toolchain.

The local prebuilt `CodeCoverageKit/OfflineMerge` subspec remains available for prepared checkouts. Do not install it together with the standalone optional Pod. Both integrations use the same provider and bridge. Keep ordinary Debug/Release on Core or physically exclude the SDK according to the host policy. Do not use a runtime switch to claim dependency isolation. Build the generated workspace.

`CoverageOfflineMerge.install(limits:)` is an `OfflineMerge` SPI for a validated internal Coverage integration. It registers the engine and caller-supplied measured `CoverageMergeLimits`; it does **not** enable merging. There are deliberately no production budget defaults. Installation and budget selection must follow device acceptance. The facade/console local switch controls only the next manual upload; it resets to off when the process starts. The console cannot enable merging without an installed engine and valid budgets.

An explicitly authorized internal device-acceptance host may install experimental budgets and enable merging at startup to perform that acceptance. Its defaults belong to the host, do not approve the device matrix, and do not change Core's disabled default. Document those budgets as provisional and keep the console off switch available.

Do not update a host dependency, publish artifacts, tag a version or enable this SPI as part of ordinary SDK development.

## Format matrix

| Dimension | Implemented recognition | Acceptance boundary |
| --- | --- | --- |
| Input | little-endian 64-bit raw magic, exact version 10, no variant bits | Synthetic macOS Clang C/Objective-C/C++ and Swift fixtures; real iOS acceptance pending |
| Features | frontend instrumentation; LLVM function identity/hash/counters and binary IDs | Bitmap/MC/DC, value-profile records and vtable-profile names are explicitly rejected; IR, temporal, correlated and unknown formats are rejected |
| Merger | LLVM 20.1.8 Reader/Writer, independent memory buffers | Whole group fails on any reader/writer diagnostic; no skipped input |
| Output | sparse indexed version 12; fully reread before success | Compatible desktop fixtures read with Xcode 26.3 Apple LLVM 17.0.0 |
| Library builds | five architecture slices above | Compilation/linking is distinct from execution on those targets |

Synthetic Darwin raw fixtures currently carry an empty binary-ID list; preservation of a nonempty raw binary-ID list still needs target-input acceptance even though the reader/writer API path is implemented.

The version/variant check identifies a format, not every compiler or instrumentation option that might produce that header. Do not expand the approved matrix based only on an Xcode version string or a valid header. Unsupported input falls back to raw gzip; headers are never rewritten. Original profiles/manifests are retained across Build installations with their original identity.

## Planning and delivery

The first layer is a pure raw-source plan. Latest-only same-launch substitution is disabled in the Collector: concurrent cumulative snapshots can produce different region/line/branch hit states from the final snapshot alone. Ordering remains recorded, but is not a semantic proof. Preserve all valid unconfirmed original snapshots unless a separate equivalent representative rule is approved. Exact receipt-completed sources are still omitted.

The second layer freezes that plan when the user uploads, groups stably inside Cycle/Build/device with bounded source count and input bytes, and considers only groups containing different launches. It never consumes a prior aggregate. A serial preparation worker receives immutable records/paths/configuration and performs LLVM and gzip work; the Collector owns Store, state, batches and commit decisions. Worker results must match the active batch. New lifecycle snapshots wait for the next action.

For the exact selected group, compare the sum of complete raw multipart gzip request bodies with the complete indexed multipart gzip body, including the canonical source declaration. Use deterministic boundaries and the same encoder for comparison and actual sends. Budgets cover input/output/records/source count, metadata, preparation time, process peak RSS, disk reserve, maximum compressed request, maximum growth over the largest original request, and absolute/relative byte savings. RSS is the process lifetime peak, not an isolated allocation delta or a hard allocator limit. Do not choose budgets from small desktop fixtures.

Preparation time starts before worker dispatch, includes file reads/LLVM/gzip comparisons plus durable object/attempt publication, and is rechecked with process peak RSS immediately before the first send. LLVM receives only the remaining time after source reads. Timeout checks occur at source, record, writer and byte-comparison boundaries. An individual LLVM read/write or gzip operation may overrun; no fallback starts before the serial worker has returned. Measure the longest operation and stopping delay on the target device. A failed merge/benefit check or aggregate commit falls back to original gzip. If raw preparation/state persistence also fails, the batch stops without completing obligations.

An aggregate gets a new Run ID and explicit `profile_format: indexed`, `trigger_reason: cross_launch_merge`, `app_state: unknown` (the worker does not infer UIKit state), and schema-1 aggregation sources sorted by Run ID (2–64 distinct sources from multiple launches). Sources name only actual raw inputs. Metadata uses UTF-8 sorted compact JSON matching Python `ensure_ascii=False`; a Swift/Python golden covers escaping, Unicode, large integers, omissions and array identity.

Every retry reuses the same prepared object, metadata, payload and gzip bytes, at most three transport/5xx attempts. There is no format switch after sending starts. A later manual action may recombine unconfirmed originals with new content under a fresh identity. Permanent aggregate rejection stays visible and blocks automatic renaming of its exact sources while merging remains enabled. Explicitly disabling merge restores raw sends for unconfirmed sources.

## Durable commits and rollback

Raw payloads precede manifests. Aggregate payloads precede fixed object manifests. Strict receipts are separate from original manifests:

```text
CodeCoverageKit/
  snapshots/<build-id>/<run-id>.profraw + .json
  aggregates/<build-id>/<aggregate-id>/payload.profdata + object.json
  receipts/<aggregate-id>.json
```

`CoverageDurableFile` creates and syncs directory chains, writes a same-directory temporary file, fsyncs and full-flushes its contents, renames it, fsyncs the parent directory and full-flushes the open regular-file descriptor again. Every error propagates; unsupported flush is not treated as success. Recovery revalidates size/SHA/metadata and reestablishes sync/flush for the complete SDK directory chain before using a record or receipt as completed evidence. The default trusted anchor is the OS-owned Library directory, so a prior interrupted creation of Application Support is covered too. These explicit boundaries still require sudden-reboot verification on the target filesystem/device.

Only strict 200/201/202 accepted echoes, including indexed `profile_format` and `metadata_sha256`, permit a receipt. The receipt must finish durable publication before sources become delivered in memory or UI. Original `uploaded` means only its own directly acknowledged upload. Missing/corrupt/unverifiable receipts conservatively leave sources eligible for retransmission. Sources and committed aggregate materials are not cleaned up.

Call `CodeCoverage.setCrossLaunchMergeEnabled(false)` or turn off the console switch. The next manual operation sends unconfirmed raw snapshots individually, still as full multipart gzip. An active batch finishes its fixed objects. Existing receipts stay valid. No old SDK/server downgrade, source reactivation, received-object withdrawal or repair framework is provided.

## Verification

Run `Tools/ProfileMerge/verify.py --framework <generated-xcframework> --output <new-temporary-directory>`. It drives the production C bridge, fixes each synthetic binary/tool/source set, compares complete identity-preserving hit projections for regions, branches, segments and functions, checks each launch separately, and exercises raw/indexed/retained-profile/overlap/later-input combinations. It also measures complete gzip bodies and runs malformed/truncated, allocation-failure and output-budget checks. Do not count its synthetic fixture results as true-device acceptance.

Before enablement, finish actual iOS language/instrumentation matrix equality, low-resource/weak-network budgets and stopping latency, overwritten-install Build separation, lifecycle behavior, full flush capability, and sudden reboot after reported raw/receipt save. Validate the real host's ordinary/Coverage/Release dependency isolation and package size. Current runtime behavior remains conservative and merging off until these gates are met.
