import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Document paint stable snapshot renderer", .serialized)
struct DocumentPaintStableSnapshotRendererTests {
    @Test
    func pureChunkMathIsDeterministicCheckedAndRowAligned() throws {
        let square = try region(10, 20, 14, 24)
        let squareHalves = try DocumentPaintStableSnapshotChunkPlanner
            .bisect(square)
        #expect(squareHalves == [
            try region(10, 20, 12, 24),
            try region(12, 20, 14, 24),
        ])

        let tall = try region(-2, 7, 0, 13)
        let tallHalves = try DocumentPaintStableSnapshotChunkPlanner
            .bisect(tall)
        #expect(tallHalves == [
            try region(-2, 7, 0, 10),
            try region(-2, 10, 0, 13),
        ])

        #expect(try DocumentPaintStableSnapshotChunkPlanner
            .alignedReadbackBytesPerRow(width: 1) == 256)
        #expect(try DocumentPaintStableSnapshotChunkPlanner
            .alignedReadbackBytesPerRow(width: 64) == 256)
        #expect(try DocumentPaintStableSnapshotChunkPlanner
            .alignedReadbackBytesPerRow(width: 65) == 512)
        #expect(throws: DocumentPaintStableSnapshotRendererError
            .arithmeticOverflow) {
            _ = try DocumentPaintStableSnapshotChunkPlanner
                .alignedReadbackBytesPerRow(width: Int.max)
        }
    }

    @Test
    func childTransformPreservesOneGlobalMappingWithoutFakeRevision() throws {
        let full = try region(100, -50, 300, 150)
        let child = try region(160, 20, 200, 60)
        let global = SparseTileOutputToSourceTransform(
            sourceOffset: SIMD2(7.5, -2.25),
            sourceStep: SIMD2(1.5, 0.25)
        )
        let derived = try DocumentPaintStableSnapshotChunkPlanner
            .childTransform(global: global, full: full, child: child)
        // O + (C-F) * (S-1)
        #expect(derived.sourceOffset == SIMD2(37.5, -54.75))
        #expect(derived.sourceStep == global.sourceStep)

        let fullSourceAtChildOrigin = SIMD2(
            Float(full.minX), Float(full.minY)
        ) + global.sourceOffset + SIMD2(
            Float(child.minX - full.minX),
            Float(child.minY - full.minY)
        ) * global.sourceStep
        let childSourceAtOrigin = SIMD2(
            Float(child.minX), Float(child.minY)
        ) + derived.sourceOffset
        #expect(childSourceAtOrigin == fullSourceAtChildOrigin)

        let largeFull = try region(16_777_216, 0, 16_777_219, 1)
        let inexact = try region(16_777_217, 0, 16_777_218, 1)
        #expect(throws: DocumentPaintStableSnapshotRendererError
            .inexactFloatCoordinate) {
            _ = try DocumentPaintStableSnapshotChunkPlanner.childTransform(
                global: .identity,
                full: largeFull,
                child: inexact
            )
        }
        #expect(throws: DocumentPaintStableSnapshotRendererError
            .childOutsideFullRegion) {
            _ = try DocumentPaintStableSnapshotChunkPlanner.childTransform(
                global: .identity,
                full: try region(0, 0, 1, 1),
                child: try region(1, 0, 2, 1)
            )
        }
    }

    @Test
    func limitsRejectZeroNegativeAndOverflowingScratch() throws {
        #expect(throws: DocumentPaintStableSnapshotRendererError.invalidLimit) {
            _ = try DocumentPaintStableSnapshotRendererLimits(
                maximumChunkWidth: 0,
                maximumChunkHeight: 1,
                maximumScratchBytes: 4,
                maximumRetryCleanupPasses: 1
            )
        }
        #expect(throws: DocumentPaintStableSnapshotRendererError.invalidLimit) {
            _ = try DocumentPaintStableSnapshotRendererLimits(
                maximumChunkWidth: 1,
                maximumChunkHeight: -1,
                maximumScratchBytes: 4,
                maximumRetryCleanupPasses: 1
            )
        }
        #expect(throws: DocumentPaintStableSnapshotRendererError.invalidLimit) {
            _ = try DocumentPaintStableSnapshotRendererLimits(
                maximumChunkWidth: Int.max,
                maximumChunkHeight: Int.max,
                maximumScratchBytes: Int.max,
                maximumRetryCleanupPasses: 1
            )
        }
    }

    @Test
    func mixedAxisPendingChunksAreGloballyRowMajorAndOutputIsBounded()
        throws
    {
        let topLeft = try region(0, 0, 2, 2)
        let bottomLeft = try region(0, 2, 2, 4)
        let right = try region(2, 0, 4, 4)
        #expect(DocumentPaintStableSnapshotChunkPlanner.orderedForEmission([
            bottomLeft, right, topLeft,
        ]) == [topLeft, right, bottomLeft])

        let limits = try DocumentPaintStableSnapshotRendererLimits(
            maximumChunkWidth: 4,
            maximumChunkHeight: 4,
            maximumScratchBytes: 1_024,
            maximumOutputPixels: 16,
            maximumOutputBytes: 64,
            maximumRetryCleanupPasses: 1
        )
        try DocumentPaintStableSnapshotChunkPlanner.validateOutput(
            try region(0, 0, 4, 4),
            limits: limits
        )
        #expect(throws: DocumentPaintStableSnapshotRendererError
            .outputLimitExceeded(required: 20, maximum: 16)) {
            try DocumentPaintStableSnapshotChunkPlanner.validateOutput(
                try region(0, 0, 5, 4),
                limits: limits
            )
        }
    }

    @Test
    func boundedPendingHeapMaintainsRowMajorOrderUnderHighSplitCount()
        throws
    {
        var pending = DocumentPaintStableSnapshotPendingRegions()
        let count = 65_536
        for value in (0..<count).reversed() {
            pending.insert(try region(value, value / 256, value + 1,
                                      value / 256 + 1))
        }
        #expect(pending.count == count)
        var previous: SparseTileOutputRegion?
        while let next = pending.popFirst() {
            if let previous {
                #expect((previous.minY, previous.minX)
                    <= (next.minY, next.minX))
            }
            previous = next
        }
        #expect(pending.count == 0)
    }

    @Test @MainActor
    func emptyMetalRenderSplitsRowMajorAndLeavesEveryCacheClean()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLibrary(device)
        let fixture = try makeFixture(device: device)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 1
        )
        defer { snapshot.close() }
        let renderer = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: library,
            backendRequest: .forceFallback,
            limits: rendererLimits(chunk: 2)
        )
        let sink = RendererTestSink()
        try await renderer.render(
            request(snapshot: snapshot, output: try region(0, 0, 4, 4)),
            to: sink
        )

        let record = await sink.record()
        #expect(record.began == 1)
        #expect(record.finished == 1)
        #expect(record.aborted == 0)
        #expect(record.chunks.map(\.outputRegion) == [
            try region(0, 0, 2, 2),
            try region(2, 0, 4, 2),
            try region(0, 2, 2, 4),
            try region(2, 2, 4, 4),
        ])
        #expect(record.chunks.allSatisfy { $0.bytes.allSatisfy { $0 == 0 } })
        let state = await renderer.snapshot()
        assertClean(state)
        #expect(state.lifecycle == .active)
        #expect(state.metrics.completedRequestCount == 1)
        #expect(state.metrics.emittedChunkCount == 4)
        #expect(snapshot.activeChildSelectionCount == 0)
    }

    @Test @MainActor
    func uniformCommittedColorMatchesCPUInterchangeOracleOnEveryBackend()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLibrary(device)
        let fixture = try makeFixture(device: device)
        let color = SIMD4<Float>(0.125, 0.25, 0.0625, 0.5)
        try seed(
            fixture,
            coordinate: PaintTileCoordinate(x: 0, y: 0),
            color: color
        )
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 8
        )
        defer { snapshot.close() }
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
        let expected = DocumentColorPipeline
            .exportEncodedPremultipliedBGRA8(linear)
        let expectedBytes = [
            expected.blue, expected.green, expected.red, expected.alpha,
        ]
        let backends: [SparseTileSamplingBackendRequest] =
            device.argumentBuffersSupport == .tier2
                ? [.forceFallback, .forceTier2] : [.forceFallback]
        for backend in backends {
            let renderer = try DocumentPaintStableSnapshotRenderer.make(
                device: device,
                library: library,
                backendRequest: backend,
                limits: rendererLimits(chunk: 2)
            )
            let sink = RendererTestSink()
            try await renderer.render(
                request(
                    snapshot: snapshot,
                    output: try region(0, 0, 2, 2)
                ),
                to: sink
            )
            let record = await sink.record()
            #expect(record.chunks.count == 1)
            let bytes = try #require(record.chunks.first?.bytes)
            #expect(Array(bytes.prefix(4)) == expectedBytes)
            #expect(bytes.count == 16)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                #expect(Array(bytes[offset..<(offset + 4)]) == expectedBytes)
            }
            assertClean(await renderer.snapshot())
        }
    }

    @Test @MainActor
    func cancellationAndCapacityShapedSinkFailureNeverEmitOverlap()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLibrary(device)
        let fixture = try makeFixture(device: device)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 1
        )
        defer { snapshot.close() }
        let renderer = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: library,
            backendRequest: .forceFallback,
            limits: rendererLimits(chunk: 2)
        )
        let cancelledSink = RendererTestSink()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await renderer.render(
                request(snapshot: snapshot, output: try region(0, 0, 1, 1)),
                to: cancelledSink
            )
        }
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(await cancelledSink.record() == RendererSinkRecord())
        assertClean(await renderer.snapshot())

        let failingSink = RendererTestSink(consumeCapacityFailure: true)
        await #expect(throws: SparseTileSamplingPipelineError
            .limitExceeded(required: 2, maximum: 1)) {
            try await renderer.render(
                request(snapshot: snapshot, output: try region(0, 0, 4, 4)),
                to: failingSink
            )
        }
        let failed = await failingSink.record()
        #expect(failed.began == 1)
        #expect(failed.chunks.count == 1)
        #expect(failed.finished == 0)
        #expect(failed.aborted == 1)
        assertClean(await renderer.snapshot())

        let recovery = RendererTestSink()
        try await renderer.render(
            request(snapshot: snapshot, output: try region(0, 0, 1, 1)),
            to: recovery
        )
        #expect(await recovery.record().finished == 1)
        assertClean(await renderer.snapshot())
    }

    @Test @MainActor
    func cancellationAtOwnershipSuspensionsAndAfterEncodeAlwaysDrains()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLibrary(device)
        let fixture = try makeFixture(device: device)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 1
        )
        defer { snapshot.close() }
        let request = request(
            snapshot: snapshot,
            output: try region(0, 0, 1, 1)
        )

        let evictionGate = RendererTestGate()
        var hooks = DocumentPaintStableSnapshotRendererTestHooks()
        hooks.afterCPUEviction = { await evictionGate.pause() }
        let suspended = try DocumentPaintStableSnapshotRenderer.testingMake(
            device: device,
            library: library,
            planCache: SparseTileSamplingPlanCache(),
            hooks: hooks
        )
        let suspendedSink = RendererTestSink()
        let suspendedTask = Task {
            try await suspended.render(request, to: suspendedSink)
        }
        await evictionGate.waitUntilReached()
        let duringEviction = await suspended.snapshot()
        #expect(duringEviction.lifecycle == .busy)
        #expect(duringEviction.cpuCache.cachedContentCount == 0)
        suspendedTask.cancel()
        await evictionGate.open()
        await #expect(throws: CancellationError.self) {
            try await suspendedTask.value
        }
        let suspendedRecord = await suspendedSink.record()
        #expect(suspendedRecord.began == 1)
        #expect(suspendedRecord.chunks.isEmpty)
        #expect(suspendedRecord.aborted == 1)
        assertClean(await suspended.snapshot())

        for keyPath in [
            \DocumentPaintStableSnapshotRendererTestHooks.afterGPUAcquire,
            \DocumentPaintStableSnapshotRendererTestHooks.afterGPUInvalidation,
        ] {
            let gate = RendererTestGate()
            var gatedHooks = DocumentPaintStableSnapshotRendererTestHooks()
            gatedHooks[keyPath: keyPath] = { await gate.pause() }
            let gated = try DocumentPaintStableSnapshotRenderer.testingMake(
                device: device,
                library: library,
                planCache: SparseTileSamplingPlanCache(),
                hooks: gatedHooks
            )
            let sink = RendererTestSink()
            let task = Task { try await gated.render(request, to: sink) }
            await gate.waitUntilReached()
            #expect((await gated.snapshot()).lifecycle == .busy)
            task.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            #expect(await sink.record().aborted == 1)
            let terminal = await gated.snapshot()
            #expect(terminal.lifecycle == .active)
            assertClean(terminal)
        }

        let commitGate = RendererTestGate()
        hooks = DocumentPaintStableSnapshotRendererTestHooks()
        hooks.afterCommandCommit = { await commitGate.pause() }
        let encoded = try DocumentPaintStableSnapshotRenderer.testingMake(
            device: device,
            library: library,
            planCache: SparseTileSamplingPlanCache(),
            hooks: hooks
        )
        let encodedSink = RendererTestSink()
        let encodedTask = Task {
            try await encoded.render(request, to: encodedSink)
        }
        await commitGate.waitUntilReached()
        #expect((await encoded.snapshot()).inflightCommandCount == 1)
        encodedTask.cancel()
        await commitGate.open()
        await #expect(throws: CancellationError.self) {
            try await encodedTask.value
        }
        let encodedRecord = await encodedSink.record()
        #expect(encodedRecord.began == 1)
        #expect(encodedRecord.chunks.isEmpty)
        #expect(encodedRecord.aborted == 1)
        let encodedState = await encoded.snapshot()
        #expect(encodedState.metrics.terminalCommandCount == 1)
        assertClean(encodedState)
        #expect(snapshot.activeChildSelectionCount == 0)
    }

    @Test @MainActor
    func busyRenderAndRetryAreRejectedAndAwaitedShutdownIsTerminal()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeFixture(device: device)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 1
        )
        defer { snapshot.close() }
        let renderer = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: try makeLibrary(device),
            backendRequest: .forceFallback
        )
        let gate = RendererTestGate()
        let sink = RendererTestSink(beginGate: gate)
        let request = request(
            snapshot: snapshot,
            output: try region(0, 0, 1, 1)
        )
        let renderTask = Task { try await renderer.render(request, to: sink) }
        await gate.waitUntilReached()
        await #expect(throws: DocumentPaintStableSnapshotRendererError.busy) {
            try await renderer.render(request, to: RendererTestSink())
        }
        await #expect(throws: DocumentPaintStableSnapshotRendererError.busy) {
            try await renderer.retryCleanup()
        }
        let shutdownTask = Task { try await renderer.shutdown() }
        while !(await renderer.snapshot()).shutdownRequested {
            await Task.yield()
        }
        await gate.open()
        await #expect(throws: DocumentPaintStableSnapshotRendererError.shutDown) {
            try await renderTask.value
        }
        try await shutdownTask.value
        let record = await sink.record()
        #expect(record.began == 1)
        #expect(record.aborted == 1)
        let terminal = await renderer.snapshot()
        #expect(terminal.lifecycle == .shutDown)
        assertClean(terminal)
        #expect(snapshot.activeChildSelectionCount == 0)
        try await renderer.shutdown()
        await #expect(throws: DocumentPaintStableSnapshotRendererError.shutDown) {
            try await renderer.render(request, to: RendererTestSink())
        }
    }

    @Test @MainActor
    func cleanupRetryOwnsExclusiveLifecycleAndRestoresImmediateReuse()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeFixture(device: device)
        try seed(
            fixture,
            coordinate: PaintTileCoordinate(x: 0, y: 0),
            color: SIMD4(0.25, 0, 0, 1)
        )
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 1
        )
        defer { snapshot.close() }
        let returner = RendererLeaseReturnProbe(failures: 2)
        let gate = RendererTestGate()
        var hooks = DocumentPaintStableSnapshotRendererTestHooks()
        hooks.beforeCleanupRetryPass = { await gate.pause() }
        let renderer = try DocumentPaintStableSnapshotRenderer.testingMake(
            device: device,
            library: try makeLibrary(device),
            planCache: SparseTileSamplingPlanCache(returnLease: returner.call),
            hooks: hooks
        )
        let request = request(
            snapshot: snapshot,
            output: try region(0, 0, 1, 1)
        )
        let failedSink = RendererTestSink()
        await #expect(throws: DocumentPaintStableSnapshotRendererError
            .cleanupPending) {
            try await renderer.render(request, to: failedSink)
        }
        #expect((await renderer.snapshot()).lifecycle == .cleanupPending)
        #expect(await failedSink.record().aborted == 1)

        let retry = Task { try await renderer.retryCleanup() }
        await gate.waitUntilReached()
        #expect((await renderer.snapshot()).lifecycle == .cleaning)
        await #expect(throws: DocumentPaintStableSnapshotRendererError.busy) {
            try await renderer.retryCleanup()
        }
        await #expect(throws: DocumentPaintStableSnapshotRendererError.busy) {
            try await renderer.render(request, to: RendererTestSink())
        }
        await gate.open()
        let retried = try await retry.value
        #expect(retried.lifecycle == .active)
        assertClean(retried)

        let recovery = RendererTestSink()
        try await renderer.render(request, to: recovery)
        #expect(await recovery.record().finished == 1)
        assertClean(await renderer.snapshot())
        #expect(snapshot.activeChildSelectionCount == 0)
    }

    @Test @MainActor
    func productionShapedPhaseFailuresAbortOnceDrainAndRemainReusable()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeFixture(device: device)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 1
        )
        defer { snapshot.close() }
        let library = try makeLibrary(device)
        let request = request(
            snapshot: snapshot,
            output: try region(0, 0, 2, 2)
        )

        for phase in [
            DocumentPaintStableSnapshotRendererTestPhase.commandCreation,
            .submissionPreparation,
            .submissionEncoding,
            .readbackEncoding,
            .commandTerminal,
        ] {
            let failure = RendererPhaseFailureProbe([phase])
            var hooks = DocumentPaintStableSnapshotRendererTestHooks()
            hooks.shouldFailAtPhase = failure.shouldFail
            let renderer = try DocumentPaintStableSnapshotRenderer.testingMake(
                device: device,
                library: library,
                planCache: SparseTileSamplingPlanCache(),
                hooks: hooks
            )
            let sink = RendererTestSink()
            do {
                try await renderer.render(request, to: sink)
                Issue.record("phase \(phase) unexpectedly succeeded")
            } catch {
                switch phase {
                case .commandCreation:
                    #expect(error as? DocumentPaintStableSnapshotRendererError
                        == .commandCreationFailed)
                case .submissionPreparation:
                    #expect(error as? SparseTileSamplingPipelineError
                        == .injectedFailure(
                            "stableSnapshotSubmissionPreparation"
                        ))
                case .submissionEncoding:
                    #expect(error as? SparseTileSamplingPipelineError
                        == .injectedFailure(
                            "stableSnapshotSubmissionEncoding"
                        ))
                case .readbackEncoding:
                    #expect(error as? DocumentPaintStableSnapshotRendererError
                        == .readbackEncodingFailed)
                case .commandTerminal:
                    guard case DocumentPaintStableSnapshotRendererError
                        .commandFailed = error else {
                        Issue.record("wrong terminal error: \(error)")
                        continue
                    }
                case .scratchAllocation, .targetAllocation,
                     .readbackAllocation, .proportionalPlanBufferAllocation:
                    Issue.record("unexpected scratch phase")
                }
            }
            let record = await sink.record()
            #expect(record.began == 1)
            #expect(record.finished == 0)
            #expect(record.aborted == 1)
            #expect(record.chunks.isEmpty)
            let failedState = await renderer.snapshot()
            #expect(failedState.lifecycle == .active)
            assertClean(failedState)
            #expect(snapshot.activeChildSelectionCount == 0)

            let recovered = RendererTestSink()
            try await renderer.render(request, to: recovered)
            #expect(await recovered.record().finished == 1)
            assertClean(await renderer.snapshot())
        }

        var scratchRenderer: DocumentPaintStableSnapshotRenderer?
        for phase in [
            DocumentPaintStableSnapshotRendererTestPhase.scratchAllocation,
            .targetAllocation,
            .readbackAllocation,
            .proportionalPlanBufferAllocation,
        ] {
            let oneShotScratchFailure = RendererPhaseFailureProbe([phase])
            var scratchHooks =
                DocumentPaintStableSnapshotRendererTestHooks()
            scratchHooks.shouldFailAtPhase = oneShotScratchFailure.shouldFail
            let renderer = try DocumentPaintStableSnapshotRenderer.testingMake(
                device: device,
                library: library,
                limits: rendererLimits(chunk: 2),
                planCache: SparseTileSamplingPlanCache(),
                hooks: scratchHooks
            )
            let scratchSink = RendererTestSink()
            try await renderer.render(request, to: scratchSink)
            let scratchRecord = await scratchSink.record()
            #expect(scratchRecord.began == 1)
            #expect(scratchRecord.chunks.count == 2)
            #expect(scratchRecord.finished == 1)
            let scratchState = await renderer.snapshot()
            #expect(scratchState.metrics.adaptiveSplitCount == 1)
            #expect(scratchState.metrics.terminalCommandCount == 2)
            assertClean(scratchState)
            scratchRenderer = renderer
        }

        for phase in [
            DocumentPaintStableSnapshotRendererTestPhase.scratchAllocation,
            .proportionalPlanBufferAllocation,
        ] {
            var persistentHooks =
                DocumentPaintStableSnapshotRendererTestHooks()
            persistentHooks.shouldFailAtPhase = { $0 == phase }
            let minimumRenderer = try DocumentPaintStableSnapshotRenderer
                .testingMake(
                device: device,
                library: library,
                limits: rendererLimits(chunk: 2),
                planCache: SparseTileSamplingPlanCache(),
                hooks: persistentHooks
            )
            await #expect(throws: DocumentPaintStableSnapshotRendererError
                .cannotFitMinimumChunk(try region(0, 0, 1, 1))) {
                try await minimumRenderer.render(
                    request,
                    to: RendererTestSink()
                )
            }
            let minimumState = await minimumRenderer.snapshot()
            #expect(minimumState.lifecycle == .active)
            assertClean(minimumState)
        }

        let recovery = RendererTestSink()
        let recoveredScratchRenderer = try #require(scratchRenderer)
        try await recoveredScratchRenderer.render(request, to: recovery)
        #expect(await recovery.record().finished == 1)
        assertClean(await recoveredScratchRenderer.snapshot())
        let separateRecovery = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: library,
            backendRequest: .forceFallback
        )
        try await separateRecovery.shutdown()
        #expect(snapshot.activeChildSelectionCount == 0)
    }

    @Test @MainActor
    func concurrentShutdownWaitersShareCleanupFailureThenRetryTerminates()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeFixture(device: device)
        try seed(
            fixture,
            coordinate: PaintTileCoordinate(x: 0, y: 0),
            color: SIMD4(0.25, 0, 0, 1)
        )
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 1
        )
        defer { snapshot.close() }
        let returner = RendererLeaseReturnProbe(failures: 100)
        let gate = RendererTestGate()
        var hooks = DocumentPaintStableSnapshotRendererTestHooks()
        hooks.beforeCleanupRetryPass = { await gate.pause() }
        let renderer = try DocumentPaintStableSnapshotRenderer.testingMake(
            device: device,
            library: try makeLibrary(device),
            limits: try DocumentPaintStableSnapshotRendererLimits(
                maximumChunkWidth: 1,
                maximumChunkHeight: 1,
                maximumScratchBytes: 4 * 1_024 * 1_024,
                maximumOutputPixels: 4,
                maximumOutputBytes: 16,
                maximumRetryCleanupPasses: 1
            ),
            planCache: SparseTileSamplingPlanCache(returnLease: returner.call),
            hooks: hooks
        )
        let request = request(
            snapshot: snapshot,
            output: try region(0, 0, 1, 1)
        )
        await #expect(throws: DocumentPaintStableSnapshotRendererError
            .cleanupPending) {
            try await renderer.render(request, to: RendererTestSink())
        }
        let first = Task { try await renderer.shutdown() }
        await gate.waitUntilReached()
        let second = Task { try await renderer.shutdown() }
        while (await renderer.snapshot()).shutdownWaiterCount != 1 {
            await Task.yield()
        }
        await gate.open()
        await #expect(throws: DocumentPaintStableSnapshotRendererError
            .cleanupPending) { try await first.value }
        await #expect(throws: DocumentPaintStableSnapshotRendererError
            .cleanupPending) { try await second.value }
        let pending = await renderer.snapshot()
        #expect(pending.lifecycle == .cleanupPending)
        #expect(pending.shutdownRequested)

        returner.allowReturns()
        let terminal = try await renderer.retryCleanup()
        #expect(terminal.lifecycle == .shutDown)
        assertClean(terminal)
        #expect(snapshot.activeChildSelectionCount == 0)
    }

    @Test @MainActor
    func splitAndUnsplitReconstructIdenticallyAcrossFiniteAndPeriodicSeams()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 512, height: 512),
            storagePixelSize: PixelSize(width: 512, height: 512),
            radialLayout: nil
        )
        let fixture = try makeFixture(device: device, geometry: geometry)
        try seed(fixture, coordinate: .init(x: 0, y: 0),
                 color: SIMD4(1, 0, 0, 1))
        try seed(fixture, coordinate: .init(x: 1, y: 0),
                 color: SIMD4(0, 1, 0, 1))
        try seed(fixture, coordinate: .init(x: 0, y: 1),
                 color: SIMD4(0, 0, 1, 1))
        // (1, 1) intentionally remains missing to exercise a transparent
        // neighbor in the four-way bilinear seam.
        let library = try makeLibrary(device)
        let output = try region(10, 20, 18, 26)
        let finite = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 31
        )
        let finiteRequest = request(
            snapshot: finite,
            output: output,
            transform: SparseTileOutputToSourceTransform(
                sourceOffset: SIMD2(245, 235),
                sourceStep: SIMD2(0.75, 0.75)
            )
        )
        let finiteWhole = try await renderTightBytes(
            request: finiteRequest,
            chunk: 16,
            device: device,
            library: library
        )
        let finiteSplit = try await renderTightBytes(
            request: finiteRequest,
            chunk: 2,
            device: device,
            library: library
        )
        #expect(finiteSplit == finiteWhole)
        #expect(Set(stride(from: 3, to: finiteWhole.count, by: 4).map {
            finiteWhole[$0]
        }).count > 1)
        finite.close()

        let periodic = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .periodic(period: geometry.storagePixelSize),
            addressingRevision: 32
        )
        let periodicOutput = try region(-3, -2, 5, 4)
        let periodicRequest = request(
            snapshot: periodic,
            output: periodicOutput,
            transform: SparseTileOutputToSourceTransform(
                sourceOffset: SIMD2(514, 513),
                sourceStep: SIMD2(0.75, 0.75)
            )
        )
        let periodicWhole = try await renderTightBytes(
            request: periodicRequest,
            chunk: 16,
            device: device,
            library: library
        )
        let periodicSplit = try await renderTightBytes(
            request: periodicRequest,
            chunk: 2,
            device: device,
            library: library
        )
        #expect(periodicSplit == periodicWhole)
        #expect(periodicWhole != finiteWhole)
        periodic.close()
        let store = fixture.registry.sharedTileStore.snapshot()
        #expect(store.activeSnapshotTokenCount == 0)
        #expect(store.activeLeaseCount == 0)
        #expect(store.snapshotPayloadDebtByteCount == 0)
    }

    @Test @MainActor
    func stableOldRootRendersOldPixelsAfterNewEpochMutation()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeFixture(device: device)
        let oldColor = SIMD4<Float>(0.5, 0, 0, 1)
        try seed(fixture, coordinate: .init(x: 0, y: 0), color: oldColor)
        let old = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 41
        )
        let newColor = SIMD4<Float>(0, 0.5, 0, 1)
        try seed(fixture, coordinate: .init(x: 0, y: 0), color: newColor)
        let new = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 41
        )
        let library = try makeLibrary(device)
        let output = try region(0, 0, 2, 2)
        let oldBytes = try await renderTightBytes(
            request: request(snapshot: old, output: output),
            chunk: 1,
            device: device,
            library: library
        )
        let newBytes = try await renderTightBytes(
            request: request(snapshot: new, output: output),
            chunk: 1,
            device: device,
            library: library
        )
        #expect(old.documentGeneration != new.documentGeneration)
        #expect(oldBytes != newBytes)
        let expectedOld = try encodedPixel(oldColor)
        let expectedNew = try encodedPixel(newColor)
        for offset in stride(from: 0, to: oldBytes.count, by: 4) {
            #expect(Array(oldBytes[offset..<(offset + 4)]) == expectedOld)
            #expect(Array(newBytes[offset..<(offset + 4)]) == expectedNew)
        }
        old.close()
        new.close()
        let store = fixture.registry.sharedTileStore.snapshot()
        #expect(store.activeSnapshotTokenCount == 0)
        #expect(store.activeLeaseCount == 0)
        #expect(store.snapshotPayloadDebtByteCount == 0)
    }

    @Test @MainActor
    func signedRadialNonzeroOriginSplitMatchesWholeRender() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 512,
            sectorAngleRadians: .pi
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 1_024, height: 1_024),
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let fixture = try makeFixture(device: device, geometry: geometry)
        let page = try #require(layout.residentPages.first {
            $0.coordinate.x < 0
        })
        let physical = PaintTileCoordinate(
            x: page.atlasSlot % layout.atlasColumns,
            y: page.atlasSlot / layout.atlasColumns
        )
        try seed(
            fixture,
            coordinate: physical,
            color: SIMD4(0.125, 0.375, 0.625, 0.875)
        )
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .radial(layout: layout),
            addressingRevision: 51
        )
        let output = try region(7, 9, 13, 13)
        let logicalOrigin = SIMD2<Float>(
            Float(page.coordinate.x * PaintTileDescriptor.side + 10),
            Float(page.coordinate.y * PaintTileDescriptor.side + 10)
        )
        let transform = SparseTileOutputToSourceTransform(
            sourceOffset: logicalOrigin - SIMD2(
                Float(output.minX), Float(output.minY)
            ),
            sourceStep: SIMD2(0.75, 0.75)
        )
        let request = request(
            snapshot: snapshot,
            output: output,
            transform: transform
        )
        let library = try makeLibrary(device)
        let whole = try await renderTightBytes(
            request: request,
            chunk: 16,
            device: device,
            library: library
        )
        let split = try await renderTightBytes(
            request: request,
            chunk: 2,
            device: device,
            library: library
        )
        #expect(split == whole)
        #expect(whole.contains { $0 != 0 })
        snapshot.close()
        let store = fixture.registry.sharedTileStore.snapshot()
        #expect(store.activeSnapshotTokenCount == 0)
        #expect(store.activeLeaseCount == 0)
        #expect(store.snapshotPayloadDebtByteCount == 0)
    }

    @Test
    func finiteRadialChildMappingRemainsGlobalAcrossBisection() throws {
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 8,
                center: WorldPoint(x: 317.5, y: 241.25),
                referenceAngleRadians: 0.375
            )),
            canvasSize: PixelSize(width: 768, height: 640)
        )
        let mapping = try SparseTileSamplingOutputMapping.finiteRadial(
            strategy: strategy
        )
        let full = try region(-16, 23, 240, 151)
        let child = try region(112, 23, 240, 151)

        let actual = try DocumentPaintStableSnapshotChunkPlanner.childMapping(
            global: mapping,
            full: full,
            child: child
        )

        #expect(actual == mapping)
    }

    @Test @MainActor
    func inconsistentFiniteRadialRequestFailsBeforeStartingSinkOrLeasing()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let sourceStrategy = try TilingStrategy(
            finiteConfiguration: .radial(RadialSymmetryConfiguration(
                kind: .mirror,
                rayCount: 1,
                center: WorldPoint(x: 256, y: 256)
            )),
            canvasSize: PixelSize(width: 512, height: 512)
        )
        let requestedStrategy = try TilingStrategy(
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
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 512, height: 512),
            storagePixelSize: sourceLayout.atlasPixelSize,
            radialLayout: sourceLayout
        )
        let fixture = try makeFixture(
            device: device,
            geometry: geometry,
            byteBudgetTiles: sourceLayout.residentPages.count
        )
        let firstPage = try #require(sourceLayout.residentPages.first)
        try seed(
            fixture,
            coordinate: PaintTileCoordinate(
                x: firstPage.atlasSlot % sourceLayout.atlasColumns,
                y: firstPage.atlasSlot / sourceLayout.atlasColumns
            ),
            color: SIMD4(0.25, 0.5, 0.75, 1)
        )
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .radial(layout: sourceLayout),
            addressingRevision: 81
        )
        let renderer = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: try makeLibrary(device),
            backendRequest: .forceFallback
        )
        let sink = RendererTestSink()
        let invalid = DocumentPaintStableSnapshotRenderRequest(
            snapshot: snapshot,
            outputRegion: try region(0, 0, 16, 16),
            outputGeometryRevision: 19,
            outputMapping: try .finiteRadial(strategy: requestedStrategy)
        )
        let storeBefore = fixture.registry.sharedTileStore.snapshot()
        let rendererBefore = await renderer.snapshot()
        #expect(rendererBefore.metrics.targetAllocationCount == 0)
        #expect(rendererBefore.metrics.readbackAllocationCount == 0)
        #expect(rendererBefore.targetByteCount == 0)
        #expect(rendererBefore.readbackByteCount == 0)

        await #expect(throws: SparseTileSamplingPlanError
            .inconsistentAddressing) {
            try await renderer.render(invalid, to: sink)
        }
        #expect(await sink.record() == RendererSinkRecord())
        #expect(snapshot.activeChildSelectionCount == 0)
        let rendererAfter = await renderer.snapshot()
        #expect(rendererAfter == rendererBefore)
        #expect(rendererAfter.metrics.targetAllocationCount == 0)
        #expect(rendererAfter.metrics.readbackAllocationCount == 0)
        #expect(rendererAfter.targetByteCount == 0)
        #expect(rendererAfter.readbackByteCount == 0)
        #expect(rendererAfter.cpuCache == rendererBefore.cpuCache)
        #expect(rendererAfter.gpuCache == rendererBefore.gpuCache)
        #expect(rendererAfter.completion == rendererBefore.completion)
        assertClean(rendererAfter)
        let storeAfter = fixture.registry.sharedTileStore.snapshot()
        #expect(storeAfter == storeBefore)
        #expect(storeAfter.activeSnapshotTokenCount
            == storeBefore.activeSnapshotTokenCount)
        #expect(storeAfter.aggregateSnapshotReferenceCount
            == storeBefore.aggregateSnapshotReferenceCount)
        #expect(storeAfter.activeLeaseCount == 0)
        #expect(storeAfter.snapshotPayloadDebtByteCount
            == storeBefore.snapshotPayloadDebtByteCount)
        snapshot.close()
        assertStoreDebtIsZero(fixture.registry.sharedTileStore.snapshot())
    }

    @Test @MainActor
    func finiteRadialKindsMatchIndependentOracleAndBackendSplitParity()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeLibrary(device)
        for kind in [
            RadialSymmetryKind.rotation,
            .mirror,
            .mandala,
        ] {
            let configuration = RadialSymmetryConfiguration(
                kind: kind,
                rayCount: kind == .mirror ? 1 : 4,
                center: WorldPoint(x: 311.5, y: 287.5),
                referenceAngleRadians: 0.23
            )
            let canvasSize = PixelSize(width: 768, height: 640)
            let strategy = try TilingStrategy(
                finiteConfiguration: .radial(configuration),
                canvasSize: canvasSize
            )
            let layout = try #require(
                strategy.compiledSymmetry.domain.finite?.radial.layout
            )
            let geometry = try DocumentPaintGeometry(
                documentPixelSize: canvasSize,
                storagePixelSize: layout.atlasPixelSize,
                radialLayout: layout
            )
            let fixture = try makeFixture(
                device: device,
                geometry: geometry,
                byteBudgetTiles: layout.residentPages.count
            )
            var colors: [PaintTileCoordinate: SIMD4<Float>] = [:]
            for page in layout.residentPages {
                let physical = PaintTileCoordinate(
                    x: page.atlasSlot % layout.atlasColumns,
                    y: page.atlasSlot / layout.atlasColumns
                )
                let index = page.atlasSlot + 1
                let color = SIMD4<Float>(
                    Float((index * 3) % 11 + 1) / 16,
                    Float((index * 5) % 13 + 1) / 16,
                    Float((index * 7) % 9 + 1) / 16,
                    1
                )
                colors[physical] = color
                try seed(fixture, coordinate: physical, color: color)
            }
            let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
                layerID: fixture.layerID,
                addressing: .radial(layout: layout),
                addressingRevision: 90 + UInt64(kind.rawValue)
            )
            let output = try region(552, 272, 616, 336)
            let renderRequest = DocumentPaintStableSnapshotRenderRequest(
                snapshot: snapshot,
                outputRegion: output,
                outputGeometryRevision: 19,
                outputMapping: try .finiteRadial(strategy: strategy)
            )
            let fallbackWhole = try await renderTightBytes(
                request: renderRequest,
                chunk: 64,
                device: device,
                library: library,
                backendRequest: .forceFallback
            )
            let fallbackSplit = try await renderTightBytes(
                request: renderRequest,
                chunk: 16,
                device: device,
                library: library,
                backendRequest: .forceFallback
            )
            #expect(fallbackSplit == fallbackWhole)
            if device.argumentBuffersSupport == .tier2 {
                let tier2 = try await renderTightBytes(
                    request: renderRequest,
                    chunk: 16,
                    device: device,
                    library: library,
                    backendRequest: .forceTier2
                )
                #expect(tier2 == fallbackWhole)
            }
            var expected = Data()
            expected.reserveCapacity(output.width * output.height * 4)
            for y in output.minY..<output.maxY {
                for x in output.minX..<output.maxX {
                    expected.append(contentsOf: try expectedRadialPixel(
                        world: WorldPoint(
                            x: Float(x) + 0.5,
                            y: Float(y) + 0.5
                        ),
                        configuration: configuration,
                        canvasSize: canvasSize,
                        layout: layout,
                        colors: colors
                    ))
                }
            }
            expectEncodedBytesWithinOne(fallbackWhole, expected)
            snapshot.close()
            let store = fixture.registry.sharedTileStore.snapshot()
            #expect(store.activeSnapshotTokenCount == 0)
            #expect(store.activeLeaseCount == 0)
            #expect(store.snapshotPayloadDebtByteCount == 0)
        }
    }

    @Test @MainActor
    func finiteRadialExactRayNegativePageAndOutsideMatchEveryOracleByte()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let configuration = RadialSymmetryConfiguration(
            kind: .mirror,
            rayCount: 1,
            center: WorldPoint(x: 384.5, y: 300.5),
            referenceAngleRadians: .pi / 2
        )
        let canvasSize = PixelSize(width: 768, height: 640)
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(configuration),
            canvasSize: canvasSize
        )
        let layout = try #require(
            strategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: canvasSize,
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let fixture = try makeFixture(
            device: device,
            geometry: geometry,
            byteBudgetTiles: layout.residentPages.count
        )
        var colors: [PaintTileCoordinate: SIMD4<Float>] = [:]
        for page in layout.residentPages {
            let physical = PaintTileCoordinate(
                x: page.atlasSlot % layout.atlasColumns,
                y: page.atlasSlot / layout.atlasColumns
            )
            let index = page.atlasSlot + 1
            let color = SIMD4<Float>(
                Float((index * 3) % 11 + 1) / 16,
                Float((index * 5) % 13 + 1) / 16,
                Float((index * 7) % 9 + 1) / 16,
                1
            )
            colors[physical] = color
            try seed(fixture, coordinate: physical, color: color)
        }
        let exactRayWorld = WorldPoint(x: 384.5, y: 0.5)
        let exactFold = try #require(RadialCoverageOracle.fold(
            exactRayWorld,
            configuration: .radial(configuration),
            canvasSize: canvasSize
        ))
        let exactPage = RadialPageCoordinate(
            x: Int(floor(Double(exactFold.x) / 256)),
            y: Int(floor(Double(exactFold.y) / 256))
        )
        #expect(exactPage.x < 0 || exactPage.y < 0)
        #expect(layout.residentPage(at: exactPage) != nil)

        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .radial(layout: layout),
            addressingRevision: 101
        )
        let output = try region(382, -2, 387, 4)
        let renderRequest = DocumentPaintStableSnapshotRenderRequest(
            snapshot: snapshot,
            outputRegion: output,
            outputGeometryRevision: 19,
            outputMapping: try .finiteRadial(strategy: strategy)
        )
        let expected = try expectedRadialBytes(
            output: output,
            configuration: configuration,
            canvasSize: canvasSize,
            layout: layout,
            colors: colors
        )
        let library = try makeLibrary(device)
        let fallbackWhole = try await renderTightBytes(
            request: renderRequest,
            chunk: 16,
            device: device,
            library: library,
            backendRequest: .forceFallback
        )
        let fallbackSplit = try await renderTightBytes(
            request: renderRequest,
            chunk: 1,
            device: device,
            library: library,
            backendRequest: .forceFallback
        )
        expectEncodedBytesWithinOne(fallbackWhole, expected)
        #expect(fallbackSplit == fallbackWhole)
        #expect(expected.prefix(output.width * 2 * 4).allSatisfy { $0 == 0 })
        #expect(expected.dropFirst(output.width * 2 * 4).contains { $0 != 0 })
        if device.argumentBuffersSupport == .tier2 {
            let tier2 = try await renderTightBytes(
                request: renderRequest,
                chunk: 16,
                device: device,
                library: library,
                backendRequest: .forceTier2
            )
            #expect(tier2 == fallbackWhole)
        }
        snapshot.close()
        assertStoreDebtIsZero(fixture.registry.sharedTileStore.snapshot())
    }

    @Test @MainActor
    func finiteRadialTileCornerUsesFourNeighborsAndMissingIsTransparent()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let configuration = RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 2,
            center: WorldPoint(x: 300.5, y: 300.5),
            referenceAngleRadians: 0
        )
        let canvasSize = PixelSize(width: 768, height: 768)
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(configuration),
            canvasSize: canvasSize
        )
        let layout = try #require(
            strategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: canvasSize,
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let fixture = try makeFixture(
            device: device,
            geometry: geometry,
            byteBudgetTiles: 3
        )
        let logicalColors: [RadialPageCoordinate: SIMD4<Float>] = [
            .init(x: 0, y: 0): SIMD4(0.5, 0, 0, 1),
            .init(x: 1, y: 0): SIMD4(0, 0.5, 0, 1),
            .init(x: 0, y: 1): SIMD4(0, 0, 0.5, 1),
            // (1, 1) is intentionally absent.
        ]
        var colors: [PaintTileCoordinate: SIMD4<Float>] = [:]
        for (logical, color) in logicalColors {
            let page = try #require(layout.residentPage(at: logical))
            let physical = PaintTileCoordinate(
                x: page.atlasSlot % layout.atlasColumns,
                y: page.atlasSlot / layout.atlasColumns
            )
            colors[physical] = color
            try seed(fixture, coordinate: physical, color: color)
        }
        #expect(layout.residentPage(at: .init(x: 1, y: 1)) != nil)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .radial(layout: layout),
            addressingRevision: 102
        )
        let output = try region(555, 555, 558, 558)
        let renderRequest = DocumentPaintStableSnapshotRenderRequest(
            snapshot: snapshot,
            outputRegion: output,
            outputGeometryRevision: 19,
            outputMapping: try .finiteRadial(strategy: strategy)
        )
        let expected = try expectedRadialBytes(
            output: output,
            configuration: configuration,
            canvasSize: canvasSize,
            layout: layout,
            colors: colors
        )
        let library = try makeLibrary(device)
        let fallback = try await renderTightBytes(
            request: renderRequest,
            chunk: 3,
            device: device,
            library: library,
            backendRequest: .forceFallback
        )
        expectEncodedBytesWithinOne(fallback, expected)
        let centerOffset = (1 * output.width + 1) * 4
        let center = Array(expected[centerOffset..<(centerOffset + 4)])
        #expect(center == [85, 85, 85, 191])
        if device.argumentBuffersSupport == .tier2 {
            let tier2 = try await renderTightBytes(
                request: renderRequest,
                chunk: 3,
                device: device,
                library: library,
                backendRequest: .forceTier2
            )
            #expect(tier2 == fallback)
        }
        snapshot.close()
        assertStoreDebtIsZero(fixture.registry.sharedTileStore.snapshot())
    }

    @Test @MainActor
    func finiteRadialFallbackSubdividesMoreThanSixteenBindingsAndDrainsDebt()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let configuration = RadialSymmetryConfiguration(
            kind: .mirror,
            rayCount: 1,
            center: WorldPoint(x: 420.5, y: 530.5),
            referenceAngleRadians: 0.31
        )
        let canvasSize = PixelSize(width: 1_024, height: 1_024)
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(configuration),
            canvasSize: canvasSize
        )
        let layout = try #require(
            strategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: canvasSize,
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let fixture = try makeFixture(
            device: device,
            geometry: geometry,
            byteBudgetTiles: layout.residentPages.count
        )
        var colors: [PaintTileCoordinate: SIMD4<Float>] = [:]
        for page in layout.residentPages {
            let physical = PaintTileCoordinate(
                x: page.atlasSlot % layout.atlasColumns,
                y: page.atlasSlot / layout.atlasColumns
            )
            let index = page.atlasSlot + 1
            let alpha: Float = 0.75
            let color = SIMD4<Float>(
                Float((index * 3) % 9 + 1) / 16,
                Float((index * 5) % 9 + 1) / 16,
                Float((index * 7) % 9 + 1) / 16,
                alpha
            )
            colors[physical] = color
            try seed(fixture, coordinate: physical, color: color)
        }
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .radial(layout: layout),
            addressingRevision: 103
        )
        let output = try region(100, 274, 868, 786)
        let mapping = try SparseTileSamplingOutputMapping.finiteRadial(
            strategy: strategy
        )
        let planCache = SparseTileSamplingPlanCache()
        let plan = try snapshot.acquireVisiblePlan(
            cache: planCache,
            outputRegion: output,
            outputGeometryRevision: 19,
            outputMapping: mapping
        )
        #expect(plan.content.outputMapping.kind == .finiteRadial)
        #expect(plan.content.bindingRecords.count > 16)
        #expect(plan.content.batches.count > 1)
        #expect(plan.content.batches.allSatisfy {
            $0.globalSlots.count <= SparseSamplingABI.maximumFallbackTextures
        })
        #expect(plan.content.batches.allSatisfy {
            $0.outputRegion != output
        })
        try plan.retire()
        #expect(planCache.evictContent(
            key: plan.content.key,
            outputRegion: output
        ))
        #expect(planCache.snapshot() == SparseTileSamplingPlanCacheSnapshot(
            cachedContentCount: 0,
            activeContentAcquisitionCount: 0,
            pendingRetirementCount: 0
        ))
        #expect(snapshot.activeChildSelectionCount == 0)

        let renderRequest = DocumentPaintStableSnapshotRenderRequest(
            snapshot: snapshot,
            outputRegion: output,
            outputGeometryRevision: 19,
            outputMapping: mapping
        )
        let expected = try expectedRadialBytes(
            output: output,
            configuration: configuration,
            canvasSize: canvasSize,
            layout: layout,
            colors: colors
        )
        let fallback = try await renderTightBytes(
            request: renderRequest,
            chunk: output.width,
            device: device,
            library: try makeLibrary(device),
            backendRequest: .forceFallback
        )
        expectEncodedBytesWithinOne(fallback, expected)
        snapshot.close()
        assertStoreDebtIsZero(fixture.registry.sharedTileStore.snapshot())
    }

    @Test @MainActor
    func finiteRadialAdaptiveBisectionRecomputesEachChildSelection()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let configuration = RadialSymmetryConfiguration(
            kind: .mirror,
            rayCount: 1,
            center: WorldPoint(x: 420.5, y: 530.5),
            referenceAngleRadians: 0.31
        )
        let canvasSize = PixelSize(width: 1_024, height: 1_024)
        let strategy = try TilingStrategy(
            finiteConfiguration: .radial(configuration),
            canvasSize: canvasSize
        )
        let layout = try #require(
            strategy.compiledSymmetry.domain.finite?.radial.layout
        )
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: canvasSize,
            storagePixelSize: layout.atlasPixelSize,
            radialLayout: layout
        )
        let fixture = try makeFixture(
            device: device,
            geometry: geometry,
            byteBudgetTiles: layout.residentPages.count
        )
        for page in layout.residentPages {
            try seed(
                fixture,
                coordinate: PaintTileCoordinate(
                    x: page.atlasSlot % layout.atlasColumns,
                    y: page.atlasSlot / layout.atlasColumns
                ),
                color: SIMD4(0.25, 0.125, 0.0625, 0.5)
            )
        }
        let binding = try fixture.registry.binding(for: fixture.layerID)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .radial(layout: layout),
            addressingRevision: 104
        )
        let output = try region(100, 274, 868, 786)
        let mapping = try SparseTileSamplingOutputMapping.finiteRadial(
            strategy: strategy
        )
        let probe = RendererRadialPinProbe()
        var hooks = DocumentPaintStableSnapshotRendererTestHooks()
        hooks.afterCPUEviction = {
            let coordinates = binding.canonical.backingSnapshot().entries
                .filter {
                    ($0.pinCounts[.visible] ?? 0) > 0
                        && ($0.pinCounts[.inFlight] ?? 0) > 0
                }
                .map(\.descriptor.coordinate)
            probe.record(Set(coordinates))
        }
        let renderer = try DocumentPaintStableSnapshotRenderer.testingMake(
            device: device,
            library: try makeLibrary(device),
            backendRequest: .forceFallback,
            limits: rendererLimits(
                chunk: 256,
                maximumOutputPixels: output.width * output.height
            ),
            planCache: SparseTileSamplingPlanCache(),
            hooks: hooks
        )
        let sink = RendererTestSink()
        try await renderer.render(
            DocumentPaintStableSnapshotRenderRequest(
                snapshot: snapshot,
                outputRegion: output,
                outputGeometryRevision: 19,
                outputMapping: mapping
            ),
            to: sink
        )
        let regions = await sink.record().chunks.map(\.outputRegion)
        let observed = probe.snapshots
        #expect(regions.count > 1)
        #expect(observed.count == regions.count)
        let root = expectedRadialPhysicalCoordinates(
            strategy: strategy,
            layout: layout,
            output: output
        )
        #expect(root.count > 16)
        for (region, selected) in zip(regions, observed) {
            #expect(selected == expectedRadialPhysicalCoordinates(
                strategy: strategy,
                layout: layout,
                output: region
            ))
            #expect(selected.count < root.count)
        }
        #expect(Set(observed).count > 1)
        #expect(observed.allSatisfy { $0 != root })
        #expect(binding.canonical.backingSnapshot().entries.allSatisfy {
            ($0.pinCounts[.visible] ?? 0) == 0
                && ($0.pinCounts[.inFlight] ?? 0) == 0
        })
        let rendererState = await renderer.snapshot()
        #expect(rendererState.metrics.targetAllocationCount > 0)
        #expect(rendererState.metrics.readbackAllocationCount > 0)
        #expect(rendererState.targetByteCount
            < canvasSize.width * canvasSize.height * 8)
        #expect(rendererState.readbackByteCount
            < canvasSize.width * canvasSize.height * 4)
        assertClean(rendererState)
        #expect(snapshot.activeChildSelectionCount == 0)
        snapshot.close()
        assertStoreDebtIsZero(fixture.registry.sharedTileStore.snapshot())
    }

    @Test @MainActor
    func sinkPhaseFailuresAndCancellationAbortExactlyOnceAndStayReusable()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeFixture(device: device)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 1
        )
        defer { snapshot.close() }
        let renderer = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: try makeLibrary(device),
            backendRequest: .forceFallback
        )
        let request = request(
            snapshot: snapshot,
            output: try region(0, 0, 1, 1)
        )
        for phase in [RendererSinkPhase.begin, .finish] {
            let sink = RendererTestSink(failurePhase: phase)
            await #expect(throws: RendererSinkError.injected(phase)) {
                try await renderer.render(request, to: sink)
            }
            let record = await sink.record()
            #expect(record.aborted == 1)
            #expect(record.finished == 0)
            #expect(record.chunks.count == (phase == .finish ? 1 : 0))
            let state = await renderer.snapshot()
            #expect(state.lifecycle == .active)
            assertClean(state)
        }

        for phase in RendererSinkPhase.allCases {
            let gate = RendererTestGate()
            let sink = RendererTestSink(gate: gate, gatePhase: phase)
            let task = Task { try await renderer.render(request, to: sink) }
            await gate.waitUntilReached()
            task.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            let record = await sink.record()
            #expect(record.aborted == 1)
            #expect(record.finished == 0)
            #expect(record.chunks.count
                == (phase == .begin ? 0 : 1))
            let state = await renderer.snapshot()
            #expect(state.lifecycle == .active)
            assertClean(state)
        }
        #expect(snapshot.activeChildSelectionCount == 0)
    }

    @Test @MainActor
    func evictedStableRootPagesInExactOldPixelsWithoutRetentionDebt()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: PixelSize(width: 512, height: 256),
            storagePixelSize: PixelSize(width: 512, height: 256),
            radialLayout: nil
        )
        let fixture = try makeFixture(
            device: device,
            geometry: geometry,
            byteBudgetTiles: 1
        )
        let oldColor = SIMD4<Float>(0.25, 0.125, 0, 1)
        try seed(fixture, coordinate: .init(x: 0, y: 0), color: oldColor)
        let oldBinding = try fixture.registry.binding(for: fixture.layerID)
        let old = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(geometry.storagePixelSize),
            addressingRevision: 61
        )
        try seed(
            fixture,
            coordinate: .init(x: 1, y: 0),
            color: SIMD4(0, 0.25, 0.125, 1)
        )
        let before = fixture.registry.sharedTileStore.snapshot()
        #expect(before.residentByteCount
            <= PaintTileDescriptor.residentByteCount)
        #expect(before.backingByteCount >= PaintTileDescriptor.residentByteCount)
        let exactOldEntry = try #require(
            oldBinding.canonical.backingSnapshot().entries.first {
                $0.descriptor.coordinate == PaintTileCoordinate(x: 0, y: 0)
            }
        )
        #expect(!exactOldEntry.isResident)
        guard case let .rgba16Float(oldBacking) = exactOldEntry.backing else {
            Issue.record("exact old tile did not have restorable RGBA16F backing")
            return
        }
        #expect(oldBacking.count == PaintTileDescriptor.residentByteCount)

        let bytes = try await renderTightBytes(
            request: request(
                snapshot: old,
                output: try region(0, 0, 1, 1)
            ),
            chunk: 1,
            device: device,
            library: try makeLibrary(device)
        )
        #expect(Array(bytes) == (try encodedPixel(oldColor)))
        old.close()
        let terminal = fixture.registry.sharedTileStore.snapshot()
        #expect(terminal.activeSnapshotTokenCount == 0)
        #expect(terminal.activeLeaseCount == 0)
        #expect(terminal.snapshotPayloadDebtByteCount == 0)
    }

    @Test @MainActor
    func sinkShutdownReentrancyFailsFastWithoutPoisoningOuterRender()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeFixture(device: device)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 71
        )
        defer { snapshot.close() }
        let renderer = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: try makeLibrary(device),
            backendRequest: .forceFallback,
            limits: rendererLimits(chunk: 1)
        )
        let request = request(
            snapshot: snapshot,
            output: try region(0, 0, 1, 1)
        )

        for phase in RendererReentrantSinkPhase.allCases {
            let sink = RendererReentrantShutdownSink(
                phase: phase,
                shutdown: {
                    do {
                        try await renderer.shutdown()
                        return nil
                    } catch {
                        return error as? DocumentPaintStableSnapshotRendererError
                    }
                }
            )
            if phase == .abort {
                await #expect(throws: RendererSinkError.injected(.begin)) {
                    try await renderer.render(request, to: sink)
                }
            } else {
                try await renderer.render(request, to: sink)
            }
            let record = await sink.record()
            #expect(record.reentrantErrors == [.reentrantSinkOperation])
            #expect(record.output.finished == (phase == .abort ? 0 : 1))
            #expect(record.output.aborted == (phase == .abort ? 1 : 0))
            let state = await renderer.snapshot()
            #expect(state.lifecycle == .active)
            #expect(!state.shutdownRequested)
            assertClean(state)
            #expect(snapshot.activeChildSelectionCount == 0)
        }

        let unrelated = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: try makeLibrary(device),
            backendRequest: .forceFallback,
            limits: rendererLimits(chunk: 1)
        )
        let crossRendererSink = RendererCrossShutdownSink {
            try await unrelated.shutdown()
        }
        try await renderer.render(request, to: crossRendererSink)
        #expect((await unrelated.snapshot()).lifecycle == .shutDown)
        let afterCrossRendererShutdown = await renderer.snapshot()
        #expect(afterCrossRendererShutdown.lifecycle == .active)
        #expect(!afterCrossRendererShutdown.shutdownRequested)
        assertClean(afterCrossRendererShutdown)

        let nested = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: try makeLibrary(device),
            backendRequest: .forceFallback,
            limits: rendererLimits(chunk: 1)
        )
        let nestedInnerSink = RendererReentrantShutdownSink(
            phase: .finish,
            shutdown: {
                do {
                    try await renderer.shutdown()
                    return nil
                } catch {
                    return error as? DocumentPaintStableSnapshotRendererError
                }
            }
        )
        let nestedOuterSink = RendererCrossShutdownSink {
            try await nested.render(request, to: nestedInnerSink)
        }
        try await renderer.render(request, to: nestedOuterSink)
        #expect(await nestedInnerSink.record().reentrantErrors
            == [.reentrantSinkOperation])
        let afterNestedCycle = await renderer.snapshot()
        #expect(afterNestedCycle.lifecycle == .active)
        #expect(!afterNestedCycle.shutdownRequested)
        assertClean(afterNestedCycle)
        let nestedState = await nested.snapshot()
        #expect(nestedState.lifecycle == .active)
        #expect(!nestedState.shutdownRequested)
        assertClean(nestedState)

        let recovery = RendererTestSink()
        try await renderer.render(request, to: recovery)
        #expect(await recovery.record().finished == 1)
        assertClean(await renderer.snapshot())
    }

    @Test @MainActor
    func inheritedSinkTaskMayShutdownAfterCallbackScopeEnds() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try makeFixture(device: device)
        let snapshot = try fixture.registry.captureStableCanonicalSnapshot(
            layerID: fixture.layerID,
            addressing: .finite(fixture.geometry.storagePixelSize),
            addressingRevision: 72
        )
        defer { snapshot.close() }
        let renderer = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: try makeLibrary(device),
            backendRequest: .forceFallback,
            limits: rendererLimits(chunk: 1)
        )
        let gate = RendererTestGate()
        let sink = RendererInheritedShutdownSink(gate: gate) {
            try await renderer.shutdown()
        }
        try await renderer.render(
            request(
                snapshot: snapshot,
                output: try region(0, 0, 1, 1)
            ),
            to: sink
        )
        await gate.waitUntilReached()
        await gate.open()
        #expect(await sink.shutdownError() == nil)
        let terminal = await renderer.snapshot()
        #expect(terminal.lifecycle == .shutDown)
        #expect(terminal.shutdownRequested)
        assertClean(terminal)
        #expect(snapshot.activeChildSelectionCount == 0)
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

    private func rendererLimits(
        chunk: Int,
        maximumOutputPixels: Int = 4_096
    )
        throws -> DocumentPaintStableSnapshotRendererLimits
    {
        try DocumentPaintStableSnapshotRendererLimits(
            maximumChunkWidth: chunk,
            maximumChunkHeight: chunk,
            maximumScratchBytes: 8 * 1_024 * 1_024,
            maximumOutputPixels: maximumOutputPixels,
            maximumOutputBytes: maximumOutputPixels * 4,
            maximumRetryCleanupPasses: 4
        )
    }

    private func request(
        snapshot: DocumentPaintStableCanonicalSnapshot,
        output: SparseTileOutputRegion,
        transform: SparseTileOutputToSourceTransform = .identity
    ) -> DocumentPaintStableSnapshotRenderRequest {
        DocumentPaintStableSnapshotRenderRequest(
            snapshot: snapshot,
            outputRegion: output,
            outputGeometryRevision: 19,
            outputToSourceTransform: transform
        )
    }

    private func makeFixture(
        device: any MTLDevice,
        geometry suppliedGeometry: DocumentPaintGeometry? = nil,
        byteBudgetTiles: Int = 8
    ) throws
        -> RendererRegistryFixture
    {
        let layerID = UUID()
        let geometry = try suppliedGeometry ?? DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 256, height: 256),
                storagePixelSize: PixelSize(width: 256, height: 256),
                radialLayout: nil
            )
        return RendererRegistryFixture(
            device: device,
            layerID: layerID,
            geometry: geometry,
            registry: try DocumentPaintSurfaceStore(
                device: device,
                byteBudget:
                    PaintTileDescriptor.residentByteCount * byteBudgetTiles,
                transferByteCapacity:
                    PaintTileDescriptor.residentByteCount
                        * max(8, byteBudgetTiles + 2),
                geometry: geometry,
                layerIDs: [layerID]
            )
        )
    }

    private func seed(
        _ fixture: RendererRegistryFixture,
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

    private func seed(
        _ fixture: RendererRegistryFixture,
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
        let buffer = try pixels.withUnsafeBytes { bytes in
            try #require(fixture.device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ))
        }
        let queue = try #require(fixture.device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(
            from: buffer,
            sourceOffset: 0,
            sourceBytesPerRow: PaintTileDescriptor.side * 8,
            sourceBytesPerImage: PaintTileDescriptor.residentByteCount,
            sourceSize: MTLSize(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side,
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
        try fixture.registry.sharedTileStore.markModified(
            lease,
            surfaceID: lease.surfaceID,
            currentGeneration: lease.generation,
            coordinates: [coordinate]
        )
    }

    @MainActor
    private func renderTightBytes(
        request: DocumentPaintStableSnapshotRenderRequest,
        chunk: Int,
        device: any MTLDevice,
        library: any MTLLibrary,
        backendRequest: SparseTileSamplingBackendRequest = .forceFallback
    ) async throws -> Data {
        let renderer = try DocumentPaintStableSnapshotRenderer.make(
            device: device,
            library: library,
            backendRequest: backendRequest,
            limits: rendererLimits(
                chunk: chunk,
                maximumOutputPixels: max(
                    4_096,
                    request.outputRegion.width * request.outputRegion.height
                )
            )
        )
        let sink = RendererTestSink()
        try await renderer.render(request, to: sink)
        let record = await sink.record()
        #expect(record.finished == 1)
        #expect(record.aborted == 0)
        assertClean(await renderer.snapshot())
        let width = request.outputRegion.width
        let height = request.outputRegion.height
        var result = Data(count: width * request.outputRegion.height * 4)
        var coverage = Array(repeating: 0, count: width * height)
        var validChunks: [DocumentPaintStableSnapshotChunk] = []
        let ordered = record.chunks.map(\.outputRegion)
        #expect(ordered
            == DocumentPaintStableSnapshotChunkPlanner
                .orderedForEmission(ordered))
        for chunk in record.chunks {
            let region = chunk.outputRegion
            #expect(region.minX >= request.outputRegion.minX)
            #expect(region.minY >= request.outputRegion.minY)
            #expect(region.maxX <= request.outputRegion.maxX)
            #expect(region.maxY <= request.outputRegion.maxY)
            #expect(chunk.bytesPerRow == region.width * 4)
            #expect(chunk.bytes.count
                == chunk.bytesPerRow * region.height)
            guard region.minX >= request.outputRegion.minX,
                  region.minY >= request.outputRegion.minY,
                  region.maxX <= request.outputRegion.maxX,
                  region.maxY <= request.outputRegion.maxY,
                  chunk.bytesPerRow == region.width * 4,
                  chunk.bytes.count == chunk.bytesPerRow * region.height
            else { continue }
            validChunks.append(chunk)
            for y in region.minY..<region.maxY {
                for x in region.minX..<region.maxX {
                    coverage[(y - request.outputRegion.minY) * width
                        + x - request.outputRegion.minX] += 1
                }
            }
        }
        #expect(coverage.allSatisfy { $0 == 1 })
        result.withUnsafeMutableBytes { destination in
            for chunk in validChunks {
                chunk.bytes.withUnsafeBytes { source in
                    for row in 0..<chunk.outputRegion.height {
                        let destinationX = chunk.outputRegion.minX
                            - request.outputRegion.minX
                        let destinationY = chunk.outputRegion.minY
                            - request.outputRegion.minY + row
                        memcpy(
                            destination.baseAddress!.advanced(
                                by: (destinationY * width + destinationX) * 4
                            ),
                            source.baseAddress!.advanced(
                                by: row * chunk.bytesPerRow
                            ),
                            chunk.bytesPerRow
                        )
                    }
                }
            }
        }
        return result
    }

    private func expectedRadialPixel(
        world: WorldPoint,
        configuration: RadialSymmetryConfiguration,
        canvasSize: PixelSize,
        layout: RadialSectorLayout,
        colors: [PaintTileCoordinate: SIMD4<Float>]
    ) throws -> [UInt8] {
        guard let folded = RadialCoverageOracle.fold(
            world,
            configuration: .radial(configuration),
            canvasSize: canvasSize
        ) else { return [0, 0, 0, 0] }
        let sample = SIMD2(folded.x, folded.y)
            - SIMD2<Float>(repeating: 0.5)
        let lower = SIMD2<Int>(
            Int(floor(sample.x)),
            Int(floor(sample.y))
        )
        let fraction = SIMD2(sample.x - floor(sample.x),
                             sample.y - floor(sample.y))
        func value(_ x: Int, _ y: Int) -> SIMD4<Float> {
            guard let page = layout.residentPage(at: RadialPageCoordinate(
                x: Int(floor(Double(x) / 256)),
                y: Int(floor(Double(y) / 256))
            )) else { return .zero }
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
        let value00 = value(lower.x, lower.y)
        let value10 = value(lower.x + 1, lower.y)
        let value01 = value(lower.x, lower.y + 1)
        let value11 = value(lower.x + 1, lower.y + 1)
        let top = value00 + (value10 - value00) * fraction.x
        let bottom = value01 + (value11 - value01) * fraction.x
        let linearValue = top + (bottom - top) * fraction.y
        guard let linear = LinearPremultipliedColor(
            red: linearValue.x,
            green: linearValue.y,
            blue: linearValue.z,
            alpha: linearValue.w
        ) else { return [0, 0, 0, 0] }
        let encoded = DocumentColorPipeline
            .exportEncodedPremultipliedBGRA8(linear)
        return [encoded.blue, encoded.green, encoded.red, encoded.alpha]
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
                result.append(contentsOf: try expectedRadialPixel(
                    world: WorldPoint(
                        x: Float(x) + 0.5,
                        y: Float(y) + 0.5
                    ),
                    configuration: configuration,
                    canvasSize: canvasSize,
                    layout: layout,
                    colors: colors
                ))
            }
        }
        return result
    }

    private func expectedRadialPhysicalCoordinates(
        strategy: TilingStrategy,
        layout: RadialSectorLayout,
        output: SparseTileOutputRegion
    ) -> Set<PaintTileCoordinate> {
        let bounds = AxisAlignedRect(
            minimum: SIMD2(Float(output.minX), Float(output.minY)),
            maximum: SIMD2(Float(output.maxX), Float(output.maxY))
        )
        var logical: Set<RadialPageCoordinate> = []
        for image in strategy.images(intersecting: bounds) {
            for dy in -1...1 {
                for dx in -1...1 {
                    let coordinate = RadialPageCoordinate(
                        x: image.cell.column + dx,
                        y: image.cell.row + dy
                    )
                    if layout.residentPage(at: coordinate) != nil {
                        logical.insert(coordinate)
                    }
                }
            }
        }
        return Set(logical.compactMap { layout.residentPage(at: $0) }.map {
            PaintTileCoordinate(
                x: $0.atlasSlot % layout.atlasColumns,
                y: $0.atlasSlot / layout.atlasColumns
            )
        })
    }

    private func maximumEncodedByteDelta(
        _ actual: Data,
        _ expected: Data
    ) -> Int {
        guard actual.count == expected.count else { return .max }
        return zip(actual, expected).reduce(0) { maximum, pair in
            max(maximum, abs(Int(pair.0) - Int(pair.1)))
        }
    }

    private func expectEncodedBytesWithinOne(
        _ actual: Data,
        _ expected: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        #expect(maximumEncodedByteDelta(actual, expected) <= 1,
                sourceLocation: sourceLocation)
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
        let value = DocumentColorPipeline
            .exportEncodedPremultipliedBGRA8(linear)
        return [value.blue, value.green, value.red, value.alpha]
    }

    private func assertClean(
        _ state: DocumentPaintStableSnapshotRendererSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(state.inflightCommandCount == 0, sourceLocation: sourceLocation)
        #expect(state.cpuCache.cachedContentCount == 0,
                sourceLocation: sourceLocation)
        #expect(state.cpuCache.activeContentAcquisitionCount == 0,
                sourceLocation: sourceLocation)
        #expect(state.cpuCache.pendingRetirementCount == 0,
                sourceLocation: sourceLocation)
        #expect(state.gpuCache.preparedContentCount == 0,
                sourceLocation: sourceLocation)
        #expect(state.gpuCache.cachedPlanMetalBufferBytes == 0,
                sourceLocation: sourceLocation)
        #expect((state.gpuCache.uploadRing?.activeSlotCount ?? 0) == 0,
                sourceLocation: sourceLocation)
        #expect(state.completion.pendingPlanCompletionCount == 0,
                sourceLocation: sourceLocation)
        #expect(state.completion.pendingConsumerCompletionCount == 0,
                sourceLocation: sourceLocation)
    }

    private func assertStoreDebtIsZero(
        _ snapshot: PaintTileStoreSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(snapshot.activeSnapshotTokenCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.aggregateSnapshotReferenceCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.activeLeaseCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.preparedRetirementCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.pendingRetirementCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.snapshotMetadataByteCount == 0,
                sourceLocation: sourceLocation)
        #expect(snapshot.snapshotPayloadDebtByteCount == 0,
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

private struct RendererRegistryFixture {
    let device: any MTLDevice
    let layerID: UUID
    let geometry: DocumentPaintGeometry
    let registry: DocumentPaintSurfaceStore
}

private final class RendererRadialPinProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Set<PaintTileCoordinate>] = []

    func record(_ value: Set<PaintTileCoordinate>) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshots: [Set<PaintTileCoordinate>] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct RendererSinkRecord: Equatable, Sendable {
    var began = 0
    var chunks: [DocumentPaintStableSnapshotChunk] = []
    var finished = 0
    var aborted = 0
}

