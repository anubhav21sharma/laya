import EditorCore
import Foundation
import Metal
import PatternEngine
import simd
import Testing
@testable import MetalRenderer

@Suite("Linear sparse layer compositor", .serialized)
struct LayerCompositorTests {
    @Test
    func failuresRetainActionableLocalizedDescriptions() {
        #expect(
            LayerCompositorError.invalidLimit.localizedDescription
                == "Layer compositor limits are invalid."
        )
        #expect(
            LayerCompositorError.invalidTarget.localizedDescription
                == "Layer compositor target is incompatible."
        )
        #expect(
            LayerCompositorError.scratchLimitExceeded(
                required: 100,
                maximum: 80
            ).localizedDescription
                == "Layer compositor scratch requires 100 bytes; maximum is 80 bytes."
        )
        #expect(
            LayerCompositorError.commandFailed("out of memory")
                .localizedDescription
                == "Layer compositor Metal command failed: out of memory"
        )
    }

    @Test
    func productionDisplayLimitsAllowRetinaViewportWithoutIncreasingByteBudget()
    {
        let limits = LayerCompositorLimits.production
        let width = 2_186
        let height = 1_821
        let requiredBytes = width * height * 3 * 8

        #expect(requiredBytes == 95_536_944)
        #expect(requiredBytes <= limits.maximumScratchBytes)
        #expect(width <= limits.maximumWidth)
        #expect(height <= limits.maximumHeight)
        #expect(limits.maximumScratchBytes == 96 * 1_024 * 1_024)
    }

    @Test @MainActor
    func periodicRootAndChildPreparationReuseImmutableReachabilitySeed()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layers = try (103..<111).map { try descriptor($0) }
        let stack = try LayerStack(
            layers: layers,
            activeLayerID: try #require(layers.last).id
        )
        let documentSize = PixelSize(width: 4_096, height: 4_096)
        let storageSize = PixelSize(width: 4_096, height: 4_096)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: layers.count * PaintTileDescriptor.residentByteCount,
            geometry: DocumentPaintGeometry(
                documentPixelSize: documentSize,
                storagePixelSize: storageSize,
                radialLayout: nil
            ),
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let dirty: [UUID: [PaintTileCoordinate]] = Dictionary(
            uniqueKeysWithValues: layers.map { ($0.id, [coordinate]) }
        )
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: dirty
        )
        let colors: [UUID: SIMD4<Float>] = Dictionary(
            uniqueKeysWithValues: layers.enumerated().map { index, layer in
                (layer.id, SIMD4<Float>(
                    Float(index + 1) / 16,
                    0.25,
                    0.125,
                    1
                ))
            }
        )
        try uploadLayerColors(
            colors,
            layers: layers,
            candidate: candidate,
            coordinate: coordinate,
            device: device
        )
        registry.commitPrepared(try registry.prepareCommit(candidate))
        let fold = try #require(TilingStrategy(
            configuration: PeriodicSymmetryConfiguration(
                presetID: .squareRotation,
                repeatSize: PatternSize(
                    width: Float(storageSize.width),
                    height: Float(storageSize.height)
                ),
                orientationRadians: .pi / 7
            ),
            canonicalRasterSize: storageSize
        ).compiledSymmetry.domain.periodic?.displayFold)
        let mapping = SparseTileSamplingOutputMapping.periodic(
            SparseTilePeriodicOutputMapping(
                fold: fold,
                outputToWorldTransform: .identity
            )
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0,
            maxX: 3_024, maxY: 1_964
        )
        let plan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .periodic(period: storageSize),
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1,
            outputMapping: mapping,
            limits: .documentProduction
        )
        #expect(plan.layers.count == layers.count)
        var rootPhaseA: [SparseTilePeriodicReachabilityReceipt] = []
        for layer in plan.layers {
            let selectionReceipt = try #require(layer.sourceSelection
                .testingPeriodicReachabilityReceipt)
            let buildReceipt = try #require(layer.samplingPlan
                .periodicReachabilityReceipt)
            rootPhaseA.append(selectionReceipt)
            #expect(buildReceipt.phaseAWorkCount
                == selectionReceipt.workCount)
            #expect(buildReceipt.acquisitionWorkCount
                < max(1, selectionReceipt.workCount / 10))
            #expect(buildReceipt.cacheHitCount
                > selectionReceipt.cacheHitCount)
        }
        let firstRootPhaseA = try #require(rootPhaseA.first)
        #expect(firstRootPhaseA.workCount > 1_000)
        #expect(firstRootPhaseA.workCount < 125_000)
        #expect(firstRootPhaseA.enumeratedPixelCenterCount < 50_000)
        #expect(firstRootPhaseA.cacheHitCount == 0)
        #expect(rootPhaseA.dropFirst().allSatisfy {
            $0.workCount == firstRootPhaseA.workCount
                && $0.cacheHitCount > 0
        })

        let child = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 1_512, maxY: 1_964
        )
        let childMapping = try DocumentPaintStableSnapshotChunkPlanner
            .childMapping(global: mapping, full: output, child: child)
        let childLayers = try plan.layers(
            for: child,
            outputMapping: childMapping
        )
        #expect(childLayers.count == layers.count)
        var childPhaseA: [SparseTilePeriodicReachabilityReceipt] = []
        for layer in childLayers {
            let selectionReceipt = try #require(layer.sourceSelection
                .testingPeriodicReachabilityReceipt)
            let buildReceipt = try #require(layer.samplingPlan
                .periodicReachabilityReceipt)
            childPhaseA.append(selectionReceipt)
            #expect(buildReceipt.phaseAWorkCount
                == selectionReceipt.workCount)
            #expect(buildReceipt.acquisitionWorkCount
                < max(1, selectionReceipt.workCount / 10))
            #expect(buildReceipt.cacheHitCount
                > selectionReceipt.cacheHitCount)
        }
        let firstChildPhaseA = try #require(childPhaseA.first)
        #expect(firstChildPhaseA.workCount > 1_000)
        #expect(firstChildPhaseA.workCount < 125_000)
        #expect(firstChildPhaseA.enumeratedPixelCenterCount < 50_000)
        #expect(firstChildPhaseA.cacheHitCount == 0)
        #expect(childPhaseA.dropFirst().allSatisfy {
            $0.workCount == firstChildPhaseA.workCount
                && $0.cacheHitCount > 0
        })
        plan.close()
        let store = registry.sharedTileStore.snapshot()
        #expect(store.activeSnapshotTokenCount == 0)
        #expect(store.aggregateSnapshotReferenceCount == 0)
    }

    @Test @MainActor
    func finiteExportCompositesTheCurrentNativeLayerStackOnce() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLayerCompositorLibrary(device: device)
        let queue = try #require(device.makeCommandQueue())
        let bottom = try descriptor(101)
        let top = try descriptor(
            102,
            opacity: 0.5,
            blendMode: .normal
        )
        let stack = try LayerStack(
            layers: [bottom, top],
            activeLayerID: top.id
        )
        let size = PixelSize(width: 64, height: 64)
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: size,
            storagePixelSize: size,
            radialLayout: nil
        )
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: library,
            geometry: geometry,
            initialLayerStack: stack,
            byteBudget: PaintTileDescriptor.residentByteCount * 4,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 4,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 4
        )
        let bottomTileID = UUID(
            uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )!
        let topTileID = UUID(
            uuidString: "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb"
        )!
        let bounds = try #require(PixelRect(
            minX: 0,
            minY: 0,
            maxX: size.width,
            maxY: size.height
        ))
        let manifest = try DocumentPaintNativeArchiveImportManifest(
            geometry: geometry,
            layerStack: stack,
            layers: [
                .init(
                    layerID: bottom.id,
                    rasterRevision: 1,
                    tiles: [.init(
                        persistedID: bottomTileID,
                        coordinate: .init(x: 0, y: 0),
                        logicalBounds: bounds
                    )]
                ),
                .init(
                    layerID: top.id,
                    rasterRevision: 1,
                    tiles: [.init(
                        persistedID: topTileID,
                        coordinate: .init(x: 0, y: 0),
                        logicalBounds: bounds
                    )]
                ),
            ]
        )
        let bottomPayload = solidNativeTilePayload(
            SIMD4<Float>(1, 0, 0, 1)
        )
        let topPayload = solidNativeTilePayload(
            SIMD4<Float>(0, 0, 0.5, 0.5)
        )
        try await context.importNativeArchive(manifest) { writer in
            try writer.install(bottomPayload, for: bottomTileID)
            try writer.install(topPayload, for: topTileID)
        }
        let strategy = try TilingStrategy(
            documentConfiguration: .finite(.plain),
            canvasSize: size
        )

        let exported = try await context.exportFiniteCanvas(
            strategy: strategy,
            outputGeometryRevision: 1,
            transparentBackground: true
        )
        let expected = DocumentColorPipeline.exportEncodedPremultipliedBGRA8(
            try #require(LinearPremultipliedColor(
                red: 0.75,
                green: 0,
                blue: 0.25,
                alpha: 1
            ))
        )
        #expect(Array(exported.bgra8Bytes.prefix(4)) == [
            expected.blue,
            expected.green,
            expected.red,
            expected.alpha,
        ])
        let flattened = try await context.exportFlattenedScene(
            strategy: strategy,
            request: DocumentPaintStableFlattenedOutputRequest(
                pixelSize: size,
                outputMapping: .affine(.identity),
                transparentBackground: true
            ),
            outputGeometryRevision: 2
        )
        #expect(flattened.bgra8Bytes == exported.bgra8Bytes)

        let outputRegion = try SparseTileOutputRegion(
            minX: 0,
            minY: 0,
            maxX: size.width,
            maxY: size.height
        )
        let display = try await context.prepareLayerDisplaySubmission(
            transient: nil,
            addressing: .finite(size),
            addressingRevision: 3,
            outputRegion: outputRegion,
            outputGeometryRevision: 3,
            outputMapping: .affine(.identity),
            parameters: .identity
        )
        let displayDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: DocumentColorPipeline.displayPixelFormat,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        displayDescriptor.storageMode = .shared
        displayDescriptor.usage = [.renderTarget]
        let displayTexture = try #require(
            device.makeTexture(descriptor: displayDescriptor)
        )
        let displayCommand = try #require(queue.makeCommandBuffer())
        let displayPass = MTLRenderPassDescriptor()
        displayPass.colorAttachments[0].texture = displayTexture
        displayPass.colorAttachments[0].loadAction = .clear
        displayPass.colorAttachments[0].storeAction = .store
        displayPass.colorAttachments[0].clearColor =
            GridCanvasContract.paperClearColor
        try context.encodeLayerDisplaySubmission(
            display,
            target: displayTexture,
            commandBuffer: displayCommand,
            renderPassDescriptor: displayPass
        )
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            displayCommand.addCompletedHandler { _ in
                continuation.resume()
            }
            displayCommand.commit()
        }
        #expect(displayCommand.status == .completed)
        try await context.retryLayerDisplayCompletions()
        var displayPixel = [UInt8](repeating: 0, count: 4)
        displayTexture.getBytes(
            &displayPixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )
        #expect(displayPixel == [
            expected.blue,
            expected.green,
            expected.red,
            expected.alpha,
        ])
    }

    @Test
    func normalMultiplyScreenAndOpacityUseLinearPremultipliedSourceOver()
        throws
    {
        let bottom = try descriptor(
            1,
            opacity: 1,
            blendMode: .normal
        )
        let backdrop = SIMD4<Float>(0.1, 0.2, 0.3, 0.5)
        let source = SIMD4<Float>(0.4, 0.1, 0.2, 0.5)
        let cases: [(LayerBlendMode, Float, SIMD4<Float>)] = [
            (.normal, 0, backdrop),
            (.normal, 0.5, SIMD4(0.275, 0.2, 0.325, 0.625)),
            (.normal, 1, SIMD4(0.45, 0.2, 0.35, 0.75)),
            (.multiply, 0, backdrop),
            (.multiply, 0.5, SIMD4(0.195, 0.185, 0.305, 0.625)),
            (.multiply, 1, SIMD4(0.29, 0.17, 0.31, 0.75)),
            (.screen, 0, backdrop),
            (.screen, 0.5, SIMD4(0.28, 0.24, 0.37, 0.625)),
            (.screen, 1, SIMD4(0.46, 0.28, 0.44, 0.75)),
        ]

        for (mode, opacity, expected) in cases {
            let top = try descriptor(
                2,
                opacity: opacity,
                blendMode: mode
            )
            let stack = try LayerStack(
                layers: [bottom, top],
                activeLayerID: top.id
            )
            let actual = LayerCPUCompositingReference.composite(
                stack: stack
            ) { layer in
                layer.id == bottom.id ? backdrop : source
            }
            expectColor(actual, equals: expected)
        }
    }

    @Test
    func orderVisibilityEmptyAndEightLayerBoundsStayDeterministic() throws {
        let red = try descriptor(1)
        let hiddenGreen = try descriptor(2, isVisible: false)
        let empty = try descriptor(3)
        let zeroOpacity = try descriptor(4, opacity: 0)
        let blue = try descriptor(5, opacity: 0.5)
        let colors: [UUID: SIMD4<Float>] = [
            red.id: SIMD4(1, 0, 0, 1),
            hiddenGreen.id: SIMD4(0, 1, 0, 1),
            zeroOpacity.id: SIMD4(1, 1, 1, 1),
            blue.id: SIMD4(0, 0, 0.5, 0.5),
        ]
        let bottomToTop = try LayerStack(
            layers: [red, hiddenGreen, empty, zeroOpacity, blue],
            activeLayerID: red.id
        )
        let reordered = try LayerStack(
            layers: [blue, hiddenGreen, empty, zeroOpacity, red],
            activeLayerID: red.id
        )

        expectColor(
            LayerCPUCompositingReference.composite(stack: bottomToTop) {
                colors[$0.id] ?? .zero
            },
            equals: SIMD4(0.75, 0, 0.25, 1)
        )
        expectColor(
            LayerCPUCompositingReference.composite(stack: reordered) {
                colors[$0.id] ?? .zero
            },
            equals: SIMD4(1, 0, 0, 1)
        )

        let eight = try (10...17).map {
            try descriptor($0, opacity: 1)
        }
        let eightLayerStack = try LayerStack(
            layers: eight,
            activeLayerID: eight[0].id
        )
        let eighthAlphaBlack = SIMD4<Float>(0, 0, 0, 0.125)
        expectColor(
            LayerCPUCompositingReference.composite(stack: eightLayerStack) {
                _ in eighthAlphaBlack
            },
            equals: SIMD4(0, 0, 0, 0.6563911),
            tolerance: 2e-6
        )
    }

    @Test
    func preparedSparsePlanSamplesMissingLayerInputAsTransparent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = try descriptor(21)
        let second = try descriptor(22, blendMode: .screen)
        let stack = try LayerStack(
            layers: [first, second],
            activeLayerID: second.id
        )
        let size = PixelSize(width: 512, height: 256)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount * 4,
            geometry: DocumentPaintGeometry(
                documentPixelSize: size,
                storagePixelSize: size,
                radialLayout: nil
            ),
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [
                first.id: [.init(x: 0, y: 0)],
                second.id: [.init(x: 1, y: 0)],
            ]
        )
        registry.commitPrepared(try registry.prepareCommit(candidate))
        let plan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .finite(size),
            addressingRevision: 1,
            outputRegion: SparseTileOutputRegion(
                minX: 0, minY: 0, maxX: 1, maxY: 1
            ),
            outputGeometryRevision: 1,
            limits: .documentProduction
        )
        defer { plan.close() }

        #expect(plan.layers.map(\.layerID) == [first.id])
        let provider = SolidLayerTexelProvider(colors: [
            first.id: SIMD4(0.2, 0.1, 0.05, 0.25),
            second.id: SIMD4(0.4, 0.4, 0.4, 0.5),
        ])
        let actual = try LayerCPUCompositingReference.sample(
            at: SIMD2<Double>(0.5, 0.5),
            plan: plan,
            provider: provider
        )
        expectColor(
            actual,
            equals: SIMD4(0.2, 0.1, 0.05, 0.25)
        )
    }

    @Test @MainActor
    func gpuComposesEightSparseLayersThroughEverySupportedBackend()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLayerCompositorLibrary(device: device)
        let layers = try (31...38).enumerated().map { index, value in
            try descriptor(
                value,
                opacity: index.isMultiple(of: 3) ? 0.5 : 1,
                blendMode: LayerBlendMode.allCases[
                    index % LayerBlendMode.allCases.count
                ]
            )
        }
        let fullStack = try LayerStack(
            layers: layers,
            activeLayerID: layers.last!.id
        )
        let colors: [UUID: SIMD4<Float>] = Dictionary(
            uniqueKeysWithValues: layers.enumerated().map { index, layer in
                let alpha = Float(index + 1) / 10
                return (
                    layer.id,
                    SIMD4(
                        alpha * Float(index % 3 + 1) / 4,
                        alpha * Float((index + 1) % 3 + 1) / 5,
                        alpha * Float((index + 2) % 3 + 1) / 6,
                        alpha
                    )
                )
            }
        )
        let storageSize = PixelSize(width: 256, height: 256)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount * layers.count,
            geometry: DocumentPaintGeometry(
                documentPixelSize: storageSize,
                storagePixelSize: storageSize,
                radialLayout: nil
            ),
            layerIDs: fullStack.orderedLayerIDs,
            layerStack: fullStack
        )
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: Dictionary(
                uniqueKeysWithValues: layers.map { ($0.id, [coordinate]) }
            )
        )
        try uploadLayerColors(
            colors,
            layers: layers,
            candidate: candidate,
            coordinate: coordinate,
            device: device
        )
        registry.commitPrepared(try registry.prepareCommit(candidate))
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 2, maxY: 2
        )
        var backends = [SparseTileSamplingBackendRequest.forceFallback]
        if device.argumentBuffersSupport == .tier2 {
            backends.append(.forceTier2)
        }

        for backend in backends {
            let compositor = try LayerCompositor.make(
                device: device,
                library: library,
                backendRequest: backend
            )
            for contributingLayerCount in 1...layers.count {
                let visibleLayers = try layers.enumerated().map { index, layer in
                    try LayerDescriptor(
                        id: layer.id,
                        name: layer.name,
                        isVisible: index < contributingLayerCount,
                        opacity: layer.opacity,
                        blendMode: layer.blendMode
                    )
                }
                let stack = try LayerStack(
                    layers: visibleLayers,
                    activeLayerID: visibleLayers[0].id
                )
                if stack != registry.layerStack {
                    let candidate = try registry.makeCandidate(
                        layerStack: stack
                    )
                    registry.commitPrepared(
                        try registry.prepareCommit(candidate)
                    )
                }
                let plan = try registry.prepareLayerCompositePlan(
                    layerStack: stack,
                    addressing: .finite(storageSize),
                    addressingRevision: 1,
                    outputRegion: output,
                    outputGeometryRevision: 1,
                    limits: .documentProduction
                )
                let target = LayerCompositeTarget(
                    texture: try makeLayerCompositeTarget(
                        device: device,
                        width: output.width,
                        height: output.height
                    )
                )
                try await compositor.composite(plan, into: target)

                let expected = LayerCPUCompositingReference.composite(
                    stack: stack
                ) { colors[$0.id]! }
                #expect(plan.isClosed)
                for actual in readLayerCompositePixels(target.texture) {
                    expectColor(actual, equals: expected, tolerance: 2e-3)
                }
                let compositorState = await compositor.snapshot()
                #expect(!compositorState.isBusy)
                #expect(compositorState.scratchBytes == output.width * output.height * 24)
                #expect(compositorState.cpuPlanCache.cachedContentCount == 0)
                #expect(compositorState.cpuPlanCache.pendingRetirementCount == 0)
                #expect(compositorState.gpuPlanCache.preparedContentCount == 0)
                #expect(
                    compositorState.gpuPlanCache.uploadRing?.activeSlotCount
                        == 0
                )
                #expect(
                    compositorState.completion.pendingPlanCompletionCount == 0
                )
                #expect(
                    compositorState.completion.pendingConsumerCompletionCount
                        == 0
                )
            }
        }

        let store = registry.sharedTileStore.snapshot()
        #expect(store.activeLeaseCount == 0)
        #expect(store.activeSnapshotTokenCount == 0)
        #expect(store.aggregateSnapshotReferenceCount == 0)
    }

    @Test @MainActor
    func gpuTreatsAnEntirelyEmptyStackAsTransparentAndClosesItsRoot()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = try descriptor(41)
        let stack = try LayerStack(layers: [layer], activeLayerID: layer.id)
        let size = PixelSize(width: 256, height: 256)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount,
            geometry: DocumentPaintGeometry(
                documentPixelSize: size,
                storagePixelSize: size,
                radialLayout: nil
            ),
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
        let region = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 2, maxY: 2
        )
        let plan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .finite(size),
            addressingRevision: 0,
            outputRegion: region,
            outputGeometryRevision: 0,
            limits: .documentProduction
        )
        #expect(plan.layers.isEmpty)
        let texture = try makeLayerCompositeTarget(
            device: device,
            width: region.width,
            height: region.height
        )
        writeLayerCompositePixels(
            Array(repeating: SIMD4(0.5, 0.25, 0.125, 0.75), count: 4),
            to: texture
        )
        let compositor = try LayerCompositor.make(
            device: device,
            library: makeLayerCompositorLibrary(device: device),
            backendRequest: .forceFallback
        )

        try await compositor.composite(
            plan,
            into: LayerCompositeTarget(texture: texture)
        )

        #expect(plan.isClosed)
        #expect(readLayerCompositePixels(texture).allSatisfy { $0 == .zero })
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
    }

    @Test @MainActor
    func newCompositeCancelsAnUnencodedDisplayReservationAndReusesScratch()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = try descriptor(42)
        let stack = try LayerStack(layers: [layer], activeLayerID: layer.id)
        let size = PixelSize(width: 256, height: 256)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount,
            geometry: DocumentPaintGeometry(
                documentPixelSize: size,
                storagePixelSize: size,
                radialLayout: nil
            ),
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 2, maxY: 2
        )
        let compositor = try LayerCompositor.make(
            device: device,
            library: makeLayerCompositorLibrary(device: device),
            backendRequest: .forceFallback
        )
        let displayPlan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .finite(size),
            addressingRevision: 0,
            outputRegion: output,
            outputGeometryRevision: 0,
            limits: .documentProduction
        )
        let display = try await compositor.prepareDisplay(
            displayPlan,
            parameters: .identity
        )
        #expect((await compositor.snapshot()).isBusy)

        let nextPlan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .finite(size),
            addressingRevision: 1,
            outputRegion: output,
            outputGeometryRevision: 1,
            limits: .documentProduction
        )
        let target = try makeLayerCompositeTarget(
            device: device,
            width: output.width,
            height: output.height
        )
        try await compositor.composite(
            nextPlan,
            into: LayerCompositeTarget(texture: target)
        )

        #expect(display.isTerminal)
        #expect(displayPlan.isClosed)
        #expect(nextPlan.isClosed)
        #expect(!(await compositor.snapshot()).isBusy)
        let store = registry.sharedTileStore.snapshot()
        #expect(store.activeLeaseCount == 0)
        #expect(store.activeSnapshotTokenCount == 0)
        #expect(store.aggregateSnapshotReferenceCount == 0)
    }

    @Test @MainActor
    func displayCompletionPollDoesNotTreatConcurrentPreparationAsCleanupDebt()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = try descriptor(421)
        let stack = try LayerStack(layers: [layer], activeLayerID: layer.id)
        let size = PixelSize(width: 256, height: 256)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount,
            geometry: DocumentPaintGeometry(
                documentPixelSize: size,
                storagePixelSize: size,
                radialLayout: nil
            ),
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 2, maxY: 2
        )
        let compositor = try LayerCompositor.make(
            device: device,
            library: makeLayerCompositorLibrary(device: device),
            backendRequest: .forceFallback
        )
        let plan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .finite(size),
            addressingRevision: 0,
            outputRegion: output,
            outputGeometryRevision: 0,
            limits: .documentProduction
        )

        let preparation = Task {
            try await compositor.prepareDisplay(plan, parameters: .identity)
        }
        while !(await compositor.snapshot()).isBusy {
            await Task.yield()
        }

        try await compositor.retryDisplayCompletion()
        let submission = try await preparation.value

        #expect(!submission.isTerminal)
        #expect(plan.isClosed)
        #expect((await compositor.snapshot()).isBusy)

        try submission.cancel()
        try await compositor.retryDisplayCompletion()
        #expect(submission.isTerminal)
        #expect(!(await compositor.snapshot()).isBusy)
    }

    @Test @MainActor
    func shutdownAwaitsASubmittedDisplayBeforeDiscardingScratch() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let sharedEvent = device.makeSharedEvent()
        else { return }
        let layer = try descriptor(43)
        let stack = try LayerStack(layers: [layer], activeLayerID: layer.id)
        let size = PixelSize(width: 256, height: 256)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount,
            geometry: DocumentPaintGeometry(
                documentPixelSize: size,
                storagePixelSize: size,
                radialLayout: nil
            ),
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
        let output = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 2, maxY: 2
        )
        let compositor = try LayerCompositor.make(
            device: device,
            library: makeLayerCompositorLibrary(device: device),
            backendRequest: .forceFallback
        )
        let plan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .finite(size),
            addressingRevision: 0,
            outputRegion: output,
            outputGeometryRevision: 0,
            limits: .documentProduction
        )
        let submission = try await compositor.prepareDisplay(
            plan,
            parameters: .identity
        )
        let displayDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: DocumentColorPipeline.displayPixelFormat,
            width: output.width,
            height: output.height,
            mipmapped: false
        )
        displayDescriptor.storageMode = .shared
        displayDescriptor.usage = .renderTarget
        let target = try #require(device.makeTexture(descriptor: displayDescriptor))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        command.encodeWaitForEvent(sharedEvent, value: 1)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = GridCanvasContract.paperClearColor
        try submission.encode(
            target: target,
            commandBuffer: command,
            renderPassDescriptor: pass
        )
        command.commit()

        let shutdown = Task { try await compositor.shutdown() }
        try await Task.sleep(for: .milliseconds(10))
        sharedEvent.signaledValue = 1
        try await shutdown.value

        #expect(command.status == .completed)
        #expect(submission.isTerminal)
        #expect(!(await compositor.snapshot()).isBusy)
        #expect((await compositor.snapshot()).scratchBytes == 0)
        let store = registry.sharedTileStore.snapshot()
        #expect(store.activeLeaseCount == 0)
        #expect(store.activeSnapshotTokenCount == 0)
        #expect(store.aggregateSnapshotReferenceCount == 0)
    }

    @Test @MainActor
    func eightLayer2048DisplayAndExportStayBoundedForFullAndSparseSources()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLayerCompositorLibrary(device: device)

        try await runEightLayer2048Trace(
            device: device,
            library: library,
            fullyPopulated: true
        )
        try await runEightLayer2048Trace(
            device: device,
            library: library,
            fullyPopulated: false
        )
    }

    @Test @MainActor
    func exportConsumerFailureClosesTheRootAndAllowsImmediateGPUReuse()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = try descriptor(59)
        let stack = try LayerStack(layers: [layer], activeLayerID: layer.id)
        let documentSize = PixelSize(width: 1_088, height: 64)
        let storageSize = PixelSize(
            width: PaintTileDescriptor.side,
            height: PaintTileDescriptor.side
        )
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount,
            geometry: DocumentPaintGeometry(
                documentPixelSize: documentSize,
                storagePixelSize: storageSize,
                radialLayout: nil
            ),
            layerIDs: stack.orderedLayerIDs,
            layerStack: stack
        )
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let candidate = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layer.id: [coordinate]]
        )
        try uploadLayerColors(
            [layer.id: SIMD4<Float>(0.25, 0.1, 0.05, 0.5)],
            layers: [layer],
            candidate: candidate,
            coordinate: coordinate,
            device: device
        )
        registry.commitPrepared(try registry.prepareCommit(candidate))
        let compositor = try LayerCompositor.make(
            device: device,
            library: makeLayerCompositorLibrary(device: device),
            backendRequest: .forceFallback
        )
        let fullOutput = try SparseTileOutputRegion(
            minX: 0, minY: 0,
            maxX: documentSize.width, maxY: documentSize.height
        )
        let failedPlan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .periodic(period: storageSize),
            addressingRevision: 1,
            outputRegion: fullOutput,
            outputGeometryRevision: 1,
            limits: .documentProduction
        )
        let sink = LayerCompositorRejectingSink()
        await #expect(throws: LayerCompositorTestError.rejected) {
            try await compositor.collect(
                failedPlan,
                to: sink
            )
        }
        #expect(failedPlan.isClosed)
        #expect(await sink.didAbort)

        let reuseOutput = try SparseTileOutputRegion(
            minX: 0, minY: 0, maxX: 4, maxY: 4
        )
        let reusePlan = try registry.prepareLayerCompositePlan(
            layerStack: stack,
            addressing: .periodic(period: storageSize),
            addressingRevision: 2,
            outputRegion: reuseOutput,
            outputGeometryRevision: 2,
            limits: .documentProduction
        )
        try await compositor.composite(
            reusePlan,
            into: LayerCompositeTarget(texture: try makeLayerCompositeTarget(
                device: device,
                width: reuseOutput.width,
                height: reuseOutput.height
            ))
        )
        #expect(reusePlan.isClosed)
        let state = await compositor.snapshot()
        #expect(!state.isBusy)
        #expect(state.cpuPlanCache.cachedContentCount == 0)
        #expect(state.gpuPlanCache.preparedContentCount == 0)
        #expect(state.gpuPlanCache.uploadRing?.activeSlotCount == 0)
        let store = registry.sharedTileStore.snapshot()
        #expect(store.activeLeaseCount == 0)
        #expect(store.activeSnapshotTokenCount == 0)
        #expect(store.aggregateSnapshotReferenceCount == 0)
    }
}

