#if os(macOS)
import AppKit
import MetalKit
import MetalRenderer
import PatternEngine

@MainActor
final class InteractiveMetalView: MTKView {
    private enum DragMode {
        case drawing
        case panning(last: ScreenPoint)
    }

    let gridRenderer: GridRenderer
    private var dragMode: DragMode?
    private var spaceIsDown = false
    private var resignObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init(frame: CGRect, renderer: GridRenderer) {
        gridRenderer = renderer
        super.init(frame: frame, device: renderer.device)
    }

    required init(coder: NSCoder) {
        fatalError("InteractiveMetalView requires a GridRenderer")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        guard let window else {
            cancelActiveAndResetGestureState()
            resignObserver = nil
            screenObserver = nil
            return
        }
        window.makeFirstResponder(self)
        preferredFramesPerSecond = window.screen?.maximumFramesPerSecond ?? 60
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelActiveAndResetGestureState()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.preferredFramesPerSecond =
                    window?.screen?.maximumFramesPerSecond ?? 60
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard gridRenderer.isIdle else {
            dragMode = nil
            return
        }
        let point = backingPoint(event)
        if spaceIsDown {
            dragMode = .panning(last: point)
        } else {
            gridRenderer.handle(
                .mouse(position: point, timestamp: event.timestamp, phase: .began)
            )
            dragMode = gridRenderer.hasActiveStroke ? .drawing : nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = backingPoint(event)
        switch dragMode {
        case let .panning(last):
            gridRenderer.pan(
                byScreenDelta: SIMD2(point.x - last.x, point.y - last.y)
            )
            dragMode = .panning(last: point)
        case .drawing:
            guard gridRenderer.hasActiveStroke else {
                dragMode = nil
                return
            }
            gridRenderer.handle(
                .mouse(position: point, timestamp: event.timestamp, phase: .moved)
            )
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragMode = nil }
        guard case .drawing = dragMode else { return }
        guard gridRenderer.hasActiveStroke else { return }
        gridRenderer.handle(
            .mouse(
                position: backingPoint(event),
                timestamp: event.timestamp,
                phase: .ended
            )
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard gridRenderer.isIdle else { return }
        gridRenderer.zoom(
            by: exp(Float(-event.scrollingDeltaY) * 0.01),
            anchor: backingPoint(event)
        )
    }

    override func magnify(with event: NSEvent) {
        guard gridRenderer.isIdle else { return }
        gridRenderer.zoom(
            by: max(0.01, 1 + Float(event.magnification)),
            anchor: backingPoint(event)
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceIsDown = true
        } else if event.keyCode == 53 {
            cancelIfActive()
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceIsDown = false
        } else {
            super.keyUp(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelIfActive()
    }

    override func resignFirstResponder() -> Bool {
        cancelActiveAndResetGestureState()
        return super.resignFirstResponder()
    }

    private func backingPoint(_ event: NSEvent) -> ScreenPoint {
        let local = convert(event.locationInWindow, from: nil)
        let localPoint = ScreenPoint(
            x: Float(local.x - bounds.minX),
            y: Float(local.y - bounds.minY)
        )
        return localPoint.mapped(
            from: PatternSize(
                width: Float(bounds.width),
                height: Float(bounds.height)
            ),
            to: PatternSize(
                width: Float(drawableSize.width),
                height: Float(drawableSize.height)
            )
        )
    }

    private func cancelActiveAndResetGestureState() {
        cancelIfActive()
        spaceIsDown = false
        dragMode = nil
    }

    private func cancelIfActive() {
        guard gridRenderer.hasActiveStroke else { return }
        gridRenderer.handle(
            .mouse(
                position: ScreenPoint(x: 0, y: 0),
                timestamp: ProcessInfo.processInfo.systemUptime,
                phase: .cancelled
            )
        )
        dragMode = nil
    }
}
#endif
