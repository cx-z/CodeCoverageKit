# Build and Metadata

## Responsibility split

`coveragectl` owns Cycle/Build/Git context, neutral metadata creation, Archive inspection, Mach-O/dSYM identity checks, artifact hashing, Build registration and GET verification. The host owns `xcodebuild archive`, signing, IPA export and distribution. `CodeCoverageKit` reads the injected metadata and later uploads only Run metadata, SHA-256 and `.profraw`.

An iOS process cannot reliably read the developer's Git checkout or MR, run `xcodebuild`, inspect a Mac `.xcarchive`, execute `dwarfdump`, or upload the registered executable and dSYM. Those operations therefore remain in `coveragectl`; moving them into the SDK would make binary identity unverifiable.

## Project configuration

Create `CoverageProject.json` at the host repository root:

```json
{
  "schema_version": 1,
  "project": "ExampleProject",
  "workspace": "ExampleApp.xcworkspace",
  "scheme": "ExampleApp",
  "configuration": "Debug",
  "metadata_build_setting": "CODE_COVERAGE_METADATA_SOURCE",
  "remote": "origin"
}
```

Do not place service URLs, tokens, Cycle IDs, Build IDs or Git SHAs in this tracked file.

## Archive sequence

Use an owner-only temporary context and separate token files:

```bash
coveragectl prepare \
  --project-config /path/to/CoverageProject.json \
  --cycle-id <cycle-id> \
  --context <owner-only-context-directory> \
  --result-root /path/to/CoverageBuilds \
  --developer-dir /path/to/Xcode.app/Contents/Developer \
  --packaging-token-file /path/to/packaging-token \
  --run-token-file /path/to/restricted-run-token

DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
xcodebuild archive \
  -workspace ExampleApp.xcworkspace \
  -scheme ExampleApp \
  -configuration Debug \
  -archivePath /path/to/ExampleApp.xcarchive \
  CODE_COVERAGE_METADATA_SOURCE=<metadata-path-from-prepare>

coveragectl register \
  --project-config /path/to/CoverageProject.json \
  --context <same-context-directory> \
  --archive /path/to/ExampleApp.xcarchive \
  --packaging-token-file /path/to/packaging-token \
  --run-token-file /path/to/restricted-run-token
```

Choose an Xcode version supported by the host project and pass its Developer directory consistently to `coveragectl prepare` and the host Archive command.

Register must succeed and its GET verification must match before distributing the IPA. `coveragectl inspect-archive` can validate sections and UUIDs without registration. After export, use `coveragectl verify-ipa --context <context> --ipa <ipa> --expect-metadata` to prove the IPA contains exactly the prepared metadata.

## Metadata contract

The app Bundle resource is `CodeCoverageBuildMetadata.json`, schema version 1. Required fields are:

```text
schema_version
project
cycle_id
build_id
git_sha
target_sha_at_build
merge_base_sha
bundle_id
app_version
bundle_version
xcode_version
coverage_server_url
run_upload_token
```

`cycle_id` and `build_id` are UUIDs. A developer obtains `cycle_id` by submitting the MR in the platform Web UI. The build Mac uses a packaging-scope token only for known-Cycle and Build APIs; it is never written into metadata or the IPA. The service root must pass the SDK's LAN-only validation. The restricted Run token is required and is distributed inside the internal Coverage IPA; it is not a packaging/operator credential and the SDK never displays it.

Dynamic metadata must remain in temporary/build output, never in tracked source. The SDK reads only the neutral metadata filename and does not infer host-specific alternatives.

## Isolation checks

- Ordinary Debug: no metadata resource and no distributed token; the facade reports unavailable.
- Coverage Debug: metadata exists and matches the registered Archive context.
- Release: no metadata, token, debug entry or callable SDK facade.
- Host app target: coverage mapping enabled only where intended; do not force it on every dependency target.
