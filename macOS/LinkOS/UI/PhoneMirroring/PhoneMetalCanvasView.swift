import SwiftUI
import MetalKit
import CoreVideo
import AVFoundation

final class PhoneMetalCanvasView: MTKView, MTKViewDelegate {
    static var activeInstanceCount: Int = 0

    /// Weak reference to the currently live canvas view, so PhoneWindowController can
    /// eagerly wire onPixelBufferReady before SwiftUI's updateNSView runs.
    static weak var current: PhoneMetalCanvasView?

    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var renderPipelineState: MTLRenderPipelineState?

    // MARK: - Latest-Frame State (lock-protected)
    // enqueue() does an atomic pointer swap — no rendering, no dispatch.
    // CVDisplayLink reads the pointer on every VSync tick and renders only if new.
    private let lock = NSLock()
    private var currentPixelBuffer: PixelBufferWrapper?     // newest frame from decoder

    /// Frame-number of last successfully rendered frame.
    /// Used for render-skip check — comparing frame numbers, NOT object identity.
    /// Object-identity comparison (===) is unreliable because PixelBufferWrapper objects
    /// can be reused or retained across session boundaries, causing false "already rendered" skips.
    private var lastRenderedFrameNumber: UInt32 = UInt32.max

    // MARK: - CVDisplayLink (render clock — 60 Hz VSync)
    private var displayLink: CVDisplayLink?
    private var vSyncTickCount: Int = 0  // used to schedule periodic texture cache flush

    // MARK: - One-time renderer state flags (set once, never re-checked per frame)
    private var hasSignaledSuccess: Bool = false

    init() {
        PhoneMetalCanvasView.activeInstanceCount += 1
        LinkOSLogger.shared.info("[Instance Monitor] PhoneMetalCanvasView initialized. Active instances: \(PhoneMetalCanvasView.activeInstanceCount)", category: .media)
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        PhoneMetalCanvasView.current = self

        // MTKView is paused — CVDisplayLink drives all rendering
        self.framebufferOnly = true   // GPU can optimize: we never read back from the drawable
        self.delegate = self
        self.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        self.colorPixelFormat = .bgra8Unorm
        self.enableSetNeedsDisplay = false
        self.isPaused = true
        self.preferredFramesPerSecond = 60

        if let device = self.device {
            self.commandQueue = device.makeCommandQueue()
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            compileShaders(device: device)
        }

        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.framebufferOnly = true
            metalLayer.maximumDrawableCount = 2  // 2 is sufficient; 3 adds latency
            metalLayer.isOpaque = true
            metalLayer.displaySyncEnabled = true
            metalLayer.backgroundColor = NSColor.black.cgColor
        }

        self.acceptsTouchEvents = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Shader compilation

