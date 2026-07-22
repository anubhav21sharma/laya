import CShaderTypes
import Darwin
import Foundation
import Metal
import PatternEngine
import simd

public struct HarnessRunResult: Equatable, Sendable {
    public let imageURL: URL
    public let benchmarkURL: URL
    public let benchmark: BenchmarkRecord
    public let artifactURLs: [URL]

    public init(
        imageURL: URL,
        benchmarkURL: URL,
        benchmark: BenchmarkRecord,
        artifactURLs: [URL]
    ) {
        self.imageURL = imageURL
        self.benchmarkURL = benchmarkURL
        self.benchmark = benchmark
        self.artifactURLs = artifactURLs
    }
}

struct HarnessRenderConfiguration: Equatable, Sendable {
    let pixelSize: PixelSize
    let tiling: TilingKind
    let diagnosticMode: HarnessDiagnosticMode
}

struct TranslationHarnessInput: Equatable, Sendable {
    let center: WorldPoint
    let tiling: TilingKind
    let capturesPhasedGridLines: Bool
}

struct TaskSevenHarnessInput: Equatable, Sendable {
    let brushToWorld: Affine2D
    let oracleFootprint: OracleFootprint
    let stampFootprint: StampFootprint
    let radius: Float
    let diagnosticMode: HarnessDiagnosticMode
    let requiresDistantCells: Bool
}

struct TaskEightNoncentralInput: Equatable, Sendable {
    let tileSize: PixelSize
    let central: WorldPoint
    let visible: WorldPoint
    let visibleCell: CellIndex
}

struct HarnessFragmentAudit: Equatable, Sendable {
    let projectedFragmentCount: Int
    let maximumClipPlaneCount: Int
    let instanceBytes: Int
}

struct HarnessInstanceIdentityAudit: Equatable, Sendable {
    let newlyEncodedInstanceCount: Int
    let restampedInstanceCount: Int
    let encodedHighWater: UInt64
}

struct HarnessFragmentMeasurements {
    var totalProjectedFragmentCount = 0
    var maximumFragmentsPerFootprint = 0
    var maximumClipPlaneCount = 0
    var totalInstanceBytes = 0

    mutating func append(_ audit: HarnessFragmentAudit) {
        totalProjectedFragmentCount += audit.projectedFragmentCount
        maximumFragmentsPerFootprint = max(
            maximumFragmentsPerFootprint,
            audit.projectedFragmentCount
        )
        maximumClipPlaneCount = max(
            maximumClipPlaneCount,
            audit.maximumClipPlaneCount
        )
        totalInstanceBytes += audit.instanceBytes
    }
}

private struct FixedPointCoverageKey: Hashable {
    let centerX: UInt32
    let centerY: UInt32
    let xAxisLength: UInt32
    let yAxisLength: UInt32
}

struct HarnessOracleMetrics: Codable, Equatable, Sendable {
    let oracleHoleCount: Int
    let oraclePhantomCount: Int
    let oracleMaximumDelta: Int
    let transformMismatchCount: Int
    let duplicateFixedPointWriteCount: Int?
    let coordinateContinuityMismatchCount: Int?

    init(
        oracleHoleCount: Int,
        oraclePhantomCount: Int,
        oracleMaximumDelta: Int,
        transformMismatchCount: Int,
        duplicateFixedPointWriteCount: Int? = nil,
        coordinateContinuityMismatchCount: Int? = nil
    ) {
        self.oracleHoleCount = oracleHoleCount
        self.oraclePhantomCount = oraclePhantomCount
        self.oracleMaximumDelta = oracleMaximumDelta
        self.transformMismatchCount = transformMismatchCount
        self.duplicateFixedPointWriteCount = duplicateFixedPointWriteCount
        self.coordinateContinuityMismatchCount =
            coordinateContinuityMismatchCount
    }

    static func encode(_ metrics: HarnessOracleMetrics) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(metrics)
    }
}

public enum HarnessRunError: Error, Equatable, LocalizedError {
    case processMetricsUnavailable
    case pixelMismatch(
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )
    case gridPixelMismatch(
        sceneName: String,
        channel: HarnessPixelChannel,
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )
    case missingArtifact(
        sceneName: String,
        channel: HarnessPixelChannel
    )
    case structuralMismatch(
        sceneName: String,
        metric: HarnessStructuralMetric,
        expectedRelation: HarnessRelation,
        expectedValue: Int,
        actualValue: Int
    )
    case tilingPixelMismatch(
        sceneName: String,
        tiling: TilingKind,
        cell: CellIndex?,
        channel: HarnessPixelChannel,
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )
    case tilingStructuralMismatch(
        sceneName: String,
        tiling: TilingKind,
        cell: CellIndex?,
        metric: HarnessStructuralMetric,
        expectedRelation: HarnessRelation,
        expectedValue: Int,
        actualValue: Int
    )
    case missingStructuralMetric(
        sceneName: String,
        metric: HarnessStructuralMetric
    )
    case counterInvariant(sceneName: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .processMetricsUnavailable:
            "Peak resident-memory measurement is unavailable."
        case let .pixelMismatch(x, y, expected, actual, tolerance):
            "Pixel mismatch at (\(x), \(y)): expected \(expected), actual \(actual), tolerance \(tolerance)."
        case let .gridPixelMismatch(
            sceneName,
            channel,
            x,
            y,
            expected,
            actual,
            tolerance
        ):
            "Grid scene '\(sceneName)' channel \(channel.rawValue) pixel mismatch at (\(x), \(y)): expected \(expected), actual \(actual), tolerance \(tolerance)."
        case let .missingArtifact(sceneName, channel):
            "Grid scene '\(sceneName)' is missing artifact channel \(channel.rawValue)."
        case let .structuralMismatch(
            sceneName,
            metric,
            relation,
            expected,
            actual
        ):
            "Grid scene '\(sceneName)' structural mismatch \(metric.rawValue): expected \(relation.rawValue) \(expected), actual \(actual)."
        case let .tilingPixelMismatch(
            sceneName,
            tiling,
            cell,
            channel,
            x,
            y,
            expected,
            actual,
            tolerance
        ):
            "Tiling scene '\(sceneName)' tiling \(tiling) cell \(Self.cellDescription(cell)) channel \(channel.rawValue) coordinate \(x),\(y): expected \(expected), actual \(actual), tolerance \(tolerance)."
        case let .tilingStructuralMismatch(
            sceneName,
            tiling,
            cell,
            metric,
            relation,
            expected,
            actual
        ):
            "Tiling scene '\(sceneName)' tiling \(tiling) cell \(Self.cellDescription(cell)) metric \(metric.rawValue): expected \(relation.rawValue) \(expected), actual \(actual)."
        case let .missingStructuralMetric(sceneName, metric):
            "Grid scene '\(sceneName)' cannot measure structural metric \(metric.rawValue)."
        case let .counterInvariant(sceneName, message):
            "Grid scene '\(sceneName)' counter invariant failed: \(message)"
        }
    }

    private static func cellDescription(_ cell: CellIndex?) -> String {
        guard let cell else {
            return "none"
        }
        return "\(cell.column),\(cell.row)"
    }
}

