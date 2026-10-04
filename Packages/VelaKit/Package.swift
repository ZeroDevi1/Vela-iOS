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
    targets: [
        .target(name: "VelaCore"),
        .target(name: "VelaNetwork", dependencies: ["VelaCore"]),
        .target(name: "VelaData", dependencies: ["VelaCore", "VelaNetwork"]),
        .target(name: "VelaPlayer", dependencies: ["VelaCore"]),
        .target(name: "VelaDesignSystem", dependencies: ["VelaCore"]),
        .target(
            name: "VelaFeatures",
            dependencies: ["VelaCore", "VelaNetwork", "VelaData", "VelaPlayer", "VelaDesignSystem"]
        ),
        .testTarget(name: "VelaCoreTests", dependencies: ["VelaCore"]),
        .testTarget(name: "VelaNetworkTests", dependencies: ["VelaNetwork"]),
        .testTarget(name: "VelaPlayerTests", dependencies: ["VelaPlayer"])
    ],
    swiftLanguageModes: [.v6]
)
