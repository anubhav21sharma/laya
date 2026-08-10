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
    private var brushInputAdapter = BrushInputAdapter()
    private var tabletEventDeduplicator = TabletEventDeduplicator()
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
        brushCursorView.setAccessibilityElement(true)
        brushCursorView.setAccessibilityIdentifier("Brush Cursor")
        brushCursorView.setAccessibilityRole(.image)
        brushCursorView.setAccessibilityLabel("Brush Cursor")
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
        requestDraw()
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
        tabletEventDeduplicator.reset()
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
            guard shouldDeliverTabletEvent(
                event,
                phase: .began,
                position: coordinateTransform.map(local)
            ) else {
                dragMode = nil
                return
            }
            let samples = brushInputAdapter.orderedSamples(
                for: event,
                phase: .began,
                position: coordinateTransform.map(local)
            )
            guard !samples.isEmpty else {
                dragMode = nil
                return
            }
            deliver(samples)
            dragMode = .drawing
        }
    }

    override func tabletProximity(with event: NSEvent) {
        brushInputAdapter.updateTabletProximity(with: event)
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
            requestDraw()
        case .drawing:
            let position = coordinateTransform.map(local)
            guard shouldDeliverTabletEvent(
                event,
                phase: .moved,
                position: position
            ) else { return }
            let samples = brushInputAdapter.orderedSamples(
                for: event,
                phase: .moved,
                position: position
            )
            guard !samples.isEmpty else {
                cancelPointerInteraction()
                return
            }
            deliver(samples)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        updateBrushCursorLocation(with: event)
        defer {
            dragMode = nil
            tabletEventDeduplicator.reset()
        }
        guard case .drawing = dragMode else { return }
        guard let coordinateTransform else {
            cancelPointerInteraction()
            return
        }
        let position = coordinateTransform.map(localPoint(event))
        guard shouldDeliverTabletEvent(
            event,
            phase: .ended,
            position: position
        ) else { return }
        let samples = brushInputAdapter.orderedSamples(
            for: event,
            phase: .ended,
            position: position
        )
        guard !samples.isEmpty else {
            cancelPointerInteraction()
            return
        }
        deliver(samples)
    }

    override func tabletPoint(with event: NSEvent) {
        updateBrushCursorLocation(with: event)
        guard case .drawing = dragMode,
              let coordinateTransform
        else { return }
        let position = coordinateTransform.map(localPoint(event))
        guard shouldDeliverTabletEvent(
            event,
            phase: .moved,
            position: position
        ) else { return }
        let samples = brushInputAdapter.orderedSamples(
            for: event,
            phase: .moved,
            position: position
        )
        guard !samples.isEmpty else {
            cancelPointerInteraction()
            return
        }
        deliver(samples)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinateTransform else { return }
        controller.zoom(
            by: exp(Float(-event.scrollingDeltaY) * 0.01),
            anchor: coordinateTransform.map(localPoint(event))
        )
        updateBrushCursorLocation(with: event)
        requestDraw()
    }

    override func magnify(with event: NSEvent) {
        requestEditorFocus()
        guard let coordinateTransform else { return }
        controller.zoom(
            by: max(0.01, 1 + Float(event.magnification)),
            anchor: coordinateTransform.map(localPoint(event))
        )
        updateBrushCursorLocation(with: event)
        requestDraw()
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
        brushCursorView.setAccessibilityValue(
            "\(Int(diameter.rounded())) px"
        )
        updateBrushCursorFrame()
    }

    func applyPointerCancellation(generation: UInt) {
        guard generation != lastPointerCancellationGeneration else { return }
        lastPointerCancellationGeneration = generation
        dragMode = nil
        tabletEventDeduplicator.reset()
        requestDraw()
    }

    func requestDraw() {
        needsDisplay = true
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

    var brushDiameterForTesting: Float {
        brushDiameter
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
        tabletEventDeduplicator.reset()
        requestDraw()
    }

    private func shouldDeliverTabletEvent(
        _ event: NSEvent,
        phase: StrokePhase,
        position: ScreenPoint
    ) -> Bool {
        guard event.type == .tabletPoint || event.subtype == .tabletPoint else {
            return true
        }
        return tabletEventDeduplicator.shouldDeliver(
            TabletEventSignature(
                timestamp: event.timestamp,
                position: position,
                pressure: event.pressure,
                deviceIdentifier: event.deviceID,
                phase: phase
            )
        )
    }

    private func deliver(_ samples: [StrokeSample]) {
        controller.handleStrokeSamples(samples)
        requestDraw()
    }

    private func updateRefreshRate(for window: NSWindow) {
        preferredFramesPerSecond =
            window.screen?.maximumFramesPerSecond ?? 60
    }
}
#elseif os(iOS)
import MetalKit
import MetalRenderer
import PatternEngine
import UIKit