@MainActor
public final class HarnessRunner {
    static let defaultStrokeStyle = StrokeRenderStyle(
        color: .black,
        diameter: GridCanvasContract.brushRadius * 2,
        compositeMode: .draw,
        eraserStrength: 1
    )

    nonisolated static func translationInput(
        for program: TilingHarnessProgram
    ) -> TranslationHarnessInput? {
        switch program {
        case .generalizedGrid:
            TranslationHarnessInput(
                center: WorldPoint(x: -2, y: -2),
                tiling: .grid,
                capturesPhasedGridLines: false
            )
        case .halfDropInterior:
            TranslationHarnessInput(
                center: WorldPoint(x: 432, y: 144),
                tiling: .halfDrop,
                capturesPhasedGridLines: true
            )
        case .halfDropEdge:
            TranslationHarnessInput(
                center: WorldPoint(x: 288, y: 96),
                tiling: .halfDrop,
                capturesPhasedGridLines: true
            )
        case .halfDropCorner:
            TranslationHarnessInput(
                center: WorldPoint(x: 288, y: 288),
                tiling: .halfDrop,
                capturesPhasedGridLines: true
            )
        case .brickTranspose:
            TranslationHarnessInput(
                center: WorldPoint(x: 144, y: 192),
                tiling: .brick,
                capturesPhasedGridLines: true
            )
        default:
            nil
        }
    }

    nonisolated static func taskSevenInput(
        for program: TilingHarnessProgram
    ) -> TaskSevenHarnessInput? {
        switch program {
        case .mirrorX:
            return asymmetricTaskSevenInput(
                center: SIMD2(256, 96),
                diagnosticMode: .asymmetricCoverage
            )
        case .mirrorY:
            return asymmetricTaskSevenInput(
                center: SIMD2(96, 256),
                diagnosticMode: .asymmetricCoverage
            )
        case .mirrorXY:
            return asymmetricTaskSevenInput(
                center: SIMD2(256, 256),
                diagnosticMode: .asymmetricCoverage
            )
        case .rotationalGenerator, .rotationalOrientation:
            return asymmetricTaskSevenInput(
                center: SIMD2(64, 80),
                diagnosticMode: .asymmetricCoverage
            )
        case .rotationalFixedPoint:
            return hardRoundTaskSevenInput(
                center: SIMD2(128, 128),
                radius: 10
            )
        case .largeFootprint:
            return hardRoundTaskSevenInput(
                center: SIMD2(0, 0),
                radius: 256,
                requiresDistantCells: true
            )
        case .asymmetricFootprint:
            let angle: Float = 0.37
            let scale: Float = 40
            return asymmetricTaskSevenInput(
                brushToWorld: Affine2D(
                    xAxis: SIMD2(cos(angle), sin(angle)) * scale,
                    yAxis: SIMD2(-sin(angle), cos(angle)) * scale,
                    translation: SIMD2(250, 128)
                ),
                diagnosticMode: .asymmetricCoverage
            )
        case .canonicalCoordinateContinuity:
            return asymmetricTaskSevenInput(
                center: SIMD2(288, 96),
                diagnosticMode: .canonicalCoordinates
            )
        case .brushLocalCoordinateContinuity:
            return asymmetricTaskSevenInput(
                center: SIMD2(256, 256),
                diagnosticMode: .brushLocalCoordinates
            )
        default:
            return nil
        }
    }

