// swift-tools-version: 6.2
import PackageDescription

// The iOS app's command recognition, run on the Mac against spoken clips.
// `Sources/drive-commands/Shared/` holds symbolic links to the app's own files in
// `ios/SpeakUp/Drive/`, so this tool runs the exact code the app ships.
let package = Package(
    name: "drive-commands",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "drive-commands")
    ]
)
