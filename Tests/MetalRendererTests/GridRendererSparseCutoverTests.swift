import Foundation
@preconcurrency import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Grid renderer sparse cutover", .serialized)
struct GridRendererSparseCutoverTests {
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
            initialLayerID: layerID
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
