// swift-tools-version: 6.1
// DroidMate — macOS side (+ optional MCP server executable)

import PackageDescription

let package = Package(
    name: "DroidMate",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "DroidMateWire", targets: ["DroidMateWire"]),
        .executable(name: "DroidMate", targets: ["DroidMate"]),
        .executable(name: "DroidMateMCP", targets: ["DroidMateMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "DroidMateWire",
            path: "Sources/DroidMateWire"
        ),
        .executableTarget(
            name: "DroidMate",
            dependencies: ["DroidMateWire"],
            path: "Sources/DroidMate",
            resources: [
                .process("Resources"),
                .copy("Bin"),
            ]
        ),
        .executableTarget(
            name: "DroidMateMCP",
            dependencies: [
                "DroidMateWire",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/DroidMateMCP"
        ),
        .testTarget(
            name: "DroidMateTests",
            dependencies: ["DroidMate", "DroidMateWire"],
            path: "Tests/DroidMateTests"
        ),
        .testTarget(
            name: "DroidMateMCPTests",
            dependencies: ["DroidMateMCP"],
            path: "Tests/DroidMateMCPTests"
        ),
        .testTarget(
            name: "DroidMateWireTests",
            dependencies: ["DroidMateWire"],
            path: "Tests/DroidMateWireTests"
        ),
    ]
)
