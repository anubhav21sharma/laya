#if os(macOS)
import AppKit
import EditorCore
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Brush cursor integration", .serialized)
struct BrushCursorIntegrationTests {
    @Test
    @MainActor
    func hoverUsesTheActiveCompiledTipAndCurrentViewportScale() throws {
        guard let renderer = try makeControllerRenderer() else { return }
        let controller = EditorSessionController(renderer: renderer)
        let view = cursorView(controller: controller, renderer: renderer)
        view.updateBrushCursor(diameter: 40)

        let move = try #require(cursorPointerEvent(
            type: .mouseMoved,
            location: CGPoint(x: 30, y: 60)
        ))
        view.mouseMoved(with: move)

        #expect(view.brushCursorDescriptorForTesting?.isCircle == true)
        #expect(view.brushCursorFrameForTesting.midX == 30)
        #expect(view.brushCursorFrameForTesting.midY == 40)
        #expect(view.brushCursorFrameForTesting.width == 20)
        #expect(view.brushCursorFrameForTesting.height == 20)
        #expect(view.brushCursorDrawingFrameForTesting.width == 23)
        #expect(view.brushCursorDrawingFrameForTesting.height == 23)

        controller.zoom(by: 2, anchor: ScreenPoint(x: 30, y: 40))
        view.updateBrushCursor(diameter: 40)

        #expect(view.brushCursorFrameForTesting.width == 40)
        #expect(view.brushCursorFrameForTesting.height == 40)
    }

    @Test
    @MainActor
    func brushSelectionAndSizeChangesRefreshBroadCursorImmediately()
        async throws
    {
        guard let renderer = try makeControllerRenderer(),
              let queue = renderer.device.makeCommandQueue()
        else { return }
        let controller = EditorSessionController(renderer: renderer)
        let view = cursorView(controller: controller, renderer: renderer)
        let move = try #require(cursorPointerEvent(
            type: .mouseMoved,
            location: CGPoint(x: 50, y: 50)
        ))
        view.updateBrushCursor(diameter: 40)
        view.mouseMoved(with: move)
        let roundFrame = view.brushCursorFrameForTesting

        let compiler = BrushCompiler(
            device: renderer.device,
            commandQueue: queue,
            profile: try BrushDeviceProfile(
                registryID: renderer.device.registryID,
                recommendedWorkingSetBytes: max(
                    renderer.device.recommendedMaxWorkingSetSize,
                    64 * 1_024 * 1_024
                ),
                maximumWorkingTextureDimension: 4_096,
                brushCacheBudgetBytes: 64 * 1_024 * 1_024,
                targetFramesPerSecond: 120
            ),
            pipelineLibrary: DepositionPipelineLibrary(
                device: renderer.device,
                library: renderer.library
            )
        )
        let chisel = try await compiler.compileAndActivate(
            definition: ProfessionalBrushCatalog.chiselMarker.definition
        )
        try renderer.activateDrawBrush(chisel)
        view.updateBrushCursor(diameter: 40)

        let broadFrame = view.brushCursorFrameForTesting
        #expect(view.brushCursorDescriptorForTesting?.isCircle == false)
        #expect(max(broadFrame.width, broadFrame.height)
            > min(broadFrame.width, broadFrame.height) * 2)
        #expect(broadFrame.width != roundFrame.width)

        view.updateBrushCursor(diameter: 80)
        #expect(abs(view.brushCursorFrameForTesting.width - broadFrame.width * 2) < 0.01)
        #expect(abs(view.brushCursorFrameForTesting.height - broadFrame.height * 2) < 0.01)

        view.mouseExited(with: move)
        #expect(!view.isBrushCursorVisibleForTesting)
    }

    @Test
    @MainActor
    func compositeHoverDrawsAllLayersAndUsesUnionForFrameAndAccessibility()
        async throws
    {
        guard let renderer = try makeControllerRenderer(),
              let queue = renderer.device.makeCommandQueue()
        else { return }
        let compiler = BrushCompiler(
            device: renderer.device,
            commandQueue: queue,
            profile: try BrushDeviceProfile(
                registryID: renderer.device.registryID,
                recommendedWorkingSetBytes: max(
                    renderer.device.recommendedMaxWorkingSetSize,
                    64 * 1_024 * 1_024
                ),
                maximumWorkingTextureDimension: 4_096,
                brushCacheBudgetBytes: 64 * 1_024 * 1_024,
                targetFramesPerSecond: 120
            ),
            pipelineLibrary: DepositionPipelineLibrary(
                device: renderer.device,
                library: renderer.library
            )
        )
        let brush = try await compiler.compileAndActivate(
            definition: try compositeCursorDefinition()
        )
        try renderer.activateDrawBrush(brush)
        let controller = EditorSessionController(renderer: renderer)
        let view = cursorView(controller: controller, renderer: renderer)
        view.updateBrushCursor(diameter: 40)
        view.mouseMoved(with: try #require(cursorPointerEvent(
            type: .mouseMoved,
            location: CGPoint(x: 50, y: 50)
        )))

        let descriptor = try #require(view.brushCursorDescriptorForTesting)
        #expect(descriptor.secondaryComponent != nil)
        #expect(view.brushCursorRenderedLayerCountForTesting == 3)
        #expect(abs(
            Float(view.brushCursorFrameForTesting.width)
                - descriptor.envelopeBounds.width
        ) < 0.001)
        #expect(abs(
            Float(view.brushCursorFrameForTesting.height)
                - descriptor.envelopeBounds.height
        ) < 0.001)
        #expect(
            view.brushCursorAccessibilityValueForTesting
                == "\(Int(descriptor.envelopeBounds.width.rounded())) × "
                    + "\(Int(descriptor.envelopeBounds.height.rounded())) px"
        )
    }

    @Test
    @MainActor
    func backingScaleChangesRefreshWithoutAnotherPointerEvent() throws {
        guard let renderer = try makeControllerRenderer() else { return }
        let controller = EditorSessionController(renderer: renderer)
        let view = cursorView(controller: controller, renderer: renderer)
        view.updateBrushCursor(diameter: 40)
        let move = try #require(cursorPointerEvent(
            type: .mouseMoved,
            location: CGPoint(x: 50, y: 50)
        ))
        view.mouseMoved(with: move)
        #expect(view.brushCursorFrameForTesting.width == 20)

        view.drawableSize = CGSize(width: 100, height: 100)
        view.viewDidChangeBackingProperties()

        #expect(view.brushCursorFrameForTesting.width == 40)
        #expect(view.brushCursorFrameForTesting.midX == 50)
        #expect(view.brushCursorFrameForTesting.midY == 50)
    }

    @Test
    @MainActor
    func cursorNormalizationUsesTabletCapabilitiesWithoutBatchAllocation() throws {
        var adapter = BrushInputAdapter()
        adapter.updateTabletProximity(
            deviceIdentifier: 41,
            capabilityMask: BrushInputAdapter.TabletCapability.pressure
                | BrushInputAdapter.TabletCapability.tiltX
                | BrushInputAdapter.TabletCapability.tiltY,
            isEntering: true
        )
        let tablet = try #require(adapter.cursorSample(
            BrushInputAdapter.NativeSample(
                position: ScreenPoint(x: 3, y: 4),
                pressure: 0.7,
                timestamp: 1,
                tilt: SIMD2(0.3, 0.4),
                deviceIdentifier: 41,
                phase: .moved,
                isTablet: true
            )
        ))
        let mouse = try #require(adapter.cursorSample(
            BrushInputAdapter.NativeSample(
                position: ScreenPoint(x: 3, y: 4),
                pressure: 0,
                timestamp: 1,
                phase: .moved,
                isTablet: false
            )
        ))

        #expect(tablet.capabilities == [.pressure, .altitude, .azimuth])
        #expect(tablet.pressure == 0.7)
        #expect(tablet.altitude != nil)
        #expect(tablet.azimuth != nil)
        #expect(mouse.capabilities.isEmpty)
    }

    @Test
    @MainActor
    func controlledSingleDabsMeetCursorSupportAgreement() async throws {
        let cases: [(name: String, definition: BrushDefinition)] = [
            (
                "round",
                try cursorAnalyticDefinition(
                    id: "cursor.raster.round",
                    shape: .hardRound,
                    aspect: 1,
                    rotation: 0
                )
            ),
            (
                "ellipse",
                try cursorAnalyticDefinition(
                    id: "cursor.raster.ellipse",
                    shape: .hardRound,
                    aspect: 0.45,
                    rotation: 0
                )
            ),
            (
                "chisel",
                try cursorAnalyticDefinition(
                    id: "cursor.raster.chisel",
                    shape: .chisel,
                    aspect: 0.35,
                    rotation: 0
                )
            ),
            (
                "rotated-chisel",
                try cursorAnalyticDefinition(
                    id: "cursor.raster.rotated-chisel",
                    shape: .chisel,
                    aspect: 0.35,
                    rotation: .pi / 2
                )
            ),
            (
                "asset-tip",
                try cursorAssetDefinition()
            ),
        ]

        for testCase in cases {
            let capture = try await cursorRasterCapture(
                definition: testCase.definition,
                diameter: 40
            )
            let metrics = cursorAgreement(
                alpha: capture.alpha,
                width: 64,
                height: 64,
                center: SIMD2(32, 32),
                descriptor: capture.descriptor,
                descriptorScale: 1
            )
            #expect(
                metrics.iou >= 0.85,
                "\(testCase.name) cursor IoU was \(metrics.iou)"
            )
            #expect(
                metrics.maximumEdgeError <= 1.5,
                "\(testCase.name) edge error was \(metrics.maximumEdgeError)"
            )

            let shrunk = cursorAgreement(
                alpha: capture.alpha,
                width: 64,
                height: 64,
                center: SIMD2(32, 32),
                descriptor: capture.descriptor,
                descriptorScale: 0.8
            )
            #expect(
                shrunk.iou < 0.85 || shrunk.maximumEdgeError > 1.5,
                "\(testCase.name) negative control did not detect shrinkage"
            )
        }
    }
}

