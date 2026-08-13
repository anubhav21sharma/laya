import EditorCore
import Foundation
@preconcurrency import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Interactive stroke presentation cache", .serialized)
struct InteractiveStrokePresentationCacheTests {
    @Test
    @MainActor
    func offscreenCompletionFulfillsExactAcknowledgementWithoutDrawable()
        async throws
    {
        guard let rig = try makeRig(gateCompletion: true) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [coordinate],
            sequence: 1
        )

        let adoption = Task {
            try await rig.cache.adopt(update, parameters: rig.parameters)
        }
        try #require(await rig.gate.waitUntilSubmitted())

        #expect(update.acknowledgement.status == .available)
        #expect(try await rig.cache.current(generation: rig.generation) == nil)
        await rig.gate.open()

        #expect(try await adoption.value == .init(
            generation: rig.generation,
            strokeEpoch: rig.capability.presentationEpoch.identity,
            sequence: 1
        ))
        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 1)
        let current = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        #expect(current.authoritative?.references.map(\.coordinate)
            == [coordinate])
        #expect(current.prediction?.references.isEmpty == true)
        #expect(current.parameters == rig.parameters)
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.maximumUpdateSlotCount == 2)
        #expect(diagnostic.updateSlotHighWater == 1)
        #expect(diagnostic.completedUpdateCount == 1)
        #expect(diagnostic.acknowledgementSettlementCount == 1)
        #expect(diagnostic.residentBytes >= PaintTileDescriptor.residentByteCount)
        #expect(diagnostic.residentByteHighWater >= diagnostic.residentBytes)
        #expect(diagnostic.provisionalBytes == 0)
        #expect(diagnostic.componentCoverageBytes > 0)
    }

    @Test
    @MainActor
    func changedCoordinateCopiesExactRGBA16FloatTileBytes() async throws {
        guard let rig = try makeRig() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let reservation = try rig.capability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        let sourceTexture = try #require(reservation.bindings.first?.texture)
        let write = try #require(rig.queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sourceTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            0.25, 0.5, 0.75, 1
        )
        let encoder = try #require(write.makeRenderCommandEncoder(
            descriptor: pass
        ))
        encoder.endEncoding()
        write.commit()
        await write.completed()
        #expect(write.status == .completed)
        try rig.capability.testingMarkDirty(reservation)
        try rig.capability.releaseFrameReservations(
            authoritative: reservation,
            prediction: nil
        )
        let update = try rig.context.makeTransientCacheUpdate(
            frame: .testing(
                capability: rig.capability,
                changedCoordinates: [coordinate],
                acknowledgementIsAvailable: true
            ),
            sequence: 1
        )
        let sourceBytes = try await tileBytes(
            update.descriptor.authoritativeProvider,
            coordinate: coordinate,
            queue: rig.queue
        )

        _ = try await rig.cache.adopt(update, parameters: rig.parameters)
        let current = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        let destinationBytes = try await tileBytes(
            try #require(current.authoritative),
            coordinate: coordinate,
            queue: rig.queue
        )

        #expect(sourceBytes.contains { $0 != 0 })
        #expect(destinationBytes == sourceBytes)
    }

    @Test
    @MainActor
    func inFlightReplacementKeepsPreviousCompletedRevisionVisible()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let firstCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [firstCoordinate],
            sequence: 1
        )
        _ = try await rig.cache.adopt(first, parameters: rig.parameters)
        let previous = try #require(
            try await rig.cache.current(generation: rig.generation)
        )

        await rig.gate.close()
        let secondCoordinate = PaintTileCoordinate(x: 1, y: 0)
        let second = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [secondCoordinate],
            sequence: 2
        )
        let replacement = Task {
            try await rig.cache.adopt(second, parameters: rig.parameters)
        }
        try #require(await rig.gate.waitUntilSubmitted(count: 2))

        let whileUpdating = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        #expect(whileUpdating.revision == previous.revision)
        #expect(whileUpdating.authoritative?.references.map(\.coordinate)
            == [firstCoordinate])
        let inFlight = await rig.cache.snapshot()
        #expect(inFlight.activeUpdateSlotCount == 2)
        #expect(inFlight.updateSlotHighWater == 2)

        await rig.gate.open()
        _ = try await replacement.value
        let completed = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        #expect(completed.revision.sequence == 2)
        #expect(completed.authoritative?.references.map(\.coordinate)
            == [firstCoordinate, secondCoordinate])
        #expect(second.acknowledgement.status == .fulfilled)
    }

    @Test
    @MainActor
    func predictionReplacementClearsCoordinatesMissingFromExactSource()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let old = PaintTileCoordinate(x: 0, y: 0)
        let initial = try makeUpdate(
            rig: rig,
            role: .prediction,
            coordinates: [old],
            sequence: 1,
            clearsPrediction: true
        )
        _ = try await rig.cache.adopt(initial, parameters: rig.parameters)

        let replacement = try makeUpdate(
            rig: rig,
            role: .prediction,
            coordinates: [],
            sequence: 2,
            clearsPrediction: true
        )
        _ = try await rig.cache.adopt(replacement, parameters: rig.parameters)

        let current = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        #expect(current.authoritative?.references.isEmpty == true)
        #expect(current.prediction?.references.isEmpty == true)
        #expect(replacement.changedCoordinates.isEmpty)
        #expect(replacement.acknowledgement.status == .fulfilled)
    }

    @Test
    @MainActor
    func authoritativeUpdateClearsSupersededPredictionRole() async throws {
        guard let rig = try makeRig() else { return }
        let predicted = PaintTileCoordinate(x: 1, y: 0)
        let prediction = try makeUpdate(
            rig: rig,
            role: .prediction,
            coordinates: [predicted],
            sequence: 1
        )
        _ = try await rig.cache.adopt(prediction, parameters: rig.parameters)

        let authoritative = PaintTileCoordinate(x: 0, y: 0)
        let replacement = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [authoritative],
            sequence: 2,
            clearsPrediction: true
        )
        _ = try await rig.cache.adopt(replacement, parameters: rig.parameters)

        let current = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        #expect(current.authoritative?.references.map(\.coordinate)
            == [authoritative])
        #expect(current.prediction?.references.isEmpty == true)
        #expect(replacement.acknowledgement.testingRequestCount == 1)
    }

    @Test
    @MainActor
    func crossRoleReplacementFitsFinalResidentCapacityAtCeiling()
        async throws
    {
        let coverageBytes = try #require(
            DepositionComponentCoverage.residentByteCount(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side
            )
        )
        let tileBytes = PaintTileDescriptor.residentByteCount + coverageBytes
        let replacementPhysicalPeak = tileBytes * 3
            + PaintTileDescriptor.residentByteCount * 2
        guard let rig = try makeRig(
            gateCompletion: true,
            maximumTileCount: 1,
            cacheByteBudget: replacementPhysicalPeak
        ) else { return }
        let prediction = try makeUpdate(
            rig: rig,
            role: .prediction,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let firstAdoption = Task {
            try await rig.cache.adopt(
                prediction,
                parameters: rig.parameters
            )
        }
        try #require(await rig.gate.waitUntilSubmitted())
        var inFlight = await rig.cache.snapshot()
        #expect(inFlight.totalPhysicalResidentBytes
            <= inFlight.residentByteBudget)
        await rig.gate.open()
        _ = try await firstAdoption.value
        await rig.gate.close()

        let authoritative = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2,
            clearsPrediction: true
        )
        let replacementAdoption = Task {
            try await rig.cache.adopt(
                authoritative,
                parameters: rig.parameters
            )
        }
        try #require(await rig.gate.waitUntilSubmitted(count: 2))
        inFlight = await rig.cache.snapshot()
        #expect(inFlight.totalPhysicalResidentBytes
            == replacementPhysicalPeak)
        #expect(inFlight.totalPhysicalResidentBytes
            <= inFlight.residentByteBudget)
        #expect(inFlight.totalPhysicalResidentByteHighWater
            <= inFlight.residentByteBudget)
        await rig.gate.open()
        _ = try await replacementAdoption.value

        let current = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        #expect(current.authoritative?.references.map(\.coordinate)
            == [.init(x: 1, y: 0)])
        #expect(current.prediction?.references.isEmpty == true)
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.residentBytes
            == PaintTileDescriptor.residentByteCount + coverageBytes)
        #expect(diagnostic.componentCoverageBytes == coverageBytes)
        #expect(diagnostic.totalPhysicalResidentBytes
            <= diagnostic.residentByteBudget)
        #expect(diagnostic.totalPhysicalResidentByteHighWater
            <= diagnostic.residentByteBudget)
        #expect(diagnostic.totalPhysicalResidentByteHighWater
            == replacementPhysicalPeak)
    }

    @Test
    @MainActor
    func secondRolePreparationFailureLeavesPublishedSurfacesAndBytesUnchanged()
        async throws
    {
        guard let rig = try makeRig(
            cacheFailureInjection: .init(
                sequence: 2,
                role: .authoritative
            )
        ) else { return }
        let predictionCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let prediction = try makeUpdate(
            rig: rig,
            role: .prediction,
            coordinates: [predictionCoordinate],
            sequence: 1
        )
        _ = try await rig.cache.adopt(prediction, parameters: rig.parameters)
        let prior = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        let before = await rig.cache.snapshot()

        let replacement = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2,
            clearsPrediction: true
        )
        await #expect(
            throws: InteractiveStrokePresentationCacheError
                .injectedRolePreparationFailure(.authoritative)
        ) {
            _ = try await rig.cache.adopt(
                replacement,
                parameters: rig.parameters
            )
        }

        let current = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        #expect(current.revision == prior.revision)
        #expect(current.authoritative?.references
            == prior.authoritative?.references)
        #expect(current.prediction?.references == prior.prediction?.references)
        let after = await rig.cache.snapshot()
        #expect(after.residentBytes == before.residentBytes)
        #expect(after.componentCoverageBytes == before.componentCoverageBytes)
        #expect(after.backingBytes == before.backingBytes)
        #expect(after.provisionalBytes == 0)
        #expect(after.rolledBackRoleCommitCount == 1)
        #expect(replacement.acknowledgement.status == .fulfilled)
        #expect(replacement.acknowledgement.testingRequestCount == 1)
    }

    @Test
    @MainActor
    func replacementFailsBeforeMutationWhenDoubleBufferExceedsPhysicalBudget()
        async throws
    {
        let tileBytes = PaintTileDescriptor.residentByteCount
            + DepositionComponentCoverage.residentByteCount(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side
            )!
        let firstAdoptionPeak = tileBytes
            + PaintTileDescriptor.residentByteCount * 2
        let replacementPeak = tileBytes * 3
            + PaintTileDescriptor.residentByteCount * 2
        guard let rig = try makeRig(
            maximumTileCount: 1,
            cacheByteBudget: firstAdoptionPeak
        ) else { return }
        let predictionCoordinate = PaintTileCoordinate(x: 0, y: 0)
        let prediction = try makeUpdate(
            rig: rig,
            role: .prediction,
            coordinates: [predictionCoordinate],
            sequence: 1
        )
        _ = try await rig.cache.adopt(prediction, parameters: rig.parameters)
        let prior = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        let before = await rig.cache.snapshot()
        let replacement = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2,
            clearsPrediction: true
        )

        await #expect(throws: InteractiveStrokePresentationCacheError
            .physicalCapacityExceeded(
                requested: replacementPeak,
                current: tileBytes + PaintTileDescriptor.residentByteCount,
                highWater: firstAdoptionPeak,
                maximum: firstAdoptionPeak
            )) {
            _ = try await rig.cache.adopt(
                replacement,
                parameters: rig.parameters
            )
        }

        let current = try #require(
            try await rig.cache.current(generation: rig.generation)
        )
        #expect(current.revision == prior.revision)
        #expect(current.prediction?.references == prior.prediction?.references)
        let after = await rig.cache.snapshot()
        #expect(after.totalPhysicalResidentBytes
            == before.totalPhysicalResidentBytes)
        #expect(after.totalPhysicalResidentByteHighWater
            <= after.residentByteBudget)
        #expect(after.provisionalBytes == 0)
        #expect(after.rolledBackRoleCommitCount == 0)
    }

    @Test
    @MainActor
    func adoptionOutlivesRendererAndRetiresCacheOwnershipAfterDeinit()
        async throws
    {
        guard let rig = try makeRig(gateCompletion: true) else { return }
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        var renderer: GridRenderer? = try GridRenderer(
            device: rig.queue.device,
            library: makeShaderLibrary(device: rig.queue.device),
            drawableSize: PatternSize(width: 512, height: 256),
            configuration: TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 512, height: 256),
                finiteConfiguration: .plain
            )
        )
        let releasedRenderer = WeakGridRenderer(renderer)
        let adoption = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: update,
            parameters: rig.parameters,
            terminal: { [weak renderer] _ in renderer != nil }
        )

        renderer = nil
        #expect(releasedRenderer.value == nil)
        try #require(await rig.gate.waitUntilSubmitted())
        #expect(update.acknowledgement.status == .available)
        await rig.gate.open()
        await adoption.value
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(update.presentationEpoch.identity)

        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 1)
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.activeUpdateSlotCount == 0)
        #expect(diagnostic.retirementWaiterCount == 0)
        #expect(diagnostic.provisionalBytes == 0)
    }

    @Test
    @MainActor
    func ownerGoneRetirementFailureRetriesOnAutomaticLifecycleTurn()
        async throws
    {
        guard let rig = try makeRig(
            cacheFailureInjection: .init(retirementFailureCount: 1)
        ) else { return }
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        let adoption = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: update,
            parameters: rig.parameters,
            terminal: { _ in false },
            lifecycleTerminal: { terminal.record($0) }
        )

        await adoption.value
        let diagnostic = await terminal.waitUntilRecorded()

        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 1)
        #expect(diagnostic.retirementState == .idle)
        #expect(diagnostic.retirementFailureCount == 1)
        #expect(diagnostic.retirementErrorDescription == nil)
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.retirementWaiterCount == 0)
    }

    @Test
    @MainActor
    func ownerGoneTaskRetainsSoleCacheThroughBoundedRetirementRetry()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let layerID = UUID()
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: makeShaderLibrary(device: device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 256, height: 256),
                storagePixelSize: PixelSize(width: 256, height: 256),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: layerID),
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 16,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 8
        )
        let capability = try context.beginStrokeSurface()
        let frame = StrokePreparedDisplayFrame.testing(
            capability: capability,
            acknowledgementIsAvailable: true
        )
        let update = try context.makeTransientCacheUpdate(
            frame: frame,
            sequence: 1
        )
        let gate = InteractiveStrokePresentationCacheGate(
            initiallyOpen: true,
            blocksRetirementRetry: true
        )
        defer { Task { await gate.releaseAll() } }
        var cache: InteractiveStrokePresentationCache? =
            InteractiveStrokePresentationCache(
                device: device,
                commandQueue: queue,
                byteBudget: PaintTileDescriptor.residentByteCount * 8,
                maximumTileCount: 4,
                completionGate: gate,
                failureInjection: .init(retirementFailureCount: 1)
            )
        let weakCache = WeakInteractiveStrokePresentationCache(cache)
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        var operation: Task<Void, Never>? =
            InteractiveStrokeCacheAdoptionOperation.start(
                cache: cache!,
                update: update,
                parameters: .init(blendMode: .normal, opacity: 1),
                terminal: { _ in false },
                lifecycleTerminal: { terminal.record($0) }
            )
        cache = nil

        try #require(await gate.waitUntilRetirementRetryBlocked())
        #expect(weakCache.value != nil)
        #expect(update.acknowledgement.status == .fulfilled)
        await gate.releaseRetirementRetry()
        await operation?.value
        let diagnostic = await terminal.waitUntilRecorded()
        operation = nil

        #expect(diagnostic.retirementFailureCount == 1)
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.retirementWaiterCount == 0)
        #expect(diagnostic.provisionalBytes == 0)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
        #expect(weakCache.value == nil)
    }

    @Test
    @MainActor
    func ownerGoneCoordinatorRetainsSoleCacheAcrossRepeatedACKFailures()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let layerID = UUID()
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: makeShaderLibrary(device: device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 256, height: 256),
                storagePixelSize: PixelSize(width: 256, height: 256),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: layerID),
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 16,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 8
        )
        let capability = try context.beginStrokeSurface()
        let failure = StrokePreparationFailure.unexpected(
            "repeated owner-gone ACK failure"
        )
        let frame = StrokePreparedDisplayFrame.testing(
            capability: capability,
            acknowledgementIsAvailable: true,
            acknowledgementReleaseFailures: [failure, failure]
        )
        let update = try context.makeTransientCacheUpdate(
            frame: frame,
            sequence: 1
        )
        let gate = InteractiveStrokePresentationCacheGate(
            initiallyOpen: true,
            blocksLifecycleRetry: true
        )
        defer { Task { await gate.releaseAll() } }
        var cache: InteractiveStrokePresentationCache? =
            InteractiveStrokePresentationCache(
                device: device,
                commandQueue: queue,
                byteBudget: PaintTileDescriptor.residentByteCount * 8,
                maximumTileCount: 4,
                completionGate: gate
            )
        let weakCache = WeakInteractiveStrokePresentationCache(cache)
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        var operation: Task<Void, Never>? =
            InteractiveStrokeCacheAdoptionOperation.start(
                cache: cache!,
                update: update,
                parameters: .init(blendMode: .normal, opacity: 1),
                terminal: { _ in false },
                lifecycleTerminal: { terminal.record($0) }
            )
        cache = nil

        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 1))
        #expect(weakCache.value != nil)
        #expect(update.acknowledgement.testingRequestCount == 1)
        await gate.releaseOneLifecycleRetry()
        try #require(await gate.waitUntilAcknowledgementFailure(count: 2))
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 2))
        #expect(update.acknowledgement.testingRequestCount == 2)
        #expect(update.acknowledgement.status
            == .failed(.schedulerReleaseFailed(failure)))
        await gate.releaseOneLifecycleRetry()
        await operation?.value
        let diagnostic = await terminal.waitUntilRecorded()
        operation = nil

        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 3)
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
        #expect(diagnostic.acknowledgementSettlementCount == 1)
        #expect(weakCache.value == nil)
    }

    @Test
    @MainActor
    func liveOwnerLossStillRetriesExactACKThroughDurableHandoff()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let layerID = UUID()
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: makeShaderLibrary(device: device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 256, height: 256),
                storagePixelSize: PixelSize(width: 256, height: 256),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: layerID),
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 16,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 8
        )
        let capability = try context.beginStrokeSurface()
        let failure = StrokePreparationFailure.unexpected(
            "live renderer ACK failure"
        )
        let update = try context.makeTransientCacheUpdate(
            frame: .testing(
                capability: capability,
                acknowledgementIsAvailable: true,
                acknowledgementReleaseFailures: [failure, failure]
            ),
            sequence: 1
        )
        let gate = InteractiveStrokePresentationCacheGate(
            initiallyOpen: true,
            blocksLifecycleRetry: true
        )
        defer { Task { await gate.releaseAll() } }
        var cache: InteractiveStrokePresentationCache? =
            InteractiveStrokePresentationCache(
                device: device,
                commandQueue: queue,
                byteBudget: PaintTileDescriptor.residentByteCount * 8,
                maximumTileCount: 4,
                completionGate: gate
            )
        let weakCache = WeakInteractiveStrokePresentationCache(cache)
        var liveOwner: InteractiveStrokeLifecycleOwnerProbe? = .init()
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        var operation: Task<Void, Never>? =
            InteractiveStrokeCacheAdoptionOperation.start(
                cache: cache!,
                update: update,
                parameters: .init(blendMode: .normal, opacity: 1),
                terminal: { [weak liveOwner] _ in liveOwner != nil },
                lifecycleTerminal: { terminal.record($0) }
            )
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 1))
        try #require(await gate.lifecycleRetryScheduleCountSnapshot == 1)
        try #require(await gate.lifecycleRetryWaiterCount == 1)
        #expect(weakCache.value != nil)
        liveOwner = nil
        cache = nil
        await gate.releaseOneLifecycleRetry()
        try #require(await gate.waitUntilAcknowledgementFailure(count: 2))
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 2))
        #expect(await gate.lifecycleRetryWaiterCount == 1)
        await gate.releaseOneLifecycleRetry()
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForAcknowledgement(update.presentationEpoch.identity)
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .cancelRetainedLifecycle(update.presentationEpoch.identity)
        let diagnostic = await terminal.waitUntilRecorded()
        await operation?.value
        operation = nil

        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 3)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
        #expect(weakCache.value == nil)
    }

    @Test
    @MainActor
    func cancelDuringActiveACKRetryRetainsCreditAndTerminatesOnce()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let failure = StrokePreparationFailure.unexpected(
            "cancel during active ACK retry"
        )
        let frame = StrokePreparedDisplayFrame.testing(
            capability: rig.capability,
            acknowledgementIsAvailable: true,
            acknowledgementReleaseFailures: [failure, failure]
        )
        let update = try rig.context.makeTransientCacheUpdate(
            frame: frame,
            sequence: 1
        )
        let gate = InteractiveStrokePresentationCacheGate(
            initiallyOpen: true,
            blocksLifecycleRetry: true,
            blocksAcknowledgementFailureAt: 2
        )
        defer { Task { await gate.releaseAll() } }
        let cache = InteractiveStrokePresentationCache(
            device: rig.queue.device,
            commandQueue: rig.queue,
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            maximumTileCount: 4,
            completionGate: gate,
            failureInjection: .init(retirementFailureCount: 1)
        )
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        let failures = InteractiveStrokeLifecycleFailureProbe()
        let operation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: cache,
            update: update,
            parameters: rig.parameters,
            terminal: { _ in true },
            lifecycleTerminal: { terminal.record($0) }
        )
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 1))
        await gate.releaseOneLifecycleRetry()
        try #require(await gate.waitUntilBlockedAcknowledgementFailure())

        InteractiveStrokeCacheLifecycleCoordinator.shared
            .requestCancellation(
                cache: cache,
                strokeEpoch: update.presentationEpoch,
                failureTerminal: { failures.record($0) }
            )
        if terminal.snapshot != nil {
            Issue.record("cancellation terminalized an active ACK obligation")
            await gate.releaseBlockedAcknowledgementFailure()
            return
        }
        #expect((await cache.snapshot())
            .pendingPreparedAcknowledgementCount == 1)
        #expect(update.acknowledgement.testingRequestCount == 2)

        await gate.releaseBlockedAcknowledgementFailure()
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 2))
        await gate.releaseOneLifecycleRetry()
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 3))
        #expect(failures.count == 1)
        #expect(failures.descriptions == [String(describing:
            InteractiveStrokePresentationCacheError
                .injectedRetirementFailure(
                    update.presentationEpoch.identity
                )
        )])
        await gate.releaseOneLifecycleRetry()
        let diagnostic = await terminal.waitUntilRecorded()
        await operation.value

        #expect(terminal.recordCount == 1)
        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 3)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
    }

    @Test
    @MainActor
    func cancellingOwnerGoneLifecycleUsesItsOnlyScheduledRetry()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let layerID = UUID()
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: makeShaderLibrary(device: device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 256, height: 256),
                storagePixelSize: PixelSize(width: 256, height: 256),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: layerID),
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 16,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 8
        )
        let capability = try context.beginStrokeSurface()
        let frame = StrokePreparedDisplayFrame.testing(
            capability: capability,
            acknowledgementIsAvailable: true
        )
        let update = try context.makeTransientCacheUpdate(
            frame: frame,
            sequence: 1
        )
        let gate = InteractiveStrokePresentationCacheGate(
            initiallyOpen: true,
            blocksLifecycleRetry: true
        )
        defer { Task { await gate.releaseAll() } }
        var cache: InteractiveStrokePresentationCache? =
            InteractiveStrokePresentationCache(
                device: device,
                commandQueue: queue,
                byteBudget: PaintTileDescriptor.residentByteCount * 8,
                maximumTileCount: 4,
                completionGate: gate,
                failureInjection: .init(retirementFailureCount: 1)
            )
        let weakCache = WeakInteractiveStrokePresentationCache(cache)
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        var operation: Task<Void, Never>? =
            InteractiveStrokeCacheAdoptionOperation.start(
                cache: cache!,
                update: update,
                parameters: .init(blendMode: .normal, opacity: 1),
                terminal: { _ in false },
                lifecycleTerminal: { terminal.record($0) }
            )
        cache = nil

        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 1))
        #expect(await gate.lifecycleRetryScheduleCountSnapshot == 1)
        #expect(await gate.lifecycleRetryWaiterCount == 1)
        #expect(weakCache.value != nil)
        #expect(update.acknowledgement.status == .fulfilled)

        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .cancelRetainedLifecycle(update.presentationEpoch.identity)
        #expect(await gate.lifecycleRetryWaiterCount == 1)
        #expect(await gate.lifecycleRetryWaiterHighWaterSnapshot == 1)
        await gate.releaseOneLifecycleRetry()
        await operation?.value
        operation = nil
        let diagnostic = await terminal.waitUntilRecorded()

        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.retirementWaiterCount == 0)
        #expect(diagnostic.provisionalBytes == 0)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
        #expect(await gate.lifecycleRetryWaiterCount == 0)
        #expect(await gate.lifecycleRetryWaiterHighWaterSnapshot == 1)
        #expect(weakCache.value == nil)
    }

    @Test
    @MainActor
    func repeatedRetirementFailuresPreservePhysicalStateUntilRetrySucceeds()
        async throws
    {
        guard let rig = try makeRig(
            cacheFailureInjection: .init(retirementFailureCount: 2)
        ) else { return }
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        _ = try await rig.cache.adopt(update, parameters: rig.parameters)
        let published = await rig.cache.snapshot()
        #expect(published.residentBytes > 0)
        #expect(published.totalPhysicalResidentBytes > 0)
        #expect(published.componentCoverageBytes > 0)

        for _ in 0..<2 {
            await #expect(
                throws: InteractiveStrokePresentationCacheError
                    .injectedRetirementFailure(
                        rig.capability.presentationEpoch.identity
                    )
            ) {
                try await rig.cache.retire(
                    strokeEpoch: rig.capability.presentationEpoch
                )
            }
        }
        let retained = await rig.cache.snapshot()
        #expect(retained.residentBytes == published.residentBytes)
        #expect(retained.totalPhysicalResidentBytes
            == published.totalPhysicalResidentBytes)
        #expect(retained.componentCoverageBytes
            == published.componentCoverageBytes)
        #expect(retained.activeStrokeEpochCount == 1)
        #expect(!retained.isIdle)

        try await rig.cache.retire(
            strokeEpoch: rig.capability.presentationEpoch
        )

        let terminal = await rig.cache.snapshot()
        #expect(terminal.residentBytes == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.componentCoverageBytes == 0)
        #expect(terminal.backingBytes == 0)
        #expect(terminal.provisionalBytes == 0)
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.activeUpdateOwnerCount == 0)
        #expect(terminal.retirementWaiterCount == 0)
        #expect(terminal.pendingPreparedAcknowledgementCount == 0)
        #expect(terminal.retirementState == .idle)
    }

    @Test
    @MainActor
    func terminalRetirementKeepsEscapedProviderAndLeaseInGlobalBudget()
        async throws
    {
        let firstAdoptionPeak = PaintTileDescriptor.residentByteCount * 4
        guard let rig = try makeRig(
            maximumTileCount: 1,
            cacheByteBudget: firstAdoptionPeak,
            cacheFailureInjection: .init(retirementFailureCount: 1)
        ) else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [coordinate],
            sequence: 1
        )
        _ = try await rig.cache.adopt(update, parameters: rig.parameters)
        var provider: TiledRasterExactReferenceProvider? = try #require(
            try await rig.cache.current(generation: rig.generation)?
                .authoritative
        )
        var capture: TiledRasterExactReferenceCapture? = try
            TiledRasterExactReferenceCapture(providers: [provider!])
        var escapedLease: TiledRasterExactReferenceLease? = try provider!
            .leaseExactReferences(
                provider!.references,
                using: capture!,
                pinReasons: [.visible]
            )
        await #expect(throws: (any Error).self) {
            try await rig.cache.retire(
                strokeEpoch: rig.capability.presentationEpoch
            )
        }
        await #expect(throws: (any Error).self) {
            try await rig.cache.retire(
                strokeEpoch: rig.capability.presentationEpoch
            )
        }

        var retained = await rig.cache.snapshot()
        #expect(retained.totalPhysicalResidentBytes > 0)
        #expect(retained.activeExternalLeaseCount == 1)
        #expect(!retained.isIdle)

        let nextContext = try DocumentPaintRenderContext(
            device: rig.queue.device,
            commandQueue: rig.queue,
            library: makeShaderLibrary(device: rig.queue.device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 512, height: 256),
                storagePixelSize: PixelSize(width: 512, height: 256),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: update.layerID),
            byteBudget: PaintTileDescriptor.residentByteCount * 16,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 32,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 16,
            generation: rig.generation
        )
        let nextCapability = try nextContext.beginStrokeSurface()
        let nextFrame = StrokePreparedDisplayFrame.testing(
            capability: nextCapability,
            changedCoordinates: [.init(x: 1, y: 0)],
            acknowledgementIsAvailable: true
        )
        let next = try nextContext.makeTransientCacheUpdate(
            frame: nextFrame,
            sequence: 2
        )
        await #expect(
            throws: InteractiveStrokePresentationCacheError.self
        ) {
            _ = try await rig.cache.adopt(next, parameters: rig.parameters)
        }
        retained = await rig.cache.snapshot()
        #expect(retained.totalPhysicalResidentBytes
            <= retained.residentByteBudget)

        try escapedLease?.returnLease()
        escapedLease = nil
        try await rig.cache.retire(
            strokeEpoch: rig.capability.presentationEpoch
        )
        capture?.close()
        capture = nil
        provider = nil
        let reclaimed = await rig.cache.snapshot()
        #expect(reclaimed.totalPhysicalResidentBytes == 0)
        #expect(reclaimed.activeExternalLeaseCount == 0)
        #expect(reclaimed.isIdle)
    }

    @Test
    @MainActor
    func retiredBackingBytesRemainPhysicalAndBlockOverBudgetAdoption()
        async throws
    {
        let firstAdoptionPeak = PaintTileDescriptor.residentByteCount * 4
        guard let rig = try makeRig(
            maximumTileCount: 1,
            cacheByteBudget: firstAdoptionPeak
        ) else { return }
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        _ = try await rig.cache.adopt(first, parameters: rig.parameters)
        var provider: TiledRasterExactReferenceProvider? = try #require(
            try await rig.cache.current(generation: rig.generation)?
                .authoritative
        )
        var capture: TiledRasterExactReferenceCapture? = try
            TiledRasterExactReferenceCapture(providers: [provider!])
        try await rig.cache.retire(
            strokeEpoch: rig.capability.presentationEpoch
        )
        _ = try provider?.applyMemoryPressure(targetResidentBytes: 0)

        var retained = await rig.cache.snapshot()
        #expect(retained.backingBytes == PaintTileDescriptor.residentByteCount)
        #expect(retained.totalPhysicalResidentBytes
            == retained.backingBytes
                + PaintTileDescriptor.residentByteCount)
        #expect(!retained.isIdle)

        let nextContext = try DocumentPaintRenderContext(
            device: rig.queue.device,
            commandQueue: rig.queue,
            library: makeShaderLibrary(device: rig.queue.device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 512, height: 256),
                storagePixelSize: PixelSize(width: 512, height: 256),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: first.layerID),
            byteBudget: PaintTileDescriptor.residentByteCount * 16,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 32,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 16,
            generation: rig.generation
        )
        let nextCapability = try nextContext.beginStrokeSurface()
        let nextReservation = try nextCapability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            pinReasons: [.visible, .inFlight],
            workspace: PaintTileStrokeLeaseWorkspace(maximumBindingCount: 1),
            failureInjection: nil
        )
        try nextCapability.testingMarkDirty(nextReservation)
        try nextCapability.releaseFrameReservations(
            authoritative: nextReservation,
            prediction: nil
        )
        func update(sequence: UInt64) throws
            -> DocumentPaintTransientCacheUpdate
        {
            try nextContext.makeTransientCacheUpdate(
                frame: .testing(
                    capability: nextCapability,
                    changedCoordinates: [.init(x: 1, y: 0)],
                    acknowledgementIsAvailable: true
                ),
                sequence: sequence
            )
        }
        let blocked = try update(sequence: 2)
        await #expect(
            throws: InteractiveStrokePresentationCacheError
                .physicalCapacityExceeded(
                    requested: PaintTileDescriptor.residentByteCount * 4
                        + PaintTileDescriptor.residentByteCount / 2,
                    current: PaintTileDescriptor.residentByteCount * 2,
                    highWater: firstAdoptionPeak,
                    maximum: firstAdoptionPeak
                )
        ) {
            _ = try await rig.cache.adopt(
                blocked,
                parameters: rig.parameters
            )
        }

        capture?.close()
        capture = nil
        provider = nil
        retained = await rig.cache.snapshot()
        #expect(retained.backingBytes == 0)
        let admitted = try update(sequence: 3)
        _ = try await rig.cache.adopt(admitted, parameters: rig.parameters)
        let final = await rig.cache.snapshot()
        #expect(final.totalPhysicalResidentBytes <= final.residentByteBudget)
        #expect(final.totalPhysicalResidentByteHighWater
            <= final.residentByteBudget)
    }

    @Test
    @MainActor
    func cancelDuringRetirementWaitsPastTwoTurnsForExactLease()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        _ = try await rig.cache.adopt(update, parameters: rig.parameters)
        let gate = InteractiveStrokePresentationCacheGate(
            initiallyOpen: true,
            blocksRetirementRetry: true,
            blocksLifecycleRetry: true
        )
        defer { Task { await gate.releaseAll() } }
        let cache = InteractiveStrokePresentationCache(
            device: rig.queue.device,
            commandQueue: rig.queue,
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            maximumTileCount: 4,
            completionGate: gate
        )
        let copied = try rig.context.makeTransientCacheUpdate(
            frame: .testing(
                capability: rig.capability,
                changedCoordinates: [.init(x: 0, y: 0)],
                acknowledgementIsAvailable: true
            ),
            sequence: 2
        )
        _ = try await cache.adopt(copied, parameters: rig.parameters)
        let cachedProvider = try #require(
            try await cache.current(generation: rig.generation)?
                .authoritative
        )
        let cachedCapture = try TiledRasterExactReferenceCapture(
            providers: [cachedProvider]
        )
        let cachedLease = try cachedProvider.leaseExactReferences(
            cachedProvider.references,
            using: cachedCapture,
            pinReasons: [.visible]
        )
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        let failures = InteractiveStrokeLifecycleFailureProbe()
        InteractiveStrokeCacheLifecycleCoordinator.shared.requestRetirement(
            cache: cache,
            strokeEpoch: copied.presentationEpoch,
            lifecycleTerminal: { terminal.record($0) },
            failureTerminal: { failures.record($0) }
        )
        try #require(await gate.waitUntilRetirementRetryBlocked())

        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .cancelRetainedLifecycle(copied.presentationEpoch.identity)
        #expect(terminal.snapshot == nil)
        await gate.releaseRetirementRetry()
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 1))
        #expect(await gate.lifecycleRetryWaiterCount == 1)
        await gate.releaseOneLifecycleRetry()
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 2))
        #expect(await gate.lifecycleRetryWaiterCount == 1)
        await gate.releaseOneLifecycleRetry()
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 3))
        #expect(await gate.lifecycleRetryWaiterCount == 1)
        #expect(terminal.snapshot == nil)
        #expect(failures.count == 1)

        try cachedLease.returnLease()
        await gate.releaseOneLifecycleRetry()
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 4))
        guard terminal.snapshot == nil else {
            cachedCapture.close()
            Issue.record(
                "lifecycle terminalized while an exact capture retained bytes"
            )
            return
        }
        let providerRetained = await cache.snapshot()
        #expect(providerRetained.activeStrokeEpochCount == 0)
        #expect(providerRetained.activeExternalLeaseCount == 0)
        #expect(providerRetained.totalPhysicalResidentBytes > 0)
        #expect(!providerRetained.isIdle)
        #expect(await gate.lifecycleRetryWaiterCount == 1)

        cachedCapture.close()
        await gate.releaseOneLifecycleRetry()
        let diagnostic = await terminal.waitUntilRecorded()

        #expect(terminal.recordCount == 1)
        #expect(diagnostic.retirementFailureCount == 3)
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeExternalLeaseCount == 0)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
        #expect(diagnostic.totalPhysicalResidentBytes == 0)
        #expect(diagnostic.isIdle)
    }

    @Test
    @MainActor
    func intentUpgradeNeverOverlapsLifecycleRetryWaiters() async throws {
        guard let rig = try makeRig() else { return }
        let gate = InteractiveStrokePresentationCacheGate(
            initiallyOpen: true,
            blocksLifecycleRetry: true
        )
        defer { Task { await gate.releaseAll() } }
        let cache = InteractiveStrokePresentationCache(
            device: rig.queue.device,
            commandQueue: rig.queue,
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            maximumTileCount: 4,
            completionGate: gate
        )
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        _ = try await cache.adopt(update, parameters: rig.parameters)
        let provider = try #require(
            try await cache.current(generation: rig.generation)?
                .authoritative
        )
        let capture = try TiledRasterExactReferenceCapture(
            providers: [provider]
        )
        let lease = try provider.leaseExactReferences(
            provider.references,
            using: capture,
            pinReasons: [.visible]
        )
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        InteractiveStrokeCacheLifecycleCoordinator.shared.requestRetirement(
            cache: cache,
            strokeEpoch: update.presentationEpoch,
            lifecycleTerminal: { terminal.record($0) }
        )
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 1))
        #expect(await gate.lifecycleRetryWaiterCount == 1)

        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .cancelRetainedLifecycle(update.presentationEpoch.identity)
        #expect(await gate.lifecycleRetryWaiterCount == 1)
        #expect(await gate.lifecycleRetryWaiterHighWaterSnapshot == 1)
        await gate.releaseOneLifecycleRetry()
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 2))
        #expect(await gate.lifecycleRetryWaiterCount == 1)
        #expect(await gate.lifecycleRetryWaiterHighWaterSnapshot == 1)

        try lease.returnLease()
        capture.close()
        await gate.releaseOneLifecycleRetry()
        let final = await terminal.waitUntilRecorded()
        #expect(final.isIdle)
        #expect(final.totalPhysicalResidentBytes == 0)
        #expect(await gate.lifecycleRetryWaiterHighWaterSnapshot == 1)
    }

    @Test
    @MainActor
    func nilReporterDoesNotConsumeLaterRetirementFailureReport()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let gate = InteractiveStrokePresentationCacheGate(
            initiallyOpen: true,
            blocksLifecycleRetry: true
        )
        defer { Task { await gate.releaseAll() } }
        let cache = InteractiveStrokePresentationCache(
            device: rig.queue.device,
            commandQueue: rig.queue,
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            maximumTileCount: 4,
            completionGate: gate,
            failureInjection: .init(retirementFailureCount: 2)
        )
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        _ = try await cache.adopt(update, parameters: rig.parameters)
        InteractiveStrokeCacheLifecycleCoordinator.shared.requestRetirement(
            cache: cache,
            strokeEpoch: update.presentationEpoch
        )
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 1))

        let failures = InteractiveStrokeLifecycleFailureProbe()
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        InteractiveStrokeCacheLifecycleCoordinator.shared.requestCancellation(
            cache: cache,
            strokeEpoch: update.presentationEpoch,
            lifecycleTerminal: { terminal.record($0) },
            failureTerminal: { failures.record($0) }
        )
        await gate.releaseOneLifecycleRetry()
        try #require(await gate.waitUntilLifecycleRetryScheduled(count: 2))
        #expect(failures.count == 1)
        #expect(await gate.lifecycleRetryWaiterHighWaterSnapshot == 1)

        await gate.releaseOneLifecycleRetry()
        let final = await terminal.waitUntilRecorded()
        #expect(failures.count == 1)
        #expect(final.retirementFailureCount == 2)
        #expect(final.isIdle)
    }

    @Test
    @MainActor
    func multiPageEpochVersionsACKWaitersAndBoundsTerminalOwnership()
        async throws
    {
        guard let rig = try makeRig(blocksLifecycleRetry: true) else {
            return
        }
        defer { Task { await rig.gate.releaseAll() } }
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        var firstOperation: Task<Void, Never>? =
            InteractiveStrokeCacheAdoptionOperation.start(
                cache: rig.cache,
                update: first,
                parameters: rig.parameters,
                terminal: { _ in true },
                lifecycleTerminal: { terminal.record($0) }
            )
        await firstOperation?.value
        firstOperation = nil
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForAcknowledgement(first.presentationEpoch.identity)
        #expect(first.acknowledgement.status == .fulfilled)
        #expect(terminal.recordCount == 0)

        let failure = StrokePreparationFailure.unexpected(
            "second page ACK failure"
        )
        let second = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2,
            acknowledgementReleaseFailures: [failure]
        )
        var secondOperation: Task<Void, Never>? =
            InteractiveStrokeCacheAdoptionOperation.start(
                cache: rig.cache,
                update: second,
                parameters: rig.parameters,
                terminal: { _ in true },
                lifecycleTerminal: { terminal.record($0) }
            )
        let acknowledgementWaitProbe =
            InteractiveStrokeCacheLifecycleTerminalProbe()
        let acknowledgementWait = Task { @MainActor in
            await InteractiveStrokeCacheLifecycleCoordinator.shared
                .waitForAcknowledgement(second.presentationEpoch.identity)
            acknowledgementWaitProbe.record(await rig.cache.snapshot())
        }
        try #require(
            await rig.gate.waitUntilLifecycleRetryScheduled(count: 1)
        )
        #expect(second.acknowledgement.testingRequestCount == 1)
        #expect(second.acknowledgement.status
            == .failed(.schedulerReleaseFailed(failure)))
        #expect(terminal.recordCount == 0)
        #expect(acknowledgementWaitProbe.recordCount == 0)
        await rig.gate.releaseOneLifecycleRetry()
        await secondOperation?.value
        secondOperation = nil
        await acknowledgementWait.value

        #expect(second.acknowledgement.status == .fulfilled)
        #expect(second.acknowledgement.testingRequestCount == 2)
        #expect(terminal.recordCount == 0)
        #expect(acknowledgementWaitProbe.recordCount == 1)
        InteractiveStrokeCacheLifecycleCoordinator.shared.requestCancellation(
            cache: rig.cache,
            strokeEpoch: second.presentationEpoch,
            lifecycleTerminal: { terminal.record($0) }
        )
        let final = await terminal.waitUntilRecorded()
        #expect(terminal.recordCount == 1)
        #expect(final.isIdle)
        #expect(!InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(second.presentationEpoch.identity))
    }

    @Test
    @MainActor
    func concurrentHandoffsPreserveStaleOwnerLossRetirementIntent()
        async throws
    {
        guard let rig = try makeRig(
            gateCompletion: true,
            blocksLifecycleRetry: true
        ) else { return }
        defer { Task { await rig.gate.releaseAll() } }
        let failure = StrokePreparationFailure.unexpected(
            "first concurrent page delayed ACK"
        )
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1,
            acknowledgementReleaseFailures: [failure]
        )
        let second = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2
        )
        let terminal = InteractiveStrokeCacheLifecycleTerminalProbe()
        let firstOperation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: first,
            parameters: rig.parameters,
            terminal: { _ in false },
            lifecycleTerminal: { terminal.record($0) }
        )
        try #require(await rig.gate.waitUntilSubmitted())
        let secondOperation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: second,
            parameters: rig.parameters,
            terminal: { _ in true },
            lifecycleTerminal: { terminal.record($0) }
        )

        await rig.gate.open()
        try #require(
            await rig.gate.waitUntilLifecycleRetryScheduled(count: 1)
        )
        #expect(first.acknowledgement.testingRequestCount == 1)
        #expect(second.acknowledgement.testingRequestCount == 0)
        #expect(terminal.recordCount == 0)
        await rig.gate.releaseOneLifecycleRetry()
        await firstOperation.value
        await secondOperation.value
        let final = await terminal.waitUntilRecorded()

        #expect(first.acknowledgement.status == .fulfilled)
        #expect(second.acknowledgement.status == .fulfilled)
        #expect(first.acknowledgement.testingRequestCount == 2)
        #expect(second.acknowledgement.testingRequestCount == 1)
        #expect(terminal.recordCount == 1)
        #expect(final.isIdle)
        #expect(!InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(first.presentationEpoch.identity))
        #expect((await rig.cache.snapshot()).isIdle)
    }

    @Test
    @MainActor
    func handoffQueuedDuringRetirementWaitSettlesBeforeTerminal()
        async throws
    {
        guard let rig = try makeRig(
            blocksLifecycleRetry: true,
            cacheFailureInjection: .init(retirementFailureCount: 1)
        ) else { return }
        defer { Task { await rig.gate.releaseAll() } }
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let firstOperation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: first,
            parameters: rig.parameters,
            terminal: { _ in true }
        )
        await firstOperation.value

        let retirement = InteractiveStrokeCacheLifecycleTerminalProbe()
        InteractiveStrokeCacheLifecycleCoordinator.shared.requestRetirement(
            cache: rig.cache,
            strokeEpoch: first.presentationEpoch,
            lifecycleTerminal: { retirement.record($0) }
        )
        try #require(
            await rig.gate.waitUntilLifecycleRetryScheduled(count: 1)
        )

        let late = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2
        )
        let lateLifecycle = InteractiveStrokeCacheLifecycleTerminalProbe()
        let lateOperation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: late,
            parameters: rig.parameters,
            terminal: { _ in true },
            lifecycleTerminal: { lateLifecycle.record($0) }
        )
        #expect(late.acknowledgement.testingRequestCount == 0)
        #expect(retirement.recordCount == 0)
        #expect(lateLifecycle.recordCount == 0)
        #expect(await rig.gate.lifecycleRetryWaiterHighWaterSnapshot == 1)

        await rig.gate.releaseOneLifecycleRetry()
        await lateOperation.value
        let final = await retirement.waitUntilRecorded()

        #expect(late.acknowledgement.status == .fulfilled)
        #expect(late.acknowledgement.testingRequestCount == 1)
        #expect(retirement.recordCount == 1)
        #expect(lateLifecycle.recordCount == 0)
        #expect(final.isIdle)
        #expect(!InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(first.presentationEpoch.identity))
    }

    @Test
    @MainActor
    func laterPageWaitsForExactEarlierACKRetryBeforeAdoption()
        async throws
    {
        guard let rig = try makeRig(
            blocksLifecycleRetry: true
        ) else { return }
        defer { Task { await rig.gate.releaseAll() } }
        let failure = StrokePreparationFailure.unexpected(
            "first page delayed ACK retry"
        )
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1,
            acknowledgementReleaseFailures: [failure]
        )
        let firstOperation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: first,
            parameters: rig.parameters,
            terminal: { _ in true }
        )
        try #require(
            await rig.gate.waitUntilLifecycleRetryScheduled(count: 1)
        )

        let second = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2
        )
        let secondOperation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: second,
            parameters: rig.parameters,
            terminal: { _ in true }
        )
        #expect(first.acknowledgement.testingRequestCount == 1)
        #expect(second.acknowledgement.testingRequestCount == 0)

        await rig.gate.releaseOneLifecycleRetry()
        await firstOperation.value
        await secondOperation.value
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForAcknowledgement(second.presentationEpoch.identity)

        #expect(first.acknowledgement.status == .fulfilled)
        #expect(first.acknowledgement.testingRequestCount == 2)
        #expect(second.acknowledgement.status == .fulfilled)
        #expect(second.acknowledgement.testingRequestCount == 1)
        InteractiveStrokeCacheLifecycleCoordinator.shared.requestCancellation(
            cache: rig.cache,
            strokeEpoch: second.presentationEpoch
        )
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(second.presentationEpoch.identity)
        #expect((await rig.cache.snapshot()).isIdle)
    }

    @Test
    @MainActor
    func distinctEpochWaitsForCacheWideACKAndRetirementOwnership()
        async throws
    {
        guard let rig = try makeRig(blocksLifecycleRetry: true) else {
            return
        }
        defer { Task { await rig.gate.releaseAll() } }
        let firstFailure = StrokePreparationFailure.unexpected(
            "first epoch delayed ACK"
        )
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1,
            acknowledgementReleaseFailures: [firstFailure]
        )
        let firstLifecycle = InteractiveStrokeCacheLifecycleTerminalProbe()
        let firstOperation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: first,
            parameters: rig.parameters,
            terminal: { _ in false },
            lifecycleTerminal: { firstLifecycle.record($0) }
        )
        try #require(
            await rig.gate.waitUntilLifecycleRetryScheduled(count: 1)
        )

        let secondContext = try DocumentPaintRenderContext(
            device: rig.queue.device,
            commandQueue: rig.queue,
            library: makeShaderLibrary(device: rig.queue.device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 512, height: 256),
                storagePixelSize: PixelSize(width: 512, height: 256),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: first.layerID),
            byteBudget: PaintTileDescriptor.residentByteCount * 16,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 32,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 16,
            generation: rig.generation
        )
        let secondCapability = try secondContext.beginStrokeSurface()
        let secondFrame = StrokePreparedDisplayFrame.testing(
            capability: secondCapability,
            changedCoordinates: [.init(x: 1, y: 0)],
            acknowledgementIsAvailable: true
        )
        let second = try secondContext.makeTransientCacheUpdate(
            frame: secondFrame,
            sequence: 1
        )
        let secondLifecycle = InteractiveStrokeCacheLifecycleTerminalProbe()
        let secondOperation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: second,
            parameters: rig.parameters,
            terminal: { _ in false },
            lifecycleTerminal: { secondLifecycle.record($0) }
        )

        #expect(first.acknowledgement.testingRequestCount == 1)
        #expect(second.acknowledgement.testingRequestCount == 0)
        #expect(firstLifecycle.recordCount == 0)
        #expect(secondLifecycle.recordCount == 0)

        await rig.gate.releaseOneLifecycleRetry()
        try #require(await firstLifecycle.waitUntilRecordCount(1))
        try #require(await secondLifecycle.waitUntilRecordCount(1))
        await firstOperation.value
        await secondOperation.value

        #expect(first.acknowledgement.status == .fulfilled)
        #expect(first.acknowledgement.testingRequestCount == 2)
        #expect(second.acknowledgement.status == .fulfilled)
        #expect(second.acknowledgement.testingRequestCount == 1)
        #expect(firstLifecycle.recordCount == 1)
        #expect(secondLifecycle.recordCount == 1)
        #expect(!InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(first.presentationEpoch.identity))
        #expect(!InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(second.presentationEpoch.identity))
        #expect((await rig.cache.snapshot()).isIdle)
    }

    @Test
    @MainActor
    func firstAdoptionCannotResurrectCompletedEpochCancellation()
        async throws
    {
        guard let rig = try makeRig(blocksLifecycleRetry: true) else {
            return
        }
        defer { Task { await rig.gate.releaseAll() } }
        let acknowledgementFailure = StrokePreparationFailure.unexpected(
            "late retired adoption ACK"
        )
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1,
            acknowledgementReleaseFailures: [acknowledgementFailure]
        )
        let cancelled = InteractiveStrokeCacheLifecycleTerminalProbe()
        InteractiveStrokeCacheLifecycleCoordinator.shared.requestCancellation(
            cache: rig.cache,
            strokeEpoch: update.presentationEpoch,
            lifecycleTerminal: { cancelled.record($0) }
        )
        _ = await cancelled.waitUntilRecorded()
        #expect(!InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(update.presentationEpoch.identity))

        let late = InteractiveStrokeCacheLifecycleTerminalProbe()
        let operation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: update,
            parameters: rig.parameters,
            terminal: { _ in true },
            lifecycleTerminal: { late.record($0) }
        )
        try #require(
            await rig.gate.waitUntilLifecycleRetryScheduled(count: 1)
        )
        #expect(update.acknowledgement.testingRequestCount == 1)
        #expect(update.acknowledgement.status == .failed(
            .schedulerReleaseFailed(acknowledgementFailure)
        ))
        #expect(late.recordCount == 0)
        #expect(InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(update.presentationEpoch.identity))
        await rig.gate.releaseOneLifecycleRetry()
        await operation.value
        _ = await late.waitUntilRecorded()

        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 2)
        #expect(!InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(update.presentationEpoch.identity))
        #expect((await rig.cache.snapshot()).isIdle)
        #expect(late.recordCount == 1)
    }

    @Test
    @MainActor
    func cancellationSettlesOnceAndPreservesPriorRevision() async throws {
        guard let rig = try makeRig() else { return }
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        _ = try await rig.cache.adopt(first, parameters: rig.parameters)
        let previous = try #require(
            try await rig.cache.current(generation: rig.generation)
        )

        await rig.gate.close()
        let cancelled = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2
        )
        let task = Task {
            try await rig.cache.adopt(cancelled, parameters: rig.parameters)
        }
        try #require(await rig.gate.waitUntilSubmitted(count: 2))
        task.cancel()
        await rig.gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(cancelled.acknowledgement.status == .fulfilled)
        #expect(cancelled.acknowledgement.testingRequestCount == 1)
        #expect(try await rig.cache.current(generation: rig.generation)?
            .revision == previous.revision)
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.cancelledUpdateCount == 1)
        #expect(diagnostic.acknowledgementSettlementCount == 2)
        #expect(diagnostic.activeUpdateSlotCount == 1)
    }

    @Test
    @MainActor
    func capacityFailureSettlesExactAcknowledgementOnce() async throws {
        guard let rig = try makeRig(maximumTileCount: 1) else { return }
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [
                .init(x: 0, y: 0),
                .init(x: 1, y: 0),
            ],
            sequence: 1
        )

        await #expect(
            throws: InteractiveStrokePresentationCacheError
                .tileCapacityExceeded(required: 2, maximum: 1)
        ) {
            _ = try await rig.cache.adopt(update, parameters: rig.parameters)
        }

        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 1)
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.failedUpdateCount == 1)
        #expect(diagnostic.acknowledgementSettlementCount == 1)
        #expect(diagnostic.publishedRevision == nil)
    }

    @Test
    @MainActor
    func acknowledgementFailureRetainsExactRetryWithoutRepublishing()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let injected = StrokePreparationFailure.unexpected(
            "injected cache acknowledgement failure"
        )
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1,
            acknowledgementReleaseFailures: [injected]
        )

        await #expect(
            throws: StrokePreparationAcknowledgementError
                .schedulerReleaseFailed(injected)
        ) {
            _ = try await rig.cache.adopt(update, parameters: rig.parameters)
        }

        #expect(update.acknowledgement.testingRequestCount == 1)
        #expect(update.acknowledgement.status
            == .failed(.schedulerReleaseFailed(injected)))
        #expect(try await rig.cache.current(generation: rig.generation)?
            .revision.sequence == 1)
        var diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.completedUpdateCount == 1)
        #expect(diagnostic.failedUpdateCount == 1)
        #expect(diagnostic.acknowledgementSettlementCount == 0)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 1)
        #expect(!diagnostic.isIdle)

        async let firstRetry: Void = rig.cache
            .retryPendingPreparedAcknowledgement()
        async let concurrentRetry: Void = rig.cache
            .retryPendingPreparedAcknowledgement()
        _ = try await (firstRetry, concurrentRetry)

        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 2)
        diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.submittedUpdateCount == 1)
        #expect(diagnostic.completedUpdateCount == 1)
        #expect(diagnostic.acknowledgementSettlementCount == 1)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
    }

    @Test
    @MainActor
    func secondConcurrentUpdateIsRejectedAndSettledAtTwoSlotMaximum()
        async throws
    {
        guard let rig = try makeRig(gateCompletion: true) else { return }
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let firstAdoption = Task {
            try await rig.cache.adopt(first, parameters: rig.parameters)
        }
        try #require(await rig.gate.waitUntilSubmitted())
        let second = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2
        )

        await #expect(
            throws: InteractiveStrokePresentationCacheError
                .updateSlotCapacityExceeded(maximum: 2)
        ) {
            _ = try await rig.cache.adopt(second, parameters: rig.parameters)
        }
        #expect(second.acknowledgement.status == .fulfilled)
        #expect(second.acknowledgement.testingRequestCount == 1)
        #expect((await rig.cache.snapshot()).activeUpdateSlotCount == 1)

        await rig.gate.open()
        _ = try await firstAdoption.value
        #expect(first.acknowledgement.testingRequestCount == 1)
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.maximumUpdateSlotCount == 2)
        #expect(diagnostic.failedUpdateCount == 1)
        #expect(diagnostic.acknowledgementSettlementCount == 2)
    }

    @Test
    @MainActor
    func exactUpdateCannotBeAdoptedTwiceOrSettleBeforeOwnerCompletes()
        async throws
    {
        guard let rig = try makeRig(gateCompletion: true) else { return }
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let owner = Task {
            try await rig.cache.adopt(update, parameters: rig.parameters)
        }
        try #require(await rig.gate.waitUntilSubmitted())
        let inFlight = await rig.cache.snapshot()
        #expect(inFlight.provisionalBytes > 0)
        #expect(inFlight.retirementWaiterCount == 0)

        await #expect(
            throws: InteractiveStrokePresentationCacheError.foreignUpdate
        ) {
            _ = try await rig.cache.adopt(update, parameters: rig.parameters)
        }
        #expect(update.acknowledgement.status == .available)
        #expect(update.acknowledgement.testingRequestCount == 0)

        await rig.gate.open()
        _ = try await owner.value
        #expect(update.acknowledgement.status == .fulfilled)
        #expect(update.acknowledgement.testingRequestCount == 1)
        #expect((await rig.cache.snapshot()).acknowledgementSettlementCount == 1)
    }

    @Test
    @MainActor
    func exactPreparedFrameCanExportOnlyOneCacheSettlementOwner()
        async throws
    {
        guard let rig = try makeRig(gateCompletion: true) else { return }
        let frame = StrokePreparedDisplayFrame.testing(
            capability: rig.capability,
            acknowledgementIsAvailable: true
        )
        let first = try rig.context.makeTransientCacheUpdate(
            frame: frame,
            sequence: 1
        )
        let owner = Task {
            try await rig.cache.adopt(first, parameters: rig.parameters)
        }
        try #require(await rig.gate.waitUntilSubmitted())

        #expect(throws: DocumentPaintRenderContextError.foreignTransientDisplayFrame) {
            _ = try rig.context.makeTransientCacheUpdate(
                frame: frame,
                sequence: 1
            )
        }
        #expect(frame.acknowledgement.status == .available)
        #expect(frame.acknowledgement.testingRequestCount == 0)

        await rig.gate.open()
        _ = try await owner.value
        #expect(frame.acknowledgement.status == .fulfilled)
        #expect(frame.acknowledgement.testingRequestCount == 1)
        #expect((await rig.cache.snapshot()).acknowledgementSettlementCount == 1)
    }

    @Test
    @MainActor
    func rejectedEqualRevisionCannotReleaseTheActiveAdoptionSlot()
        async throws
    {
        guard let rig = try makeRig(gateCompletion: true) else { return }
        let owner = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let ownerAdoption = Task {
            try await rig.cache.adopt(owner, parameters: rig.parameters)
        }
        try #require(await rig.gate.waitUntilSubmitted())
        let equalRevision = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 1
        )

        await #expect(
            throws: InteractiveStrokePresentationCacheError
                .updateSlotCapacityExceeded(maximum: 2)
        ) {
            _ = try await rig.cache.adopt(
                equalRevision,
                parameters: rig.parameters
            )
        }
        #expect(equalRevision.acknowledgement.status == .fulfilled)
        #expect(owner.acknowledgement.status == .available)
        #expect((await rig.cache.snapshot()).activeUpdateSlotCount == 1)

        let third = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [],
            sequence: 2
        )
        let foreignThird = DocumentPaintTransientCacheUpdate(
            generation: third.generation,
            strokeEpoch: third.strokeEpoch,
            sequence: third.sequence,
            layerID: UUID(),
            canonicalIdentity: third.canonicalIdentity,
            changedRole: third.changedRole,
            changedCoordinates: third.changedCoordinates,
            clearedAuthoritativeSurface: third.clearedAuthoritativeSurface,
            clearedPredictionSurface: third.clearedPredictionSurface,
            descriptor: third.descriptor,
            acknowledgement: third.acknowledgement,
            traceIdentities: third.traceIdentities,
            acknowledgementSettlement: third.acknowledgementSettlement,
            presentationEpoch: third.presentationEpoch
        )
        await #expect(
            throws: InteractiveStrokePresentationCacheError
                .updateSlotCapacityExceeded(maximum: 2)
        ) {
            _ = try await rig.cache.adopt(
                foreignThird,
                parameters: rig.parameters
            )
        }

        await rig.gate.open()
        _ = try await ownerAdoption.value
        #expect(owner.acknowledgement.status == .fulfilled)
        #expect(owner.acknowledgement.testingRequestCount == 1)
        #expect((await rig.cache.snapshot()).activeUpdateSlotCount == 1)
    }

    @Test
    @MainActor
    func descriptorCapabilityRejectsJointlySplicedEpochBeforeACKClaim()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let authentic = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let forgedIdentity = UUID()
        let spliced = DocumentPaintTransientCacheUpdate(
            generation: authentic.generation,
            strokeEpoch: forgedIdentity,
            sequence: authentic.sequence,
            layerID: authentic.layerID,
            canonicalIdentity: authentic.canonicalIdentity,
            changedRole: authentic.changedRole,
            changedCoordinates: authentic.changedCoordinates,
            clearedAuthoritativeSurface:
                authentic.clearedAuthoritativeSurface,
            clearedPredictionSurface: authentic.clearedPredictionSurface,
            descriptor: authentic.descriptor,
            acknowledgement: authentic.acknowledgement,
            traceIdentities: authentic.traceIdentities,
            acknowledgementSettlement:
                authentic.acknowledgementSettlement,
            presentationEpoch: DocumentPaintStrokePresentationEpoch(
                identity: forgedIdentity
            )
        )

        await #expect(
            throws: InteractiveStrokePresentationCacheError.foreignUpdate
        ) {
            _ = try await rig.cache.adopt(
                spliced,
                parameters: rig.parameters
            )
        }

        #expect(authentic.acknowledgement.status == .available)
        #expect(authentic.acknowledgement.testingRequestCount == 0)
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.activeUpdateSlotCount == 0)
        #expect(diagnostic.submittedUpdateCount == 0)
        #expect(diagnostic.provisionalBytes == 0)
        #expect(diagnostic.publishedRevision == nil)

        _ = try await rig.cache.adopt(
            authentic,
            parameters: rig.parameters
        )
        #expect(authentic.acknowledgement.status == .fulfilled)
        #expect(authentic.acknowledgement.testingRequestCount == 1)
    }

    @Test
    @MainActor
    func sameUUIDEpochTwinCannotCancelOrRetireAuthenticatedState()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        _ = try await rig.cache.adopt(first, parameters: rig.parameters)
        let before = await rig.cache.snapshot()
        let twin = DocumentPaintStrokePresentationEpoch(
            identity: rig.capability.presentationEpoch.identity
        )

        await #expect(
            throws: InteractiveStrokePresentationCacheError.foreignUpdate
        ) {
            try await rig.cache.cancel(strokeEpoch: twin)
        }
        await #expect(
            throws: InteractiveStrokePresentationCacheError.foreignUpdate
        ) {
            try await rig.cache.retire(strokeEpoch: twin)
        }
        let afterTwin = await rig.cache.snapshot()
        #expect(afterTwin.publishedRevision == before.publishedRevision)
        #expect(afterTwin.activeStrokeEpochCount == 1)
        #expect(afterTwin.retirementFailureCount == 0)
        #expect(!rig.capability.presentationEpoch.isRetired)

        let authenticContinuation = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2
        )
        _ = try await rig.cache.adopt(
            authenticContinuation,
            parameters: rig.parameters
        )
        #expect(authenticContinuation.acknowledgement.status == .fulfilled)

        try await rig.cache.cancel(
            strokeEpoch: rig.capability.presentationEpoch
        )
        let terminal = await rig.cache.snapshot()
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.isIdle)
    }

    @Test
    @MainActor
    func adoptionOperationRejectsSameUUIDTwinWithoutForeignLifecycle()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let first = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let firstOperation = InteractiveStrokeCacheAdoptionOperation.start(
            cache: rig.cache,
            update: first,
            parameters: rig.parameters,
            terminal: { _ in true }
        )
        await firstOperation.value
        let published = (await rig.cache.snapshot()).publishedRevision

        let authentic = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2
        )
        let twin = DocumentPaintStrokePresentationEpoch(
            identity: authentic.presentationEpoch.identity
        )
        let spliced = DocumentPaintTransientCacheUpdate(
            generation: authentic.generation,
            strokeEpoch: authentic.strokeEpoch,
            sequence: authentic.sequence,
            layerID: authentic.layerID,
            canonicalIdentity: authentic.canonicalIdentity,
            changedRole: authentic.changedRole,
            changedCoordinates: authentic.changedCoordinates,
            clearedAuthoritativeSurface:
                authentic.clearedAuthoritativeSurface,
            clearedPredictionSurface: authentic.clearedPredictionSurface,
            descriptor: authentic.descriptor,
            acknowledgement: authentic.acknowledgement,
            traceIdentities: authentic.traceIdentities,
            acknowledgementSettlement:
                authentic.acknowledgementSettlement,
            presentationEpoch: twin
        )
        let failures = InteractiveStrokeLifecycleFailureProbe()
        let invalidOperation =
            InteractiveStrokeCacheAdoptionOperation.start(
                cache: rig.cache,
                update: spliced,
                parameters: rig.parameters,
                terminal: { error in
                    if let error { failures.record(error) }
                    return true
                }
            )
        await invalidOperation.value

        #expect(failures.count == 1)
        #expect(authentic.acknowledgement.status == .fulfilled)
        #expect(authentic.acknowledgement.testingRequestCount == 1)
        let after = await rig.cache.snapshot()
        #expect(after.publishedRevision == published)
        #expect(after.activeStrokeEpochCount == 1)
        #expect(InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(authentic.presentationEpoch.identity))

        InteractiveStrokeCacheLifecycleCoordinator.shared.requestCancellation(
            cache: rig.cache,
            strokeEpoch: authentic.presentationEpoch
        )
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(authentic.presentationEpoch.identity)
        #expect((await rig.cache.snapshot()).isIdle)
    }

    @Test
    @MainActor
    func emptyCancellationFailureIsNonIdleUntilExactRetryCompletes()
        async throws
    {
        guard let rig = try makeRig(
            cacheFailureInjection: .init(retirementFailureCount: 1)
        ) else { return }

        await #expect(
            throws: InteractiveStrokePresentationCacheError
                .injectedRetirementFailure(
                    rig.capability.presentationEpoch.identity
                )
        ) {
            try await rig.cache.cancel(
                strokeEpoch: rig.capability.presentationEpoch
            )
        }
        var failed = await rig.cache.snapshot()
        #expect(failed.retirementState == .failed(
            strokeEpoch: rig.capability.presentationEpoch.identity
        ))
        #expect(!failed.isIdle)

        try await rig.cache.cancel(
            strokeEpoch: rig.capability.presentationEpoch
        )
        failed = await rig.cache.snapshot()
        #expect(failed.retirementState == .idle)
        #expect(failed.isIdle)
    }

    @Test
    @MainActor
    func sameUUIDTwinCannotClaimRetiringEscapedPhysicalState()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        _ = try await rig.cache.adopt(update, parameters: rig.parameters)
        var provider: TiledRasterExactReferenceProvider? = try #require(
            try await rig.cache.current(generation: rig.generation)?
                .authoritative
        )
        var capture: TiledRasterExactReferenceCapture? = try
            TiledRasterExactReferenceCapture(providers: [provider!])

        try await rig.cache.retire(
            strokeEpoch: rig.capability.presentationEpoch
        )
        let retained = await rig.cache.snapshot()
        #expect(retained.activeStrokeEpochCount == 0)
        #expect(retained.totalPhysicalResidentBytes > 0)
        #expect(!retained.isIdle)
        await rig.cache.installFailureInjectionForTesting(
            .init(retirementFailureCount: 1)
        )
        let twin = DocumentPaintStrokePresentationEpoch(
            identity: rig.capability.presentationEpoch.identity
        )
        await #expect(
            throws: InteractiveStrokePresentationCacheError.foreignUpdate
        ) {
            try await rig.cache.cancel(strokeEpoch: twin)
        }
        await #expect(
            throws: InteractiveStrokePresentationCacheError.foreignUpdate
        ) {
            try await rig.cache.retire(strokeEpoch: twin)
        }
        #expect((await rig.cache.snapshot()).retirementFailureCount == 0)

        capture?.close()
        capture = nil
        provider = nil
        await #expect(
            throws: InteractiveStrokePresentationCacheError
                .injectedRetirementFailure(
                    rig.capability.presentationEpoch.identity
                )
        ) {
            try await rig.cache.retire(
                strokeEpoch: rig.capability.presentationEpoch
            )
        }
        try await rig.cache.retire(
            strokeEpoch: rig.capability.presentationEpoch
        )
        let terminal = await rig.cache.snapshot()
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.isIdle)
    }

    @Test
    @MainActor
    func cancellationBeforeFirstUpdateDoesNotPoisonNextStrokeInDocumentEpoch()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let firstEpoch = rig.capability.presentationEpoch

        try await rig.cache.cancel(strokeEpoch: firstEpoch)
        try rig.context.cancelStrokeSurface(rig.capability)
        let nextCapability = try rig.context.beginStrokeSurface()
        #expect(nextCapability.generation == rig.capability.generation)
        #expect(nextCapability.presentationEpoch.identity != firstEpoch.identity)
        let frame = StrokePreparedDisplayFrame.testing(
            capability: nextCapability,
            acknowledgementIsAvailable: true
        )
        let next = try rig.context.makeTransientCacheUpdate(
            frame: frame,
            sequence: 1
        )

        _ = try await rig.cache.adopt(next, parameters: rig.parameters)

        #expect(next.acknowledgement.status == .fulfilled)
        #expect(try await rig.cache.current(generation: rig.generation)?
            .revision.strokeEpoch == nextCapability.presentationEpoch.identity)
    }

    @Test
    @MainActor
    func retirementBeforeAdoptionRejectsOnlyThatExactStrokeEpoch()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let late = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )

        try await rig.cache.retire(strokeEpoch: rig.capability.presentationEpoch)
        await #expect(throws: CancellationError.self) {
            _ = try await rig.cache.adopt(late, parameters: rig.parameters)
        }

        #expect(late.acknowledgement.status == .fulfilled)
        #expect(late.acknowledgement.testingRequestCount == 1)
        #expect(try await rig.cache.current(generation: rig.generation) == nil)
    }

    @Test
    @MainActor
    func queuedLateAdoptionCannotCrossAcceptedEpochRetirement()
        async throws
    {
        guard let rig = try makeRig(gateCompletion: true) else { return }
        let owner = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let adoption = Task {
            try await rig.cache.adopt(owner, parameters: rig.parameters)
        }
        try #require(await rig.gate.waitUntilSubmitted())
        let late = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 1, y: 0)],
            sequence: 2
        )
        let retirement = Task {
            try await rig.cache.retire(
                strokeEpoch: rig.capability.presentationEpoch
            )
        }
        try #require(await rig.gate.waitUntilRetirementWaiting())

        await #expect(throws: CancellationError.self) {
            _ = try await rig.cache.adopt(late, parameters: rig.parameters)
        }
        #expect(late.acknowledgement.status == .fulfilled)
        #expect(owner.acknowledgement.status == .available)

        await rig.gate.open()
        _ = try await adoption.value
        try await retirement.value
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.retirementWaiterCount == 0)
    }

    @Test
    @MainActor
    func cacheEmitsOnlySubmittedAndCompletedTraceStages() async throws {
        let recorder = InteractiveBrushTraceRecorder()
        let sink = InteractiveStrokePresentationTraceSink()
        recorder.configure(sink: sink)
        guard let rig = try makeRig(traceRecorder: recorder) else { return }
        let identity = StrokeTraceIdentity(
            strokeGeneration: rig.generation,
            authoritativeSequence: 4,
            sampleSequence: 9,
            provenance: .authoritative
        )
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1,
            traceIdentities: [identity]
        )

        _ = try await rig.cache.adopt(update, parameters: rig.parameters)

        #expect(sink.records.map(\.stage) == [
            .transientCacheSubmitted,
            .transientCacheCompleted,
        ])
        #expect(sink.records.allSatisfy { $0.identity == identity })
        #expect(!sink.records.contains { $0.stage == .drawableSubmitted })
        #expect(!sink.records.contains { $0.stage == .drawablePresented })
    }

    @Test(arguments: InteractiveStrokeRetirementTerminal.allCases)
    @MainActor
    func retirementWaiterResumesOnceAfterExactTerminalSettlement(
        terminal: InteractiveStrokeRetirementTerminal
    ) async throws {
        guard let rig = try makeRig(gateCompletion: true) else { return }
        let injected = StrokePreparationFailure.unexpected(
            "injected retirement acknowledgement failure"
        )
        let update = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1,
            acknowledgementReleaseFailures:
                terminal == .failure ? [injected] : []
        )
        let adoption = Task {
            try await rig.cache.adopt(update, parameters: rig.parameters)
        }
        try #require(await rig.gate.waitUntilSubmitted())
        let retirement = Task {
            switch terminal {
            case .success, .failure:
                try await rig.cache.retire(
                    strokeEpoch: rig.capability.presentationEpoch
                )
            case .cancellation:
                try await rig.cache.cancel(
                    strokeEpoch: rig.capability.presentationEpoch
                )
            }
        }
        try #require(await rig.gate.waitUntilRetirementWaiting())

        var diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.retirementWaiterCount == 1)
        #expect(diagnostic.retirementResumeCount == 0)
        #expect(diagnostic.activeUpdateSlotCount == 1)
        await rig.gate.open()

        switch terminal {
        case .success:
            _ = try await adoption.value
            #expect(update.acknowledgement.status == .fulfilled)
        case .failure:
            await #expect(
                throws: StrokePreparationAcknowledgementError
                    .schedulerReleaseFailed(injected)
            ) {
                _ = try await adoption.value
            }
        case .cancellation:
            await #expect(throws: CancellationError.self) {
                _ = try await adoption.value
            }
            #expect(update.acknowledgement.status == .fulfilled)
        }
        try await retirement.value

        if terminal == .failure {
            diagnostic = await rig.cache.snapshot()
            #expect(diagnostic.pendingPreparedAcknowledgementCount == 1)
            try await rig.cache.retryPendingPreparedAcknowledgement()
        }

        diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.retirementWaiterCount == 0)
        #expect(diagnostic.retirementResumeCount == 1)
        #expect(diagnostic.activeUpdateSlotCount == 0)
        #expect(diagnostic.acknowledgementSettlementCount == 1)
        #expect(update.acknowledgement.testingRequestCount
            == (terminal == .failure ? 2 : 1))
        #expect(try await rig.cache.current(generation: rig.generation) == nil)
    }

    @MainActor
    private func makeRig(
        gateCompletion: Bool = false,
        blocksLifecycleRetry: Bool = false,
        maximumTileCount: Int = 8,
        cacheByteBudget: Int = PaintTileDescriptor.residentByteCount * 16,
        cacheFailureInjection:
            InteractiveStrokePresentationCacheFailureInjection? = nil,
        traceRecorder: InteractiveBrushTraceRecorder? = nil
    ) throws -> Rig? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        let layerID = UUID()
        let generation: UInt64 = 77
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: makeShaderLibrary(device: device),
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 512, height: 256),
                storagePixelSize: PixelSize(width: 512, height: 256),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: layerID),
            byteBudget: PaintTileDescriptor.residentByteCount * 16,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 32,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 16,
            generation: generation
        )
        let capability = try context.beginStrokeSurface()
        let gate = InteractiveStrokePresentationCacheGate(
            initiallyOpen: !gateCompletion,
            blocksLifecycleRetry: blocksLifecycleRetry
        )
        let cache = InteractiveStrokePresentationCache(
            device: device,
            commandQueue: queue,
            byteBudget: cacheByteBudget,
            maximumTileCount: maximumTileCount,
            completionGate: gate,
            failureInjection: cacheFailureInjection,
            traceRecorder: traceRecorder
        )
        return Rig(
            generation: generation,
            queue: queue,
            context: context,
            capability: capability,
            cache: cache,
            gate: gate,
            parameters: .init(blendMode: .normal, opacity: 0.75)
        )
    }

    @MainActor
    private func makeUpdate(
        rig: Rig,
        role: StrokePrivateSurfaceLayer,
        coordinates: [PaintTileCoordinate],
        sequence: UInt64,
        clearsPrediction: Bool = false,
        traceIdentities: [StrokeTraceIdentity] = [],
        acknowledgementReleaseFailures: [StrokePreparationFailure] = []
    ) throws -> DocumentPaintTransientCacheUpdate {
        if !coordinates.isEmpty {
            let reservation = try rig.capability.reserveStrokeTiles(
                role: role == .authoritative ? .authoritative : .prediction,
                coordinates: coordinates.sorted(),
                pinReasons: [.visible, .inFlight],
                workspace: PaintTileStrokeLeaseWorkspace(
                    maximumBindingCount: coordinates.count
                ),
                failureInjection: nil
            )
            try rig.capability.testingMarkDirty(reservation)
            try rig.capability.releaseFrameReservations(
                authoritative: role == .authoritative ? reservation : nil,
                prediction: role == .prediction ? reservation : nil
            )
        }
        let frame = StrokePreparedDisplayFrame.testing(
            capability: rig.capability,
            layer: role,
            changedCoordinates: coordinates,
            clearedPredictionSurface: clearsPrediction,
            traceIdentities: traceIdentities,
            acknowledgementIsAvailable: true,
            acknowledgementReleaseFailures:
                acknowledgementReleaseFailures
        )
        return try rig.context.makeTransientCacheUpdate(
            frame: frame,
            sequence: sequence
        )
    }

    private struct Rig {
        let generation: UInt64
        let queue: any MTLCommandQueue
        let context: DocumentPaintRenderContext
        let capability: DocumentPaintStrokeSurfaceCapability
        let cache: InteractiveStrokePresentationCache
        let gate: InteractiveStrokePresentationCacheGate
        let parameters: InteractiveStrokeCompositeParameters
    }

    private func tileBytes(
        _ provider: TiledRasterExactReferenceProvider,
        coordinate: PaintTileCoordinate,
        queue: any MTLCommandQueue
    ) async throws -> [UInt8] {
        let reference = try #require(provider.references.first {
            $0.coordinate == coordinate
        })
        let restricted = try provider.restrictingEntitlement(to: [reference])
        let capture = try TiledRasterExactReferenceCapture(
            providers: [restricted]
        )
        let lease = try restricted.leaseExactReferences(
            [reference],
            using: capture,
            pinReasons: [.inFlight]
        )
        defer {
            try? lease.returnLease()
            capture.close()
        }
        let texture = try #require(lease.bindings.first?.texture)
        let buffer = try #require(queue.device.makeBuffer(
            length: PaintTileDescriptor.residentByteCount,
            options: .storageModeShared
        ))
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side,
                depth: 1
            ),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: PaintTileDescriptor.side * 8,
            destinationBytesPerImage:
                PaintTileDescriptor.residentByteCount
        )
        blit.endEncoding()
        command.commit()
        await command.completed()
        guard command.status == .completed else {
            throw InteractiveStrokePresentationCacheError.commandFailed(
                command.error?.localizedDescription ?? "test readback failed"
            )
        }
        return Array(UnsafeRawBufferPointer(
            start: buffer.contents(),
            count: PaintTileDescriptor.residentByteCount
        ))
    }

    @MainActor
    private func makeShaderLibrary(
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
}

