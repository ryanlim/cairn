fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios generate

```sh
[bundle exec] fastlane ios generate
```

Regenerate Cairn.xcodeproj from project.yml (requires xcodegen)

### ios ship_version

```sh
[bundle exec] fastlane ios ship_version
```

Cut a new marketing version end-to-end: bump → commit → TestFlight upload → annotated git tag → push tag.
Usage: bundle exec fastlane ship_version to:0.2.0 notes:"Offline retry queue + About screen"

### ios bump_version

```sh
[bundle exec] fastlane ios bump_version
```

Bump marketing version (CFBundleShortVersionString) — usage: bundle exec fastlane bump_version to:0.2.0

### ios bump_build

```sh
[bundle exec] fastlane ios bump_build
```

Bump CFBundleVersion based on TestFlight latest

### ios test

```sh
[bundle exec] fastlane ios test
```

Run all Swift Package tests

### ios build

```sh
[bundle exec] fastlane ios build
```

Build a release IPA

### ios build_ipa

```sh
[bundle exec] fastlane ios build_ipa
```

Run tests + bump build + build the IPA

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Upload to TestFlight

### ios status

```sh
[bundle exec] fastlane ios status
```

List recent TestFlight builds and their processing state

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Push App Store listing metadata + screenshots without rebuilding

### ios release

```sh
[bundle exec] fastlane ios release
```

Upload to App Store

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Capture App Store + README screenshots

### ios setup_certificates

```sh
[bundle exec] fastlane ios setup_certificates
```

Setup certificates and provisioning profiles via match

### ios sync_certificates

```sh
[bundle exec] fastlane ios sync_certificates
```

Sync certificates (readonly — for CI / fresh machines)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
