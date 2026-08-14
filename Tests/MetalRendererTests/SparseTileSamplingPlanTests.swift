import Foundation
import Metal
import Testing
@testable import MetalRenderer
@testable import PatternEngine

@Suite("Sparse tile sampling plan")
struct SparseTileSamplingPlanTests {
    @Test
    func hugeFinitePeriodicFoldFailsClosedBeforeRetentionInSubprocess()
        throws
    {
        if ProcessInfo.processInfo.environment[
            "PATTERN_PERIODIC_HUGE_FINITE_FOLD"
        ] == "1" {
            try exerciseHugeFinitePeriodicFoldRejection()
            return
        }
        let result = try runHugeFinitePeriodicFoldSubprocess()
        #expect(result.status == 0, Comment(rawValue: result.standardError))
    }

    @Test
    func periodicFloatAliasedCanonicalPeriodFailsBeforeRetention() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let sourceSize = PixelSize(width: 64, height: 64)
        let fixture = try makeSource(
            device: device,
            pixelSize: sourceSize,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .periodic(period: sourceSize)
        )
        let supported = try periodicFold(.grid, rasterSize: sourceSize)
        let aliasedWidth = (1 << 24) + 1
        #expect(Float(aliasedWidth) == Float(aliasedWidth - 1))
        let fold = CompiledPeriodicDisplayFold(
            family: supported.family,
            coordinateSpace: supported.coordinateSpace,
            worldToLattice: supported.worldToLattice,
            canonicalSize: PatternSize(
                width: Float(aliasedWidth),
                height: supported.canonicalSize.height
            ),
            repeatSize: supported.repeatSize,
            phase: supported.phase,
            alternatingReflections: supported.alternatingReflections
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: .identity
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        let before = fixture.request.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.inconsistentAddressing) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sources: [fixture.request],
                outputRegion: try region(0, 0, 1, 1),
                limits: .testDefaults
            )
        }
        #expect(fixture.request.provider.backingSnapshot() == before)
    }

    @Test
    func periodicCellBeyondMetalInt32FailsBeforeRetention() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 64, height: 64)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .periodic(period: size)
        )
        let fold = try periodicFold(.grid, rasterSize: size)
        let firstUnsafeCell = Float(Int32.max) + 1
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: SparseTileOutputToSourceTransform(
                sourceOffset: SIMD2(
                    firstUnsafeCell * fold.repeatSize.width,
                    0
                ),
                sourceStep: SIMD2(repeating: 1)
            )
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        let before = fixture.request.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError
            .invalidOutputToSourceTransform) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sources: [fixture.request],
                outputRegion: try region(0, 0, 1, 1),
                limits: .testDefaults
            )
        }
        #expect(fixture.request.provider.backingSnapshot() == before)
    }

    @Test
    func incompatiblePeriodicMappingFailsBeforeSelectionOrSourceRetention()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let fold = try periodicFold(.halfDrop, rasterSize: size)
        let mapping = SparseTileSamplingOutputMapping.periodic(
            SparseTilePeriodicOutputMapping(
                fold: fold,
                outputToWorldTransform: .identity
            )
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: mapping
        )
        let before = fixture.request.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.inconsistentAddressing) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sources: [fixture.request],
                outputRegion: try region(0, 0, 1, 1),
                limits: .testDefaults
            )
        }
        #expect(fixture.request.provider.backingSnapshot() == before)
    }

    @Test
    func unsupportedPeriodicPhaseCountFailsBeforeSourceRetention() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .periodic(period: size)
        )
        let supported = try periodicFold(.halfDrop, rasterSize: size)
        let fold = CompiledPeriodicDisplayFold(
            family: supported.family,
            coordinateSpace: supported.coordinateSpace,
            worldToLattice: supported.worldToLattice,
            canonicalSize: supported.canonicalSize,
            repeatSize: supported.repeatSize,
            phase: PeriodicPhaseProgram(
                indexAxis: .x,
                offsetAxis: .y,
                fractions: [0, 0.25, 0.5]
            ),
            alternatingReflections: supported.alternatingReflections
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(SparseTilePeriodicOutputMapping(
                fold: fold,
                outputToWorldTransform: .identity
            ))
        )
        let before = fixture.request.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.inconsistentAddressing) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sources: [fixture.request],
                outputRegion: try region(0, 0, 1, 1),
                limits: .testDefaults
            )
        }
        #expect(fixture.request.provider.backingSnapshot() == before)
    }

    @Test(arguments: [
        SymmetryPresetID.halfDrop,
        .brick,
        .mirrorXY,
        .squareRotation,
        .rotation3,
        .kaleidoscope30,
    ])
    func periodicReachabilityMatchesFoldedPixelCentersAtBoundariesAndNegatives(
        preset: SymmetryPresetID
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 768, height: 768)
        let fold = try periodicFold(preset, rasterSize: size)
        let coordinates = allPageCoordinates(size)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: coordinates,
            addressing: .periodic(period: size)
        )
        let output = try region(-259, -131, -251, -123)
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(511.5, 255.5),
            sourceStep: SIMD2(0.5, 0.5)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        let expected = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        )

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(Set(lease.content.bindingRecords.map(\.reference.coordinate))
            == expected)
        #expect(lease.content.outputMapping == .periodic(mapping))
        try lease.retire()
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
    }

    @Test
    func periodicFallbackBatchesReuseExactReachabilityBelowSixteenTextures()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 1_536, height: 1_536)
        let fold = try periodicFold(.halfDrop, rasterSize: size)
        let coordinates = allPageCoordinates(size)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: coordinates,
            addressing: .periodic(period: size)
        )
        let output = try region(-6, -6, 7, 7)
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(767.5, 767.5),
            sourceStep: SIMD2(255.75, 255.75)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(lease.content.bindingRecords.count > 16)
        #expect(lease.content.batches.count > 1)
        #expect(lease.content.batches.allSatisfy {
            $0.globalSlots.count <= SparseSamplingABI.maximumFallbackTextures
        })
        for batch in lease.content.batches {
            let expected = expectedPeriodicPages(
                fold: fold,
                transform: transform,
                output: output,
                subregion: batch.outputRegion
            )
            let actual = Set(batch.globalSlots.compactMap { slot in
                lease.content.bindingRecords.first {
                    $0.globalSlot == slot
                }?.reference.coordinate
            })
            #expect(actual == expected)
        }
        try lease.retire()
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
    }

    @Test
    func periodicObliqueSeamAfterFirst4096CentersIsNotMissed() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 1_536, height: 1_536)
        let fold = try orientedPeriodicFold(
            .squareRotation,
            rasterSize: size,
            orientationRadians: .pi / 7
        )
        let output = try region(0, 0, 129, 65)
        #expect(output.width * output.height > 4_096)

        // Put an oblique lattice-cell boundary through the lower-right portion
        // of the region. Row-major traversal cannot encounter it among the
        // first 4,096 pixel centers.
        let seamLocal = SIMD2<Float>(126.25, 48.75)
        let seamWorld = fold.worldToLattice.inverted().applying(
            to: SIMD2<Float>(1, 0.375)
        )
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: seamWorld - seamLocal,
            sourceStep: SIMD2(repeating: 1)
        )
        let expected = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        )
        let first4096 = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output,
            maximumPixelCenters: 4_096
        )
        #expect(!expected.subtracting(first4096).isEmpty)

        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(Set(lease.content.bindingRecords.map(\.reference.coordinate))
            == expected)
        try lease.retire()
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
    }

    @Test
    func unitLatticeThinDiagonalRetainsOnlyExactlyReachablePages() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 2_048, height: 2_048)
        let fold = try orientedPeriodicFold(
            .squareRotation,
            rasterSize: size,
            orientationRadians: .pi / 4
        )
        let output = try region(0, 0, 1_024, 1)
        let step: Float = 1.9
        let firstLatticeCenter = SIMD2<Float>(0.1, 0.8)
        let firstWorldCenter = fold.worldToLattice.inverted().applying(
            to: firstLatticeCenter
        )
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: firstWorldCenter - SIMD2<Float>(
                repeating: 0.5 * step
            ),
            sourceStep: SIMD2(repeating: step)
        )
        let expected = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        )
        #expect(expected.count < 24)

        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        let before = fixture.request.provider.backingSnapshot()

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: limits(maximumBindingSlots: 24)
        )
        let actual = Set(
            lease.content.bindingRecords.map(\.reference.coordinate)
        )
        #expect(actual == expected)
        #expect(lease.content.bindingRecords.count == expected.count)
        // One aggregate exact-reference lease must back the exact selected
        // binding set; no unreachable page may create another reference.
        let retained = fixture.request.provider.backingSnapshot()
        #expect(retained.activeLeaseCount == 1)
        #expect(Set(retained.entries.filter { !$0.pinCounts.isEmpty }
            .map(\.identity.coordinate)) == expected)
        try lease.retire()
        let after = fixture.request.provider.backingSnapshot()
        #expect(after.activeLeaseCount == before.activeLeaseCount)
        #expect(after.entries.allSatisfy { $0.pinCounts.isEmpty })
    }

    @Test
    func axisAlignedSparseStepRetainsOnlySampledBilinearPages() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 2_048, height: 2_048)
        let fold = try periodicFold(.grid, rasterSize: size)
        let output = try region(0, 0, 2, 1)
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(-511.5, 0),
            sourceStep: SIMD2(1_024, 1)
        )
        let expected = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        )
        #expect(expected == [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 4, y: 0),
        ])
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        let before = fixture.request.provider.backingSnapshot()

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: limits(maximumBindingSlots: expected.count)
        )
        #expect(Set(lease.content.bindingRecords.map(\.reference.coordinate))
            == expected)
        #expect(lease.content.bindingRecords.count == expected.count)
        let retained = fixture.request.provider.backingSnapshot()
        #expect(retained.activeLeaseCount == 1)
        #expect(Set(retained.entries.filter { !$0.pinCounts.isEmpty }
            .map(\.identity.coordinate)) == expected)
        try lease.retire()
        let after = fixture.request.provider.backingSnapshot()
        #expect(after.activeLeaseCount == before.activeLeaseCount)
        #expect(after.entries.allSatisfy { $0.pinCounts.isEmpty })
    }

    @Test(arguments: [
        SymmetryPresetID.squareRotation,
        .rotation3,
    ])
    func productionViewportPeriodicReachabilityUsesBoundedSubdivision(
        preset: SymmetryPresetID
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 4_096, height: 4_096)
        let fold = try orientedPeriodicFold(
            preset,
            rasterSize: size,
            orientationRadians: .pi / 7
        )
        let output = try region(0, 0, 3_024, 1_964)
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: SparseTileOutputToSourceTransform(
                sourceOffset: SIMD2(-1_205.25, -773.5),
                sourceStep: SIMD2(repeating: 0.625)
            )
        )
        let expected = try SparseTileSamplingPlanBuilder
            .testingPeriodicReachabilityReceipt(
                for: output,
                mapping: mapping,
                addressing: .periodic(period: size)
            )
        let coordinates = expected.physicalPages.sorted()
        let layerID = UUID()
        let sources = try SparseTileSampleRole.allCases.map { role in
            try makeRequest(
                device: device,
                layerID: layerID,
                role: role,
                pixelSize: size,
                coordinates: coordinates,
                addressing: .periodic(period: size),
                contentRevision: UInt64(role.rawValue) + 1
            )
        }
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: layerID,
                roles: sources.map(\.contentKey)
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        let metadata = try sources.map { source in
            try SparseTileSourceSnapshot(
                contentKey: source.contentKey,
                addressing: source.addressing,
                layerID: source.layerID,
                references: source.references,
                changedCoordinates: source.changedCoordinates,
                disposition: source.disposition
            )
        }
        let fullContent = try SparseTileSamplingPlanBuilder.buildFull(
            key: key,
            sources: metadata,
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(Set(fullContent.bindingRecords.map {
            SparseTileRecordCoordinateKey(
                layerID: $0.layerID,
                role: $0.role,
                coordinate: $0.reference.coordinate
            )
        }) == Set(SparseTileSampleRole.allCases.flatMap { role in
            coordinates.map {
                SparseTileRecordCoordinateKey(
                    layerID: layerID,
                    role: role,
                    coordinate: $0
                )
            }
        }))
        let selection = try SparseTileOwnedSourceBatch.selecting(
            sources: sources,
            key: key,
            outputRegion: output
        )
        let phaseA = try #require(
            selection.testingPeriodicReachabilityReceipt
        )
        #expect(phaseA.physicalPages == expected.physicalPages)
        #expect(try selection.selectedReferenceCount()
            == coordinates.count * SparseTileSampleRole.allCases.count)
        let batch = try SparseTileOwnedSourceBatch.capturing(selection)
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: key,
            sourceBatch: batch,
            outputRegion: output,
            limits: .testDefaults
        )
        let receipt = try #require(
            cache.testingLastPeriodicReachabilityReceipt
        )
        let area = output.width * output.height
        #expect(area == 5_939_136)
        #expect(!receipt.physicalPages.isEmpty)
        #expect(receipt.singlePageFastPathCount > 0)
        #expect(
            receipt.enumeratedPixelCenterCount < 50_000,
            "\(receipt)"
        )
        #expect(receipt.visitedNodeCount < 50_000, "\(receipt)")
        #expect(receipt.subdivisionCount < receipt.visitedNodeCount)
        #expect(receipt.cacheHitCount > 2, "\(receipt)")
        // Every corner/signature/fold/witness/page walk is charged, so this
        // honest aggregate stays below half the production 250k hard cap while
        // expensive discrete-center enumeration remains below 50k.
        #expect(receipt.workCount < 125_000, "\(receipt)")
        #expect(receipt.phaseAWorkCount == phaseA.workCount)
        #expect(receipt.acquisitionWorkCount
            < receipt.phaseAWorkCount / 10, "\(receipt)")
        for source in sources {
            let backing = source.provider.backingSnapshot()
            #expect(Set(backing.entries.filter { !$0.pinCounts.isEmpty }
                .map(\.identity.coordinate)) == expected.physicalPages)
        }
        try lease.retire()
        for source in sources {
            let backing = source.provider.backingSnapshot()
            #expect(backing.activeLeaseCount == 0)
            #expect(backing.entries.allSatisfy { $0.pinCounts.isEmpty })
        }
    }

    @Test
    func periodicReachabilitySplitsProjectedFoldAmbiguityBeforeScreenLength()
        throws
    {
        let size = PixelSize(width: 512, height: 512)
        let fold = try periodicFold(.grid, rasterSize: size)
        let output = try region(0, 0, 3_024, 2)
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(100, -0.5),
            sourceStep: SIMD2(0, 512)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let receipt = try SparseTileSamplingPlanBuilder
            .testingPeriodicReachabilityReceipt(
                for: output,
                mapping: mapping,
                addressing: .periodic(period: size)
            )
        #expect(receipt.physicalPages == expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        ))
        #expect(receipt.visitedNodeCount == 3, "\(receipt)")
        #expect(receipt.subdivisionCount == 1, "\(receipt)")
        #expect(receipt.enumeratedPixelCenterCount == 0, "\(receipt)")
        // Root signature work (5), two proved children (14 each), and the
        // four-entry recursive Set merge are all charged.
        #expect(receipt.workCount == 37, "\(receipt)")
    }

    @Test
    func periodicReachabilityBudgetsFailTypedWithoutLeasesOrSlotDebt() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 2_048, height: 2_048)
        let fold = try orientedPeriodicFold(
            .rotation3,
            rasterSize: size,
            orientationRadians: .pi / 7
        )
        let output = try region(0, 0, 2_048, 2_048)
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: SparseTileOutputToSourceTransform(
                sourceOffset: SIMD2(-421.25, -317.75),
                sourceStep: SIMD2(repeating: 0.75)
            )
        )
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let before = fixture.request.provider.backingSnapshot()

        let axisMapping = SparseTilePeriodicOutputMapping(
            fold: try periodicFold(.grid, rasterSize: size),
            outputToWorldTransform: SparseTileOutputToSourceTransform(
                sourceOffset: .zero,
                sourceStep: SIMD2(1_024, 1)
            )
        )
        let axisKey = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(axisMapping)
        )
        // One node, five upper-bound page visits, three discrete axis centers,
        // then two exact Cartesian page insertions. These thresholds prove all
        // formerly hidden variable loops participate in the hard budget.
        for maximum in [13, 15, 18, 20] {
            #expect(throws: SparseTileSamplingPlanError
                .periodicReachabilityWorkLimitExceeded(maximum: maximum)) {
                _ = try SparseTileOwnedSourceBatch.selecting(
                    sources: [fixture.request],
                    key: axisKey,
                    outputRegion: try region(0, 0, 2, 1),
                    maximumPeriodicReachabilityWork: maximum
                )
            }
        }
        #expect(fixture.request.provider.backingSnapshot() == before)

        // A complete immutable seed must not bypass a stricter Phase-B cap
        // merely because every acquisition lookup is a cache hit.
        let onePixel = try region(0, 0, 1, 1)
        let fullSeedSelection = try SparseTileOwnedSourceBatch.selecting(
            sources: [fixture.request],
            key: axisKey,
            outputRegion: onePixel
        )
        #expect(try #require(fullSeedSelection
            .testingPeriodicReachabilityReceipt).phaseAWorkCount > 1)
        let fullSeedBatch = try SparseTileOwnedSourceBatch.capturing(
            fullSeedSelection
        )
        let strictSeedCache = SparseTileSamplingPlanCache(
            maximumPeriodicReachabilityWork: 1
        )
        #expect(throws: SparseTileSamplingPlanError
            .periodicReachabilityWorkLimitExceeded(maximum: 1)) {
            _ = try strictSeedCache.acquire(
                key: axisKey,
                sourceBatch: fullSeedBatch,
                outputRegion: onePixel,
                limits: .testDefaults
            )
        }
        #expect(fixture.request.provider.backingSnapshot() == before)
        #expect(strictSeedCache.snapshot().activeContentAcquisitionCount == 0)
        #expect(strictSeedCache.snapshot().pendingRetirementCount == 0)

        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        #expect(throws: SparseTileSamplingPlanError
            .periodicReachabilityWorkLimitExceeded(maximum: 1)) {
            _ = try SparseTileOwnedSourceBatch.selecting(
                sources: [fixture.request],
                key: key,
                outputRegion: output,
                maximumPeriodicReachabilityWork: 1
            )
        }
        #expect(fixture.request.provider.backingSnapshot() == before)

        let completeSelection = try SparseTileOwnedSourceBatch.selecting(
            sources: [fixture.request],
            key: key,
            outputRegion: output
        )
        let phaseAWork = try #require(completeSelection
            .testingPeriodicReachabilityReceipt).phaseAWorkCount
        let selection = completeSelection
            .testingWithRootOnlyPeriodicReachabilitySeed()
        #expect(try selection.selectedReferenceCount() > 16)
        let batch = try SparseTileOwnedSourceBatch.capturing(selection)
        let retained = fixture.request.provider.backingSnapshot()
        #expect(retained.activeLeaseCount == 0)
        #expect(retained.entries.reduce(0) {
            $0 + $1.snapshotRetainCount
        } > 0)
        let cache = SparseTileSamplingPlanCache(
            maximumPeriodicReachabilityWork: phaseAWork
        )
        #expect(throws: SparseTileSamplingPlanError
            .periodicReachabilityWorkLimitExceeded(maximum: phaseAWork)) {
            _ = try cache.acquire(
                key: key,
                sourceBatch: batch,
                outputRegion: output,
                limits: .testDefaults
            )
        }
        let after = fixture.request.provider.backingSnapshot()
        #expect(after.activeLeaseCount == 0)
        #expect(after.entries.allSatisfy { $0.snapshotRetainCount == 0 })
        #expect(after.entries.allSatisfy { $0.pinCounts.isEmpty })
        let cacheSnapshot = cache.snapshot()
        #expect(cacheSnapshot.activeContentAcquisitionCount == 0)
        #expect(cacheSnapshot.pendingRetirementCount == 0)
        #expect(cache.testingActiveContentIdentityCount == 0)
    }

    @Test
    func periodicOnePixelFallbackUsesExactFoldedBilinearHalo() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 1_536, height: 1_536)
        let fold = try orientedPeriodicFold(
            .squareRotation,
            rasterSize: size,
            orientationRadians: -.pi / 9
        )
        let targetCanonical = SIMD2<Float>(255.6, 255.6)
        let targetWorld = fold.worldToLattice.inverted().applying(
            to: targetCanonical / Float(size.width)
        )
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: targetWorld - SIMD2<Float>(repeating: 0.5),
            sourceStep: SIMD2(repeating: 1)
        )
        let output = try region(0, 0, 1, 1)
        let expected = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        )
        #expect(expected.count == 4)

        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(Set(lease.content.bindingRecords.map(\.reference.coordinate))
            == expected)
        #expect(lease.content.batches.count == 1)
        #expect(lease.content.batches[0].globalSlots.count == 4)
        try lease.retire()
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
    }

    @Test
    func obliqueLatticeReachabilityPinsOnlyPreciseTask7Pages()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 1_536, height: 1_536)
        let fold = try orientedPeriodicFold(
            .squareRotation,
            rasterSize: size,
            orientationRadians: .pi / 7
        )
        let world = SIMD2<Float>(
            Float(bitPattern: 1_232_348_175),
            Float(bitPattern: 1_302_845_308)
        )
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: world - SIMD2<Float>(repeating: 0.5),
            sourceStep: SIMD2(repeating: 1)
        )
        let output = try region(0, 0, 1, 1)
        let expected = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        )
        #expect(Set(expected.map(\.x)) == [2])

        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(Set(lease.content.bindingRecords.map(
            \.reference.coordinate
        )) == expected)
        #expect(Set(fixture.request.provider.backingSnapshot().entries
            .filter { !$0.pinCounts.isEmpty }
            .map(\.identity.coordinate)) == expected)
        try lease.retire()
    }

    @Test
    func largeTriangularUnitLatticeUsesModuloWithoutInt32CellNarrowing()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let fold = try orientedPeriodicFold(
            .rotation3,
            rasterSize: size,
            orientationRadians: .pi / 7
        )
        #expect(fold.coordinateSpace == .unitLattice)
        #expect(fold.family == .triangular)
        let large = Float(Int32.max) * 8
        let world = SIMD2<Float>(large, -large.nextDown)
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: world - SIMD2<Float>(repeating: 0.5),
            sourceStep: SIMD2(repeating: 1)
        )
        let output = try region(0, 0, 1, 1)
        let expected = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        )
        #expect(!expected.isEmpty)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(Set(lease.content.bindingRecords.map(
            \.reference.coordinate
        )) == expected)
        #expect(Set(fixture.request.provider.backingSnapshot().entries
            .filter { !$0.pinCounts.isEmpty }
            .map(\.identity.coordinate)) == expected)
        try lease.retire()
        #expect(fixture.request.provider.backingSnapshot()
            .entries.allSatisfy { $0.pinCounts.isEmpty })
    }

    @Test
    func largeRectangularUnitLatticeRejectsTask7InexactCellBeforeRetention()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let fold = try orientedPeriodicFold(
            .squareRotation,
            rasterSize: size,
            orientationRadians: .pi / 7
        )
        #expect(fold.coordinateSpace == .unitLattice)
        #expect(fold.family == .rectangular)
        let large = Float(Int32.max) * 8
        let world = SIMD2<Float>(large, -large.nextDown)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let before = fixture.request.provider.backingSnapshot()
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: SparseTileOutputToSourceTransform(
                sourceOffset: world - SIMD2<Float>(repeating: 0.5),
                sourceStep: .one
            )
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        #expect(throws: SparseTileSamplingPlanError
            .invalidOutputToSourceTransform) {
            _ = try SparseTileOwnedSourceBatch.selecting(
                sources: [fixture.request],
                key: key,
                outputRegion: try region(0, 0, 1, 1)
            )
        }
        #expect(fixture.request.provider.backingSnapshot() == before)
    }

    @Test
    func axisFoldScalingPinsOnlyPreciseTask7LowerNeighbors() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let repeatWidth: Float = 1_000.7
        let remainder = Float(bitPattern: 0x43f9_afb6)
        let scalarCanonical = remainder * Float(size.width) / repeatWidth
        let reassociatedCanonical = remainder
            * (Float(size.width) / repeatWidth)
        #expect(scalarCanonical < 255.5)
        #expect(reassociatedCanonical == 255.5)
        let fold = CompiledPeriodicDisplayFold(
            family: .rectangular,
            coordinateSpace: .axisAlignedRepeat,
            worldToLattice: .identity,
            canonicalSize: PatternSize(width: 512, height: 512),
            repeatSize: PatternSize(width: repeatWidth, height: 512),
            phase: nil,
            alternatingReflections: []
        )
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(remainder - 0.5, 63.5),
            sourceStep: SIMD2(repeating: 1)
        )
        let output = try region(0, 0, 1, 1)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        let selectedXPages = Set(
            lease.content.bindingRecords.map(\.reference.coordinate.x)
        )
        let expected = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        )
        #expect(Set(expected.map(\.x)) == [0])
        #expect(selectedXPages == Set(expected.map(\.x)))
        #expect(Set(fixture.request.provider.backingSnapshot().entries
            .filter { !$0.pinCounts.isEmpty }
            .map(\.identity.coordinate)) == expected)
        try lease.retire()
    }

    @Test
    func negativePhaseAndOddReflectionPinOnlyPreciseTask7Neighbors()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let repeatWidth: Float = 1_000.7
        let remainder = Float(bitPattern: 0x43f9_afb8)
        let phaseOffset = repeatWidth * 0.5
        let phasedX = remainder - repeatWidth
        let world = SIMD2<Float>(phasedX + phaseOffset, -0.5)
        let fold = CompiledPeriodicDisplayFold(
            family: .rectangular,
            coordinateSpace: .axisAlignedRepeat,
            worldToLattice: .identity,
            canonicalSize: PatternSize(width: 512, height: 512),
            repeatSize: PatternSize(width: repeatWidth, height: 512),
            phase: PeriodicPhaseProgram(
                indexAxis: .y,
                offsetAxis: .x,
                fractions: [0, 0.5]
            ),
            alternatingReflections: [.x]
        )
        let compiled = fold.applying(to: WorldPoint(world))
        #expect(compiled.x == 256.5)
        let reassociatedLocal = remainder * (512 / repeatWidth)
        let reassociatedReflected = (512 as Float) - reassociatedLocal
        #expect(reassociatedReflected < 256.5)
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: world - SIMD2<Float>(repeating: 0.5),
            sourceStep: SIMD2(repeating: 1)
        )
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: allPageCoordinates(size),
            addressing: .periodic(period: size)
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: fold,
            outputToWorldTransform: transform
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        let output = try region(0, 0, 1, 1)
        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        let expected = expectedPeriodicPages(
            fold: fold,
            transform: transform,
            output: output
        )
        #expect(Set(expected.map(\.x)) == [1])
        #expect(Set(lease.content.bindingRecords.map(
            \.reference.coordinate
        )) == expected)
        #expect(Set(fixture.request.provider.backingSnapshot().entries
            .filter { !$0.pinCounts.isEmpty }
            .map(\.identity.coordinate)) == expected)
        try lease.retire()
    }

    @Test
    func finiteRadialMappingIdentityCannotAliasAffinePlanIdentity() throws {
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 7,
                center: WorldPoint(x: 321.5, y: 217.25),
                referenceAngleRadians: 0.375
            )),
            canvasSize: PixelSize(width: 768, height: 640)
        )
        let radial = try SparseTileSamplingOutputMapping.finiteRadial(
            strategy: strategy
        )
        let affine = SparseTileSamplingOutputMapping.affine(.identity)
        let layerID = UUID()
        let role = SparseTileRoleContentKey(
            role: .canonical,
            surfaceIdentity: UUID(),
            contentRevision: 1,
            bindingChunkRevision: 1
        )
        let commonLayers = [
            SparseTileLayerContentKey(layerID: layerID, roles: [role]),
        ]
        let affineKey = SparseTileSamplingPlanKey(
            documentGeneration: 1,
            orderedLayers: commonLayers,
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: affine
        )
        let radialKey = SparseTileSamplingPlanKey(
            documentGeneration: 1,
            orderedLayers: commonLayers,
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: radial
        )

        #expect(affine != radial)
        #expect(affineKey != radialKey)
        #expect(Set([affineKey, radialKey]).count == 2)
    }

    @Test
    func finiteRadialSelectionUsesIntersectingImagesAndThreeByThreePageHalo()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mirror,
                rayCount: 1,
                center: WorldPoint(x: 640, y: 384),
                referenceAngleRadians: 0.25
            )),
            canvasSize: PixelSize(width: 1_280, height: 768)
        )
        let radial = try #require(
            strategy.compiledSymmetry.domain.finite?.radial
        )
        let layout = try #require(radial.layout)
        let allPhysical = layout.residentPages.map {
            PaintTileCoordinate(
                x: $0.atlasSlot % layout.atlasColumns,
                y: $0.atlasSlot / layout.atlasColumns
            )
        }
        let fixture = try makeSource(
            device: device,
            pixelSize: layout.atlasPixelSize,
            coordinates: allPhysical,
            addressing: .radial(layout: layout)
        )
        // This lies left of the off-center origin and reaches a signed logical
        // page through the mirror fold.
        let output = try region(286, 356, 302, 372)
        let mapping = try SparseTileSamplingOutputMapping.finiteRadial(
            strategy: strategy
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: mapping
        )
        let worldRect = AxisAlignedRect(
            minimum: SIMD2(Float(output.minX), Float(output.minY)),
            maximum: SIMD2(Float(output.maxX), Float(output.maxY))
        )
        var expectedPages: Set<RadialPageCoordinate> = []
        for image in strategy.images(intersecting: worldRect) {
            for dy in -1...1 {
                for dx in -1...1 {
                    let coordinate = RadialPageCoordinate(
                        x: image.cell.column + dx,
                        y: image.cell.row + dy
                    )
                    if layout.residentPage(at: coordinate) != nil {
                        expectedPages.insert(coordinate)
                    }
                }
            }
        }
        let expected = expectedPages.compactMap {
            layout.residentPage(at: $0)
        }.map {
            PaintTileCoordinate(
                x: $0.atlasSlot % layout.atlasColumns,
                y: $0.atlasSlot / layout.atlasColumns
            )
        }.sorted()
        #expect(expected.contains { coordinate in
            guard let page = layout.residentPages.first(where: {
                $0.atlasSlot == coordinate.y * layout.atlasColumns
                    + coordinate.x
            }) else { return false }
            return page.coordinate.x < 0
        })

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(lease.content.bindingRecords
            .map(\.reference.coordinate).sorted() == expected)
        #expect(expected.count < allPhysical.count)
        try lease.retire()
    }

    @Test
    func inconsistentFiniteRadialMappingFailsBeforeSourceRetention() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let sourceStrategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mirror,
                rayCount: 1,
                center: WorldPoint(x: 256, y: 256)
            )),
            canvasSize: PixelSize(width: 512, height: 512)
        )
        let mappingStrategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 4,
                center: WorldPoint(x: 240, y: 272),
                referenceAngleRadians: 0.5
            )),
            canvasSize: PixelSize(width: 512, height: 512)
        )
        let sourceLayout = try #require(
            sourceStrategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let physical = sourceLayout.residentPages.map {
            PaintTileCoordinate(
                x: $0.atlasSlot % sourceLayout.atlasColumns,
                y: $0.atlasSlot / sourceLayout.atlasColumns
            )
        }
        let fixture = try makeSource(
            device: device,
            pixelSize: sourceLayout.atlasPixelSize,
            coordinates: physical,
            addressing: .radial(layout: sourceLayout)
        )
        let before = fixture.request.provider.backingSnapshot()
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: try .finiteRadial(strategy: mappingStrategy)
        )

        #expect(throws: SparseTileSamplingPlanError.inconsistentAddressing) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sources: [fixture.request],
                outputRegion: try region(0, 0, 16, 16),
                limits: .testDefaults
            )
        }
        #expect(fixture.request.provider.backingSnapshot() == before)
    }

    @Test
    func finiteFourNeighborCornerUsesAllTilesInLinearPremultipliedSpace()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSource(
            device: device,
            pixelSize: PixelSize(width: 512, height: 512),
            coordinates: [
                .init(x: 0, y: 0), .init(x: 1, y: 0),
                .init(x: 0, y: 1), .init(x: 1, y: 1),
            ],
            addressing: .finite(PixelSize(width: 512, height: 512))
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 512, 512),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        let provider = CoordinateColorProvider(colors: [
            .init(x: 0, y: 0): SIMD4(1, 0, 0, 1),
            .init(x: 1, y: 0): SIMD4(0, 1, 0, 1),
            .init(x: 0, y: 1): SIMD4(0, 0, 1, 1),
            .init(x: 1, y: 1): SIMD4(1, 1, 1, 1),
        ])
        let actual = try SparseTileCPUReferenceSampler.sample(
            at: SIMD2(256, 256),
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: provider
        )
        #expect(actual == SIMD4<Float>(0.5, 0.5, 0.5, 1))
    }

    @Test
    func missingFiniteNeighborIsTransparentWithoutWeightRenormalization()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSource(
            device: device,
            pixelSize: PixelSize(width: 512, height: 256),
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(PixelSize(width: 512, height: 256))
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 512, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }
        let provider = CoordinateColorProvider(colors: [
            .init(x: 0, y: 0): SIMD4(0.8, 0.4, 0.2, 0.6),
        ])

        let actual = try SparseTileCPUReferenceSampler.sample(
            at: SIMD2(256, 1),
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: provider
        )
        #expect(actual == SIMD4<Float>(0.4, 0.2, 0.1, 0.3))
    }

    @Test
    func periodicSamplingWrapsEachNegativeNeighborBeforePageLookup() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let period = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: period,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .periodic(period: period)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(-2, -2, 2, 2),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        let actual = try SparseTileCPUReferenceSampler.sample(
            at: SIMD2(0, 0.5),
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: LocalXProvider()
        )
        #expect(abs(actual.x - 0.5) < 0.000_01)
        #expect(actual.y == 0)
        #expect(actual.w == 1)
    }

    @Test
    func radialSamplingResolvesSignedLogicalPageToCompactAtlasTile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 512,
            sectorAngleRadians: .pi
        )
        let logical = try #require(layout.residentPages.first {
            $0.coordinate.x < 0
        })
        let physical = PaintTileCoordinate(
            x: logical.atlasSlot % layout.atlasColumns,
            y: logical.atlasSlot / layout.atlasColumns
        )
        let fixture = try makeSource(
            device: device,
            pixelSize: layout.atlasPixelSize,
            coordinates: [physical],
            addressing: .radial(layout: layout)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(-512, 0, 512, 512),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        let point = SIMD2<Double>(
            Double(logical.coordinate.x * 256) + 0.5,
            Double(logical.coordinate.y * 256) + 0.5
        )
        let expected = SIMD4<Float>(0.2, 0.3, 0.4, 0.5)
        let actual = try SparseTileCPUReferenceSampler.sample(
            at: point,
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: CoordinateColorProvider(colors: [physical: expected])
        )
        #expect(actual == expected)
    }

    @Test
    func cpuProviderReceivesOnlyReferenceAndLocalCoordinates() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }
        let provider = RecordingProvider()

        _ = try SparseTileCPUReferenceSampler.sample(
            at: SIMD2(1.5, 2.5),
            layerID: fixture.layerID,
            role: .canonical,
            content: lease.content,
            provider: provider
        )
        #expect(provider.snapshot() == [
            .init(coordinate: .init(x: 0, y: 0), localX: 1, localY: 2),
            .init(coordinate: .init(x: 0, y: 0), localX: 2, localY: 2),
            .init(coordinate: .init(x: 0, y: 0), localX: 1, localY: 3),
            .init(coordinate: .init(x: 0, y: 0), localX: 2, localY: 3),
        ])
    }

    @Test
    func batchingSplitsLargestDimensionWithCompleteBilinearHalos() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 1_024, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: (0..<4).map { .init(x: $0, y: 0) },
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 1_024, 256),
            limits: limits(maximumTexturesPerBatch: 2)
        )
        defer { try? lease.retire() }

        #expect(lease.content.batches.map(\.outputRegion) == [
            try region(0, 0, 256, 256),
            try region(256, 0, 512, 256),
            try region(512, 0, 1_024, 256),
        ])
        #expect(lease.content.batches.map(\.globalSlots) == [
            [0, 1], [1, 2], [2, 3],
        ])
        #expect(lease.content.batches.allSatisfy {
            $0.globalSlots.count <= 2
        })
    }

    @Test
    func onePixelThatNeedsTwoRolesFailsBeforeEitherSurfaceIsLeased() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let authoritative = try makeRequest(
            device: device,
            layerID: layerID,
            role: .authoritative,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let before = [
            canonical.provider.backingSnapshot(),
            authoritative.provider.backingSnapshot(),
        ]
        let key = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, authoritative.contentKey]
        )

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sources: [canonical, authoritative],
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumTexturesPerBatch: 1)
            )
        }
        #expect(canonical.provider.backingSnapshot() == before[0])
        #expect(authoritative.provider.backingSnapshot() == before[1])
    }

    @Test
    func pageAndByteLimitsFailBeforeChangingTileStoreEvidence() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let before = fixture.request.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.pageEntryLimitExceeded(
            required: 4,
            maximum: 3
        )) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: fixture.key,
                sources: [fixture.request],
                outputRegion: try region(0, 0, 512, 512),
                limits: limits(maximumPageEntries: 3)
            )
        }
        #expect(fixture.request.provider.backingSnapshot() == before)
    }

    @Test
    func transformedViewportLeasesAndPagesOnlyItsExactBilinearHalo() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 1_024, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: (0..<4).map { .init(x: $0, y: 0) },
            addressing: .finite(size)
        )
        let beforeMetadata = fixture.request.provider.backingSnapshot()
        _ = try SparseTileSourceRequest(
            contentKey: fixture.request.contentKey,
            addressing: fixture.request.addressing,
            provider: fixture.request.provider,
            changedCoordinates: fixture.request.changedCoordinates,
            disposition: fixture.request.disposition
        )
        #expect(fixture.request.provider.backingSnapshot() == beforeMetadata)

        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(255, 0),
            sourceStep: SIMD2(repeating: 1)
        )
        let key = planKey(
            layerID: fixture.layerID,
            contentKeys: [fixture.request.contentKey],
            outputToSourceTransform: transform
        )
        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 1, 1),
            limits: .testDefaults
        )

        #expect(lease.content.bindingRecords.map(\.reference.coordinate) == [
            .init(x: 0, y: 0), .init(x: 1, y: 0),
        ])
        let table = try #require(lease.content.pageTable(
            layerID: fixture.layerID,
            role: .canonical
        ))
        #expect(table.entry(at: .init(x: 0, y: 0))?.isMissing == false)
        #expect(table.entry(at: .init(x: 1, y: 0))?.isMissing == false)
        #expect(table.entry(at: .init(x: 2, y: 0))?.isMissing == true)
        #expect(table.entry(at: .init(x: 3, y: 0))?.isMissing == true)

        let pinned = fixture.request.provider.backingSnapshot().entries
        #expect(pinned.filter { !$0.pinCounts.isEmpty }
            .map(\.identity.coordinate).sorted() == [
                .init(x: 0, y: 0), .init(x: 1, y: 0),
            ])
        let pressure = try fixture.request.provider.applyMemoryPressure(
            targetResidentBytes: 2 * PaintTileDescriptor.residentByteCount
        )
        #expect(pressure.evictedIdentities.map(\.coordinate).sorted() == [
            .init(x: 2, y: 0), .init(x: 3, y: 0),
        ])
        try lease.retire()
        let finalPressure = try fixture.request.provider.applyMemoryPressure(
            targetResidentBytes: 0
        )
        #expect(finalPressure.evictedIdentities.map(\.coordinate).sorted() == [
            .init(x: 0, y: 0), .init(x: 1, y: 0),
        ])
    }

    @Test
    func ordinaryIdentityAtTileEdgeDoesNotWidenPastShaderReachability() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size)
        )

        func legalGroupings(at center: Float) -> [Float] {
            let origin: Float = 0
            let step: Float = 1
            let product = center * step
            return [
                (origin + product) - 0.5,
                origin.addingProduct(center, step) - 0.5,
                (origin - 0.5) + product,
                (origin - 0.5).addingProduct(center, step),
                origin + (product - 0.5),
                origin + (-Float(0.5)).addingProduct(center, step),
            ]
        }

        let first = legalGroupings(at: 0.5)
        let last = legalGroupings(at: 254.5)
        #expect(first.allSatisfy { $0 == 0 })
        #expect(last.allSatisfy { $0 == 254 })

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 255, 1),
            limits: .testDefaults
        )
        #expect(lease.content.bindingRecords.map(\.reference.coordinate) == [
            .init(x: 0, y: 0),
        ])
        try lease.retire()
    }

    @Test
    func largeNonzeroIdentityIncludesFloatRoundedNeighborPage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let tileSide = PaintTileDescriptor.side
        let outputOrigin = 33_554_432
        let nextPage = 131_073
        let size = PixelSize(
            width: (nextPage + 1) * tileSide,
            height: tileSide
        )
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [
                .init(x: nextPage - 1, y: 0),
                .init(x: nextPage, y: 0),
            ],
            addressing: .finite(size)
        )

        let origin = Float(outputOrigin)
        let center: Float = 254.5
        let step: Float = 1
        let product = center * step
        let legalGroupings = [
            (origin + product) - 0.5,
            origin.addingProduct(center, step) - 0.5,
            (origin - 0.5) + product,
            (origin - 0.5).addingProduct(center, step),
            origin + (product - 0.5),
            origin + (-Float(0.5)).addingProduct(center, step),
        ]
        #expect(legalGroupings.allSatisfy { $0 == 33_554_688 })
        #expect(legalGroupings.allSatisfy {
            Int($0) / tileSide == nextPage
        })

        let largeLimits = SparseTilePlanLimits(
            maximumPageEntries: nextPage + 1,
            maximumPageChunks: 4_096,
            maximumPageTableBytes: (nextPage + 1) * 32,
            maximumBindingSlots: 8,
            maximumBindingChunks: 8,
            maximumBindingBytes: 8 * 64,
            maximumTexturesPerBatch: 16,
            maximumBatchCount: 64
        )

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(
                outputOrigin,
                0,
                outputOrigin + 255,
                1
            ),
            limits: largeLimits
        )
        #expect(lease.content.bindingRecords.map(\.reference.coordinate) == [
            .init(x: nextPage - 1, y: 0),
            .init(x: nextPage, y: 0),
        ])
        try lease.retire()
    }

    @Test
    func fmaBoundaryHaloIncludesBothLegalFloatResultsOnBothAxesAndStepSigns()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let tileSide = PaintTileDescriptor.side
        let positiveOrigin: Float = 5_931.1797
        let positiveStep: Float = 17.014889
        let negativeOrigin: Float = 1_783.2158
        let negativeStep: Float = -17.014889

        // These literals independently characterize the reviewed boundary:
        // ordinary Float multiply+add lands on the page boundary while an
        // explicitly contracted operation lands one Float below it.
        #expect(positiveOrigin + Float(659.5) * positiveStep == 17_152.5)
        #expect(positiveOrigin.addingProduct(Float(659.5), positiveStep)
            == Float(17_152.5).nextDown)
        #expect(negativeOrigin + Float(14.5) * negativeStep == 1_536.5)
        #expect(negativeOrigin.addingProduct(Float(14.5), negativeStep)
            == Float(1_536.5).nextDown)

        struct Case {
            let size: PixelSize
            let coordinates: [PaintTileCoordinate]
            let region: SparseTileOutputRegion
            let transform: SparseTileOutputToSourceTransform
            let expected: [PaintTileCoordinate]
        }
        let cases = try [
            Case(
                size: PixelSize(width: 70 * tileSide, height: tileSide),
                coordinates: (65...69).map { .init(x: $0, y: 0) },
                region: region(0, 0, 660, 1),
                transform: .init(
                    sourceOffset: SIMD2(positiveOrigin, 0),
                    sourceStep: SIMD2(positiveStep, 1)
                ),
                expected: [.init(x: 66, y: 0), .init(x: 67, y: 0)]
            ),
            Case(
                size: PixelSize(width: tileSide, height: 70 * tileSide),
                coordinates: (65...69).map { .init(x: 0, y: $0) },
                region: region(0, 0, 1, 660),
                transform: .init(
                    sourceOffset: SIMD2(0, positiveOrigin),
                    sourceStep: SIMD2(1, positiveStep)
                ),
                expected: [.init(x: 0, y: 66), .init(x: 0, y: 67)]
            ),
            Case(
                size: PixelSize(width: 8 * tileSide, height: tileSide),
                coordinates: (4...7).map { .init(x: $0, y: 0) },
                region: region(0, 0, 15, 1),
                transform: .init(
                    sourceOffset: SIMD2(negativeOrigin, 0),
                    sourceStep: SIMD2(negativeStep, 1)
                ),
                expected: [
                    .init(x: 5, y: 0), .init(x: 6, y: 0),
                ]
            ),
            Case(
                size: PixelSize(width: tileSide, height: 8 * tileSide),
                coordinates: (4...7).map { .init(x: 0, y: $0) },
                region: region(0, 0, 1, 15),
                transform: .init(
                    sourceOffset: SIMD2(0, negativeOrigin),
                    sourceStep: SIMD2(1, negativeStep)
                ),
                expected: [
                    .init(x: 0, y: 5), .init(x: 0, y: 6),
                ]
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let fixture = try makeSource(
                device: device,
                pixelSize: testCase.size,
                coordinates: testCase.coordinates,
                addressing: .finite(testCase.size)
            )
            let cache = SparseTileSamplingPlanCache()
            if index < 2 {
                #expect(throws: SparseTileSamplingPlanError
                    .onePixelBatchExceedsTextureLimit(
                        required: 2,
                        maximum: 1
                    )) {
                    _ = try cache.acquire(
                        key: planKey(
                            layerID: fixture.layerID,
                            contentKeys: [fixture.request.contentKey],
                            outputToSourceTransform: testCase.transform
                        ),
                        sources: [fixture.request],
                        outputRegion: testCase.region,
                        limits: limits(maximumTexturesPerBatch: 1)
                    )
                }
                #expect(fixture.request.provider.backingSnapshot()
                    .activeLeaseCount == 0)
                continue
            }
            let lease = try cache.acquire(
                key: planKey(
                    layerID: fixture.layerID,
                    contentKeys: [fixture.request.contentKey],
                    outputToSourceTransform: testCase.transform
                ),
                sources: [fixture.request],
                outputRegion: testCase.region,
                limits: .testDefaults
            )
            #expect(lease.content.bindingRecords.map(\.reference.coordinate)
                == testCase.expected)
            try lease.retire()
        }
    }

    @Test
    func fastMathReassociationHaloCoversEveryFloatGroupingOnBothAxesAndSigns()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let center: Float = 39_844.5
        let positiveOrigin: Float = 338_030.75
        let positiveStep: Float = 242.9513
        let negativeOrigin: Float = 26_457_744
        let negativeStep: Float = -242.9513

        func legalGroupings(
            origin: Float,
            step: Float
        ) -> [Float] {
            let product = center * step
            return [
                (origin + product) - 0.5,
                origin.addingProduct(center, step) - 0.5,
                (origin - 0.5) + product,
                (origin - 0.5).addingProduct(center, step),
                origin + (product - 0.5),
                origin + (-Float(0.5)).addingProduct(center, step),
            ]
        }

        let positive = legalGroupings(
            origin: positiveOrigin,
            step: positiveStep
        )
        #expect(positive == [
            10_018_304, 10_018_304,
            10_018_303, 10_018_303,
            10_018_303, 10_018_303,
        ])
        #expect(positive.map { Int($0) / PaintTileDescriptor.side } == [
            39_134, 39_134, 39_133, 39_133, 39_133, 39_133,
        ])
        let negative = legalGroupings(
            origin: negativeOrigin,
            step: negativeStep
        )
        #expect(negative == [
            16_777_472, 16_777_472,
            16_777_472, 16_777_472,
            16_777_470, 16_777_472,
        ])
        #expect(negative.map { Int($0) / PaintTileDescriptor.side } == [
            65_537, 65_537, 65_537, 65_537, 65_536, 65_537,
        ])

        struct Case {
            let size: PixelSize
            let coordinates: [PaintTileCoordinate]
            let region: SparseTileOutputRegion
            let transform: SparseTileOutputToSourceTransform
        }
        let positivePageCount = 39_135
        let negativePageCount = 65_538
        let tileSide = PaintTileDescriptor.side
        let cases = try [
            Case(
                size: PixelSize(
                    width: positivePageCount * tileSide,
                    height: tileSide
                ),
                coordinates: [
                    .init(x: 39_133, y: 0), .init(x: 39_134, y: 0),
                ],
                region: region(0, 0, 39_845, 1),
                transform: .init(
                    sourceOffset: SIMD2(positiveOrigin, 0),
                    sourceStep: SIMD2(positiveStep, 1)
                )
            ),
            Case(
                size: PixelSize(
                    width: tileSide,
                    height: positivePageCount * tileSide
                ),
                coordinates: [
                    .init(x: 0, y: 39_133), .init(x: 0, y: 39_134),
                ],
                region: region(0, 0, 1, 39_845),
                transform: .init(
                    sourceOffset: SIMD2(0, positiveOrigin),
                    sourceStep: SIMD2(1, positiveStep)
                )
            ),
            Case(
                size: PixelSize(
                    width: negativePageCount * tileSide,
                    height: tileSide
                ),
                coordinates: [
                    .init(x: 65_536, y: 0), .init(x: 65_537, y: 0),
                ],
                region: region(0, 0, 39_845, 1),
                transform: .init(
                    sourceOffset: SIMD2(negativeOrigin, 0),
                    sourceStep: SIMD2(negativeStep, 1)
                )
            ),
            Case(
                size: PixelSize(
                    width: tileSide,
                    height: negativePageCount * tileSide
                ),
                coordinates: [
                    .init(x: 0, y: 65_536), .init(x: 0, y: 65_537),
                ],
                region: region(0, 0, 1, 39_845),
                transform: .init(
                    sourceOffset: SIMD2(0, negativeOrigin),
                    sourceStep: SIMD2(1, negativeStep)
                )
            ),
        ]
        let largeLimits = SparseTilePlanLimits(
            maximumPageEntries: 70_000,
            maximumPageChunks: 2_048,
            maximumPageTableBytes: 70_000 * 32,
            maximumBindingSlots: 8,
            maximumBindingChunks: 8,
            maximumBindingBytes: 8 * 64,
            maximumTexturesPerBatch: 1,
            maximumBatchCount: 256
        )
        for testCase in cases {
            let fixture = try makeSource(
                device: device,
                pixelSize: testCase.size,
                coordinates: testCase.coordinates,
                addressing: .finite(testCase.size)
            )
            #expect(throws: SparseTileSamplingPlanError
                .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
                _ = try SparseTileSamplingPlanCache().acquire(
                    key: planKey(
                        layerID: fixture.layerID,
                        contentKeys: [fixture.request.contentKey],
                        outputToSourceTransform: testCase.transform
                    ),
                    sources: [fixture.request],
                    outputRegion: testCase.region,
                    limits: largeLimits
                )
            }
            #expect(fixture.request.provider.backingSnapshot()
                .activeLeaseCount == 0)
        }
    }

    @Test
    func failedSelectedLeaseReturnRetainsOnlyHaloPinsUntilRetry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 1_024, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: (0..<4).map { .init(x: $0, y: 0) },
            addressing: .finite(size)
        )
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(255, 0),
            sourceStep: SIMD2(repeating: 1)
        )
        let probe = LeaseReturnProbe(failingAttempts: [1, 2])
        let cache = SparseTileSamplingPlanCache(returnLease: probe.call)
        var lease: SparseTileSamplingPlanLease? = try cache.acquire(
            key: planKey(
                layerID: fixture.layerID,
                contentKeys: [fixture.request.contentKey],
                outputToSourceTransform: transform
            ),
            sources: [fixture.request],
            outputRegion: try region(0, 0, 1, 1),
            limits: .testDefaults
        )

        #expect(throws: LeaseReturnProbe.InjectedError.failure) {
            try lease?.retire()
        }
        let failed = fixture.request.provider.backingSnapshot()
        #expect(failed.activeLeaseCount == 1)
        #expect(failed.entries.filter { !$0.pinCounts.isEmpty }
            .map(\.identity.coordinate).sorted() == [
                .init(x: 0, y: 0), .init(x: 1, y: 0),
            ])
        lease = nil
        try cache.retryPendingRetirements()
        let retired = fixture.request.provider.backingSnapshot()
        #expect(retired.activeLeaseCount == 0)
        #expect(retired.entries.allSatisfy { $0.pinCounts.isEmpty })
    }

    @Test
    func offscreenDeltaKeepsFullIdentityButReusesSelectedChunks() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let layerID = UUID()
        let surface = TiledRasterSurface(
            device: device,
            layerID: layerID,
            pixelSize: size,
            generation: 7,
            byteBudget: 2 * PaintTileDescriptor.residentByteCount
        )
        let initial = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(initial)
        try surface.returnLease(initial)
        let firstRequest = try SparseTileSourceRequest(
            contentKey: SparseTileRoleContentKey(
                role: .canonical,
                contentRevision: surface.revision.rawValue,
                bindingChunkRevision: surface.revision.rawValue
            ),
            addressing: .finite(size),
            provider: surface.makeExactReferenceProvider(),
            changedCoordinates: [.init(x: 0, y: 0)],
            disposition: .fullSnapshot
        )
        let cache = SparseTileSamplingPlanCache()
        let firstKey = planKey(
            layerID: layerID,
            contentKeys: [firstRequest.contentKey]
        )
        let firstOutput = try region(0, 0, 1, 1)
        let firstBatch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [firstRequest],
            key: firstKey,
            outputRegion: firstOutput
        )
        let first = try cache.acquire(
            key: firstKey,
            sourceBatch: firstBatch,
            outputRegion: firstOutput,
            limits: .testDefaults
        )

        let offscreen = try surface.reserveTiles(
            at: [.init(x: 1, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(offscreen)
        try surface.returnLease(offscreen)
        let secondRequest = try SparseTileSourceRequest(
            contentKey: SparseTileRoleContentKey(
                role: .canonical,
                contentRevision: surface.revision.rawValue,
                bindingChunkRevision: surface.revision.rawValue
            ),
            addressing: .finite(size),
            provider: surface.makeExactReferenceProvider(),
            changedCoordinates: [.init(x: 1, y: 0)],
            disposition: .delta
        )
        #expect(secondRequest.references.count == 2)
        let secondKey = planKey(
            layerID: layerID,
            contentKeys: [secondRequest.contentKey]
        )
        let secondOutput = try region(0, 0, 1, 1)
        let secondBatch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [secondRequest],
            key: secondKey,
            outputRegion: secondOutput
        )
        let retained = surface.backingSnapshot()
        #expect(retained.entries.filter { $0.snapshotRetainCount > 0 }
            .map(\.identity.coordinate) == [.init(x: 0, y: 0)])
        let second = try cache.acquire(
            key: secondKey,
            sourceBatch: secondBatch,
            outputRegion: secondOutput,
            limits: .testDefaults,
            updating: first.content
        )

        #expect(first.content.sourceFingerprints
            != second.content.sourceFingerprints)
        #expect(second.content.sourceFingerprints[0].references.count == 2)
        #expect(first.content.bindingChunks[0]
            === second.content.bindingChunks[0])
        #expect(first.content.pageTables[0].chunks[0]
            === second.content.pageTables[0].chunks[0])
        #expect(second.content.telemetry.rebuiltBindingCount == 0)
        #expect(second.content.telemetry.rebuiltPageEntryCount == 0)
        #expect(second.content.bindingRecords.map(\.reference.coordinate) == [
            .init(x: 0, y: 0),
        ])
        let pinned = surface.backingSnapshot().entries.filter {
            !$0.pinCounts.isEmpty
        }
        #expect(pinned.map(\.identity.coordinate) == [.init(x: 0, y: 0)])
        try first.retire()
        try second.retire()
    }

    @Test
    func moreThan512OffscreenReferencesDoNotConsumeSlotsOrLeases() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let count = 513
        let size = PixelSize(
            width: count * PaintTileDescriptor.side,
            height: PaintTileDescriptor.side
        )
        let layerID = UUID()
        let bytes = PaintTileDescriptor.residentByteCount
        let store = PaintTileStore(
            device: device,
            byteBudget: bytes,
            // One-in/one-out seeding owns the resident and replacement
            // textures, the persistent zero source, and one readback payload
            // in both staging and retained form at the transfer boundary.
            transferByteCapacity: bytes * 5,
            snapshotRetentionLimits: .init(
                maximumActiveTokenCount: count + 1,
                maximumReferencesPerToken: 65_536,
                maximumAggregateReferenceCount: count * 2,
                maximumIndexEntryCount: count,
                maximumMetadataBytes: 64 * 1_024 * 1_024,
                maximumPayloadDebtBytes: bytes * count
            )
        )
        let physical = TiledRasterSurface(
            store: store,
            layerID: layerID,
            pixelSize: size,
            generation: 7
        )
        let coordinates = (0..<count).map {
            PaintTileCoordinate(x: $0, y: 0)
        }
        var seedTokens: [PaintTileSnapshotToken] = []
        seedTokens.reserveCapacity(count)
        for coordinate in coordinates {
            let seed = try physical.reserveTiles(
                at: [coordinate],
                pinReasons: [.visible]
            )
            if coordinate == coordinates[0] {
                try physical.markDirty(seed)
            }
            let reference = try #require(physical.references.last)
            seedTokens.append(try store.retainSnapshotReferences([reference]))
            try physical.returnLease(seed)
        }
        let references = physical.references
        #expect(references.count == count)
        let request = try SparseTileSourceRequest(
            contentKey: SparseTileRoleContentKey(
                role: .canonical,
                contentRevision: 1,
                bindingChunkRevision: 1
            ),
            addressing: .finite(size),
            provider: physical.makeExactReferenceProvider(),
            changedCoordinates: coordinates,
            disposition: .fullSnapshot
        )
        let cache = SparseTileSamplingPlanCache()
        let key = planKey(layerID: layerID, contentKeys: [request.contentKey])
        let output = try region(0, 0, 1, 1)
        let beforeCapture = store.snapshot()
        let sourceBatch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [request],
            key: key,
            outputRegion: output
        )
        let captured = store.snapshot()
        #expect(captured.activeSnapshotTokenCount
            == beforeCapture.activeSnapshotTokenCount + 1)
        #expect(captured.aggregateSnapshotReferenceCount
            == beforeCapture.aggregateSnapshotReferenceCount + 1)
        for token in seedTokens { token.close() }
        let selectedOnly = store.snapshot()
        #expect(selectedOnly.activeSnapshotTokenCount == 1)
        #expect(selectedOnly.aggregateSnapshotReferenceCount == 1)
        #expect(selectedOnly.snapshotPayloadDebtByteCount <= bytes)
        let lease = try cache.acquire(
            key: key,
            sourceBatch: sourceBatch,
            outputRegion: output,
            limits: limits(maximumBindingSlots: 1)
        )

        #expect(lease.content.bindingRecords.map(\.reference.coordinate) == [
            .init(x: 0, y: 0),
        ])
        #expect(store.snapshot().activeLeaseCount == 1)

        try lease.retire()
        #expect(store.snapshot().activeLeaseCount == 0)
    }

    @Test
    func periodicSelectionWrapsNegativeAndMaximumHaloToPhysicalEdges() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let period = PixelSize(width: 768, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: period,
            coordinates: (0..<3).map { .init(x: $0, y: 0) },
            addressing: .periodic(period: period)
        )
        for output in [
            try region(-1, 0, 0, 1),
            try region(767, 0, 768, 1),
        ] {
            let lease = try SparseTileSamplingPlanCache().acquire(
                key: fixture.key,
                sources: [fixture.request],
                outputRegion: output,
                limits: .testDefaults
            )
            #expect(lease.content.bindingRecords.map(\.reference.coordinate) == [
                .init(x: 0, y: 0), .init(x: 2, y: 0),
            ])
            try lease.retire()
        }
    }

    @Test
    func radialSelectionMapsLogicalResidentPageToPhysicalAtlasReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 768,
            sectorAngleRadians: .pi
        )
        let logical = try #require(layout.residentPages.first {
            $0.coordinate.x < 0 && $0.coordinate.y >= 0
        })
        let selected = PaintTileCoordinate(
            x: logical.atlasSlot % layout.atlasColumns,
            y: logical.atlasSlot / layout.atlasColumns
        )
        let unrelatedPage = try #require(layout.residentPages.first {
            $0.atlasSlot != logical.atlasSlot
        })
        let unrelated = PaintTileCoordinate(
            x: unrelatedPage.atlasSlot % layout.atlasColumns,
            y: unrelatedPage.atlasSlot / layout.atlasColumns
        )
        let fixture = try makeSource(
            device: device,
            pixelSize: layout.atlasPixelSize,
            coordinates: [selected, unrelated].sorted(),
            addressing: .radial(layout: layout)
        )
        let x = logical.coordinate.x * PaintTileDescriptor.side + 17
        let y = logical.coordinate.y * PaintTileDescriptor.side + 17
        let lease = try SparseTileSamplingPlanCache().acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(x, y, x + 1, y + 1),
            limits: .testDefaults
        )
        #expect(lease.content.bindingRecords.map(\.reference.coordinate) == [
            selected,
        ])
        try lease.retire()
    }

    @Test
    func cacheSourceSelectsBeforeReservationAndCannotLeaseWholeSnapshot()
        throws
    {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/MetalRenderer/Compositing/SparseTileSamplingPlan.swift"
            ),
            encoding: .utf8
        )
        #expect(!source.contains("at: references.map(\\.coordinate)"))
        #expect(!source.contains("surface: TiledRasterSurface"))
        #expect(!source.contains("leaseExistingTiles("))
        #expect(!source.contains("selectedReferences.map(\\.coordinate)"))
        #expect(!source.contains(
            "sources: [SparseTileSourceRequest],\n        outputRegion:"
        ))
        let heldLease = try #require(source.range(
            of: "private struct SparseTileHeldLease"
        ))
        let cache = try #require(source.range(
            of: "final class SparseTileSamplingPlanCache"
        ))
        let heldLeaseSource = source[heldLease.lowerBound..<cache.lowerBound]
        #expect(!heldLeaseSource.contains("TiledRasterSurface"))
        #expect(!heldLeaseSource.contains("PaintTileLease"))
        let selection = try #require(source.range(of: "let selectedMetadata"))
        let reservation = try #require(source.range(of: "reserveSlotsLocked("))
        #expect(selection.lowerBound < reservation.lowerBound)
    }

    @Test
    func sourceOrderIsLayerThenFixedRoleAndRejectedBeforeLease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let before = prediction.provider.backingSnapshot()
        let key = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, prediction.contentKey]
        )

        #expect(throws: SparseTileSamplingPlanError.sourceOrderMismatch) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sources: [prediction, canonical],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        #expect(prediction.provider.backingSnapshot() == before)
    }

    @Test
    func cacheReusesContentButAcquiresAndReturnsFreshCompleteVisibleLeases()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 512, 256),
            limits: .testDefaults
        )
        let second = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 512, 256),
            limits: .testDefaults
        )

        #expect(first.content === second.content)
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 2)
        try first.retire()
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 1)
        try second.retire()
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
        #expect(throws: SparseTileSamplingPlanError.leaseAlreadyRetired) {
            try second.retire()
        }
    }

    @Test
    func sameLogicalKeyCachesTwoOutputRegionsAndReusesEachIndependently()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        let firstRegion = try region(0, 0, 1, 1)
        let secondRegion = try region(300, 0, 301, 1)
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: firstRegion,
            limits: .testDefaults
        )
        let second = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: secondRegion,
            limits: .testDefaults
        )
        let firstHit = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: firstRegion,
            limits: .testDefaults
        )
        let secondHit = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: secondRegion,
            limits: .testDefaults
        )
        #expect(first.content !== second.content)
        #expect(firstHit.content === first.content)
        #expect(secondHit.content === second.content)
        #expect(first.content.key == second.content.key)
        let cacheEvidence = cache.snapshot()
        #expect(cacheEvidence.hitCount == 2)
        #expect(cacheEvidence.missCount == 2)
        for lease in [first, second, firstHit, secondHit] {
            try lease.retire()
        }
    }

    @Test
    func exactRegionEvictionDoesNotDisturbNeighborRegion() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        let firstRegion = try region(0, 0, 1, 1)
        let secondRegion = try region(300, 0, 301, 1)
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: firstRegion,
            limits: .testDefaults
        )
        let second = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: secondRegion,
            limits: .testDefaults
        )
        #expect(cache.snapshot().cachedContentCount == 2)
        #expect(cache.evictContent(
            key: fixture.key,
            outputRegion: firstRegion
        ))
        #expect(cache.snapshot().cachedContentCount == 1)
        #expect(!cache.evictContent(
            key: fixture.key,
            outputRegion: firstRegion
        ))
        let rebuiltFirst = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: firstRegion,
            limits: .testDefaults
        )
        let retainedSecond = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: secondRegion,
            limits: .testDefaults
        )
        #expect(rebuiltFirst.content !== first.content)
        #expect(retainedSecond.content === second.content)
        #expect(cache.snapshot().cachedContentCount == 2)
        for lease in [first, second, rebuiltFirst, retainedSecond] {
            try lease.retire()
        }
    }

    @Test
    func exactEvictionCannotBeUndoneByPreEvictionInflightAcquire()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let output = try region(0, 0, 1, 1)
        let barrier = ArmedSparsePlanBarrier()
        let cache = SparseTileSamplingPlanCache(
            beforePublication: barrier.pauseIfArmed
        )
        let seeded = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        barrier.arm()
        let inflight = Task.detached {
            try cache.acquire(
                key: fixture.key,
                sources: [fixture.request],
                outputRegion: output,
                limits: .testDefaults
            )
        }
        try await barrier.waitUntilPaused()
        #expect(cache.evictContent(key: fixture.key, outputRegion: output))
        barrier.resume()
        let stale = try await inflight.value
        let rebuilt = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(stale.content === seeded.content)
        #expect(rebuilt.content !== seeded.content)
        for lease in [seeded, stale, rebuilt] { try lease.retire() }
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
        #expect(cache.pendingRetirementCount == 0)
        #expect(cache.testingActiveContentIdentityCount == 0)
    }

    @Test
    func cacheSnapshotCountsConcurrentAcquiresNotOnlyDistinctIdentities()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let output = try region(0, 0, 1, 1)
        let barrier = CountedSparsePlanBarrier(expected: 2)
        let cache = SparseTileSamplingPlanCache(
            beforePublication: barrier.pause
        )
        let first = Task.detached {
            try cache.acquire(
                key: fixture.key,
                sources: [fixture.request],
                outputRegion: output,
                limits: .testDefaults
            )
        }
        let second = Task.detached {
            try cache.acquire(
                key: fixture.key,
                sources: [fixture.request],
                outputRegion: output,
                limits: .testDefaults
            )
        }
        try await barrier.waitUntilAllPaused()
        let active = cache.snapshot()
        #expect(active.activeContentAcquisitionCount == 2)
        #expect(active.pendingRetirementCount == 2)
        barrier.resumeAll()
        let leases = try await [first.value, second.value]
        for lease in leases { try lease.retire() }
        let terminal = cache.snapshot()
        #expect(terminal.cachedContentCount == 1)
        #expect(terminal.activeContentAcquisitionCount == 0)
        #expect(terminal.pendingRetirementCount == 0)
    }

    @Test
    func generationInvalidationRemovesEveryRegionForLogicalKey() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        let firstRegion = try region(0, 0, 1, 1)
        let secondRegion = try region(300, 0, 301, 1)
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: firstRegion,
            limits: .testDefaults
        )
        let second = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: secondRegion,
            limits: .testDefaults
        )
        cache.invalidate(documentGeneration: fixture.key.documentGeneration)
        let rebuiltFirst = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: firstRegion,
            limits: .testDefaults
        )
        let rebuiltSecond = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: secondRegion,
            limits: .testDefaults
        )
        #expect(rebuiltFirst.content !== first.content)
        #expect(rebuiltSecond.content !== second.content)
        #expect(rebuiltFirst.content !== rebuiltSecond.content)
        for lease in [first, second, rebuiltFirst, rebuiltSecond] {
            try lease.retire()
        }
    }

    @Test
    func cacheKeyCollisionIsRejectedBeforeLeasingDifferentReferences() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let firstRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 11
        )
        let collision = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 11
        )
        let key = planKey(layerID: layerID, contentKeys: [firstRequest.contentKey])
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: key,
            sources: [firstRequest],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        defer { try? first.retire() }
        let before = collision.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.contentKeyCollision) {
            _ = try cache.acquire(
                key: key,
                sources: [collision],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        #expect(collision.provider.backingSnapshot() == before)
    }

    @Test
    func deltaUpdateKeepsSlotsAndReusesUnaffectedRoleChunks() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonicalV1 = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let canonicalV2 = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 2,
            disposition: .delta
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let firstKey = planKey(
            layerID: layerID,
            contentKeys: [canonicalV1.contentKey, prediction.contentKey]
        )
        let secondKey = planKey(
            layerID: layerID,
            contentKeys: [canonicalV2.contentKey, prediction.contentKey]
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: firstKey,
            sources: [canonicalV1, prediction],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        let second = try cache.acquire(
            key: secondKey,
            sources: [canonicalV2, prediction],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults,
            updating: first.content
        )
        defer {
            try? first.retire()
            try? second.retire()
        }

        let firstCanonical = try #require(first.content.bindingRecords.first {
            $0.role == .canonical
        })
        let secondCanonical = try #require(second.content.bindingRecords.first {
            $0.role == .canonical
        })
        #expect(firstCanonical.globalSlot == secondCanonical.globalSlot)
        #expect(firstCanonical.reference != secondCanonical.reference)
        let firstPredictionTable = try #require(first.content.pageTable(
            layerID: layerID, role: .prediction
        ))
        let secondPredictionTable = try #require(second.content.pageTable(
            layerID: layerID, role: .prediction
        ))
        #expect(firstPredictionTable.chunks[0]
            === secondPredictionTable.chunks[0])
        let firstPredictionChunk = try #require(first.content.bindingChunks.first {
            $0.layerID == layerID && $0.role == .prediction
        })
        let secondPredictionChunk = try #require(second.content.bindingChunks.first {
            $0.layerID == layerID && $0.role == .prediction
        })
        #expect(firstPredictionChunk === secondPredictionChunk)
        #expect(second.content.telemetry.rebuiltPageEntryCount == 1)
        #expect(second.content.telemetry.rebuiltBindingCount == 1)
    }

    @Test
    func inFlightConsumersKeepLeasesPinnedAcrossCacheInvalidationUntilFinalAck()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let lease = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        let first = try lease.beginConsumer()
        let second = try lease.beginConsumer()
        cache.invalidate(documentGeneration: fixture.key.documentGeneration)
        try lease.retire()
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 1)

        try lease.completeConsumer(second)
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 1)
        try lease.completeConsumer(first)
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
        #expect(throws: SparseTileSamplingPlanError.staleConsumer) {
            try lease.completeConsumer(first)
        }
    }

    @Test
    func overlappingPlanUnionCannotAllocateGlobalSlot512BeforeLeasing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let pixelSize = PixelSize(
            width: 513 * PaintTileDescriptor.side,
            height: PaintTileDescriptor.side
        )
        let oldContentKey = SparseTileRoleContentKey(
            role: .canonical,
            contentRevision: 1,
            bindingChunkRevision: 1
        )
        let oldReferences = try makeMetadataReferences(
            layerID: layerID,
            pixelSize: pixelSize,
            coordinates: (0..<512).map { .init(x: $0, y: 0) }
        )
        let oldSnapshot = try SparseTileSourceSnapshot(
            contentKey: oldContentKey,
            addressing: .finite(pixelSize),
            layerID: layerID,
            references: oldReferences,
            changedCoordinates: oldReferences.map(\.coordinate),
            disposition: .fullSnapshot
        )
        let oldContent = try SparseTileSamplingPlanBuilder.buildFull(
            key: planKey(layerID: layerID, contentKeys: [oldContentKey]),
            sources: [oldSnapshot],
            outputRegion: try region(
                0,
                0,
                512 * PaintTileDescriptor.side,
                PaintTileDescriptor.side
            ),
            limits: limits(maximumBindingSlots: 512)
        )
        #expect(oldContent.bindingRecords.map(\.globalSlot) == Array(0..<512))

        let replacement = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: pixelSize,
            coordinates: [.init(x: 512, y: 0)],
            addressing: .finite(pixelSize),
            contentRevision: 2,
            disposition: .delta
        )
        let before = replacement.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.bindingSlotLimitExceeded(
            required: 513,
            maximum: 512
        )) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [replacement.contentKey]
                ),
                sources: [replacement],
                outputRegion: try region(
                    512 * PaintTileDescriptor.side,
                    0,
                    513 * PaintTileDescriptor.side,
                    PaintTileDescriptor.side
                ),
                limits: limits(maximumBindingSlots: 512),
                updating: oldContent
            )
        }
        #expect(replacement.provider.backingSnapshot() == before)
    }

    @Test
    func integerNeighborResolutionExposesFixedRoleOrderBeforeBilinearMix()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let key = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, prediction.contentKey]
        )
        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [canonical, prediction],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        let resolution = try SparseTileCPUReferenceSampler.resolveFourNeighbors(
            at: SIMD2(8.75, 9.25),
            content: lease.content
        )

        #expect(lease.boundTextures.count == 2)
        #expect(ObjectIdentifier(lease.boundTextures[0].texture as AnyObject)
            != ObjectIdentifier(lease.boundTextures[1].texture as AnyObject))
        #expect(resolution.fraction == SIMD2<Float>(0.25, 0.75))
        #expect(resolution.neighbors.map(\.logicalPixel) == [
            SIMD2(8, 8), SIMD2(9, 8), SIMD2(8, 9), SIMD2(9, 9),
        ])
        #expect(resolution.neighbors.allSatisfy {
            $0.contributions.map(\.role) == [.canonical, .prediction]
                && $0.contributions.map(\.globalBindingSlot) == [0, 1]
        })
    }

    @Test
    func declaredRoleOrderCannotOverrideCanonicalAuthoritativePredictionOrder()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let reversedKey = planKey(
            layerID: layerID,
            contentKeys: [prediction.contentKey, canonical.contentKey]
        )
        let before = canonical.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.contentRoleMismatch) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: reversedKey,
                sources: [prediction, canonical],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        #expect(canonical.provider.backingSnapshot() == before)
    }

    @Test
    func normalizedSnapshotRejectsUnsortedDuplicateAndForeignReferences()
        throws
    {
        let layerID = UUID()
        let size = PixelSize(width: 512, height: 256)
        let references = try makeMetadataReferences(
            layerID: layerID,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)]
        )
        let key = SparseTileRoleContentKey(
            role: .canonical,
            contentRevision: 1,
            bindingChunkRevision: 1
        )

        #expect(throws: SparseTileSamplingPlanError.unsortedReference) {
            _ = try SparseTileSourceSnapshot(
                contentKey: key,
                addressing: .finite(size),
                layerID: layerID,
                references: Array(references.reversed()),
                changedCoordinates: [],
                disposition: .fullSnapshot
            )
        }
        #expect(throws: SparseTileSamplingPlanError.duplicateReference(
            references[0].coordinate
        )) {
            _ = try SparseTileSourceSnapshot(
                contentKey: key,
                addressing: .finite(size),
                layerID: layerID,
                references: [references[0], references[0]],
                changedCoordinates: [],
                disposition: .fullSnapshot
            )
        }
        #expect(throws: SparseTileSamplingPlanError.foreignReference(
            references[0]
        )) {
            _ = try SparseTileSourceSnapshot(
                contentKey: key,
                addressing: .finite(size),
                layerID: UUID(),
                references: [references[0]],
                changedCoordinates: [],
                disposition: .fullSnapshot
            )
        }
        let foreignStoreReference = PaintTileReference(
            storeIdentity: PaintTileStoreIdentity(),
            physicalSurfaceID: references[1].physicalSurfaceID,
            layerID: references[1].layerID,
            physicalGeneration: references[1].physicalGeneration,
            identity: references[1].identity,
            descriptor: references[1].descriptor
        )
        #expect(throws: SparseTileSamplingPlanError.foreignReference(
            foreignStoreReference
        )) {
            _ = try SparseTileSourceSnapshot(
                contentKey: key,
                addressing: .finite(size),
                layerID: layerID,
                references: [references[0], foreignStoreReference],
                changedCoordinates: [],
                disposition: .fullSnapshot
            )
        }
    }

    @Test
    func acceptedCanonicalAndTransientAdaptersPreserveExactVisibleMetadata()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let layerID = UUID()
        func seededSurface(
            _ coordinates: [PaintTileCoordinate]
        ) throws -> TiledRasterSurface {
            let surface = TiledRasterSurface(
                device: device,
                layerID: layerID,
                pixelSize: size,
                generation: 7,
                byteBudget: max(1, coordinates.count)
                    * PaintTileDescriptor.residentByteCount
            )
            let seed = try surface.reserveTiles(
                at: coordinates,
                pinReasons: [.dirty]
            )
            try surface.markDirty(seed)
            try surface.returnLease(seed)
            return surface
        }
        let canonicalSurface = try seededSurface([
            .init(x: 0, y: 0), .init(x: 1, y: 0),
        ])
        let binding = DocumentPaintLayerBinding(
            layerID: layerID,
            generation: canonicalSurface.generation,
            canonical: canonicalSurface
        )
        let canonical = try binding.sparseTileSourceRequest(
            addressing: .finite(size)
        )
        #expect(canonical.role == .canonical)
        #expect(canonical.disposition == .fullSnapshot)
        #expect(canonical.changedCoordinates
            == canonical.provider.references.map(\.coordinate))

        let authoritative = try seededSurface([.init(x: 0, y: 0)])
        let prediction = try seededSurface([.init(x: 1, y: 0)])
        let transient = try SparseTileAcceptedSourceAdapter.transient(
            layerID: layerID,
            authoritative: authoritative,
            prediction: prediction,
            changedRole: .prediction,
            changedCoordinates: [.init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        #expect(transient.map(\.role) == [.authoritative, .prediction])
        #expect(transient[0].changedCoordinates.isEmpty)
        #expect(transient[1].changedCoordinates == [.init(x: 1, y: 0)])
        #expect(transient.allSatisfy { $0.disposition == .delta })
    }

    @Test
    func failedUpdateLeavesPreviousCachedContentCurrentAndUnleased() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let firstKey = planKey(
            layerID: layerID, contentKeys: [canonical.contentKey]
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: firstKey,
            sources: [canonical],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let failingKey = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, prediction.contentKey]
        )
        let predictionBefore = prediction.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try cache.acquire(
                key: failingKey,
                sources: [canonical, prediction],
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumTexturesPerBatch: 1),
                updating: first.content
            )
        }
        #expect(prediction.provider.backingSnapshot() == predictionBefore)
        let reacquired = try cache.acquire(
            key: firstKey,
            sources: [canonical],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        #expect(reacquired.content === first.content)
        try reacquired.retire()
        try first.retire()
    }

    @Test
    func cacheRejectsDisjointPlanWhenLiveGlobalSlotUnionCannotFit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 768, height: 256)
        let layerID = UUID()
        let firstRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let disjoint = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 2, y: 0)],
            addressing: .finite(size),
            contentRevision: 2
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: planKey(layerID: layerID, contentKeys: [firstRequest.contentKey]),
            sources: [firstRequest],
            outputRegion: try region(0, 0, 512, 256),
            limits: limits(maximumBindingSlots: 2)
        )
        defer { try? first.retire() }
        let before = disjoint.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.bindingSlotLimitExceeded(
            required: 3,
            maximum: 2
        )) {
            _ = try cache.acquire(
                key: planKey(layerID: layerID, contentKeys: [disjoint.contentKey]),
                sources: [disjoint],
                outputRegion: try region(512, 0, 768, 256),
                limits: limits(maximumBindingSlots: 2)
            )
        }
        #expect(disjoint.provider.backingSnapshot() == before)
    }

    @Test
    func cacheHitStillHonorsStricterBatchLimitsBeforeLeasing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let key = planKey(
            layerID: layerID,
            contentKeys: [canonical.contentKey, prediction.contentKey]
        )
        let cache = SparseTileSamplingPlanCache()
        let first = try cache.acquire(
            key: key,
            sources: [canonical, prediction],
            outputRegion: try region(0, 0, 1, 1),
            limits: .testDefaults
        )
        defer { try? first.retire() }
        let before = prediction.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try cache.acquire(
                key: key,
                sources: [canonical, prediction],
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumTexturesPerBatch: 1)
            )
        }
        #expect(prediction.provider.backingSnapshot() == before)
    }

    @Test
    func sourceRequestCapturesExactReferencesBeforeLaterSurfaceMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let layerID = UUID()
        let surface = TiledRasterSurface(
            device: device,
            layerID: layerID,
            pixelSize: size,
            generation: 7,
            byteBudget: 4 * PaintTileDescriptor.residentByteCount
        )
        let initial = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(initial)
        try surface.returnLease(initial)
        let request = try SparseTileSourceRequest(
            contentKey: SparseTileRoleContentKey(
                role: .canonical,
                contentRevision: surface.revision.rawValue,
                bindingChunkRevision: 1
            ),
            addressing: .finite(size),
            provider: surface.makeExactReferenceProvider(),
            changedCoordinates: [.init(x: 0, y: 0)],
            disposition: .fullSnapshot
        )
        let key = planKey(layerID: layerID, contentKeys: [request.contentKey])
        let later = try surface.reserveTiles(
            at: [.init(x: 1, y: 0)], pinReasons: [.dirty]
        )
        try surface.markDirty(later)
        try surface.returnLease(later)

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [request],
            outputRegion: try region(0, 0, 512, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }

        #expect(surface.references.count == 2)
        #expect(lease.content.bindingRecords.map(\.reference.coordinate)
            == [.init(x: 0, y: 0)])
    }

    @Test
    func publishedPartialCOWCanonicalLeasesMixedPhysicalNamespacesExactly()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID()
        let size = PixelSize(width: 512, height: 256)
        let registry = try DocumentPaintSurfaceStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount * 4,
            geometry: DocumentPaintGeometry(
                documentPixelSize: size,
                storagePixelSize: size,
                radialLayout: nil
            ),
            layerIDs: [layerID],
            generation: 7
        )
        let coordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ]
        let initial = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layerID: coordinates]
        )
        registry.commitPrepared(try registry.prepareCommit(initial))
        let before = try registry.binding(for: layerID).canonical.references

        let changed = try registry.makeCandidate(
            dirtyCoordinatesByLayer: [layerID: [coordinates[1]]]
        )
        registry.commitPrepared(try registry.prepareCommit(changed))
        let binding = try registry.binding(for: layerID)
        let expected = binding.canonical.references
        #expect(expected.count == 2)
        #expect(expected[0] == before[0])
        #expect(expected[1].identity != before[1].identity)
        #expect(expected[0].physicalSurfaceID != expected[1].physicalSurfaceID)

        let request = try binding.sparseTileSourceRequest(
            addressing: .finite(size)
        )
        let key = planKey(
            layerID: layerID,
            contentKeys: [request.contentKey]
        )
        let fullOutput = try region(0, 0, 512, 1)
        let batch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [request],
            key: key,
            outputRegion: fullOutput
        )
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)
        let lease = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sourceBatch: batch,
            outputRegion: fullOutput,
            limits: .testDefaults
        )
        #expect(lease.content.bindingRecords.map(\.reference) == expected)
        #expect(lease.boundTextures.count == 2)
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 1)
        try lease.retire()
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 0)

        let oneSideOutput = try region(300, 10, 301, 11)
        let oneSideBatch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [request],
            key: key,
            outputRegion: oneSideOutput
        )
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 1)
        let oneSide = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sourceBatch: oneSideBatch,
            outputRegion: oneSideOutput,
            limits: .testDefaults
        )
        #expect(oneSide.content.bindingRecords.map(\.reference) == [expected[1]])
        #expect(oneSide.content.bindingRecords[0].reference.identity
            == expected[1].identity)
        #expect(oneSide.boundTextures.count == 1)
        #expect(registry.sharedTileStore.snapshot().activeSnapshotTokenCount == 0)
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 1)
        try oneSide.retire()
        #expect(registry.sharedTileStore.snapshot().activeLeaseCount == 0)
    }

    @Test
    func ownedSourceBatchClosesBeforePublicationRejectsReuseAndFreshHitWorks()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bytes = PaintTileDescriptor.residentByteCount
        let store = PaintTileStore(device: device, byteBudget: bytes)
        let layerID = UUID()
        let size = PixelSize(width: 256, height: 256)
        let surface = TiledRasterSurface(
            store: store,
            layerID: layerID,
            pixelSize: size,
            generation: 7
        )
        let seed = try surface.reserveTiles(
            at: [.init(x: 0, y: 0)],
            pinReasons: [.dirty]
        )
        try surface.markDirty(seed)
        try surface.returnLease(seed)
        let request = try SparseTileSourceRequest(
            contentKey: SparseTileRoleContentKey(
                role: .canonical,
                surfaceIdentity: surface.surfaceID,
                contentRevision: surface.revision.rawValue,
                bindingChunkRevision: surface.revision.rawValue
            ),
            addressing: .finite(size),
            provider: surface.makeExactReferenceProvider(),
            changedCoordinates: [.init(x: 0, y: 0)],
            disposition: .fullSnapshot
        )
        let key = planKey(
            layerID: layerID,
            contentKeys: [request.contentKey]
        )
        let output = try region(0, 0, 1, 1)
        let firstBatch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [request], key: key, outputRegion: output
        )
        #expect(store.snapshot().activeSnapshotTokenCount == 1)
        let beforePublicationProbe = IntegerProbe()
        let cache = SparseTileSamplingPlanCache(beforePublication: {
            beforePublicationProbe.record(
                store.snapshot().activeSnapshotTokenCount
            )
        })
        let first = try cache.acquire(
            key: key,
            sourceBatch: firstBatch,
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(beforePublicationProbe.value == 0)
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
        #expect(throws: SparseTileSamplingPlanError.sourceBatchConsumed) {
            _ = try cache.acquire(
                key: key,
                sourceBatch: firstBatch,
                outputRegion: output,
                limits: .testDefaults
            )
        }

        let freshBatch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [request], key: key, outputRegion: output
        )
        let hit = try cache.acquire(
            key: key,
            sourceBatch: freshBatch,
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(hit.content === first.content)
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
        try first.retire()
        try hit.retire()
    }

    @Test
    func partialProviderAcquisitionFailureClosesTokenReturnsLeaseAndRetries()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bytes = PaintTileDescriptor.residentByteCount
        let store = PaintTileStore(device: device, byteBudget: bytes * 2)
        let layerID = UUID()
        let size = PixelSize(width: 256, height: 256)
        var requests: [SparseTileSourceRequest] = []
        for role in [SparseTileSampleRole.canonical, .prediction] {
            let surface = TiledRasterSurface(
                store: store,
                layerID: layerID,
                pixelSize: size,
                generation: 7
            )
            let seed = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)],
                pinReasons: [.dirty]
            )
            try surface.markDirty(seed)
            try surface.returnLease(seed)
            requests.append(try SparseTileSourceRequest(
                contentKey: SparseTileRoleContentKey(
                    role: role,
                    surfaceIdentity: surface.surfaceID,
                    contentRevision: surface.revision.rawValue,
                    bindingChunkRevision: surface.revision.rawValue
                ),
                addressing: .finite(size),
                provider: surface.makeExactReferenceProvider(),
                changedCoordinates: [.init(x: 0, y: 0)],
                disposition: .fullSnapshot
            ))
        }
        let key = planKey(
            layerID: layerID,
            contentKeys: requests.map(\.contentKey)
        )
        let output = try region(0, 0, 1, 1)
        let batch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: requests, key: key, outputRegion: output
        )
        #expect(store.snapshot().activeSnapshotTokenCount == 1)
        let cache = SparseTileSamplingPlanCache(
            sourceLeaseFailureInjector: { index in
                if index == 1 {
                    throw SparseTileSamplingPlanError
                        .injectedSourceLeaseFailure(index)
                }
            }
        )
        #expect(throws: SparseTileSamplingPlanError
            .injectedSourceLeaseFailure(1)) {
            _ = try cache.acquire(
                key: key,
                sourceBatch: batch,
                outputRegion: output,
                limits: .testDefaults
            )
        }
        let failed = store.snapshot()
        #expect(failed.activeSnapshotTokenCount == 0)
        #expect(failed.activeLeaseCount == 0)
        #expect(cache.pendingRetirementCount == 0)

        let retry = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sourceBatch: SparseTileOwnedSourceBatch.capturingSelection(
                sources: requests, key: key, outputRegion: output
            ),
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(store.snapshot().activeSnapshotTokenCount == 0)
        try retry.retire()
        #expect(store.snapshot().activeLeaseCount == 0)
    }

    @Test
    func boundTextureAndPublicationFailuresCloseAllOwnershipAndRetry()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        enum Stage: CaseIterable { case boundTexture, publication }
        for stage in Stage.allCases {
            let bytes = PaintTileDescriptor.residentByteCount
            let store = PaintTileStore(device: device, byteBudget: bytes)
            let layerID = UUID()
            let size = PixelSize(width: 256, height: 256)
            let surface = TiledRasterSurface(
                store: store,
                layerID: layerID,
                pixelSize: size,
                generation: 7
            )
            let seed = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)],
                pinReasons: [.dirty]
            )
            try surface.markDirty(seed)
            try surface.returnLease(seed)
            let request = try SparseTileSourceRequest(
                contentKey: SparseTileRoleContentKey(
                    role: .canonical,
                    surfaceIdentity: surface.surfaceID,
                    contentRevision: surface.revision.rawValue,
                    bindingChunkRevision: surface.revision.rawValue
                ),
                addressing: .finite(size),
                provider: surface.makeExactReferenceProvider(),
                changedCoordinates: [.init(x: 0, y: 0)],
                disposition: .fullSnapshot
            )
            let key = planKey(
                layerID: layerID,
                contentKeys: [request.contentKey]
            )
            let output = try region(0, 0, 1, 1)
            let cache = SparseTileSamplingPlanCache(
                boundTextureFailureInjector: {
                    if stage == .boundTexture {
                        throw SparseTileSamplingPlanError
                            .injectedBoundTextureFailure
                    }
                },
                afterContentPublication: {
                    if stage == .publication {
                        throw SparseTileSamplingPlanError
                            .injectedContentPublicationFailure
                    }
                }
            )
            let expected: SparseTileSamplingPlanError = stage == .boundTexture
                ? .injectedBoundTextureFailure
                : .injectedContentPublicationFailure
            #expect(throws: expected) {
                _ = try cache.acquire(
                    key: key,
                    sourceBatch: SparseTileOwnedSourceBatch.capturingSelection(
                        sources: [request], key: key, outputRegion: output
                    ),
                    outputRegion: output,
                    limits: .testDefaults
                )
            }
            let failed = store.snapshot()
            #expect(failed.activeSnapshotTokenCount == 0)
            #expect(failed.activeLeaseCount == 0)
            #expect(cache.pendingRetirementCount == 0)

            let retry = try SparseTileSamplingPlanCache().acquire(
                key: key,
                sourceBatch: SparseTileOwnedSourceBatch.capturingSelection(
                    sources: [request], key: key, outputRegion: output
                ),
                outputRegion: output,
                limits: .testDefaults
            )
            try retry.retire()
        }
    }

    @Test
    func threeRoleBatchSharesOneTokenAndClosesItBeforePublication() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = PaintTileStore(
            device: device,
            byteBudget: PaintTileDescriptor.residentByteCount * 3
        )
        let layerID = UUID()
        let size = PixelSize(width: 256, height: 256)
        var requests: [SparseTileSourceRequest] = []
        for role in SparseTileSampleRole.allCases {
            let surface = TiledRasterSurface(
                store: store,
                layerID: layerID,
                pixelSize: size,
                generation: 7
            )
            let seed = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)],
                pinReasons: [.dirty]
            )
            try surface.markDirty(seed)
            try surface.returnLease(seed)
            requests.append(try SparseTileSourceRequest(
                contentKey: .init(
                    role: role,
                    surfaceIdentity: surface.surfaceID,
                    contentRevision: surface.revision.rawValue,
                    bindingChunkRevision: surface.revision.rawValue
                ),
                addressing: .finite(size),
                provider: surface.makeExactReferenceProvider(),
                changedCoordinates: [.init(x: 0, y: 0)],
                disposition: .fullSnapshot
            ))
        }
        let key = planKey(
            layerID: layerID,
            contentKeys: requests.map(\.contentKey)
        )
        let output = try region(0, 0, 1, 1)
        let batch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: requests, key: key, outputRegion: output
        )
        var retained = store.snapshot()
        #expect(retained.activeSnapshotTokenCount == 1)
        #expect(retained.aggregateSnapshotReferenceCount == 3)
        let probe = IntegerProbe()
        let lease = try SparseTileSamplingPlanCache(
            beforePublication: {
                probe.record(store.snapshot().activeSnapshotTokenCount)
            }
        ).acquire(
            key: key,
            sourceBatch: batch,
            outputRegion: output,
            limits: .testDefaults
        )
        retained = store.snapshot()
        #expect(probe.value == 0)
        #expect(retained.activeSnapshotTokenCount == 0)
        #expect(retained.activeLeaseCount == 3)
        try lease.retire()
        #expect(store.snapshot().activeLeaseCount == 0)
    }

    @Test
    func sameOwnedBatchRejectsConcurrentConsumptionAndRemainsOneShot()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let output = try region(0, 0, 1, 1)
        let batch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: output
        )
        let barrier = OneShotReservationBarrier()
        let cache = SparseTileSamplingPlanCache(
            afterSlotReservation: barrier.waitOnce
        )
        let first = Task {
            try cache.acquire(
                key: fixture.key,
                sourceBatch: batch,
                outputRegion: output,
                limits: .testDefaults
            )
        }
        barrier.waitUntilReached()
        #expect(throws: SparseTileSamplingPlanError.sourceBatchInUse) {
            _ = try cache.acquire(
                key: fixture.key,
                sourceBatch: batch,
                outputRegion: output,
                limits: .testDefaults
            )
        }
        barrier.proceed()
        let lease = try await first.value
        #expect(throws: SparseTileSamplingPlanError.sourceBatchConsumed) {
            _ = try cache.acquire(
                key: fixture.key,
                sourceBatch: batch,
                outputRegion: output,
                limits: .testDefaults
            )
        }
        try lease.retire()
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
    }

    @Test
    func borrowedBatchConsumptionReleasesBorrowButLeavesRootCaptureReusable()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let output = try region(0, 0, 1, 1)
        let capture = try TiledRasterExactReferenceCapture(
            providers: [fixture.request.provider]
        )
        let selection = try SparseTileOwnedSourceBatch.selecting(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: output
        )
        let batch = try SparseTileOwnedSourceBatch.borrowing(
            selection,
            from: capture
        )

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: fixture.key,
            sourceBatch: batch,
            outputRegion: output,
            limits: .testDefaults
        )

        var snapshot = fixture.request.provider.backingSnapshot()
        #expect(snapshot.entries[0].snapshotRetainCount == 1)
        #expect(snapshot.activeLeaseCount == 1)
        try lease.retire()
        snapshot = fixture.request.provider.backingSnapshot()
        #expect(snapshot.entries[0].snapshotRetainCount == 1)
        #expect(snapshot.activeLeaseCount == 0)

        let second = try SparseTileOwnedSourceBatch.borrowing(
            selection,
            from: capture
        )
        try second.abandon()
        #expect(fixture.request.provider.backingSnapshot()
            .entries[0].snapshotRetainCount == 1)
        capture.close()
        #expect(fixture.request.provider.backingSnapshot()
            .entries[0].snapshotRetainCount == 0)
    }

    @Test
    func borrowedBatchInUseAndAbandonTerminalsAreLinearAndOneShot() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let output = try region(0, 0, 1, 1)
        let capture = try TiledRasterExactReferenceCapture(
            providers: [fixture.request.provider]
        )
        let selection = try SparseTileOwnedSourceBatch.selecting(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: output
        )
        let batch = try SparseTileOwnedSourceBatch.borrowing(
            selection,
            from: capture
        )

        _ = try batch.beginConsumption()
        #expect(throws: SparseTileSamplingPlanError.sourceBatchInUse) {
            try batch.abandon()
        }
        batch.finishConsumption()
        batch.finishConsumption()
        try batch.abandon()
        #expect(throws: SparseTileSamplingPlanError.sourceBatchConsumed) {
            _ = try batch.beginConsumption()
        }
        #expect(fixture.request.provider.backingSnapshot()
            .entries[0].snapshotRetainCount == 1)
        capture.close()
        #expect(fixture.request.provider.backingSnapshot()
            .entries[0].snapshotRetainCount == 0)
    }

    @Test
    func borrowedBatchPartialLeaseFailureReturnsLeasesAndRootStaysReusable()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let sources = [canonical, prediction]
        let key = planKey(
            layerID: layerID,
            contentKeys: sources.map(\.contentKey)
        )
        let output = try region(0, 0, 1, 1)
        let capture = try TiledRasterExactReferenceCapture(
            providers: sources.map(\.provider)
        )
        let selection = try SparseTileOwnedSourceBatch.selecting(
            sources: sources,
            key: key,
            outputRegion: output
        )
        let batch = try SparseTileOwnedSourceBatch.borrowing(
            selection,
            from: capture
        )
        let cache = SparseTileSamplingPlanCache(
            sourceLeaseFailureInjector: { sourceIndex in
                if sourceIndex == 1 {
                    throw SparseTileSamplingPlanError
                        .injectedSourceLeaseFailure(sourceIndex)
                }
            }
        )

        #expect(throws: SparseTileSamplingPlanError
            .injectedSourceLeaseFailure(1)) {
            _ = try cache.acquire(
                key: key,
                sourceBatch: batch,
                outputRegion: output,
                limits: .testDefaults
            )
        }
        for source in sources {
            let snapshot = source.provider.backingSnapshot()
            #expect(snapshot.activeLeaseCount == 0)
            #expect(snapshot.entries[0].snapshotRetainCount == 1)
        }
        let reusable = try SparseTileOwnedSourceBatch.borrowing(
            selection,
            from: capture
        )
        try reusable.abandon()
        capture.close()
        for source in sources {
            #expect(source.provider.backingSnapshot()
                .entries[0].snapshotRetainCount == 0)
        }
    }

    @Test
    func leakedBorrowedBatchDiagnosesAndReleasesBorrow() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let output = try region(0, 0, 1, 1)
        let capture = try TiledRasterExactReferenceCapture(
            providers: [fixture.request.provider]
        )
        let selection = try SparseTileOwnedSourceBatch.selecting(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: output
        )
        let diagnostic = IntegerProbe()
        var batch: SparseTileOwnedSourceBatch? = try .borrowing(
            selection,
            from: capture,
            deinitDiagnostic: { diagnostic.record(1) }
        )
        #expect(batch != nil)
        batch = nil
        #expect(diagnostic.value == 1)
        #expect(fixture.request.provider.backingSnapshot()
            .entries[0].snapshotRetainCount == 1)
        capture.close()
        #expect(fixture.request.provider.backingSnapshot()
            .entries[0].snapshotRetainCount == 0)
    }

    @Test
    func droppedInUseBorrowedBatchDiagnosesAndReleasesBorrow() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let output = try region(0, 0, 1, 1)
        let capture = try TiledRasterExactReferenceCapture(
            providers: [fixture.request.provider]
        )
        let selection = try SparseTileOwnedSourceBatch.selecting(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: output
        )
        let diagnostic = IntegerProbe()
        var batch: SparseTileOwnedSourceBatch? = try .borrowing(
            selection,
            from: capture,
            deinitDiagnostic: { diagnostic.record(1) }
        )
        _ = try #require(batch).beginConsumption()

        batch = nil
        #expect(diagnostic.value == 1)
        capture.close()
        let terminal = fixture.request.provider.backingSnapshot()
        #expect(terminal.entries[0].snapshotRetainCount == 0)
        #expect(terminal.activeLeaseCount == 0)
    }

    @Test
    func invalidAndDisjointEarlyExitsCloseOwnedBatchExactlyOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let visibleOutput = try region(0, 0, 1, 1)
        let invalidBatch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: visibleOutput
        )
        #expect(throws: SparseTileSamplingPlanError.invalidLimit) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: fixture.key,
                sourceBatch: invalidBatch,
                outputRegion: visibleOutput,
                limits: limits(maximumBindingSlots: 0)
            )
        }
        #expect(fixture.request.provider.backingSnapshot()
            .activeLeaseCount == 0)
        #expect(throws: SparseTileSamplingPlanError.sourceBatchConsumed) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: fixture.key,
                sourceBatch: invalidBatch,
                outputRegion: visibleOutput,
                limits: .testDefaults
            )
        }

        let disjointOutput = try region(512, 0, 513, 1)
        let disjointBatch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: disjointOutput
        )
        let emptyLease = try SparseTileSamplingPlanCache().acquire(
            key: fixture.key,
            sourceBatch: disjointBatch,
            outputRegion: disjointOutput,
            limits: .testDefaults
        )
        #expect(emptyLease.boundTextures.isEmpty)
        #expect(fixture.request.provider.backingSnapshot()
            .activeLeaseCount == 0)
        try emptyLease.retire()

        #expect(throws: SparseTileSamplingPlanError.contentKeyMismatch) {
            _ = try SparseTileOwnedSourceBatch.capturingSelection(
                sources: [],
                key: fixture.key,
                outputRegion: visibleOutput
            )
        }
    }

    @Test
    func strictSelectedBatchRejectsViewportMismatchAndClosesOwnership()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .finite(size)
        )
        let provider = fixture.request.provider
        let wrongOutput = try region(256, 0, 257, 1)
        let wrongSelection = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: wrongOutput
        )
        #expect(provider.backingSnapshot().entries
            .filter { $0.snapshotRetainCount > 0 }
            .map(\.identity.coordinate) == [.init(x: 1, y: 0)])

        #expect(throws: SparseTileSamplingPlanError
            .sourceBatchSelectionMismatch(sourceIndex: 0)) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: fixture.key,
                sourceBatch: wrongSelection,
                outputRegion: try region(0, 0, 1, 1),
                limits: .testDefaults
            )
        }
        let failed = provider.backingSnapshot()
        #expect(failed.entries.allSatisfy { $0.snapshotRetainCount == 0 })
        #expect(failed.activeLeaseCount == 0)

        let correctOutput = try region(0, 0, 1, 1)
        let retry = try SparseTileSamplingPlanCache().acquire(
            key: fixture.key,
            sourceBatch: SparseTileOwnedSourceBatch.capturingSelection(
                sources: [fixture.request],
                key: fixture.key,
                outputRegion: correctOutput
            ),
            outputRegion: correctOutput,
            limits: .testDefaults
        )
        try retry.retire()
    }

    @Test
    func buildFromSelectionCannotWidenRestrictedPeriodicEntitlement() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0), .init(x: 1, y: 0)],
            addressing: .periodic(period: size)
        )
        let references = fixture.request.references
        let restrictedProvider = try fixture.request.provider
            .restrictingEntitlement(to: [references[0]])
        let restricted = try SparseTileSourceRequest(
            contentKey: fixture.request.contentKey,
            addressing: fixture.request.addressing,
            provider: restrictedProvider,
            changedCoordinates: [],
            disposition: fixture.request.disposition,
            referenceScope: .entitlement
        )
        let mapping = SparseTilePeriodicOutputMapping(
            fold: try periodicFold(.grid, rasterSize: size),
            outputToWorldTransform: .identity
        )
        let key = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(mapping)
        )
        let output = try region(0, 0, 512, 1)
        let before = restrictedProvider.backingSnapshot()
        let selection = try SparseTileOwnedSourceBatch.selecting(
            sources: [restricted],
            key: key,
            outputRegion: output
        )
        #expect(try selection.selectedReferenceCount() == 1)

        #expect(throws: SparseTileSamplingPlanError
            .sourceBatchSelectionMismatch(sourceIndex: 0)) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: key,
                selection: selection,
                outputRegion: output,
                limits: .testDefaults
            )
        }
        #expect(restrictedProvider.backingSnapshot() == before)
    }

    @Test
    func buildFromSelectionRejectsPeriodicMappingKindSubstitution() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .periodic(period: size)
        )
        let output = try region(0, 0, 1, 1)
        let affineKey = fixture.key
        let periodicKey = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [SparseTileLayerContentKey(
                layerID: fixture.layerID,
                roles: [fixture.request.contentKey]
            )],
            addressingRevision: 1,
            outputGeometryRevision: 1,
            outputMapping: .periodic(SparseTilePeriodicOutputMapping(
                fold: try periodicFold(.grid, rasterSize: size),
                outputToWorldTransform: .identity
            ))
        )
        let affineSelection = try SparseTileOwnedSourceBatch.selecting(
            sources: [fixture.request],
            key: affineKey,
            outputRegion: output
        )
        let periodicSelection = try SparseTileOwnedSourceBatch.selecting(
            sources: [fixture.request],
            key: periodicKey,
            outputRegion: output
        )

        #expect(throws: SparseTileSamplingPlanError.inconsistentAddressing) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: periodicKey,
                selection: affineSelection,
                outputRegion: output,
                limits: .testDefaults
            )
        }
        #expect(throws: SparseTileSamplingPlanError.inconsistentAddressing) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: affineKey,
                selection: periodicSelection,
                outputRegion: output,
                limits: .testDefaults
            )
        }
    }

    @Test
    func productionSelectionForDisjointViewportOwnsNoTokenOrLease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let output = try region(512, 0, 513, 1)
        let batch = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: output
        )
        let retained = fixture.request.provider.backingSnapshot()
        #expect(retained.entries.allSatisfy { $0.snapshotRetainCount == 0 })

        let lease = try SparseTileSamplingPlanCache().acquire(
            key: fixture.key,
            sourceBatch: batch,
            outputRegion: output,
            limits: .testDefaults
        )
        #expect(lease.boundTextures.isEmpty)
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
        try lease.retire()
    }

    @Test
    func pureSelectionDoesNotMutateAndStrictCaptureFailureRollsBackAllStores()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bytes = PaintTileDescriptor.residentByteCount
        let firstStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: .init(
                maximumActiveTokenCount: 1,
                maximumReferencesPerToken: 2,
                maximumAggregateReferenceCount: 2,
                maximumIndexEntryCount: 2,
                maximumMetadataBytes: 1_024 * 1_024,
                maximumPayloadDebtBytes: bytes * 2
            )
        )
        let secondStore = PaintTileStore(
            device: device,
            byteBudget: bytes,
            transferByteCapacity: bytes * 4,
            snapshotRetentionLimits: .init(
                maximumActiveTokenCount: 1,
                maximumReferencesPerToken: 2,
                maximumAggregateReferenceCount: 2,
                maximumIndexEntryCount: 2,
                maximumMetadataBytes: 1_024 * 1_024,
                maximumPayloadDebtBytes: bytes * 2
            )
        )
        // The capture sorts stores by identity. Pre-fill the second store's
        // only token slot so its failure deterministically rolls back the
        // retention already installed for the first store.
        let acceptingStore: PaintTileStore
        let rejectingStore: PaintTileStore
        if firstStore.identity < secondStore.identity {
            acceptingStore = firstStore
            rejectingStore = secondStore
        } else {
            acceptingStore = secondStore
            rejectingStore = firstStore
        }

        let layerID = UUID()
        let size = PixelSize(width: 256, height: 256)
        func request(
            store: PaintTileStore,
            role: SparseTileSampleRole
        ) throws -> SparseTileSourceRequest {
            let surface = TiledRasterSurface(
                store: store,
                layerID: layerID,
                pixelSize: size,
                generation: 7
            )
            let lease = try surface.reserveTiles(
                at: [.init(x: 0, y: 0)],
                pinReasons: [.dirty]
            )
            try surface.markDirty(lease)
            try surface.returnLease(lease)
            return try SparseTileSourceRequest(
                contentKey: .init(
                    role: role,
                    surfaceIdentity: surface.surfaceID,
                    contentRevision: surface.revision.rawValue,
                    bindingChunkRevision: surface.revision.rawValue
                ),
                addressing: .finite(size),
                provider: surface.makeExactReferenceProvider(),
                changedCoordinates: [.init(x: 0, y: 0)],
                disposition: .fullSnapshot
            )
        }
        let sources = try [
            request(store: acceptingStore, role: .canonical),
            request(store: rejectingStore, role: .prediction),
        ]
        let preexistingRejectingToken = try rejectingStore
            .retainSnapshotReferences(sources[1].references)
        let key = planKey(
            layerID: layerID,
            contentKeys: sources.map(\.contentKey)
        )
        let output = try region(0, 0, 1, 1)
        let beforeAccepting = acceptingStore.snapshot()
        let beforeRejecting = rejectingStore.snapshot()

        let selection = try SparseTileOwnedSourceBatch.selecting(
            sources: sources,
            key: key,
            outputRegion: output
        )
        #expect(acceptingStore.snapshot() == beforeAccepting)
        #expect(rejectingStore.snapshot() == beforeRejecting)

        #expect(throws: PaintTileStoreError.snapshotRetentionLimitExceeded(
            limit: .activeTokens,
            required: 2,
            maximum: 1
        )) {
            _ = try SparseTileOwnedSourceBatch.capturing(selection)
        }
        #expect(acceptingStore.snapshot() == beforeAccepting)
        #expect(rejectingStore.snapshot() == beforeRejecting)
        preexistingRejectingToken.close()
    }

    @Test
    func strictBatchRejectsForeignAndABAEntitlementsBeforeRetention()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let foreign = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let before = fixture.request.provider.backingSnapshot()
        #expect(throws: TiledRasterSurfaceError.exactReferenceNotCaptured) {
            _ = try fixture.request.provider.restrictingEntitlement(
                to: foreign.request.references
            )
        }

        let reference = fixture.request.references[0]
        let aba = reference.replacing(identity: PaintTileIdentity(
            layerID: reference.layerID,
            coordinate: reference.coordinate,
            tileID: PaintTileID(rawValue: UInt64.max)
        ))
        #expect(throws: TiledRasterSurfaceError.exactReferenceNotCaptured) {
            _ = try fixture.request.provider.restrictingEntitlement(to: [aba])
        }
        #expect(fixture.request.provider.backingSnapshot() == before)
    }

    @Test
    func ownedBatchAbandonAndDeinitCloseRetentionExactlyOnce()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeSource(
            device: device,
            pixelSize: PixelSize(width: 256, height: 256),
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(PixelSize(width: 256, height: 256))
        )
        let provider = fixture.request.provider
        let output = try region(0, 0, 1, 1)
        let abandoned = try SparseTileOwnedSourceBatch.capturingSelection(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: output
        )
        #expect(provider.backingSnapshot().entries[0].snapshotRetainCount == 1)
        try abandoned.abandon()
        #expect(provider.backingSnapshot().entries[0].snapshotRetainCount == 0)
        #expect(throws: SparseTileSamplingPlanError.sourceBatchConsumed) {
            _ = try abandoned.beginConsumption()
        }

        let diagnostic = IntegerProbe()
        var leaked: SparseTileOwnedSourceBatch? = try .capturingSelection(
            sources: [fixture.request],
            key: fixture.key,
            outputRegion: output,
            deinitDiagnostic: { diagnostic.record(1) }
        )
        weak let weakBatch = leaked
        leaked = nil
        #expect(weakBatch == nil)
        #expect(diagnostic.value == 1)
        #expect(provider.backingSnapshot().entries[0].snapshotRetainCount == 0)
    }

    @Test
    func consumerHandleStronglyPinsLeaseAfterPublicLeaseIsDropped() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        var lease: SparseTileSamplingPlanLease? = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        weak let weakLease = lease
        let consumer = try #require(lease).beginConsumer()
        try lease?.retire()
        lease = nil

        #expect(weakLease != nil)
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 1)
        #expect(cache.pendingRetirementCount == 1)

        try consumer.complete()
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
        #expect(cache.pendingRetirementCount == 0)
    }

    @Test
    func firstFailedReturnIsRetainedAndRetriedWithoutDoubleReturn() throws {
        try assertReturnFailureIsRetryable(failingAttempt: 1)
    }

    @Test
    func middleFailedReturnRetainsItAndEarlierLeasesForOrderedRetry() throws {
        try assertReturnFailureIsRetryable(failingAttempt: 2)
    }

    @Test
    func concurrentSameKeyAcquiresSelectOneCanonicalContent() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let cache = SparseTileSamplingPlanCache()
        let leases = try await withThrowingTaskGroup(
            of: SparseTileSamplingPlanLease.self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try cache.acquire(
                        key: fixture.key,
                        sources: [fixture.request],
                        outputRegion: try region(0, 0, 256, 256),
                        limits: .testDefaults
                    )
                }
            }
            var values: [SparseTileSamplingPlanLease] = []
            for try await value in group { values.append(value) }
            return values
        }
        let canonical = try #require(leases.first?.content)
        #expect(leases.allSatisfy { $0.content === canonical })
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 8)
        for lease in leases { try lease.retire() }
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
        #expect(cache.pendingRetirementCount == 0)
    }

    @Test
    func concurrentSameKeyWithDifferentFingerprintRejectsTheLoser() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let firstRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let collision = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let key = planKey(layerID: layerID, contentKeys: [firstRequest.contentKey])
        let barrier = OneShotReservationBarrier()
        let cache = SparseTileSamplingPlanCache(
            afterSlotReservation: barrier.waitOnce
        )
        let loser = Task {
            try cache.acquire(
                key: key,
                sources: [firstRequest],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        barrier.waitUntilReached()
        let winner = try cache.acquire(
            key: key,
            sources: [collision],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        barrier.proceed()

        do {
            _ = try await loser.value
            Issue.record("incompatible same-key race unexpectedly succeeded")
        } catch {
            #expect(error as? SparseTileSamplingPlanError == .contentKeyCollision)
        }
        #expect(firstRequest.provider.backingSnapshot().activeLeaseCount == 0)
        #expect(collision.provider.backingSnapshot().activeLeaseCount == 1)
        try winner.retire()
        #expect(cache.pendingRetirementCount == 0)
    }

    @Test
    func extremeOutputAndSampleGeometryThrowsInsteadOfTrapping() throws {
        #expect(throws: SparseTileSamplingPlanError.arithmeticOverflow) {
            _ = try SparseTileOutputRegion(
                minX: Int.min,
                minY: 0,
                maxX: Int.max,
                maxY: 1
            )
        }

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let lease = try SparseTileSamplingPlanCache().acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        defer { try? lease.retire() }
        #expect(throws: SparseTileSamplingPlanError.arithmeticOverflow) {
            _ = try SparseTileCPUReferenceSampler.resolveFourNeighbors(
                at: SIMD2(Double(Int.max), 0),
                content: lease.content
            )
        }
    }

    @Test
    func pageLimitsRejectBeforeAnyPageTableAllocation() throws {
        let layerID = UUID()
        let size = PixelSize(width: 1_024, height: 1_024)
        let contentKey = SparseTileRoleContentKey(
            role: .canonical,
            contentRevision: 1,
            bindingChunkRevision: 1
        )
        let source = try SparseTileSourceSnapshot(
            contentKey: contentKey,
            addressing: .finite(size),
            layerID: layerID,
            references: [],
            changedCoordinates: [],
            disposition: .fullSnapshot
        )
        let allocationProbe = IntegerProbe()

        #expect(throws: SparseTileSamplingPlanError.pageEntryLimitExceeded(
            required: 16,
            maximum: 1
        )) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: planKey(layerID: layerID, contentKeys: [contentKey]),
                sources: [source],
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumPageEntries: 1),
                allocationObserver: { _, count in
                    allocationProbe.record(count)
                }
            )
        }
        #expect(allocationProbe.value == 0)
    }

    @Test
    func terminalBatchAndHaloFailuresPrecedeEveryPlanAllocation() throws {
        let layerID = UUID()
        let size = PixelSize(width: 256, height: 256)
        let reference = try makeMetadataReferences(
            layerID: layerID,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)]
        )
        let canonicalKey = SparseTileRoleContentKey(
            role: .canonical,
            contentRevision: 1,
            bindingChunkRevision: 1
        )
        let predictionKey = SparseTileRoleContentKey(
            role: .prediction,
            contentRevision: 1,
            bindingChunkRevision: 1
        )
        let sources = try [canonicalKey, predictionKey].map { contentKey in
            try SparseTileSourceSnapshot(
                contentKey: contentKey,
                addressing: .finite(size),
                layerID: layerID,
                references: reference,
                changedCoordinates: reference.map(\.coordinate),
                disposition: .fullSnapshot
            )
        }
        let probe = IntegerProbe()
        let observe: @Sendable (SparseTilePlanAllocationKind, Int) -> Void = {
            _, count in probe.record(count)
        }

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [canonicalKey, predictionKey]
                ),
                sources: sources,
                outputRegion: try region(0, 0, 1, 1),
                limits: limits(maximumTexturesPerBatch: 1),
                allocationObserver: observe
            )
        }
        #expect(probe.value == 0)

        #expect(throws: SparseTileSamplingPlanError
            .onePixelBatchExceedsTextureLimit(required: 2, maximum: 1)) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [canonicalKey, predictionKey]
                ),
                sources: sources,
                outputRegion: try region(0, 0, 2, 1),
                limits: limits(maximumTexturesPerBatch: 1),
                allocationObserver: observe
            )
        }
        #expect(probe.value == 0)

        #expect(throws: SparseTileSamplingPlanError.arithmeticOverflow) {
            _ = try SparseTileSamplingPlanBuilder.buildFull(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [canonicalKey, predictionKey]
                ),
                sources: sources,
                outputRegion: try SparseTileOutputRegion(
                    minX: Int.max - 1,
                    minY: 0,
                    maxX: Int.max,
                    maxY: 1
                ),
                limits: .testDefaults,
                allocationObserver: observe
            )
        }
        #expect(probe.value == 0)
    }

    @Test
    func duplicateLayerEntriesCannotSplitAndReorderFixedRoles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let prediction = try makeRequest(
            device: device,
            layerID: layerID,
            role: .prediction,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let canonical = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let duplicateLayerKey = SparseTileSamplingPlanKey(
            documentGeneration: 7,
            orderedLayers: [
                .init(layerID: layerID, roles: [prediction.contentKey]),
                .init(layerID: layerID, roles: [canonical.contentKey]),
            ],
            addressingRevision: 1,
            outputGeometryRevision: 1
        )
        let predictionBefore = prediction.provider.backingSnapshot()
        let canonicalBefore = canonical.provider.backingSnapshot()

        #expect(throws: SparseTileSamplingPlanError.duplicateLayer(layerID)) {
            _ = try SparseTileSamplingPlanCache().acquire(
                key: duplicateLayerKey,
                sources: [prediction, canonical],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        #expect(prediction.provider.backingSnapshot() == predictionBefore)
        #expect(canonical.provider.backingSnapshot() == canonicalBefore)
    }

    @Test
    func invalidatingAnInFlightReservationPreventsStalePublication() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let fixture = try makeSource(
            device: device,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size)
        )
        let barrier = OneShotReservationBarrier()
        let cache = SparseTileSamplingPlanCache(
            afterSlotReservation: barrier.waitOnce
        )
        let acquisition = Task {
            try cache.acquire(
                key: fixture.key,
                sources: [fixture.request],
                outputRegion: try region(0, 0, 256, 256),
                limits: .testDefaults
            )
        }
        barrier.waitUntilReached()
        cache.invalidate(documentGeneration: fixture.key.documentGeneration)
        barrier.proceed()

        do {
            _ = try await acquisition.value
            Issue.record("invalidated reservation unexpectedly published")
        } catch {
            #expect(error as? SparseTileSamplingPlanError == .staleSlotOwner)
        }
        #expect(fixture.request.provider.backingSnapshot().activeLeaseCount == 0)
        #expect(cache.pendingRetirementCount == 0)

        let fresh = try cache.acquire(
            key: fixture.key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )
        try fresh.retire()
    }

    @Test
    func staleFailedRetirementCannotFreeAReusedSlotOwner() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let layerID = UUID()
        let firstRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 0, y: 0)],
            addressing: .finite(size),
            contentRevision: 1
        )
        let secondRequest = try makeRequest(
            device: device,
            layerID: layerID,
            role: .canonical,
            pixelSize: size,
            coordinates: [.init(x: 1, y: 0)],
            addressing: .finite(size),
            contentRevision: 2
        )
        let probe = LeaseReturnProbe(failingAttempts: [1, 2])
        let cache = SparseTileSamplingPlanCache(returnLease: probe.call)
        var first: SparseTileSamplingPlanLease? = try cache.acquire(
            key: planKey(layerID: layerID, contentKeys: [firstRequest.contentKey]),
            sources: [firstRequest],
            outputRegion: try region(0, 0, 256, 256),
            limits: limits(maximumBindingSlots: 1)
        )
        #expect(throws: LeaseReturnProbe.InjectedError.failure) {
            try first?.retire()
        }
        first = nil
        #expect(cache.pendingRetirementCount == 1)
        #expect(throws: SparseTileSamplingPlanError.bindingSlotLimitExceeded(
            required: 2,
            maximum: 1
        )) {
            _ = try cache.acquire(
                key: planKey(
                    layerID: layerID,
                    contentKeys: [secondRequest.contentKey]
                ),
                sources: [secondRequest],
                outputRegion: try region(256, 0, 512, 256),
                limits: limits(maximumBindingSlots: 1)
            )
        }

        try cache.retryPendingRetirements()
        let second = try cache.acquire(
            key: planKey(layerID: layerID, contentKeys: [secondRequest.contentKey]),
            sources: [secondRequest],
            outputRegion: try region(256, 0, 512, 256),
            limits: limits(maximumBindingSlots: 1)
        )
        try cache.retryPendingRetirements()
        #expect(secondRequest.provider.backingSnapshot().activeLeaseCount == 1)
        try second.retire()
        #expect(cache.pendingRetirementCount == 0)
    }

    @Test
    func sparsePlanRemainsDisconnectedFromProductionRendererAndShaderABI()
        throws
    {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in [
            "Sources/MetalRenderer/GridRenderer.swift",
            "Sources/MetalRenderer/Shaders.metal",
            "Sources/MetalRenderer/ShaderABI.swift",
            "Sources/CShaderTypes/include/ShaderTypes.h",
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(!source.contains("SparseTileSamplingPlan"))
            #expect(!source.contains("SparseTileSourceRequest"))
        }
    }

    private func assertReturnFailureIsRetryable(failingAttempt: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = UUID()
        let requests = try SparseTileSampleRole.allCases.map { role in
            try makeRequest(
                device: device,
                layerID: layerID,
                role: role,
                pixelSize: size,
                coordinates: [.init(x: 0, y: 0)],
                addressing: .finite(size)
            )
        }
        let key = planKey(
            layerID: layerID,
            contentKeys: requests.map(\.contentKey)
        )
        let probe = LeaseReturnProbe(failingAttempts: [failingAttempt])
        let cache = SparseTileSamplingPlanCache(returnLease: probe.call)
        var lease: SparseTileSamplingPlanLease? = try cache.acquire(
            key: key,
            sources: requests,
            outputRegion: try region(0, 0, 256, 256),
            limits: .testDefaults
        )

        #expect(throws: LeaseReturnProbe.InjectedError.failure) {
            try lease?.retire()
        }
        let afterFailure = requests.map {
            $0.provider.backingSnapshot().activeLeaseCount
        }
        #expect(afterFailure.reduce(0, +) == 4 - failingAttempt)
        #expect(cache.pendingRetirementCount == 1)

        // The public lease may disappear; cache ownership keeps the exact
        // failed and not-yet-attempted returns alive and retryable.
        lease = nil
        try cache.retryPendingRetirements()
        #expect(requests.allSatisfy {
            $0.provider.backingSnapshot().activeLeaseCount == 0
        })
        #expect(cache.pendingRetirementCount == 0)
        let attempts = probe.attemptedLeases()
        #expect(attempts.count == 4)
        #expect(Dictionary(grouping: attempts, by: { $0 }).values
            .map(\.count).sorted() == [1, 1, 2])
    }
}