    nonisolated static func taskEightNoncentralInput(
        for tiling: TilingKind
    ) -> TaskEightNoncentralInput {
        switch tiling {
        case .grid:
            TaskEightNoncentralInput(
                tileSize: PixelSize(width: 256, height: 256),
                central: WorldPoint(x: 64, y: 64),
                visible: WorldPoint(x: 320, y: 64),
                visibleCell: CellIndex(column: 1, row: 0)
            )
        case .halfDrop:
            TaskEightNoncentralInput(
                tileSize: PixelSize(width: 288, height: 192),
                central: WorldPoint(x: 64, y: 64),
                visible: WorldPoint(x: 352, y: 160),
                visibleCell: CellIndex(column: 1, row: 0)
            )
        case .brick:
            TaskEightNoncentralInput(
                tileSize: PixelSize(width: 288, height: 192),
                central: WorldPoint(x: 64, y: 64),
                visible: WorldPoint(x: 208, y: 256),
                visibleCell: CellIndex(column: 0, row: 1)
            )
        case .mirrorX:
            TaskEightNoncentralInput(
                tileSize: PixelSize(width: 256, height: 256),
                central: WorldPoint(x: 64, y: 64),
                visible: WorldPoint(x: 448, y: 64),
                visibleCell: CellIndex(column: 1, row: 0)
            )
        case .mirrorY:
            TaskEightNoncentralInput(
                tileSize: PixelSize(width: 256, height: 256),
                central: WorldPoint(x: 64, y: 64),
                visible: WorldPoint(x: 64, y: 448),
                visibleCell: CellIndex(column: 0, row: 1)
            )
        case .mirrorXY:
            TaskEightNoncentralInput(
                tileSize: PixelSize(width: 256, height: 256),
                central: WorldPoint(x: 64, y: 64),
                visible: WorldPoint(x: 448, y: 448),
                visibleCell: CellIndex(column: 1, row: 1)
            )
        case .rotational:
            TaskEightNoncentralInput(
                tileSize: PixelSize(width: 256, height: 256),
                central: WorldPoint(x: 64, y: 80),
                visible: WorldPoint(x: 320, y: 80),
                visibleCell: CellIndex(column: 1, row: 0)
            )
        }
    }

    nonisolated static var taskEightRectangularCenter: WorldPoint {
        WorldPoint(x: 318, y: 190)
    }

    nonisolated static var taskEightMetadataCenter: WorldPoint {
        WorldPoint(x: 64, y: 64)
    }

    nonisolated static var taskEightLiveCommitPoints: [WorldPoint] {
        [
            WorldPoint(x: 278, y: 90),
            WorldPoint(x: 298, y: 110),
        ]
    }

    nonisolated static var taskEightLongStrokePoints: [WorldPoint] {
        (0...400).map { index in
            WorldPoint(
                x: index.isMultiple(of: 2) ? 64 : 96,
                y: 96
            )
        }
    }

    nonisolated static func differingByteCount(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Int {
        guard lhs.count == rhs.count else {
            return max(lhs.count, rhs.count)
        }
        return zip(lhs, rhs).reduce(0) {
            $0 + ($1.0 == $1.1 ? 0 : 1)
        }
    }

    nonisolated static func maximumByteDelta(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Int {
        guard lhs.count == rhs.count else {
            return 255
        }
        return zip(lhs, rhs).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
    }

    nonisolated static func previewCommitViolationCount(
        _ live: [UInt8],
        _ committed: [UInt8],
        tolerance: UInt8
    ) -> Int {
        guard live.count == committed.count else {
            return max(live.count, committed.count)
        }
        return zip(live, committed).reduce(0) {
            $0 + (abs(Int($1.0) - Int($1.1)) > Int(tolerance) ? 1 : 0)
        }
    }

    nonisolated static func auditFragmentBatch(
        sceneName: String,
        fragments: [CellFragment],
        repeatedFragments: [CellFragment],
        pendingCapacity: Int = GridCanvasContract.pendingCapacity
    ) throws -> HarnessFragmentAudit {
        guard fragments == repeatedFragments else {
            throw HarnessRunError.counterInvariant(
                sceneName: sceneName,
                message: "fragment order changed across identical projection runs"
            )
        }
        guard fragments.count <= pendingCapacity else {
            throw HarnessRunError.counterInvariant(
                sceneName: sceneName,
                message: "generated \(fragments.count) fragments beyond the fixed \(pendingCapacity) pending-instance capacity"
            )
        }
        let maximumClipPlaneCount = fragments.lazy
            .map(\.brushClip.halfPlanes.count)
            .max() ?? 0
        guard maximumClipPlaneCount <= 4 else {
            throw HarnessRunError.counterInvariant(
                sceneName: sceneName,
                message: "generated fragment contains \(maximumClipPlaneCount) clip planes instead of at most 4"
            )
        }
        let (instanceBytes, overflow) = fragments.count
            .multipliedReportingOverflow(
                by: MemoryLayout<PatternProjectedStampInstance>.stride
            )
        guard !overflow else {
            throw HarnessRunError.counterInvariant(
                sceneName: sceneName,
                message: "projected instance-byte count overflowed"
            )
        }
        return HarnessFragmentAudit(
            projectedFragmentCount: fragments.count,
            maximumClipPlaneCount: maximumClipPlaneCount,
            instanceBytes: instanceBytes
        )
    }

    nonisolated static func auditEncodedInstanceIdentityRanges(
        sceneName: String,
        previousEncodedHighWater: UInt64,
        emittedHighWater: UInt64,
        encodedIdentityRanges: [Range<UInt64>]
    ) throws -> HarnessInstanceIdentityAudit {
        guard emittedHighWater >= previousEncodedHighWater else {
            throw HarnessRunError.counterInvariant(
                sceneName: sceneName,
                message: "emitted projected-instance identity moved backward"
            )
        }
        var encodedHighWater = previousEncodedHighWater
        var newlyEncodedInstanceCount = 0
        for range in encodedIdentityRanges {
            guard range.lowerBound == encodedHighWater else {
                throw HarnessRunError.counterInvariant(
                    sceneName: sceneName,
                    message: "encoded projected identity range \(range) did not begin at expected high-water \(encodedHighWater)"
                )
            }
            guard
                !range.isEmpty,
                range.upperBound <= emittedHighWater
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: sceneName,
                    message: "encoded projected identity range \(range) exceeded emitted high-water \(emittedHighWater)"
                )
            }
            newlyEncodedInstanceCount += range.count
            encodedHighWater = range.upperBound
        }
        guard encodedHighWater == emittedHighWater else {
            throw HarnessRunError.counterInvariant(
                sceneName: sceneName,
                message: "encoded projected high-water \(encodedHighWater) did not reach emitted high-water \(emittedHighWater)"
            )
        }
        return HarnessInstanceIdentityAudit(
            newlyEncodedInstanceCount: newlyEncodedInstanceCount,
            restampedInstanceCount: 0,
            encodedHighWater: encodedHighWater
        )
    }

