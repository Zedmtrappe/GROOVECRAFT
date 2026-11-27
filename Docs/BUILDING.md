# Building Groovecraft

## Engine (any platform)

The engine (`Sources/GrooveCore`) is plain Swift and has its own tests:

```
swift test
```

On Linux without Swift installed, Docker works:
`docker run --rm -v "$PWD":/src -w /src swift:6.0-noble swift test`.

## The macOS app

Needs macOS 14+, Xcode 15+ and XcodeGen (`brew install xcodegen`).

```
xcodegen generate
open Groovecraft.xcodeproj
```

Run the **Groovecraft** scheme.

## Builds on the owner's Mac

`.github/workflows/build-macos.yml` runs on a self-hosted runner registered **for this
repository**, with the labels `self-hosted, macOS, ARM64`. A runner registered for another
repository can't pick up jobs from this one, so a second runner is needed:

1. GitHub ▸ this repository ▸ Settings ▸ Actions ▸ Runners ▸ **New self-hosted runner** ▸ macOS, ARM64.
2. Follow the commands shown there, but in a **new folder** (for example `~/actions-runner-groovecraft`),
   so it doesn't disturb any existing runner.
3. Run `./svc.sh install && ./svc.sh start` in that folder so it starts with the Mac.

Then: Actions ▸ **Build Groovecraft (macOS)** ▸ Run workflow. The zipped app is copied to
`~/Downloads/Groovecraft builds`.

The app is ad-hoc signed. On first launch, right-click it ▸ Open (or allow it in
System Settings ▸ Privacy & Security).
