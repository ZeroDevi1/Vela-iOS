import AVFoundation
import CoreVideo
import MetalKit
import SwiftUI
import VelaCore

/// VR 转平面渲染：从 `AVPlayerItemVideoOutput` 逐帧取画面，经 Metal 反投影为普通 2D 画面（取左眼）。
///
/// 只在开启「VR 转平面」时挂载视频输出，关闭或切换条目时移除。
/// 输出为 8 位 BT.709 视频范围 YUV 双平面：VR 片源多为 8K SDR HEVC，与解码器输出格式一致时系统不做逐帧转换
/// （此前要求 BGRA，8K 每帧约 120 MB 的颜色转换会拖慢起播与播放）；HDR 片源由系统色调映射到 BT.709。
@MainActor
final class VRRenderer: NSObject, MTKViewDelegate {
    var layout: VRLayout
    var state = VRViewState()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    /// 最近一帧的亮度 / 色度平面；GPU 使用期间必须保持 CVMetalTexture 存活。
    private var currentFrame: (luma: CVMetalTexture, chroma: CVMetalTexture)?

    private weak var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private var itemObservation: NSKeyValueObservation?
    private var loggedTextureFailure = false
    /// 诊断：开始等待首帧的时刻（挂载输出或开始播放时重置），以及已上报的问题。
    private var waitingSince: CFTimeInterval?
    private var reportedIssue: String?
    /// 画面问题变化时回调（nil 表示已正常出画面）。
    var onIssue: ((String?) -> Void)?
    /// 播放中超过该时长仍没有任何画面即视为失败并提示原因（秒）。8K 片源首帧本身较慢，留足余量。
    private static let firstFrameTimeout: CFTimeInterval = 6

    /// 必须声明 Metal 兼容（IOSurface 支持），否则 `CVMetalTextureCacheCreateTextureFromImage` 失败、画面全黑。
    nonisolated private static var attributes: [String: Any] {
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

    /// 绑定播放器；条目替换（切集、切换码流）时把视频输出迁移到新条目。
    func attach(to player: AVPlayer) {
        guard self.player !== player else { return }
        self.player = player
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor in self?.attachOutput(to: item) }
        }
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
        currentFrame = nil
        guard let item else { return }
        let output = AVPlayerItemVideoOutput(outputSettings: Self.outputSettings)
        item.add(output)
        self.output = output
        attachedItem = item
        waitingSince = nil
        report(nil)
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
        if let currentFrame,
           let luma = CVMetalTextureGetTexture(currentFrame.luma),
           let chroma = CVMetalTextureGetTexture(currentFrame.chroma) {
            var params = uniforms(viewSize: view.drawableSize)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)
            encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func updateTexture() {
        guard let output, let cache = textureCache else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let frame = output.pixelBufferAndDisplayTime(forItemTime: time).pixelBuffer else { return }
        // 纹理只在主线程的渲染回调中使用；闭包内直接写入局部变量，避免跨隔离域返回非 Sendable 值。
        nonisolated(unsafe) var luma: CVMetalTexture?
        nonisolated(unsafe) var chroma: CVMetalTexture?
        nonisolated(unsafe) var status: CVReturn = kCVReturnSuccess
        frame.withUnsafeBuffer { buffer in
            status = Self.makeTextures(from: buffer, cache: cache, luma: &luma, chroma: &chroma)
        }
        if let luma, let chroma {
            currentFrame = (luma, chroma)
            report(nil)
        } else if !loggedTextureFailure {
            loggedTextureFailure = true
            let format = frame.withUnsafeBuffer { CVPixelBufferGetPixelFormatType($0) }
            Log.player.error("VR 纹理创建失败：CVReturn \(status) format=\(format)")
            report("VR 纹理创建失败（CVReturn \(status)，像素格式 \(format)）")
        }
    }

    /// 播放中长时间没有画面：汇总条目状态，让界面给出原因而不是一直黑屏。
    private func diagnose() {
        guard currentFrame == nil, reportedIssue == nil, let player, let item = attachedItem else {
            if currentFrame != nil { waitingSince = nil }
            return
        }
        // 只在真正播放时计时：缓冲 / 暂停期间没有新帧是正常的。
        guard player.timeControlStatus == .playing else {
            waitingSince = nil
            return
        }
        let now = CACurrentMediaTime()
        guard let since = waitingSince else {
            waitingSince = now
            return
        }
        guard now - since > Self.firstFrameTimeout else { return }
        let size = item.presentationSize
        var parts = ["VR 转平面没有收到视频画面"]
        if let error = item.error { parts.append("条目错误：\(error.localizedDescription)") }
        parts.append(size == .zero ? "画面尺寸未知（可能无法解码该视频）" : "画面 \(Int(size.width))×\(Int(size.height))")
        if let tracks = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }), !tracks.isEnabled {
            parts.append("视频轨未启用")
        }
        let message = parts.joined(separator: "；")
        Log.player.error("\(message, privacy: .public)")
        report(message)
    }

    private func report(_ issue: String?) {
        guard issue != reportedIssue else { return }
        reportedIssue = issue
        onIssue?(issue)
    }

    /// YUV 双平面像素缓冲区 → 亮度（R8）与色度（RG8）两张 Metal 纹理（共享内存，不拷贝）。
    nonisolated static func makeTextures(
        from buffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        luma: inout CVMetalTexture?,
        chroma: inout CVMetalTexture?
    ) -> CVReturn {
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else { return kCVReturnInvalidPixelFormat }
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .r8Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &luma
        )
        guard status == kCVReturnSuccess else { return status }
        return CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &chroma
        )
    }

    /// 测试用：与视频输出相同的像素缓冲区属性。
    nonisolated static var pixelBufferAttributes: [String: Any] { attributes }

    /// 两个 float4：(aspect, outputFOV, yaw, pitch)、(projection, inputFOV, stereo, 0)。
    private func uniforms(viewSize: CGSize) -> (SIMD4<Float>, SIMD4<Float>) {
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
            SIMD4(projection, Float(layout.inputFOV), stereo, 0)
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

    // BT.709 视频范围 YCbCr → RGB（与视频输出的色彩设置一致）。
    static float4 sample_rgb(texture2d<float> luma, texture2d<float> chroma, sampler s, float2 uv) {
        float y = (luma.sample(s, uv).r - 16.0 / 255.0) * (255.0 / 219.0);
        float2 c = (chroma.sample(s, uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
        return float4(saturate(rgb), 1.0);
    }

    fragment float4 vr_fragment(VOut in [[stage_in]], texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]], constant Params &p [[buffer(0)]]) {
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
        return sample_rgb(luma, chroma, s, uv);
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
        if case .avPlayer(let player) = controller.engine.surface { renderer.attach(to: player) }
        return renderer.makeView()
    }

    @MainActor
    private func update(_ view: PlayerPlatformView, context: Context) {
        context.coordinator.renderer?.layout = layout
        context.coordinator.renderer?.state = controller.vrState
        // 非播放状态没有新帧，只需响应拖动 / 捏合视角：降到 15 fps，省掉 60 fps 全屏反投影的 GPU 与电量开销。
        (view as? MTKView)?.preferredFramesPerSecond = controller.engine.status == .playing ? 60 : 15
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
