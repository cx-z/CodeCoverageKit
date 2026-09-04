# Runtime Behavior

## Snapshot lifecycle

`CodeCoverage.start()` initializes the collector once, restores all manifests and captures the current LLVM runtime buffer. Entering the background captures again. Entering the foreground reloads manifests but does not capture or upload. `snapshot` captures on demand without networking. `uploadPending` first captures a current snapshot, then uploads all pending and retryable records.

The collector does not depend on application termination callbacks and does not run a timer. Normal snapshots do not reset LLVM counters, so later profiles represent cumulative execution in that process.

## Ownership and persistence

All LLVM runtime access, filesystem mutation, record state and upload sequencing belong to one private serial collector queue. The store is used only on that boundary. Public callbacks return immutable summaries on the main thread; the UIKit console and its view model are main-actor isolated.

New hosts store data under:

```text
Application Support/CodeCoverageKit/
  device.json
  snapshots/<build-id>/<run-id>.profraw
  snapshots/<build-id>/<run-id>.json
```

Profile bytes are written before the manifest, both atomically. Directories are excluded from backup. Every manifest fixes its own Cycle and Build identity, so installing another Build cannot relabel old pending files.

## Recovery and upload states

The durable states are pending, uploading, uploaded, retryable failure and permanent failure. An `uploading` record found after process interruption returns to pending. Before upload, size and SHA-256 are recalculated from disk and must match the manifest.

Only HTTP 200, 201 or 202 with exact `status`, `run_id`, `cycle_id`, `build_id`, `sha256` and `size` echoes marks a record uploaded. Authentication errors stop the current batch. Conflict is permanent. Transport and 5xx errors receive only bounded retries during the current user action and remain recoverable afterward.

The SDK never uploads the app executable, dynamic libraries, dSYM, Build manifest or business data. Those Build artifacts belong to the Mac-side registration process.