private struct SourceFixture {
    let layerID: UUID
    let request: SparseTileSourceRequest
    let key: SparseTileSamplingPlanKey
}

private func makeSource(
    device: any MTLDevice,
    pixelSize: PixelSize,
    coordinates: [PaintTileCoordinate],
    addressing: SparseTileAddressing
) throws -> SourceFixture {
    let layerID = UUID()
    let request = try makeRequest(
        device: device,
        layerID: layerID,
        role: .canonical,
        pixelSize: pixelSize,
        coordinates: coordinates,
        addressing: addressing
    )
    return SourceFixture(
        layerID: layerID,
        request: request,
        key: planKey(layerID: layerID, contentKeys: [request.contentKey])
    )
}

private func makeRequest(
    device: any MTLDevice,
    layerID: UUID,
    role: SparseTileSampleRole,
    pixelSize: PixelSize,
    coordinates: [PaintTileCoordinate],
    addressing: SparseTileAddressing,
    contentRevision: UInt64? = nil,
    disposition: SparseTileSourceDisposition = .fullSnapshot
) throws -> SparseTileSourceRequest {
    let surface = TiledRasterSurface(
        device: device,
        layerID: layerID,
        pixelSize: pixelSize,
        generation: 7,
        byteBudget: max(1, coordinates.count) * PaintTileDescriptor.residentByteCount
    )
    if !coordinates.isEmpty {
        let tileLease = try surface.reserveTiles(
            at: coordinates,
            pinReasons: [.dirty]
        )
        try surface.markDirty(tileLease)
        try surface.returnLease(tileLease)
    }
    let contentKey = SparseTileRoleContentKey(
        role: role,
        contentRevision: contentRevision ?? surface.revision.rawValue,
        bindingChunkRevision: 1
    )
    let request = try SparseTileSourceRequest(
        contentKey: contentKey,
        addressing: addressing,
        provider: surface.makeExactReferenceProvider(),
        changedCoordinates: coordinates.sorted(),
        disposition: disposition
    )
    return request
}

