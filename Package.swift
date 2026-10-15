// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "TouchM",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TouchMCore", path: "Sources/TouchMCore"),
        .executableTarget(name: "TouchM", dependencies: ["TouchMCore"], path: "Sources/TouchM"),
        .executableTarget(name: "touchm-cli", dependencies: ["TouchMCore"], path: "Sources/touchm-cli"),
        .executableTarget(name: "hidprobe", path: "Sources/hidprobe"),
    ]
)
