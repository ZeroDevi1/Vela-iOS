// swift-tools-version: 6.2
import PackageDescription

/// 模块依赖方向（只允许自上而下）：
/// VelaFeatures → VelaData / VelaPlayer / VelaDesignSystem → VelaNetwork → VelaCore
/// App target 只依赖 VelaFeatures，自身只负责 Scene、菜单命令与资源。
let package = Package(
    name: "VelaKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0")
    ],
    products: [
        .library(name: "VelaFeatures", targets: ["VelaFeatures"])
    ],
    dependencies: [
        // 第二播放内核 KSPlayer（FFmpeg + VideoToolbox + Metal，GPL-3.0），与本项目 GPLv3 兼容。
        // 本地镜像：由 scripts/fetch-ksplayer.sh 拉取到 Packages/KSPlayer 与 Packages/FFmpegKit。
        .package(path: "../KSPlayer"),
        // libmpv 由 FFmpegKit 提供（与 KSPlayer 共用同一份 FFmpeg，无符号冲突）。
        .package(path: "../FFmpegKit"),
        // VLC 内核：VideoLAN 官方 VLCKit 4（LGPL-2.1，动态库），由 scripts/fetch-vlckit.sh 拉取到 Packages/VLCKit。
        .package(path: "../VLCKit")
    ],
    targets: [
        .target(name: "VelaCore"),
        .target(name: "VelaNetwork", dependencies: ["VelaCore"]),
        .target(name: "VelaData", dependencies: ["VelaCore", "VelaNetwork"]),
        .target(name: "VelaPlayer", dependencies: [
            "VelaCore",
            .product(name: "KSPlayer", package: "KSPlayer"),
            .product(name: "libmpv", package: "FFmpegKit"),
            .product(name: "VLCKit", package: "VLCKit")
        ]),
        .target(name: "VelaDesignSystem", dependencies: ["VelaCore"]),
        .target(
            name: "VelaFeatures",
            dependencies: ["VelaCore", "VelaNetwork", "VelaData", "VelaPlayer", "VelaDesignSystem"]
        ),
        .testTarget(name: "VelaCoreTests", dependencies: ["VelaCore"]),
        .testTarget(name: "VelaNetworkTests", dependencies: ["VelaNetwork"]),
        .testTarget(
            name: "VelaPlayerTests",
            dependencies: ["VelaPlayer"],
            resources: [.copy("Resources")],
            // VLCKit 是二进制动态框架，`swift test` 把它放在 Products/Debug 下，测试包默认的 rpath 找不到：
            // 测试可执行文件位于 Products/Debug/VelaPlayerTests.xctest/Contents/MacOS，向上三级即框架目录。
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])]
        )
    ],
    swiftLanguageModes: [.v6]
)
