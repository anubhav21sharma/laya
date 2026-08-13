import Foundation
import EditorCore
@preconcurrency import Metal
import MetalKit
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Grid renderer sparse cutover", .serialized)
struct GridRendererSparseCutoverTests {
    @Test
    @MainActor
    func productionConstructionPreservesDocumentTransientAndCanonicalCaps()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try makeSparseCutoverRenderer(
            device: device,
            library: try makeSparseCutoverLibrary(device: device)
        )
        let envelope = renderer.presentationMemoryEnvelopeForTesting()
        #expect(envelope.documentStoreBytes == 512 * 1_024 * 1_024)
        #expect(envelope.transientCacheBytes == 512 * 1_024 * 1_024)
        #expect(envelope.canonicalResidentBytes == 128 * 1_024 * 1_024)
        #expect(envelope.canonicalCopyOnWriteHeadroomBytes
            >= 137 * 1_024 * 1_024)
        #expect(try envelope.checkedPartitionByteCount()
            == envelope.maximumPhysicalBytes)
        let cache = try #require(
            await renderer.canvasCompositeCacheSnapshotForTesting()
        )
        #expect(cache.maximumPhysicalBytes == envelope.canonicalCacheBytes)
    }

    @Test
    @MainActor
    func durableLifecycleRetriesACKWithoutRendererPump()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let library = try makeSparseCutoverLibrary(device: device)
        let renderer = try makeSparseCutoverRenderer(
            device: device,
            library: library
        )
        let layerID = UUID()
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: library,
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
            "production lifecycle ACK retry"
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
        let gate = SparseCutoverInteractiveCacheGate(
            blocksLifecycleRetry: true
        )
        defer { Task { await gate.releaseAll() } }
        await renderer.installInteractiveStrokeCacheCompletionGateForTesting(
            gate
        )
        await gate.open()
        let operation = renderer.startInteractiveStrokeCacheUpdateForTesting(
            update,
            parameters: .init(blendMode: .normal, opacity: 1)
        )
        try #require(
            await gate.waitUntilLifecycleRetryScheduled(count: 1)
        )
        #expect(update.acknowledgement.testingRequestCount == 1)
        await gate.releaseOneLifecycleRetry()
        try #require(
            await gate.waitUntilLifecycleRetryScheduled(count: 2)
        )
        #expect(update.acknowledgement.testingRequestCount == 2)
        await gate.releaseOneLifecycleRetry()
        await operation.value
        #expect(update.acknowledgement.testingRequestCount == 3)
        #expect(update.acknowledgement.status == .fulfilled)
        let diagnostic = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(diagnostic.submittedUpdateCount == 1)
        #expect(diagnostic.completedUpdateCount == 1)
        #expect(diagnostic.acknowledgementSettlementCount == 1)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
    }

    @Test
    @MainActor
    func rendererDeinitCannotDropLiveFailedACKOwnership() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let library = try makeSparseCutoverLibrary(device: device)
        var renderer: GridRenderer? = try makeSparseCutoverRenderer(
            device: device,
            library: library
        )
        let weakRenderer = WeakSparseCutoverRenderer(renderer)
        var cache: InteractiveStrokePresentationCache? = renderer?
            .interactiveStrokePresentationCacheForTesting()
        let weakCache = WeakSparseCutoverCache(cache)
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: library,
            geometry: try DocumentPaintGeometry(
                documentPixelSize: PixelSize(width: 256, height: 256),
                storagePixelSize: PixelSize(width: 256, height: 256),
                radialLayout: nil
            ),
            initialLayerStack: try .single(id: UUID()),
            byteBudget: PaintTileDescriptor.residentByteCount * 8,
            transferByteCapacity: PaintTileDescriptor.residentByteCount * 16,
            maximumRevisionBytes: PaintTileDescriptor.residentByteCount * 8
        )
        let capability = try context.beginStrokeSurface()
        let failure = StrokePreparationFailure.unexpected(
            "renderer deinit ACK failure"
        )
        let update = try context.makeTransientCacheUpdate(
            frame: .testing(
                capability: capability,
                acknowledgementIsAvailable: true,
                acknowledgementReleaseFailures:
                    [failure, failure, failure, failure]
            ),
            sequence: 1
        )
        let gate = SparseCutoverInteractiveCacheGate(
            blocksLifecycleRetry: true
        )
        defer { Task { await gate.releaseAll() } }
        await renderer?.installInteractiveStrokeCacheCompletionGateForTesting(
            gate
        )
        await gate.open()
        let operation = renderer?.startInteractiveStrokeCacheUpdateForTesting(
            update,
            parameters: .init(blendMode: .normal, opacity: 1)
        )
        try #require(
            await gate.waitUntilLifecycleRetryScheduled(count: 1)
        )
        #expect(update.acknowledgement.testingRequestCount == 1)
        cache = nil
        renderer = nil

        #expect(weakRenderer.value == nil)
        #expect(weakCache.value != nil)
        for retryCount in 2...4 {
            await gate.releaseOneLifecycleRetry()
            try #require(
                await gate.waitUntilLifecycleRetryScheduled(
                    count: retryCount
                )
            )
        }
        await gate.releaseOneLifecycleRetry()
        await operation?.value
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(update.presentationEpoch.identity)

        #expect(update.acknowledgement.testingRequestCount == 5)
        #expect(update.acknowledgement.status == .fulfilled)
        #expect(weakCache.value == nil)
    }

    @Test
    @MainActor
    func rendererDeinitUpgradesSuccessfulLiveACKToDurableRetirement()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return }
        let library = try makeSparseCutoverLibrary(device: device)
        var renderer: GridRenderer? = try makeSparseCutoverRenderer(
            device: device,
            library: library
        )
        let weakRenderer = WeakSparseCutoverRenderer(renderer)
        var cache: InteractiveStrokePresentationCache? = renderer?
            .interactiveStrokePresentationCacheForTesting()
        let weakCache = WeakSparseCutoverCache(cache)
        let layerID = UUID()
        let context = try DocumentPaintRenderContext(
            device: device,
            commandQueue: queue,
            library: library,
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
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let sourceLease = try capability.reserveStrokeTiles(
            role: .authoritative,
            coordinates: [coordinate],
            pinReasons: [.inFlight],
            workspace: .init(maximumBindingCount: 1),
            failureInjection: nil
        )
        try capability.testingMarkDirty(sourceLease)
        try capability.releaseFrameReservations(
            authoritative: sourceLease,
            prediction: nil
        )
        let update = try context.makeTransientCacheUpdate(
            frame: .testing(
                capability: capability,
                changedCoordinates: [coordinate],
                acknowledgementIsAvailable: true
            ),
            sequence: 1
        )
        let terminal = SparseCutoverCacheTerminalProbe()
        await renderer?.installFailedInteractiveStrokeCacheUpdateForTesting(
            update,
            parameters: .init(blendMode: .normal, opacity: 1),
            lifecycleTerminal: { terminal.record($0) }
        )
        #expect(update.acknowledgement.status == .fulfilled)
        let published = await cache?.snapshot()
        #expect(published?.activeStrokeEpochCount == 1)
        #expect((published?.totalPhysicalResidentBytes ?? 0) > 0)
        let provider = try #require(
            try await cache?.current(generation: capability.generation)?
                .authoritative
        )
        let capture = try TiledRasterExactReferenceCapture(
            providers: [provider]
        )
        #expect(InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(update.presentationEpoch.identity))
        cache = nil
        renderer = nil
        #expect(weakRenderer.value == nil)
        #expect(weakCache.value != nil)

        capture.close()
        let final = await terminal.waitUntilRecorded()
        #expect(final.activeStrokeEpochCount == 0)
        #expect(final.activeUpdateOwnerCount == 0)
        #expect(final.pendingPreparedAcknowledgementCount == 0)
        #expect(final.totalPhysicalResidentBytes == 0)
        #expect(final.isIdle)
    }

    @Test
    @MainActor
    func liveStrokePumpDoesNotPreventPostACKRendererDeinitRetirement()
        async throws
    {
        var renderer: GridRenderer?
        let brush: CompiledBrush
        do {
            guard let setup = try makeDepositionRendererSetup() else { return }
            renderer = setup.renderer
            brush = try await setup.compileBrush(
                id: "brush.cache-live-owner-deinit"
            )
        }
        try renderer?.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_D3_11)
        try renderer?.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer?.drainPreparedStrokeInputForHarness(
            outputPixelSize: try #require(renderer?.pixelSize)
        )
        var cache = renderer?.interactiveStrokePresentationCacheForTesting()
        let published = try #require(await cache?.snapshot())
        #expect(published.completedUpdateCount >= 1)
        #expect(published.pendingPreparedAcknowledgementCount == 0)
        #expect(published.activeStrokeEpochCount == 1)
        #expect(published.totalPhysicalResidentBytes > 0)
        let revision = try #require(published.publishedRevision)
        let provider = try #require(
            try await cache?.current(generation: revision.generation)?
                .authoritative
        )
        let capture = try TiledRasterExactReferenceCapture(
            providers: [provider]
        )
        #expect(InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(revision.strokeEpoch))
        let weakRenderer = WeakSparseCutoverRenderer(renderer)
        let weakCache = WeakSparseCutoverCache(cache)
        cache = nil
        renderer = nil

        #expect(weakRenderer.value == nil)
        #expect(weakCache.value != nil)
        capture.close()
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(revision.strokeEpoch)
        #expect(!InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(revision.strokeEpoch))
        #expect(weakCache.value == nil)
    }

    @Test
    @MainActor
    func suspendedDisplayPreparationDoesNotPreventLiveCacheTeardown()
        async throws
    {
        var renderer: GridRenderer?
        let brush: CompiledBrush
        let device: any MTLDevice
        do {
            guard let setup = try makeDepositionRendererSetup() else { return }
            renderer = setup.renderer
            brush = try await setup.compileBrush(
                id: "brush.cache-display-preparation-deinit"
            )
            device = setup.device
        }
        try renderer?.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_D3_12)
        try renderer?.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer?.drainPreparedStrokeInputForHarness(
            outputPixelSize: try #require(renderer?.pixelSize)
        )
        var cache = renderer?.interactiveStrokePresentationCacheForTesting()
        let published = try #require(await cache?.snapshot())
        let revision = try #require(published.publishedRevision)
        #expect(published.activeStrokeEpochCount == 1)
        #expect(published.pendingPreparedAcknowledgementCount == 0)
        #expect(InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(revision.strokeEpoch))

        let preparationRevision = CanvasPresentationRevision(
            sequence: max(
                renderer!.paintDisplayPreparationRevisionForTesting,
                1
            )
        )
        let gate = PresentationPreparationGate(
            blockedRevision: preparationRevision
        )
        renderer?.installPresentationPreparationGateForTesting(gate)
        let view = sparseCutoverView(device: device)
        renderer?.draw(in: view)
        await gate.waitUntilStarted(preparationRevision)

        let weakRenderer = WeakSparseCutoverRenderer(renderer)
        renderer = nil
        #expect(weakRenderer.value == nil)
        await gate.releaseBlockedRevision()
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(revision.strokeEpoch)

        let terminal = try #require(await cache?.snapshot())
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.pendingPreparedAcknowledgementCount == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.isIdle)
        cache = nil
    }

    @Test
    @MainActor
    func cacheRetirementFailureAutomaticallyRetriesBeforeIdle()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try GridRenderer(
            device: device,
            library: try makeSparseCutoverLibrary(device: device),
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: try TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 64, height: 64),
                tiling: .grid
            )
        )
        try renderer.installNativeHarnessBrushes()
        renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
        await renderer.installInteractiveStrokeCacheFailureInjectionForTesting(
            .init(retirementFailureCount: 1)
        )
        var errors: [MetalRendererError] = []
        renderer.onError = { errors.append($0) }
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_01)
        let style = try renderer.nativeHarnessStrokeStyle(
            diameter: 12,
            seed: token.rawValue
        )
        let sample = StrokeSample(
            position: ScreenPoint(x: 16, y: 16),
            pressure: 0.75,
            timestamp: 0,
            phase: .began,
            source: .mouse,
            capabilities: [.pressure]
        )

        try renderer.beginStroke(token: token, sample: sample, style: style)
        try renderer.cancelStroke(token: token)
        await renderer.awaitInteractiveStrokeCacheRetirementForHarness()
        try renderer.drainStrokeWorkspaceRetirementForHarness()

        #expect(renderer.isIdle)
        #expect(errors.count == 1)
        #expect(renderer.lastError == errors.first)
        let diagnostic = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(diagnostic.retirementFailureCount == 1)
        #expect(diagnostic.retirementState == .idle)
        #expect(diagnostic.retirementErrorDescription == nil)
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.retirementWaiterCount == 0)
        #expect(diagnostic.provisionalBytes == 0)
    }

    @Test
    @MainActor
    func cacheRetirementRetriesPastTwoFailuresUntilTerminalSettlement()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try GridRenderer(
            device: device,
            library: try makeSparseCutoverLibrary(device: device),
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: try TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 64, height: 64),
                tiling: .grid
            )
        )
        try renderer.installNativeHarnessBrushes()
        renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
        await renderer.installInteractiveStrokeCacheFailureInjectionForTesting(
            .init(retirementFailureCount: 3)
        )
        var errors: [MetalRendererError] = []
        renderer.onError = { errors.append($0) }
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_02)
        let style = try renderer.nativeHarnessStrokeStyle(
            diameter: 12,
            seed: token.rawValue
        )
        let sample = StrokeSample(
            position: ScreenPoint(x: 16, y: 16),
            pressure: 0.75,
            timestamp: 0,
            phase: .began,
            source: .mouse,
            capabilities: [.pressure]
        )

        try renderer.beginStroke(token: token, sample: sample, style: style)
        try renderer.cancelStroke(token: token)
        await renderer.awaitInteractiveStrokeCacheRetirementForHarness()
        try renderer.drainStrokeWorkspaceRetirementForHarness()

        #expect(renderer.isIdle)
        #expect(errors.count == 1)
        let diagnostic = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(diagnostic.retirementFailureCount == 3)
        #expect(diagnostic.retirementState == .idle)
        #expect(diagnostic.activeStrokeEpochCount == 0)
        #expect(diagnostic.activeUpdateOwnerCount == 0)
        #expect(diagnostic.retirementWaiterCount == 0)
        #expect(diagnostic.provisionalBytes == 0)
        #expect(diagnostic.pendingPreparedAcknowledgementCount == 0)
        #expect(diagnostic.residentBytes == 0)
        #expect(diagnostic.totalPhysicalResidentBytes == 0)
        #expect(diagnostic.componentCoverageBytes == 0)
        #expect(diagnostic.backingBytes == 0)
    }

    @Test
    @MainActor
    func committedStrokeRetiresCacheBeforeNextStrokeAdoption() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        let brush = try await setup.compileBrush(
            id: "brush.cache-commit-retirement"
        )
        try renderer.activateDrawBrush(brush)
        let commitGate = SparseCutoverPaintCommitGate()
        renderer.installPaintStrokeCommitGateForTesting(commitGate)

        for (index, rawToken) in [
            UInt64(0xCA_C4_E0_11), 0xCA_C4_E0_12,
        ].enumerated() {
            let token = RendererOperationToken(rawValue: rawToken)
            try renderer.beginStroke(
                token: token,
                sample: depositionSample(.began, x: 12),
                style: depositionStyle(brush, compositeMode: .draw)
            )
            _ = try await renderer.drainPreparedStrokeInputForHarness(
                outputPixelSize: renderer.pixelSize
            )
            var adopted = await renderer
                .interactiveStrokeCacheSnapshotForTesting()
            #expect(adopted.activeStrokeEpochCount == 1)
            #expect(adopted.totalPhysicalResidentBytes > 0)
            try renderer.requestStrokeCommit(
                token: token,
                sample: depositionSample(.ended, x: 44)
            )
            let completion = Task { @MainActor in
                try await renderer.completePendingInteractiveStrokeAndAwaitIdle(
                    deadlineUptimeNanoseconds:
                        DispatchTime.now().uptimeNanoseconds
                            &+ 2_000_000_000
                )
            }
            try #require(
                await commitGate.waitUntilBlocked(count: index + 1)
            )
            adopted = await renderer
                .interactiveStrokeCacheSnapshotForTesting()
            #expect(adopted.activeStrokeEpochCount == 1)
            #expect(adopted.totalPhysicalResidentBytes > 0)
            await commitGate.releaseOne()
            _ = try await completion.value

            let terminal = await renderer
                .interactiveStrokeCacheSnapshotForTesting()
            #expect(terminal.activeStrokeEpochCount == 0)
            #expect(terminal.activeUpdateOwnerCount == 0)
            #expect(terminal.pendingPreparedAcknowledgementCount == 0)
            #expect(terminal.totalPhysicalResidentBytes == 0)
            #expect(terminal.isIdle)
            #expect(renderer.isIdle)
        }
    }

    @Test
    @MainActor
    func failedCommitRetiresCacheBeforeNextStrokeAdoption() async throws {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        var reportedErrors: [MetalRendererError] = []
        renderer.onError = { reportedErrors.append($0) }
        let brush = try await setup.compileBrush(
            id: "brush.cache-failure-retirement"
        )
        try renderer.activateDrawBrush(brush)
        let commitGate = SparseCutoverPaintCommitGate()
        renderer.installPaintStrokeCommitGateForTesting(commitGate)
        let failedToken = RendererOperationToken(rawValue: 0xCA_C4_E0_21)
        try renderer.beginStroke(
            token: failedToken,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        var terminal = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(terminal.activeStrokeEpochCount == 1)
        #expect(terminal.totalPhysicalResidentBytes > 0)
        renderer.installPaintStrokeCommitFailureForTesting(
            .commandFailed("injected cache retirement commit failure")
        )
        try renderer.requestStrokeCommit(
            token: failedToken,
            sample: depositionSample(.ended, x: 44)
        )
        let failedCompletion = Task { @MainActor in
            try await renderer.completePendingInteractiveStrokeAndAwaitIdle(
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                        &+ 2_000_000_000
            )
        }
        try #require(await commitGate.waitUntilBlocked(count: 1))
        terminal = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(terminal.activeStrokeEpochCount == 1)
        #expect(terminal.totalPhysicalResidentBytes > 0)
        await commitGate.releaseOne()
        do {
            _ = try await failedCompletion.value
        } catch is MetalRendererError {}
        #expect(reportedErrors.count == 1)

        terminal = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.isIdle)
        #expect(renderer.isIdle)

        let recoveryToken = RendererOperationToken(rawValue: 0xCA_C4_E0_22)
        try renderer.beginStroke(
            token: recoveryToken,
            sample: depositionSample(.began, x: 20),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        terminal = await renderer.interactiveStrokeCacheSnapshotForTesting()
        #expect(terminal.activeStrokeEpochCount == 1)
        #expect(terminal.totalPhysicalResidentBytes > 0)
        try renderer.cancelStroke(token: recoveryToken)
        await renderer.awaitInteractiveStrokeCacheRetirementForHarness()
        try renderer.drainStrokeWorkspaceRetirementForHarness()
        terminal = await renderer.interactiveStrokeCacheSnapshotForTesting()
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.isIdle)
        #expect(renderer.isIdle)
    }

    @Test
    @MainActor
    func resetDuringFirstGatedCacheAdoptionCannotResurrectLifecycle()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        let brush = try await setup.compileBrush(
            id: "brush.cache-first-adoption-cancel"
        )
        try renderer.activateDrawBrush(brush)
        let gate = SparseCutoverInteractiveCacheGate()
        defer { Task { await gate.releaseAll() } }
        await renderer.installInteractiveStrokeCacheCompletionGateForTesting(
            gate
        )
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_31)
        try renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        let drain = Task { @MainActor in
            try await renderer.drainPreparedStrokeInputForHarness(
                outputPixelSize: renderer.pixelSize
            )
        }
        try #require(await gate.waitUntilSubmitted())
        let inFlight = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(inFlight.activeUpdateOwnerCount == 1)

        try renderer.cancelStroke(token: token)
        await gate.open()
        _ = try? await drain.value
        await renderer.awaitInteractiveStrokeCacheRetirementForHarness()
        try renderer.drainStrokeWorkspaceRetirementForHarness()

        let terminal = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.activeUpdateOwnerCount == 0)
        #expect(terminal.pendingPreparedAcknowledgementCount == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.isIdle)
        #expect(renderer.isIdle)
    }

    @Test
    @MainActor
    func rendererDeinitBeforeRealMailboxACKCancelsWorkerAndCache()
        async throws
    {
        var renderer: GridRenderer?
        let brush: CompiledBrush
        do {
            guard let setup = try makeDepositionRendererSetup() else { return }
            renderer = setup.renderer
            brush = try await setup.compileBrush(
                id: "brush.cache-pre-ack-deinit"
            )
        }
        if let renderer {
            renderer.replaceAvailableStrokePreparationWorkspaceForTesting(
                budget: renderer.depositionFrameBudget,
                cancellationCleanupFailures: [
                    .injectedFailure(.beforePartition),
                ]
            )
        }
        let gate = SparseCutoverInteractiveCacheGate()
        defer { Task { await gate.releaseAll() } }
        await renderer?.installInteractiveStrokeCacheCompletionGateForTesting(
            gate
        )
        try renderer?.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_32)
        try renderer?.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        try #require(await gate.waitUntilSubmitted())

        var cache = renderer?.interactiveStrokePresentationCacheForTesting()
        let identity = try #require(
            renderer?.interactiveStrokeCacheLifecycleIdentityForTesting()
        )
        let mailbox = try #require(
            renderer?.offMainPreparationMailboxForTesting
        )
        let progress = StrokePreparationAsyncProgressRegistration(
            mailbox: mailbox
        )
        defer { progress.remove() }
        let workerTask = try #require(
            renderer?.offMainPreparationWorkerTaskForTesting
        )
        weak let workerDriver = renderer?
            .offMainPreparationWorkerDriverForTesting
        let inFlight = try #require(await cache?.snapshot())
        #expect(inFlight.activeUpdateOwnerCount == 1)
        #expect(inFlight.pendingPreparedAcknowledgementCount == 0)
        #expect(InteractiveStrokeCacheLifecycleCoordinator.shared
            .retainsLifecycle(identity))

        let weakRenderer = WeakSparseCutoverRenderer(renderer)
        renderer = nil
        #expect(weakRenderer.value == nil)
        await gate.open()
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(identity)

        var observedTerminalCancellation = mailbox.snapshot
            .terminalCancellationPublicationCount > 0
        for _ in 0..<4 where !observedTerminalCancellation {
            let revision = progress.currentRevision
            if mailbox.snapshot.terminalCancellationPublicationCount > 0 {
                observedTerminalCancellation = true
                break
            }
            if progress.currentRevision == revision {
                _ = try await progress.waitForProgress(
                    after: revision,
                    timeoutNanoseconds: 500_000_000
                )
            }
            observedTerminalCancellation = mailbox.snapshot
                .terminalCancellationPublicationCount > 0
        }
        if !observedTerminalCancellation {
            Issue.record(
                "terminal cancellation missing; mailbox=\(mailbox.snapshot); workerAlive=\(workerDriver != nil)"
            )
        }
        guard observedTerminalCancellation else { return }

        await workerTask.value
        #expect(workerDriver == nil)
        let terminal = try #require(await cache?.snapshot())
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.activeUpdateOwnerCount == 0)
        #expect(terminal.pendingPreparedAcknowledgementCount == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.acknowledgementSettlementCount == 1)
        #expect(terminal.isIdle)
        cache = nil
    }

    @Test
    @MainActor
    func rendererDeinitDuringGatedCommitDoesNotRetainGridOrCache()
        async throws
    {
        var renderer: GridRenderer?
        let brush: CompiledBrush
        do {
            guard let setup = try makeDepositionRendererSetup() else { return }
            renderer = setup.renderer
            brush = try await setup.compileBrush(
                id: "brush.cache-commit-owner-loss"
            )
        }
        let commitGate = SparseCutoverPaintCommitGate()
        defer { Task { await commitGate.releaseAll() } }
        renderer?.installPaintStrokeCommitGateForTesting(commitGate)
        try renderer?.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_33)
        try renderer?.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer?.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer?.pixelSize ?? PixelSize(width: 64, height: 64)
        )
        var cache = renderer?.interactiveStrokePresentationCacheForTesting()
        let identity = try #require(
            renderer?.interactiveStrokeCacheLifecycleIdentityForTesting()
        )
        let adopted = try #require(await cache?.snapshot())
        #expect(adopted.activeStrokeEpochCount == 1)
        #expect(adopted.totalPhysicalResidentBytes > 0)
        try renderer?.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 44)
        )
        try #require(await commitGate.waitUntilBlocked(count: 1))

        let weakRenderer = WeakSparseCutoverRenderer(renderer)
        renderer = nil
        guard weakRenderer.value == nil else {
            Issue.record("gated paint commit task retained GridRenderer")
            await commitGate.releaseAll()
            return
        }
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(identity)
        let terminal = try #require(await cache?.snapshot())
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.activeUpdateOwnerCount == 0)
        #expect(terminal.pendingPreparedAcknowledgementCount == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.isIdle)
        cache = nil
    }

    @Test
    @MainActor
    func shutdownDuringGatedCommitWaitsForGridAndCacheTerminal()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        let brush = try await setup.compileBrush(
            id: "brush.cache-commit-shutdown"
        )
        let commitGate = SparseCutoverPaintCommitGate()
        defer { Task { await commitGate.releaseAll() } }
        renderer.installPaintStrokeCommitGateForTesting(commitGate)
        try renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_34)
        try renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        let identity = try #require(
            renderer.interactiveStrokeCacheLifecycleIdentityForTesting()
        )
        let adopted = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(adopted.activeStrokeEpochCount == 1)
        #expect(adopted.totalPhysicalResidentBytes > 0)
        try renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 44)
        )
        try #require(await commitGate.waitUntilBlocked(count: 1))

        let shutdown = try await renderer.shutdown(reason: .sessionReplacement)
        let terminal = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(shutdown.isComplete)
        #expect(renderer.isIdle)
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.activeUpdateOwnerCount == 0)
        #expect(terminal.pendingPreparedAcknowledgementCount == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.isIdle)

        await commitGate.releaseAll()
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(identity)
        try renderer.drainStrokeWorkspaceRetirementForHarness()
    }

    @Test
    @MainActor
    func shutdownDuringCollectingStrokeRetiresWorkerAndCache()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        renderer.configureStrokeRuntimeTelemetry(profile: .syntheticTest)
        var completions: [RendererOperationCompletion] = []
        var runtimeMarkers: [StrokeRuntimeSegmentMarker] = []
        renderer.onOperationCompleted = { completions.append($0) }
        renderer.onStrokeRuntimeSegmentMarker = { runtimeMarkers.append($0) }
        let brush = try await setup.compileBrush(
            id: "brush.cache-collecting-shutdown"
        )
        try renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_36)
        try renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        let adopted = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(adopted.activeStrokeEpochCount == 1)
        #expect(adopted.totalPhysicalResidentBytes > 0)

        let shutdown = try await renderer.shutdown(reason: .sessionReplacement)
        let terminal = await renderer
            .interactiveStrokeCacheSnapshotForTesting()
        #expect(shutdown.isComplete)
        #expect(renderer.isIdle)
        #expect(terminal.activeStrokeEpochCount == 0)
        #expect(terminal.activeUpdateOwnerCount == 0)
        #expect(terminal.pendingPreparedAcknowledgementCount == 0)
        #expect(terminal.totalPhysicalResidentBytes == 0)
        #expect(terminal.isIdle)
        let matchingTerminalCount = completions.reduce(into: 0) {
            count, completion in
            switch completion {
            case let .failure(completed, _) where completed == token:
                count += 1
            default:
                break
            }
        }
        #expect(matchingTerminalCount == 1)
        #expect(runtimeMarkers.map(\.kind) == [.segmentBegan, .segmentEnded])
        #expect(runtimeMarkers.first?.strokeID
            == runtimeMarkers.last?.strokeID)
        #expect(renderer.pendingStrokeRuntimeFrameCountForTesting == 0)
    }

    @Test
    @MainActor
    func cancellationCleanupFailurePublishesTerminalAndReleasesGridCache()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        let failure = StrokeTileSurfaceError.injectedFailure(
            .beforePartition
        )
        renderer.replaceAvailableStrokePreparationWorkspaceForTesting(
            budget: renderer.depositionFrameBudget,
            cancellationCleanupFailures: [failure]
        )
        var reportedErrors: [MetalRendererError] = []
        renderer.onError = { reportedErrors.append($0) }
        let brush = try await setup.compileBrush(
            id: "brush.cache-terminal-cancel-failure"
        )
        try renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_38)
        try renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        try renderer.cancelStroke(token: token)
        await renderer.awaitInteractiveStrokeCacheRetirementForHarness()
        try renderer.drainStrokeWorkspaceRetirementForHarness()

        #expect(renderer.offMainTerminalCancellationPublicationCountForTesting
            == 1)
        #expect(renderer.isIdle)
        #expect((await renderer.interactiveStrokeCacheSnapshotForTesting())
            .isIdle)
        #expect(reportedErrors.count == 1)

        let nextToken = RendererOperationToken(rawValue: 0xCA_C4_E0_3B)
        try renderer.beginStroke(
            token: nextToken,
            sample: depositionSample(.began, x: 20),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        try renderer.cancelStroke(token: nextToken)
        await renderer.awaitInteractiveStrokeCacheRetirementForHarness()
        try renderer.drainStrokeWorkspaceRetirementForHarness()
        #expect(renderer.isIdle)
        #expect(reportedErrors.count == 1)
    }

    @Test
    @MainActor
    func operationFailureCancelsGatedCommitWithoutSecondTerminal()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        var reportedErrors: [MetalRendererError] = []
        renderer.onError = { reportedErrors.append($0) }
        let brush = try await setup.compileBrush(
            id: "brush.cache-commit-operation-failure"
        )
        let commitGate = SparseCutoverPaintCommitGate()
        defer { Task { await commitGate.releaseAll() } }
        renderer.installPaintStrokeCommitGateForTesting(commitGate)
        try renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_35)
        try renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        let identity = try #require(
            renderer.interactiveStrokeCacheLifecycleIdentityForTesting()
        )
        try renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 44)
        )
        try #require(await commitGate.waitUntilBlocked(count: 1))

        renderer.failActiveOperationIfNeeded(
            .commandFailed("injected gated commit operation failure")
        )
        try #require(await commitGate.waitUntilCancellation())
        await InteractiveStrokeCacheLifecycleCoordinator.shared
            .waitForLifecycle(identity)
        try renderer.drainStrokeWorkspaceRetirementForHarness()
        #expect(renderer.isIdle)
        #expect(reportedErrors.count == 1)

        await commitGate.releaseAll()
        let committed = try await renderer.captureCommittedDocument()
        guard case let .singleRaster(bytes) = committed.storage else {
            Issue.record("plain failed commit must remain a single raster")
            return
        }
        #expect(bytes.allSatisfy { $0 == 0 })
        #expect(reportedErrors.count == 1)
    }

    @Test
    @MainActor
    func failureAfterCanonicalPublicationFinalizesCommitAsSuccess()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        let brush = try await setup.compileBrush(
            id: "brush.cache-post-publication-linearization"
        )
        let publicationGate = SparseCutoverPaintCommitGate()
        defer {
            Task { await publicationGate.releaseAll() }
            Task {
                await renderer
                    .installAfterPaintMutationPublicationHookForTesting(nil)
            }
        }
        await renderer.installAfterPaintMutationPublicationHookForTesting {
            await publicationGate.waitBeforeCommit()
        }
        var completions: [RendererOperationCompletion] = []
        var reportedErrors: [MetalRendererError] = []
        renderer.onOperationCompleted = { completions.append($0) }
        renderer.onError = { reportedErrors.append($0) }
        try renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_37)
        try renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        try renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 44)
        )
        let completion = Task { @MainActor in
            try await renderer.completePendingInteractiveStrokeAndAwaitIdle(
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                        &+ 2_000_000_000
            )
        }
        try #require(await publicationGate.waitUntilBlocked(count: 1))

        renderer.failActiveOperationIfNeeded(
            .commandFailed("failure requested after canonical publication")
        )
        await publicationGate.releaseAll()
        _ = try? await completion.value

        let successCount = completions.reduce(into: 0) { count, completion in
            switch completion {
            case let .rasterSuccess(receipt) where receipt.token == token:
                count += 1
            case let .operationSuccess(completed) where completed == token:
                count += 1
            default:
                break
            }
        }
        #expect(successCount == 1)
        #expect(reportedErrors.isEmpty)
        let committed = try await renderer.captureCommittedDocument()
        guard case let .singleRaster(bytes) = committed.storage else {
            Issue.record("published stroke must remain a single raster")
            return
        }
        #expect(bytes.contains { $0 != 0 })
        #expect(renderer.isIdle)
        #expect((await renderer.interactiveStrokeCacheSnapshotForTesting())
            .isIdle)
    }

    @Test
    @MainActor
    func failureClaimBeforeCanonicalPublicationPreventsPublish()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        let publicationGate = SparseCutoverPaintCommitGate()
        defer {
            Task { await publicationGate.releaseAll() }
            Task {
                await renderer
                    .installBeforePaintMutationPublicationClaimHookForTesting(
                        nil
                    )
            }
        }
        await renderer
            .installBeforePaintMutationPublicationClaimHookForTesting {
                await publicationGate.waitBeforeCommit()
            }
        var completions: [RendererOperationCompletion] = []
        var reportedErrors: [MetalRendererError] = []
        renderer.onOperationCompleted = { completions.append($0) }
        renderer.onError = { reportedErrors.append($0) }
        let brush = try await setup.compileBrush(
            id: "brush.cache-pre-publication-linearization"
        )
        try renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_39)
        try renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        try renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 44)
        )
        let completion = Task { @MainActor in
            try await renderer.completePendingInteractiveStrokeAndAwaitIdle(
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
                        &+ 2_000_000_000
            )
        }
        try #require(await publicationGate.waitUntilBlocked(count: 1))

        renderer.failActiveOperationIfNeeded(
            .commandFailed("failure claimed before canonical publication")
        )
        await publicationGate.releaseAll()
        _ = try? await completion.value

        let failureCount = completions.reduce(into: 0) {
            count, completion in
            if case let .failure(completed, _) = completion,
               completed == token
            {
                count += 1
            }
        }
        #expect(failureCount == 1)
        #expect(reportedErrors.count == 1)
        let committed = try await renderer.captureCommittedDocument()
        guard case let .singleRaster(bytes) = committed.storage else {
            Issue.record("failed prepublication stroke must remain raster")
            return
        }
        #expect(bytes.allSatisfy { $0 == 0 })
        #expect(renderer.isIdle)
    }

    @Test
    @MainActor
    func shutdownClaimsFailureBeforeCanonicalPublication()
        async throws
    {
        guard let setup = try makeDepositionRendererSetup() else { return }
        let renderer = setup.renderer
        let publicationGate = SparseCutoverPaintCommitGate()
        defer {
            Task { await publicationGate.releaseAll() }
            Task {
                await renderer
                    .installBeforePaintMutationPublicationClaimHookForTesting(
                        nil
                    )
            }
        }
        await renderer
            .installBeforePaintMutationPublicationClaimHookForTesting {
                await publicationGate.waitBeforeCommit()
            }
        var completions: [RendererOperationCompletion] = []
        renderer.onOperationCompleted = { completions.append($0) }
        let brush = try await setup.compileBrush(
            id: "brush.cache-pre-publication-shutdown"
        )
        try renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xCA_C4_E0_3A)
        try renderer.beginStroke(
            token: token,
            sample: depositionSample(.began, x: 12),
            style: depositionStyle(brush, compositeMode: .draw)
        )
        _ = try await renderer.drainPreparedStrokeInputForHarness(
            outputPixelSize: renderer.pixelSize
        )
        try renderer.requestStrokeCommit(
            token: token,
            sample: depositionSample(.ended, x: 44)
        )
        try #require(await publicationGate.waitUntilBlocked(count: 1))

        let shutdown = try await renderer.shutdown(reason: .sessionReplacement)
        let outcomes = completions.reduce(into: (success: 0, failure: 0)) {
            counts, completion in
            switch completion {
            case let .rasterSuccess(receipt) where receipt.token == token:
                counts.success += 1
            case let .operationSuccess(completed) where completed == token:
                counts.success += 1
            case let .failure(completed, _) where completed == token:
                counts.failure += 1
            default:
                break
            }
        }
        #expect(shutdown.isComplete)
        #expect(outcomes.success == 0)
        #expect(outcomes.failure == 1)
        #expect(renderer.isIdle)
    }

    @Test
    func displayPreparationDoesNotOwnPendingPreparedPageCredit() {
        #expect(
            GridRenderer.paintDisplayPreparationAction(for: nil) == .stable
        )
        #expect(
            GridRenderer.paintDisplayPreparationAction(for: .available)
                == .transient
        )
        #expect(
            GridRenderer.paintDisplayPreparationAction(for: .pending)
                == .stable
        )
        #expect(
            GridRenderer.paintDisplayPreparationAction(for: .fulfilled)
                == .stable
        )
        #expect(
            GridRenderer.isDeferredPaintDisplayPreparationFailure(
                DocumentPaintVisiblePlanControllerError
                    .transientSourceNotAvailable
            )
        )
        #expect(
            !GridRenderer.isDeferredPaintDisplayPreparationFailure(
                DocumentPaintVisiblePlanControllerError.staleSubmission
            )
        )
    }

    @Test
    @MainActor
    func delayedGPUCompletionDoesNotInflateCPUPreparationTime()
        async
    {
        var timestamp: CFAbsoluteTime = 1
        let measured = await GridRenderer
            .performMeasuredCPUPreparation(
                clock: { timestamp },
                preparation: {
                    timestamp = 1.00025
                },
                waitForCompletion: {
                    timestamp = 10
                    return "completed"
                }
            )

        #expect(measured.completion == "completed")
        #expect(
            abs(measured.cpuPreparationMilliseconds - 0.25)
                < 0.000_001
        )
        #expect(timestamp == 10)
    }

    @Test
    @MainActor
    func publishingPreparationRetainsExclusiveOwnershipThroughRetirement()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseCutoverLibrary(device: device)
        let renderer = try makeSparseCutoverRenderer(
            device: device,
            library: library
        )
        let first = CanvasPresentationRevision(sequence: 1)
        let second = CanvasPresentationRevision(sequence: 2)
        let gate = PresentationPreparationGate(
            blockedRetirementRevision: first
        )
        renderer.installPresentationPreparationGateForTesting(gate)
        let view = sparseCutoverView(device: device)

        renderer.draw(in: view)
        await gate.waitUntilRetiring(first)
        #expect(renderer.paintDisplayPreparationOwnershipCountForTesting == 1)

        renderer.pan(byScreenDelta: SIMD2(1, 0))
        for _ in 0..<100 where await gate.snapshot.started == [first] {
            await Task.yield()
        }
        var state = await gate.snapshot
        #expect(state.started == [first])
        #expect(state.maximumConcurrentPreparationCount == 1)
        #expect(renderer.paintDisplayPreparationOwnershipCountForTesting == 1)
        #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 1)

        await gate.releaseBlockedRetirement()
        await gate.waitUntilRetired(second)
        state = await gate.snapshot
        #expect(state.started == [first, second])
        #expect(state.maximumConcurrentPreparationCount == 1)
        #expect(state.activePreparationCount == 0)
        #expect(renderer.paintDisplayPreparationOwnershipCountForTesting == 0)
    }

    @Test
    @MainActor
    func terminalAsyncPreparationFailureSettlesOnceAndNewerDemandProgresses()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try makeSparseCutoverRenderer(
            device: device,
            library: try makeSparseCutoverLibrary(device: device)
        )
        let first = CanvasPresentationRevision(sequence: 1)
        let second = CanvasPresentationRevision(sequence: 2)
        let gate = PresentationPreparationGate(
            failedRevision: first
        )
        renderer.installPresentationPreparationGateForTesting(gate)
        let view = sparseCutoverView(device: device)
        var errors: [MetalRendererError] = []
        renderer.onError = { errors.append($0) }

        renderer.draw(in: view)
        await gate.waitUntilRetired(first)
        for _ in 0..<1_000
        where renderer.paintDisplayPreparationOwnershipCountForTesting != 0
            || renderer.interactiveFrameHasDemandForTesting
        {
            await Task.yield()
        }
        renderer.draw(in: view)
        renderer.draw(in: view)

        var state = await gate.snapshot
        #expect(state.started == [first])
        #expect(!renderer.interactiveFrameHasDemandForTesting)
        #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 1)
        #expect(errors.count == 1)
        #expect(renderer.lastError == errors.first)

        renderer.pan(byScreenDelta: SIMD2(1, 0))
        renderer.draw(in: view)
        await gate.waitUntilRetired(second)
        state = await gate.snapshot

        #expect(state.started == [first, second])
        #expect(state.published == [second])
        #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 2)
        #expect(errors.count == 1)
    }

    @Test
    @MainActor
    func committedRestoreSupersedesActivePreparationAndDemandsPresentation()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try makeSparseCutoverRenderer(
            device: device,
            library: try makeSparseCutoverLibrary(device: device)
        )
        let first = CanvasPresentationRevision(sequence: 1)
        let second = CanvasPresentationRevision(sequence: 2)
        let gate = PresentationPreparationGate(blockedRevision: first)
        renderer.installPresentationPreparationGateForTesting(gate)
        let view = sparseCutoverView(device: device)
        var errors: [MetalRendererError] = []
        renderer.onError = { errors.append($0) }

        renderer.draw(in: view)
        await gate.waitUntilStarted(first)
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bytes[0] = 31
        bytes[1] = 63
        bytes[2] = 127
        bytes[3] = 255
        try await renderer.restoreCommittedDocument(
            CommittedDocumentSnapshot(
                canvasSize: PixelSize(width: 64, height: 64),
                documentConfiguration: .finite(.plain),
                documentDomainLocked: true,
                radialGeometryLocked: false,
                storage: .singleRaster(
                    bgra8PremultipliedBytes: bytes
                )
            )
        )

        #expect(renderer.interactiveFrameHasDemandForTesting)
        await gate.releaseBlockedRevision()
        await gate.waitUntilRetired(first)
        await gate.waitUntilRetired(second)
        let state = await gate.snapshot

        #expect(state.started == [first, second])
        #expect(state.published == [second])
        #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 2)
        #expect(errors.isEmpty)
        #expect(renderer.lastError == nil)
    }

    #if DEBUG
    @Test
    @MainActor
    func publishedRestoreInvalidatesBeforeRevisionReleaseFailure()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try makeSparseCutoverRenderer(
            device: device,
            library: try makeSparseCutoverLibrary(device: device)
        )
        let first = CanvasPresentationRevision(sequence: 1)
        let second = CanvasPresentationRevision(sequence: 2)
        let gate = PresentationPreparationGate(blockedRevision: first)
        renderer.installPresentationPreparationGateForTesting(gate)
        renderer.installPaintRevisionReleaseFailureForTesting(
            .commandFailed("injected revision release failure")
        )
        let view = sparseCutoverView(device: device)

        renderer.draw(in: view)
        await gate.waitUntilStarted(first)
        let identityBefore = renderer.paintCanonicalStateIdentityForTesting()
        let revisionBefore =
            renderer.paintDisplayPreparationRevisionForTesting
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bytes[0] = 29
        bytes[1] = 61
        bytes[2] = 113
        bytes[3] = 255
        let restored = CommittedDocumentSnapshot(
            canvasSize: PixelSize(width: 64, height: 64),
            documentConfiguration: .finite(.plain),
            documentDomainLocked: true,
            radialGeometryLocked: false,
            storage: .singleRaster(bgra8PremultipliedBytes: bytes)
        )

        do {
            try await renderer.restoreCommittedDocument(restored)
            Issue.record("revision release failure must propagate")
        } catch let error as MetalRendererError {
            #expect(
                error
                    == .commandFailed("injected revision release failure")
            )
        }

        let identityAfter = renderer.paintCanonicalStateIdentityForTesting()
        #expect(identityAfter.compositeRevision > identityBefore.compositeRevision)
        #expect(renderer.interactiveFrameHasDemandForTesting)
        #expect(
            renderer.paintDisplayPreparationRevisionForTesting
                == revisionBefore + 1
        )
        let captured = try await renderer.captureCommittedDocument()
        guard case let .singleRaster(actual) = captured.storage else {
            Issue.record("plain restore must remain a single raster")
            return
        }
        #expect(Array(actual.prefix(4)) == Array(bytes.prefix(4)))

        await gate.releaseBlockedRevision()
        await gate.waitUntilRetired(second)
        let state = await gate.snapshot

        #expect(state.started == [first, second])
        #expect(state.published == [second])
        #expect(renderer.paintDisplayPreparationOwnershipCountForTesting == 0)
        #expect(renderer.lastError == nil)
    }
    #endif

    #if DEBUG
    @Test
    @MainActor
    func failedTransientAcknowledgementSettlesOnceAndNewerDemandProgresses()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try makeSparseCutoverRenderer(
            device: device,
            library: try makeSparseCutoverLibrary(device: device)
        )
        let gate = PresentationPreparationGate()
        renderer.installPresentationPreparationGateForTesting(gate)
        renderer.installFailedTransientAcknowledgementForTesting()
        let view = sparseCutoverView(device: device)
        var errors: [MetalRendererError] = []
        renderer.onError = { errors.append($0) }

        renderer.draw(in: view)
        renderer.draw(in: view)

        #expect(await gate.snapshot.started.isEmpty)
        #expect(!renderer.interactiveFrameHasDemandForTesting)
        #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 0)
        #expect(errors.count == 1)
        #expect(renderer.lastError == errors.first)

        renderer.pan(byScreenDelta: SIMD2(1, 0))
        renderer.draw(in: view)
        await gate.waitUntilRetired(CanvasPresentationRevision(sequence: 2))

        #expect(
            await gate.snapshot.started
                == [CanvasPresentationRevision(sequence: 2)]
        )
        #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 1)
        #expect(errors.count == 1)
    }
    #endif

    #if DEBUG
    @Test
    @MainActor
    func supersededPreparationRetiresBeforeOnlyTheLatestRevisionPublishes()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseCutoverLibrary(device: device)
        let size = PixelSize(width: 64, height: 64)
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: try TilingCanvasConfiguration(
                pixelSize: size,
                finiteConfiguration: .plain
            )
        )
        let gate = PresentationPreparationGate(
            blockedRevision: CanvasPresentationRevision(sequence: 1)
        )
        renderer.installPresentationPreparationGateForTesting(gate)
        let view = MTKView(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        view.drawableSize = CGSize(width: 64, height: 64)

        renderer.draw(in: view)
        await gate.waitUntilStarted(
            CanvasPresentationRevision(sequence: 1)
        )
        renderer.pan(byScreenDelta: SIMD2(1, 0))
        renderer.pan(byScreenDelta: SIMD2(1, 0))

        var state = await gate.snapshot
        #expect(state.started == [CanvasPresentationRevision(sequence: 1)])
        #expect(state.maximumConcurrentPreparationCount == 1)
        #expect(state.activePreparationCount == 1)
        #expect(renderer.paintDisplayPreparationOwnershipCountForTesting == 1)
        #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 1)

        await gate.releaseBlockedRevision()
        await gate.waitUntilPublished(
            CanvasPresentationRevision(sequence: 3)
        )
        await gate.waitUntilRetired(
            CanvasPresentationRevision(sequence: 3)
        )
        state = await gate.snapshot

        #expect(state.maximumConcurrentPreparationCount == 1)
        #expect(state.activePreparationCount == 0)
        #expect(
            state.published == [CanvasPresentationRevision(sequence: 3)]
        )
        #expect(
            renderer.paintDisplayPublishedRevisionsForTesting
                == [CanvasPresentationRevision(sequence: 3)]
        )
        #expect(renderer.paintDisplayPreparationOwnershipCountForTesting == 0)
        #expect(renderer.lastError == nil)
    }
    #endif

    @Test
    @MainActor
    func exactDrawablePresentationSettlesOnlyTheNewestSubmittedRevision()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseCutoverLibrary(device: device)
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: try TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 64, height: 64),
                finiteConfiguration: .plain
            )
        )
        let registrar = TestDrawablePresentationRegistrar()
        renderer.installDrawablePresentationRegistrarForTesting(registrar)
        let view = MTKView(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        let first = CanvasPresentationRevision(sequence: 1)
        let newest = CanvasPresentationRevision(sequence: 2)

        renderer.submitInteractivePresentationForTesting(first, in: view)
        #expect(renderer.interactiveFrameHasDemandForTesting)
        #expect(registrar.registeredRevisions == [first])

        renderer.signalInteractivePresentationDemandForTesting(newest)
        registrar.present(first)
        #expect(renderer.interactiveFrameHasDemandForTesting)

        renderer.submitInteractivePresentationForTesting(newest, in: view)
        let requestsBeforeNewestPresentation =
            renderer.presentationContinuationRequestCountForTesting
        registrar.present(newest)

        #expect(!renderer.interactiveFrameHasDemandForTesting)
        #expect(
            renderer.presentationContinuationRequestCountForTesting
                == requestsBeforeNewestPresentation
        )
        #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 0)
    }

    #if DEBUG
    @Test
    @MainActor
    func debugFrameCallbacksDoNotCreateCompletionTelemetryDemand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseCutoverLibrary(device: device)
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: try TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 64, height: 64),
                finiteConfiguration: .plain
            )
        )
        let view = MTKView(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        renderer.onInteractiveFramePresented = { _, _ in }
        renderer.onInteractiveFrameMetrics = { _ in }

        renderer.handleInteractiveCommandCompletionForTesting(in: view)

        #expect(!renderer.interactiveFrameHasDemandForTesting)
        #expect(renderer.presentationContinuationRequestCountForTesting == 0)
        #expect(renderer.paintDisplayPreparationScheduleCountForTesting == 0)
    }
    #endif

    @Test
    @MainActor
    func oneGenericLayerOwnsRestoreCaptureAndTerminalDebt() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try makeSparseCutoverLibrary(device: device)
        let layerID = UUID(
            uuidString: "5ef32db9-2683-420c-a50a-b8e309dc3807"
        )!
        let size = PixelSize(width: 64, height: 64)
        let configuration = try TilingCanvasConfiguration(
            pixelSize: size,
            finiteConfiguration: .plain
        )
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: configuration,
            initialLayerStack: try .single(id: layerID)
        )

        let initial = await renderer.paintStateSnapshotForTesting()
        #expect(initial.activeLayerID == layerID)
        #expect(initial.layerIDs == [layerID])
        #expect(initial.activeStrokeSurfaceCount == 0)
        #expect(initial.activeCommandOperationCount == 0)

        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bytes[0] = 17
        bytes[1] = 33
        bytes[2] = 65
        bytes[3] = 127
        let restored = CommittedDocumentSnapshot(
            canvasSize: size,
            documentConfiguration: .finite(.plain),
            documentDomainLocked: true,
            radialGeometryLocked: false,
            storage: .singleRaster(bgra8PremultipliedBytes: bytes)
        )
        try await renderer.restoreCommittedDocument(restored)
        let captured = try await renderer.captureCommittedDocument()
        guard case let .singleRaster(actual) = captured.storage else {
            Issue.record("plain document must remain one canonical raster")
            return
        }
        #expect(actual.count == bytes.count)
        for (lhs, rhs) in zip(actual, bytes) {
            #expect(abs(Int(lhs) - Int(rhs)) <= 1)
        }

        let terminal = try await renderer.shutdown(
            reason: .sessionReplacement
        )
        #expect(terminal.isComplete)
        let final = await renderer.paintStateSnapshotForTesting()
        #expect(final.activeSnapshotTokenCount == 0)
        #expect(final.aggregateSnapshotReferenceCount == 0)
        #expect(final.activeTileLeaseCount == 0)
        #expect(final.snapshotPayloadLiabilityByteCount == 0)
        #expect(final.revisionResidentBytes == 0)
        #expect(final.activeStrokeSurfaceCount == 0)
        #expect(final.activeCommandOperationCount == 0)
    }
}

