#if os(macOS)
import AppKit
import MetalKit
import MetalRenderer
import PatternEngine

@MainActor
final class InteractiveMetalView: MTKView {
    private enum DragMode {
        case drawing
        case panning(lastLocal: ScreenPoint)
    }

    let controller: EditorSessionController
    let gridRenderer: GridRenderer
    private var dragMode: DragMode?

    init(
        frame: CGRect,
        controller: EditorSessionController,
        renderer: GridRenderer
    ) {
        self.controller = controller
        gridRenderer = renderer
        super.init(frame: frame, device: renderer.device)
    }

    required init(coder: NSCoder) {
        fatalError("InteractiveMetalView requires a GridRenderer")
    }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
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
    }

    override func magnify(with event: NSEvent) {
        guard let coordinateTransform else { return }
        controller.zoom(
            by: max(0.01, 1 + Float(event.magnification)),
            anchor: coordinateTransform.map(localPoint(event))
        )
    }

    private func localPoint(_ event: NSEvent) -> ScreenPoint {
        let local = convert(event.locationInWindow, from: nil)
        return ScreenPoint(x: Float(local.x), y: Float(local.y))
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
}
#endif
