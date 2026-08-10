import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Current paint lifecycle acceptance", .serialized)
struct StageCAcceptanceLifecycleTests {
    @Test(arguments: StageCAcceptanceMode.all)
    @MainActor
    func commitClearRestoreAndExportUseOneCurrentSurfaceOwner(
        mode: StageCAcceptanceMode
    ) async throws {
        guard let setup = try mode.makeSetup() else { return }
        let program = try stageCMetalTestProgram(
            id: "test.current-lifecycle.\(mode.label)"
        )
        let brush = try await setup.compileBrush(definition: program.definition)
        try setup.renderer.activateDrawBrush(brush)
        let strokeToken = RendererOperationToken(rawValue: 120_001)
        try setup.renderer.beginStroke(
            token: strokeToken,
            sample: stageCAcceptanceSample(.began, x: 8, y: 32),
            style: depositionStyle(brush, compositeMode: .draw, diameter: 8)
        )
        try setup.renderer.appendStroke(
            token: strokeToken,
            sample: stageCAcceptanceSample(.moved, x: 56, y: 32)
        )
        try setup.renderer.requestStrokeCommit(
            token: strokeToken,
            sample: stageCAcceptanceSample(.ended, x: 56, y: 32)
        )
        _ = try await setup.renderer.finishCommitForHarness()
        let committed = try await setup.renderer.captureCommittedDocument()
        #expect(committed.storage.containsCurrentPaint)

        var clearReceipt: RasterMutationReceipt?
        setup.renderer.onOperationCompleted = {
            if case let .rasterSuccess(receipt) = $0 { clearReceipt = receipt }
        }
        try await setup.renderer.clearDocument(
            token: RendererOperationToken(rawValue: 120_002)
        )
        let cleared = try await setup.renderer.captureCommittedDocument()
        #expect(!cleared.storage.containsCurrentPaint)

        let history = try #require(clearReceipt)
        try await setup.renderer.restoreDocumentRevision(
            token: RendererOperationToken(rawValue: 120_003),
            revision: history.before
        )
        let restored = try await setup.renderer.captureCommittedDocument()
        #expect(restored.canvasSize == committed.canvasSize)
        #expect(
            restored.documentConfiguration == committed.documentConfiguration
        )
        #expect(restored.storage == committed.storage)
        #expect(
            restored.documentDomainLocked == committed.documentDomainLocked
        )
        #expect(
            restored.radialGeometryLocked == committed.radialGeometryLocked
        )

        let export = try await setup.renderer.exportFlattenedScene(
            pixelSize: setup.renderer.pixelSize,
            transparentBackground: true
        )
        #expect(export.pixelSize == setup.renderer.pixelSize)
        #expect(export.bgra8Bytes.contains { $0 != 0 })
        try await setup.renderer.releasePaintRevisions([
            history.before.id,
            history.after.id,
        ])
    }
}

enum StageCAcceptanceMode: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case periodic
    case plain
    case radial

    static let all = Array(allCases)
    var label: String { rawValue }
    var testDescription: String { rawValue }

    @MainActor
    func makeSetup() throws -> DepositionRendererSetup? {
        switch self {
        case .periodic:
            return try makeDepositionRendererSetup(tiling: .grid)
        case .plain:
            return try makeDepositionRendererSetup(finite: .plain)
        case .radial:
            return try makeDepositionRendererSetup(finite: .radial(
                RadialSymmetryConfiguration(
                    kind: .mandala,
                    rayCount: 8,
                    center: WorldPoint(x: 32, y: 32)
                )
            ))
        }
    }
}

private extension CommittedRasterStorage {
    var containsCurrentPaint: Bool {
        switch self {
        case let .singleRaster(bytes):
            return bytes.contains { $0 != 0 }
        case let .radialPages(pages):
            return pages.contains {
                $0.bgra8PremultipliedBytes.contains { $0 != 0 }
            }
        }
    }
}

private func stageCAcceptanceSample(
    _ phase: StrokePhase,
    x: Float,
    y: Float
) -> StrokeSample {
    .mouse(
        position: ScreenPoint(x: x, y: y),
        timestamp: 0,
        phase: phase
    )
}
