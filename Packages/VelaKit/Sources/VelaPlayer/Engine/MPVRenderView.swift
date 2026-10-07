import Foundation
import libmpv
import VelaCore
#if os(iOS)
import OpenGLES
import UIKit
#else
import AppKit
import OpenGL.GL3
#endif

// mpv 画面经 libmpv render API（OpenGL / OpenGL ES）绘制。所用 libmpv 由 FFmpegKit 提供，没有编入
// MoltenVK 上下文，不能让 mpv 直接画到 CAMetalLayer；VideoToolbox 硬解帧经 OpenGL 互通直接上屏，4K 不回读 CPU。
// OpenGL 在 Apple 平台已标记弃用但仍可用；以后若换成带 MoltenVK 的 libmpv，可改为 `vo=gpu-next` + `wid` 直接渲染。

/// render API 需要的 OpenGL 函数地址查找。
nonisolated(unsafe) private let glLibrary: UnsafeMutableRawPointer? = {
    #if os(iOS)
    dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY)
    #else
    dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)
    #endif
}()

private func mpvGetProcAddress(_ context: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    return dlsym(glLibrary, name)
}

/// 在当前 OpenGL 上下文中创建 mpv 渲染上下文；调用前必须已 `makeCurrent`。
private func createRenderContext(_ handle: OpaquePointer) -> OpaquePointer? {
    var initParams = mpv_opengl_init_params(get_proc_address: mpvGetProcAddress, get_proc_address_ctx: nil)
    let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
    defer { free(apiType) }
    var context: OpaquePointer?
    let result = withUnsafeMutablePointer(to: &initParams) { initPointer in
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
        ]
        return mpv_render_context_create(&context, handle, &params)
    }
    if result < 0 {
        Log.player.error("mpv 渲染上下文创建失败：\(String(cString: mpv_error_string(result)), privacy: .public)")
        return nil
    }
    return context
}

/// 把当前帧画进指定 FBO。`flipY`：上屏的帧缓冲（macOS 默认帧缓冲、iOS 呈现的 renderbuffer）原点在左下角，需要翻转。
private func renderFrame(_ context: OpaquePointer, fbo: Int32, width: Int32, height: Int32, flipY: Bool) {
    var target = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
    var flip: Int32 = flipY ? 1 : 0
    withUnsafeMutablePointer(to: &target) { targetPointer in
        withUnsafeMutablePointer(to: &flip) { flipPointer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(targetPointer)),
                mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            _ = mpv_render_context_render(context, &params)
        }
    }
}

/// mpv 渲染更新回调：在 mpv 内部线程触发。必须是文件级的非隔离函数（理由同 `mpvWakeup`）。
private func mpvRenderUpdate(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<RenderTrigger>.fromOpaque(context).takeUnretainedValue().fire()
}

/// mpv 更新回调的转发对象：回调在 mpv 内部线程触发，只做线程安全的投递。
private final class RenderTrigger: @unchecked Sendable {
    let fire: @Sendable () -> Void
    init(_ fire: @escaping @Sendable () -> Void) { self.fire = fire }
}

#if os(iOS)

/// iOS：`CAEAGLLayer` + OpenGL ES 3。视图属于主线程（UIKit），GL 调用全部交给 `GLESRenderer` 在专用串行队列上执行，
/// 不能写在视图的方法里——Swift 6 会对主线程隔离的方法做运行时检查，在后台队列执行会直接中断进程。
final class MPVRenderView: UIView {
    override class var layerClass: AnyClass { CAEAGLLayer.self }

    private let renderer: GLESRenderer

