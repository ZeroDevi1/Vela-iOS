import AVFoundation
import CoreVideo
import MetalKit
import SwiftUI
import VelaCore

/// VR 转平面的画面来源：系统内核从 `AVPlayerItemVideoOutput` 取帧，KSPlayer 内核直接读取其解码帧。
@MainActor
protocol VRFrameSource: AnyObject {
    /// 有新帧时返回，否则 nil（继续显示上一帧）。
    func nextFrame(hostTime: CFTimeInterval) -> CVPixelBuffer?
    /// 内核正在播放（缓冲 / 暂停时没有新帧是正常的，不计入首帧超时）。
    var isPlaying: Bool { get }
    /// 长时间没有画面时的附加诊断（条目错误、画面尺寸、解码能力等）。
    func diagnosis() -> [String]
    func detach()
}

/// 系统内核：给当前 `AVPlayerItem` 挂视频输出；条目替换（切集、切换码流）时迁移到新条目。
///
/// 输出为 8 位 BT.709 视频范围 YUV 双平面：VR 片源多为 8K SDR HEVC，与解码器输出格式一致时系统不做逐帧转换
/// （此前要求 BGRA，8K 每帧约 120 MB 的颜色转换会拖慢起播与播放）；HDR 片源由系统色调映射到 BT.709。
@MainActor
final class AVPlayerVRFrameSource: VRFrameSource {
    private weak var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private var itemObservation: NSKeyValueObservation?

    /// 必须声明 Metal 兼容（IOSurface 支持），否则 `CVMetalTextureCacheCreateTextureFromImage` 失败、画面全黑。
    nonisolated static var attributes: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
    }

    /// 视频输出设置：像素格式 + 固定 BT.709 色彩，着色器据此用固定矩阵转 RGB。
    nonisolated private static var outputSettings: [String: Any] {
        attributes.merging([
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]) { current, _ in current }
    }

    init(player: AVPlayer) {
        self.player = player
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor in self?.attachOutput(to: item) }
        }
    }

    var isPlaying: Bool { player?.timeControlStatus == .playing }

    func nextFrame(hostTime: CFTimeInterval) -> CVPixelBuffer? {
        guard let output else { return nil }
        let time = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: time),
              let frame = output.pixelBufferAndDisplayTime(forItemTime: time).pixelBuffer else { return nil }
        // 纹理只在主线程的渲染回调中创建与使用；闭包内写入局部变量，避免跨隔离域返回非 Sendable 值。
        // 只读语义由调用方保证：渲染器只读取像素，不修改缓冲区。
        nonisolated(unsafe) var buffer: CVPixelBuffer?
        frame.withUnsafeBuffer { buffer = $0 }
        return buffer
    }

    func diagnosis() -> [String] {
        guard let item = attachedItem else { return [] }
        var parts: [String] = []
        if let error = item.error { parts.append("条目错误：\(error.localizedDescription)") }
        let size = item.presentationSize
        parts.append(size == .zero ? "系统解码器没有输出画面（常见原因：分辨率超过本机硬解上限，如 8192 宽的 8K；或 HEVC 标签为 hev1）" : "画面 \(Int(size.width))×\(Int(size.height))")
        if let track = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }), !track.isEnabled {
            parts.append("视频轨未启用")
        }
        return parts
    }

    func detach() {
        itemObservation = nil
        attachOutput(to: nil)
        player = nil
    }

    private func attachOutput(to item: AVPlayerItem?) {
        if let attachedItem, let output { attachedItem.remove(output) }
        attachedItem = nil
        output = nil
        guard let item else { return }
        let output = AVPlayerItemVideoOutput(outputSettings: Self.outputSettings)
        item.add(output)
        self.output = output
        attachedItem = item
    }
}

/// KSPlayer 内核：读取其最近一帧解码画面（VideoToolbox 输出的 IOSurface 缓冲区，零拷贝）。
@MainActor
final class KSPlayerVRFrameSource: VRFrameSource {
    private weak var engine: KSPlayerEngine?
    private var lastFrame: CVPixelBuffer?

    init(engine: KSPlayerEngine) {
        self.engine = engine
    }

    var isPlaying: Bool { engine?.status == .playing }

    func nextFrame(hostTime: CFTimeInterval) -> CVPixelBuffer? {
        guard let frame = engine?.currentPixelBuffer(), frame !== lastFrame else { return nil }
        lastFrame = frame
        return frame
    }

    func diagnosis() -> [String] {
        guard let engine else { return [] }
        let size = engine.videoSize
        if size == .zero { return ["解码器没有输出画面"] }
        return ["画面 \(Int(size.width))×\(Int(size.height))", "当前为软解或解码帧格式不受支持，VR 需要硬解（设置 → 解码）"]
    }

    func detach() {
        engine = nil
        lastFrame = nil
    }
}