private func planKey(
    layerID: UUID,
    contentKeys: [SparseTileRoleContentKey],
    outputToSourceTransform: SparseTileOutputToSourceTransform = .identity
) -> SparseTileSamplingPlanKey {
    SparseTileSamplingPlanKey(
        documentGeneration: 7,
        orderedLayers: [
            SparseTileLayerContentKey(layerID: layerID, roles: contentKeys),
        ],
        addressingRevision: 1,
        outputGeometryRevision: 1,
        outputToSourceTransform: outputToSourceTransform
    )
}

private func makeMetadataReferences(
    layerID: UUID,
    pixelSize: PixelSize,
    coordinates: [PaintTileCoordinate]
) throws -> [PaintTileReference] {
    let storeIdentity = PaintTileStoreIdentity()
    let surfaceID = UUID()
    return try coordinates.enumerated().map { index, coordinate in
        PaintTileReference(
            storeIdentity: storeIdentity,
            physicalSurfaceID: surfaceID,
            layerID: layerID,
            physicalGeneration: 7,
            identity: PaintTileIdentity(
                layerID: layerID,
                coordinate: coordinate,
                tileID: PaintTileID(rawValue: UInt64(index + 1))
            ),
            descriptor: try PaintTileDescriptor(
                coordinate: coordinate,
                logicalPixelSize: pixelSize
            )
        )
    }
}

