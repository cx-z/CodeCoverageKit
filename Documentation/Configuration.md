# Configuration

The SDK does not package an environment-specific server-address configuration file. The effective server URL comes from injected Build metadata or a user-saved override, so hosts do not need to modify SDK sources or resources.

## Server address

The package default comes from `coverage_server_url` in Build metadata. A user may save a replacement URL in the console or restore the Build metadata value. The SDK persists only the normalized URL override under `CodeCoverageKit.server_url`.

Allowed roots are:

- private IPv4: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`;
- link-local IPv4: `169.254.0.0/16`;
- a non-empty `.local` hostname;
- `http` or `https`, optionally with a valid port.

User info, paths other than `/`, query strings, fragments, public IPs and general DNS names are rejected. This prevents a console edit from redirecting `.profraw` uploads to an arbitrary public endpoint.

## Credentials

The restricted Run token is read only from Bundle metadata for each network operation. It is not displayed or persisted in UserDefaults.

The restricted token is still recoverable from an IPA. Treat Coverage IPA files as internal, rotate compromised credentials on the service side, and never substitute an operator token.

## Network behavior

- `/health` is a GET without Authorization.
- `/api/v1/probes` uses the restricted token and uploads a generated JSON file containing no host business data.
- `/api/v1/runs` uses the restricted token and uploads exactly `metadata`, `sha256` and `profile` multipart fields.
- Startup, foreground restore, background capture and manual snapshot do not create network requests.
- Only an explicit upload or probe action creates an authenticated request.

The SDK uses an isolated ephemeral `URLSession`, so host cookies, login state, custom encryption and caches do not affect coverage traffic.