/// VR 转平面渲染：逐帧从画面来源取图，经 Metal 反投影为普通 2D 画面（取左眼）。
///
/// 只在开启「VR 转平面」时创建；关闭或切换内核时移除。
/// 支持 8 / 10 位 YUV 双平面、8 位 YUV 三平面（视频范围 / 全范围）与 BGRA 帧；YUV 按 BT.709 转 RGB。
@MainActor
final class VRRenderer: NSObject, MTKViewDelegate {
    var layout: VRLayout
    var state = VRViewState()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    /// 最近一帧的纹理；GPU 使用期间必须保持 CVMetalTexture 存活。
    private var currentFrame: VRFrameTextures?

    private var source: VRFrameSource?
    private var loggedTextureFailure = false
    /// 诊断：开始等待首帧的时刻（挂载来源或开始播放时重置），以及已上报的问题。
    private var waitingSince: CFTimeInterval?
    private var reportedIssue: String?
    /// 画面问题变化时回调（nil 表示已正常出画面）。
    var onIssue: ((String?) -> Void)?
    /// 播放中超过该时长仍没有任何画面即视为失败并提示原因（秒）。8K 片源首帧本身较慢，留足余量。
    private static let firstFrameTimeout: CFTimeInterval = 6

    init?(layout: VRLayout) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vr_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "vr_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Log.player.error("VR 着色器编译失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.device = device
        self.queue = queue
        self.layout = layout
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = self
        return view
    }

    /// 绑定画面来源（内核替换时由视图重建）。
    func attach(_ source: VRFrameSource) {
        self.source?.detach()
        self.source = source
        currentFrame = nil
        waitingSince = nil
        report(nil)
    }

    func detach() {
        source?.detach()
        source = nil
        currentFrame = nil
    }

    // MARK: - MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        updateTexture()
        diagnose()
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        if let currentFrame, let luma = CVMetalTextureGetTexture(currentFrame.luma) {
            let chroma = currentFrame.chroma.flatMap(CVMetalTextureGetTexture) ?? luma
            let chromaRed = currentFrame.chromaRed.flatMap(CVMetalTextureGetTexture) ?? chroma
            var params = uniforms(viewSize: view.drawableSize, mode: currentFrame.mode)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)
            encoder.setFragmentTexture(chromaRed, index: 2)
            encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func updateTexture() {
        guard let source, let cache = textureCache,
              let frame = source.nextFrame(hostTime: CACurrentMediaTime()) else { return }
        switch Self.makeTextures(from: frame, cache: cache) {
        case .success(let textures):
            currentFrame = textures
            report(nil)
        case .failure(let failure):
            guard !loggedTextureFailure else { return }
            loggedTextureFailure = true
            Log.player.error("VR 纹理创建失败：\(failure.message, privacy: .public)")
            report("VR 纹理创建失败（\(failure.message)）")
        }
    }

    /// 播放中长时间没有画面：汇总来源给出的原因，让界面提示而不是一直黑屏。
    private func diagnose() {
        guard currentFrame == nil, reportedIssue == nil, let source else {
            if currentFrame != nil { waitingSince = nil }
            return
        }
        // 只在真正播放时计时：缓冲 / 暂停期间没有新帧是正常的。
        guard source.isPlaying else {
            waitingSince = nil
            return
        }
        let now = CACurrentMediaTime()
        guard let since = waitingSince else {
            waitingSince = now
            return
        }
        guard now - since > Self.firstFrameTimeout else { return }
        let message = (["VR 转平面没有收到视频画面"] + source.diagnosis()).joined(separator: "；")
        Log.player.error("\(message, privacy: .public)")
        report(message)
    }

    private func report(_ issue: String?) {
        guard issue != reportedIssue else { return }
        reportedIssue = issue
        onIssue?(issue)
    }

    /// 一帧画面对应的纹理与着色器取色方式。
    struct VRFrameTextures {
        var luma: CVMetalTexture
        /// 双平面时为 CbCr 交错平面；三平面时为 Cb 平面；BGRA 帧为 nil。
        var chroma: CVMetalTexture?
        /// 三平面（I420）的 Cr 平面；其余格式为 nil。
        var chromaRed: CVMetalTexture? = nil
        /// 0：双平面视频范围；1：双平面全范围；2：BGRA（luma 即 RGB 纹理）；3：三平面视频范围；4：三平面全范围。
        var mode: Float
    }

    struct TextureFailure: Error {
        var message: String
    }

    /// 像素缓冲区 → Metal 纹理（共享 IOSurface 内存，不拷贝）。10 位格式按 16 位纹理读取（数据在高 10 位，归一化后与 8 位等价）。
    nonisolated static func makeTextures(from buffer: CVPixelBuffer, cache: CVMetalTextureCache) -> Result<VRFrameTextures, TextureFailure> {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planes: (luma: MTLPixelFormat, chroma: MTLPixelFormat, mode: Float)?
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: planes = (.r8Unorm, .rg8Unorm, 0)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: planes = (.r8Unorm, .rg8Unorm, 1)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: planes = (.r16Unorm, .rg16Unorm, 0)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: planes = (.r16Unorm, .rg16Unorm, 1)
        case kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            // FFmpeg 软解输出的 I420（y420 / f420）：Y、Cb、Cr 三个单通道平面。
            guard CVPixelBufferGetPlaneCount(buffer) == 3 else { return .failure(TextureFailure(message: "平面数异常 \(fourCC(format))")) }
            var textures: [CVMetalTexture] = []
            for plane in 0..<3 {
                var texture: CVMetalTexture?
                let status = CVMetalTextureCacheCreateTextureFromImage(
                    nil, cache, buffer, nil, .r8Unorm,
                    CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture
                )
                guard status == kCVReturnSuccess, let texture else {
                    return .failure(TextureFailure(message: "CVReturn \(status)，像素格式 \(fourCC(format))"))
                }
                textures.append(texture)
            }
            let fullRange = format == kCVPixelFormatType_420YpCbCr8PlanarFullRange
            return .success(VRFrameTextures(luma: textures[0], chroma: textures[1], chromaRed: textures[2], mode: fullRange ? 4 : 3))
        case kCVPixelFormatType_32BGRA:
            var texture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture
            )
            guard status == kCVReturnSuccess, let texture else { return .failure(TextureFailure(message: "CVReturn \(status)")) }
            return .success(VRFrameTextures(luma: texture, chroma: nil, mode: 2))
        default:
            planes = nil
        }
        guard let planes, CVPixelBufferGetPlaneCount(buffer) == 2 else {
            return .failure(TextureFailure(message: "不支持的像素格式 \(fourCC(format))"))
        }
        var luma: CVMetalTexture?
        var chroma: CVMetalTexture?
        var status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, planes.luma,
            CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &luma
        )
        if status == kCVReturnSuccess {
            status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buffer, nil, planes.chroma,
                CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &chroma
            )
        }
        guard status == kCVReturnSuccess, let luma, let chroma else {
            return .failure(TextureFailure(message: "CVReturn \(status)，像素格式 \(fourCC(format))"))
        }
        return .success(VRFrameTextures(luma: luma, chroma: chroma, mode: planes.mode))
    }

    nonisolated private static func fourCC(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : String(code)
    }

    /// 测试用：与系统内核视频输出相同的像素缓冲区属性。
    nonisolated static var pixelBufferAttributes: [String: Any] { AVPlayerVRFrameSource.attributes }

    /// 两个 float4：(aspect, outputFOV, yaw, pitch)、(projection, inputFOV, stereo, 取色方式)。
    private func uniforms(viewSize: CGSize, mode: Float) -> (SIMD4<Float>, SIMD4<Float>) {
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let projection: Float = switch layout.projection {
        case .halfEquirect: 0
        case .equirect: 1
        case .fisheye: 2
        }
        let stereo: Float = switch layout.stereo {
        case .mono: 0
        case .sideBySide: 1
        case .topBottom: 2
        }
        return (
            SIMD4(aspect, Float(state.outputFOV), Float(state.yaw), Float(state.pitch)),
            SIMD4(projection, Float(layout.inputFOV), stereo, mode)
        )
    }

    /// 与 `VRProjection.sourceUV` 相同的公式（该 Swift 版本有单测）。
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 ndc; };

    vertex VOut vr_vertex(uint vid [[vertex_id]]) {
        const float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VOut out;
        out.position = float4(positions[vid], 0, 1);
        out.ndc = positions[vid];
        return out;
    }

    struct Params { float4 a; float4 b; };

    // BT.709 YCbCr → RGB。mode：0 / 1 双平面（视频范围 / 全范围），2 纹理本身为 RGB，3 / 4 三平面（视频范围 / 全范围）。
    static float4 sample_rgb(texture2d<float> luma, texture2d<float> chroma, texture2d<float> chromaRed, sampler s, float2 uv, float mode) {
        if (mode > 1.5 && mode < 2.5) { return float4(luma.sample(s, uv).rgb, 1.0); }
        float y;
        float2 c;
        if (mode > 2.5) {
            float2 raw = float2(chroma.sample(s, uv).r, chromaRed.sample(s, uv).r);
            if (mode > 3.5) {
                y = luma.sample(s, uv).r;
                c = raw - 0.5;
            } else {
                y = (luma.sample(s, uv).r - 16.0 / 255.0) * (255.0 / 219.0);
                c = (raw - 128.0 / 255.0) * (255.0 / 224.0);
            }
        } else if (mode > 0.5) {
            y = luma.sample(s, uv).r;
            c = chroma.sample(s, uv).rg - 0.5;
        } else {
            y = (luma.sample(s, uv).r - 16.0 / 255.0) * (255.0 / 219.0);
            c = (chroma.sample(s, uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
        }
        float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
        return float4(saturate(rgb), 1.0);
    }

    fragment float4 vr_fragment(VOut in [[stage_in]], texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]], texture2d<float> chromaRed [[texture(2)]], constant Params &p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float aspect = p.a.x;
        float2 point = in.ndc;
        point.x *= aspect;
        float tanHalf = tan(p.a.y * M_PI_F / 360.0) / max(aspect, 1.0);
        float3 dir = normalize(float3(point.x * tanHalf, point.y * tanHalf, 1.0));

        float yaw = p.a.z * M_PI_F / 180.0;
        float pitch = p.a.w * M_PI_F / 180.0;
        float cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch);
        float3 pitched = float3(dir.x, dir.y * cp + dir.z * sp, -dir.y * sp + dir.z * cp);
        float3 look = float3(pitched.x * cy + pitched.z * sy, pitched.y, -pitched.x * sy + pitched.z * cy);

        float2 uv;
        if (p.b.x > 1.5) {
            float theta = acos(clamp(look.z, -1.0, 1.0));
            float r = theta / (p.b.y * M_PI_F / 180.0);
            float mag = length(look.xy);
            float2 n = mag > 1e-6 ? look.xy / mag : float2(0.0);
            uv = n * r + 0.5;
            uv.y = 1.0 - uv.y;
        } else {
            float sourceFOV = p.b.x > 0.5 ? 360.0 : max(p.b.y, 1.0);
            float lon = atan2(look.x, look.z);
            float lat = asin(clamp(look.y, -1.0, 1.0));
            uv = float2(lon / (sourceFOV * M_PI_F / 180.0) + 0.5, 0.5 - lat / M_PI_F);
        }
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { return float4(0, 0, 0, 1); }
        if (p.b.z > 1.5) { uv.y *= 0.5; } else if (p.b.z > 0.5) { uv.x *= 0.5; }
        return sample_rgb(luma, chroma, chromaRed, s, uv, p.b.w);
    }
    """
}

/// SwiftUI 包装：VR 模式下覆盖在普通画面之上。
public struct VRVideoView: PlayerPlatformViewRepresentable {
    let controller: PlayerController
    let layout: VRLayout

    public init(controller: PlayerController, layout: VRLayout) {
        self.controller = controller
        self.layout = layout
    }

    public final class Coordinator {
        var renderer: VRRenderer?
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    private func makeView(context: Context) -> PlayerPlatformView {
        guard let renderer = VRRenderer(layout: layout) else {
            // 不支持 Metal（极少数环境）：返回空视图，普通画面仍可见。
            return PlayerPlatformView()
        }
        context.coordinator.renderer = renderer
        let controller = controller
        renderer.onIssue = { [weak controller] issue in controller?.vrIssue = issue }
        switch controller.engine.surface {
        case .avPlayer(let player): renderer.attach(AVPlayerVRFrameSource(player: player))
        case .view: if let engine = controller.engine as? KSPlayerEngine { renderer.attach(KSPlayerVRFrameSource(engine: engine)) }
        }
        return renderer.makeView()
    }

    @MainActor
    private func update(_ view: PlayerPlatformView, context: Context) {
        context.coordinator.renderer?.layout = layout
        context.coordinator.renderer?.state = controller.vrState
        guard let view = view as? MTKView else { return }
        let playing = controller.engine.status == .playing
        // 播放中按屏幕刷新连续绘制；暂停 / 缓冲时改为按需绘制：只在视角变化或定位后重绘，
        // 省掉静止画面上每秒数十次的全屏反投影（GPU 与电量）。
        view.isPaused = !playing
        view.enableSetNeedsDisplay = !playing
        guard !playing else { return }
        // 读取当前位置以便暂停中拖动进度后重绘；新帧可能稍晚送达，补画两次。
        _ = controller.engine.currentTime
        Self.redraw(view)
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                MainActor.assumeIsolated { if let view { Self.redraw(view) } }
            }
        }
    }

    @MainActor
    private static func redraw(_ view: MTKView) {
        #if os(iOS)
        view.setNeedsDisplay()
        #else
        view.needsDisplay = true
        #endif
    }

    #if os(iOS)
    public func makeUIView(context: Context) -> UIView { makeView(context: context) }
    public func updateUIView(_ view: UIView, context: Context) { update(view, context: context) }
    public static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.renderer?.detach() }
    }
    #else
    public func makeNSView(context: Context) -> NSView { makeView(context: context) }
    public func updateNSView(_ view: NSView, context: Context) { update(view, context: context) }
    public static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.renderer?.detach() }
    }
    #endif
}