private extension SparseTilePlanLimits {
    static let testDefaults = SparseTilePlanLimits(
        maximumPageEntries: 4_096,
        maximumPageChunks: 256,
        maximumPageTableBytes: 512 * 1_024,
        maximumBindingSlots: 256,
        maximumBindingChunks: 64,
        maximumBindingBytes: 256 * 1_024,
        maximumTexturesPerBatch: 16,
        maximumBatchCount: 1_024
    )
}

private func exerciseHugeFinitePeriodicFoldRejection() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let size = PixelSize(width: 64, height: 64)
    let fixture = try makeSource(
        device: device,
        pixelSize: size,
        coordinates: [.init(x: 0, y: 0)],
        addressing: .periodic(period: size)
    )
    let fold = try periodicFold(.halfDrop, rasterSize: size)
    // The local quotient is finite and Int-representable, but the adjusted
    // half-open cell does not satisfy Task 7's exact Float round-trip.
    let unsafeCoordinate = Float(bitPattern: 1_317_061_535)
    let mapping = SparseTilePeriodicOutputMapping(
        fold: fold,
        outputToWorldTransform: SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(unsafeCoordinate, 0),
            sourceStep: SIMD2(repeating: 1)
        )
    )
    let key = SparseTileSamplingPlanKey(
        documentGeneration: 7,
        orderedLayers: [SparseTileLayerContentKey(
            layerID: fixture.layerID,
            roles: [fixture.request.contentKey]
        )],
        addressingRevision: 1,
        outputGeometryRevision: 1,
        outputMapping: .periodic(mapping)
    )
    let before = fixture.request.provider.backingSnapshot()
    #expect(throws: SparseTileSamplingPlanError
        .invalidOutputToSourceTransform) {
        _ = try SparseTileSamplingPlanCache().acquire(
            key: key,
            sources: [fixture.request],
            outputRegion: try region(0, 0, 1, 1),
            limits: .testDefaults
        )
    }
    #expect(fixture.request.provider.backingSnapshot() == before)
}

