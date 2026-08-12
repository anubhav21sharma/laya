#if os(macOS)
import AppKit
import MetalKit
import MetalRenderer
import PatternEngine

@MainActor
private final class BrushCursorView: NSView {
    static let strokeInset: CGFloat = 1.5

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    private var descriptor: BrushCursorDescriptor?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let descriptor, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let offset = SIMD2(
            Float(Self.strokeInset) - descriptor.envelopeBounds.minimum.x,
            Float(Self.strokeInset) - descriptor.envelopeBounds.minimum.y
        )
        if descriptor.envelopeBounds != descriptor.coreBounds {
            let envelope = NSBezierPath(rect: CGRect(
                x: CGFloat(
                    descriptor.envelopeBounds.minimum.x + offset.x
                ),
                y: CGFloat(
                    descriptor.envelopeBounds.minimum.y + offset.y
                ),
                width: CGFloat(descriptor.envelopeBounds.width),
                height: CGFloat(descriptor.envelopeBounds.height)
            ))
            envelope.lineWidth = 1
            envelope.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.55).setStroke()
            envelope.stroke()
        }

        stroke(component: descriptor.primaryComponent, offset: offset)
        if let secondary = descriptor.secondaryComponent {
            stroke(component: secondary, offset: offset)
        }
    }

    func update(descriptor: BrushCursorDescriptor) {
        self.descriptor = descriptor
        needsDisplay = true
    }

    var renderedLayerCountForTesting: Int {
        guard let descriptor else { return 0 }
        return layerCount(descriptor.primaryComponent)
            + (descriptor.secondaryComponent.map(layerCount) ?? 0)
    }

    private func stroke(
        component: BrushCursorComponentDescriptor,
        offset: SIMD2<Float>
    ) {
        if let secondary = component.secondary {
            switch component.secondaryCombination {
            case .replace:
                stroke(path(for: secondary, offset: offset))
            case .multiply, .minimum, .maximum, nil:
                stroke(path(for: component.primary, offset: offset))
                stroke(path(for: secondary, offset: offset))
            }
        } else {
            stroke(path(for: component.primary, offset: offset))
        }
    }

    private func layerCount(
        _ component: BrushCursorComponentDescriptor
    ) -> Int {
        guard component.secondary != nil else { return 1 }
        return component.secondaryCombination == .replace ? 1 : 2
    }

    private func path(
        for layer: BrushCursorLayerDescriptor,
        offset: SIMD2<Float>
    ) -> NSBezierPath {
        let path: NSBezierPath
        switch layer.shape {
        case .analyticEllipse:
            path = NSBezierPath(ovalIn: CGRect(x: -1, y: -1, width: 2, height: 2))
        case .analyticRectangle:
            path = NSBezierPath(rect: CGRect(x: -1, y: -1, width: 2, height: 2))
        case let .contour(points):
            path = NSBezierPath()
            if let first = points.first {
                path.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
                for point in points.dropFirst() {
                    path.line(to: CGPoint(
                        x: CGFloat(point.x),
                        y: CGFloat(point.y)
                    ))
                }
                path.close()
            }
        }
        let transform = layer.normalizedTipToLogical
        path.transform(using: AffineTransform(
            m11: CGFloat(transform.xAxis.x),
            m12: CGFloat(transform.xAxis.y),
            m21: CGFloat(transform.yAxis.x),
            m22: CGFloat(transform.yAxis.y),
            tX: CGFloat(transform.translation.x + offset.x),
            tY: CGFloat(transform.translation.y + offset.y)
        ))
        return path
    }

    private func stroke(_ path: NSBezierPath) {
        let extent = min(bounds.width, bounds.height)
        let outerWidth = min(3, extent)
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
    private var brushCursorSample: StrokeSample?
    private var brushCursorDirection: Float = 0
    private var brushCursorDescriptor: BrushCursorDescriptor?
    private var brushCursorSupportFrame: CGRect = .zero
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
        updateBrushCursorFrame()
        window.invalidateCursorRects(for: self)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.updateRefreshRate(for: window)
                self.updateBrushCursorFrame()
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBrushCursorFrame()
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
        brushCursorSample = nil
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
        brushCursorSupportFrame
    }

    var brushCursorDrawingFrameForTesting: CGRect {
        brushCursorView.frame
    }

    var isBrushCursorVisibleForTesting: Bool {
        !brushCursorView.isHidden
    }

    var brushDiameterForTesting: Float {
        brushDiameter
    }

    var brushCursorDescriptorForTesting: BrushCursorDescriptor? {
        brushCursorDescriptor
    }

    var brushCursorRenderedLayerCountForTesting: Int {
        brushCursorView.renderedLayerCountForTesting
    }

    var brushCursorAccessibilityValueForTesting: String? {
        brushCursorView.accessibilityValue() as? String
    }

    private func localPoint(_ event: NSEvent) -> ScreenPoint {
        let local = convert(event.locationInWindow, from: nil)
        return ScreenPoint(x: Float(local.x), y: Float(local.y))
    }

    private func updateBrushCursorLocation(with event: NSEvent) {
        let point = localPoint(event)
        if let previous = brushCursorLocation {
            let delta = SIMD2(
                point.x - Float(previous.x),
                point.y - Float(previous.y)
            )
            if hypot(delta.x, delta.y) > 0.001 {
                brushCursorDirection = atan2(delta.y, delta.x)
            }
        }
        brushCursorLocation = CGPoint(
            x: CGFloat(point.x),
            y: CGFloat(point.y)
        )
        brushCursorSample = brushInputAdapter.cursorSample(
            for: event,
            position: point
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

        guard let brush = gridRenderer.preparedBrush(for: .draw) else {
            brushCursorView.isHidden = true
            brushCursorDescriptor = nil
            return
        }
        let sample = brushCursorSample
        let capabilities = sample?.capabilities ?? []
        guard let input = try? BrushCursorInput(
            nominalDiameter: brushDiameter,
            pressure: capabilities.contains(.pressure)
                ? sample?.pressure
                : nil,
            altitude: capabilities.contains(.altitude)
                ? sample?.altitude
                : nil,
            azimuth: capabilities.contains(.azimuth)
                ? sample?.azimuth
                : nil,
            roll: capabilities.contains(.roll) ? sample?.roll : nil,
            tangentialPressure: capabilities.contains(.tangentialPressure)
                ? sample?.tangentialPressure
                : nil,
            direction: brushCursorDirection,
            deformation: .identity,
            viewportScale: gridRenderer.viewport.zoom,
            backingScale: Float(contentScale)
        ) else {
            brushCursorView.isHidden = true
            brushCursorDescriptor = nil
            return
        }
        guard let descriptor = try? brush.cursorDescriptor(input: input) else {
            brushCursorView.isHidden = true
            brushCursorDescriptor = nil
            return
        }
        brushCursorDescriptor = descriptor
        let cursorBounds = descriptor.envelopeBounds
        brushCursorSupportFrame = CGRect(
            x: brushCursorLocation.x + CGFloat(cursorBounds.minimum.x),
            y: brushCursorLocation.y + CGFloat(cursorBounds.minimum.y),
            width: CGFloat(cursorBounds.width),
            height: CGFloat(cursorBounds.height)
        )
        brushCursorView.frame = brushCursorSupportFrame.insetBy(
            dx: -BrushCursorView.strokeInset,
            dy: -BrushCursorView.strokeInset
        )
        brushCursorView.setAccessibilityValue(
            "\(Int(cursorBounds.width.rounded())) × "
                + "\(Int(cursorBounds.height.rounded())) px"
        )
        brushCursorView.update(descriptor: descriptor)
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