@MainActor
private func cursorView(
    controller: EditorSessionController,
    renderer: GridRenderer
) -> InteractiveMetalView {
    let view = InteractiveMetalView(
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        controller: controller,
        renderer: renderer,
        requestEditorFocus: {},
        pointerCancellationGeneration: 0
    )
    view.drawableSize = CGSize(width: 200, height: 200)
    return view
}

private func cursorPointerEvent(
    type: NSEvent.EventType,
    location: CGPoint
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}

private struct CursorRasterCapture {
    let alpha: [UInt8]
    let descriptor: BrushCursorDescriptor
}

private struct CursorAgreementMetrics {
    let iou: Float
    let maximumEdgeError: Float
}

@MainActor
private func cursorRasterCapture(
    definition: BrushDefinition,
    diameter: Float
) async throws -> CursorRasterCapture {
    let renderer = try #require(try makeControllerRenderer())
    let queue = try #require(renderer.device.makeCommandQueue())
    let compiler = BrushCompiler(
        device: renderer.device,
        commandQueue: queue,
        profile: try BrushDeviceProfile(
            registryID: renderer.device.registryID,
            recommendedWorkingSetBytes: max(
                renderer.device.recommendedMaxWorkingSetSize,
                64 * 1_024 * 1_024
            ),
            maximumWorkingTextureDimension: 4_096,
            brushCacheBudgetBytes: 64 * 1_024 * 1_024,
            targetFramesPerSecond: 120
        ),
        pipelineLibrary: DepositionPipelineLibrary(
            device: renderer.device,
            library: renderer.library
        )
    )
    let brush = try await compiler.compileAndActivate(definition: definition)
    try renderer.activateDrawBrush(brush)
    let descriptor = try brush.cursorDescriptor(input: BrushCursorInput(
        nominalDiameter: diameter,
        pressure: nil,
        altitude: nil,
        azimuth: nil,
        roll: nil,
        tangentialPressure: nil,
        direction: 0,
        deformation: .identity,
        viewportScale: 1,
        backingScale: 1
    ))
    let token = RendererOperationToken(rawValue: 0xC0_16)
    let style = StrokeRenderStyle(
        color: .black,
        diameter: diameter,
        compositeMode: .draw,
        eraserStrength: 1,
        program: brush.program,
        renderIdentity: brush.renderIdentity,
        seed: 1
    )
    try renderer.beginStroke(
        token: token,
        sample: .mouse(
            position: ScreenPoint(x: 32, y: 32),
            timestamp: 0,
            phase: .began
        ),
        style: style
    )
    try renderer.requestStrokeCommit(
        token: token,
        sample: .mouse(
            position: ScreenPoint(x: 32, y: 32),
            timestamp: 1,
            phase: .ended
        )
    )
    _ = try await renderer.finishCommitForHarness()
    let snapshot = try await renderer.captureCommittedDocument()
    let bytes: [UInt8]
    switch snapshot.storage {
    case let .singleRaster(value):
        bytes = value
    case let .radialPages(pages):
        bytes = pages.flatMap(\.bgra8PremultipliedBytes)
    }
    var alpha = [UInt8]()
    alpha.reserveCapacity(64 * 64)
    for offset in stride(from: 3, to: bytes.count, by: 4) {
        alpha.append(bytes[offset])
    }
    return CursorRasterCapture(alpha: alpha, descriptor: descriptor)
}