    nonisolated static func performLongStrokeProductionThenAudit<
        Value,
        Measurement
    >(
        production: () throws -> (
            value: Value,
            measurement: Measurement
        ),
        audit: (Value) throws -> Void
    ) rethrows -> (value: Value, measurement: Measurement) {
        let result = try production()
        try audit(result.value)
        return result
    }

    nonisolated static func configuration(
        for scene: HarnessScene
    ) -> HarnessRenderConfiguration {
        HarnessRenderConfiguration(
            pixelSize: PixelSize(
                width: scene.tileWidth ?? Int(GridCanvasContract.tileSize),
                height: scene.tileHeight ?? Int(GridCanvasContract.tileSize)
            ),
            tiling: scene.tiling ?? .grid,
            diagnosticMode: scene.diagnosticMode ?? .hardRound
        )
    }

    private nonisolated static func asymmetricTaskSevenInput(
        center: SIMD2<Float>,
        diagnosticMode: HarnessDiagnosticMode
    ) -> TaskSevenHarnessInput {
        asymmetricTaskSevenInput(
            brushToWorld: Affine2D(
                xAxis: SIMD2(40, 0),
                yAxis: SIMD2(0, 40),
                translation: center
            ),
            diagnosticMode: diagnosticMode
        )
    }

    private nonisolated static func asymmetricTaskSevenInput(
        brushToWorld: Affine2D,
        diagnosticMode: HarnessDiagnosticMode
    ) -> TaskSevenHarnessInput {
        let radius = max(
            simd_length(brushToWorld.xAxis),
            simd_length(brushToWorld.yAxis)
        )
        return TaskSevenHarnessInput(
            brushToWorld: brushToWorld,
            oracleFootprint: .asymmetricTriangle,
            stampFootprint: StampFootprint(
                brushToWorld: brushToWorld,
                localBounds: AxisAlignedRect(
                    minimum: SIMD2(-0.75, -0.60),
                    maximum: SIMD2(0.85, 0.90)
                ),
                coverageSymmetry: .oriented
            ),
            radius: radius,
            diagnosticMode: diagnosticMode,
            requiresDistantCells: false
        )
    }

    private nonisolated static func hardRoundTaskSevenInput(
        center: SIMD2<Float>,
        radius: Float,
        requiresDistantCells: Bool = false
    ) -> TaskSevenHarnessInput {
        let brushToWorld = Affine2D(
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(0, 1),
            translation: center
        )
        return TaskSevenHarnessInput(
            brushToWorld: brushToWorld,
            oracleFootprint: .hardRound(radius: radius),
            stampFootprint: StampFootprint(
                brushToWorld: Affine2D(
                    xAxis: SIMD2(radius, 0),
                    yAxis: SIMD2(0, radius),
                    translation: center
                ),
                localBounds: AxisAlignedRect(
                    minimum: SIMD2(-1, -1),
                    maximum: SIMD2(1, 1)
                ),
                coverageSymmetry: .halfTurnInvariant
            ),
            radius: radius,
            diagnosticMode: .hardRound,
            requiresDistantCells: requiresDistantCells
        )
    }

    nonisolated static func hardRoundFragments(
        at world: WorldPoint,
        radius requestedRadius: Float,
        configuration: HarnessRenderConfiguration
    ) -> [CellFragment] {
        let tileSize = PatternSize(
            width: Float(configuration.pixelSize.width),
            height: Float(configuration.pixelSize.height)
        )
        let radius = TilingProjection.clampedRadius(
            requested: requestedRadius,
            tileSize: tileSize
        )
        let footprint = StampFootprint(
            brushToWorld: Affine2D(
                xAxis: SIMD2(radius, 0),
                yAxis: SIMD2(0, radius),
                translation: world.simd
            ),
            localBounds: AxisAlignedRect(
                minimum: SIMD2(-1, -1),
                maximum: SIMD2(1, 1)
            ),
            coverageSymmetry: .halfTurnInvariant
        )
        return TilingProjection.fragments(
            for: footprint,
            using: TilingStrategy(
                kind: configuration.tiling,
                tileSize: tileSize
            )
        )
    }

    nonisolated static func repeatedFragments(
        for footprint: StampFootprint,
        configuration: HarnessRenderConfiguration
    ) -> [CellFragment] {
        TilingProjection.fragments(
            for: footprint,
            using: TilingStrategy(
                kind: configuration.tiling,
                tileSize: PatternSize(
                    width: Float(configuration.pixelSize.width),
                    height: Float(configuration.pixelSize.height)
                )
            )
        )
    }

    nonisolated static func appendFragmentAudit(
        sceneName: String,
        fragments: [CellFragment],
        repeatedFragments: [CellFragment],
        into measurements: inout HarnessFragmentMeasurements
    ) throws {
        measurements.append(
            try auditFragmentBatch(
                sceneName: sceneName,
                fragments: fragments,
                repeatedFragments: repeatedFragments
            )
        )
    }