private func runHugeFinitePeriodicFoldSubprocess()
    throws -> (status: Int32, standardError: String)
{
    guard
        let optionIndex = CommandLine.arguments.firstIndex(
            of: "--test-bundle-path"
        ),
        CommandLine.arguments.indices.contains(optionIndex + 1)
    else {
        preconditionFailure("Swift Testing test executable path is unavailable")
    }
    let testExecutablePath = CommandLine.arguments[optionIndex + 1]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
        "--test-bundle-path", testExecutablePath,
        "--filter", "hugeFinitePeriodicFoldFailsClosedBeforeRetentionInSubprocess",
        testExecutablePath,
        "--testing-library", "swift-testing",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["PATTERN_PERIODIC_HUGE_FINITE_FOLD": "1"],
        uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = FileHandle.nullDevice
    let standardError = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    return (process.terminationStatus, errorOutput)
}

private func limits(
    maximumPageEntries: Int = 4_096,
    maximumBindingSlots: Int = 256,
    maximumTexturesPerBatch: Int = 16,
    maximumBatchCount: Int = 1_024
) -> SparseTilePlanLimits {
    SparseTilePlanLimits(
        maximumPageEntries: maximumPageEntries,
        maximumPageChunks: 256,
        maximumPageTableBytes: 512 * 1_024,
        maximumBindingSlots: maximumBindingSlots,
        maximumBindingChunks: 64,
        maximumBindingBytes: 256 * 1_024,
        maximumTexturesPerBatch: maximumTexturesPerBatch,
        maximumBatchCount: maximumBatchCount
    )
}