private actor RendererTestSink: DocumentPaintStableSnapshotSink {
    private var value = RendererSinkRecord()
    private let consumeCapacityFailure: Bool
    private let failurePhase: RendererSinkPhase?
    private let gate: RendererTestGate?
    private let gatePhase: RendererSinkPhase?

    init(
        consumeCapacityFailure: Bool = false,
        beginGate: RendererTestGate? = nil,
        failurePhase: RendererSinkPhase? = nil,
        gate: RendererTestGate? = nil,
        gatePhase: RendererSinkPhase? = nil
    ) {
        self.consumeCapacityFailure = consumeCapacityFailure
        self.failurePhase = failurePhase
        self.gate = gate ?? beginGate
        self.gatePhase = gatePhase ?? (beginGate == nil ? nil : .begin)
    }

    func begin(_ descriptor: DocumentPaintStableSnapshotSinkDescriptor)
        async throws
    {
        value.began += 1
        try await suspendOrFail(.begin)
    }

    func consume(_ chunk: DocumentPaintStableSnapshotChunk) async throws {
        value.chunks.append(chunk)
        try await suspendOrFail(.consume)
        if consumeCapacityFailure {
            throw SparseTileSamplingPipelineError.limitExceeded(
                required: 2,
                maximum: 1
            )
        }
    }

    func finish() async throws {
        try await suspendOrFail(.finish)
        value.finished += 1
    }
    func abort() async { value.aborted += 1 }
    func record() -> RendererSinkRecord { value }

    private func suspendOrFail(_ phase: RendererSinkPhase) async throws {
        if gatePhase == phase {
            await gate?.pause()
            try Task.checkCancellation()
        }
        if failurePhase == phase { throw RendererSinkError.injected(phase) }
    }
}