enum InteractiveStrokeRetirementTerminal:
    CaseIterable, CustomTestStringConvertible, Sendable
{
    case success
    case failure
    case cancellation

    var testDescription: String { String(describing: self) }
}

private final class InteractiveStrokePresentationTraceSink:
    InteractiveBrushTraceSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [InteractiveBrushTraceRecord] = []

    var records: [InteractiveBrushTraceRecord] {
        lock.withLock { storage }
    }

    func record(_ record: InteractiveBrushTraceRecord) {
        lock.withLock { storage.append(record) }
    }
}

private final class WeakInteractiveStrokePresentationCache:
    @unchecked Sendable
{
    weak var value: InteractiveStrokePresentationCache?

    init(_ value: InteractiveStrokePresentationCache?) { self.value = value }
}

private final class InteractiveStrokeCacheLifecycleTerminalProbe:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: InteractiveStrokePresentationCacheSnapshot?
    private var storedRecordCount = 0
    private var waiters: [CheckedContinuation<
        InteractiveStrokePresentationCacheSnapshot,
        Never
    >] = []
    private var boundedWaiters:
        [(Int, UUID, InteractiveStrokeGateBoundedWaiter)] = []

    var snapshot: InteractiveStrokePresentationCacheSnapshot? {
        lock.withLock { storage }
    }

    var recordCount: Int { lock.withLock { storedRecordCount } }

    func record(_ snapshot: InteractiveStrokePresentationCacheSnapshot) {
        let ready = lock.withLock {
            storedRecordCount += 1
            storage = snapshot
            let bounded = boundedWaiters.filter {
                $0.0 <= storedRecordCount
            }
            boundedWaiters.removeAll { $0.0 <= storedRecordCount }
            defer { waiters.removeAll() }
            return (waiters, bounded)
        }
        for waiter in ready.0 { waiter.resume(returning: snapshot) }
        for (_, _, waiter) in ready.1 { waiter.signal() }
    }

    func waitUntilRecordCount(_ count: Int) async -> Bool {
        let waiterID = UUID()
        let waiter = InteractiveStrokeGateBoundedWaiter()
        let alreadyRecorded = lock.withLock {
            guard storedRecordCount < count else { return true }
            boundedWaiters.append((count, waiterID, waiter))
            return false
        }
        guard !alreadyRecorded else { return true }
        let didSignal = await waiter.wait()
        return lock.withLock {
            boundedWaiters.removeAll { $0.1 == waiterID }
            return didSignal && storedRecordCount >= count
        }
    }

    func waitUntilRecorded() async
        -> InteractiveStrokePresentationCacheSnapshot
    {
        await withCheckedContinuation { continuation in
            let recorded: InteractiveStrokePresentationCacheSnapshot? =
                lock.withLock {
                    if let storage { return storage }
                    waiters.append(continuation)
                    return nil
                }
            if let recorded { continuation.resume(returning: recorded) }
        }
    }
}

