import AppKit
import OpenGL.GL3
import CMPV
import Darwin

final class VideoView: NSOpenGLView {
    private var renderer: OpaquePointer?
    private var stopped = false
    private var renderQueued = false
    private var glLibrary: UnsafeMutableRawPointer?

    init?(surfaceSize: NSSize) {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFAAlphaSize), 8, 0
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes) else { return nil }
        super.init(frame: NSRect(origin: .zero, size: surfaceSize), pixelFormat: format)
        glLibrary = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)
        wantsBestResolutionOpenGLSurface = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Input belongs to the containing surface; the video renderer is display-only.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func connect(to engine: PlaybackEngine) throws {
        guard let core = engine.handle, let context = openGLContext else {
            throw MPXError.playback("Could not connect the video display.")
        }
        context.makeCurrentContext()
        var interval: GLint = 1
        context.setValues(&interval, for: .swapInterval)
        var gl = mpv_opengl_init_params(get_proc_address: { context, name in
            guard let context, let name else { return nil }
            return dlsym(context, name)
        }, get_proc_address_ctx: glLibrary)
        let api = strdup(MPV_RENDER_API_TYPE_OPENGL)!
        defer { free(api) }
        let result = withUnsafeMutablePointer(to: &gl) { parameters -> Int32 in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(parameters)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            return mpv_render_context_create(&renderer, core, &params)
        }
        guard result >= 0, let renderer else { throw MPXError.playback("Could not initialize video rendering.") }
        mpv_render_context_set_update_callback(renderer, { context in
            guard let context else { return }
            let view = Unmanaged<VideoView>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak view] in view?.scheduleRender() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func scheduleRender() {
        guard !stopped, !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderQueued = false
            self.renderFrame()
        }
    }

    override func draw(_ dirtyRect: NSRect) { renderFrame() }
    override func reshape() {
        super.reshape()
        openGLContext?.update()
        renderFrame()
    }

    private func renderFrame() {
        guard !stopped, let context = openGLContext, bounds.width > 0, bounds.height > 0 else { return }
        context.makeCurrentContext()
        let size = convertToBacking(bounds).size
        guard let renderer else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            context.flushBuffer()
            return
        }
        _ = mpv_render_context_update(renderer)
        var fbo = mpv_opengl_fbo(fbo: 0, w: Int32(size.width), h: Int32(size.height), internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &fbo) { target in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(target)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(renderer, &params)
            }
        }
        context.flushBuffer()
        mpv_render_context_report_swap(renderer)
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        if let renderer {
            openGLContext?.makeCurrentContext()
            mpv_render_context_set_update_callback(renderer, nil, nil)
            mpv_render_context_free(renderer)
            self.renderer = nil
        }
    }

    deinit { if let glLibrary { dlclose(glLibrary) } }
}
