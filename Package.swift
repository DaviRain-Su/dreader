// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DReader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DReader", targets: ["DReader"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DReader",
            dependencies: [],
            path: "Sources/DReader"
        )
    ]
)