private func cursorAgreement(
    alpha: [UInt8],
    width: Int,
    height: Int,
    center: SIMD2<Float>,
    descriptor: BrushCursorDescriptor,
    descriptorScale: Float
) -> CursorAgreementMetrics {
    var raster = [Bool](repeating: false, count: width * height)
    var cursor = [Bool](repeating: false, count: width * height)
    var intersection = 0
    var union = 0
    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            raster[index] = alpha[index] >= 4
            let relative = SIMD2(
                Float(x) + 0.5 - center.x,
                Float(y) + 0.5 - center.y
            ) / descriptorScale
            cursor[index] = descriptor.containsCore(relative)
            if raster[index] && cursor[index] { intersection += 1 }
            if raster[index] || cursor[index] { union += 1 }
        }
    }
    return CursorAgreementMetrics(
        iou: union == 0 ? 0 : Float(intersection) / Float(union),
        maximumEdgeError: max(
            directedBoundaryDistance(
                from: boundaryPoints(raster, width: width, height: height),
                to: boundaryPoints(cursor, width: width, height: height)
            ),
            directedBoundaryDistance(
                from: boundaryPoints(cursor, width: width, height: height),
                to: boundaryPoints(raster, width: width, height: height)
            )
        )
    )
}

private func boundaryPoints(
    _ mask: [Bool],
    width: Int,
    height: Int
) -> [SIMD2<Float>] {
    var result: [SIMD2<Float>] = []
    for y in 0..<height {
        for x in 0..<width where mask[y * width + x] {
            let isBoundary = x == 0 || y == 0 || x == width - 1
                || y == height - 1
                || !mask[y * width + x - 1]
                || !mask[y * width + x + 1]
                || !mask[(y - 1) * width + x]
                || !mask[(y + 1) * width + x]
            if isBoundary {
                result.append(SIMD2(Float(x) + 0.5, Float(y) + 0.5))
            }
        }
    }
    return result
}