private final class InteractiveStrokeLifecycleOwnerProbe:
    @unchecked Sendable
{}

private final class InteractiveStrokeLifecycleFailureProbe:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [String] = []

    var count: Int { lock.withLock { storage.count } }
    var descriptions: [String] { lock.withLock { storage } }

    func record(_ error: any Error) {
        lock.withLock { storage.append(String(describing: error)) }
    }
}

@MainActor
private final class WeakGridRenderer {
    weak var value: GridRenderer?

    init(_ value: GridRenderer?) { self.value = value }
}

/// A one-shot test signal with a monotonic timeout. Timeout and task
/// cancellation both resolve the suspended continuation, so a failed causal
/// expectation cannot strand the serialized cache suite.
private final class InteractiveStrokeGateBoundedWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var pendingResult: Bool?
    private var isFinished = false

    func wait(timeout: Duration = .seconds(5)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.waitForSignal() }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {}
                return false
            }
            let result = await group.next() ?? false
            if !result { resolve(false) }
            group.cancelAll()
            return result
        }
    }

    func signal() { resolve(true) }

    private func waitForSignal() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                isFinished = true
                lock.unlock()
                continuation.resume(returning: pendingResult)
            } else if isFinished {
                lock.unlock()
                continuation.resume(returning: false)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func resolve(_ result: Bool) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        isFinished = true
        lock.unlock()
        continuation.resume(returning: result)
    }
}

