// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "AudioJackMIDI",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AudioJackMIDI", targets: ["AudioJackMIDI"])],
    targets: [
        .target(name: "TransportCore", publicHeadersPath: "include"),
        .executableTarget(name: "AudioJackMIDI", dependencies: ["TransportCore"],
            linkerSettings: [.linkedFramework("CoreMIDI"), .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio")]),
        .testTarget(name: "AudioJackMIDITests", dependencies: ["AudioJackMIDI", "TransportCore"])
    ]
)