    nonisolated static func auditInterpolatedHardRoundStroke(
        sceneName: String,
        points: [WorldPoint],
        configuration: HarnessRenderConfiguration,
        into measurements: inout HarnessFragmentMeasurements
    ) throws -> Int {
        guard let first = points.first, let last = points.last else {
            throw HarnessRunError.counterInvariant(
                sceneName: sceneName,
                message: "interactive projection audit has no points"
            )
        }
        let initialTotal = measurements.totalProjectedFragmentCount
        var interpolator = CentripetalCatmullRomStrokeInterpolator(
            radius: GridCanvasContract.brushRadius
        )
        let record: (WorldPoint) throws -> Void = { point in
            let fragments = hardRoundFragments(
                at: point,
                radius: GridCanvasContract.brushRadius,
                configuration: configuration
            )
            try appendFragmentAudit(
                sceneName: sceneName,
                fragments: fragments,
                repeatedFragments: hardRoundFragments(
                    at: point,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &measurements
            )
        }
        try interpolator.begin(at: first, emit: record)
        try interpolator.finish(at: last, emit: record)
        return measurements.totalProjectedFragmentCount - initialTotal
    }

    nonisolated static func diagnosticWire(
        for mode: HarnessDiagnosticMode
    ) -> UInt32? {
        switch mode {
        case .hardRound:
            nil
        case .asymmetricCoverage:
            PatternDiagnosticWireAsymmetricCoverage
        case .canonicalCoordinates:
            PatternDiagnosticWireCanonicalCoordinates
        case .brushLocalCoordinates:
            PatternDiagnosticWireBrushLocalCoordinates
        }
    }

    nonisolated static func productionCoverage(
        fromBGRA bytes: [UInt8],
        pixelSize: PixelSize
    ) -> OracleCoverage {
        let pixelCount = pixelSize.width * pixelSize.height
        precondition(
            bytes.count == pixelCount * 4,
            "Production BGRA byte count must equal pixel area times four"
        )
        var coverage = [UInt8](repeating: 0, count: pixelCount)
        for pixelIndex in 0..<pixelCount {
            coverage[pixelIndex] = bytes[pixelIndex * 4 + 3] >= 128
                ? 255
                : 0
        }
        return OracleCoverage(pixelSize: pixelSize, bytes: coverage)
    }

    nonisolated static func compareOracleCoverage(
        expected: OracleCoverage,
        productionBGRA: [UInt8]
    ) -> CoverageComparison {
        let actual = productionCoverage(
            fromBGRA: productionBGRA,
            pixelSize: expected.pixelSize
        )
        return TilingCoverageOracle.compare(
            expected: expected,
            actual: actual,
            boundaryTolerance: 1
        )
    }

    nonisolated static func coordinateContinuityMismatchCount(
        productionBGRA: [UInt8],
        oracleBGRA: [UInt8],
        usesCircularRGDistance: Bool
    ) -> Int {
        precondition(
            productionBGRA.count == oracleBGRA.count
                && productionBGRA.count.isMultiple(of: 4),
            "Coordinate comparison requires equal BGRA buffers"
        )
        var mismatchCount = 0
        for offset in stride(
            from: 0,
            to: productionBGRA.count,
            by: 4
        ) {
            let productionCovered = productionBGRA[offset + 3] > 0
            let oracleCovered = oracleBGRA[offset + 3] > 0
            guard productionCovered || oracleCovered else {
                continue
            }
            guard productionCovered && oracleCovered else {
                mismatchCount += 1
                continue
            }

            let redDistance = channelDistance(
                productionBGRA[offset + 2],
                oracleBGRA[offset + 2],
                circular: usesCircularRGDistance
            )
            let greenDistance = channelDistance(
                productionBGRA[offset + 1],
                oracleBGRA[offset + 1],
                circular: usesCircularRGDistance
            )
            if redDistance > 1 || greenDistance > 1 {
                mismatchCount += 1
            }
        }
        return mismatchCount
    }

    nonisolated static func displayFoldMismatchCount(
        productionScreenBGRA: [UInt8],
        canonicalBGRA: [UInt8],
        screenSize: PixelSize,
        tileSize: PixelSize,
        tiling: TilingKind
    ) -> Int {
        precondition(
            productionScreenBGRA.count
                == screenSize.width * screenSize.height * 4,
            "Display comparison screen bytes must match the drawable"
        )
        precondition(
            canonicalBGRA.count == tileSize.width * tileSize.height * 4,
            "Display comparison canonical bytes must match the tile"
        )
        precondition(
            tiling == .mirrorX || tiling == .mirrorY
                || tiling == .mirrorXY || tiling == .rotational,
            "Task 7 display comparison accepts mirror or rotational tiling"
        )

        var mismatchCount = 0
        for y in 0..<screenSize.height {
            for x in 0..<screenSize.width {
                let expectedOffset = independentDisplaySampleOffset(
                    screenX: x,
                    screenY: y,
                    screenSize: screenSize,
                    tileSize: tileSize,
                    tiling: tiling
                )
                let actualOffset = (y * screenSize.width + x) * 4
                if pixelDiffers(
                    productionScreenBGRA,
                    at: actualOffset,
                    from: canonicalBGRA,
                    at: expectedOffset,
                    tolerance: 0
                ) {
                    mismatchCount += 1
                }
            }
        }
        return mismatchCount
    }

    nonisolated static func gridLineLatticeMismatchCount(
        productionGridBGRA: [UInt8],
        productionBaseBGRA: [UInt8],
        screenSize: PixelSize,
        tileSize: PixelSize
    ) -> Int {
        let expectedByteCount = screenSize.width * screenSize.height * 4
        precondition(
            productionGridBGRA.count == expectedByteCount
                && productionBaseBGRA.count == expectedByteCount,
            "Grid-line comparison bytes must match the drawable"
        )

        var mismatchCount = 0
        let tileWidth = Float(tileSize.width)
        let tileHeight = Float(tileSize.height)
        for y in 0..<screenSize.height {
            for x in 0..<screenSize.width {
                let world = independentDisplayWorld(
                    screenX: x,
                    screenY: y,
                    screenSize: screenSize,
                    tileSize: tileSize
                )
                let localX = positiveDisplayFold(world.x, tileWidth)
                let localY = positiveDisplayFold(world.y, tileHeight)
                let edgeDistance = min(
                    min(localX, tileWidth - localX),
                    min(localY, tileHeight - localY)
                )
                let smoothInput = min(1, max(0, edgeDistance - 1))
                let smooth = smoothInput * smoothInput
                    * (3 - 2 * smoothInput)
                let alpha = Float(0.22) * (1 - smooth)
                let gridBGRA: [Float] = [
                    0.19 * alpha,
                    0.20 * alpha,
                    0.18 * alpha,
                    alpha,
                ]
                let offset = (y * screenSize.width + x) * 4
                var differs = false
                for channel in 0..<4 {
                    let base = Float(
                        productionBaseBGRA[offset + channel]
                    ) / 255
                    let expected = unormByte(
                        gridBGRA[channel] + base * (1 - alpha)
                    )
                    if abs(
                        Int(productionGridBGRA[offset + channel])
                            - Int(expected)
                    ) > 1 {
                        differs = true
                    }
                }
                mismatchCount += differs ? 1 : 0
            }
        }
        return mismatchCount
    }

    nonisolated static func rotationalGeneratorWorldProbes(
        input: TaskSevenHarnessInput,
        tileSize: PixelSize
    ) -> [WorldPoint] {
        let center = input.brushToWorld.translation
        let tile = SIMD2(Float(tileSize.width), Float(tileSize.height))
        return [
            WorldPoint(center),
            WorldPoint(center + SIMD2(tile.x, 0)),
            WorldPoint(center + SIMD2(0, tile.y)),
            WorldPoint(tile - center),
        ]
    }

    nonisolated static func displayProbeMismatchCount(
        productionScreenBGRA: [UInt8],
        canonicalBGRA: [UInt8],
        screenSize: PixelSize,
        tileSize: PixelSize,
        tiling: TilingKind,
        worldPoints: [WorldPoint]
    ) -> Int {
        var mismatchCount = 0
        for point in worldPoints {
            let screenX = Int(floor(
                point.x - Float(tileSize.width) * 0.5
                    + Float(screenSize.width) * 0.5
            ))
            let screenY = Int(floor(
                point.y - Float(tileSize.height) * 0.5
                    + Float(screenSize.height) * 0.5
            ))
            guard
                (0..<screenSize.width).contains(screenX),
                (0..<screenSize.height).contains(screenY)
            else {
                mismatchCount += 1
                continue
            }
            let expectedOffset = independentDisplaySampleOffset(
                screenX: screenX,
                screenY: screenY,
                screenSize: screenSize,
                tileSize: tileSize,
                tiling: tiling
            )
            let actualOffset =
                (screenY * screenSize.width + screenX) * 4
            if pixelDiffers(
                productionScreenBGRA,
                at: actualOffset,
                from: canonicalBGRA,
                at: expectedOffset,
                tolerance: 0
            ) {
                mismatchCount += 1
            }
        }
        return mismatchCount
    }

    nonisolated static func independentTransformMismatchCount(
        fragments: [CellFragment],
        brushToWorld: Affine2D,
        tileSize: PixelSize,
        tiling: TilingKind
    ) -> Int {
        var mismatchCount = 0
        var ordinalsByCell: [CellIndex: Set<UInt8>] = [:]
        for fragment in fragments {
            ordinalsByCell[fragment.cell, default: []].insert(
                fragment.imageOrdinal
            )
            guard let expectedWorldToCanonical =
                    independentWorldToCanonical(
                        cell: fragment.cell,
                        ordinal: fragment.imageOrdinal,
                        tileSize: tileSize,
                        tiling: tiling
                    )
            else {
                mismatchCount += 1
                continue
            }
            let expected = brushToWorld.concatenating(
                expectedWorldToCanonical
            )
            if !affinesMatch(
                fragment.canonicalFromBrush,
                expected,
                tolerance: 0.0001
            ) {
                mismatchCount += 1
            }
        }

        let expectedOrdinals: Set<UInt8> = tiling == .rotational
            ? [0, 1]
            : [0]
        for ordinals in ordinalsByCell.values {
            mismatchCount += ordinals.symmetricDifference(
                expectedOrdinals
            ).count
        }
        return mismatchCount
    }

    nonisolated static func duplicateFixedPointWriteCount(
        fragments: [CellFragment]
    ) -> Int {
        var seen: Set<FixedPointCoverageKey> = []
        var duplicates = 0
        for fragment in fragments {
            let affine = fragment.canonicalFromBrush
            let key = FixedPointCoverageKey(
                centerX: normalizedZero(affine.translation.x).bitPattern,
                centerY: normalizedZero(affine.translation.y).bitPattern,
                xAxisLength: normalizedZero(
                    simd_length(affine.xAxis)
                ).bitPattern,
                yAxisLength: normalizedZero(
                    simd_length(affine.yAxis)
                ).bitPattern
            )
            if !seen.insert(key).inserted {
                duplicates += 1
            }
        }
        return duplicates
    }

    nonisolated static func isPhasedGridLineVisible(
        line: SIMD4<UInt8>,
        offLine: SIMD4<UInt8>
    ) -> Bool {
        Int(line.x) + 20 < Int(offLine.x)
            && Int(line.y) + 20 < Int(offLine.y)
            && Int(line.z) + 20 < Int(offLine.z)
            && line.w == 255
    }

    struct GridArtifacts {
        var liveScreen: (any MTLTexture)?
        var committedScreen: (any MTLTexture)?
        var canonical: (any MTLTexture)?
        var initialTilingScreen: (any MTLTexture)?
        var alternateTilingScreen: (any MTLTexture)?
        var restoredTilingScreen: (any MTLTexture)?
        var phasedGridScreen: (any MTLTexture)?
        var displayValidationCanonical: (any MTLTexture)?
        var displayValidationScreen: (any MTLTexture)?
        var displayValidationGridLinesScreen: (any MTLTexture)?
        var oracle: OracleRasterResult?
        var oracleMetrics: HarnessOracleMetrics?

        func texture(
            for channel: HarnessPixelChannel
        ) -> (any MTLTexture)? {
            switch channel {
            case .screen:
                committedScreen ?? liveScreen
            case .liveScreen:
                liveScreen
            case .committedScreen:
                committedScreen
            case .canonical:
                canonical
            case .oracleCoverage, .oracleCanonicalCoordinates,
                 .oracleBrushLocalCoordinates:
                nil
            }
        }

        func oracleBGRA(
            for channel: HarnessPixelChannel
        ) -> (bytes: [UInt8], pixelSize: PixelSize)? {
            guard let oracle else {
                return nil
            }
            switch channel {
            case .oracleCoverage:
                var bytes: [UInt8] = []
                bytes.reserveCapacity(oracle.coverage.bytes.count * 4)
                for byte in oracle.coverage.bytes {
                    bytes.append(contentsOf: [byte, byte, byte, 255])
                }
                return (bytes, oracle.coverage.pixelSize)
            case .oracleCanonicalCoordinates:
                return (
                    oracle.canonicalCoordinatesBGRA,
                    oracle.coverage.pixelSize
                )
            case .oracleBrushLocalCoordinates:
                return (
                    oracle.brushLocalCoordinatesBGRA,
                    oracle.coverage.pixelSize
                )
            case .screen, .liveScreen, .committedScreen, .canonical:
                return nil
            }
        }
    }

    struct GridMeasurements {
        var timestamp: TimeInterval = 0
        var nextOperationRawValue: UInt64 = 1
        var activeOperationToken: RendererOperationToken?
        var pendingEventStart: CFAbsoluteTime?
        var brushProcessingMilliseconds: [Double] = []
        var eventToSubmitMilliseconds: [Double] = []
        var cpuEncodeMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        var dabGPUMilliseconds: [Double] = []
        var gridGPUMilliseconds: [Double] = []
        var commitGPUMilliseconds: [Double] = []
        var commitPendingMilliseconds: [Double] = []
        var newInstanceCounts: [Int] = []
        var totalStrokeInstanceCounts: [Int] = []
        var encodedInstanceHighWater: UInt64 = 0
        var restampedInstanceCount = 0
        var missedFrameCount = 0
        var longStrokeCPUMilliseconds: [Double] = []
        var longStrokeDabGPUMilliseconds: [Double] = []
        var longStrokeProjectedInstanceCounts: [Int] = []
        let displayFrameBudgetMilliseconds = 1_000.0 / 60.0
    }

    let device: any MTLDevice
    let library: any MTLLibrary
    private let blankRenderer: BlankRenderer
    var pristineGridRenderer: GridRenderer?

    public init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        self.device = device
        self.library = library
        blankRenderer = try BlankRenderer(device: device, library: library)
        pristineGridRenderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 512, height: 512),
            configuration: try TilingCanvasConfiguration(
                pixelSize: GridCanvasContract.defaultPixelSize,
                tiling: .grid
            )
        )
    }

    public func run(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        if scene.schemaVersion == 1 {
            return try runBlank(
                scene: scene,
                outputDirectory: outputDirectory,
                build: build
            )
        }
        return try runGrid(
            scene: scene,
            outputDirectory: outputDirectory,
            build: build
        )
    }

    private func runBlank(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        let frame = try blankRenderer.renderOffscreen(
            width: scene.width,
            height: scene.height
        )
        let imageURL = outputDirectory
            .appendingPathComponent("\(scene.name).screen.png")

        try PNGWriter.write(texture: frame.texture, to: imageURL)

        for check in scene.checks {
            let actual = try checkedPixel(in: frame.texture, check: check)
            let expected = SIMD4(
                check.expectedBGRA[0],
                check.expectedBGRA[1],
                check.expectedBGRA[2],
                check.expectedBGRA[3]
            )
            guard BlankCanvasContract.matches(
                actual: actual,
                expected: expected,
                tolerance: check.tolerance
            ) else {
                throw HarnessRunError.pixelMismatch(
                    x: check.x,
                    y: check.y,
                    expected: check.expectedBGRA,
                    actual: [actual.x, actual.y, actual.z, actual.w],
                    tolerance: check.tolerance
                )
            }
        }

        let processInfo = ProcessInfo.processInfo
        let record = BenchmarkRecord(
            schemaVersion: 1,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: blankRenderer.device.name,
                logicalProcessorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            ),
            operatingSystem: processInfo.operatingSystemVersionString,
            build: build,
            frameCount: 1,
            cpuEncodeMilliseconds: [frame.metrics.cpuEncodeMilliseconds],
            gpuMilliseconds: [frame.metrics.gpuMilliseconds],
            peakResidentBytes: try Self.peakResidentBytes()
        )
        let benchmarkURL = outputDirectory
            .appendingPathComponent("\(scene.name).benchmark.json")
        try BenchmarkRecord.encode(record).write(
            to: benchmarkURL,
            options: .atomic
        )

        return HarnessRunResult(
            imageURL: imageURL,
            benchmarkURL: benchmarkURL,
            benchmark: record,
            artifactURLs: [imageURL, benchmarkURL]
        )
    }

}
private func independentDisplaySampleOffset(
    screenX: Int,
    screenY: Int,
    screenSize: PixelSize,
    tileSize: PixelSize,
    tiling: TilingKind
) -> Int {
    let world = independentDisplayWorld(
        screenX: screenX,
        screenY: screenY,
        screenSize: screenSize,
        tileSize: tileSize
    )
    let tileWidth = Float(tileSize.width)
    let tileHeight = Float(tileSize.height)
    let localX = positiveDisplayFold(world.x, tileWidth)
    let localY = positiveDisplayFold(world.y, tileHeight)
    let column = Int(floor(world.x / tileWidth))
    let row = Int(floor(world.y / tileHeight))
    let reflectsX = (tiling == .mirrorX || tiling == .mirrorXY)
        && (column & 1) != 0
    let reflectsY = (tiling == .mirrorY || tiling == .mirrorXY)
        && (row & 1) != 0
    let canonicalX = reflectsX
        ? positiveDisplayFold(tileWidth - localX, tileWidth)
        : localX
    let canonicalY = reflectsY
        ? positiveDisplayFold(tileHeight - localY, tileHeight)
        : localY
    let sampleX = positiveIntegerModulo(
        Int(floor(canonicalX)),
        tileSize.width
    )
    let sampleY = positiveIntegerModulo(
        Int(floor(canonicalY)),
        tileSize.height
    )
    return (sampleY * tileSize.width + sampleX) * 4
}

