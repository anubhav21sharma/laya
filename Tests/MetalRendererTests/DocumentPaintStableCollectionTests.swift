import Foundation
@preconcurrency import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Document paint stable collection", .serialized)
struct DocumentPaintStableCollectionTests {
    @Test @MainActor
    func contextOwnsAndReusesOneRendererForAffineCollections() async throws {
        guard let fixture = try makeContextFixture(size: 16) else { return }
        let output = try region(5, -3, 9, 1)
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(1.25, 2.5),
            sourceStep: SIMD2(0.5, 1.25)
        )

        let first = try await fixture.context.collectStableFiniteCanonical(
            addressing: .finite(PixelSize(width: 16, height: 16)),
            addressingRevision: 31,
            outputRegion: output,
            outputGeometryRevision: 41,
            outputMapping: .affine(transform)
        )
        let firstState = await fixture.context.snapshot()
        let second = try await fixture.context.collectStableFiniteCanonical(
            addressing: .finite(PixelSize(width: 16, height: 16)),
            addressingRevision: 32,
            outputRegion: output,
            outputGeometryRevision: 42,
            outputMapping: .affine(transform)
        )
        let secondState = await fixture.context.snapshot()

        #expect(first.outputRegion == output)
        #expect(first.pixelSize == PixelSize(width: 4, height: 4))
        #expect(first.bytesPerRow == 16)
        #expect(first.bgra8PremultipliedBytes
            == Data(repeating: 0, count: 64))
        #expect(second == first)
        #expect(firstState.stableCollectionRenderer.metrics.requestCount == 1)
        #expect(secondState.stableCollectionRenderer.metrics.requestCount == 2)
        #expect(secondState.stableCollectionRenderer.metrics
            .completedRequestCount == 2)
        #expect(firstState.stableCollectionRenderer.metrics
            .targetAllocationCount == 1)
        #expect(secondState.stableCollectionRenderer.metrics
            .targetAllocationCount == 1)
        #expect(firstState.stableCollectionRenderer.metrics
            .readbackAllocationCount == 1)
        #expect(secondState.stableCollectionRenderer.metrics
            .readbackAllocationCount == 1)
        expectNoCollectionDebt(secondState)
    }

    @Test @MainActor
    func contextRejectsRadialMappingMismatchBeforeRetentionOrAllocation()
        async throws
    {
        guard let fixture = try makeContextFixture(size: 256) else { return }
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mirror,
                rayCount: 1,
                center: WorldPoint(x: 128, y: 128)
            )),
            canvasSize: PixelSize(width: 256, height: 256)
        )
        let before = await fixture.context.snapshot()

        await #expect(throws: SparseTileSamplingPlanError
            .inconsistentAddressing) {
            _ = try await fixture.context.collectStableFiniteCanonical(
                addressing: .finite(PixelSize(width: 256, height: 256)),
                addressingRevision: 1,
                outputRegion: try region(0, 0, 4, 4),
                outputGeometryRevision: 1,
                outputMapping: try .finiteRadial(strategy: strategy)
            )
        }

        let after = await fixture.context.snapshot()
        #expect(after.stableCollectionRenderer == before.stableCollectionRenderer)
        #expect(after.residentTileBytes == before.residentTileBytes)
        #expect(after.backingTileBytes == before.backingTileBytes)
        #expect(after.activeSnapshotTokenCount == 0)
        #expect(after.aggregateSnapshotReferenceCount == 0)
        expectNoCollectionDebt(after)

        let recovered = try await fixture.context
            .collectStableFiniteCanonical(
                addressing: .finite(PixelSize(width: 256, height: 256)),
                addressingRevision: 2,
                outputRegion: try region(0, 0, 1, 1),
                outputGeometryRevision: 2,
                outputMapping: .affine(.identity)
            )
        #expect(recovered.bgra8PremultipliedBytes == Data([0, 0, 0, 0]))
        let recoveredState = await fixture.context.snapshot()
        #expect(recoveredState.stableCollectionRenderer.metrics.requestCount
            == 1)
        expectNoCollectionDebt(recoveredState)
    }

    @Test @MainActor
    func contextStableCollectionExcludesNonzeroTransientPaint() async throws {
        guard let fixture = try makeContextFixture(size: 256) else { return }
        let capability = try fixture.context.beginStrokeSurface()
        let reservation = try capability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [PaintTileCoordinate(x: 0, y: 0)],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try fill(
            reservation.bindings[0].texture,
            color: SIMD4<Float16>(0.5, 0.25, 0.125, 1),
            device: fixture.device
        )
        try capability.testingMarkDirty(reservation)
        try capability.releaseFrameReservations(
            authoritative: reservation,
            prediction: nil
        )

        let result = try await fixture.context.collectStableFiniteCanonical(
            addressing: .finite(PixelSize(width: 256, height: 256)),
            addressingRevision: 1,
            outputRegion: try region(0, 0, 1, 1),
            outputGeometryRevision: 1,
            outputMapping: .affine(.identity)
        )
        #expect(result.bgra8PremultipliedBytes == Data([0, 0, 0, 0]))

        try fixture.context.cancelStrokeSurface(capability)
        let terminal = await fixture.context.snapshot()
        #expect(terminal.activeStrokeSurfaceCount == 0)
        expectNoCollectionDebt(terminal)
    }

    @Test @MainActor
    func committedFiniteAndPeriodicEachCollectOneAffineRaster() async throws {
        guard let fixture = try makeContextFixture(size: 16) else { return }
        let size = PixelSize(width: 16, height: 16)

        let finite = try await fixture.context.collectStableCommittedStorage(
            addressing: .finite(size),
            addressingRevision: 51,
            outputGeometryRevision: 61
        )
        let periodic = try await fixture.context.collectStableCommittedStorage(
            addressing: .periodic(period: size),
            addressingRevision: 52,
            outputGeometryRevision: 62
        )

        #expect(finite.documentPixelSize == size)
        #expect(finite.storagePixelSize == size)
        #expect(periodic.documentGeneration == finite.documentGeneration)
        guard case let .singleRaster(finiteRaster) = finite.storage,
              case let .singleRaster(periodicRaster) = periodic.storage
        else {
            Issue.record("plain and periodic storage must be one raster")
            return
        }
        let fullRegion = try region(0, 0, 16, 16)
        #expect(finiteRaster.outputRegion == fullRegion)
        #expect(finiteRaster.bgra8PremultipliedBytes
            == Data(repeating: 0, count: 16 * 16 * 4))
        #expect(periodicRaster == finiteRaster)
        let terminal = await fixture.context.snapshot()
        #expect(terminal.stableCollectionRenderer.metrics.requestCount == 2)
        expectNoCollectionDebt(terminal)
    }

    @Test @MainActor
    func committedRadialCollectsLogicalPagesInDeterministicOrder() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 384,
            sectorAngleRadians: .pi
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 768, height: 768),
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: try makeLibrary(device),
            geometry: geometry,
            initialLayerID: UUID(),
            byteBudget: PaintTileDescriptor.residentByteCount
                * layout.residentPages.count,
            transferByteCapacity: PaintTileDescriptor.residentByteCount
                * max(8, layout.residentPages.count + 2),
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 8
        )

        let result = try await context.collectStableCommittedStorage(
            addressing: .radial(layout: layout),
            addressingRevision: 71,
            outputGeometryRevision: 72
        )

        #expect(result.documentPixelSize == geometry.documentPixelSize)
        #expect(result.storagePixelSize == geometry.storagePixelSize)
        guard case let .radialPages(pages) = result.storage else {
            Issue.record("radial storage must not become an atlas")
            return
        }
        #expect(pages.isEmpty)
        let terminal = await context.snapshot()
        #expect(terminal.stableCollectionRenderer.metrics.requestCount
            == UInt64(layout.residentPages.count))
        expectNoCollectionDebt(terminal)
    }

    @Test @MainActor
    func stablePersistenceAdaptersEmitTightPlainAndSortedRadialStorage()
        async throws
    {
        let plainSize = PixelSize(width: 256, height: 256)
        let plainGeometry = try DocumentPaintGeometry(
            documentPixelSize: plainSize,
            storagePixelSize: plainSize,
            radialLayout: nil
        )
        guard let plain = try makeRegistryFixture(geometry: plainGeometry)
        else { return }
        let plainColor = SIMD4<Float>(0.25, 0.125, 0.0625, 0.5)
        try seed(plain, coordinate: .init(x: 0, y: 0), color: plainColor)
        let plainCapture = try plain.registry.captureStableCommittedCollection(
            layerID: plain.layerID,
            addressing: .finite(plainSize),
            addressingRevision: 201,
            rendererLimits: .production
        )
        let plainSnapshot = try await CommittedDocumentSnapshot.collectStable(
            canvasSize: plainSize,
            documentConfiguration: .finite(.plain),
            documentDomainLocked: true,
            radialGeometryLocked: false,
            capture: plainCapture,
            renderer: plain.renderer,
            outputGeometryRevision: 202
        )
        guard case let .singleRaster(plainBytes) = plainSnapshot.storage else {
            Issue.record("plain persistence emitted paged storage")
            return
        }
        let expectedPlainPixel = try encodedPixel(plainColor)
        #expect(plainBytes.count == plainSize.width * plainSize.height * 4)
        #expect(Array(plainBytes.prefix(4)) == expectedPlainPixel)
        await assertNoRegistryOrRendererDebt(plain)

        let radialConfiguration = RadialSymmetryConfiguration(
            kind: .mirror,
            rayCount: 1,
            center: WorldPoint(x: 384, y: 384)
        )
        let radialCanvas = PixelSize(width: 768, height: 768)
        let radialStrategy = try TilingStrategy(
            finiteConfiguration: .radial(radialConfiguration),
            canvasSize: radialCanvas
        )
        let layout = try #require(
            radialStrategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let radialGeometry = try DocumentPaintGeometry(
            documentPixelSize: radialCanvas,
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        guard let radial = try makeRegistryFixture(
            geometry: radialGeometry,
            byteBudgetTiles: layout.residentPages.count
        ) else { return }
        let selected = Array(layout.residentPages.reversed().prefix(2))
        for (index, page) in selected.enumerated() {
            try seed(
                radial,
                coordinate: .init(
                    x: page.atlasSlot % layout.atlasColumns,
                    y: page.atlasSlot / layout.atlasColumns
                ),
                color: SIMD4<Float>(
                    Float(index + 1) / 8,
                    Float(index + 2) / 8,
                    Float(index + 3) / 8,
                    1
                )
            )
        }
        let radialCapture = try radial.registry
            .captureStableCommittedCollection(
                layerID: radial.layerID,
                addressing: .radial(layout: layout),
                addressingRevision: 203,
                rendererLimits: .production
            )
        let radialSnapshot = try await CommittedDocumentSnapshot.collectStable(
            canvasSize: radialCanvas,
            documentConfiguration: .finite(.radial(radialConfiguration)),
            documentDomainLocked: true,
            radialGeometryLocked: true,
            capture: radialCapture,
            renderer: radial.renderer,
            outputGeometryRevision: 204
        )
        guard case let .radialPages(pages) = radialSnapshot.storage else {
            Issue.record("radial persistence assembled a raster atlas")
            return
        }
        #expect(pages.map(\.coordinate) == selected.map(\.coordinate).sorted())
        #expect(pages.allSatisfy {
            $0.bgra8PremultipliedBytes.count == 256 * 256 * 4
        })
        await assertNoRegistryOrRendererDebt(radial)
    }

    @Test @MainActor
    func stableFiniteAndFlattenedAdaptersCollectFinalTightDestinations()
        async throws
    {
        let size = PixelSize(width: 256, height: 256)
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: size,
            storagePixelSize: size,
            radialLayout: nil
        )
        guard let fixture = try makeRegistryFixture(geometry: geometry)
        else { return }
        let color = SIMD4<Float>(0.25, 0.125, 0.0625, 0.5)
        try seed(fixture, coordinate: .init(x: 0, y: 0), color: color)
        let strategy = try TilingStrategy(
            finiteConfiguration: .plain,
            canvasSize: size
        )
        let finiteRoot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(size),
            addressingRevision: 211
        )
        let finite = try await FiniteCanvasExport.collectStable(
            strategy: strategy,
            snapshot: finiteRoot,
            renderer: fixture.renderer,
            outputGeometryRevision: 212,
            transparentBackground: false
        )
        let expectedColor = try encodedPixel(color)
        let expectedOpaqueColor = opaquePaperPixel(expectedColor)
        #expect(finite.pixelSize == size)
        #expect(finite.bytesPerRow == size.width * 4)
        #expect(Array(finite.bgra8Bytes.prefix(4)) == expectedOpaqueColor)
        #expect(!finite.hasTransparentBackground)

        let outputSize = PixelSize(width: 64, height: 80)
        let mapping = SparseTileSamplingOutputMapping.affine(
            SparseTileOutputToSourceTransform(
                sourceOffset: SIMD2(31.5, 47.5),
                sourceStep: SIMD2(2, 2)
            )
        )
        let flattenedRoot = try fixture.registry
            .captureStableCanonicalSnapshot(
                layerID: fixture.layerID,
                addressing: .finite(size),
                addressingRevision: 213,
                outputMapping: mapping
            )
        let request = try DocumentPaintStableFlattenedOutputRequest(
            pixelSize: outputSize,
            outputMapping: mapping,
            transparentBackground: true
        )
        let flattened = try await FlattenedSceneExport.collectStable(
            request: request,
            snapshot: flattenedRoot,
            renderer: fixture.renderer,
            outputGeometryRevision: 214
        )
        #expect(flattened.pixelSize == outputSize)
        #expect(flattened.bytesPerRow == outputSize.width * 4)
        #expect(flattened.bgra8Bytes.count
            == outputSize.width * outputSize.height * 4)
        #expect(Array(flattened.bgra8Bytes.prefix(4)) == expectedColor)
        await assertNoRegistryOrRendererDebt(fixture)
    }

    @Test @MainActor
    func stableMetricAndBakedAdaptersPreserveScaleAndMirrorXMapping()
        async throws
    {
        let size = PixelSize(width: 256, height: 256)
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: size,
            storagePixelSize: size,
            radialLayout: nil
        )
        guard let fixture = try makeRegistryFixture(geometry: geometry)
        else { return }
        let pixels = (0..<(256 * 256)).map { index -> SIMD4<Float16> in
            let x = index % 256
            return SIMD4(
                Float16(Float(x + 1) / 512),
                Float16(0.125),
                Float16(0.0625),
                Float16(1)
            )
        }
        try seed(fixture, coordinate: .init(x: 0, y: 0), pixels: pixels)

        let metricStrategy = try TilingStrategy(
            configuration: .defaultConfiguration(
                presetID: .squareRotation,
                canonicalRasterSize: size
            ),
            canonicalRasterSize: size
        )
        let metricRoot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .periodic(period: size),
            addressingRevision: 221
        )
        let metric = try await PeriodicRepeatExport.collectStableMetric(
            strategy: metricStrategy,
            density: 64,
            snapshot: metricRoot,
            renderer: fixture.renderer,
            outputGeometryRevision: 222
        )
        #expect(metric.pixelSize == PixelSize(width: 64, height: 64))
        #expect(metric.bytesPerRow == 256)
        #expect(metric.bgra8Bytes.count == 64 * 64 * 4)

        let mirrorStrategy = try TilingStrategy(
            configuration: .defaultConfiguration(
                presetID: .mirrorX,
                canonicalRasterSize: size
            ),
            canonicalRasterSize: size
        )
        let bakedRoot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .periodic(period: size),
            addressingRevision: 223
        )
        let baked = try await PeriodicRepeatExport.collectStableBaked(
            strategy: mirrorStrategy,
            snapshot: bakedRoot,
            renderer: fixture.renderer,
            outputGeometryRevision: 224
        )
        let expectedReflectedPixel = try encodedPixel(pixels[255])
        #expect(baked.pixelSize == PixelSize(width: 512, height: 256))
        #expect(
            stableExportPixel(baked, x: 256, y: 0)
                == expectedReflectedPixel
        )
        await assertNoRegistryOrRendererDebt(fixture)
    }

    @Test @MainActor
    func affineCollectionMatchesCPUOracleForEveryByteWithScaledMapping()
        async throws
    {
        guard let fixture = try makeRegistryFixture(
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 256, height: 256),
                storagePixelSize: PixelSize(width: 256, height: 256),
                radialLayout: nil
            )
        ) else { return }
        let pixels = (0..<(PaintTileDescriptor.side
            * PaintTileDescriptor.side)).map { index in
            let x = index % PaintTileDescriptor.side
            let y = index / PaintTileDescriptor.side
            return SIMD4<Float16>(
                Float16(Float((x * 3 + y) % 31 + 1) / 64),
                Float16(Float((x + y * 5) % 29 + 1) / 64),
                Float16(Float((x * 7 + y * 3) % 23 + 1) / 64),
                1
            )
        }
        try seed(
            fixture,
            coordinate: .init(x: 0, y: 0),
            pixels: pixels
        )
        let root = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 81
        )
        let output = try region(11, -7, 29, 6)
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(17.25, 23.5),
            sourceStep: SIMD2(1.5, 0.75)
        )
        let result = try await DocumentPaintStableCollectionEngine.collect(
            snapshot: root,
            renderer: fixture.renderer,
            descriptor: .init(
                outputRegion: output,
                maximumByteCount: output.width * output.height * 4
            ),
            outputGeometryRevision: 82,
            outputMapping: .affine(transform)
        )

        let expected = try expectedAffineBytes(
            output: output,
            transform: transform,
            pixels: pixels
        )
        expectEncodedBytesWithinOne(
            result.bgra8PremultipliedBytes,
            expected
        )
        #expect(result.outputRegion == output)
        #expect(result.pixelSize
            == PixelSize(width: output.width, height: output.height))
        #expect(root.activeChildSelectionCount == 0)
        root.close()
        await assertNoRegistryOrRendererDebt(fixture)
    }

    @Test @MainActor
    func finiteRadialCollectionMatchesCPUOracleForEveryByte() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let configuration = RadialSymmetryConfiguration(
            kind: .mirror,
            rayCount: 1,
            center: WorldPoint(x: 384, y: 384),
            referenceAngleRadians: 0.23
        )
        let canvas = PixelSize(width: 768, height: 768)
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(configuration),
            canvasSize: canvas
        )
        let layout = try #require(
            strategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: canvas,
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        guard let fixture = try makeRegistryFixture(
            device: device,
            geometry: geometry,
            byteBudgetTiles: layout.residentPages.count
        ) else { return }
        var colors: [PaintTileCoordinate: SIMD4<Float>] = [:]
        for page in layout.residentPages {
            let index = page.atlasSlot + 1
            let color = SIMD4<Float>(
                Float((index * 3) % 11 + 1) / 16,
                Float((index * 5) % 13 + 1) / 16,
                Float((index * 7) % 9 + 1) / 16,
                1
            )
            let coordinate = PaintTileCoordinate(
                x: page.atlasSlot % layout.atlasColumns,
                y: page.atlasSlot / layout.atlasColumns
            )
            colors[coordinate] = color
            try seed(
                fixture,
                coordinate: coordinate,
                color: color
            )
        }
        let root = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .radial(layout: layout),
            addressingRevision: 91
        )
        let output = try region(552, 272, 616, 336)
        let result = try await DocumentPaintStableCollectionEngine.collect(
            snapshot: root,
            renderer: fixture.renderer,
            descriptor: .init(
                outputRegion: output,
                maximumByteCount: output.width * output.height * 4
            ),
            outputGeometryRevision: 92,
            outputMapping: try .finiteRadial(strategy: strategy)
        )

        let expected = try expectedRadialBytes(
            output: output,
            configuration: configuration,
            canvasSize: canvas,
            layout: layout,
            colors: colors
        )
        expectEncodedBytesWithinOne(
            result.bgra8PremultipliedBytes,
            expected
        )
        #expect(root.activeChildSelectionCount == 0)
        root.close()
        await assertNoRegistryOrRendererDebt(fixture)

        let queue = try #require(device.makeCommandQueue())
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: try makeLibrary(device),
            geometry: geometry,
            initialLayerID: UUID(),
            byteBudget: PaintTileDescriptor.residentByteCount
                * layout.residentPages.count,
            transferByteCapacity: PaintTileDescriptor.residentByteCount
                * max(8, layout.residentPages.count + 2),
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 8
        )
        let facadeOutput = try region(552, 272, 556, 275)
        let facade = try await context.collectStableFiniteCanonical(
            addressing: .radial(layout: layout),
            addressingRevision: 93,
            outputRegion: facadeOutput,
            outputGeometryRevision: 94,
            outputMapping: try .finiteRadial(strategy: strategy)
        )
        #expect(facade.bgra8PremultipliedBytes
            == Data(repeating: 0, count: facadeOutput.width
                * facadeOutput.height * 4))
        expectNoCollectionDebt(await context.snapshot())
    }

    @Test @MainActor
    func committedRadialPagesUseOneOldRootAndOmitOnlyCollectedTransparency()
        async throws
    {
        let layout = try RadialSectorLayout(
            maximumRadius: 384,
            sectorAngleRadians: .pi
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 768, height: 768),
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        guard let fixture = try makeRegistryFixture(
            geometry: geometry,
            byteBudgetTiles: layout.residentPages.count
        ) else { return }
        let selected = Array(layout.residentPages.prefix(2))
        let oldColors = [
            SIMD4<Float>(0.25, 0.125, 0.0625, 0.5),
            SIMD4<Float>(0.0625, 0.25, 0.125, 0.5),
        ]
        for (page, color) in zip(selected, oldColors) {
            try seed(
                fixture,
                coordinate: PaintTileCoordinate(
                    x: page.atlasSlot % layout.atlasColumns,
                    y: page.atlasSlot / layout.atlasColumns
                ),
                color: color
            )
        }
        let addressing = SparseTileAddressing.radial(layout: layout)
        let oldCapture = try fixture.registry
            .captureStableCommittedCollection(
            layerID: fixture.layerID,
            addressing: addressing,
            addressingRevision: 101,
            rendererLimits: .production
        )
        let newColor = SIMD4<Float>(0.125, 0.0625, 0.25, 0.5)
        let firstPhysical = PaintTileCoordinate(
            x: selected[0].atlasSlot % layout.atlasColumns,
            y: selected[0].atlasSlot / layout.atlasColumns
        )
        try seed(fixture, coordinate: firstPhysical, color: newColor)

        let old = try await DocumentPaintStableCollectionEngine
            .collectCommitted(
                oldCapture,
                renderer: fixture.renderer,
                outputGeometryRevision: 102
            )
        #expect(oldCapture.activeChildSelectionCount == 0)
        oldCapture.close()
        guard case let .radialPages(oldPages) = old.storage else {
            Issue.record("radial collection returned an atlas")
            return
        }
        #expect(oldPages.map(\.coordinate)
            == selected.map(\.coordinate).sorted())
        for (page, color) in zip(oldPages, oldColors) {
            let expected = repeatedPixel(
                try encodedPixel(color),
                count: RadialSectorLayout.pageSide
                    * RadialSectorLayout.pageSide
            )
            expectEncodedBytesWithinOne(
                page.image.bgra8PremultipliedBytes,
                expected
            )
        }
        #expect(oldPages.allSatisfy {
            $0.image.outputRegion.minX
                == $0.coordinate.x * RadialSectorLayout.pageSide
                && $0.image.outputRegion.minY
                    == $0.coordinate.y * RadialSectorLayout.pageSide
        })

        let newCapture = try fixture.registry
            .captureStableCommittedCollection(
            layerID: fixture.layerID,
            addressing: addressing,
            addressingRevision: 103,
            rendererLimits: .production
        )
        let new = try await DocumentPaintStableCollectionEngine
            .collectCommitted(
                newCapture,
                renderer: fixture.renderer,
                outputGeometryRevision: 104
            )
        #expect(newCapture.activeChildSelectionCount == 0)
        newCapture.close()
        guard case let .radialPages(newPages) = new.storage else { return }
        #expect(new.documentGeneration != old.documentGeneration)
        let firstExpected = repeatedPixel(
            try encodedPixel(newColor),
            count: RadialSectorLayout.pageSide * RadialSectorLayout.pageSide
        )
        expectEncodedBytesWithinOne(
            try #require(newPages.first).image.bgra8PremultipliedBytes,
            firstExpected
        )
        await assertNoRegistryOrRendererDebt(fixture)
    }

    @Test @MainActor
    func committedCaptureAndGeometryPublicationLinearizeAsWholeEpochs()
        async throws
    {
        let oldGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 16, height: 16),
            storagePixelSize: PixelSize(width: 16, height: 16),
            radialLayout: nil
        )
        let newGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 32, height: 16),
            storagePixelSize: PixelSize(width: 16, height: 16),
            radialLayout: nil
        )
        guard let fixture = try makeRegistryFixture(geometry: oldGeometry)
        else { return }
        let replacement = try fixture.registry.makeCandidate(
            geometry: newGeometry
        )
        let prepared = try fixture.registry.prepareCommit(replacement)
        let barrier = StableCommittedCaptureRaceBarrier()
        fixture.registry.testingEpochHook = barrier.hook

        let captureTask = Task.detached {
            try fixture.registry.captureStableCommittedCollection(
                layerID: fixture.layerID,
                addressing: .finite(oldGeometry.storagePixelSize),
                addressingRevision: 105,
                rendererLimits: .production
            )
        }
        try await barrier.waitUntilReached()
        let commitTask = Task.detached {
            fixture.registry.commitPrepared(prepared)
        }
        barrier.release()
        let oldCapture = try await captureTask.value
        await commitTask.value
        fixture.registry.testingEpochHook = nil

        let newCapture = try fixture.registry
            .captureStableCommittedCollection(
                layerID: fixture.layerID,
                addressing: .finite(newGeometry.storagePixelSize),
                addressingRevision: 106,
                rendererLimits: .production
            )
        let old = try await DocumentPaintStableCollectionEngine
            .collectCommitted(
                oldCapture,
                renderer: fixture.renderer,
                outputGeometryRevision: 107
            )
        let new = try await DocumentPaintStableCollectionEngine
            .collectCommitted(
                newCapture,
                renderer: fixture.renderer,
                outputGeometryRevision: 108
            )
        oldCapture.close()
        oldCapture.close()
        newCapture.close()

        #expect(old.documentGeneration + 1 == new.documentGeneration)
        #expect(old.documentPixelSize == oldGeometry.documentPixelSize)
        #expect(old.storagePixelSize == oldGeometry.storagePixelSize)
        #expect(new.documentPixelSize == newGeometry.documentPixelSize)
        #expect(new.storagePixelSize == newGeometry.storagePixelSize)
        await assertNoRegistryOrRendererDebt(fixture)
    }

    @Test @MainActor
    func retainedRootsStayWholeAcrossMutationClearAndResize() async throws {
        let oldGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 256, height: 256),
            storagePixelSize: PixelSize(width: 256, height: 256),
            radialLayout: nil
        )
        guard let fixture = try makeRegistryFixture(geometry: oldGeometry)
        else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let oldColor = SIMD4<Float>(0.25, 0.125, 0, 0.5)
        let mutatedColor = SIMD4<Float>(0, 0.25, 0.125, 0.5)
        try seed(fixture, coordinate: coordinate, color: oldColor)
        let oldRoot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(oldGeometry.storagePixelSize),
            addressingRevision: 111
        )
        try seed(fixture, coordinate: coordinate, color: mutatedColor)
        let mutatedRoot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(oldGeometry.storagePixelSize),
            addressingRevision: 112
        )
        let clear = try fixture.registry.makeCandidate(
            removingCoordinatesByLayer: [fixture.layerID: [coordinate]]
        )
        fixture.registry.commitPrepared(
            try fixture.registry.prepareCommit(clear)
        )
        let clearRoot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(oldGeometry.storagePixelSize),
            addressingRevision: 113
        )
        let resizedGeometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 512, height: 256),
            storagePixelSize: PixelSize(width: 512, height: 256),
            radialLayout: nil
        )
        let resize = try fixture.registry.makeCandidate(
            geometry: resizedGeometry
        )
        fixture.registry.commitPrepared(
            try fixture.registry.prepareCommit(resize)
        )
        let resizedRoot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(resizedGeometry.storagePixelSize),
            addressingRevision: 114
        )
        let output = try region(0, 0, 32, 32)
        let descriptor = try DocumentPaintTightBGRA8Descriptor(
            outputRegion: output,
            maximumByteCount: 32 * 32 * 4
        )
        let roots = [oldRoot, mutatedRoot, clearRoot, resizedRoot]
        let expectedPixels = [
            try encodedPixel(oldColor),
            try encodedPixel(mutatedColor),
            [UInt8](repeating: 0, count: 4),
            [UInt8](repeating: 0, count: 4),
        ]
        for (root, pixel) in zip(roots, expectedPixels) {
            let result = try await DocumentPaintStableCollectionEngine.collect(
                snapshot: root,
                renderer: fixture.renderer,
                descriptor: descriptor,
                outputGeometryRevision: 115,
                outputMapping: .affine(.identity)
            )
            expectEncodedBytesWithinOne(
                result.bgra8PremultipliedBytes,
                repeatedPixel(pixel, count: output.width * output.height)
            )
            #expect(root.activeChildSelectionCount == 0)
            root.close()
        }
        #expect(Set(roots.map(\.documentGeneration)).count == roots.count)
        await assertNoRegistryOrRendererDebt(fixture)
    }

    @Test
    func collectorCancellationLeavesOneAbortTerminalAndNoResult()
        async throws
    {
        let output = try region(0, 0, 1, 1)
        let collector = try DocumentPaintTightBGRA8Collector(
            descriptor: .init(outputRegion: output, maximumByteCount: 4)
        )
        try await collector.begin(sinkDescriptor(output))
        let gate = StableCollectionTestGate()
        let task = Task {
            await gate.wait()
            try await collector.consume(DocumentPaintStableSnapshotChunk(
                outputRegion: output,
                bytesPerRow: 4,
                bytes: Data([1, 2, 3, 4])
            ))
        }
        for _ in 0..<1_000 {
            if await gate.isWaiting { break }
            await Task.yield()
        }
        #expect(await gate.isWaiting)
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        await collector.abort()
        await collector.abort()
        await #expect(throws: DocumentPaintStableCollectionError
            .collectionUnavailable) {
            _ = try await collector.result()
        }
    }

    @Test
    func collectorReconstructsOutOfOrderChunksInTightRowMajorOrder()
        async throws
    {
        let output = try region(10, -2, 14, 0)
        let collector = try DocumentPaintTightBGRA8Collector(
            descriptor: .init(outputRegion: output, maximumByteCount: 32)
        )
        try await collector.begin(sinkDescriptor(output))

        try await collector.consume(chunk(
            try region(12, -1, 14, 0),
            pixels: [7, 8]
        ))
        try await collector.consume(chunk(
            try region(10, -2, 14, -1),
            pixels: [1, 2, 3, 4]
        ))
        try await collector.consume(chunk(
            try region(10, -1, 12, 0),
            pixels: [5, 6]
        ))
        try await collector.finish()

        let result = try await collector.result()
        #expect(result.outputRegion == output)
        #expect(result.pixelSize == PixelSize(width: 4, height: 2))
        #expect(result.bytesPerRow == 16)
        #expect(result.bgra8PremultipliedBytes == Data((1...8).flatMap(pixel)))
    }

    @Test
    func collectorRejectsOverlapWithoutCorruptingAcceptedRows() async throws {
        let output = try region(0, 0, 3, 2)
        let collector = try DocumentPaintTightBGRA8Collector(
            descriptor: .init(outputRegion: output, maximumByteCount: 24)
        )
        try await collector.begin(sinkDescriptor(output))
        let first = chunk(try region(0, 0, 1, 1), pixels: [1])
        try await collector.consume(first)

        await #expect(throws: DocumentPaintStableCollectionError
            .overlappingChunk(try region(0, 0, 3, 1))) {
            try await collector.consume(chunk(
                try region(0, 0, 3, 1),
                pixels: [9, 9, 9]
            ))
        }
        try await collector.consume(chunk(
            try region(1, 0, 3, 1),
            pixels: [2, 3]
        ))
        try await collector.consume(chunk(
            try region(0, 1, 3, 2),
            pixels: [4, 5, 6]
        ))
        try await collector.finish()
        #expect(try await collector.result().bgra8PremultipliedBytes
            == Data((1...6).flatMap(pixel)))
    }

    @Test
    func collectorCoverageStaysDescriptorBoundedUnderPixelFragments()
        async throws
    {
        let side = 32
        let pixelCount = side * side
        var structuralCoverage = try DocumentPaintStablePixelCoverage(
            pixelCount: pixelCount
        )
        #expect(structuralCoverage.storageByteCount == pixelCount / 8)
        for index in 0..<pixelCount {
            structuralCoverage.insert(index)
        }
        #expect(structuralCoverage.coveredPixelCount == pixelCount)
        #expect(structuralCoverage.storageByteCount == pixelCount / 8)
        #expect(structuralCoverage.contains(0))
        #expect(structuralCoverage.contains(pixelCount - 1))

        let output = try region(-16, 7, 16, 39)
        let collector = try DocumentPaintTightBGRA8Collector(
            descriptor: .init(
                outputRegion: output,
                maximumByteCount: pixelCount * 4
            )
        )
        try await collector.begin(sinkDescriptor(output))
        for index in (0..<pixelCount).reversed() {
            let x = index % side
            let y = index / side
            try await collector.consume(chunk(
                try region(
                    output.minX + x,
                    output.minY + y,
                    output.minX + x + 1,
                    output.minY + y + 1
                ),
                pixels: [UInt8(index % 251)]
            ))
        }
        try await collector.finish()
        #expect(try await collector.result().bgra8PremultipliedBytes
            == Data((0..<pixelCount).flatMap { pixel(UInt8($0 % 251)) }))
    }

    @Test
    func collectorRejectsGapAtTheSingleFinishBoundary() async throws {
        let output = try region(0, 0, 2, 2)
        let collector = try DocumentPaintTightBGRA8Collector(
            descriptor: .init(outputRegion: output, maximumByteCount: 16)
        )
        try await collector.begin(sinkDescriptor(output))
        try await collector.consume(chunk(
            try region(0, 0, 2, 1),
            pixels: [1, 2]
        ))

        await #expect(throws: DocumentPaintStableCollectionError
            .incompleteCoverage(expectedPixels: 4, actualPixels: 2)) {
            try await collector.finish()
        }
        await collector.abort()
        await #expect(throws: DocumentPaintStableCollectionError
            .collectionUnavailable) {
            _ = try await collector.result()
        }
    }

    @Test
    func collectorValidatesDescriptorStrideAndBytesBeforeCopy() async throws {
        let output = try region(-1, 4, 1, 5)
        #expect(throws: DocumentPaintStableCollectionError
            .outputByteLimitExceeded(required: 8, maximum: 7)) {
            _ = try DocumentPaintTightBGRA8Descriptor(
                outputRegion: output,
                maximumByteCount: 7
            )
        }
        let collector = try DocumentPaintTightBGRA8Collector(
            descriptor: .init(outputRegion: output, maximumByteCount: 8)
        )
        await #expect(throws: DocumentPaintStableCollectionError
            .descriptorMismatch) {
            try await collector.begin(DocumentPaintStableSnapshotSinkDescriptor(
                outputRegion: output,
                bytesPerPixel: 8,
                pixelFormatRawValue: 0
            ))
        }
        try await collector.begin(sinkDescriptor(output))
        await #expect(throws: DocumentPaintStableCollectionError
            .invalidChunkStride(expected: 8, actual: 12)) {
            try await collector.consume(DocumentPaintStableSnapshotChunk(
                outputRegion: output,
                bytesPerRow: 12,
                bytes: Data(repeating: 1, count: 12)
            ))
        }
        await #expect(throws: DocumentPaintStableCollectionError
            .invalidChunkByteCount(expected: 8, actual: 7)) {
            try await collector.consume(DocumentPaintStableSnapshotChunk(
                outputRegion: output,
                bytesPerRow: 8,
                bytes: Data(repeating: 1, count: 7)
            ))
        }
        await collector.abort()
    }

    private func region(
        _ minX: Int,
        _ minY: Int,
        _ maxX: Int,
        _ maxY: Int
    ) throws -> SparseTileOutputRegion {
        try SparseTileOutputRegion(
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY
        )
    }

    private func sinkDescriptor(
        _ output: SparseTileOutputRegion
    ) -> DocumentPaintStableSnapshotSinkDescriptor {
        DocumentPaintStableSnapshotSinkDescriptor(
            outputRegion: output,
            bytesPerPixel: 4,
            pixelFormatRawValue:
                DocumentColorPipeline.interchangePixelFormat.rawValue
        )
    }

    private func chunk(
        _ output: SparseTileOutputRegion,
        pixels: [UInt8]
    ) -> DocumentPaintStableSnapshotChunk {
        DocumentPaintStableSnapshotChunk(
            outputRegion: output,
            bytesPerRow: output.width * 4,
            bytes: Data(pixels.flatMap(pixel))
        )
    }

    private func pixel(_ value: UInt8) -> [UInt8] {
        [value, value, value, value]
    }

    private struct RegistryFixture {
        let device: any MTLDevice
        let layerID: UUID
        let geometry: DocumentPaintGeometry
        let registry: DocumentPaintSurfaceStore
        let renderer: DocumentPaintStableSnapshotRenderer
    }

    @MainActor
    private func makeRegistryFixture(
        device suppliedDevice: (any MTLDevice)? = nil,
        geometry: DocumentPaintGeometry,
        byteBudgetTiles: Int = 8
    ) throws -> RegistryFixture? {
        guard let device = suppliedDevice ?? MTLCreateSystemDefaultDevice()
        else { return nil }
        let layerID = UUID()
        return RegistryFixture(
            device: device,
            layerID: layerID,
            geometry: geometry,
            registry: try DocumentPaintSurfaceStore(
                device: device,
                byteBudget: PaintTileDescriptor.residentByteCount
                    * max(1, byteBudgetTiles),
                transferByteCapacity: PaintTileDescriptor.residentByteCount
                    * max(8, byteBudgetTiles + 2),
                geometry: geometry,
                layerIDs: [layerID]
            ),
            renderer: try DocumentPaintStableSnapshotRenderer.make(
                device: device,
                library: try makeLibrary(device),
                limits: .production,
                planLimits: .documentProduction
            )
        )
    }

    @MainActor
    private func seed(
        _ fixture: RegistryFixture,
        coordinate: PaintTileCoordinate,
        color: SIMD4<Float>
    ) throws {
        let half = SIMD4<Float16>(
            Float16(color.x), Float16(color.y),
            Float16(color.z), Float16(color.w)
        )
        try seed(
            fixture,
            coordinate: coordinate,
            pixels: Array(
                repeating: half,
                count: PaintTileDescriptor.side * PaintTileDescriptor.side
            )
        )
    }

    @MainActor
    private func seed(
        _ fixture: RegistryFixture,
        coordinate: PaintTileCoordinate,
        pixels: [SIMD4<Float16>]
    ) throws {
        #expect(pixels.count
            == PaintTileDescriptor.side * PaintTileDescriptor.side)
        let candidate = try fixture.registry.makeCandidate(
            dirtyCoordinatesByLayer: [fixture.layerID: [coordinate]]
        )
        fixture.registry.commitPrepared(
            try fixture.registry.prepareCommit(candidate)
        )
        let binding = try fixture.registry.binding(for: fixture.layerID)
        let lease = try binding.canonical.leaseExistingTiles(
            at: [coordinate],
            pinReasons: [.inFlight]
        )
        defer { try? binding.canonical.returnLease(lease) }
        let texture = try #require(lease.bindings.first?.texture)
        try fill(
            texture,
            pixels: pixels,
            device: fixture.device
        )
        try fixture.registry.sharedTileStore.markModified(
            lease,
            surfaceID: lease.surfaceID,
            currentGeneration: lease.generation,
            coordinates: [coordinate]
        )
    }

    private func encodedPixel(_ color: SIMD4<Float>) throws -> [UInt8] {
        let quantized = SIMD4<Float>(
            Float(Float16(color.x)), Float(Float16(color.y)),
            Float(Float16(color.z)), Float(Float16(color.w))
        )
        let linear = try #require(LinearPremultipliedColor(
            red: quantized.x,
            green: quantized.y,
            blue: quantized.z,
            alpha: quantized.w
        ))
        let encoded = DocumentColorPipeline
            .exportEncodedPremultipliedBGRA8(linear)
        return [encoded.blue, encoded.green, encoded.red, encoded.alpha]
    }

    private func encodedPixel(_ color: SIMD4<Float16>) throws -> [UInt8] {
        try encodedPixel(SIMD4(
            Float(color.x), Float(color.y), Float(color.z), Float(color.w)
        ))
    }

    private func stableExportPixel(
        _ export: PeriodicRepeatExport,
        x: Int,
        y: Int
    ) -> [UInt8] {
        let offset = y * export.bytesPerRow + x * 4
        return Array(export.bgra8Bytes[offset..<(offset + 4)])
    }

    private func opaquePaperPixel(_ sourceBytes: [UInt8]) -> [UInt8] {
        precondition(sourceBytes.count == 4)
        let source = DocumentColorPipeline.importEncodedPremultipliedBGRA8(
            EncodedPremultipliedBGRA8(
                blue: sourceBytes[0],
                green: sourceBytes[1],
                red: sourceBytes[2],
                alpha: sourceBytes[3]
            )
        )
        let paper = DocumentColorPipeline.importEncodedPremultipliedBGRA8(
            EncodedPremultipliedBGRA8(
                blue: GridCanvasContract.paperBGRA.x,
                green: GridCanvasContract.paperBGRA.y,
                red: GridCanvasContract.paperBGRA.z,
                alpha: GridCanvasContract.paperBGRA.w
            )
        )
        let output = DocumentColorPipeline.exportEncodedPremultipliedBGRA8(
            DocumentColorPipeline.referenceSourceOver(
                source: source,
                destination: paper
            )
        )
        return [output.blue, output.green, output.red, output.alpha]
    }

    private func expectedAffineBytes(
        output: SparseTileOutputRegion,
        transform: SparseTileOutputToSourceTransform,
        pixels: [SIMD4<Float16>]
    ) throws -> Data {
        let side = PaintTileDescriptor.side
        func value(_ x: Int, _ y: Int) -> SIMD4<Float> {
            guard x >= 0, y >= 0, x < side, y < side else { return .zero }
            let value = pixels[y * side + x]
            return SIMD4(
                Float(value.x), Float(value.y),
                Float(value.z), Float(value.w)
            )
        }
        var result = Data()
        result.reserveCapacity(output.width * output.height * 4)
        for y in 0..<output.height {
            for x in 0..<output.width {
                let point = SIMD2<Float>(
                    Float(output.minX) + transform.sourceOffset.x
                        + (Float(x) + 0.5) * transform.sourceStep.x,
                    Float(output.minY) + transform.sourceOffset.y
                        + (Float(y) + 0.5) * transform.sourceStep.y
                )
                let sample = point - SIMD2<Float>(repeating: 0.5)
                let lowerX = Int(floor(sample.x))
                let lowerY = Int(floor(sample.y))
                let fraction = SIMD2(
                    sample.x - floor(sample.x),
                    sample.y - floor(sample.y)
                )
                let top = value(lowerX, lowerY)
                    + (value(lowerX + 1, lowerY)
                        - value(lowerX, lowerY)) * fraction.x
                let bottom = value(lowerX, lowerY + 1)
                    + (value(lowerX + 1, lowerY + 1)
                        - value(lowerX, lowerY + 1)) * fraction.x
                let linearValue = top + (bottom - top) * fraction.y
                let linear = try #require(LinearPremultipliedColor(
                    red: linearValue.x,
                    green: linearValue.y,
                    blue: linearValue.z,
                    alpha: linearValue.w
                ))
                let encoded = DocumentColorPipeline
                    .exportEncodedPremultipliedBGRA8(linear)
                result.append(contentsOf: [
                    encoded.blue, encoded.green,
                    encoded.red, encoded.alpha,
                ])
            }
        }
        return result
    }

    private func expectedRadialBytes(
        output: SparseTileOutputRegion,
        configuration: RadialSymmetryConfiguration,
        canvasSize: PixelSize,
        layout: RadialSectorLayout,
        colors: [PaintTileCoordinate: SIMD4<Float>]
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(output.width * output.height * 4)
        for y in output.minY..<output.maxY {
            for x in output.minX..<output.maxX {
                guard let folded = RadialCoverageOracle.fold(
                    WorldPoint(x: Float(x) + 0.5, y: Float(y) + 0.5),
                    configuration: .radial(configuration),
                    canvasSize: canvasSize
                ) else {
                    result.append(contentsOf: [0, 0, 0, 0])
                    continue
                }
                let sample = SIMD2(folded.x, folded.y)
                    - SIMD2<Float>(repeating: 0.5)
                let lowerX = Int(floor(sample.x))
                let lowerY = Int(floor(sample.y))
                let fraction = SIMD2(
                    sample.x - floor(sample.x),
                    sample.y - floor(sample.y)
                )
                func value(_ x: Int, _ y: Int) -> SIMD4<Float> {
                    let logical = RadialPageCoordinate(
                        x: Int(floor(Double(x) / 256)),
                        y: Int(floor(Double(y) / 256))
                    )
                    guard let page = layout.residentPage(at: logical) else {
                        return .zero
                    }
                    let physical = PaintTileCoordinate(
                        x: page.atlasSlot % layout.atlasColumns,
                        y: page.atlasSlot / layout.atlasColumns
                    )
                    guard let color = colors[physical] else { return .zero }
                    return SIMD4(
                        Float(Float16(color.x)), Float(Float16(color.y)),
                        Float(Float16(color.z)), Float(Float16(color.w))
                    )
                }
                let top = value(lowerX, lowerY)
                    + (value(lowerX + 1, lowerY)
                        - value(lowerX, lowerY)) * fraction.x
                let bottom = value(lowerX, lowerY + 1)
                    + (value(lowerX + 1, lowerY + 1)
                        - value(lowerX, lowerY + 1)) * fraction.x
                let linearValue = top + (bottom - top) * fraction.y
                let linear = try #require(LinearPremultipliedColor(
                    red: linearValue.x,
                    green: linearValue.y,
                    blue: linearValue.z,
                    alpha: linearValue.w
                ))
                let encoded = DocumentColorPipeline
                    .exportEncodedPremultipliedBGRA8(linear)
                result.append(contentsOf: [
                    encoded.blue, encoded.green,
                    encoded.red, encoded.alpha,
                ])
            }
        }
        return result
    }

    private func repeatedPixel(_ pixel: [UInt8], count: Int) -> Data {
        precondition(pixel.count == 4)
        var result = Data()
        result.reserveCapacity(count * 4)
        for _ in 0..<count { result.append(contentsOf: pixel) }
        return result
    }

    private func expectEncodedBytesWithinOne(
        _ actual: Data,
        _ expected: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        let maximum = zip(actual, expected).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
        #expect(maximum <= 1, sourceLocation: sourceLocation)
    }

    private func assertNoRegistryOrRendererDebt(
        _ fixture: RegistryFixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let store = fixture.registry.sharedTileStore.snapshot()
        #expect(store.activeSnapshotTokenCount == 0,
                sourceLocation: sourceLocation)
        #expect(store.aggregateSnapshotReferenceCount == 0,
                sourceLocation: sourceLocation)
        #expect(store.activeLeaseCount == 0, sourceLocation: sourceLocation)
        #expect(store.snapshotMetadataByteCount == 0,
                sourceLocation: sourceLocation)
        #expect(store.snapshotPayloadDebtByteCount == 0,
                sourceLocation: sourceLocation)
        let renderer = await fixture.renderer.snapshot()
        #expect(renderer.inflightCommandCount == 0,
                sourceLocation: sourceLocation)
        #expect(renderer.cpuCache.cachedContentCount == 0,
                sourceLocation: sourceLocation)
        #expect(renderer.cpuCache.activeContentAcquisitionCount == 0,
                sourceLocation: sourceLocation)
        #expect(renderer.cpuCache.pendingRetirementCount == 0,
                sourceLocation: sourceLocation)
        #expect(renderer.gpuCache.preparedContentCount == 0,
                sourceLocation: sourceLocation)
        #expect(renderer.completion.pendingPlanCompletionCount == 0,
                sourceLocation: sourceLocation)
        #expect(renderer.completion.pendingConsumerCompletionCount == 0,
                sourceLocation: sourceLocation)
    }

    @MainActor
    private func makeContextFixture(size: Int) throws -> (
        device: any MTLDevice,
        context: DocumentPaintRenderContext
    )? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        let pixelSize = PixelSize(width: size, height: size)
        return (
            device,
            try DocumentPaintRenderContext(
                device: device,
                commandQueue: queue,
                library: try makeLibrary(device),
                geometry: try DocumentPaintGeometry(
                    documentPixelSize: pixelSize,
                    storagePixelSize: pixelSize,
                    radialLayout: nil
                ),
                initialLayerID: UUID(),
                byteBudget: PaintTileDescriptor.residentByteCount * 4,
                transferByteCapacity:
                    PaintTileDescriptor.residentByteCount * 8,
                maximumRevisionBytes:
                    PaintTileDescriptor.residentByteCount * 8
            )
        )
    }

    private func fill(
        _ texture: any MTLTexture,
        color: SIMD4<Float16>,
        device: any MTLDevice
    ) throws {
        let pixels = Array(
            repeating: color,
            count: texture.width * texture.height
        )
        try fill(texture, pixels: pixels, device: device)
    }

    private func fill(
        _ texture: any MTLTexture,
        pixels: [SIMD4<Float16>],
        device: any MTLDevice
    ) throws {
        #expect(pixels.count == texture.width * texture.height)
        let buffer = try pixels.withUnsafeBytes { raw in
            try #require(device.makeBuffer(
                bytes: raw.baseAddress!,
                length: raw.count,
                options: .storageModeShared
            ))
        }
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(
            from: buffer,
            sourceOffset: 0,
            sourceBytesPerRow: texture.width * 8,
            sourceBytesPerImage: texture.width * texture.height * 8,
            sourceSize: MTLSize(
                width: texture.width,
                height: texture.height,
                depth: 1
            ),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
    }

    private func expectNoCollectionDebt(
        _ snapshot: DocumentPaintRenderContextSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(snapshot.activeSnapshotTokenCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.aggregateSnapshotReferenceCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.activeTileLeaseCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.snapshotMetadataByteCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.snapshotPayloadLiabilityByteCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.stableCollectionRenderer.inflightCommandCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.stableCollectionRenderer.cpuCache
            .activeContentAcquisitionCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.stableCollectionRenderer.cpuCache
            .pendingRetirementCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.stableCollectionRenderer.gpuCache
            .preparedContentCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.stableCollectionRenderer.completion
            .pendingPlanCompletionCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.stableCollectionRenderer.completion
            .pendingConsumerCompletionCount == 0,
                sourceLocation: sourceLocation)
    }

    private func makeLibrary(_ device: any MTLDevice) throws
        -> any MTLLibrary
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
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
}

private final class StableCommittedCaptureRaceBarrier: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let permit = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didReach = false

    lazy var hook: @Sendable (DocumentPaintSurfaceEpochTestingPoint) -> Void = {
        [weak self] point in
        guard point == .stableSnapshotCaptured else { return }
        self?.pauseOnce()
    }

    func waitUntilReached() async throws {
        let reached = reached
        let succeeded = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: reached.wait(timeout: .now() + 5) == .success
                )
            }
        }
        guard succeeded else {
            throw StableCommittedCaptureRaceError.timeout
        }
    }

    func release() { permit.signal() }

    private func pauseOnce() {
        lock.lock()
        let shouldPause = !didReach
        didReach = true
        lock.unlock()
        guard shouldPause else { return }
        reached.signal()
        _ = permit.wait(timeout: .now() + 5)
    }
}

private enum StableCommittedCaptureRaceError: Error { case timeout }

private actor StableCollectionTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
        }
    }

    func open() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}