private func directedBoundaryDistance(
    from source: [SIMD2<Float>],
    to target: [SIMD2<Float>]
) -> Float {
    guard !source.isEmpty, !target.isEmpty else { return .infinity }
    var maximum: Float = 0
    for point in source {
        var nearest = Float.infinity
        for candidate in target {
            nearest = min(nearest, hypot(
                point.x - candidate.x,
                point.y - candidate.y
            ))
        }
        maximum = max(maximum, nearest)
    }
    return maximum
}

private func cursorAnalyticDefinition(
    id: String,
    shape: BrushShapeDescriptor,
    aspect: Float,
    rotation: Float
) throws -> BrushDefinition {
    let base = try GridRenderer.nativeHarnessDefinition(mode: .draw)
    return try BrushDefinition(
        id: BrushRecipeID(id),
        metadata: BrushMetadata(displayName: id),
        capabilities: [],
        resources: [],
        coverage: BrushCoverageDefinition(
            shapes: [BrushShapeLayerDefinition(
                shape: shape,
                combination: .replace,
                scale: 1,
                rotation: 0,
                offset: .zero
            )],
            grains: [],
            baseHardness: 1,
            aspectRatio: aspect,
            tipThreshold: 0.01,
            antialiasing: true
        ),
        placement: BrushPlacementDefinition(
            baseSpacingFraction: base.components[0].placement.baseSpacingFraction,
            maximumSpacingFraction: base.components[0].placement.maximumSpacingFraction,
            baseFlow: 1,
            strokeOpacity: 1,
            baseScatterFraction: 0,
            baseRotation: rotation,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        dynamics: base.components[0].dynamics,
        color: base.components[0].color,
        material: base.components[0].material,
        stabilization: 0,
        taper: .none,
        replayMode: .appendOnly,
        replayLimits: nil,
        termination: .cap,
        seedPolicy: .perStroke,
        limits: base.limits,
        performanceIntent: .realtime120,
        compatibility: base.compatibility,
        sensorNormalization: base.sensorNormalization,
        sensorProgram: base.components[0].sensorProgram,
        stabilizationV2: .none,
        direction: base.direction,
        emission: base.components[0].emission,
        tipSupports: [
            shape == .chisel ? .analyticRectangle : .analyticEllipse,
        ]
    )
}

private func cursorAssetDefinition() throws -> BrushDefinition {
    let base = try GridRenderer.nativeHarnessDefinition(mode: .draw)
    let identifier = "builtin.shape.technical-nib"
    return try BrushDefinition(
        id: BrushRecipeID("cursor.raster.asset-tip"),
        metadata: BrushMetadata(displayName: "cursor.raster.asset-tip"),
        capabilities: [],
        resources: [
            BrushResourceReference(
                identifier: identifier,
                kind: .shape,
                required: false,
                fallback: .builtIn(identifier: identifier)
            ),
        ],
        coverage: BrushCoverageDefinition(
            shapes: [BrushShapeLayerDefinition(
                shape: .asset(identifier),
                combination: .replace,
                scale: 1,
                rotation: 0,
                offset: .zero
            )],
            grains: [],
            baseHardness: 1,
            aspectRatio: 0.92,
            tipThreshold: 0.01,
            antialiasing: true
        ),
        placement: BrushPlacementDefinition(
            baseSpacingFraction: base.components[0].placement.baseSpacingFraction,
            maximumSpacingFraction: base.components[0].placement.maximumSpacingFraction,
            baseFlow: 1,
            strokeOpacity: 1,
            baseScatterFraction: 0,
            baseRotation: 0,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        dynamics: base.components[0].dynamics,
        color: base.components[0].color,
        material: base.components[0].material,
        stabilization: 0,
        taper: .none,
        replayMode: .appendOnly,
        replayLimits: nil,
        termination: .cap,
        seedPolicy: .perStroke,
        limits: base.limits,
        performanceIntent: .realtime120,
        compatibility: base.compatibility,
        sensorNormalization: base.sensorNormalization,
        sensorProgram: base.components[0].sensorProgram,
        stabilizationV2: .none,
        direction: base.direction,
        emission: base.components[0].emission,
        tipSupports: [.analyticEllipse]
    )
}

private func compositeCursorDefinition() throws -> BrushDefinition {
    let base = try GridRenderer.nativeHarnessDefinition(mode: .draw)
    func component(
        identifier: String,
        ordinal: UInt8,
        coverage: BrushCoverageDefinition,
        offset: SIMD2<Float>,
        tipSupports: [BrushTipSupportDefinition]
    ) -> BrushComponentDefinition {
        let inherited = base.components[0]
        return BrushComponentDefinition(
            identifier: BrushComponentIdentifier(identifier),
            ordinal: ordinal,
            resources: [],
            coverage: coverage,
            placement: BrushPlacementDefinition(
                baseSpacingFraction: inherited.placement.baseSpacingFraction,
                maximumSpacingFraction:
                    inherited.placement.maximumSpacingFraction,
                baseFlow: 1,
                strokeOpacity: 1,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: offset
            ),
            dynamics: inherited.dynamics,
            color: inherited.color,
            material: inherited.material,
            taper: inherited.taper,
            sensorProgram: inherited.sensorProgram,
            emission: inherited.emission,
            tipSupports: tipSupports
        )
    }
    let primaryCoverage = BrushCoverageDefinition(
        shapes: [BrushShapeLayerDefinition(
            shape: .hardRound,
            combination: .replace,
            scale: 1,
            rotation: 0,
            offset: .zero
        )],
        grains: [],
        baseHardness: 1,
        aspectRatio: 1,
        tipThreshold: 0.01,
        antialiasing: true
    )
    let secondaryCoverage = BrushCoverageDefinition(
        shapes: [
            BrushShapeLayerDefinition(
                shape: .chisel,
                combination: .replace,
                scale: 1,
                rotation: 0,
                offset: .zero
            ),
            BrushShapeLayerDefinition(
                shape: .hardRound,
                combination: .maximum,
                scale: 0.5,
                rotation: 0,
                offset: .zero
            ),
        ],
        grains: [],
        baseHardness: 1,
        aspectRatio: 0.5,
        tipThreshold: 0.01,
        antialiasing: true
    )
    return try BrushDefinition(
        id: BrushRecipeID("cursor.composite.integration"),
        metadata: BrushMetadata(displayName: "Composite Cursor"),
        capabilities: base.capabilities,
        composition: .orderedSourceOver,
        components: [
            component(
                identifier: "primary",
                ordinal: 0,
                coverage: primaryCoverage,
                offset: SIMD2(-24, 0),
                tipSupports: [.analyticEllipse]
            ),
            component(
                identifier: "secondary",
                ordinal: 1,
                coverage: secondaryCoverage,
                offset: SIMD2(24, 0),
                tipSupports: [.analyticRectangle, .analyticEllipse]
            ),
        ],
        stabilization: base.stabilization,
        replayMode: base.replayMode,
        replayLimits: base.replayLimits,
        termination: base.termination,
        seedPolicy: base.seedPolicy,
        limits: base.limits,
        performanceIntent: .realtime60,
        compatibility: base.compatibility,
        sensorNormalization: base.sensorNormalization,
        stabilizationV2: base.stabilizationV2,
        direction: base.direction
    )
}
#endif