private func periodicFold(
    _ preset: SymmetryPresetID,
    rasterSize: PixelSize
) throws -> CompiledPeriodicDisplayFold {
    let strategy = try TilingStrategy(
        configuration: .defaultConfiguration(
            presetID: preset,
            canonicalRasterSize: rasterSize
        ),
        canonicalRasterSize: rasterSize
    )
    return try #require(
        strategy.compiledSymmetry.domain.periodic?.displayFold
    )
}

private func orientedPeriodicFold(
    _ preset: SymmetryPresetID,
    rasterSize: PixelSize,
    orientationRadians: Float
) throws -> CompiledPeriodicDisplayFold {
    let strategy = try TilingStrategy(
        configuration: PeriodicSymmetryConfiguration(
            presetID: preset,
            repeatSize: PatternSize(
                width: Float(rasterSize.width),
                height: Float(rasterSize.height)
            ),
            orientationRadians: orientationRadians
        ),
        canonicalRasterSize: rasterSize
    )
    return try #require(
        strategy.compiledSymmetry.domain.periodic?.displayFold
    )
}

private func allPageCoordinates(
    _ size: PixelSize
) -> [PaintTileCoordinate] {
    let columns = (size.width + PaintTileDescriptor.side - 1)
        / PaintTileDescriptor.side
    let rows = (size.height + PaintTileDescriptor.side - 1)
        / PaintTileDescriptor.side
    return (0..<rows).flatMap { y in
        (0..<columns).map { x in PaintTileCoordinate(x: x, y: y) }
    }
}

