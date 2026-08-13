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
    func displayPreparationWaitsForPendingTransientAcknowledgement() {
        #expect(
            GridRenderer.paintDisplayPreparationAction(for: nil) == .stable
        )
        #expect(
            GridRenderer.paintDisplayPreparationAction(for: .available)
                == .transient
        )
        #expect(
            GridRenderer.paintDisplayPreparationAction(for: .pending) == .wait
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
