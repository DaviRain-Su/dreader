// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DReader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DReader", targets: ["DReader"]),
        .executable(name: "dreader-mcp", targets: ["dreader-mcp"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DReader",
            dependencies: [],
            path: "Sources/DReader"
        ),
        .executableTarget(
            name: "dreader-mcp",
            dependencies: [],
            path: "Sources/dreader-mcp"
        ),
        .testTarget(
            name: "DReaderTests",
            dependencies: ["DReader"],
            path: "Tests/DReaderTests"
        ),
    ]
)