private func expectedPeriodicPages(
    fold: CompiledPeriodicDisplayFold,
    transform: SparseTileOutputToSourceTransform,
    output: SparseTileOutputRegion,
    subregion: SparseTileOutputRegion? = nil,
    maximumPixelCenters: Int? = nil
) -> Set<PaintTileCoordinate> {
    let region = subregion ?? output
    let width = Int(fold.canonicalSize.width)
    let height = Int(fold.canonicalSize.height)
    var result: Set<PaintTileCoordinate> = []
    var remaining = maximumPixelCenters ?? Int.max
    outer: for y in region.minY..<region.maxY {
        for x in region.minX..<region.maxX {
            guard remaining > 0 else { break outer }
            remaining -= 1
            let local = SIMD2(
                Float(x - output.minX) + 0.5,
                Float(y - output.minY) + 0.5
            )
            let root = SIMD2(Float(output.minX), Float(output.minY))
                + transform.sourceOffset
            let world = root + local * transform.sourceStep
            let canonical = fold.applying(to: WorldPoint(world))
            let lowerX = Int(floor(canonical.x - 0.5))
            let lowerY = Int(floor(canonical.y - 0.5))
            for dy in 0...1 {
                for dx in 0...1 {
                    let pixelX = ((lowerX + dx) % width + width) % width
                    let pixelY = ((lowerY + dy) % height + height) % height
                    result.insert(PaintTileCoordinate(
                        x: pixelX / PaintTileDescriptor.side,
                        y: pixelY / PaintTileDescriptor.side
                    ))
                }
            }
        }
    }
    return result
}

