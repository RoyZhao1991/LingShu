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
            path: "Sources",
            linkerSettings: [
                // 把 Info.plist 嵌入可执行文件的 __TEXT,__info_plist 段，
                // 这样 `swift run` / .build 产物也带相机、麦克风、语音识别的
                // 隐私用途说明；缺这些 key 时 TCC 会在首次访问时直接 SIGABRT。
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/LingShuMac-Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "LingShuMacTests",
            dependencies: ["LingShuMac"],
            path: "Tests/LingShuMacTests"
        )
    ]
)
