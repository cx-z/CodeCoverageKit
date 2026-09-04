# Contributing

Use the build machine's selected Xcode unless the host project requires a specific version, and keep changes within the established ownership boundaries. Every new or modified Swift, Objective-C or C method/function requires an accurate method-level comment. Shared mutable state must remain behind the collector queue, an actor or an equally explicit synchronization boundary; UIKit state belongs on the main actor.

Before requesting review:

```bash
xcrun swift test --enable-code-coverage

xcrun swift build -c release
```

Set `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer` on both commands when validating against a non-default Xcode.

Also build the iOS package scheme and at least one real host through its workspace. Changes to persistence, metadata, multipart fields, response validation, token handling or lifecycle behavior require focused tests and a written compatibility assessment.

Do not commit `.build`, DerivedData, result bundles, profiles, tokens, generated metadata, Archives or IPA files. Never place operator or restricted Run tokens in source, fixtures, logs or issue reports.

The Package currently has no remote or release tag. Do not invent a dependency URL or publish from a developer machine until repository ownership and release policy are approved.