@MainActor
final class InteractiveMetalView: MTKView {
    let controller: EditorSessionController
    let gridRenderer: GridRenderer
    private let requestEditorFocus: @MainActor () -> Void
    private var lastPointerCancellationGeneration: UInt
    private var brushInputAdapter = BrushInputAdapter()
    private var activeTouch: UITouch?
    private var activeInputGeneration: UInt64?
    private var nextInputGeneration: UInt64 = 1
    private var pendingEstimatedTouches =
        PendingEstimatedInputRegistry<UITouch>()

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
        isMultipleTouchEnabled = true
    }

    required init(coder: NSCoder) {
        fatalError("InteractiveMetalView requires a GridRenderer")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let screen = window?.screen else { return }
        preferredFramesPerSecond = screen.maximumFramesPerSecond
        requestDraw()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        requestDraw()
    }

    override func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        guard activeTouch == nil,
              let touch = BrushInputBatchPolicy.primaryInput(
                  Array(touches),
                  isPencil: { $0.type == .pencil }
              )
        else { return }
        requestEditorFocus()
        pendingEstimatedTouches.removeAll()
        brushInputAdapter.beginTouch()
        activeTouch = touch
        activeInputGeneration = takeInputGeneration()
        deliver(
            touch,
            event: event,
            terminalPhase: .began,
            includesPrediction: true
        )
    }

    override func touchesMoved(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        guard let touch = matchingActiveTouch(in: touches) else { return }
        deliver(
            touch,
            event: event,
            terminalPhase: .moved,
            includesPrediction: true
        )
    }

    override func touchesEnded(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        guard let touch = matchingActiveTouch(in: touches) else { return }
        deliver(
            touch,
            event: event,
            terminalPhase: .ended,
            includesPrediction: false
        )
        activeTouch = nil
        activeInputGeneration = nil
        if pendingEstimatedTouches.isEmpty {
            brushInputAdapter.endTouch()
        }
    }

    override func touchesCancelled(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        guard let touch = matchingActiveTouch(in: touches) else { return }
        deliver(
            touch,
            event: nil,
            terminalPhase: .cancelled,
            includesPrediction: false
        )
        resetTouchState()
    }

    override func touchesEstimatedPropertiesUpdated(
        _ touches: Set<UITouch>
    ) {
        let matching = touches.compactMap {
            touch -> (Int, UITouch, UInt64)? in
            let state = brushInputAdapter.estimationState(for: touch)
            guard let index = state.index,
                  pendingEstimatedTouches.containsIdentical(
                      touch,
                      for: index
                  ),
                  let inputGeneration =
                      pendingEstimatedTouches.inputGeneration(for: index)
            else { return nil }
            return (index, touch, inputGeneration)
        }
        .sorted {
            if $0.1.timestamp == $1.1.timestamp {
                return $0.0 < $1.0
            }
            return $0.1.timestamp < $1.1.timestamp
        }
        for (index, touch, inputGeneration) in matching {
            if let sample = brushInputAdapter.estimatedUpdate(
                for: touch,
                in: self
            ) {
                controller.handleStrokeSample(
                    sample,
                    inputGeneration: inputGeneration
                )
                requestDraw()
            }
            let state = brushInputAdapter.estimationState(for: touch)
            precondition(state.index == index)
            pendingEstimatedTouches.record(
                touch,
                index: index,
                expecting: state.expecting,
                isPredicted: false,
                inputGeneration: inputGeneration
            )
        }
        if activeTouch == nil, pendingEstimatedTouches.isEmpty {
            brushInputAdapter.endTouch()
        }
    }

    func applyPointerCancellation(generation: UInt) {
        guard generation != lastPointerCancellationGeneration else { return }
        lastPointerCancellationGeneration = generation
        resetTouchState()
        requestDraw()
    }

    func requestDraw() {
        setNeedsDisplay()
    }

    private func matchingActiveTouch(
        in touches: Set<UITouch>
    ) -> UITouch? {
        guard let activeTouch else { return nil }
        return touches.first(where: { $0 === activeTouch })
    }

    private func takeInputGeneration() -> UInt64 {
        precondition(
            nextInputGeneration < UInt64.max,
            "Input generation exhausted"
        )
        let generation = nextInputGeneration
        nextInputGeneration += 1
        return generation
    }

    private func deliver(
        _ touch: UITouch,
        event: UIEvent?,
        terminalPhase: StrokePhase,
        includesPrediction: Bool
    ) {
        guard coordinateTransform != nil,
              let inputGeneration = activeInputGeneration
        else {
            cancelActiveTouch()
            return
        }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        let predicted = includesPrediction
            ? event?.predictedTouches(for: touch) ?? []
            : []
        let predictionBatch = BrushInputBatchPolicy.predictionBatch(
            predicted,
            maximumCount: PredictionAdmissionLimits.maximumNormalizedSampleCount
        )
        pendingEstimatedTouches.discardPredicted()
        for ordinaryTouch in coalesced {
            let state = brushInputAdapter.estimationState(
                for: ordinaryTouch
            )
            pendingEstimatedTouches.record(
                ordinaryTouch,
                index: state.index,
                expecting: state.expecting,
                isPredicted: false,
                inputGeneration: inputGeneration
            )
        }
        if !coalesced.contains(where: { $0 === touch }) {
            let state = brushInputAdapter.estimationState(for: touch)
            pendingEstimatedTouches.record(
                touch,
                index: state.index,
                expecting: state.expecting,
                isPredicted: false,
                inputGeneration: inputGeneration
            )
        }
        for predictedTouch in predictionBatch.admitted {
            let state = brushInputAdapter.estimationState(
                for: predictedTouch
            )
            pendingEstimatedTouches.record(
                predictedTouch,
                index: state.index,
                expecting: state.expecting,
                isPredicted: true,
                inputGeneration: inputGeneration
            )
        }
        let samples = brushInputAdapter.orderedSamples(
            coalescedTouches: coalesced,
            actualTouch: touch,
            predictedTouches: predictionBatch.admitted,
            terminalPhase: terminalPhase,
            in: self
        ).compactMap(mapToDrawable)
        guard !samples.isEmpty else {
            cancelActiveTouch()
            return
        }
        controller.handleStrokeSamples(
            samples,
            inputGeneration: inputGeneration,
            submittedPredictionSampleCount:
                predictionBatch.submittedCount
        )
        requestDraw()
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

    private func mapToDrawable(_ sample: StrokeSample) -> StrokeSample? {
        guard let coordinateTransform else { return nil }
        return StrokeSample.validated(
            position: coordinateTransform.map(sample.position),
            pressure: sample.pressure,
            timestamp: sample.timestamp,
            phase: sample.phase,
            source: sample.source,
            kind: sample.kind,
            capabilities: sample.capabilities,
            altitude: sample.altitude,
            azimuth: sample.azimuth,
            roll: sample.roll,
            tangentialPressure: sample.tangentialPressure,
            deviceIdentifier: sample.deviceIdentifier,
            estimationUpdateIndex: sample.estimationUpdateIndex,
            estimatedProperties: sample.estimatedProperties,
            estimatedPropertiesExpectingUpdates:
                sample.estimatedPropertiesExpectingUpdates
        )
    }

    private func cancelActiveTouch() {
        controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 0, y: 0),
                timestamp: ProcessInfo.processInfo.systemUptime,
                phase: .cancelled
            ),
            inputGeneration: activeInputGeneration
        )
        resetTouchState()
        requestDraw()
    }

    private func resetTouchState() {
        activeTouch = nil
        activeInputGeneration = nil
        pendingEstimatedTouches.removeAll()
        brushInputAdapter.endTouch()
    }
}
#endif
