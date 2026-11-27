# Runtime Behavior

`CodeCoverage.start()` initializes one Collector, restores original manifests/strict aggregate receipts, and captures the current LLVM runtime buffer. Background transitions and explicit snapshots save locally. Foreground reload does not capture/upload. Lifecycle events never upload. The SDK does not reset counters, run a timer or depend on termination callbacks.

`uploadPending` captures and freezes the current valid unconfirmed raw inputs for that user action. Latest-only same-launch substitution is disabled: concurrent cumulative sampling does not generally preserve all earlier region/line/branch hit states. `capture_sequence` remains a local strictly increasing launch sequence, excluded from original Run metadata; sequence ordering alone is not a hit-equivalence proof. Every original profile and manifest is retained.

The single SDK includes the pinned LLVM merger. `start()` installs it and enables merging internally, using SDK-owned provisional device-acceptance budgets. No extra dependency, import, provider or budget setup belongs to the host. See [OfflineProfileMerge](OfflineProfileMerge.md) for the format matrix, limits, gzip comparisons and pending true-device acceptance.

## Ownership and batches

The private serial Collector queue owns runtime access, Store, records, receipts, batch state and result commits. A serial preparation worker receives immutable frozen input/configuration and handles LLVM and gzip work. It never mutates Store or Collector collections. Results are checked against the active batch before publication. Preparing counts as busy; a second action is rejected before capture/reload. Lifecycle snapshots may continue during preparation and wait for the next upload. Callbacks deliver immutable summaries on main; UI is main-actor isolated.

Foreground recovery preserves active raw upload ownership. Every retry uses the same prepared request bytes and object identity, for at most three transport/5xx attempts. New content cannot join an active batch. A later manual action can recombine unconfirmed original sources with new content under a new aggregate identity. Aggregates never become input to another aggregate.

## Persistence and obligations

Data lives under `Application Support/CodeCoverageKit`, excluded from backup. Original snapshots remain under `snapshots/<build-id>`. Optional artifacts use `aggregates/<build-id>/<aggregate-id>` and separate `receipts/<aggregate-id>.json`. Each source keeps its original Cycle/Build/device identity across installations.

Raw profile bytes precede manifests; aggregate bytes precede object manifests. `CoverageDurableFile` explicitly syncs file contents, atomically renames, re-syncs the complete owned directory chain through its stable container anchor and issues Darwin full-storage flush. Sync/flush errors propagate. Only the completed boundary reports local save success. Recovery validates size/SHA and reestablishes the boundary. Device sudden-reboot acceptance is still required; `.atomic`, process restart or a passing desktop fault test is not that proof.

Original statuses remain pending/uploading/uploaded/retryable failure/permanent failure. Interrupted uploading returns to pending unless this Collector still owns the request. A raw Run becomes uploaded only after its own strict acknowledgement and durable state commit. An aggregate gets a separate new Run ID; a strict durable receipt completes exactly its listed raw sources, without setting their manifests to uploaded. Unproven receipts lead to possible duplicate upload, never guessed delivery. There is no client cleanup.

## Requests and feedback

Every upload uses full multipart gzip with system zlib in all network environments, including fallback/retries. Original raw requests keep original metadata and `<run_id>.profraw`; indexed objects use `<run_id>.profdata` and explicit provenance. Payload size/SHA always describe the decompressed profile. Only 200/201/202 accepted responses with matching Run/Cycle/Build/size/SHA are accepted; indexed responses must also echo indexed format and the canonical metadata SHA. HTTP success does not wait for LLVM analysis.

Authentication/encoding rejection stops the batch; 409/permanent rejection cannot be bypassed by automatic new identities. Unsupported formats, failed preparation, exceeded budgets or insufficient complete gzip savings fall back before sending. Raw encoding or local state-commit failure stops without completing obligations. Permanent aggregate errors remain visible.

The console separates preparing/uploading/failure/fallback, received upload objects, aggregate-delivered sources and pending/failed raw sources. The latest raw snapshot never borrows an aggregate's compressed size. Group statistics include complete raw/merged gzip bytes, largest original request, bounded retry bytes, preparation duration and process peak RSS; no credentials/profile content enter telemetry.

The console switch or `CodeCoverage.setCrossLaunchMergeEnabled(false)` affects the next manual operation; it does not rewrite in-flight requests or discard receipts. A new process defaults to enabled when `start()` runs; repeated `start()` does not override a switch disabled in the same process. Closing merge restores individual raw gzip for unconfirmed inputs. The SDK never uploads Build binaries, dSYM, Build manifests or business data.
