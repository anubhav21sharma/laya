import BrushFormat
import EditorCore
import Foundation
@testable import MetalRenderer
@testable import MetalRendererDiagnostics
import Metal
import PatternEngine
import Testing

private let correctiveFunctionalCanvasSize = PixelSize(
    width: 512,
    height: 512
)

@Suite("Brush corrective functional", .serialized)
struct BrushCorrectiveFunctionalTests {
    @Test
    func correctiveTraceCorpusFitsItsDedicatedCanvasWithoutClipping() {
        #expect(
            correctiveFunctionalCanvasSize
                == PixelSize(width: 512, height: 512)
        )
        for trace in StrokeTraceFixtures.corrective {
            for sample in trace.samples {
                #expect(
                    (32...480).contains(sample.position.x),
                    "\(trace.name) x"
                )
                #expect(
                    (32...480).contains(sample.position.y),
                    "\(trace.name) y"
                )
            }
        }
    }

    @Test
    func scalarReadbackMetricsMeasureKnownSupportWithoutRendererHelpers()
        throws
    {
        var pixels = [UInt8](repeating: 0, count: 12 * 8 * 4)
        for y in 2...4 {
            for x in 2...8 {
                pixels[(y * 12 + x) * 4 + 3] = 128
            }
        }

        let measurement = try BrushFunctionalMetrics.measure(
            bgra8: pixels,
            width: 12,
            height: 8,
            centerline: [
                ScreenPoint(x: 2, y: 3),
                ScreenPoint(x: 9, y: 3),
            ],
            nominalDiameter: 3,
            alphaThreshold: 1
        )

        #expect(measurement.changedPixelCount == 21)
        #expect(measurement.alphaSupportBounds == PixelBounds(
            minimumX: 2,
            minimumY: 2,
            maximumX: 8,
            maximumY: 4
        ))
        #expect(measurement.centerlineWidthP50 == 3)
        #expect(measurement.centerlineWidthP95 == 3)
        #expect(abs(measurement.alphaP50 - (128 / 255)) < 0.0001)
        #expect(abs(measurement.alphaP90 - (128 / 255)) < 0.0001)
        #expect(measurement.endpointRetreatPixels == 1)
        #expect(measurement.turnProtrusionPixels < 0.001)
        #expect(measurement.isolatedComponentCount == 0)
        #expect(
            try JSONDecoder().decode(
                BrushFunctionalMeasurement.self,
                from: JSONEncoder().encode(measurement)
            ) == measurement
        )
    }

    @Test
    func scalarReadbackNegativeControlsRejectMalformedAndExposeIslands()
        throws
    {
        #expect(throws: BrushFunctionalMetricsError.self) {
            _ = try BrushFunctionalMetrics.measure(
                bgra8: [0, 0, 0, 0],
                width: 2,
                height: 2,
                centerline: [ScreenPoint(x: 0, y: 0)],
                nominalDiameter: 1
            )
        }

        let blank = try BrushFunctionalMetrics.measure(
            bgra8: [UInt8](repeating: 0, count: 8 * 8 * 4),
            width: 8,
            height: 8,
            centerline: [
                ScreenPoint(x: 1, y: 3),
                ScreenPoint(x: 5, y: 3),
            ],
            nominalDiameter: 2
        )
        #expect(blank.changedPixelCount < 128)
        #expect(blank.alphaSupportBounds == nil)
        #expect(blank.centerlineWidthP50 < 4)

        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        pixels[(3 * 8 + 3) * 4 + 3] = 255
        pixels[(7 * 8 + 7) * 4 + 3] = 255
        let measurement = try BrushFunctionalMetrics.measure(
            bgra8: pixels,
            width: 8,
            height: 8,
            centerline: [
                ScreenPoint(x: 1, y: 3),
                ScreenPoint(x: 5, y: 3),
            ],
            nominalDiameter: 2
        )

        #expect(measurement.changedPixelCount == 2)
        #expect(measurement.isolatedComponentCount == 1)
        #expect(measurement.turnProtrusionPixels > 3)
    }

    @Test
    func scalarReadbackCounterexamplesDetectBoundsWidthAlphaAndRetreat()
        throws
    {
        let centerline = [
            ScreenPoint(x: 2, y: 3),
            ScreenPoint(x: 9, y: 3),
        ]
        let baseline = try BrushFunctionalMetrics.measure(
            bgra8: rectanglePixels(
                width: 12,
                height: 8,
                xRange: 2...8,
                yRange: 2...4,
                alpha: 128
            ),
            width: 12,
            height: 8,
            centerline: centerline,
            nominalDiameter: 3
        )

        var expandedBoundsPixels = rectanglePixels(
            width: 12,
            height: 8,
            xRange: 2...8,
            yRange: 2...4,
            alpha: 128
        )
        expandedBoundsPixels[(6 * 12 + 10) * 4 + 3] = 128
        let expandedBounds = try BrushFunctionalMetrics.measure(
            bgra8: expandedBoundsPixels,
            width: 12,
            height: 8,
            centerline: centerline,
            nominalDiameter: 3
        )
        #expect(expandedBounds.alphaSupportBounds == PixelBounds(
            minimumX: 2,
            minimumY: 2,
            maximumX: 10,
            maximumY: 6
        ))
        #expect(expandedBounds.alphaSupportBounds != baseline.alphaSupportBounds)

        let wider = try BrushFunctionalMetrics.measure(
            bgra8: rectanglePixels(
                width: 12,
                height: 8,
                xRange: 2...8,
                yRange: 1...5,
                alpha: 128
            ),
            width: 12,
            height: 8,
            centerline: centerline,
            nominalDiameter: 5
        )
        #expect(wider.centerlineWidthP50 == 5)
        #expect(wider.centerlineWidthP95 == 5)
        #expect(wider.centerlineWidthP50 != baseline.centerlineWidthP50)
        #expect(wider.centerlineWidthP95 != baseline.centerlineWidthP95)

        let fainter = try BrushFunctionalMetrics.measure(
            bgra8: rectanglePixels(
                width: 12,
                height: 8,
                xRange: 2...8,
                yRange: 2...4,
                alpha: 32
            ),
            width: 12,
            height: 8,
            centerline: centerline,
            nominalDiameter: 3
        )
        #expect(abs(fainter.alphaP50 - (32 / 255)) < 0.0001)
        #expect(abs(fainter.alphaP90 - (32 / 255)) < 0.0001)
        #expect(fainter.alphaP50 != baseline.alphaP50)
        #expect(fainter.alphaP90 != baseline.alphaP90)

        let shortened = try BrushFunctionalMetrics.measure(
            bgra8: rectanglePixels(
                width: 12,
                height: 8,
                xRange: 2...6,
                yRange: 2...4,
                alpha: 128
            ),
            width: 12,
            height: 8,
            centerline: centerline,
            nominalDiameter: 3
        )
        #expect(shortened.endpointRetreatPixels == 3)
        #expect(
            shortened.endpointRetreatPixels
                > baseline.endpointRetreatPixels
        )
    }

    @Test
    @MainActor
    func requiredMetalValidationRejectsMissingDevice() {
        #expect(throws: RequiredFunctionalMetalError.deviceUnavailable) {
            _ = try requiredMetalDevice(nil)
        }
    }

    @Test
    @MainActor
    func tenSecondTechnicalInkRetainsOnlyItsBoundedCorrectionTail()
        async throws
    {
        let capture = try await render(
            entry: ProfessionalBrushCatalog.technicalInk,
            trace: StrokeTraceFixtures.correctiveTechnicalInkTenSecondLine,
            diameter: 40,
            baselineStem: "technical-ink-ten-second"
        )

        #expect(
            capture.maximumRetainedDabCount > 0,
            "bounded correction retained no replay tail"
        )
        #expect(
            capture.maximumRetainedDabCount
                <= BrushRecipePolicy.replayTailLimits.maximumDabs,
            "bounded correction retained \(capture.maximumRetainedDabCount) dabs"
        )
    }

    @Test
    @MainActor
    func fastReleaseTechnicalInkKeepsVisibleEndpointAtPointerUp()
        async throws
    {
        let capture = try await render(
            entry: ProfessionalBrushCatalog.technicalInk,
            trace: StrokeTraceFixtures.correctiveTechnicalInkFastRelease,
            diameter: 40,
            baselineStem: "technical-ink-fast-release"
        )
        let measurement = try measure(
            capture,
            trace: StrokeTraceFixtures.correctiveTechnicalInkFastRelease,
            nominalDiameter: 40,
            alphaThreshold: 16
        )

        #expect(
            measurement.endpointRetreatPixels <= 1,
            "visible endpoint retreated \(measurement.endpointRetreatPixels) px"
        )
    }

    @Test
    @MainActor
    func fortyPixelGraphiteSupportMatchesNominalCursorFootprint()
        async throws
    {
        let capture = try await render(
            entry: ProfessionalBrushCatalog.graphitePencil,
            trace: StrokeTraceFixtures.correctiveGraphiteFortyPixelLine,
            diameter: 40,
            baselineStem: "graphite-forty-pixel"
        )
        let measurement = try measure(
            capture,
            trace: StrokeTraceFixtures.correctiveGraphiteFortyPixelLine,
            nominalDiameter: 40,
            alphaThreshold: 8
        )

        #expect(
            measurement.centerlineWidthP50 >= 20,
            "40 px cursor produced p50 support \(measurement.centerlineWidthP50) px"
        )
        #expect(
            measurement.centerlineWidthP95 >= 24,
            "40 px cursor produced p95 support \(measurement.centerlineWidthP95) px"
        )
    }

    @Test
    @MainActor
    func neutralPressureCharcoalProducesVisibleContinuousSupport()
        async throws
    {
        let capture = try await render(
            entry: ProfessionalBrushCatalog.naturalCharcoal,
            trace: StrokeTraceFixtures.correctiveCharcoalNeutralPressureLine,
            diameter: 40,
            baselineStem: "charcoal-neutral-pressure"
        )
        let measurement = try measure(
            capture,
            trace: StrokeTraceFixtures.correctiveCharcoalNeutralPressureLine,
            nominalDiameter: 40,
            alphaThreshold: 8
        )

        #expect(
            measurement.changedPixelCount >= 512,
            "neutral Charcoal changed only \(measurement.changedPixelCount) pixels"
        )
        #expect(
            measurement.alphaP50 >= 0.10,
            "neutral Charcoal median alpha was \(measurement.alphaP50)"
        )
    }

    @Test
    @MainActor
    func chiselTurnsStayInsidePrincipalSupportEnvelopeWithoutIslands()
        async throws
    {
        let fixtures = [
            (
                StrokeTraceFixtures.correctiveChiselRightAngle,
                "chisel-right-angle"
            ),
            (
                StrokeTraceFixtures.correctiveChiselCircle,
                "chisel-circle"
            ),
        ]
        for (trace, stem) in fixtures {
            let capture = try await render(
                entry: ProfessionalBrushCatalog.chiselMarker,
                trace: trace,
                diameter: 40,
                baselineStem: stem
            )
            let measurement = try measure(
                capture,
                trace: trace,
                nominalDiameter: 40,
                alphaThreshold: 8
            )
            #expect(
                measurement.changedPixelCount >= 128,
                "\(trace.name) changed only \(measurement.changedPixelCount) pixels"
            )
            #expect(
                measurement.alphaSupportBounds != nil,
                "\(trace.name) has no visible alpha support"
            )
            #expect(
                measurement.centerlineWidthP50 >= 4,
                "\(trace.name) p50 width was \(measurement.centerlineWidthP50) px"
            )
            #expect(
                measurement.turnProtrusionPixels <= 4,
                "\(trace.name) protruded \(measurement.turnProtrusionPixels) px"
            )
            #expect(
                measurement.isolatedComponentCount == 0,
                "\(trace.name) had \(measurement.isolatedComponentCount) isolated components"
            )
        }
    }
}