private enum LayerCompositorTestError: Error, Equatable {
    case rejected
}

private actor LayerCompositorRejectingSink: DocumentPaintStableSnapshotSink {
    private(set) var didAbort = false

    func begin(_: DocumentPaintStableSnapshotSinkDescriptor) throws {}

    func consume(_: DocumentPaintStableSnapshotChunk) throws {
        throw LayerCompositorTestError.rejected
    }

    func finish() throws {}

    func abort() { didAbort = true }
}

@MainActor
private func runEightLayer2048Trace(
    device: any MTLDevice,
    library: any MTLLibrary,
    fullyPopulated: Bool
) async throws {
    let layers = try (51...58).enumerated().map { index, value in
        try descriptor(
            value,
            opacity: index.isMultiple(of: 2) ? 0.75 : 1,
            blendMode: LayerBlendMode.allCases[
                index % LayerBlendMode.allCases.count
            ]
        )
    }
    let stack = try LayerStack(
        layers: layers,
        activeLayerID: layers.last!.id
    )
    let alpha: Float = 0.25
    let colors = Dictionary(uniqueKeysWithValues: layers.enumerated().map {
        index, layer in
        (
            layer.id,
            SIMD4<Float>(
                alpha * Float(index % 3 + 1) / 4,
                alpha * Float((index + 1) % 3 + 1) / 4,
                alpha * Float((index + 2) % 3 + 1) / 4,
                alpha
            )
        )
    })
    let documentSize = PixelSize(width: 2_048, height: 2_048)
    let storageSize = fullyPopulated
        ? PixelSize(width: PaintTileDescriptor.side, height: PaintTileDescriptor.side)
        : documentSize
    let geometry = try DocumentPaintGeometry(
        documentPixelSize: documentSize,
        storagePixelSize: storageSize,
        radialLayout: nil
    )
    let registry = try DocumentPaintSurfaceStore(
        device: device,
        byteBudget: PaintTileDescriptor.residentByteCount * layers.count,
        geometry: geometry,
        layerIDs: stack.orderedLayerIDs,
        layerStack: stack
    )
    let coordinate = PaintTileCoordinate(x: 0, y: 0)
    let candidate = try registry.makeCandidate(
        dirtyCoordinatesByLayer: Dictionary(
            uniqueKeysWithValues: layers.map { ($0.id, [coordinate]) }
        )
    )
    try uploadLayerColors(
        colors,
        layers: layers,
        candidate: candidate,
        coordinate: coordinate,
        device: device
    )
    registry.commitPrepared(try registry.prepareCommit(candidate))
    let baselineStore = registry.sharedTileStore.snapshot()
    #expect(
        baselineStore.residentByteCount
            == PaintTileDescriptor.residentByteCount * layers.count
    )
    let output = try SparseTileOutputRegion(
        minX: 0, minY: 0,
        maxX: documentSize.width, maxY: documentSize.height
    )
    let addressing: SparseTileAddressing = fullyPopulated
        ? .periodic(period: storageSize)
        : .finite(documentSize)
    let compositor = try LayerCompositor.make(
        device: device,
        library: library,
        backendRequest: .forceFallback
    )

    let displayPlan = try registry.prepareLayerCompositePlan(
        layerStack: stack,
        addressing: addressing,
        addressingRevision: 1,
        outputRegion: output,
        outputGeometryRevision: 1,
        limits: .documentProduction
    )
    let submission = try await compositor.prepareDisplay(
        displayPlan,
        parameters: .identity
    )
    let displayDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: DocumentColorPipeline.displayPixelFormat,
        width: output.width,
        height: output.height,
        mipmapped: false
    )
    displayDescriptor.storageMode = .shared
    displayDescriptor.usage = .renderTarget
    let displayTarget = try #require(device.makeTexture(
        descriptor: displayDescriptor
    ))
    let queue = try #require(device.makeCommandQueue())
    let displayCommand = try #require(queue.makeCommandBuffer())
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = displayTarget
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = GridCanvasContract.paperClearColor
    try submission.encode(
        target: displayTarget,
        commandBuffer: displayCommand,
        renderPassDescriptor: pass
    )
    await withCheckedContinuation {
        (continuation: CheckedContinuation<Void, Never>) in
        displayCommand.addCompletedHandler { _ in continuation.resume() }
        displayCommand.commit()
    }
    #expect(displayCommand.status == .completed)
    try await compositor.retryDisplayCompletion()
    let displayState = await compositor.snapshot()
    #expect(!displayState.isBusy)
    #expect(displayState.scratchBytes == 96 * 1_024 * 1_024)
    #expect(displayState.cpuPlanCache.cachedContentCount == 0)
    #expect(displayState.gpuPlanCache.preparedContentCount == 0)
    #expect(displayState.gpuPlanCache.uploadRing?.activeSlotCount == 0)
    #expect(displayState.completion.pendingPlanCompletionCount == 0)
    #expect(displayState.completion.pendingConsumerCompletionCount == 0)

    let source = LayerCPUCompositingReference.composite(stack: stack) {
        colors[$0.id]!
    }
    let sourceColor = try #require(LinearPremultipliedColor(
        red: source.x,
        green: source.y,
        blue: source.z,
        alpha: source.w
    ))
    let expectedDisplay = encodedBGRABytes(
        DocumentColorPipeline.referenceSourceOver(
            source: sourceColor,
            destination: GridCanvasContract.paperLinearPremultiplied
        )
    )
    expectBGRA(
        readBGRA(displayTarget, x: 0, y: 0),
        equals: expectedDisplay
    )
    expectBGRA(
        readBGRA(displayTarget, x: 1_800, y: 1_800),
        equals: fullyPopulated
            ? expectedDisplay : [
                GridCanvasContract.paperBGRA.x,
                GridCanvasContract.paperBGRA.y,
                GridCanvasContract.paperBGRA.z,
                GridCanvasContract.paperBGRA.w,
            ]
    )

    let exportPlan = try registry.prepareLayerCompositePlan(
        layerStack: stack,
        addressing: addressing,
        addressingRevision: 2,
        outputRegion: output,
        outputGeometryRevision: 2,
        limits: .documentProduction
    )
    let exportDescriptor = try DocumentPaintTightBGRA8Descriptor(
        outputRegion: output,
        maximumByteCount: 32 * 1_024 * 1_024
    )
    let collector = try DocumentPaintTightBGRA8Collector(
        descriptor: exportDescriptor
    )
    try await compositor.collect(
        exportPlan,
        to: collector
    )
    let export = try await collector.result()
    let expectedExport = encodedBGRABytes(sourceColor)
    expectBGRA(
        readBGRA(export.bgra8PremultipliedBytes, x: 0, y: 0, width: 2_048),
        equals: expectedExport
    )
    expectBGRA(
        readBGRA(
            export.bgra8PremultipliedBytes,
            x: 1_800,
            y: 1_800,
            width: 2_048
        ),
        equals: fullyPopulated ? expectedExport : [0, 0, 0, 0]
    )
    let exportState = await compositor.snapshot()
    #expect(!exportState.isBusy)
    #expect(exportState.scratchBytes == 40 * 1_024 * 1_024)
    #expect(exportState.cpuPlanCache.cachedContentCount == 0)
    #expect(exportState.gpuPlanCache.preparedContentCount == 0)
    #expect(exportState.gpuPlanCache.uploadRing?.activeSlotCount == 0)
    #expect(exportState.completion.pendingPlanCompletionCount == 0)
    #expect(exportState.completion.pendingConsumerCompletionCount == 0)
    #expect(displayPlan.isClosed)
    #expect(exportPlan.isClosed)
    let terminalStore = registry.sharedTileStore.snapshot()
    #expect(
        terminalStore.residentByteCount == baselineStore.residentByteCount
    )
    #expect(terminalStore.activeLeaseCount == 0)
    #expect(terminalStore.activeSnapshotTokenCount == 0)
    #expect(terminalStore.aggregateSnapshotReferenceCount == 0)
}

