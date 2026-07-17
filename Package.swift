// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LingShuMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // 可执行产物（进程名/菜单栏应用名）用中文「灵枢」；内部模块名仍是 LingShuMac，
        // 以保持 @testable import 与测试目标不变。
        .executable(name: "灵枢", targets: ["LingShuMac"]),
        // 外部自动化只通过本机控制面进入同一条主会话，不复制分诊、记忆或执行逻辑。
        .executable(name: "lingshu", targets: ["LingShuCLI"])
    ],
    targets: [
        .executableTarget(
            name: "LingShuMac",
            dependencies: ["LingShuAudioExceptionCatcher"],
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
        .target(
            name: "LingShuAudioExceptionCatcher",
            path: "SourcesObjC/LingShuAudioExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LingShuCLIKit",
            path: "SourcesCLIKit"
        ),
        .executableTarget(
            name: "LingShuCLI",
            dependencies: ["LingShuCLIKit"],
            path: "SourcesCLI"
        ),
        .testTarget(
            name: "LingShuMacTests",
            dependencies: ["LingShuMac", "LingShuCLIKit"],
            path: "Tests/LingShuMacTests"
        )
    ]
)
