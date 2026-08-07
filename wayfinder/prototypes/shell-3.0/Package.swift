// swift-tools-version: 6.1
// PROTOTYPE — throwaway. Not production DroidMate.
// Question: does locked 3.0 visual + shell/IA + motion feel native?

import PackageDescription

let package = Package(
    name: "Shell30Prototype",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Shell30Prototype",
            path: "Sources"
        ),
    ]
)