    init(handle: OpaquePointer) {
        renderer = GLESRenderer(handle: handle)
        super.init(frame: .zero)
        let layer = self.layer as! CAEAGLLayer
        layer.isOpaque = true
        layer.drawableProperties = [kEAGLDrawablePropertyRetainedBacking: false, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8]
        contentScaleFactor = UIScreen.main.scale
        backgroundColor = .black
        renderer.start(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderer.resize()
    }

    /// 释放渲染上下文；必须在 `mpv_terminate_destroy` 之前调用，同步等待渲染队列清空。
    func teardown() {
        renderer.teardown()
    }
}

/// 只在 `queue` 上访问可变状态（串行队列保证互斥）。
private final class GLESRenderer: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "vela.mpv.render", qos: .userInteractive)
    private let glContext: EAGLContext
    private var layer: CAEAGLLayer?
    private var renderContext: OpaquePointer?
    private var framebuffer: GLuint = 0
    private var colorbuffer: GLuint = 0
    private var bufferSize: (width: GLint, height: GLint) = (0, 0)
    private var trigger: RenderTrigger?
    private var needsResize = true
    private var torndown = false

    init(handle: OpaquePointer) {
        self.handle = handle
        glContext = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)!
    }

    func start(layer: CAEAGLLayer) {
        nonisolated(unsafe) let layer = layer
        queue.async { [self] in
            self.layer = layer
            EAGLContext.setCurrent(glContext)
            glGenFramebuffers(1, &framebuffer)
            glGenRenderbuffers(1, &colorbuffer)
            renderContext = createRenderContext(handle)
            guard let renderContext else { return }
            let trigger = RenderTrigger { [weak self] in
                self?.queue.async { self?.draw() }
            }
            self.trigger = trigger
            mpv_render_context_set_update_callback(renderContext, mpvRenderUpdate, Unmanaged.passUnretained(trigger).toOpaque())
        }
    }

    func resize() {
        queue.async { [self] in
            needsResize = true
            draw()
        }
    }

    func teardown() {
        queue.sync {
            torndown = true
            EAGLContext.setCurrent(glContext)
            if let renderContext {
                mpv_render_context_set_update_callback(renderContext, nil, nil)
                mpv_render_context_free(renderContext)
            }
            renderContext = nil
            if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer) }
            if colorbuffer != 0 { glDeleteRenderbuffers(1, &colorbuffer) }
            EAGLContext.setCurrent(nil)
            trigger = nil
            layer = nil
        }
    }

    private func resizeIfNeeded() {
        guard needsResize, let layer else { return }
        needsResize = false
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorbuffer)
        glContext.renderbufferStorage(Int(GL_RENDERBUFFER), from: layer)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &bufferSize.width)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &bufferSize.height)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorbuffer)
    }

    private func draw() {
        guard !torndown, let renderContext else { return }
        EAGLContext.setCurrent(glContext)
        resizeIfNeeded()
        guard bufferSize.width > 0, bufferSize.height > 0 else { return }
        _ = mpv_render_context_update(renderContext)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        renderFrame(renderContext, fbo: Int32(framebuffer), width: bufferSize.width, height: bufferSize.height, flipY: true)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorbuffer)
        glContext.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }
}

#else

/// macOS：`CAOpenGLLayer`，由 Core Animation 在需要时调用 `draw(inCGLContext:)`；mpv 有新帧时请求重绘。
final class MPVRenderView: NSView {
    private let renderLayer: MPVOpenGLLayer

    init(handle: OpaquePointer) {
        renderLayer = MPVOpenGLLayer(handle: handle)
        super.init(frame: .zero)
        wantsLayer = true
        layer = renderLayer
        renderLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func teardown() {
        renderLayer.teardown()
    }
}

private final class MPVOpenGLLayer: CAOpenGLLayer, @unchecked Sendable {
    private let handle: OpaquePointer
    private var renderContext: OpaquePointer?
    private var cglContext: CGLContextObj?
    private var trigger: RenderTrigger?
    private var loggedFirstDraw = false
    private let lock = NSLock()

    init(handle: OpaquePointer) {
        self.handle = handle
        super.init()
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    override init(layer: Any) {
        let other = layer as! MPVOpenGLLayer
        handle = other.handle
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0)
        ]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &format, &count)
        return format!
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: pixelFormat)
        lock.lock()
        defer { lock.unlock() }
        if renderContext == nil {
            CGLSetCurrentContext(context)
            renderContext = createRenderContext(handle)
            cglContext = context
            if let renderContext {
                // 图层自身线程安全（@unchecked Sendable），回调只在主线程请求重绘。
                nonisolated(unsafe) weak var layer = self
                let trigger = RenderTrigger {
                    DispatchQueue.main.async { layer?.setNeedsDisplay() }
                }
                self.trigger = trigger
                mpv_render_context_set_update_callback(renderContext, mpvRenderUpdate, Unmanaged.passUnretained(trigger).toOpaque())
            }
        }
        return context
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        lock.lock()
        defer { lock.unlock() }
        guard let renderContext else { return }
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        _ = mpv_render_context_update(renderContext)
        renderFrame(renderContext, fbo: fbo, width: viewport[2], height: viewport[3], flipY: true)
        glFlush()
        if !loggedFirstDraw {
            loggedFirstDraw = true
            Log.player.info("mpv 首次绘制 fbo=\(fbo) viewport=\(viewport[2])x\(viewport[3]) thread=\(Thread.isMainThread ? "main" : "background", privacy: .public)")
        }
    }

    func teardown() {
        lock.lock()
        defer { lock.unlock() }
        if let renderContext {
            if let cglContext { CGLSetCurrentContext(cglContext) }
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
        }
        renderContext = nil
        trigger = nil
    }
}

#endif