    private func compileShaders(device: MTLDevice) {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };
        vertex VertexOut vertexShader(uint vertexID [[vertex_id]], constant int &rotation [[buffer(0)]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            float2 texCoords[4];
            if (rotation == 90) {
                texCoords[0] = float2(1.0, 1.0);
                texCoords[1] = float2(1.0, 0.0);
                texCoords[2] = float2(0.0, 1.0);
                texCoords[3] = float2(0.0, 0.0);
            } else if (rotation == 180) {
                texCoords[0] = float2(1.0, 0.0);
                texCoords[1] = float2(0.0, 0.0);
                texCoords[2] = float2(1.0, 1.0);
                texCoords[3] = float2(0.0, 1.0);
            } else if (rotation == 270) {
                texCoords[0] = float2(0.0, 0.0);
                texCoords[1] = float2(0.0, 1.0);
                texCoords[2] = float2(1.0, 0.0);
                texCoords[3] = float2(1.0, 1.0);
            } else {
                texCoords[0] = float2(0.0, 1.0);
                texCoords[1] = float2(1.0, 1.0);
                texCoords[2] = float2(0.0, 0.0);
                texCoords[3] = float2(1.0, 0.0);
            }
            VertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }
        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> texture [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            return texture.sample(s, in.texCoord);
        }
        """

        guard let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
            LinkOSLogger.shared.error("[Render Thread] Failed to compile Metal shaders.", category: .media)
            return
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat
        self.renderPipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // MARK: - CVDisplayLink lifecycle

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        LinkOSLogger.shared.info("[Render Thread] startDisplayLink() invoked (displayLink is starting)", category: .media)
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }
        CVDisplayLinkSetOutputHandler(dl) { [weak self] _, _, _, _, _ -> CVReturn in
            LinkOSLogger.shared.info("[Pipeline] CVDisplayLink output handler fired", category: .media)
            self?.renderLatestFrame()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(dl)
    }

    private func stopDisplayLink() {
        guard let dl = displayLink else { return }
        LinkOSLogger.shared.info("[Render Thread] stopDisplayLink() invoked (displayLink is stopping)", category: .media)
        CVDisplayLinkStop(dl)
        displayLink = nil
    }

    // MARK: - enqueue — atomic pointer swap only (called from decoder callback, any thread)

    func enqueue(pixelBuffer: PixelBufferWrapper) {
        // Drop-and-replace: always keep only the newest frame.
        // If CVDisplayLink hasn't consumed the previous frame yet, it is discarded here.
        LinkOSLogger.shared.info("[Pipeline] enqueue called: frame #\(pixelBuffer.frameNum)", category: .media)
        lock.lock()
        currentPixelBuffer = pixelBuffer
        lock.unlock()
        LinkOSLogger.shared.info("[Pipeline] currentPixelBuffer replaced -> frame #\(pixelBuffer.frameNum)", category: .media)
        // CVDisplayLink will pick it up on the next VSync tick (~16ms away at most). No dispatch needed.
        PipelineTracker.shared.updateEnqueue(pixelBuffer.frameNum)
    }

    // MARK: - CVDisplayLink render callback (~60 Hz, background thread)

    private func renderLatestFrame() {
        // Step 1: Atomic read of the latest frame (dequeue)
        lock.lock()
        let pbWrapper = currentPixelBuffer
        lock.unlock()

        if let pb = pbWrapper {
            LinkOSLogger.shared.info("[Pipeline] dequeue read: frame #\(pb.frameNum)", category: .media)
        } else {
            LinkOSLogger.shared.info("[Pipeline] dequeue read: nil", category: .media)
        }

        // Step 2: Skip if no frame available yet
        guard let pbWrapper = pbWrapper else {
            LinkOSLogger.shared.info("[Render Thread] CVDisplayLink tick skipped: currentPixelBuffer is nil", category: .media)
            return
        }

        // Step 3: Skip if this is the same frame number we already rendered last tick.
        // Compare by frameNum (UInt64), NOT by object identity (===).
        // Object-identity fails when wrappers are retained across session boundaries.
        if pbWrapper.frameNum == lastRenderedFrameNumber {
            LinkOSLogger.shared.info("[Render Thread] CVDisplayLink tick skipped: frame #\(pbWrapper.frameNum) already rendered", category: .media)
            return
        }

        LinkOSLogger.shared.info("[Pipeline] renderLatestFrame: rendering new frame #\(pbWrapper.frameNum) (last was #\(lastRenderedFrameNumber == UInt32.max ? -1 : Int64(lastRenderedFrameNumber)))", category: .media)

        // Step 4: Periodic texture cache flush (every ~60 ticks = 1 second at 60 Hz)
        vSyncTickCount += 1
        if vSyncTickCount % 60 == 0, let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }

        // Step 5: Render to screen
        renderFrame(pbWrapper)
    }

    // MARK: - Core render function (no per-frame logging, no allocations)

    private func renderFrame(_ pbWrapper: PixelBufferWrapper) {
        let pb = pbWrapper.buffer
        PipelineTracker.shared.updateRender(pbWrapper.frameNum)
        PhoneSessionManager.shared.activeSession.displayedFrameCountSecond += 1

        let viewSize = self.drawableSize
        guard viewSize.width > 0, viewSize.height > 0,
              !viewSize.width.isNaN, !viewSize.height.isNaN else { return }

        // Non-blocking: skip this frame rather than stalling the render thread
        guard let drawable = self.currentDrawable else {
            LinkOSLogger.shared.info("[Render Thread] currentDrawable is nil for frame #\(pbWrapper.frameNum)!", category: .media)
            return
        }
        LinkOSLogger.shared.info("[Pipeline] currentDrawable acquired: frame #\(pbWrapper.frameNum)", category: .media)
        
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        guard let textureCache = self.textureCache else { return }

        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        var cvTextureOut: CVMetalTexture?

        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil, .bgra8Unorm,
            width, height, 0, &cvTextureOut
        )

        guard let cvTexture = cvTextureOut,
              let sourceTexture = CVMetalTextureGetTexture(cvTexture) else {
            LinkOSLogger.shared.error("[Render Thread] Failed to create Metal texture from CVPixelBuffer", category: .media)
            return
        }

        var rotation = Int32(PhoneSessionManager.shared.activeSession.displayRotation)

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }

        if let pipelineState = renderPipelineState {
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBytes(&rotation, length: MemoryLayout<Int32>.size, index: 0)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        
        LinkOSLogger.shared.info("[Pipeline] calling present(drawable) for frame #\(pbWrapper.frameNum)", category: .media)
        commandBuffer.present(drawable)

        // Retain pixel buffer and texture mapping until GPU has finished reading them
        commandBuffer.addCompletedHandler { [weak self, pbWrapper, cvTexture] _ in
            let _ = pbWrapper  // keep CVPixelBuffer alive until GPU done
            let _ = cvTexture  // keep texture mapping alive until GPU done

            // Signal renderer success exactly once — never on every frame
            if let self = self, !self.hasSignaledSuccess {
                self.hasSignaledSuccess = true
                Task { @MainActor in
                    let session = PhoneSessionManager.shared.activeSession
                    if session.mirrorState != .presenting && session.mirrorState != .streaming {
                        _ = session.transitionTo(.presenting)
                    }
                    if session.rendererStatus != .success {
                        session.updateDiagnostic(stage: "renderer", ok: true, error: "")
                    }
                }
            }
        }

        LinkOSLogger.shared.info("[Pipeline] calling commandBuffer.commit() for frame #\(pbWrapper.frameNum)", category: .media)
        commandBuffer.commit()
        LinkOSLogger.shared.info("[Pipeline] present(drawable): frame #\(pbWrapper.frameNum) committed to GPU", category: .media)

        // Mark last rendered frame number (compare by number, not pointer)
        lastRenderedFrameNumber = pbWrapper.frameNum
    }

    // MARK: - MTKViewDelegate (system-driven redraws: resize, exposure)

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handled automatically by MTKView autoResizeDrawable.
    }

    func draw(in view: MTKView) {
        LinkOSLogger.shared.info("[Render Thread] MTKView.draw(in:) called", category: .media)
        // AppKit-requested redraw (e.g. expose/resize). Render current frame immediately.
        lock.lock()
        let pb = currentPixelBuffer
        lock.unlock()
        if let pb = pb { renderFrame(pb) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // MARK: - Window visibility (suspend CVDisplayLink when hidden — saves CPU + battery)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if window == nil {
            stopDisplayLink()
            restoreCursor()
            return
        }
        if let win = self.window {
            startDisplayLink()

            NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: win, queue: .main) { [weak self] _ in
                self?.stopDisplayLink()
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: win, queue: .main) { [weak self] _ in
                self?.startDisplayLink()
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.window?.invalidateCursorRects(for: self)
                self.wakeCursor()
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.restoreCursor()
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }

    // MARK: - Renderer reset (called on session change)

    func resetRenderer() {
        LinkOSLogger.shared.info("[Render Thread] Resetting renderer due to session change", category: .media)
        restoreCursor()
        hasSignaledSuccess = false
        lock.lock()
        currentPixelBuffer = nil
        lastRenderedFrameNumber = UInt32.max
        lock.unlock()
        if let cache = self.textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    deinit {
        stopDisplayLink()
        PhoneMetalCanvasView.activeInstanceCount -= 1
        if PhoneMetalCanvasView.current === self {
            PhoneMetalCanvasView.current = nil
        }
        LinkOSLogger.shared.info("[Instance Monitor] PhoneMetalCanvasView deallocated. Active instances: \(PhoneMetalCanvasView.activeInstanceCount)", category: .media)
        restoreCursor()
    }

    // MARK: - Cursor management

    func restoreCursor() {
        cursorHideWorkItem?.cancel()
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
    }

    func wakeCursor() {
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        cursorHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !self.isCursorHidden {
                NSCursor.hide()
                self.isCursorHidden = true
            }
        }
        cursorHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    // MARK: - Tracking areas & cursor rects

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .mouseMoved, .cursorUpdate]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        if let activeCursor = CursorManager.shared.activeCursor {
            activeCursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let activeCursor = CursorManager.shared.activeCursor {
            self.addCursorRect(self.bounds, cursor: activeCursor)
        } else {
            self.addCursorRect(self.bounds, cursor: NSCursor.arrow)
        }
    }

    // MARK: - Properties

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var trackingArea: NSTrackingArea?
    private var isCursorHidden = false
    private var cursorHideWorkItem: DispatchWorkItem?
    private var activeTouchCount = 0

    // MARK: - Input event handlers

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); wakeCursor() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); restoreCursor() }

    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        activeTouchCount = event.touches(matching: .touching, in: self).count
        wakeCursor()
    }
    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        activeTouchCount = event.touches(matching: .touching, in: self).count
        wakeCursor()
    }
    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        activeTouchCount = event.touches(matching: .touching, in: self).count
        wakeCursor()
    }
    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        activeTouchCount = event.touches(matching: .touching, in: self).count
        wakeCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        wakeCursor()
        let loc = convert(event.locationInWindow, from: nil)
        PhoneInputService.shared.handleMouseMoved(at: loc, viewSize: bounds.size)
        PhoneWindowController.shared.wakeToolbar()
    }

    override func mouseDown(with event: NSEvent) {
        wakeCursor()
        let loc = convert(event.locationInWindow, from: nil)
        PhoneInputService.shared.handleMouseDown(at: loc, viewSize: bounds.size, clickCount: event.clickCount)
        Task { @MainActor in
            PhoneSessionManager.shared.activeSession.triggerTapAnimation(at: loc, in: bounds.size)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        wakeCursor()
        let loc = convert(event.locationInWindow, from: nil)
        PhoneInputService.shared.handleMouseDragged(to: loc, viewSize: bounds.size)
    }

    override func mouseUp(with event: NSEvent) {
        wakeCursor()
        let loc = convert(event.locationInWindow, from: nil)
        PhoneInputService.shared.handleMouseUp(at: loc, viewSize: bounds.size)
    }

    override func scrollWheel(with event: NSEvent) {
        wakeCursor()
        let loc = convert(event.locationInWindow, from: nil)
        PhoneInputService.shared.handleScroll(at: loc, event: event, viewSize: bounds.size)
    }

    override func magnify(with event: NSEvent) {
        PhoneInputService.shared.handleMagnify(at: convert(event.locationInWindow, from: nil), event: event, viewSize: bounds.size)
    }

    override func rotate(with event: NSEvent) {
        PhoneInputService.shared.handleRotate(at: convert(event.locationInWindow, from: nil), event: event, viewSize: bounds.size)
    }

    override func swipe(with event: NSEvent) {
        PhoneInputService.shared.handleSwipe(at: convert(event.locationInWindow, from: nil), event: event, viewSize: bounds.size)
    }

    override func pressureChange(with event: NSEvent) {
        PhoneInputService.shared.handlePressureChange(at: convert(event.locationInWindow, from: nil), event: event, viewSize: bounds.size)
    }

    override func keyDown(with event: NSEvent) {
        PhoneInputService.shared.handleKeyDown(with: event)
    }
}

// MARK: - SwiftUI Representable

struct PhoneMetalCanvasViewRepresentable: NSViewRepresentable {
    @ObservedObject var session: PhoneSession

    class Coordinator {
        /// Track the *object identity* of the bound session, not just its ID string.
        /// Two different PhoneSession instances can share the same sessionId during a
        /// recreate race — ObjectIdentifier is guaranteed unique per live object.
        var lastSessionObjectId: ObjectIdentifier = ObjectIdentifier(NSObject())
        /// Track the *object identity* of the view to detect if SwiftUI swapped the NSView instance.
        var lastViewObjectId: ObjectIdentifier?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PhoneMetalCanvasView {
        let view = PhoneMetalCanvasView()
        let sessionObjId = ObjectIdentifier(session)
        let viewObjId = ObjectIdentifier(view)
        context.coordinator.lastSessionObjectId = sessionObjId
        context.coordinator.lastViewObjectId = viewObjId
        
        LinkOSLogger.shared.info("[Binding Audit] makeNSView: wiring view [\(viewObjId)] to session [\(sessionObjId)] (ID: \(session.sessionId))", category: .media)
        wireSession(session, to: view)
        return view
    }

    func updateNSView(_ nsView: PhoneMetalCanvasView, context: Context) {
        if !session.isStreaming && session.connectionState == .disconnected {
            nsView.resetRenderer()
        }

        let currentSessionObjectId = ObjectIdentifier(session)
        let currentViewObjectId = ObjectIdentifier(nsView)
        let sessionChanged = context.coordinator.lastSessionObjectId != currentSessionObjectId
        let viewChanged = context.coordinator.lastViewObjectId != currentViewObjectId
        let callbackMissing = session.onPixelBufferReady == nil

        if sessionChanged || viewChanged || callbackMissing {
            LinkOSLogger.shared.info("[Binding Audit] updateNSView: re-wiring required. sessionChanged=\(sessionChanged), viewChanged=\(viewChanged), callbackMissing=\(callbackMissing). Session [\(currentSessionObjectId)] (ID: \(session.sessionId)), View [\(currentViewObjectId)]", category: .media)
            
            if sessionChanged || viewChanged {
                context.coordinator.lastSessionObjectId = currentSessionObjectId
                context.coordinator.lastViewObjectId = currentViewObjectId
                nsView.resetRenderer()
            }
            wireSession(session, to: nsView)
            nsView.restoreCursor()
            nsView.wakeCursor()
        }
    }

    static func dismantleNSView(_ nsView: PhoneMetalCanvasView, coordinator: Coordinator) {
        nsView.resetRenderer()
    }

    private func wireSession(_ session: PhoneSession, to view: PhoneMetalCanvasView) {
        LinkOSLogger.shared.info("[Binding Audit] wireSession: binding onPixelBufferReady on session \(session.sessionId) to view \(ObjectIdentifier(view))", category: .media)
        session.onSampleBufferReady = { [weak view] buffer in
            if let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) {
                view?.enqueue(pixelBuffer: PixelBufferWrapper(pixelBuffer, frameNum: 0))
            }
        }
        session.onPixelBufferReady = { [weak view] pb in
            LinkOSLogger.shared.info("[Pipeline] onPixelBufferReady (SwiftUI wire): frame #\(pb.frameNum) → enqueue", category: .media)
            view?.enqueue(pixelBuffer: pb)
        }
    }
}

