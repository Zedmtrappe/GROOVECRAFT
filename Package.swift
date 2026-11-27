// swift-tools-version:5.9
//
// Groovecraft — intelligent drum MIDI humanisation for macOS.
//
// GrooveCore is platform-independent Swift (Foundation only): MIDI files, drum mapping,
// the humanisation and groove engines, backing-track analysis, playback scheduling and the
// preview drum synth. It is unit tested on its own (also on Linux).
// The macOS app (GroovecraftApp: SwiftUI, AppKit, CoreMIDI, AVFoundation) is built through
// the Xcode project generated from `project.yml` (see Docs/BUILDING.md).

import PackageDescription

let package = Package(
    name: "Groovecraft",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GrooveCore", targets: ["GrooveCore"]),
    ],
    targets: [
        .target(name: "GrooveCore"),
        .testTarget(name: "GrooveCoreTests", dependencies: ["GrooveCore"]),
    ]
)
