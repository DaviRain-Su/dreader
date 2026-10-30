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
        // Vendored libmobi 0.12 (LGPL-3.0-or-later, https://github.com/bfabiszewski/libmobi)。
        // 静态链接：仓库附带 COPYING-LGPL 与版本说明，源码可得即满足其重链接义务。
        .target(
            name: "Cmobi",
            path: "Vendor/Cmobi",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "DReader",
            dependencies: ["Cmobi"],
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
            path: "Tests/DReaderTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
