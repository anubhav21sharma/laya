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
        await rig.gate.waitUntilSubmitted()

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
        await rig.gate.waitUntilSubmitted(count: 2)

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
        await rig.gate.waitUntilSubmitted()
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
        await rig.gate.waitUntilSubmitted(count: 2)
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
        await rig.gate.waitUntilSubmitted()
        #expect(update.acknowledgement.status == .available)
        await rig.gate.open()
        await adoption.value
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .advancePendingLifecycles()

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

        await gate.waitUntilRetirementRetryBlocked()
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

        await gate.waitUntilLifecycleRetryScheduled(count: 1)
        #expect(weakCache.value != nil)
        #expect(update.acknowledgement.testingRequestCount == 1)
        await gate.releaseOneLifecycleRetry()
        await gate.waitUntilAcknowledgementFailure(count: 2)
        await gate.waitUntilLifecycleRetryScheduled(count: 2)
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
    func cancellingOwnerGoneLifecycleCancelsItsOnlyScheduledRetry()
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

        await gate.waitUntilLifecycleRetryScheduled(count: 1)
        await operation?.value
        operation = nil
        #expect(await gate.lifecycleRetryScheduleCountSnapshot == 1)
        #expect(await gate.lifecycleRetryWaiterCount == 1)
        #expect(weakCache.value != nil)
        #expect(update.acknowledgement.status == .fulfilled)

        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .cancelRetainedLifecycle(update.presentationEpoch.identity)
        let diagnostic = await terminal.waitUntilRecorded()
        await gate.waitUntilLifecycleRetryCancellation(count: 1)

        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.retirementWaiterCount == 0)
        #expect(diagnostic.provisionalBytes == 0)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
        #expect(await gate.lifecycleRetryWaiterCount == 0)
        #expect(weakCache.value == nil)
    }

    @Test
    @MainActor
    func terminalRetirementAbandonmentReplacesPublishedPhysicalStore()
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
        await rig.cache.terminallyAbandonFailedRetirement(
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
        await rig.gate.waitUntilSubmitted(count: 2)
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
        await rig.gate.waitUntilSubmitted()
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
        await rig.gate.waitUntilSubmitted()
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
        await rig.gate.waitUntilSubmitted()

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
        await rig.gate.waitUntilSubmitted()
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
    func splicedStrokeEpochIsRejectedBeforeCacheStateOrEncoding()
        async throws
    {
        guard let rig = try makeRig() else { return }
        let authentic = try makeUpdate(
            rig: rig,
            role: .authoritative,
            coordinates: [.init(x: 0, y: 0)],
            sequence: 1
        )
        let spliced = DocumentPaintTransientCacheUpdate(
            generation: authentic.generation,
            strokeEpoch: UUID(),
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
            presentationEpoch: authentic.presentationEpoch
        )

        await #expect(
            throws: InteractiveStrokePresentationCacheError.foreignUpdate
        ) {
            _ = try await rig.cache.adopt(
                spliced,
                parameters: rig.parameters
            )
        }

        #expect(authentic.acknowledgement.status == .fulfilled)
        #expect(authentic.acknowledgement.testingRequestCount == 1)
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.activeUpdateSlotCount == 0)
        #expect(diagnostic.submittedUpdateCount == 0)
        #expect(diagnostic.provisionalBytes == 0)
        #expect(diagnostic.publishedRevision == nil)
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
        await rig.gate.waitUntilSubmitted()
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
        await rig.gate.waitUntilRetirementWaiting()

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
        await rig.gate.waitUntilSubmitted()
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
        await rig.gate.waitUntilRetirementWaiting()

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
            initiallyOpen: !gateCompletion
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
    private var waiters: [CheckedContinuation<
        InteractiveStrokePresentationCacheSnapshot,
        Never
    >] = []

    var snapshot: InteractiveStrokePresentationCacheSnapshot? {
        lock.withLock { storage }
    }

    func record(_ snapshot: InteractiveStrokePresentationCacheSnapshot) {
        let ready = lock.withLock {
            storage = snapshot
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in ready { waiter.resume(returning: snapshot) }
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

@MainActor
private final class WeakGridRenderer {
    weak var value: GridRenderer?

    init(_ value: GridRenderer?) { self.value = value }
}

private actor InteractiveStrokePresentationCacheGate:
    InteractiveStrokePresentationCacheCompletionGating
{
    private var isOpen: Bool
    private var submissionCount = 0
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var submissionWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []
    private var retirementWaitCount = 0
    private var retirementWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocksRetirementRetry: Bool
    private var retirementRetryDidBlock = false
    private var retirementRetryBlockWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var retirementRetryReleaseWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var acknowledgementFailureCount = 0
    private var acknowledgementFailureWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []
    private let blocksLifecycleRetry: Bool
    private var lifecycleRetryScheduleCount = 0
    private var lifecycleRetryScheduleWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []
    private var lifecycleRetryWaiters:
        [UUID: CheckedContinuation<Void, Never>] = [:]
    private var lifecycleRetryCancellationCount = 0
    private var lifecycleRetryCancellationWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []

    var lifecycleRetryScheduleCountSnapshot: Int {
        lifecycleRetryScheduleCount
    }

    var lifecycleRetryWaiterCount: Int { lifecycleRetryWaiters.count }

    init(
        initiallyOpen: Bool,
        blocksRetirementRetry: Bool = false,
        blocksLifecycleRetry: Bool = false
    ) {
        isOpen = initiallyOpen
        self.blocksRetirementRetry = blocksRetirementRetry
        self.blocksLifecycleRetry = blocksLifecycleRetry
    }

    func cacheCommandDidSubmit() {
        submissionCount += 1
        let ready = submissionWaiters.filter { $0.0 <= submissionCount }
        submissionWaiters.removeAll { $0.0 <= submissionCount }
        for (_, waiter) in ready { waiter.resume() }
    }

    func waitAfterGPUCompletion() async {
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func cacheRetirementDidWait() {
        retirementWaitCount += 1
        let waiters = retirementWaiters
        retirementWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func cacheRetirementDidFail() async {
        guard blocksRetirementRetry else { return }
        retirementRetryDidBlock = true
        let blockWaiters = retirementRetryBlockWaiters
        retirementRetryBlockWaiters.removeAll()
        for waiter in blockWaiters { waiter.resume() }
        await withCheckedContinuation {
            retirementRetryReleaseWaiters.append($0)
        }
    }

    func cacheAcknowledgementDidFail() {
        acknowledgementFailureCount += 1
        let ready = acknowledgementFailureWaiters.filter {
            $0.0 <= acknowledgementFailureCount
        }
        acknowledgementFailureWaiters.removeAll {
            $0.0 <= acknowledgementFailureCount
        }
        for (_, waiter) in ready { waiter.resume() }
    }

    func waitUntilAcknowledgementFailure(count: Int) async {
        guard acknowledgementFailureCount < count else { return }
        await withCheckedContinuation {
            acknowledgementFailureWaiters.append((count, $0))
        }
    }

    func waitForLifecycleRetry(attempt: Int) async throws {
        lifecycleRetryScheduleCount += 1
        let ready = lifecycleRetryScheduleWaiters.filter {
            $0.0 <= lifecycleRetryScheduleCount
        }
        lifecycleRetryScheduleWaiters.removeAll {
            $0.0 <= lifecycleRetryScheduleCount
        }
        for (_, waiter) in ready { waiter.resume() }
        guard blocksLifecycleRetry else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    lifecycleRetryWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelLifecycleRetryWaiter(waiterID) }
        }
    }

    func waitUntilLifecycleRetryScheduled(count: Int) async {
        guard lifecycleRetryScheduleCount < count else { return }
        await withCheckedContinuation {
            lifecycleRetryScheduleWaiters.append((count, $0))
        }
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
        for (_, cancellationWaiter) in ready {
            cancellationWaiter.resume()
        }
    }

    func waitUntilLifecycleRetryCancellation(count: Int) async {
        guard lifecycleRetryCancellationCount < count else { return }
        await withCheckedContinuation {
            lifecycleRetryCancellationWaiters.append((count, $0))
        }
    }

    func waitUntilRetirementRetryBlocked() async {
        guard !retirementRetryDidBlock else { return }
        await withCheckedContinuation {
            retirementRetryBlockWaiters.append($0)
        }
    }

    func releaseRetirementRetry() {
        blocksRetirementRetry = false
        let waiters = retirementRetryReleaseWaiters
        retirementRetryReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilRetirementWaiting() async {
        guard retirementWaitCount == 0 else { return }
        await withCheckedContinuation { retirementWaiters.append($0) }
    }

    func waitUntilSubmitted(count: Int = 1) async {
        guard submissionCount < count else { return }
        await withCheckedContinuation {
            submissionWaiters.append((count, $0))
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func close() { isOpen = false }
}