private func encodedBGRABytes(
    _ color: LinearPremultipliedColor
) -> [UInt8] {
    let encoded = DocumentColorPipeline.exportEncodedPremultipliedBGRA8(color)
    return [encoded.blue, encoded.green, encoded.red, encoded.alpha]
}

private func readBGRA(
    _ texture: any MTLTexture,
    x: Int,
    y: Int
) -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    texture.getBytes(
        &pixel,
        bytesPerRow: 4,
        from: MTLRegionMake2D(x, y, 1, 1),
        mipmapLevel: 0
    )
    return pixel
}

private func readBGRA(
    _ bytes: Data,
    x: Int,
    y: Int,
    width: Int
) -> [UInt8] {
    let offset = (y * width + x) * 4
    return Array(bytes[offset..<(offset + 4)])
}

private func expectBGRA(
    _ actual: [UInt8],
    equals expected: [UInt8],
    tolerance: Int = 1
) {
    #expect(actual.count == 4)
    #expect(expected.count == 4)
    for channel in 0..<4 {
        #expect(abs(Int(actual[channel]) - Int(expected[channel])) <= tolerance)
    }
}

private func solidNativeTilePayload(_ color: SIMD4<Float>) -> Data {
    let texel = [color.x, color.y, color.z, color.w].map {
        Float16($0).bitPattern
    }
    var words = [UInt16]()
    words.reserveCapacity(PaintTileDescriptor.residentByteCount / 2)
    for _ in 0..<(PaintTileDescriptor.side * PaintTileDescriptor.side) {
        words.append(contentsOf: texel)
    }
    return words.withUnsafeBytes { Data($0) }
}

