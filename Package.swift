// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LingShuMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LingShuMac", targets: ["LingShuMac"])
    ],
    targets: [
        .executableTarget(
            name: "LingShuMac",
            path: "Sources"
        ),
        .testTarget(
            name: "LingShuMacTests",
            dependencies: ["LingShuMac"],
            path: "Tests/LingShuMacTests"
        )
    ]
)