private func independentDisplayWorld(
    screenX: Int,
    screenY: Int,
    screenSize: PixelSize,
    tileSize: PixelSize
) -> SIMD2<Float> {
    SIMD2(
        Float(screenX) + 0.5
            - Float(screenSize.width) * 0.5
            + Float(tileSize.width) * 0.5,
        Float(screenY) + 0.5
            - Float(screenSize.height) * 0.5
            + Float(tileSize.height) * 0.5
    )
}

private func positiveDisplayFold(_ coordinate: Float, _ extent: Float)
    -> Float
{
    coordinate - floor(coordinate / extent) * extent
}

private func positiveIntegerModulo(_ value: Int, _ modulus: Int) -> Int {
    let remainder = value % modulus
    return remainder < 0 ? remainder + modulus : remainder
}

private func pixelDiffers(
    _ lhs: [UInt8],
    at lhsOffset: Int,
    from rhs: [UInt8],
    at rhsOffset: Int,
    tolerance: Int
) -> Bool {
    (0..<4).contains {
        abs(Int(lhs[lhsOffset + $0]) - Int(rhs[rhsOffset + $0]))
            > tolerance
    }
}

private func unormByte(_ value: Float) -> UInt8 {
    UInt8(
        clamping: Int(
            (min(1, max(0, value)) * 255).rounded()
        )
    )
}

