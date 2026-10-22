import AppKit
import CShm
import Metal
import MetalKit

/// Reads the TV picture that the emulator writes to shared memory (`-share-vid`).
///
/// Layout of the region "videmulator<port>":
///   offset 0:  UInt32 width, UInt32 height, UInt32 fps, UInt32 frameNumber
///   offset 16: UInt64 timestamp (microseconds)
///   offset 24: width * height BGRA pixels, top row first
/// The host GPU draws the frames. Nothing is encoded or compressed.
final class SharedFrameSource {
    static let headerSize = 24

    private let name: String
    private(set) var base: UnsafeMutableRawPointer?
    private(set) var length = 0
    private(set) var buffer: MTLBuffer?

    init(port: Int) {
        name = "videmulator\(port)"
    }

    deinit { unmap() }

    var width: Int { base.map { Int($0.load(as: UInt32.self)) } ?? 0 }
    var height: Int { base.map { Int($0.load(fromByteOffset: 4, as: UInt32.self)) } ?? 0 }
    var frameNumber: UInt32 { base?.load(fromByteOffset: 12, as: UInt32.self) ?? 0 }

    /// Maps the region if needed. Returns false if the emulator has not created it yet.
    func ensureMapped(device: MTLDevice) -> Bool {
        if base != nil, Self.headerSize + width * height * 4 <= length { return true }
        unmap()
        var size = 0
        guard let pointer = cshm_map(name, &size) else { return false }
        base = pointer
        length = size
        // Zero-copy: the GPU reads the shared pages directly (unified memory).
        buffer = device.makeBuffer(bytesNoCopy: pointer, length: size, options: .storageModeShared, deallocator: nil)
        if buffer == nil || width == 0 || Self.headerSize + width * height * 4 > length {
            unmap()
            return false
        }
        NSLog("TVDroid: TV picture connected, \(width)x\(height)")
        return true
    }

    /// Call after the emulator restarts. The emulator then creates a new region.
    func unmap() {
        buffer = nil
        if let base { cshm_unmap(base, length) }
        base = nil
        length = 0
    }
}