private func region(
    _ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int
) throws -> SparseTileOutputRegion {
    try SparseTileOutputRegion(
        minX: minX, minY: minY, maxX: maxX, maxY: maxY
    )
}

private struct CoordinateColorProvider: SparseTileCPUTexelProvider {
    let colors: [PaintTileCoordinate: SIMD4<Float>]

    func texel(
        reference: PaintTileReference,
        localX: Int,
        localY: Int
    ) throws -> SIMD4<Float> {
        colors[reference.coordinate] ?? .zero
    }
}

private struct LocalXProvider: SparseTileCPUTexelProvider {
    func texel(
        reference: PaintTileReference,
        localX: Int,
        localY: Int
    ) throws -> SIMD4<Float> {
        SIMD4(Float(localX) / 255, 0, 0, 1)
    }
}

private final class RecordingProvider: SparseTileCPUTexelProvider,
    @unchecked Sendable
{
    struct Call: Equatable {
        let coordinate: PaintTileCoordinate
        let localX: Int
        let localY: Int
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func texel(
        reference: PaintTileReference,
        localX: Int,
        localY: Int
    ) throws -> SIMD4<Float> {
        lock.lock()
        calls.append(.init(
            coordinate: reference.coordinate,
            localX: localX,
            localY: localY
        ))
        lock.unlock()
        return SIMD4(repeating: 1)
    }

    func snapshot() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class LeaseReturnProbe: @unchecked Sendable {
    enum InjectedError: Error, Equatable {
        case failure
    }

    private let lock = NSLock()
    private let failingAttempts: Set<Int>
    private var attempt = 0
    private var leases: [LeaseIdentity] = []

    fileprivate struct LeaseIdentity: Hashable {
        let surfaceID: UUID
        let lease: ObjectIdentifier
    }

    init(failingAttempts: Set<Int>) {
        self.failingAttempts = failingAttempts
    }

    func call(lease: TiledRasterExactReferenceLease) throws {
        lock.lock()
        attempt += 1
        let currentAttempt = attempt
        leases.append(.init(
            surfaceID: lease.surfaceID,
            lease: ObjectIdentifier(lease)
        ))
        lock.unlock()
        if failingAttempts.contains(currentAttempt) { throw InjectedError.failure }
        try lease.returnLease()
    }

    func attemptedLeases() -> [LeaseIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return leases
    }
}

private final class ArmedSparsePlanBarrier: @unchecked Sendable {
    private let paused = DispatchSemaphore(value: 0)
    private let permit = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isArmed = false
    private var didPause = false

    func arm() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }

    func pauseIfArmed() {
        lock.lock()
        let shouldPause = isArmed && !didPause
        if shouldPause { didPause = true }
        lock.unlock()
        guard shouldPause else { return }
        paused.signal()
        _ = permit.wait(timeout: .now() + 5)
    }

    func waitUntilPaused() async throws {
        let paused = paused
        let succeeded = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: paused.wait(timeout: .now() + 5) == .success
                )
            }
        }
        guard succeeded else { throw ArmedSparsePlanBarrierError.timeout }
    }

    func resume() { permit.signal() }
}

private enum ArmedSparsePlanBarrierError: Error { case timeout }

private final class CountedSparsePlanBarrier: @unchecked Sendable {
    private let expected: Int
    private let paused = DispatchSemaphore(value: 0)
    private let permit = DispatchSemaphore(value: 0)

    init(expected: Int) { self.expected = expected }

    func pause() {
        paused.signal()
        _ = permit.wait(timeout: .now() + 5)
    }

    func waitUntilAllPaused() async throws {
        let paused = paused
        let expected = expected
        let succeeded = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for _ in 0..<expected where
                    paused.wait(timeout: .now() + 5) != .success
                {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: true)
            }
        }
        guard succeeded else { throw ArmedSparsePlanBarrierError.timeout }
    }

    func resumeAll() {
        for _ in 0..<expected { permit.signal() }
    }
}

private final class OneShotReservationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private var shouldWait = true

    func waitOnce() {
        lock.lock()
        let wait = shouldWait
        shouldWait = false
        lock.unlock()
        guard wait else { return }
        reached.signal()
        continuation.wait()
    }

    func waitUntilReached() {
        reached.wait()
    }

    func proceed() {
        continuation.signal()
    }
}

private final class IntegerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ value: Int) {
        lock.lock()
        storedValue += value
        lock.unlock()
    }
}
