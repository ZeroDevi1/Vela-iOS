#if DEBUG
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VelaCore

/// 仅 Debug：把视频帧写成 PNG 并在日志中输出路径与帧属性，用于排查画中画等无法截图的画面问题。
enum DebugFrameDump {
    static func write(_ buffer: CVPixelBuffer, name: String) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }, encoding: .ascii) ?? "\(format)"
        let planes = (0..<max(CVPixelBufferGetPlaneCount(buffer), 1)).map { plane in
            "\(CVPixelBufferGetWidthOfPlane(buffer, plane))x\(CVPixelBufferGetHeightOfPlane(buffer, plane))/\(CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))"
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "vela-\(name).png")
        let image = CIImage(cvPixelBuffer: buffer)
        var written = false
        if let cgImage = CIContext().createCGImage(image, from: image.extent),
           let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cgImage, nil)
            written = CGImageDestinationFinalize(destination)
        }
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
        Log.player.debug("帧转储 \(name, privacy: .public)：\(width)x\(height) \(fourCC, privacy: .public) planes=\(planes.joined(separator: ","), privacy: .public) extent=\(String(describing: image.extent), privacy: .public) written=\(written) \(url.path, privacy: .public) attachments=\(attachments.keys.sorted().joined(separator: ","), privacy: .public)")
    }
}
#endif

#if DEBUG && os(macOS)
import AppKit
import AVFoundation

/// 仅 Debug：输出画中画面板（`PIPPanel`）的视图树与图层几何，排查小窗画面错位（小窗由系统进程合成，无法截图）。
enum DebugPictureInPictureLayout {
    @MainActor
    static func dump() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("PIP") || window.title.contains("PIP")
            || window.contentView?.layer.map(containsPlayerLayer) == true {
            var lines = ["窗口 \(type(of: window)) frame=\(window.frame) scale=\(window.backingScaleFactor)"]
            if let view = window.contentView { describe(view, depth: 1, into: &lines) }
            for line in lines { Log.player.debug("PIPDUMP \(line, privacy: .public)") }
        }
    }

    @MainActor
    private static func describe(_ view: NSView, depth: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: depth)
        lines.append("\(pad)\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds)")
        if let layer = view.layer { describe(layer, depth: depth + 1, into: &lines) }
        for sub in view.subviews { describe(sub, depth: depth + 1, into: &lines) }
    }

    private static func containsPlayerLayer(_ layer: CALayer) -> Bool {
        layer is AVPlayerLayer || (layer.sublayers ?? []).contains { containsPlayerLayer($0) }
    }

    private static func describe(_ layer: CALayer, depth: Int, into lines: inout [String]) {
        guard depth < 12 else { return }
        let pad = String(repeating: "  ", count: depth)
        var extra = ""
        if let display = layer as? AVSampleBufferDisplayLayer { extra = " gravity=\(display.videoGravity.rawValue)" }
        let sub = CATransform3DIsIdentity(layer.sublayerTransform) ? "" : " sublayerTransform=m11:\(layer.sublayerTransform.m11) m22:\(layer.sublayerTransform.m22)"
        let t = CATransform3DIsIdentity(layer.transform) ? "id" : "m11:\(layer.transform.m11) m22:\(layer.transform.m22)"
        lines.append("\(pad)· \(type(of: layer)) frame=\(layer.frame) bounds=\(layer.bounds) transform=\(t)\(sub) gravity=\(layer.contentsGravity.rawValue)\(extra)")
        for sub in layer.sublayers ?? [] { describe(sub, depth: depth + 1, into: &lines) }
    }
}
#endif