/// Draws the shared frames with Metal, aspect-fit with black bars.
final class TVRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let source: SharedFrameSource
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var texture: MTLTexture?
    private var lastFrame: UInt32 = .max
    private var lastMapAttempt = Date.distantPast

    /// The part of the view (in points) that shows the picture. Used to map mouse clicks.
    private(set) var pictureRect: CGRect = .zero

    /// Called on the main thread when the picture appears or goes away.
    var onPictureChange: ((Bool) -> Void)?
    private(set) var hasPicture = false {
        didSet { if hasPicture != oldValue { onPictureChange?(hasPicture) } }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; float2 uv; };
    vertex Out vmain(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        Out o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }
    // Catmull-Rom bicubic filter with 9 bilinear taps. It is sharper than bilinear when the picture is scaled up.
    float4 bicubic(texture2d<float> tex, sampler s, float2 uv) {
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 pos = uv * size;
        float2 p1 = floor(pos - 0.5) + 0.5;
        float2 f = pos - p1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 t0 = (p1 - 1.0) / size;
        float2 t3 = (p1 + 2.0) / size;
        float2 t12 = (p1 + w2 / w12) / size;
        float4 c = 0.0;
        c += tex.sample(s, float2(t0.x,  t0.y))  * w0.x  * w0.y;
        c += tex.sample(s, float2(t12.x, t0.y))  * w12.x * w0.y;
        c += tex.sample(s, float2(t3.x,  t0.y))  * w3.x  * w0.y;
        c += tex.sample(s, float2(t0.x,  t12.y)) * w0.x  * w12.y;
        c += tex.sample(s, float2(t12.x, t12.y)) * w12.x * w12.y;
        c += tex.sample(s, float2(t3.x,  t12.y)) * w3.x  * w12.y;
        c += tex.sample(s, float2(t0.x,  t3.y))  * w0.x  * w3.y;
        c += tex.sample(s, float2(t12.x, t3.y))  * w12.x * w3.y;
        c += tex.sample(s, float2(t3.x,  t3.y))  * w3.x  * w3.y;
        return c;
    }
    fragment float4 fmain(Out in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                          constant int &upscale [[buffer(0)]]) {
        float3 rgb = upscale != 0 ? bicubic(tex, s, in.uv).rgb : tex.sample(s, in.uv).rgb;
        return float4(saturate(rgb), 1.0);
    }
    """

    init?(port: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.source = SharedFrameSource(port: port)
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vmain")
            descriptor.fragmentFunction = library.makeFunction(name: "fmain")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("TVDroid: Metal setup failed: \(error)")
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler
        super.init()
    }

    /// Forces a new map on the next frame (after the emulator restarts).
    func reconnect() {
        source.unmap()
        texture = nil
        lastFrame = .max
        hasPicture = false
    }

    private var watchedFrame: UInt32 = .max
    private var lastFrameChange = Date()

    /// Call about once a second. Finds a TV that stopped or restarted, also when TVDroid did not start it.
    /// A restarted emulator makes a new shared region. The old mapping then keeps an old, frozen frame.
    func checkSource() {
        guard source.base != nil else { return }
        let frame = source.frameNumber
        if frame != watchedFrame {
            watchedFrame = frame
            lastFrameChange = Date()
            return
        }
        // A still TV screen also sends no new frames, so only check after a few seconds.
        guard Date().timeIntervalSince(lastFrameChange) > 3 else { return }
        lastFrameChange = Date()
        var size = 0
        guard let probe = cshm_map("videmulator\(TVController.port)", &size) else {
            reconnect()  // The TV is off.
            return
        }
        let probeFrame = probe.load(fromByteOffset: 12, as: UInt32.self)
        cshm_unmap(probe, size)
        if probeFrame != frame || size != source.length { reconnect() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandBuffer = queue.makeCommandBuffer() else { return }

        // Copy a new frame to the texture. The GPU does the copy, not the CPU.
        if source.base == nil, Date().timeIntervalSince(lastMapAttempt) > 1 {
            lastMapAttempt = Date()
            _ = source.ensureMapped(device: device)
        }
        if source.base != nil, source.ensureMapped(device: device), let buffer = source.buffer {
            let width = source.width, height = source.height
            if texture?.width != width || texture?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.usage = [.shaderRead]
                descriptor.storageMode = .private
                texture = device.makeTexture(descriptor: descriptor)
                lastFrame = .max
            }
            let frame = source.frameNumber
            if frame != lastFrame, let texture, let blit = commandBuffer.makeBlitCommandEncoder() {
                // Frame 0 is empty. Show the picture from the first real frame.
                if frame > 0 { hasPicture = true }
                lastFrame = frame
                blit.copy(from: buffer, sourceOffset: SharedFrameSource.headerSize,
                          sourceBytesPerRow: width * 4, sourceBytesPerImage: width * height * 4,
                          sourceSize: MTLSize(width: width, height: height, depth: 1),
                          to: texture, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
        }

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
            commandBuffer.commit()
            return
        }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let texture, hasPicture {
            let drawableSize = view.drawableSize
            let fit = AVMakeRectFit(CGSize(width: texture.width, height: texture.height),
                                    CGRect(origin: .zero, size: drawableSize))
            let scale = view.window?.backingScaleFactor ?? 2
            pictureRect = CGRect(x: fit.minX / scale, y: fit.minY / scale, width: fit.width / scale, height: fit.height / scale)
            encoder.setViewport(MTLViewport(originX: fit.minX, originY: fit.minY, width: fit.width, height: fit.height, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var upscale: Int32 = fit.width > CGFloat(texture.width) * 1.05 ? 1 : 0
            encoder.setFragmentBytes(&upscale, length: MemoryLayout<Int32>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    var pictureSize: CGSize {
        CGSize(width: texture?.width ?? 0, height: texture?.height ?? 0)
    }
}

/// Aspect-fit rectangle, origin at the top left (Metal viewport space).
private func AVMakeRectFit(_ size: CGSize, _ bounds: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return bounds }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
}

/// The TV picture view. Sends keyboard and mouse input to Android.
final class TVScreenView: MTKView {
    let renderer: TVRenderer
    private let console = EmulatorConsole.shared

    init?(port: Int) {
        guard let renderer = TVRenderer(port: port) else { return nil }
        self.renderer = renderer
        super.init(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 60
        framebufferOnly = true
        delegate = renderer
        // TVDroid drives the drawing itself. The MTKView timer can stop after the window hides and shows again.
        isPaused = true
        enableSetNeedsDisplay = false
    }

    private var displayLinkObject: CADisplayLink?
    private var watchdog: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, displayLinkObject == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayTick))
        link.add(to: .main, forMode: .common)
        displayLinkObject = link
        // Also draw from a timer: a display link does not run while the window is on no screen.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderer.checkSource()
                if Date().timeIntervalSince(self.lastDraw) > 0.5 { self.draw() }
            }
        }
    }

    private var lastDraw = Date.distantPast

    @objc private func displayTick() {
        lastDraw = Date()
        draw()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Keyboard

    private let keyboard = VirtualKeyboard.shared

    /// Keys go to the TV as a real keyboard: each Mac key sends the same key position.
    /// Command shortcuts stay on the Mac. ⌘F switches full screen. ⌥H is Home.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if event.charactersIgnoringModifiers == "f" { window?.toggleFullScreen(nil); return }
            super.keyDown(with: event)
            return
        }
        if flags.contains(.option), event.charactersIgnoringModifiers == "h" {
            if !event.isARepeat { keyboard.tap(Linux.home) }
            return
        }
        // Android makes its own key repeat while the key is down.
        guard !event.isARepeat, let code = Linux.macKeys[event.keyCode] else { return }
        keyboard.set(code, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let code = Linux.macKeys[event.keyCode] else { return }
        keyboard.set(code, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = Linux.macKeys[event.keyCode] else { return }
        let flags = event.modifierFlags
        switch event.keyCode {
        case 57: keyboard.tap(code)  // Caps Lock: each change toggles it in Android too.
        case 56, 60: keyboard.set(code, down: flags.contains(.shift))
        case 59, 62: keyboard.set(code, down: flags.contains(.control))
        default: break
        }
    }

    override func resignFirstResponder() -> Bool {
        keyboard.releaseAll()
        return super.resignFirstResponder()
    }

    // MARK: Mouse (touch)

    /// The first click on the window also goes to the TV, not only to make the window active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        touch(event, down: true)
    }
    override func mouseDragged(with event: NSEvent) { touch(event, down: true) }
    override func mouseUp(with event: NSEvent) { touch(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { console.press(.back) }

    private var scrollAccumulator: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        // Scrolling moves the focus one row for each step.
        guard event.momentumPhase == [] else { return }
        let step: CGFloat = 30
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * step
        while abs(scrollAccumulator) >= step {
            console.press(scrollAccumulator > 0 ? .up : .down)
            scrollAccumulator -= scrollAccumulator > 0 ? step : -step
        }
    }

    private func touch(_ event: NSEvent, down: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = renderer.pictureRect
        let size = renderer.pictureSize
        guard rect.width > 0, size.width > 0 else { return }
        // AppKit y grows upward. The TV picture y grows downward.
        let flippedY = bounds.height - point.y
        let x = (point.x - rect.minX) / rect.width * size.width
        let y = (flippedY - rect.minY) / rect.height * size.height
        guard x >= 0, y >= 0, x < size.width, y < size.height else { return }
        console.touch(x: Int(x), y: Int(y), down: down)
    }
}
