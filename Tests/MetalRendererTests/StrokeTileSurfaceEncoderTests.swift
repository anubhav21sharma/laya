import CShaderTypes
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Sparse stroke tile surfaces", .serialized)
struct StrokeTileSurfaceEncoderTests {
    @Test
    func sortedReserveRejectsInvalidInputBeforeStoreMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount * 4
        )
        let surface = TiledRasterSurface(
            store: store,
            layerID: UUID(),
            pixelSize: PixelSize(width: 512, height: 512)
        )
        let before = store.snapshot()
        let unsorted = [
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 0),
        ]

        #expect(throws: PaintTileStoreError.unsortedCoordinate(
            previous: unsorted[0],
            current: unsorted[1]
        )) {
            _ = try surface.reserveSortedUniqueTiles(
                at: unsorted,
                pinReasons: [.inFlight]
            )
        }
        #expect(store.snapshot() == before)
        #expect(throws: PaintTileStoreError.unsortedPinReason(
            previous: .inFlight,
            current: .active
        )) {
            _ = try surface.reserveSortedUniqueTiles(
                at: [unsorted[1], unsorted[0]],
                pinReasons: [.inFlight, .active]
            )
        }
        #expect(store.snapshot() == before)

        let lease = try surface.reserveSortedUniqueTiles(
            at: [unsorted[1], unsorted[0]],
            pinReasons: [.inFlight]
        )
        #expect(lease.bindings.map(\.descriptor.coordinate) == [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ])
        try surface.markDirty(
            lease,
            coordinates: [PaintTileCoordinate(x: 0, y: 0)]
        )
        #expect(surface.dirtyTileCoordinates == [
            PaintTileCoordinate(x: 0, y: 0),
        ])
        try surface.returnLease(lease)
    }

    @Test
    func partitionClipsDeduplicatesAndOrdersTileReferences() throws {
        let records = [
            StrokeTilePartitionInput(
                recordIndex: 0,
                supportBounds: try #require(PixelRect(
                    minX: 250, minY: 250, maxX: 270, maxY: 270
                ))
            ),
            StrokeTilePartitionInput(
                recordIndex: 1,
                supportBounds: try #require(PixelRect(
                    minX: 255, minY: 255, maxX: 257, maxY: 257
                ))
            ),
            StrokeTilePartitionInput(
                recordIndex: 2,
                supportBounds: try #require(PixelRect(
                    minX: -20, minY: -20, maxX: 2, maxY: 2
                ))
            ),
        ]
        var scratch = StrokeTilePartitionScratch(
            maximumRecordCount: 3,
            maximumTileReferenceCount: 9,
            maximumTileCount: 4
        )

        let result = try scratch.partition(
            records,
            pixelSize: PixelSize(width: 512, height: 512),
            role: .authoritative
        )

        #expect(result.map(\.physicalCoordinate) == [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
            PaintTileCoordinate(x: 1, y: 1),
        ])
        #expect(result.map(\.recordRange) == [0..<3, 3..<5, 5..<7, 7..<9])
        #expect(scratch.recordReferences == [0, 1, 2, 0, 1, 0, 1, 0, 1])
    }

    @Test
    func emptyAndFullyClippedPartitionOwnNoTiles() throws {
        var scratch = StrokeTilePartitionScratch(
            maximumRecordCount: 2,
            maximumTileReferenceCount: 2,
            maximumTileCount: 2
        )
        #expect(try scratch.partition(
            [],
            pixelSize: PixelSize(width: 4096, height: 4096),
            role: .prediction
        ).isEmpty)
        #expect(try scratch.partition(
            [StrokeTilePartitionInput(
                recordIndex: 0,
                supportBounds: try #require(PixelRect(
                    minX: -20, minY: -20, maxX: -1, maxY: -1
                ))
            )],
            pixelSize: PixelSize(width: 4096, height: 4096),
            role: .prediction
        ).isEmpty)
    }

    @Test
    func tileReferenceBudgetFailsBeforePublishingPartialRanges() throws {
        var scratch = StrokeTilePartitionScratch(
            maximumRecordCount: 1,
            maximumTileReferenceCount: 3,
            maximumTileCount: 4
        )
        let input = StrokeTilePartitionInput(
            recordIndex: 0,
            supportBounds: try #require(PixelRect(
                minX: 250, minY: 250, maxX: 270, maxY: 270
            ))
        )

        #expect(throws: StrokeTileSurfaceError.tileReferenceBudgetExceeded(
            required: 4,
            maximum: 3
        )) {
            _ = try scratch.partition(
                [input],
                pixelSize: PixelSize(width: 512, height: 512),
                role: .authoritative
            )
        }
        #expect(scratch.ranges.isEmpty)
        #expect(scratch.recordReferences.isEmpty)
    }

    @Test
    func longSupportAndRadialExtremesRespectIndependentBudgets() throws {
        var rectangular = StrokeTilePartitionScratch(
            maximumRecordCount: 1,
            maximumTileReferenceCount: 16,
            maximumTileCount: 16
        )
        let longSupport = StrokeTilePartitionInput(
            recordIndex: 0,
            supportBounds: try #require(PixelRect(
                minX: 0, minY: 0, maxX: 1_024, maxY: 1_024
            ))
        )
        let rectangularRanges = try rectangular.partition(
            [longSupport],
            pixelSize: PixelSize(width: 1_024, height: 1_024),
            role: .authoritative
        )
        #expect(rectangularRanges.count == 16)
        #expect(rectangular.recordReferences == Array(repeating: 0, count: 16))

        for rayCount in [2, SymmetryDescriptorCompiler.maximumRadialRayCount] {
            let layout = try RadialSectorLayout(
                maximumRadius: 700,
                sectorAngleRadians: 2 * .pi / Float(rayCount)
            )
            let inputs = try layout.residentPages.enumerated().map {
                index, page in
                let x = page.coordinate.x * RadialSectorLayout.pageSide
                let y = page.coordinate.y * RadialSectorLayout.pageSide
                return StrokeTilePartitionInput(
                    recordIndex: index,
                    supportBounds: try #require(PixelRect(
                        minX: x, minY: y, maxX: x + 1, maxY: y + 1
                    )),
                    radialPage: page.coordinate
                )
            }
            var radial = StrokeTilePartitionScratch(
                maximumRecordCount: inputs.count,
                maximumTileReferenceCount: inputs.count,
                maximumTileCount: inputs.count
            )
            let ranges = try radial.partition(
                inputs,
                pixelSize: layout.atlasPixelSize,
                role: .authoritative,
                radialLayout: layout
            )
            #expect(ranges.count == layout.residentPages.count)
            #expect(radial.recordReferences.count == inputs.count)
        }
    }

    @Test
    func maximumReferencePartitionUsesBoundedRadixPasses() throws {
        let fullCanvas = try #require(PixelRect(
            minX: 0, minY: 0, maxX: 4_096, maxY: 4_096
        ))
        let inputs = (0..<64).map {
            StrokeTilePartitionInput(
                recordIndex: $0,
                supportBounds: fullCanvas
            )
        }
        var scratch = StrokeTilePartitionScratch(
            maximumRecordCount: inputs.count,
            maximumTileReferenceCount: 16_384,
            maximumTileCount: 256
        )

        let ranges = try scratch.partition(
            inputs,
            pixelSize: PixelSize(width: 4_096, height: 4_096),
            role: .authoritative
        )

        #expect(ranges.count == 256)
        #expect(scratch.recordReferences.count == 16_384)
        #expect(scratch.lastSortPassCount == 24)
        #expect(ranges.first?.physicalCoordinate == .init(x: 0, y: 0))
        #expect(ranges.last?.physicalCoordinate == .init(x: 15, y: 15))
    }

    @Test
    func radialPageMapsToResidentAtlasSlotAndRejectsMissingPage() throws {
        let layout = try RadialSectorLayout(
            maximumRadius: 700,
            sectorAngleRadians: .pi / 6
        )
        let resident = try #require(layout.residentPages.last)
        var scratch = StrokeTilePartitionScratch(
            maximumRecordCount: 1,
            maximumTileReferenceCount: 1,
            maximumTileCount: 1
        )
        let bounds = try #require(PixelRect(
            minX: resident.coordinate.x * 256,
            minY: resident.coordinate.y * 256,
            maxX: resident.coordinate.x * 256 + 1,
            maxY: resident.coordinate.y * 256 + 1
        ))

        let range = try #require(try scratch.partition(
            [StrokeTilePartitionInput(
                recordIndex: 0,
                supportBounds: bounds,
                radialPage: resident.coordinate
            )],
            pixelSize: layout.atlasPixelSize,
            role: .authoritative,
            radialLayout: layout
        ).first)
        #expect(range.physicalCoordinate == PaintTileCoordinate(
            x: resident.atlasSlot % layout.atlasColumns,
            y: resident.atlasSlot / layout.atlasColumns
        ))
        #expect(range.logicalOrigin == SIMD2(
            resident.coordinate.x * 256,
            resident.coordinate.y * 256
        ))

        let missing = RadialPageCoordinate(
            x: layout.pageOrigin.x - 1,
            y: layout.pageOrigin.y
        )
        #expect(throws: StrokeTileSurfaceError.missingRadialPage(missing)) {
            _ = try scratch.partition(
                [StrokeTilePartitionInput(
                    recordIndex: 0,
                    supportBounds: bounds,
                    radialPage: missing
                )],
                pixelSize: layout.atlasPixelSize,
                role: .authoritative,
                radialLayout: layout
            )
        }
        #expect(scratch.ranges.isEmpty)
    }

    @Test
    @MainActor
    func borrowedStoreResourcesAreSparseAndRequireRGBA16Float() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let bytes = PaintTileDescriptor.residentByteCount
        let store = PaintTileStore(device: context.device, byteBudget: bytes * 8)
        let resources = try StrokeTileSurfaceResources(
            device: context.device,
            store: store,
            layerID: context.layerID,
            pixelSize: PixelSize(width: 4096, height: 4096),
            generation: 7,
            maximumRecordCount: 32,
            maximumTileReferenceCount: 128,
            pipeline: context.pipeline,
            namespaceLease: .testing(generation: 7)
        )

        #expect(resources.store === store)
        #expect(resources.pipeline.key.colorPixelFormatRawValue
            == MTLPixelFormat.rgba16Float.rawValue)
        #expect(resources.snapshot.residentTileCount == 0)
        #expect(resources.snapshot.fullCanvasTextureCount == 0)
        #expect(resources.authoritative.pixelSize == PixelSize(
            width: 4096, height: 4096
        ))
        #expect(resources.prediction.pixelSize == PixelSize(
            width: 4096, height: 4096
        ))

        guard let invalid = try await makeContext(pixelFormat: .bgra8Unorm)
        else { return }
        #expect(throws: StrokeTileSurfaceError.invalidPipelinePixelFormat(
            expected: MTLPixelFormat.rgba16Float.rawValue,
            actual: MTLPixelFormat.bgra8Unorm.rawValue
        )) {
            _ = try StrokeTileSurfaceResources(
                device: invalid.device,
                store: store,
                layerID: context.layerID,
                pixelSize: PixelSize(width: 4096, height: 4096),
                generation: 7,
                maximumRecordCount: 32,
                maximumTileReferenceCount: 128,
                pipeline: invalid.pipeline,
                namespaceLease: .testing(generation: 7)
            )
        }
    }

    @Test
    @MainActor
    func encoderPublishesSparseImmutableDeltaAndReturnsExactPins() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: PatternDepositionMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let seam = try projectedRecord(
            ordinal: 0,
            bounds: try #require(PixelRect(
                minX: 250, minY: 250, maxX: 270, maxY: 270
            ))
        )

        let first = try #require(try await encoder.encode(
            generation: 7,
            records: [seam],
            layer: .authoritative,
            allocationProbe: nil
        ))
        #expect(first.tiledBindings.map(\.descriptor.coordinate) == [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
            PaintTileCoordinate(x: 1, y: 1),
        ])
        #expect(first.newBindingCount == 4)
        #expect(first.authoritativeInstanceCount == 1)
        #expect(resources.snapshot.activeLeaseCount == 1)
        let firstBindings = first.tiledBindings
        let untouchedBefore = firstBindings[3]
        let untouchedTextureIdentity = ObjectIdentifier(
            untouchedBefore.texture as AnyObject
        )
        try encoder.acknowledge(first)
        #expect(resources.snapshot.activeLeaseCount == 0)
        #expect(resources.store.snapshot().entries.allSatisfy {
            $0.pinCounts[.active] == 1
        })

        let sameTile = try projectedRecord(
            ordinal: 1,
            bounds: try #require(PixelRect(
                minX: 8, minY: 8, maxX: 12, maxY: 12
            ))
        )
        let second = try #require(try await encoder.encode(
            generation: 7,
            records: [sameTile],
            layer: .authoritative,
            allocationProbe: nil
        ))
        #expect(second.tiledBindings.count == 1)
        #expect(second.newBindingCount == 0)
        #expect(second.bindingDeltaCoordinates == [
            PaintTileCoordinate(x: 0, y: 0),
        ])
        let wrongToken = StrokePreparedSurfaceLease(
            generation: second.generation,
            token: second.token + 1,
            layer: second.layer,
            authoritativeInstanceCount: second.authoritativeInstanceCount,
            predictedInstanceCount: second.predictedInstanceCount,
            clearedAuthoritativeSurface:
                second.clearedAuthoritativeSurface,
            clearedPredictionSurface: second.clearedPredictionSurface,
            encodingRanOnMainThread: second.encodingRanOnMainThread,
            backing: second.backing,
            newBindingCount: second.newBindingCount
        )
        #expect(throws: StrokeTileSurfaceError.staleLease) {
            try encoder.acknowledge(wrongToken)
        }
        let wrongGeneration = StrokePreparedSurfaceLease(
            generation: second.generation + 1,
            token: second.token,
            layer: second.layer,
            authoritativeInstanceCount: second.authoritativeInstanceCount,
            predictedInstanceCount: second.predictedInstanceCount,
            clearedAuthoritativeSurface:
                second.clearedAuthoritativeSurface,
            clearedPredictionSurface: second.clearedPredictionSurface,
            encodingRanOnMainThread: second.encodingRanOnMainThread,
            backing: second.backing,
            newBindingCount: second.newBindingCount
        )
        #expect(throws: StrokeTileSurfaceError.staleLease) {
            try encoder.acknowledge(wrongGeneration)
        }
        let wrongLayer = StrokePreparedSurfaceLease(
            generation: second.generation,
            token: second.token,
            layer: .prediction,
            authoritativeInstanceCount: second.authoritativeInstanceCount,
            predictedInstanceCount: second.predictedInstanceCount,
            clearedAuthoritativeSurface:
                second.clearedAuthoritativeSurface,
            clearedPredictionSurface: second.clearedPredictionSurface,
            encodingRanOnMainThread: second.encodingRanOnMainThread,
            backing: second.backing,
            newBindingCount: second.newBindingCount
        )
        #expect(throws: StrokeTileSurfaceError.staleLease) {
            try encoder.acknowledge(wrongLayer)
        }
        #expect(encoder.snapshot.hasOutstandingLease)
        guard case let .tiled(secondBacking) = second.backing else {
            Issue.record("Expected tiled lease backing")
            return
        }
        #expect(secondBacking.authoritativeStoreLease?.bindings.count == 1)
        #expect(ObjectIdentifier(
            try #require(
                secondBacking.authoritativeStoreLease?.bindings.first
            ).texture as AnyObject
        ) == ObjectIdentifier(
            try #require(second.tiledBindings.first).texture as AnyObject
        ))
        let wholeVisible = secondBacking.wholeVisibleBindings(
            role: .authoritative
        )
        #expect(wholeVisible.map(\.descriptor.coordinate) == [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
            PaintTileCoordinate(x: 1, y: 1),
        ])
        let untouchedAfter = wholeVisible[3]
        #expect(ObjectIdentifier(untouchedAfter.texture as AnyObject)
            == untouchedTextureIdentity)
        #expect(encoder.snapshot.bindingChunkCount == 4)
        let forgedBacking = StrokeTileSurfaceLeaseBacking(
            resources: secondBacking.resources,
            authoritativeStoreLease: nil,
            predictionStoreLease: nil,
            publicationSlot: StrokeTilePublicationSlot(capacity: 1),
            publicationVersion: 0,
            layerID: secondBacking.layerID
        )
        let forgedLease = StrokePreparedSurfaceLease(
            generation: second.generation,
            token: second.token,
            layer: second.layer,
            authoritativeInstanceCount: second.authoritativeInstanceCount,
            predictedInstanceCount: second.predictedInstanceCount,
            clearedAuthoritativeSurface:
                second.clearedAuthoritativeSurface,
            clearedPredictionSurface: second.clearedPredictionSurface,
            encodingRanOnMainThread: second.encodingRanOnMainThread,
            backing: .tiled(forgedBacking),
            newBindingCount: second.newBindingCount
        )
        #expect(throws: StrokeTileSurfaceError.staleLease) {
            try encoder.acknowledge(forgedLease)
        }
        #expect(resources.snapshot.activeLeaseCount == 1)
        #expect(encoder.snapshot.hasOutstandingLease)
        try encoder.acknowledge(second)
        #expect(throws: StrokeTileSurfaceError.staleLease) {
            try encoder.acknowledge(second)
        }
    }

    @Test
    @MainActor
    func sameCoordinatePublishesIntoANewImmutableChunkSlot() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: visibleMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let record = try recordInTile(
            ordinal: 1,
            coordinate: .init(x: 0, y: 0),
            predicted: false
        )
        let first = try #require(try await encoder.encode(
            generation: 7,
            records: [record],
            layer: .authoritative,
            allocationProbe: nil
        ))
        guard case let .tiled(firstBacking) = first.backing else { return }
        let firstSlot = try #require(
            firstBacking.debugPublishedChunkIndices.first
        )
        try encoder.acknowledge(first)

        let second = try #require(try await encoder.encode(
            generation: 7,
            records: [try recordInTile(
                ordinal: 2,
                coordinate: .init(x: 0, y: 0),
                predicted: false
            )],
            layer: .authoritative,
            allocationProbe: nil
        ))
        guard case let .tiled(secondBacking) = second.backing else { return }
        let secondSlot = try #require(
            secondBacking.debugPublishedChunkIndices.first
        )
        #expect(secondSlot != firstSlot)
        try encoder.acknowledge(second)
        try encoder.cancel(frameDisposition: .unpublished)
    }

    @Test
    @MainActor
    func predictionReplacementPublishesOnlyAfterSuccessAndEmptyClearNeedsAck() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: PatternDepositionMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        encoder.beginPredictionReplacement()
        let predicted = try projectedRecord(
            ordinal: 40,
            bounds: try #require(PixelRect(
                minX: 20, minY: 20, maxX: 24, maxY: 24
            )),
            predicted: true
        )
        let visible = try #require(try await encoder.encode(
            generation: 7,
            records: [predicted],
            layer: .prediction,
            allocationProbe: nil
        ))
        #expect(visible.tiledBindings.count == 1)
        #expect(visible.clearedPredictionSurface)
        try encoder.acknowledge(visible)
        #expect(encoder.snapshot.predictionVisibleTileCount == 1)

        encoder.beginPredictionReplacement()
        let clear = try #require(try await encoder.encode(
            generation: 7,
            records: [],
            layer: .prediction,
            allocationProbe: nil
        ))
        #expect(clear.predictedInstanceCount == 0)
        #expect(clear.clearedPredictionSurface)
        #expect(clear.tiledBindings.isEmpty)
        #expect(clear.bindingDeltaCoordinates == [
            PaintTileCoordinate(x: 0, y: 0),
        ])
        #expect(encoder.snapshot.predictionVisibleTileCount == 0)
        try encoder.acknowledge(clear)
        #expect(resources.snapshot.activeLeaseCount == 0)
        #expect(resources.snapshot.residentTileCount == 0)
        #expect(resources.store.snapshot().entries.isEmpty)
        #expect(encoder.snapshot.bindingChunkCount == 0)
    }

    @Test
    @MainActor
    func predictionReplacementMatrixClearsOnlyPriorFootprintAndNeverChangesActualBytes()
        async throws
    {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: visibleMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let actual = try #require(try await encoder.encode(
            generation: 7,
            records: [try recordInTile(
                ordinal: 1,
                coordinate: .init(x: 0, y: 0),
                predicted: false
            )],
            layer: .authoritative,
            allocationProbe: nil
        ))
        try encoder.acknowledge(actual)
        let authoritativeBefore = try readTile(
            resources.authoritative,
            coordinate: .init(x: 0, y: 0),
            device: context.device
        )
        #expect(authoritativeBefore.contains { $0 != 0 })

        var ordinal: UInt64 = 100
        func predictionRecords(
            _ coordinates: [PaintTileCoordinate]
        ) throws -> [StrokePreparedProjectedRecord] {
            try coordinates.map { coordinate in
                defer { ordinal += 1 }
                return try recordInTile(
                    ordinal: ordinal,
                    coordinate: coordinate,
                    predicted: true
                )
            }
        }
        func replace(
            _ coordinates: [PaintTileCoordinate]
        ) async throws -> StrokePreparedSurfaceLease {
            encoder.beginPredictionReplacement()
            return try #require(try await encoder.encode(
                generation: 7,
                records: try predictionRecords(coordinates),
                layer: .prediction,
                allocationProbe: nil
            ))
        }

        let c00 = PaintTileCoordinate(x: 0, y: 0)
        let c10 = PaintTileCoordinate(x: 1, y: 0)
        let c01 = PaintTileCoordinate(x: 0, y: 1)
        let c11 = PaintTileCoordinate(x: 1, y: 1)

        var lease = try await replace([c00, c10])
        #expect(lease.bindingDeltaCoordinates == [c00, c10])
        try encoder.acknowledge(lease)
        #expect(encoder.snapshot.predictionVisibleTileCount == 2)

        lease = try await replace([c10])
        #expect(lease.bindingDeltaCoordinates == [c00, c10])
        try encoder.acknowledge(lease)
        #expect(encoder.snapshot.predictionVisibleTileCount == 1)

        lease = try await replace([c00, c10, c01, c11])
        #expect(lease.bindingDeltaCoordinates == [c00, c10, c01, c11])
        try encoder.acknowledge(lease)
        #expect(encoder.snapshot.predictionVisibleTileCount == 4)

        lease = try await replace([c10, c11])
        #expect(lease.bindingDeltaCoordinates == [c00, c10, c01, c11])
        try encoder.acknowledge(lease)
        #expect(encoder.snapshot.predictionVisibleTileCount == 2)

        lease = try await replace([c00])
        #expect(lease.bindingDeltaCoordinates == [c00, c10, c11])
        try encoder.acknowledge(lease)
        #expect(encoder.snapshot.predictionVisibleTileCount == 1)

        lease = try #require(try await encoder.encode(
            generation: 7,
            records: try predictionRecords([c10]),
            layer: .prediction,
            allocationProbe: nil
        ))
        #expect(!lease.clearedPredictionSurface)
        #expect(lease.bindingDeltaCoordinates == [c10])
        try encoder.acknowledge(lease)
        #expect(encoder.snapshot.predictionVisibleTileCount == 2)

        lease = try await replace([])
        #expect(lease.bindingDeltaCoordinates == [c00, c10])
        try encoder.acknowledge(lease)
        #expect(encoder.snapshot.predictionVisibleTileCount == 0)

        let authoritativeAfter = try readTile(
            resources.authoritative,
            coordinate: c00,
            device: context.device
        )
        #expect(authoritativeAfter == authoritativeBefore)
    }

    @Test
    @MainActor
    func commandFailurePublishesNothingAndEncoderCanBeReconfigured() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: PatternDepositionMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: true
            ),
            generation: 7
        )
        let before = resources.store.snapshot()
        let record = try projectedRecord(
            ordinal: 0,
            bounds: try #require(PixelRect(
                minX: 8, minY: 8, maxX: 20, maxY: 20
            ))
        )

        await #expect(throws: StrokeTileSurfaceError.commandFailed(
            "sparse stroke command failed"
        )) {
            _ = try await encoder.encode(
                generation: 7,
                records: [record],
                layer: .authoritative,
                allocationProbe: nil
            )
        }
        let afterFailure = resources.store.snapshot()
        #expect(afterFailure.entries == before.entries)
        #expect(afterFailure.activeLeaseCount == before.activeLeaseCount)
        #expect(afterFailure.residentByteCount == before.residentByteCount)
        #expect(afterFailure.backingByteCount == before.backingByteCount)
        #expect(encoder.snapshot.authoritativeVisibleTileCount == 0)
        #expect(!encoder.snapshot.hasOutstandingLease)

        let replacement = try makeResources(context: context)
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: replacement,
                materialUniforms: PatternDepositionMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let recovered = try #require(try await encoder.encode(
            generation: 7,
            records: [record],
            layer: .authoritative,
            allocationProbe: nil
        ))
        try encoder.acknowledge(recovered)
    }

    @Test
    @MainActor
    func metalViewportDepositsOneGlobalDabAcrossBothSidesOfATileSeam()
        async throws
    {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: visibleMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let record = try projectedRecord(
            ordinal: 1,
            bounds: try #require(PixelRect(
                minX: 250, minY: 120, maxX: 263, maxY: 137
            )),
            position: SIMD2(256, 128)
        )
        let lease = try #require(try await encoder.encode(
            generation: 7,
            records: [record],
            layer: .authoritative,
            allocationProbe: nil
        ))
        let bindings = lease.tiledBindings
        #expect(bindings.map(\.descriptor.coordinate) == [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ])
        let left = try download(bindings[0].texture, device: context.device)
        let right = try download(bindings[1].texture, device: context.device)
        #expect(regionContainsNonzero(
            left, x: 250..<256, y: 120..<137
        ))
        #expect(regionContainsNonzero(
            right, x: 0..<7, y: 120..<137
        ))
        try encoder.acknowledge(lease)
    }

    @Test
    @MainActor
    func radialMetalViewportMapsLogicalPagePixelsIntoCompactAtlasSlot()
        async throws
    {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 700,
            sectorAngleRadians: .pi / 6
        )
        let page = try #require(layout.residentPages.first { page in
            let physical = PaintTileCoordinate(
                x: page.atlasSlot % layout.atlasColumns,
                y: page.atlasSlot / layout.atlasColumns
            )
            return physical.x != page.coordinate.x
                || physical.y != page.coordinate.y
        })
        let resources = try StrokeTileSurfaceResources(
            device: context.device,
            store: PaintTileStore(
                device: context.device,
                byteBudget: PaintTileDescriptor.residentByteCount * 16
            ),
            layerID: context.layerID,
            pixelSize: layout.atlasPixelSize,
            generation: 7,
            maximumRecordCount: 32,
            maximumTileReferenceCount: 128,
            pipeline: context.pipeline,
            namespaceLease: .testing(generation: 7)
        )
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: visibleMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 1_024),
                radialLayout: layout,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let logicalOrigin = SIMD2(
            page.coordinate.x * PaintTileDescriptor.side,
            page.coordinate.y * PaintTileDescriptor.side
        )
        let center = SIMD2<Float>(
            Float(logicalOrigin.x + 128),
            Float(logicalOrigin.y + 128)
        )
        let record = try projectedRecord(
            ordinal: 1,
            bounds: try #require(PixelRect(
                minX: logicalOrigin.x + 120,
                minY: logicalOrigin.y + 120,
                maxX: logicalOrigin.x + 137,
                maxY: logicalOrigin.y + 137
            )),
            position: center,
            radialPage: page.coordinate
        )
        let lease = try #require(try await encoder.encode(
            generation: 7,
            records: [record],
            layer: .authoritative,
            allocationProbe: nil
        ))
        let binding = try #require(lease.tiledBindings.first)
        #expect(binding.descriptor.coordinate == PaintTileCoordinate(
            x: page.atlasSlot % layout.atlasColumns,
            y: page.atlasSlot / layout.atlasColumns
        ))
        let bytes = try download(binding.texture, device: context.device)
        #expect(regionContainsNonzero(
            bytes, x: 120..<137, y: 120..<137
        ))
        try encoder.acknowledge(lease)
    }

    @Test
    @MainActor
    func edgeTileScissorKeepsPaddingOutsideLogicalCanvasClear()
        async throws
    {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try StrokeTileSurfaceResources(
            device: context.device,
            store: PaintTileStore(
                device: context.device,
                byteBudget: PaintTileDescriptor.residentByteCount * 4
            ),
            layerID: context.layerID,
            pixelSize: PixelSize(width: 300, height: 300),
            generation: 7,
            maximumRecordCount: 32,
            maximumTileReferenceCount: 128,
            pipeline: context.pipeline,
            namespaceLease: .testing(generation: 7)
        )
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: visibleMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 300),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let record = try projectedRecord(
            ordinal: 1,
            bounds: try #require(PixelRect(
                minX: 280, minY: 280, maxX: 310, maxY: 310
            )),
            position: SIMD2(292, 292)
        )
        let lease = try #require(try await encoder.encode(
            generation: 7,
            records: [record],
            layer: .authoritative,
            allocationProbe: nil
        ))
        let binding = try #require(lease.tiledBindings.first)
        #expect(binding.descriptor.coordinate == .init(x: 1, y: 1))
        #expect(binding.descriptor.logicalBounds.width == 44)
        #expect(binding.descriptor.logicalBounds.height == 44)
        let bytes = try download(binding.texture, device: context.device)
        #expect(regionContainsNonzero(bytes, x: 24..<44, y: 24..<44))
        #expect(regionIsAllZero(bytes, x: 44..<256, y: 0..<256))
        #expect(regionIsAllZero(bytes, x: 0..<44, y: 44..<256))
        try encoder.acknowledge(lease)
    }

    @Test
    @MainActor
    func commandFailureCannotMutateAnExistingVisibleTile() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        let normal = StrokeTileEncodingConfiguration(
            resources: resources,
            materialUniforms: visibleMaterialUniforms(),
            primaryShape: nil,
            secondaryShape: nil,
            primaryGrain: nil,
            secondaryGrain: nil,
            frameUniforms: frameUniforms(side: 512),
            radialLayout: nil,
            forceCommandFailure: false
        )
        try encoder.configure(normal, generation: 7)
        let bounds = try #require(PixelRect(
            minX: 8, minY: 8, maxX: 24, maxY: 24
        ))
        let first = try #require(try await encoder.encode(
            generation: 7,
            records: [try projectedRecord(ordinal: 0, bounds: bounds)],
            layer: .authoritative,
            allocationProbe: nil
        ))
        let texture = try #require(first.tiledBindings.first?.texture)
        let before = try download(texture, device: context.device)
        try encoder.acknowledge(first)

        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: visibleMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: true
            ),
            generation: 7
        )
        let red = try #require(InkColor(
            red: 1, green: 0, blue: 0, alpha: 1
        ))
        await #expect(throws: StrokeTileSurfaceError.commandFailed(
            "sparse stroke command failed"
        )) {
            _ = try await encoder.encode(
                generation: 7,
                records: [try projectedRecord(
                    ordinal: 1,
                    bounds: bounds,
                    color: red
                )],
                layer: .authoritative,
                allocationProbe: nil
            )
        }

        let inspection = try resources.authoritative.reserveSortedUniqueTiles(
            at: [PaintTileCoordinate(x: 0, y: 0)],
            pinReasons: [.inFlight]
        )
        let after = try download(
            try #require(inspection.bindings.first?.texture),
            device: context.device
        )
        try resources.authoritative.returnLease(inspection)
        #expect(after == before)
    }

    @Test
    @MainActor
    func everyPreparationFailureSeamIsAtomicAndEncoderRemainsReusable()
        async throws
    {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let bounds = try #require(PixelRect(
            minX: 8, minY: 8, maxX: 24, maxY: 24
        ))
        let record = try projectedRecord(ordinal: 1, bounds: bounds)
        for seam in StrokeTileFailureInjectionSeam.allCases {
            let resources = try makeResources(context: context)
            let encoder = StrokeTileSurfaceEncoder()
            try encoder.configure(
                StrokeTileEncodingConfiguration(
                    resources: resources,
                    materialUniforms: visibleMaterialUniforms(),
                    primaryShape: nil,
                    secondaryShape: nil,
                    primaryGrain: nil,
                    secondaryGrain: nil,
                    frameUniforms: frameUniforms(side: 512),
                    radialLayout: nil,
                    forceCommandFailure: false,
                    failureInjection: StrokeTileFailureInjection(seam: seam)
                ),
                generation: 7
            )
            let before = resources.store.snapshot()
            await #expect(throws: StrokeTileSurfaceError.injectedFailure(seam)) {
                _ = try await encoder.encode(
                    generation: 7,
                    records: [record],
                    layer: .authoritative,
                    allocationProbe: nil
                )
            }
            let after = resources.store.snapshot()
            #expect(after.entries == before.entries)
            #expect(after.activeLeaseCount == 0)
            #expect(!encoder.snapshot.hasOutstandingLease)
            #expect(encoder.snapshot.authoritativeVisibleTileCount == 0)

            try encoder.configure(
                StrokeTileEncodingConfiguration(
                    resources: resources,
                    materialUniforms: visibleMaterialUniforms(),
                    primaryShape: nil,
                    secondaryShape: nil,
                    primaryGrain: nil,
                    secondaryGrain: nil,
                    frameUniforms: frameUniforms(side: 512),
                    radialLayout: nil,
                    forceCommandFailure: false
                ),
                generation: 7
            )
            let recovered = try #require(try await encoder.encode(
                generation: 7,
                records: [record],
                layer: .authoritative,
                allocationProbe: nil
            ))
            try encoder.acknowledge(recovered)
        }
    }

    @Test
    @MainActor
    func everyColdTileAllocationFailureIsAtomic() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let seam = try projectedRecord(
            ordinal: 1,
            bounds: try #require(PixelRect(
                minX: 250, minY: 250, maxX: 270, maxY: 270
            )),
            position: SIMD2(256, 256)
        )
        for reserveIndex in 0..<4 {
            let resources = try makeResources(context: context)
            let encoder = StrokeTileSurfaceEncoder()
            try encoder.configure(
                StrokeTileEncodingConfiguration(
                    resources: resources,
                    materialUniforms: visibleMaterialUniforms(),
                    primaryShape: nil,
                    secondaryShape: nil,
                    primaryGrain: nil,
                    secondaryGrain: nil,
                    frameUniforms: frameUniforms(side: 512),
                    radialLayout: nil,
                    forceCommandFailure: false,
                    tileAllocationFailureInjection:
                        PaintTileAllocationFailureInjection(
                            failingAtReserveIndex: reserveIndex
                        )
                ),
                generation: 7
            )
            let before = resources.store.snapshot()
            await #expect(throws: StrokeTileSurfaceError.store(
                .injectedAllocationFailure(reserveIndex: reserveIndex)
            )) {
                _ = try await encoder.encode(
                    generation: 7,
                    records: [seam],
                    layer: .authoritative,
                    allocationProbe: nil
                )
            }
            let after = resources.store.snapshot()
            #expect(after.entries == before.entries)
            #expect(after.activeLeaseCount == 0)
            #expect(!encoder.snapshot.hasOutstandingLease)
        }
    }

    @Test
    @MainActor
    func provisionalTextureBudgetFailsAtomicallyThenAllowsSmallerReuse()
        async throws
    {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let bytes = PaintTileDescriptor.residentByteCount
        let store = PaintTileStore(
            device: context.device,
            byteBudget: bytes * 4,
            transferByteCapacity: bytes * 5
        )
        let resources = try StrokeTileSurfaceResources(
            device: context.device,
            store: store,
            layerID: context.layerID,
            pixelSize: PixelSize(width: 512, height: 512),
            generation: 7,
            maximumRecordCount: 32,
            maximumTileReferenceCount: 128,
            pipeline: context.pipeline,
            namespaceLease: .testing(generation: 7)
        )
        let encoder = StrokeTileSurfaceEncoder()
        let configuration = StrokeTileEncodingConfiguration(
            resources: resources,
            materialUniforms: visibleMaterialUniforms(),
            primaryShape: nil,
            secondaryShape: nil,
            primaryGrain: nil,
            secondaryGrain: nil,
            frameUniforms: frameUniforms(side: 512),
            radialLayout: nil,
            forceCommandFailure: false
        )
        let warmCoordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
            PaintTileCoordinate(x: 0, y: 1),
            PaintTileCoordinate(x: 1, y: 1),
        ]
        for coordinate in warmCoordinates {
            let warm = try resources.authoritative.reserveSortedUniqueTiles(
                at: [coordinate],
                pinReasons: [.inFlight]
            )
            try resources.authoritative.markDirty(warm)
            try resources.authoritative.returnLease(warm)
        }
        try encoder.configure(configuration, generation: 7)
        let seam = try projectedRecord(
            ordinal: 1,
            bounds: try #require(PixelRect(
                minX: 250, minY: 250, maxX: 270, maxY: 270
            )),
            position: SIMD2(256, 256)
        )
        await #expect(throws: StrokeTileSurfaceError.store(
            .transferCapacityExceeded(
                requiredBytes: bytes * 8,
                capacityBytes: bytes * 5,
                residentBytes: bytes * 4,
                allocationBytes: bytes * 4,
                stagingBytes: 0
            )
        )) {
            _ = try await encoder.encode(
                generation: 7,
                records: [seam],
                layer: .authoritative,
                allocationProbe: nil
            )
        }
        #expect(store.snapshot().entries.count == 4)
        #expect(store.snapshot().activeLeaseCount == 0)

        try encoder.configure(configuration, generation: 7)
        let recovered = try #require(try await encoder.encode(
            generation: 7,
            records: [try recordInTile(
                ordinal: 2,
                coordinate: .init(x: 0, y: 0),
                predicted: false
            )],
            layer: .authoritative,
            allocationProbe: nil
        ))
        try encoder.acknowledge(recovered)
        #expect(store.snapshot().activeLeaseCount == 0)
    }

    @Test
    @MainActor
    func sharedStoreProvisionalReservationsUseOneCheckedGlobalBudget()
        async throws
    {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let bytes = PaintTileDescriptor.residentByteCount
        let store = PaintTileStore(
            device: context.device,
            byteBudget: bytes * 2,
            transferByteCapacity: bytes * 3
        )
        let firstSurface = TiledRasterSurface(
            store: store,
            layerID: context.layerID,
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let secondSurface = TiledRasterSurface(
            store: store,
            layerID: context.layerID,
            pixelSize: PixelSize(width: 256, height: 256)
        )
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        for surface in [firstSurface, secondSurface] {
            let warm = try surface.reserveSortedUniqueTiles(
                at: [coordinate],
                pinReasons: [.inFlight]
            )
            try surface.markDirty(warm)
            try surface.returnLease(warm)
        }
        let firstLeaseWorkspace = PaintTileStrokeLeaseWorkspace(
            maximumBindingCount: 1
        )
        let secondLeaseWorkspace = PaintTileStrokeLeaseWorkspace(
            maximumBindingCount: 1
        )
        let firstLease = try firstSurface.reserveSortedUniqueStrokeTiles(
            at: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: firstLeaseWorkspace
        )
        let secondLease = try secondSurface.reserveSortedUniqueStrokeTiles(
            at: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: secondLeaseWorkspace
        )
        let firstProvisionalWorkspace = PaintTileProvisionalWorkspace(
            maximumBindingCount: 1
        )
        let secondProvisionalWorkspace = PaintTileProvisionalWorkspace(
            maximumBindingCount: 1
        )
        let firstReservation = try firstSurface.makeProvisionalBindings(
            for: firstLease,
            coordinates: [coordinate],
            workspace: firstProvisionalWorkspace
        )
        #expect(store.snapshot().provisionalByteCount == bytes)
        #expect(throws: PaintTileStoreError.transferCapacityExceeded(
            requiredBytes: bytes * 4,
            capacityBytes: bytes * 3,
            residentBytes: bytes * 2,
            allocationBytes: bytes,
            stagingBytes: bytes
        )) {
            _ = try secondSurface.makeProvisionalBindings(
                for: secondLease,
                coordinates: [coordinate],
                workspace: secondProvisionalWorkspace
            )
        }
        try firstSurface.cancelProvisionalBindings(firstReservation)
        #expect(store.snapshot().provisionalByteCount == 0)
        let recovered = try secondSurface.makeProvisionalBindings(
            for: secondLease,
            coordinates: [coordinate],
            workspace: secondProvisionalWorkspace
        )
        try secondSurface.cancelProvisionalBindings(recovered)
        try firstSurface.returnLease(firstLease)
        try secondSurface.returnLease(secondLease)
        #expect(store.snapshot().provisionalReservationCount == 0)
        #expect(store.snapshot().provisionalByteCount == 0)
    }

    @Test
    @MainActor
    func predictionShrinkAndFinalCancelReleaseAllRetainedTextureReferences()
        async throws
    {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: visibleMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        encoder.beginPredictionReplacement()
        let wide = try #require(try await encoder.encode(
            generation: 7,
            records: try [
                PaintTileCoordinate(x: 0, y: 0),
                PaintTileCoordinate(x: 1, y: 0),
                PaintTileCoordinate(x: 0, y: 1),
                PaintTileCoordinate(x: 1, y: 1),
            ].enumerated().map { index, coordinate in
                try recordInTile(
                    ordinal: UInt64(index),
                    coordinate: coordinate,
                    predicted: true
                )
            },
            layer: .prediction,
            allocationProbe: nil
        ))
        try encoder.acknowledge(wide)
        #expect(resources.store.snapshot().entries.count == 4)
        #expect(resources.store.snapshot().entries.allSatisfy {
            $0.pinCounts[.active] == 1
        })

        encoder.beginPredictionReplacement()
        let narrow = try #require(try await encoder.encode(
            generation: 7,
            records: [try recordInTile(
                ordinal: 10,
                coordinate: .init(x: 0, y: 0),
                predicted: true
            )],
            layer: .prediction,
            allocationProbe: nil
        ))
        try encoder.acknowledge(narrow)
        #expect(resources.store.snapshot().entries.count == 1)
        #expect(resources.store.snapshot().provisionalByteCount == 0)
        #expect(encoder.snapshot.retainedLeaseWorkspaceBindingCount == 0)
        #expect(encoder.snapshot.retainedProvisionalBindingCount == 0)

        try encoder.cancel(frameDisposition: .unpublished)
        #expect(resources.store.snapshot().entries.isEmpty)
        #expect(resources.store.snapshot().provisionalByteCount == 0)
        #expect(encoder.snapshot.bindingChunkCount == 0)
        #expect(encoder.snapshot.retainedLeaseWorkspaceBindingCount == 0)
        #expect(encoder.snapshot.retainedProvisionalBindingCount == 0)
    }

    @Test
    @MainActor
    func cancelDefersRetirementUntilMainReturnsPublishedLease() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: PatternDepositionMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let record = try projectedRecord(
            ordinal: 0,
            bounds: try #require(PixelRect(
                minX: 8, minY: 8, maxX: 20, maxY: 20
            ))
        )
        let lease = try #require(try await encoder.encode(
            generation: 7,
            records: [record],
            layer: .authoritative,
            allocationProbe: nil
        ))

        try encoder.cancel(frameDisposition: .mainOwnsLease)
        #expect(resources.store.snapshot().activeLeaseCount == 1)
        #expect(encoder.snapshot.hasOutstandingLease)
        try encoder.acknowledge(lease)
        #expect(resources.store.snapshot().activeLeaseCount == 0)
        #expect(resources.store.snapshot().entries.isEmpty)
        #expect(!encoder.snapshot.hasOutstandingLease)
    }

    @Test
    @MainActor
    func unpublishedCancellationReturnsLeaseWithoutMainAcknowledgement() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let resources = try makeResources(context: context)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: PatternDepositionMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let record = try projectedRecord(
            ordinal: 0,
            bounds: try #require(PixelRect(
                minX: 8, minY: 8, maxX: 20, maxY: 20
            ))
        )
        _ = try #require(try await encoder.encode(
            generation: 7,
            records: [record],
            layer: .authoritative,
            allocationProbe: nil
        ))

        try encoder.cancel(frameDisposition: .unpublished)

        #expect(resources.store.snapshot().activeLeaseCount == 0)
        #expect(resources.store.snapshot().entries.isEmpty)
        #expect(!encoder.snapshot.hasOutstandingLease)
    }

    @Test
    @MainActor
    func injectedNamespaceIsDistinctAndRetiresExactlyOnceAfterFinalAck()
        async throws
    {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let recorder = StrokeNamespaceRetirementRecorder()
        let authoritativeID = UUID()
        let predictionID = UUID()
        let resources = try StrokeTileSurfaceResources(
            device: context.device,
            store: PaintTileStore(
                device: context.device,
                byteBudget: PaintTileDescriptor.residentByteCount * 4
            ),
            layerID: context.layerID,
            pixelSize: PixelSize(width: 512, height: 512),
            generation: 7,
            maximumRecordCount: 32,
            maximumTileReferenceCount: 128,
            pipeline: context.pipeline,
            namespaceLease: StrokeTileSurfaceNamespaceLease(
                authoritativeSurfaceID: authoritativeID,
                predictionSurfaceID: predictionID,
                retirementToken: 0xD5,
                onRetired: recorder.record
            )
        )
        #expect(resources.authoritative.surfaceID == authoritativeID)
        #expect(resources.prediction.surfaceID == predictionID)
        let encoder = StrokeTileSurfaceEncoder()
        try encoder.configure(
            StrokeTileEncodingConfiguration(
                resources: resources,
                materialUniforms: visibleMaterialUniforms(),
                primaryShape: nil,
                secondaryShape: nil,
                primaryGrain: nil,
                secondaryGrain: nil,
                frameUniforms: frameUniforms(side: 512),
                radialLayout: nil,
                forceCommandFailure: false
            ),
            generation: 7
        )
        let bounds = try #require(PixelRect(
            minX: 8, minY: 8, maxX: 24, maxY: 24
        ))
        let lease = try #require(try await encoder.encode(
            generation: 7,
            records: [try projectedRecord(
                ordinal: 1,
                bounds: bounds
            )],
            layer: .authoritative,
            allocationProbe: nil
        ))

        try encoder.cancel(frameDisposition: .mainOwnsLease)
        #expect(recorder.tokens.isEmpty)
        try encoder.acknowledge(lease)
        #expect(recorder.tokens == [0xD5])
        try encoder.cancel(frameDisposition: .unpublished)
        #expect(recorder.tokens == [0xD5])
        #expect(resources.store.snapshot().entries.isEmpty)
    }

    @Test
    @MainActor
    func duplicateInjectedSurfaceNamespaceIsRejected() async throws {
        guard let context = try await makeContext(pixelFormat: .rgba16Float)
        else { return }
        let duplicate = UUID()
        #expect(throws: StrokeTileSurfaceError.duplicateSurfaceNamespace(
            duplicate
        )) {
            _ = try StrokeTileSurfaceResources(
                device: context.device,
                store: PaintTileStore(
                    device: context.device,
                    byteBudget: PaintTileDescriptor.residentByteCount * 4
                ),
                layerID: context.layerID,
                pixelSize: PixelSize(width: 512, height: 512),
                generation: 7,
                maximumRecordCount: 32,
                maximumTileReferenceCount: 128,
                pipeline: context.pipeline,
                namespaceLease: StrokeTileSurfaceNamespaceLease(
                    authoritativeSurfaceID: duplicate,
                    predictionSurfaceID: duplicate,
                    retirementToken: 1,
                    onRetired: { _ in }
                )
            )
        }
    }

    @MainActor
    private func makeContext(
        pixelFormat: MTLPixelFormat
    ) async throws -> (
        device: any MTLDevice,
        pipeline: DepositionPipelineBinding,
        layerID: UUID
    )? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
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
        let library = try await device.makeLibrary(
            source: shader.replacingOccurrences(
                of: "#include \"ShaderTypes.h\"",
                with: header
            ),
            options: nil
        )
        let key = DepositionPipelineKey(
            brush: BrushPipelineKey(
                backend: .deposition,
                accumulation: .flow,
                edgeTreatment: .none,
                functionConstants: BrushFunctionConstants(
                    usesSecondaryShape: false,
                    usesGrain: false,
                    usesSecondaryGrain: false,
                    usesDestinationSampling: false
                )
            ),
            abiVersion: DepositionABI.version,
            colorPixelFormatRawValue: pixelFormat.rawValue,
            sampleCount: 1
        )
        return (
            device,
            try await DepositionPipelineLibrary(
                device: device,
                library: library
            ).prepare(for: key),
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
    }

    @MainActor
    private func makeResources(
        context: (
            device: any MTLDevice,
            pipeline: DepositionPipelineBinding,
            layerID: UUID
        )
    ) throws -> StrokeTileSurfaceResources {
        try StrokeTileSurfaceResources(
            device: context.device,
            store: PaintTileStore(
                device: context.device,
                byteBudget: PaintTileDescriptor.residentByteCount * 16
            ),
            layerID: context.layerID,
            pixelSize: PixelSize(width: 512, height: 512),
            generation: 7,
            maximumRecordCount: 32,
            maximumTileReferenceCount: 128,
            pipeline: context.pipeline,
            namespaceLease: .testing(generation: 7)
        )
    }

    private func projectedRecord(
        ordinal: UInt64,
        bounds: PixelRect,
        predicted: Bool = false,
        color: InkColor = .black,
        position: SIMD2<Float> = SIMD2(16, 16),
        radialPage: RadialPageCoordinate? = nil
    ) throws -> StrokePreparedProjectedRecord {
        let dab = LogicalDab(
            position: WorldPoint(x: position.x, y: position.y),
            brushToWorld: Affine2D(
                xAxis: SIMD2(4, 0),
                yAxis: SIMD2(0, 4),
                translation: position
            ),
            radius: 4,
            diameter: 8,
            spacing: 1,
            flow: 1,
            strokeOpacity: 1,
            rotation: 0,
            scatter: .zero,
            hardness: 1,
            grainOffset: .zero,
            grainScale: 1,
            grainRotation: 0,
            color: color,
            colorAdjustment: .identity,
            materialFamily: .ink,
            materialContribution: 1,
            sourceDistance: 0,
            ordinal: ordinal,
            isPredicted: predicted
        )
        let fragment = CellFragment(
            cell: CellIndex(column: 0, row: 0),
            imageOrdinal: 0,
            canonicalFromBrush: dab.brushToWorld,
            brushClip: ConvexClip(halfPlanes: [])
        )
        return StrokePreparedProjectedRecord(
            depositionRecord: ProjectedDepositionRecord(
                identity: ordinal,
                instance: try PatternDepositionStampInstance(
                    fragment: fragment,
                    dab: dab,
                    logicalOrdinal: ordinal,
                    isometryOrdinal: 0
                ),
                radialPage: radialPage
            ),
            dirtyRect: bounds,
            radialPage: radialPage
        )
    }

    private func recordInTile(
        ordinal: UInt64,
        coordinate: PaintTileCoordinate,
        predicted: Bool
    ) throws -> StrokePreparedProjectedRecord {
        let center = SIMD2<Float>(
            Float(coordinate.x * PaintTileDescriptor.side + 128),
            Float(coordinate.y * PaintTileDescriptor.side + 128)
        )
        return try projectedRecord(
            ordinal: ordinal,
            bounds: try #require(PixelRect(
                minX: Int(center.x) - 8,
                minY: Int(center.y) - 8,
                maxX: Int(center.x) + 8,
                maxY: Int(center.y) + 8
            )),
            predicted: predicted,
            position: center
        )
    }

    private func readTile(
        _ surface: TiledRasterSurface,
        coordinate: PaintTileCoordinate,
        device: any MTLDevice
    ) throws -> Data {
        let lease = try surface.reserveSortedUniqueTiles(
            at: [coordinate],
            pinReasons: [.inFlight]
        )
        do {
            let data = try download(
                try #require(lease.bindings.first?.texture),
                device: device
            )
            try surface.returnLease(lease)
            return data
        } catch {
            try? surface.returnLease(lease)
            throw error
        }
    }

    private func frameUniforms(side: Float) -> PatternGridFrameUniforms {
        PatternGridFrameUniforms(
            drawableSize: SIMD2(repeating: side),
            worldCenter: SIMD2(repeating: side / 2),
            tileSize: SIMD2(repeating: side),
            zoom: 1,
            gridLineWidth: 0,
            showGridLines: 0,
            liveVisible: 1,
            tilingKind: 0,
            diagnosticMode: 0,
            compositeMode: 0,
            symmetryFamily: 0,
            repeatSize: SIMD2(repeating: side),
            latticeXAxis: SIMD2(1, 0),
            latticeYAxis: SIMD2(0, 1),
            latticeTranslation: .zero,
            guideKind: 0,
            showCanvasBoundary: 0
        )
    }

    private func visibleMaterialUniforms()
        -> PatternDepositionMaterialUniforms
    {
        PatternDepositionMaterialUniforms(
            coverageParameters: SIMD4(0, 0, 0, 1),
            secondaryShapeTransform: SIMD4(1, 0, 0, 0),
            edgeParameters: SIMD4(1, 0, 0, 0),
            options: SIMD4(
                PatternDepositionShapeCombinationMultiply,
                1,
                PatternDepositionShapeKindHardRound,
                PatternDepositionShapeKindHardRound
            )
        )
    }

    private func regionContainsNonzero(
        _ bytes: Data,
        x: Range<Int>,
        y: Range<Int>
    ) -> Bool {
        for row in y {
            for column in x {
                let offset = (row * PaintTileDescriptor.side + column) * 8
                if bytes[offset..<(offset + 8)].contains(where: { $0 != 0 }) {
                    return true
                }
            }
        }
        return false
    }

    private func regionIsAllZero(
        _ bytes: Data,
        x: Range<Int>,
        y: Range<Int>
    ) -> Bool {
        !regionContainsNonzero(bytes, x: x, y: y)
    }

    private func download(
        _ texture: any MTLTexture,
        device: any MTLDevice
    ) throws -> Data {
        let buffer = try #require(device.makeBuffer(
            length: PaintTileDescriptor.residentByteCount,
            options: .storageModeShared
        ))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 256, height: 256, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: PaintTileDescriptor.side * 8,
            destinationBytesPerImage: PaintTileDescriptor.residentByteCount
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        return Data(
            bytes: buffer.contents(),
            count: PaintTileDescriptor.residentByteCount
        )
    }
}

private final class StrokeNamespaceRetirementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    var tokens: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ token: UInt64) {
        lock.lock()
        storage.append(token)
        lock.unlock()
    }
}