private enum RequiredFunctionalMetalError: Error, Equatable {
    case deviceUnavailable
    case commandQueueUnavailable
}

@MainActor
private func requiredMetalDevice(
    _ device: (any MTLDevice)?
) throws -> any MTLDevice {
    guard let device else {
        throw RequiredFunctionalMetalError.deviceUnavailable
    }
    return device
}

private struct FunctionalRasterCapture {
    let width: Int
    let height: Int
    let committedBGRA8: [UInt8]
    let maximumRetainedDabCount: Int
}

private extension BrushCorrectiveFunctionalTests {
    func rectanglePixels(
        width: Int,
        height: Int,
        xRange: ClosedRange<Int>,
        yRange: ClosedRange<Int>,
        alpha: UInt8
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in yRange {
            for x in xRange {
                pixels[(y * width + x) * 4 + 3] = alpha
            }
        }
        return pixels
    }

    @MainActor
    func render(
        entry: ProfessionalBrushEntry,
        trace: StrokeTraceFixture,
        diameter: Float,
        baselineStem: String
    ) async throws -> FunctionalRasterCapture {
        let device = try requiredMetalDevice(MTLCreateSystemDefaultDevice())
        guard let commandQueue = device.makeCommandQueue() else {
            throw RequiredFunctionalMetalError.commandQueueUnavailable
        }
        let canvasSize = correctiveFunctionalCanvasSize
        let library = try depositionHarnessTestLibrary(device: device)
        let profile = try BrushDeviceProfile(
            registryID: device.registryID,
            recommendedWorkingSetBytes:
                max(device.recommendedMaxWorkingSetSize, 64 * 1_024 * 1_024),
            maximumWorkingTextureDimension: 4_096,
            brushCacheBudgetBytes: 64 * 1_024 * 1_024,
            targetFramesPerSecond: 120
        )
        let compiler = BrushCompiler(
            device: device,
            commandQueue: commandQueue,
            profile: profile,
            pipelinePreparing: DepositionPipelineLibrary(
                device: device,
                library: library
            ),
            testHooks: .none
        )
        let package = try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: entry.definition,
            resourceData: [:]
        )
        let brush = try await compiler.compileAndActivate(package: package)
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(
                width: Float(canvasSize.width),
                height: Float(canvasSize.height)
            ),
            configuration: TilingCanvasConfiguration(
                pixelSize: canvasSize,
                tiling: .grid
            )
        )
        try renderer.activateDrawBrush(brush)
        let token = RendererOperationToken(rawValue: 0xC0_22)
        let style = StrokeRenderStyle(
            color: .black,
            diameter: diameter,
            compositeMode: .draw,
            eraserStrength: 1,
            program: brush.program,
            renderIdentity: brush.renderIdentity,
            seed: 0xC0_22
        )
        try renderer.beginStroke(
            token: token,
            sample: trace.samples[0],
            style: style
        )
        var maximumRetainedDabCount = 0
        var latestFrame = try await drain(
            renderer,
            maximumRetainedDabCount: &maximumRetainedDabCount
        )
        for sample in trace.samples.dropFirst().dropLast() {
            try renderer.appendStroke(token: token, sample: sample)
            latestFrame = try await drain(
                renderer,
                maximumRetainedDabCount: &maximumRetainedDabCount
            )
        }
        let beforeRelease = latestFrame.texture
        let beforeReleaseBytes = textureBytes(beforeRelease)

        try renderer.requestStrokeCommit(
            token: token,
            sample: trace.samples.last!
        )
        let afterRelease = try await drain(
            renderer,
            maximumRetainedDabCount: &maximumRetainedDabCount
        ).texture
        let afterReleaseBytes = textureBytes(afterRelease)
        _ = try await renderer.finishCommitForHarness()
        let committed = try await renderer.captureCommittedDocument()
        guard case let .singleRaster(committedBytes) = committed.storage else {
            throw MetalRendererError.committedSnapshotIncompatible
        }

        try writeFailureBaseline(
            beforeReleaseBytes,
            width: canvasSize.width,
            height: canvasSize.height,
            stem: "\(baselineStem)-before-release"
        )
        try writeFailureBaseline(
            afterReleaseBytes,
            width: canvasSize.width,
            height: canvasSize.height,
            stem: "\(baselineStem)-after-release"
        )
        try writeFailureBaseline(
            committedBytes,
            width: canvasSize.width,
            height: canvasSize.height,
            stem: "\(baselineStem)-committed"
        )

        return FunctionalRasterCapture(
            width: canvasSize.width,
            height: canvasSize.height,
            committedBGRA8: committedBytes,
            maximumRetainedDabCount: maximumRetainedDabCount
        )
    }

    @MainActor
    func drain(
        _ renderer: GridRenderer,
        maximumRetainedDabCount: inout Int
    ) async throws -> RenderedFrame {
        var frame: RenderedFrame?
        repeat {
            let result = try await renderer.flushPendingLiveForHarness()
            frame = result.frame
            maximumRetainedDabCount = max(
                maximumRetainedDabCount,
                result.replayRetention.retainedDabCount
            )
        } while !renderer.harnessScheduledAuthoritativeRecords.isEmpty
            || !renderer.harnessScheduledPredictedRecords.isEmpty
        guard let frame else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        return frame
    }

    func measure(
        _ capture: FunctionalRasterCapture,
        trace: StrokeTraceFixture,
        nominalDiameter: Float,
        alphaThreshold: UInt8
    ) throws -> BrushFunctionalMeasurement {
        try BrushFunctionalMetrics.measure(
            bgra8: capture.committedBGRA8,
            width: capture.width,
            height: capture.height,
            centerline: trace.samples.map(\.position),
            nominalDiameter: nominalDiameter,
            alphaThreshold: alphaThreshold
        )
    }

    @MainActor
    func textureBytes(_ texture: any MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * texture.height
        )
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
    }

    func writeFailureBaseline(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        stem: String
    ) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/brush-corrective-baseline")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try PNGWriter.writeBGRA(
            bytes,
            pixelSize: PixelSize(width: width, height: height),
            to: root.appendingPathComponent("2026-08-01-\(stem).png")
        )
    }
}
