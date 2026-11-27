# Built-in offline profile merge

`CodeCoverageKit` includes LLVM offline merging in its single CocoaPods/SwiftPM product. `CodeCoverage.start()` automatically installs the internal engine and SDK-owned budgets and enables cross-launch merging. Hosts declare/import only CodeCoverageKit and do not know about a separate provider, SPI, subspec or engine installation. This default is for the current internal device-acceptance build; true-device equality, sudden-reboot and production resource acceptance are still pending.

## Dependency and build

`Tools/ProfileMerge/build.py` pins official LLVM **20.1.8**, verifies both source archive SHA-256 values, and builds the `LLVMProfileData` static dependency closure. The closure includes Support, Core, Object and debug-information libraries; it is not the profile runtime. No LLVM source patches are applied. LLVM uses Apache-2.0 WITH LLVM-exception; the build copies its license beside the generated XCFramework.

Use CMake 3.31.6 and Ninja 1.11.1.4 for the validated build recipe. Supply a dedicated cache and a fresh output directory:

```sh
python3 Tools/ProfileMerge/build.py \
  --cache /path/to/isolated-llvm-cache \
  --output /path/to/fresh-artifacts \
  --developer-dir /Applications/Xcode263.app/Contents/Developer
```

The default slices are iOS arm64, iOS Simulator arm64/x86_64, and macOS arm64/x86_64. Minimum deployment targets are explicitly set to iOS 15 and macOS 12 for every corresponding object, including the native arm64 host slice. The current build recipe is validated on an Apple Silicon build Mac. LLVM symbols use hidden visibility, so a final Debug dylib cannot retain unused command-line process helpers merely through default exports. LLVM assertions, backtraces and crash overrides are disabled; exception handling and RTTI are enabled so allocation exceptions can unwind to the C bridge. The bridge catches standard exceptions and returns a failure; it does not install process-wide LLVM handlers or access App counters. OS process termination or jetsam is not a catchable exception.

The fixed XCFramework, LLVM license and checksums are versioned under `Vendor/LLVMProfileMerge`. CocoaPods and SwiftPM use the same artifact. Consumers do not build LLVM or install CMake/Ninja. Maintainers rebuild into a fresh output directory, verify the production bridge/equality suite, update vendor checksums and replace the artifact together with its bridge source. Keep an unmodified verified source cache; do not silently change the pinned LLVM version.

## Integration boundary

Declare only `CodeCoverageKit`, pinned to the reviewed commit/version. CocoaPods uses the root podspec, whose internal source and vendored static framework form one SDK module. SwiftPM uses only the root `CodeCoverageKit` product, which owns the binary target internally. No second pod/package/product/import or provider call is needed. The older standalone provider and local support package are removed.

Call `CodeCoverage.start()` from the existing main-actor startup path. It installs and enables the engine once before local collection starts; repeated start calls do not reinstall or reset a user-disabled switch. Keep the entire SDK in the authorized Debug/Coverage configuration. For hosts that must physically exclude it from Release, use the documented CocoaPods configuration boundary; Xcode Swift Package product dependencies cannot express that boundary on one app target.

The SDK provisionally owns these internal acceptance budgets: 32 sources, 32 MiB total input/output each, 2,000,000 records, 5 seconds total preparation, 8 MiB complete gzip request, at most 8x largest original request, savings at least 128 B and 5%, whole-process peak RSS at most 2 GiB, and at least 256 MiB free disk. These are bounded test defaults carried over from the device-acceptance integration, not thresholds approved from actual device measurements. Unsupported formats, failed preparation, exceeded budgets or insufficient savings fall back to individual raw gzip. Hosts do not assemble these budgets.

The console switch and `CodeCoverage.setCrossLaunchMergeEnabled(false)` remain available for the next manual upload. Each new process starts enabled when `start()` runs. Changing the flag never uploads automatically, changes a fixed active object, deletes originals or invalidates receipts.

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

For the exact selected group, compare the sum of complete raw multipart gzip request bodies with the complete indexed multipart gzip body, including the canonical source declaration. Use deterministic boundaries and the same encoder for comparison and actual sends. Budgets cover input/output/records/source count, metadata, preparation time, process peak RSS, disk reserve, maximum compressed request, maximum growth over the largest original request, and absolute/relative byte savings. RSS is the process lifetime peak, not an isolated allocation delta or a hard allocator limit. The provisional built-in limits still require actual device/host acceptance; small desktop fixtures do not validate them.

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

Before enablement, finish actual iOS language/instrumentation matrix equality, low-resource/weak-network budgets and stopping latency, overwritten-install Build separation, lifecycle behavior, full flush capability, and sudden reboot after reported raw/receipt save. Validate the real host's ordinary/Coverage/Release dependency isolation and package size. The current default is explicitly enabled for internal device acceptance; do not describe that setting as proof that these gates passed.