private struct SolidLayerTexelProvider: SparseTileCPUTexelProvider {
    let colors: [UUID: SIMD4<Float>]

    func texel(
        reference: PaintTileReference,
        localX _: Int,
        localY _: Int
    ) throws -> SIMD4<Float> {
        colors[reference.layerID] ?? .zero
    }
}

private func descriptor(
    _ value: Int,
    isVisible: Bool = true,
    opacity: Float = 1,
    blendMode: LayerBlendMode = .normal
) throws -> LayerDescriptor {
    try LayerDescriptor(
        id: UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012d",
            value
        ))!,
        name: "Layer \(value)",
        isVisible: isVisible,
        opacity: opacity,
        blendMode: blendMode
    )
}

private func expectColor(
    _ actual: SIMD4<Float>,
    equals expected: SIMD4<Float>,
    tolerance: Float = 1e-6
) {
    for channel in 0..<4 {
        #expect(abs(actual[channel] - expected[channel]) <= tolerance)
    }
}

private func uploadLayerColors(
    _ colors: [UUID: SIMD4<Float>],
    layers: [LayerDescriptor],
    candidate: DocumentPaintSurfaceCandidate,
    coordinate: PaintTileCoordinate,
    device: any MTLDevice
) throws {
    let queue = try #require(device.makeCommandQueue())
    for layer in layers {
        let surface = try candidate.binding(for: layer.id).canonical
        let lease = try surface.leaseExistingTiles(
            at: [coordinate],
            pinReasons: [.inFlight]
        )
        do {
            let binding = try #require(lease.bindings.first)
            let source = try makeSolidLayerTexture(
                device: device,
                color: colors[layer.id]!
            )
            let command = try #require(queue.makeCommandBuffer())
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(
                from: source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0),
                sourceSize: .init(
                    width: PaintTileDescriptor.side,
                    height: PaintTileDescriptor.side,
                    depth: 1
                ),
                to: binding.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: .init(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            try surface.returnLease(lease)
        } catch {
            try? surface.returnLease(lease)
            throw error
        }
    }
}

private func makeSolidLayerTexture(
    device: any MTLDevice,
    color: SIMD4<Float>
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: PaintTileDescriptor.side,
        height: PaintTileDescriptor.side,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    let encoded = SIMD4<Float16>(
        Float16(color.x), Float16(color.y),
        Float16(color.z), Float16(color.w)
    )
    let row = Array(repeating: encoded, count: PaintTileDescriptor.side)
    row.withUnsafeBytes { bytes in
        for y in 0..<PaintTileDescriptor.side {
            texture.replace(
                region: MTLRegionMake2D(0, y, PaintTileDescriptor.side, 1),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: bytes.count
            )
        }
    }
    return texture
}

private func makeLayerCompositeTarget(
    device: any MTLDevice,
    width: Int,
    height: Int
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderWrite]
    return try #require(device.makeTexture(descriptor: descriptor))
}

