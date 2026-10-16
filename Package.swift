// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kuma",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kuma", targets: ["Kuma"]),
        .executable(name: "kuma-hook", targets: ["KumaHook"]),
    ],
    targets: [
        .target(name: "KumaCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "KumaHook", dependencies: ["KumaCore"]),
        .executableTarget(name: "Kuma", dependencies: ["KumaCore"]),
        .testTarget(name: "KumaCoreTests", dependencies: ["KumaCore"]),
    ]
)
