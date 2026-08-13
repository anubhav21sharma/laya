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
    func acknowledgementFailureIsAttemptedOnceAfterCompletedPublication()
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
        let diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.completedUpdateCount == 1)
        #expect(diagnostic.failedUpdateCount == 1)
        #expect(diagnostic.acknowledgementSettlementCount == 1)
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
                try await rig.cache.retire(generation: rig.generation)
            case .cancellation:
                try await rig.cache.cancel(generation: rig.generation)
            }
        }
        for _ in 0..<100
        where (await rig.cache.snapshot()).retirementWaiterCount == 0 {
            await Task.yield()
        }

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

        diagnostic = await rig.cache.snapshot()
        #expect(diagnostic.retirementWaiterCount == 0)
        #expect(diagnostic.retirementResumeCount == 1)
        #expect(diagnostic.activeUpdateSlotCount == 0)
        #expect(diagnostic.acknowledgementSettlementCount == 1)
        #expect(update.acknowledgement.testingRequestCount == 1)
        #expect(try await rig.cache.current(generation: rig.generation) == nil)
    }

    @MainActor
    private func makeRig(
        gateCompletion: Bool = false,
        maximumTileCount: Int = 8,
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
            byteBudget: PaintTileDescriptor.residentByteCount * 16,
            maximumTileCount: maximumTileCount,
            completionGate: gate,
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

private actor InteractiveStrokePresentationCacheGate:
    InteractiveStrokePresentationCacheCompletionGating
{
    private var isOpen: Bool
    private var submissionCount = 0
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var submissionWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []

    init(initiallyOpen: Bool) { isOpen = initiallyOpen }

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
