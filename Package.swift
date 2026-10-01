// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexStatus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexStatus", targets: ["CodexStatusApp"])],
    targets: [
        .target(name: "ProcessInspection", linkerSettings: [.linkedLibrary("proc")]),
        .target(name: "CodexStatusCore", dependencies: ["ProcessInspection"]),
        .executableTarget(name: "CodexStatusApp", dependencies: ["CodexStatusCore"]),
        .testTarget(name: "CodexStatusCoreTests", dependencies: ["CodexStatusCore"]),
        .testTarget(name: "CodexStatusAppTests", dependencies: ["CodexStatusApp"])
    ]
)