private enum RendererSinkPhase: CaseIterable, Equatable, Sendable {
    case begin
    case consume
    case finish
}

private enum RendererSinkError: Error, Equatable, Sendable {
    case injected(RendererSinkPhase)
}

private enum RendererReentrantSinkPhase: CaseIterable, Equatable, Sendable {
    case begin
    case consume
    case finish
    case abort
}

private struct RendererReentrantSinkRecord: Equatable, Sendable {
    var output = RendererSinkRecord()
    var reentrantErrors: [DocumentPaintStableSnapshotRendererError] = []
}

private actor RendererReentrantShutdownSink:
    DocumentPaintStableSnapshotSink
{
    private var value = RendererReentrantSinkRecord()
    private let phase: RendererReentrantSinkPhase
    private let shutdown:
        @Sendable () async -> DocumentPaintStableSnapshotRendererError?

    init(
        phase: RendererReentrantSinkPhase,
        shutdown: @escaping @Sendable () async
            -> DocumentPaintStableSnapshotRendererError?
    ) {
        self.phase = phase
        self.shutdown = shutdown
    }

    func begin(_ descriptor: DocumentPaintStableSnapshotSinkDescriptor)
        async throws
    {
        value.output.began += 1
        await attemptShutdown(if: .begin)
        if phase == .abort { throw RendererSinkError.injected(.begin) }
    }

    func consume(_ chunk: DocumentPaintStableSnapshotChunk) async throws {
        value.output.chunks.append(chunk)
        await attemptShutdown(if: .consume)
    }

    func finish() async throws {
        await attemptShutdown(if: .finish)
        value.output.finished += 1
    }

    func abort() async {
        await attemptShutdown(if: .abort)
        value.output.aborted += 1
    }

    func record() -> RendererReentrantSinkRecord { value }

    private func attemptShutdown(if candidate: RendererReentrantSinkPhase)
        async
    {
        guard phase == candidate else { return }
        if let error = await shutdown() {
            value.reentrantErrors.append(error)
        } else {
            Issue.record("reentrant shutdown unexpectedly succeeded")
        }
    }
}

