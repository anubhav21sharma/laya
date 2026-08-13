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
    func supersededPreparationRetiresBeforeOnlyTheLatestRevisionPublishes()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary()
        else { return }
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

    @Test
    @MainActor
    func exactDrawablePresentationSettlesOnlyTheNewestSubmittedRevision()
        throws
    {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary()
        else { return }
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

    @Test
    @MainActor
    func debugFrameCallbacksDoNotCreateCompletionTelemetryDemand() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary()
        else { return }
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

    @Test
    @MainActor
    func oneGenericLayerOwnsRestoreCaptureAndTerminalDebt() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary()
        else { return }
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

    private let blockedRevision: CanvasPresentationRevision
    private var blockedContinuation: CheckedContinuation<Void, Never>?
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

    init(blockedRevision: CanvasPresentationRevision) {
        self.blockedRevision = blockedRevision
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

    func preparationDidPublish(
        revision: CanvasPresentationRevision
    ) {
        published.append(revision)
        publishWaiters.removeValue(forKey: revision)?.forEach { $0.resume() }
    }

    func preparationDidRetire(revision: CanvasPresentationRevision) {
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

    func releaseBlockedRevision() {
        blockedContinuation?.resume()
        blockedContinuation = nil
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