private func readLayerCompositePixels(
    _ texture: any MTLTexture
) -> [SIMD4<Float>] {
    var encoded = Array(
        repeating: SIMD4<Float16>.zero,
        count: texture.width * texture.height
    )
    encoded.withUnsafeMutableBytes { bytes in
        texture.getBytes(
            bytes.baseAddress!,
            bytesPerRow: texture.width * MemoryLayout<SIMD4<Float16>>.stride,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
    }
    return encoded.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) }
}

private func writeLayerCompositePixels(
    _ pixels: [SIMD4<Float>],
    to texture: any MTLTexture
) {
    let encoded = pixels.map {
        SIMD4<Float16>(
            Float16($0.x), Float16($0.y),
            Float16($0.z), Float16($0.w)
        )
    }
    encoded.withUnsafeBytes { bytes in
        texture.replace(
            region: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0,
            withBytes: bytes.baseAddress!,
            bytesPerRow: texture.width * MemoryLayout<SIMD4<Float16>>.stride
        )
    }
}

private func makeLayerCompositorLibrary(
    device: any MTLDevice
) throws -> any MTLLibrary {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let shader = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/MetalRenderer/Shaders.metal"
        ),
        encoding: .utf8
    )
    let header = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CShaderTypes/include/ShaderTypes.h"
        ),
        encoding: .utf8
    )
    return try device.makeLibrary(
        source: shader.replacingOccurrences(
            of: "#include \"ShaderTypes.h\"",
            with: header
        ),
        options: nil
    )
}