private actor InteractiveStrokePresentationCacheGate:
    InteractiveStrokePresentationCacheCompletionGating
{
    private var isOpen: Bool
    private var submissionCount = 0
    private var openWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var submissionWaiters:
        [(Int, UUID, InteractiveStrokeGateBoundedWaiter)] = []
    private var retirementWaitCount = 0
    private var retirementWaiters:
        [UUID: InteractiveStrokeGateBoundedWaiter] = [:]
    private var blocksRetirementRetry: Bool
    private var retirementRetryDidBlock = false
    private var retirementRetryBlockWaiters:
        [UUID: InteractiveStrokeGateBoundedWaiter] = [:]
    private var retirementRetryReleaseWaiters:
        [UUID: CheckedContinuation<Void, Never>] = [:]
    private var acknowledgementFailureCount = 0
    private var acknowledgementFailureWaiters:
        [(Int, UUID, InteractiveStrokeGateBoundedWaiter)] = []
    private let blocksAcknowledgementFailureAt: Int?
    private var blockedAcknowledgementFailure = false
    private var blockedAcknowledgementFailureWaiters:
        [UUID: InteractiveStrokeGateBoundedWaiter] = [:]
    private var acknowledgementFailureReleaseWaiters:
        [UUID: CheckedContinuation<Void, Never>] = [:]
    private let blocksLifecycleRetry: Bool
    private var lifecycleRetryScheduleCount = 0
    private var lifecycleRetryScheduleWaiters:
        [(Int, UUID, InteractiveStrokeGateBoundedWaiter)] = []
    private var lifecycleRetryWaiters:
        [UUID: CheckedContinuation<Void, Never>] = [:]
    private var lifecycleRetryWaiterHighWater = 0
    private var lifecycleRetryCancellationCount = 0
    private var lifecycleRetryCancellationWaiters:
        [(Int, UUID, InteractiveStrokeGateBoundedWaiter)] = []

    var lifecycleRetryScheduleCountSnapshot: Int {
        lifecycleRetryScheduleCount
    }

    var lifecycleRetryWaiterCount: Int { lifecycleRetryWaiters.count }
    var lifecycleRetryWaiterHighWaterSnapshot: Int {
        lifecycleRetryWaiterHighWater
    }

    init(
        initiallyOpen: Bool,
        blocksRetirementRetry: Bool = false,
        blocksLifecycleRetry: Bool = false,
        blocksAcknowledgementFailureAt: Int? = nil
    ) {
        isOpen = initiallyOpen
        self.blocksRetirementRetry = blocksRetirementRetry
        self.blocksLifecycleRetry = blocksLifecycleRetry
        self.blocksAcknowledgementFailureAt = blocksAcknowledgementFailureAt
    }

    func cacheCommandDidSubmit() {
        submissionCount += 1
        let ready = submissionWaiters.filter { $0.0 <= submissionCount }
        submissionWaiters.removeAll { $0.0 <= submissionCount }
        for (_, _, waiter) in ready { waiter.signal() }
    }

    func waitAfterGPUCompletion() async {
        guard !isOpen else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    openWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelOpenWaiter(waiterID) }
        }
    }

    func cacheRetirementDidWait() {
        retirementWaitCount += 1
        let waiters = Array(retirementWaiters.values)
        retirementWaiters.removeAll()
        for waiter in waiters { waiter.signal() }
    }

    func cacheRetirementDidFail() async {
        guard blocksRetirementRetry else { return }
        retirementRetryDidBlock = true
        let blockWaiters = Array(retirementRetryBlockWaiters.values)
        retirementRetryBlockWaiters.removeAll()
        for waiter in blockWaiters { waiter.signal() }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || !blocksRetirementRetry {
                    continuation.resume()
                } else {
                    retirementRetryReleaseWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelRetirementRetryWaiter(waiterID) }
        }
    }

    func cacheAcknowledgementDidFail() async {
        acknowledgementFailureCount += 1
        let ready = acknowledgementFailureWaiters.filter {
            $0.0 <= acknowledgementFailureCount
        }
        acknowledgementFailureWaiters.removeAll {
            $0.0 <= acknowledgementFailureCount
        }
        for (_, _, waiter) in ready { waiter.signal() }
        guard acknowledgementFailureCount
                == blocksAcknowledgementFailureAt
        else { return }
        blockedAcknowledgementFailure = true
        let blocked = Array(blockedAcknowledgementFailureWaiters.values)
        blockedAcknowledgementFailureWaiters.removeAll()
        for waiter in blocked { waiter.signal() }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    acknowledgementFailureReleaseWaiters[waiterID] =
                        continuation
                }
            }
        } onCancel: {
            Task { await self.cancelAcknowledgementFailureWaiter(waiterID) }
        }
    }

    @discardableResult
    func waitUntilAcknowledgementFailure(count: Int) async -> Bool {
        guard acknowledgementFailureCount < count else { return true }
        let waiterID = UUID()
        let waiter = InteractiveStrokeGateBoundedWaiter()
        acknowledgementFailureWaiters.append((count, waiterID, waiter))
        let didSignal = await waiter.wait()
        acknowledgementFailureWaiters.removeAll { $0.1 == waiterID }
        return didSignal && acknowledgementFailureCount >= count
    }

    @discardableResult
    func waitUntilBlockedAcknowledgementFailure() async -> Bool {
        guard !blockedAcknowledgementFailure else { return true }
        let waiterID = UUID()
        let waiter = InteractiveStrokeGateBoundedWaiter()
        blockedAcknowledgementFailureWaiters[waiterID] = waiter
        let didSignal = await waiter.wait()
        blockedAcknowledgementFailureWaiters.removeValue(forKey: waiterID)
        return didSignal && blockedAcknowledgementFailure
    }

    func releaseBlockedAcknowledgementFailure() {
        let waiters = Array(acknowledgementFailureReleaseWaiters.values)
        acknowledgementFailureReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForLifecycleRetry(attempt: Int) async throws {
        lifecycleRetryScheduleCount += 1
        let ready = lifecycleRetryScheduleWaiters.filter {
            $0.0 <= lifecycleRetryScheduleCount
        }
        lifecycleRetryScheduleWaiters.removeAll {
            $0.0 <= lifecycleRetryScheduleCount
        }
        for (_, _, waiter) in ready { waiter.signal() }
        guard blocksLifecycleRetry else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    lifecycleRetryWaiters[waiterID] = continuation
                    lifecycleRetryWaiterHighWater = max(
                        lifecycleRetryWaiterHighWater,
                        lifecycleRetryWaiters.count
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelLifecycleRetryWaiter(waiterID) }
        }
    }

    @discardableResult
    func waitUntilLifecycleRetryScheduled(count: Int) async -> Bool {
        guard lifecycleRetryScheduleCount < count else { return true }
        let waiterID = UUID()
        let waiter = InteractiveStrokeGateBoundedWaiter()
        lifecycleRetryScheduleWaiters.append((count, waiterID, waiter))
        let didSignal = await waiter.wait()
        lifecycleRetryScheduleWaiters.removeAll { $0.1 == waiterID }
        return didSignal && lifecycleRetryScheduleCount >= count
    }

    func releaseOneLifecycleRetry() {
        guard let first = lifecycleRetryWaiters.first else { return }
        lifecycleRetryWaiters.removeValue(forKey: first.key)
        first.value.resume()
    }

    private func cancelLifecycleRetryWaiter(_ waiterID: UUID) {
        guard let waiter = lifecycleRetryWaiters.removeValue(
            forKey: waiterID
        ) else { return }
        lifecycleRetryCancellationCount += 1
        let ready = lifecycleRetryCancellationWaiters.filter {
            $0.0 <= lifecycleRetryCancellationCount
        }
        lifecycleRetryCancellationWaiters.removeAll {
            $0.0 <= lifecycleRetryCancellationCount
        }
        waiter.resume()
        for (_, _, cancellationWaiter) in ready {
            cancellationWaiter.signal()
        }
    }

    @discardableResult
    func waitUntilLifecycleRetryCancellation(count: Int) async -> Bool {
        guard lifecycleRetryCancellationCount < count else { return true }
        let waiterID = UUID()
        let waiter = InteractiveStrokeGateBoundedWaiter()
        lifecycleRetryCancellationWaiters.append((count, waiterID, waiter))
        let didSignal = await waiter.wait()
        lifecycleRetryCancellationWaiters.removeAll { $0.1 == waiterID }
        return didSignal && lifecycleRetryCancellationCount >= count
    }

    @discardableResult
    func waitUntilRetirementRetryBlocked() async -> Bool {
        guard !retirementRetryDidBlock else { return true }
        let waiterID = UUID()
        let waiter = InteractiveStrokeGateBoundedWaiter()
        retirementRetryBlockWaiters[waiterID] = waiter
        let didSignal = await waiter.wait()
        retirementRetryBlockWaiters.removeValue(forKey: waiterID)
        return didSignal && retirementRetryDidBlock
    }

    func releaseRetirementRetry() {
        blocksRetirementRetry = false
        let waiters = Array(retirementRetryReleaseWaiters.values)
        retirementRetryReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    @discardableResult
    func waitUntilRetirementWaiting() async -> Bool {
        guard retirementWaitCount == 0 else { return true }
        let waiterID = UUID()
        let waiter = InteractiveStrokeGateBoundedWaiter()
        retirementWaiters[waiterID] = waiter
        let didSignal = await waiter.wait()
        retirementWaiters.removeValue(forKey: waiterID)
        return didSignal && retirementWaitCount > 0
    }

    @discardableResult
    func waitUntilSubmitted(count: Int = 1) async -> Bool {
        guard submissionCount < count else { return true }
        let waiterID = UUID()
        let waiter = InteractiveStrokeGateBoundedWaiter()
        submissionWaiters.append((count, waiterID, waiter))
        let didSignal = await waiter.wait()
        submissionWaiters.removeAll { $0.1 == waiterID }
        return didSignal && submissionCount >= count
    }

    func open() {
        isOpen = true
        let waiters = Array(openWaiters.values)
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func close() { isOpen = false }

    func releaseAll() {
        open()
        releaseRetirementRetry()
        releaseBlockedAcknowledgementFailure()
        let retryWaiters = Array(lifecycleRetryWaiters.values)
        lifecycleRetryWaiters.removeAll()
        for waiter in retryWaiters { waiter.resume() }
    }

    private func cancelOpenWaiter(_ waiterID: UUID) {
        openWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func cancelRetirementRetryWaiter(_ waiterID: UUID) {
        retirementRetryReleaseWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func cancelAcknowledgementFailureWaiter(_ waiterID: UUID) {
        acknowledgementFailureReleaseWaiters
            .removeValue(forKey: waiterID)?.resume()
    }
}