private actor RendererCrossShutdownSink: DocumentPaintStableSnapshotSink {
    private let shutdown: @Sendable () async throws -> Void

    init(shutdown: @escaping @Sendable () async throws -> Void) {
        self.shutdown = shutdown
    }

    func begin(_ descriptor: DocumentPaintStableSnapshotSinkDescriptor)
        async throws
    {}
    func consume(_ chunk: DocumentPaintStableSnapshotChunk) async throws {}
    func finish() async throws { try await shutdown() }
    func abort() async {}
}

private actor RendererInheritedShutdownSink:
    DocumentPaintStableSnapshotSink
{
    private let gate: RendererTestGate
    private let shutdown: @Sendable () async throws -> Void
    private var shutdownTask: Task<(any Error)?, Never>?

    init(
        gate: RendererTestGate,
        shutdown: @escaping @Sendable () async throws -> Void
    ) {
        self.gate = gate
        self.shutdown = shutdown
    }

    func begin(_ descriptor: DocumentPaintStableSnapshotSinkDescriptor)
        async throws
    {}
    func consume(_ chunk: DocumentPaintStableSnapshotChunk) async throws {}
    func finish() async throws {
        let gate = gate
        let shutdown = shutdown
        shutdownTask = Task {
            await gate.pause()
            do {
                try await shutdown()
                return nil
            } catch {
                return error
            }
        }
    }
    func abort() async {}

    func shutdownError() async -> (any Error)? {
        await shutdownTask?.value
    }
}

