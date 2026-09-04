# Getting Started

## Prerequisites

- An Xcode version supported by the host project.
- An iOS 15 or newer app using Swift.
- An internal Debug-style build configuration that may contain coverage metadata and a restricted Run token.
- Access to `coveragectl` and a compatible Coverage service.

The package does not support a public Objective-C host facade in this version.

## 1. Add the package

For local development, choose **File > Add Package Dependencies > Add Local** in Xcode and select:

```text
/path/to/CodeCoverageKit
```

Link the `CodeCoverageKit` product only to the host app target. Do not link or import `CodeCoverageRuntimeBridge` directly.

For a future remote dependency, use the company GitLab package URL and an approved semantic-version rule after those values exist. Do not copy the source directory into each app repository.

## 2. Enable the host app target

Set the intended internal Debug configuration on the app target itself:

```text
ENABLE_CODE_COVERAGE = YES
CLANG_COVERAGE_MAPPING = YES
```

Keep the package import, startup and debug-menu entry behind the host's existing Debug/Coverage condition. Do not add these entries to Release merely to make the integration compile.

The condition name belongs to the host. For example, a project may define `INTERNAL_COVERAGE` in **Active Compilation Conditions** for its Coverage Debug configuration and use `#if INTERNAL_COVERAGE`; the SDK does not require any particular host flag.

## 3. Start and navigate

Call the facade once from the app's established startup path:

```swift
#if INTERNAL_COVERAGE
import CodeCoverageKit

if CodeCoverage.isAvailable {
    CodeCoverage.start()
}
#endif
```

Expose the built-in console from an existing debug menu:

```swift
#if INTERNAL_COVERAGE
let controller = CodeCoverage.makeConsoleViewController()
navigationController?.pushViewController(controller, animated: true)
#endif
```

`isAvailable` validates Bundle metadata without exposing its token. `start()` is idempotent, restores local records and captures locally; it does not make a network request.

## 4. Prepare and inject metadata

Create a `CoverageProject.json` in the host repository and run `coveragectl prepare`. Add a host build phase that copies the path in the configured metadata build setting into the app Bundle as `CodeCoverageBuildMetadata.json`. A minimal phase is:

```sh
set -eu
destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/CodeCoverageBuildMetadata.json"
source_path="${CODE_COVERAGE_METADATA_SOURCE:-}"

if [ -z "${source_path}" ]; then
  /bin/rm -f "${destination}"
  exit 0
fi

if [ "${CONFIGURATION}" != "Debug" ] || [ ! -f "${source_path}" ]; then
  echo "error: invalid Coverage metadata input" >&2
  exit 1
fi

/bin/mkdir -p "$(/usr/bin/dirname "${destination}")"
/usr/bin/install -m 0644 "${source_path}" "${destination}"
```

Declare the metadata setting as an input when the host build system requires explicit script inputs. The build phase must fail when a Coverage build requests metadata but the source is absent or invalid, and must remove stale output when no metadata source was supplied.

Follow the complete sequence in [Build and Metadata](BuildAndMetadata.md). A normal Debug or Release build must not inject metadata or a token.

The current tool exposes the real two-phase commands below; replace only paths and identifiers:

```bash
/path/to/coveragectl prepare \
  --project-config /path/to/CoverageProject.json \
  --cycle-id <cycle-id> \
  --context <empty-owner-only-directory> \
  --result-root /path/to/CoverageBuilds \
  --developer-dir /path/to/Xcode.app/Contents/Developer \
  --operator-token-file /path/to/operator-token \
  --run-token-file /path/to/restricted-run-token

# Archive with the metadata path emitted by prepare, then:
/path/to/coveragectl register \
  --project-config /path/to/CoverageProject.json \
  --context <same-context-directory> \
  --archive /path/to/App.xcarchive \
  --operator-token-file /path/to/operator-token \
  --run-token-file /path/to/restricted-run-token

# After the host exports its IPA:
/path/to/coveragectl verify-ipa \
  --context <same-context-directory> \
  --ipa /path/to/App.ipa \
  --expect-metadata
```

Choose an Xcode version supported by the host project and use the same Developer directory for context preparation and Archive creation.

## 5. Validate on device

1. Install the registered Coverage Debug IPA without uninstalling an older test build when pending preservation is under test.
2. Open the console and verify the expected Cycle and Build identifiers.
3. Confirm launch and background transitions increase pending while the server Run count remains unchanged.
4. Kill and relaunch the app; pending must remain.
5. Run health and the no-business-data probe.
6. Tap upload once; the SDK creates a fresh snapshot and uploads all pending records.
7. Confirm pending reaches zero, failed remains zero, and the latest Run is analyzable in the service.
8. Open the report URL provided by the Coverage service and confirm the registered Build and latest Run appear. The SDK does not invent or discover a report URL.

Local-network permission is controlled by iOS. If the system asks, grant it normally; the SDK does not bypass it.
