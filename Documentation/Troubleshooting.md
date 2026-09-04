# Troubleshooting

## `CodeCoverage.isAvailable` is false

Inspect the built `.app`, not only the source tree. Confirm `CodeCoverageBuildMetadata.json` exists in the Bundle, uses schema 1, contains valid UUIDs and a private/LAN service root, and was generated for this exact Build. Ordinary Debug and Release are expected to be unavailable.

## No `.profraw` is created

Confirm the app target was compiled and linked with `ENABLE_CODE_COVERAGE=YES` and `CLANG_COVERAGE_MAPPING=YES`. Inspect the final executable for `__llvm_covmap` and `__llvm_prf_*` sections. A successful SDK compile alone does not instrument the host executable.

## Upload is unavailable

Confirm valid Build metadata is present, the console is running in a Debug-enabled package build, no upload batch is already active, and a valid LAN service URL can be constructed. The button does not manufacture a missing token or Build identity.

## Health or probe times out

Try the same `/health` URL in Safari on that device. Confirm the service listens on a LAN interface, the Mac firewall permits it, both devices share a reachable AP/VLAN, no VPN or relay changes the route, and iOS Settings allows Local Network access for the app. A Safari failure indicates reachability below the SDK protocol layer.

If Safari succeeds but the app reports an ATS error, inspect the host's Debug `Info.plist` transport-security policy and the URL scheme. Keep any exception scoped to the internal build and intended LAN endpoint; do not disable transport security globally as an SDK workaround.

Do not bypass the iOS local-network permission prompt. Switching Wi-Fi bands or devices may isolate an AP-specific problem, but is not an SDK fix.

## Pending survives but upload fails

Use the console category and message:

- 401/403: the IPA token does not belong to the current service; the batch stops.
- 409: Run identity conflicts permanently; preserve evidence and inspect service state.
- 413: payload exceeds the service limit.
- 422 or echo mismatch: profile bytes, declared SHA or response identity failed validation.
- network/5xx: retry through a new explicit user upload after connectivity recovers.

Never delete Application Support as the first diagnostic step; it destroys the pending evidence being investigated.

## Overwrite installation and uninstall differ

An overwrite install keeps the app container, so saved URLs and pending Runs remain. Uninstalling removes the sandbox and its local pending records. Server-side Builds and already uploaded Runs are unaffected by either action.

## Build is registered but the report is stale

First confirm a Run for the same Build is `uploaded` and analyzable; Build registration alone contains no execution profile. Then inspect the service's background-analysis state and report refresh behavior. Do not re-upload executable or dSYM artifacts from the phone and do not alter Run identity to force a match.

## Release unexpectedly exposes APIs

Build the host in Release and inspect the final `.app` for `CodeCoverageKit` symbols, Coverage Build metadata and token. SwiftPM guards implementation source but cannot condition a product dependency by build configuration; use a Debug-scoped CocoaPods dependency when Release must physically exclude the SDK. A host-created wrapper that leaks into Release remains the host's responsibility.
