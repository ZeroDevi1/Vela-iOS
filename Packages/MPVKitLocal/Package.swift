// swift-tools-version: 5.9
import PackageDescription

/// MPVKit 1.0.0（LGPL）的本地镜像：结构与上游 Package.swift 一致，只是二进制改为本地路径。
///
/// 二进制由 `scripts/fetch-mpvkit.sh` 下载并校验（不入库）。改用本地路径的原因：部分网络环境下
/// SwiftPM 的二进制下载器会卡住。上游：https://github.com/mpvkit/MPVKit
let package = Package(
    name: "MPVKit",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "MPVKit", targets: ["_MPVKit"])
    ],
    targets: [
        .target(
            name: "_MPVKit",
            dependencies: [
                "Libmpv", "_FFmpeg", "Libuchardet", "Libbluray",
                .target(name: "Libluajit", condition: .when(platforms: [.macOS]))
            ],
            path: "Sources/_MPVKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .target(
            name: "_FFmpeg",
            dependencies: ["Libavcodec", "Libavdevice", "Libavfilter", "Libavformat", "Libavutil", "Libswresample", "Libswscale", "Libssl", "Libcrypto", "Libass", "Libfreetype", "Libfribidi", "Libharfbuzz", "MoltenVK", "Libshaderc_combined", "lcms2", "Libplacebo", "Libdovi", "Libunibreak", "gmp", "nettle", "hogweed", "gnutls", "Libdav1d", "Libuavs3d"],
            path: "Sources/_FFmpeg",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++")
            ]
        ),
        .binaryTarget(name: "Libass", path: "Frameworks/Libass.xcframework"),
        .binaryTarget(name: "Libavcodec", path: "Frameworks/Libavcodec.xcframework"),
        .binaryTarget(name: "Libavdevice", path: "Frameworks/Libavdevice.xcframework"),
        .binaryTarget(name: "Libavfilter", path: "Frameworks/Libavfilter.xcframework"),
        .binaryTarget(name: "Libavformat", path: "Frameworks/Libavformat.xcframework"),
        .binaryTarget(name: "Libavutil", path: "Frameworks/Libavutil.xcframework"),
        .binaryTarget(name: "Libbluray", path: "Frameworks/Libbluray.xcframework"),
        .binaryTarget(name: "Libcrypto", path: "Frameworks/Libcrypto.xcframework"),
        .binaryTarget(name: "Libdav1d", path: "Frameworks/Libdav1d.xcframework"),
        .binaryTarget(name: "Libdovi", path: "Frameworks/Libdovi.xcframework"),
        .binaryTarget(name: "Libfreetype", path: "Frameworks/Libfreetype.xcframework"),
        .binaryTarget(name: "Libfribidi", path: "Frameworks/Libfribidi.xcframework"),
        .binaryTarget(name: "Libharfbuzz", path: "Frameworks/Libharfbuzz.xcframework"),
        .binaryTarget(name: "Libluajit", path: "Frameworks/Libluajit.xcframework"),
        .binaryTarget(name: "Libmpv", path: "Frameworks/Libmpv.xcframework"),
        .binaryTarget(name: "Libplacebo", path: "Frameworks/Libplacebo.xcframework"),
        .binaryTarget(name: "Libshaderc_combined", path: "Frameworks/Libshaderc_combined.xcframework"),
        .binaryTarget(name: "Libssl", path: "Frameworks/Libssl.xcframework"),
        .binaryTarget(name: "Libswresample", path: "Frameworks/Libswresample.xcframework"),
        .binaryTarget(name: "Libswscale", path: "Frameworks/Libswscale.xcframework"),
        .binaryTarget(name: "Libuavs3d", path: "Frameworks/Libuavs3d.xcframework"),
        .binaryTarget(name: "Libuchardet", path: "Frameworks/Libuchardet.xcframework"),
        .binaryTarget(name: "Libunibreak", path: "Frameworks/Libunibreak.xcframework"),
        .binaryTarget(name: "MoltenVK", path: "Frameworks/MoltenVK.xcframework"),
        .binaryTarget(name: "gmp", path: "Frameworks/gmp.xcframework"),
        .binaryTarget(name: "gnutls", path: "Frameworks/gnutls.xcframework"),
        .binaryTarget(name: "hogweed", path: "Frameworks/hogweed.xcframework"),
        .binaryTarget(name: "lcms2", path: "Frameworks/lcms2.xcframework"),
        .binaryTarget(name: "nettle", path: "Frameworks/nettle.xcframework"),
    ]
)