@MainActor
private final class WeakSparseCutoverRenderer {
    weak var value: GridRenderer?

    init(_ value: GridRenderer?) { self.value = value }
}

private final class WeakSparseCutoverCache: @unchecked Sendable {
    weak var value: InteractiveStrokePresentationCache?

    init(_ value: InteractiveStrokePresentationCache?) { self.value = value }
}

private final class SparseCutoverBoundedSignal: @unchecked Sendable {
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

@MainActor
private final class SparseCutoverCacheTerminalProbe {
    private(set) var snapshot: InteractiveStrokePresentationCacheSnapshot?
    private var waiters:
        [CheckedContinuation<InteractiveStrokePresentationCacheSnapshot, Never>]
        = []

    func record(_ snapshot: InteractiveStrokePresentationCacheSnapshot) {
        self.snapshot = snapshot
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: snapshot) }
    }

    func waitUntilRecorded() async
        -> InteractiveStrokePresentationCacheSnapshot
    {
        if let snapshot { return snapshot }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor SparseCutoverPaintCommitGate:
    InteractiveStrokePaintCommitGating
{
    private var blockedCount = 0
    private var blockedWaiters:
        [(Int, UUID, SparseCutoverBoundedSignal)] = []
    private var releaseWaiters:
        [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancellationCount = 0
    private var cancellationWaiters:
        [(Int, UUID, SparseCutoverBoundedSignal)] = []

    func waitBeforeCommit() async {
        blockedCount += 1
        let ready = blockedWaiters.filter { $0.0 <= blockedCount }
        blockedWaiters.removeAll { $0.0 <= blockedCount }
        for (_, _, waiter) in ready { waiter.signal() }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    releaseWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelReleaseWaiter(waiterID) }
        }
    }

    func waitUntilBlocked(count: Int) async -> Bool {
        guard blockedCount < count else { return true }
        let waiterID = UUID()
        let waiter = SparseCutoverBoundedSignal()
        blockedWaiters.append((count, waiterID, waiter))
        let result = await waiter.wait()
        blockedWaiters.removeAll { $0.1 == waiterID }
        return result
    }

    func waitUntilCancellation(count: Int = 1) async -> Bool {
        guard cancellationCount < count else { return true }
        let waiterID = UUID()
        let waiter = SparseCutoverBoundedSignal()
        cancellationWaiters.append((count, waiterID, waiter))
        let result = await waiter.wait(timeout: .milliseconds(500))
        cancellationWaiters.removeAll { $0.1 == waiterID }
        return result
    }

    func releaseOne() {
        guard !releaseWaiters.isEmpty else { return }
        let waiterID = releaseWaiters.keys.first!
        releaseWaiters.removeValue(forKey: waiterID)?.resume()
    }

    func releaseAll() {
        let waiters = Array(releaseWaiters.values)
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func cancelReleaseWaiter(_ waiterID: UUID) {
        releaseWaiters.removeValue(forKey: waiterID)?.resume()
        cancellationCount += 1
        let ready = cancellationWaiters.filter { $0.0 <= cancellationCount }
        cancellationWaiters.removeAll { $0.0 <= cancellationCount }
        for (_, _, waiter) in ready { waiter.signal() }
    }
}

private actor SparseCutoverInteractiveCacheGate:
    InteractiveStrokePresentationCacheCompletionGating
{
    private var isOpen = false
    private var didSubmit = false
    private var submissionWaiters:
        [UUID: SparseCutoverBoundedSignal] = [:]
    private var completionWaiters:
        [UUID: CheckedContinuation<Void, Never>] = [:]
    private let blocksLifecycleRetry: Bool
    private var lifecycleRetryScheduleCount = 0
    private var lifecycleRetryScheduleWaiters:
        [(Int, UUID, SparseCutoverBoundedSignal)] = []
    private var lifecycleRetryWaiters:
        [UUID: CheckedContinuation<Void, Never>] = [:]

    init(blocksLifecycleRetry: Bool = false) {
        self.blocksLifecycleRetry = blocksLifecycleRetry
    }

    func cacheCommandDidSubmit() {
        didSubmit = true
        let waiters = Array(submissionWaiters.values)
        submissionWaiters.removeAll()
        for waiter in waiters { waiter.signal() }
    }

    func waitAfterGPUCompletion() async {
        guard !isOpen else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || isOpen {
                    continuation.resume()
                } else {
                    completionWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelCompletionWaiter(waiterID) }
        }
    }

    func cacheRetirementDidWait() {}
    func cacheRetirementDidFail() {}
    func cacheAcknowledgementDidFail() {}
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
                }
            }
        } onCancel: {
            Task { await self.cancelLifecycleRetryWaiter(waiterID) }
        }
    }

    func waitUntilSubmitted() async -> Bool {
        guard !didSubmit else { return true }
        let waiterID = UUID()
        let waiter = SparseCutoverBoundedSignal()
        submissionWaiters[waiterID] = waiter
        let didSignal = await waiter.wait()
        submissionWaiters.removeValue(forKey: waiterID)
        return didSignal && didSubmit
    }

    func waitUntilLifecycleRetryScheduled(count: Int) async -> Bool {
        guard lifecycleRetryScheduleCount < count else { return true }
        let waiterID = UUID()
        let waiter = SparseCutoverBoundedSignal()
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

    func open() {
        isOpen = true
        let waiters = Array(completionWaiters.values)
        completionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func releaseAll() {
        open()
        let waiters = Array(lifecycleRetryWaiters.values)
        lifecycleRetryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func cancelCompletionWaiter(_ waiterID: UUID) {
        completionWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func cancelLifecycleRetryWaiter(_ waiterID: UUID) {
        lifecycleRetryWaiters.removeValue(forKey: waiterID)?.resume()
    }
}

@MainActor
private func makeSparseCutoverRenderer(
    device: any MTLDevice,
    library: any MTLLibrary
) throws -> GridRenderer {
    try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 64, height: 64),
        configuration: TilingCanvasConfiguration(
            pixelSize: PixelSize(width: 64, height: 64),
            finiteConfiguration: .plain
        )
    )
}

private func makeSparseCutoverLibrary(
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

@MainActor
private func sparseCutoverView(device: any MTLDevice) -> MTKView {
    let view = MTKView(
        frame: CGRect(x: 0, y: 0, width: 64, height: 64),
        device: device
    )
    view.drawableSize = CGSize(width: 64, height: 64)
    return view
}

@MainActor
private final class TestDrawablePresentationRegistrar:
    DrawablePresentationRegistering
{
    private var handlers:
        [CanvasPresentationRevision: @MainActor @Sendable () -> Void] = [:]

    var registeredRevisions: [CanvasPresentationRevision] {
        handlers.keys.sorted()
    }

    func register(
        revision: CanvasPresentationRevision,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        handlers[revision] = handler
    }

    func present(_ revision: CanvasPresentationRevision) {
        handlers.removeValue(forKey: revision)?()
    }
}

private actor PresentationPreparationGate:
    PresentationPreparationGating
{
    struct Snapshot: Sendable {
        let started: [CanvasPresentationRevision]
        let published: [CanvasPresentationRevision]
        let activePreparationCount: Int
        let maximumConcurrentPreparationCount: Int
    }

    private let blockedRevision: CanvasPresentationRevision?
    private let blockedRetirementRevision: CanvasPresentationRevision?
    private let failedRevision: CanvasPresentationRevision?
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedRetirementContinuation:
        CheckedContinuation<Void, Never>?
    private var started: [CanvasPresentationRevision] = []
    private var published: [CanvasPresentationRevision] = []
    private var retired: [CanvasPresentationRevision] = []
    private var activePreparationCount = 0
    private var maximumConcurrentPreparationCount = 0
    private var startWaiters:
        [CanvasPresentationRevision: [CheckedContinuation<Void, Never>]] = [:]
    private var publishWaiters:
        [CanvasPresentationRevision: [CheckedContinuation<Void, Never>]] = [:]
    private var retirementWaiters:
        [CanvasPresentationRevision: [CheckedContinuation<Void, Never>]] = [:]
    private var retiringWaiters:
        [CanvasPresentationRevision: [CheckedContinuation<Void, Never>]] = [:]

    init(
        blockedRevision: CanvasPresentationRevision? = nil,
        blockedRetirementRevision: CanvasPresentationRevision? = nil,
        failedRevision: CanvasPresentationRevision? = nil
    ) {
        self.blockedRevision = blockedRevision
        self.blockedRetirementRevision = blockedRetirementRevision
        self.failedRevision = failedRevision
    }

    func preparationDidBegin(
        revision: CanvasPresentationRevision
    ) async {
        activePreparationCount += 1
        maximumConcurrentPreparationCount = max(
            maximumConcurrentPreparationCount,
            activePreparationCount
        )
        started.append(revision)
        startWaiters.removeValue(forKey: revision)?.forEach { $0.resume() }
        if revision == blockedRevision {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
    }

    func injectedPreparationFailure(
        revision: CanvasPresentationRevision
    ) -> MetalRendererError? {
        guard revision == failedRevision else { return nil }
        return .commandFailed("injected asynchronous preparation failure")
    }

    func preparationDidPublish(
        revision: CanvasPresentationRevision
    ) async {
        published.append(revision)
        publishWaiters.removeValue(forKey: revision)?.forEach { $0.resume() }
    }

    func preparationDidRetire(revision: CanvasPresentationRevision) async {
        retiringWaiters.removeValue(forKey: revision)?.forEach {
            $0.resume()
        }
        if revision == blockedRetirementRevision {
            await withCheckedContinuation { continuation in
                blockedRetirementContinuation = continuation
            }
        }
        activePreparationCount -= 1
        retired.append(revision)
        retirementWaiters.removeValue(forKey: revision)?.forEach {
            $0.resume()
        }
    }

    func waitUntilStarted(_ revision: CanvasPresentationRevision) async {
        if started.contains(revision) { return }
        await withCheckedContinuation { continuation in
            startWaiters[revision, default: []].append(continuation)
        }
    }

    func waitUntilPublished(_ revision: CanvasPresentationRevision) async {
        if published.contains(revision) { return }
        await withCheckedContinuation { continuation in
            publishWaiters[revision, default: []].append(continuation)
        }
    }

    func waitUntilRetired(_ revision: CanvasPresentationRevision) async {
        if retired.contains(revision) { return }
        await withCheckedContinuation { continuation in
            retirementWaiters[revision, default: []].append(continuation)
        }
    }

    func waitUntilRetiring(_ revision: CanvasPresentationRevision) async {
        if retired.contains(revision)
            || (revision == blockedRetirementRevision
                && blockedRetirementContinuation != nil)
        {
            return
        }
        await withCheckedContinuation { continuation in
            retiringWaiters[revision, default: []].append(continuation)
        }
    }

    func releaseBlockedRevision() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func releaseBlockedRetirement() {
        blockedRetirementContinuation?.resume()
        blockedRetirementContinuation = nil
    }

    var snapshot: Snapshot {
        Snapshot(
            started: started,
            published: published,
            activePreparationCount: activePreparationCount,
            maximumConcurrentPreparationCount:
                maximumConcurrentPreparationCount
        )
    }
}
