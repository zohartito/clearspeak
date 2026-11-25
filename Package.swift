// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClearSpeak",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClearSpeak", targets: ["ClearSpeak"])],
    targets: [
        .target(name: "ClearSpeakCore", resources: [.process("Resources")]),
        .executableTarget(name: "ClearSpeak", dependencies: ["ClearSpeakCore"]),
        .executableTarget(name: "ClearSpeakChecks", dependencies: ["ClearSpeakCore"], path: "Checks")
    ]
)
