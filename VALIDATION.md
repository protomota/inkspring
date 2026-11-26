# Validating Inkspring

Run `swift test --package-path native-mac` for the macOS suite. Build a local bundle with `native-mac/build-app.sh`. Use a disposable workspace for UI and MCP tests, as described in the [native guide](native-mac/README.md#build-and-open).

For a release, verify the signed Mac bundle and installer, the update feed, and the companion's production iCloud connection. Provider fixtures cover request and state handling; real account sign-in and delivery are separate checks.
