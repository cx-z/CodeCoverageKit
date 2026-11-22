# Runtime Behavior

## Snapshot lifecycle

`CodeCoverage.start()` initializes the collector once, restores all manifests and captures the current LLVM runtime buffer. Entering the background captures again. Entering the foreground reloads manifests but does not capture or upload. `snapshot` captures on demand without networking. `uploadPending` first captures a current snapshot, then freezes a plan of pending/retryable representatives for upload. Legacy records without capture ordering remain independent.

The collector does not depend on application termination callbacks and does not run a timer. Normal snapshots do not reset LLVM counters, so later profiles represent cumulative execution in that process. Each new local manifest has an optional `capture_sequence`, strictly increasing inside that launch and excluded from Run metadata. The upload plan groups by Cycle, Build, device, launch and process, and uses the highest valid sequence in pending/retryable/uploaded state. Missing, invalid or duplicate sequences or unvalidated files disable coalescing for that group. Permanent failures stay visible. Different launches are never substituted.

## Ownership and persistence

All LLVM runtime access, filesystem mutation, record state and upload sequencing belong to one private serial collector queue. The store is used only on that boundary. Foreground reload preserves this collector’s active uploading Run instead of resetting it as an interrupted request. A second upload is rejected before disk reload or capture. Snapshots created during a batch wait for the next explicit upload. Public callbacks return immutable summaries on the main thread; the UIKit console and its view model are main-actor isolated.

New hosts store data under:

```text
Application Support/CodeCoverageKit/
  device.json
  snapshots/<build-id>/<run-id>.profraw
  snapshots/<build-id>/<run-id>.json
```

Profile bytes are written before the manifest, both atomically. Directories are excluded from backup. Every manifest fixes its own Cycle and Build identity, so installing another Build cannot relabel old pending files.

## Recovery and upload states

The durable states are pending, uploading, uploaded, retryable failure and permanent failure. An `uploading` record found after process interruption returns to pending. Before upload, size and SHA-256 are recalculated from disk and must match the manifest. Coalescing only changes the derived upload plan: all profile/manifest files and original statuses remain. Pending/retryable counts omit represented records; uploaded counts include only exact server acknowledgements. Reverting to an older SDK may upload more records but cannot lose data.

Only HTTP 200, 201 or 202 with exact `status`, `run_id`, `cycle_id`, `build_id`, `sha256` and `size` echoes marks a record uploaded. Authentication errors stop the current batch. Conflict is permanent. Transport and 5xx errors receive only bounded retries during the current user action and remain recoverable afterward.

Every Run upload, including old pending records and retries, gzip-encodes the complete multipart body with system zlib, regardless of network conditions or compression ratio. Size/SHA and strict response echoes describe the original raw profile. Encoding failure or server encoding rejection retains a retryable Run and stops the batch without identity fallback or automatic encoding retries. Transport/5xx retries stay bounded; incomplete-request errors are transport-retryable. The single local server must support gzip before the new SDK is used; health/probe does not negotiate capabilities.

The SDK never uploads the app executable, dynamic libraries, dSYM, Build manifest or business data. Those Build artifacts belong to the Mac-side registration process.