private func channelDistance(
    _ lhs: UInt8,
    _ rhs: UInt8,
    circular: Bool
) -> Int {
    let linear = abs(Int(lhs) - Int(rhs))
    return circular ? min(linear, 256 - linear) : linear
}

private func independentWorldToCanonical(
    cell: CellIndex,
    ordinal: UInt8,
    tileSize: PixelSize,
    tiling: TilingKind
) -> Affine2D? {
    let width = Float(tileSize.width)
    let height = Float(tileSize.height)
    let phaseX = tiling == .brick && (cell.row & 1) != 0
        ? width * 0.5
        : 0
    let phaseY = tiling == .halfDrop && (cell.column & 1) != 0
        ? height * 0.5
        : 0
    let origin = SIMD2(
        Float(cell.column) * width + phaseX,
        Float(cell.row) * height + phaseY
    )

    if tiling == .rotational {
        switch ordinal {
        case 0:
            return Affine2D(
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                translation: -origin
            )
        case 1:
            return Affine2D(
                xAxis: SIMD2(-1, 0),
                yAxis: SIMD2(0, -1),
                translation: origin + SIMD2(width, height)
            )
        default:
            return nil
        }
    }
    guard ordinal == 0 else {
        return nil
    }
    let reflectsX = (tiling == .mirrorX || tiling == .mirrorXY)
        && (cell.column & 1) != 0
    let reflectsY = (tiling == .mirrorY || tiling == .mirrorXY)
        && (cell.row & 1) != 0
    return Affine2D(
        xAxis: SIMD2(reflectsX ? -1 : 1, 0),
        yAxis: SIMD2(0, reflectsY ? -1 : 1),
        translation: SIMD2(
            reflectsX ? origin.x + width : -origin.x,
            reflectsY ? origin.y + height : -origin.y
        )
    )
}

private func affinesMatch(
    _ lhs: Affine2D,
    _ rhs: Affine2D,
    tolerance: Float
) -> Bool {
    simd_distance(lhs.xAxis, rhs.xAxis) <= tolerance
        && simd_distance(lhs.yAxis, rhs.yAxis) <= tolerance
        && simd_distance(lhs.translation, rhs.translation) <= tolerance
}

private func normalizedZero(_ value: Float) -> Float {
    value == 0 ? 0 : value
}
