// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BKSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "bkswitcher", targets: ["BKSwitcher"])
    ],
    targets: [
        .executableTarget(
            name: "BKSwitcher",
            path: "Sources/BKSwitcher"
        )
    ]
)