private actor RendererTestGate {
    private var reached = false
    private var opened = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func open() {
        opened = true
        let waiters = openWaiters
        openWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

private enum RendererLeaseReturnProbeError: Error { case injected }

private final class RendererPhaseFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: Set<DocumentPaintStableSnapshotRendererTestPhase>

    init(_ phases: Set<DocumentPaintStableSnapshotRendererTestPhase>) {
        self.phases = phases
    }

    lazy var shouldFail:
        @Sendable (DocumentPaintStableSnapshotRendererTestPhase) -> Bool = {
            [weak self] phase in
            guard let self else { return false }
            lock.lock()
            defer { lock.unlock() }
            return phases.remove(phase) != nil
        }
}

private final class RendererLeaseReturnProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int

    init(failures: Int) { remainingFailures = failures }

    func allowReturns() {
        lock.lock()
        remainingFailures = 0
        lock.unlock()
    }

    lazy var call: SparseTileLeaseReturner = { [weak self] lease in
        guard let self else { throw RendererLeaseReturnProbeError.injected }
        lock.lock()
        let shouldFail = remainingFailures > 0
        if shouldFail { remainingFailures -= 1 }
        lock.unlock()
        guard !shouldFail else {
            throw RendererLeaseReturnProbeError.injected
        }
        try lease.returnLease()
    }
}
