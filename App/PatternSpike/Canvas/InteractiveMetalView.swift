#if os(macOS)
import AppKit
import MetalKit
import MetalRenderer
import PatternEngine

@MainActor
private final class BrushCursorView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let extent = min(bounds.width, bounds.height)
        guard extent > 0 else { return }

        let outerWidth = min(3, extent)
        let path = NSBezierPath(
            ovalIn: bounds.insetBy(
                dx: outerWidth * 0.5,
                dy: outerWidth * 0.5
            )
        )
        path.lineWidth = outerWidth
        NSColor.black.withAlphaComponent(0.78).setStroke()
        path.stroke()

        path.lineWidth = min(1, outerWidth * 0.5)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.stroke()
    }
}

@MainActor
final class InteractiveMetalView: MTKView {
    private enum DragMode {
        case drawing
        case panning(lastLocal: ScreenPoint)
    }

    let controller: EditorSessionController
    let gridRenderer: GridRenderer
    private let requestEditorFocus: @MainActor () -> Void
    private var dragMode: DragMode?
    private var lastPointerCancellationGeneration: UInt
    private var screenObserver: NSObjectProtocol?
    private let brushCursorView = BrushCursorView(frame: .zero)
    private var brushDiameter: Float = 20
    private var brushCursorLocation: CGPoint?
    private var brushTrackingArea: NSTrackingArea?

    private static let invisibleCursor: NSCursor = {
        let size = NSSize(width: 1, height: 1)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    init(
        frame: CGRect,
        controller: EditorSessionController,
        renderer: GridRenderer,
        requestEditorFocus: @escaping @MainActor () -> Void,
        pointerCancellationGeneration: UInt
    ) {
        self.controller = controller
        gridRenderer = renderer
        self.requestEditorFocus = requestEditorFocus
        lastPointerCancellationGeneration = pointerCancellationGeneration
        super.init(frame: frame, device: renderer.device)
        brushCursorView.isHidden = true
        addSubview(brushCursorView)
    }

    required init(coder: NSCoder) {
        fatalError("InteractiveMetalView requires a GridRenderer")
    }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.invisibleCursor)
    }

    override func updateTrackingAreas() {
        if let brushTrackingArea {
            removeTrackingArea(brushTrackingArea)
        }
        super.updateTrackingAreas()
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        brushTrackingArea = area
    }

    override func layout() {
        super.layout()
        updateBrushCursorFrame()
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        guard let window else { return }
        updateRefreshRate(for: window)
        window.invalidateCursorRects(for: self)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.updateRefreshRate(for: window)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        updateBrushCursorLocation(with: event)
        requestEditorFocus()
        let local = localPoint(event)
        guard let coordinateTransform else {
            dragMode = nil
            return
        }
        if controller.isSpaceDown {
            dragMode = .panning(lastLocal: local)
        } else {
            controller.handleStrokeSample(
                .mouse(
                    position: coordinateTransform.map(local),
                    timestamp: event.timestamp,
                    phase: .began
                )
            )
            dragMode = .drawing
        }
    }

    override func mouseDragged(with event: NSEvent) {
        updateBrushCursorLocation(with: event)
        let local = localPoint(event)
        guard let coordinateTransform else {
            cancelPointerInteraction()
            return
        }
        switch dragMode {
        case let .panning(lastLocal):
            controller.pan(
                byScreenDelta: coordinateTransform.mapDelta(
                    local.simd - lastLocal.simd
                )
            )
            dragMode = .panning(lastLocal: local)
        case .drawing:
            controller.handleStrokeSample(
                .mouse(
                    position: coordinateTransform.map(local),
                    timestamp: event.timestamp,
                    phase: .moved
                )
            )
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        updateBrushCursorLocation(with: event)
        defer { dragMode = nil }
        guard case .drawing = dragMode else { return }
        guard let coordinateTransform else {
            cancelPointerInteraction()
            return
        }
        controller.handleStrokeSample(
            .mouse(
                position: coordinateTransform.map(localPoint(event)),
                timestamp: event.timestamp,
                phase: .ended
            )
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinateTransform else { return }
        controller.zoom(
            by: exp(Float(-event.scrollingDeltaY) * 0.01),
            anchor: coordinateTransform.map(localPoint(event))
        )
        updateBrushCursorLocation(with: event)
    }

    override func magnify(with event: NSEvent) {
        requestEditorFocus()
        guard let coordinateTransform else { return }
        controller.zoom(
            by: max(0.01, 1 + Float(event.magnification)),
            anchor: coordinateTransform.map(localPoint(event))
        )
        updateBrushCursorLocation(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateBrushCursorLocation(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateBrushCursorLocation(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        brushCursorLocation = nil
        brushCursorView.isHidden = true
    }

    func updateBrushCursor(diameter: Float) {
        guard diameter.isFinite, diameter > 0 else {
            brushCursorView.isHidden = true
            return
        }
        brushDiameter = diameter
        updateBrushCursorFrame()
    }

    func applyPointerCancellation(generation: UInt) {
        guard generation != lastPointerCancellationGeneration else { return }
        lastPointerCancellationGeneration = generation
        dragMode = nil
    }

    var hasActivePointerInteractionForTesting: Bool {
        dragMode != nil
    }

    var brushCursorFrameForTesting: CGRect {
        brushCursorView.frame
    }

    var isBrushCursorVisibleForTesting: Bool {
        !brushCursorView.isHidden
    }

    private func localPoint(_ event: NSEvent) -> ScreenPoint {
        let local = convert(event.locationInWindow, from: nil)
        return ScreenPoint(x: Float(local.x), y: Float(local.y))
    }

    private func updateBrushCursorLocation(with event: NSEvent) {
        let point = localPoint(event)
        brushCursorLocation = CGPoint(
            x: CGFloat(point.x),
            y: CGFloat(point.y)
        )
        brushCursorView.isHidden = false
        updateBrushCursorFrame()
    }

    private func updateBrushCursorFrame() {
        guard let brushCursorLocation,
              bounds.width > 0,
              bounds.height > 0,
              drawableSize.width > 0,
              drawableSize.height > 0
        else { return }

        let scaleX = drawableSize.width / bounds.width
        let scaleY = drawableSize.height / bounds.height
        let contentScale = (scaleX + scaleY) * 0.5
        guard contentScale.isFinite, contentScale > 0 else { return }

        let diameter = CGFloat(brushDiameter * gridRenderer.viewport.zoom)
            / contentScale
        brushCursorView.frame = CGRect(
            x: brushCursorLocation.x - diameter * 0.5,
            y: brushCursorLocation.y - diameter * 0.5,
            width: diameter,
            height: diameter
        )
        brushCursorView.needsDisplay = true
    }

    private var coordinateTransform: DrawableCoordinateTransform? {
        DrawableCoordinateTransform(
            viewOrigin: ScreenPoint(
                x: Float(bounds.minX),
                y: Float(bounds.minY)
            ),
            viewSize: SIMD2(
                Float(bounds.width),
                Float(bounds.height)
            ),
            drawableSize: SIMD2(
                Float(drawableSize.width),
                Float(drawableSize.height)
            )
        )
    }

    private func cancelPointerInteraction() {
        controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 0, y: 0),
                timestamp: ProcessInfo.processInfo.systemUptime,
                phase: .cancelled
            )
        )
        dragMode = nil
    }

    private func updateRefreshRate(for window: NSWindow) {
        preferredFramesPerSecond =
            window.screen?.maximumFramesPerSecond ?? 60
    }
}
#endif
