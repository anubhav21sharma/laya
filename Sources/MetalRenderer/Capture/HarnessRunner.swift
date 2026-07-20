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

private struct HarnessFragmentMeasurements {
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
    private static let defaultStrokeStyle = StrokeRenderStyle(
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

    private nonisolated static func hardRoundFragments(
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

    private nonisolated static func repeatedFragments(
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

    private nonisolated static func appendFragmentAudit(
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

    private nonisolated static func auditInterpolatedHardRoundStroke(
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

    private nonisolated static func diagnosticWire(
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

    private struct GridArtifacts {
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

    private struct GridMeasurements {
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

    private let device: any MTLDevice
    private let library: any MTLLibrary
    private let blankRenderer: BlankRenderer
    private var pristineGridRenderer: GridRenderer?

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
        if scene.schemaVersion == 4 {
            return try SliceThreeHarnessRunner(
                device: device,
                library: library
            ).run(
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

    private func runGrid(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        guard let program = scene.program else {
            throw HarnessSceneError.missingProgram
        }
        let configuration = Self.configuration(for: scene)

        let gridRenderer: GridRenderer
        if configuration == HarnessRenderConfiguration(
            pixelSize: GridCanvasContract.defaultPixelSize,
            tiling: .grid,
            diagnosticMode: .hardRound
        ), let initialRenderer = pristineGridRenderer {
            pristineGridRenderer = nil
            gridRenderer = initialRenderer
        } else {
            gridRenderer = try GridRenderer(
                device: device,
                library: library,
                drawableSize: PatternSize(
                    width: Float(scene.width),
                    height: Float(scene.height)
                ),
                configuration: try TilingCanvasConfiguration(
                    pixelSize: configuration.pixelSize,
                    tiling: configuration.tiling
                )
            )
        }

        var measurements = GridMeasurements()
        var artifacts = GridArtifacts()
        var revisionStart = gridRenderer.harnessRevision.rawValue
        var canonicalBefore: [UInt8]?
        var taskSevenHarnessInput: TaskSevenHarnessInput?
        var taskSevenFragments: [CellFragment] = []
        var visibleCellCanonicalByteDelta: Int?
        var restoredDisplayMaximumDelta: Int?
        var previewCommitViolationCount: Int?
        var fragmentMeasurements = HarnessFragmentMeasurements()

        switch program {
        case .gridInterior:
            measureHandle(
                .began,
                x: 200,
                y: 256,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .moved,
                x: 240,
                y: 256,
                renderer: gridRenderer,
                into: &measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            measureHandle(
                .ended,
                x: 240,
                y: 256,
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .gridBoundary:
            measureHandle(
                .began,
                x: 128,
                y: 128,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .moved,
                x: 160,
                y: 160,
                renderer: gridRenderer,
                into: &measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            measureHandle(
                .ended,
                x: 160,
                y: 160,
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .previewCommit:
            measureHandle(
                .began,
                x: 180,
                y: 220,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .moved,
                x: 260,
                y: 300,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .ended,
                x: 260,
                y: 300,
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .cancelPreservesCanonical:
            measureHandle(
                .began,
                x: 180,
                y: 180,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .ended,
                x: 220,
                y: 180,
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try finishCommit(
                renderer: gridRenderer,
                measurements: &measurements
            )
            let beforeTexture = try gridRenderer.copyCanonicalForHarness()
            canonicalBefore = textureBytes(beforeTexture)
            revisionStart = gridRenderer.harnessRevision.rawValue

            measureHandle(
                .began,
                x: 300,
                y: 300,
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .moved,
                x: 340,
                y: 320,
                renderer: gridRenderer,
                into: &measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            measureHandle(
                .cancelled,
                x: 340,
                y: 320,
                renderer: gridRenderer,
                into: &measurements
            )
            artifacts.committedScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.canonical = try gridRenderer.copyCanonicalForHarness()

        case .fiveHundredDabs:
            let start = CFAbsoluteTimeGetCurrent()
            measurements.pendingEventStart = start
            try gridRenderer.injectFiveHundredInteriorDabsIntoOneFrame()
            measurements.brushProcessingMilliseconds.append(
                elapsedMilliseconds(since: start)
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )

        case .longStroke:
            try replayLongZigzag(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            guard measurements.newInstanceCounts.last == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "late frame encoded \(measurements.newInstanceCounts.last ?? -1) instances instead of 0"
                )
            }
            let last = longZigzagPoint(index: 239)
            measureHandle(
                .ended,
                x: last.x,
                y: last.y,
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
        case .generalizedGrid, .halfDropInterior, .halfDropEdge,
             .halfDropCorner, .brickTranspose:
            guard let input = Self.translationInput(for: program),
                  input.tiling == configuration.tiling,
                  gridRenderer.harnessTiling == configuration.tiling
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "translation program and renderer tiling disagree"
                )
            }
            let fragments = try gridRenderer.injectHarnessDab(
                at: input.center
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: fragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: input.center,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            if input.capturesPhasedGridLines {
                artifacts.phasedGridScreen =
                    try capturePhasedGridDisplay(
                        scene: scene,
                        renderer: gridRenderer,
                        measurements: &measurements
                    )
                try validatePhasedGridLine(
                    scene: scene,
                    program: program,
                    texture: artifacts.phasedGridScreen!
                )
            }
            artifacts.oracle = TilingCoverageOracle.renderCanonical(
                footprint: .hardRound(
                    radius: GridCanvasContract.brushRadius
                ),
                brushToWorld: Affine2D(
                    xAxis: SIMD2(1, 0),
                    yAxis: SIMD2(0, 1),
                    translation: input.center.simd
                ),
                tileSize: configuration.pixelSize,
                tiling: configuration.tiling,
                supersampling: 1
            )
        case .mirrorX, .mirrorY, .mirrorXY,
             .rotationalGenerator, .rotationalFixedPoint,
             .rotationalOrientation, .largeFootprint,
             .asymmetricFootprint, .canonicalCoordinateContinuity,
             .brushLocalCoordinateContinuity:
            guard let input = Self.taskSevenInput(for: program),
                  input.diagnosticMode == configuration.diagnosticMode,
                  gridRenderer.harnessTiling == configuration.tiling
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "Task 7 program and renderer configuration disagree"
                )
            }
            taskSevenHarnessInput = input

            if input.diagnosticMode == .hardRound {
                taskSevenFragments = try gridRenderer.injectHarnessDab(
                    at: WorldPoint(input.brushToWorld.translation),
                    radius: input.radius
                )
                try Self.appendFragmentAudit(
                    sceneName: scene.name,
                    fragments: taskSevenFragments,
                    repeatedFragments: Self.repeatedFragments(
                        for: input.stampFootprint,
                        configuration: configuration
                    ),
                    into: &fragmentMeasurements
                )
                try flushPending(
                    scene: scene,
                    renderer: gridRenderer,
                    measurements: &measurements
                )
                artifacts.liveScreen = try captureDisplay(
                    scene: scene,
                    renderer: gridRenderer,
                    measurements: &measurements
                )
                try captureCommittedAndCanonical(
                    scene: scene,
                    renderer: gridRenderer,
                    artifacts: &artifacts,
                    measurements: &measurements
                )
            } else {
                guard let diagnosticWire = Self.diagnosticWire(
                    for: input.diagnosticMode
                ) else {
                    throw HarnessRunError.counterInvariant(
                        sceneName: scene.name,
                        message: "diagnostic program resolved to hard-round wire"
                    )
                }
                let frame = try gridRenderer
                    .renderDiagnosticFootprintForHarness(
                        footprint: input.stampFootprint,
                        radius: input.radius,
                        diagnosticMode: diagnosticWire,
                        width: scene.width,
                        height: scene.height
                    )
                taskSevenFragments = frame.fragments
                try Self.appendFragmentAudit(
                    sceneName: scene.name,
                    fragments: frame.fragments,
                    repeatedFragments: Self.repeatedFragments(
                        for: input.stampFootprint,
                        configuration: configuration
                    ),
                    into: &fragmentMeasurements
                )
                artifacts.liveScreen = frame.screen
                artifacts.canonical = frame.canonical
                artifacts.displayValidationCanonical =
                    frame.displayValidationCanonical
                artifacts.displayValidationScreen =
                    frame.displayValidationScreen
                artifacts.displayValidationGridLinesScreen =
                    frame.gridLinesScreen
                measurements.cpuEncodeMilliseconds.append(
                    frame.metrics.cpuEncodeMilliseconds
                )
                measurements.gpuMilliseconds.append(
                    frame.metrics.gpuMilliseconds
                )
                measurements.dabGPUMilliseconds.append(
                    frame.metrics.gpuMilliseconds
                )
                measurements.newInstanceCounts.append(
                    frame.fragments.count
                )
                measurements.totalStrokeInstanceCounts.append(
                    frame.fragments.count
                )
            }

            if input.requiresDistantCells,
               !taskSevenFragments.contains(where: {
                   abs($0.cell.column) > 1 || abs($0.cell.row) > 1
               })
            {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "large footprint did not cross beyond immediate neighbors"
                )
            }
            artifacts.oracle = TilingCoverageOracle.renderCanonical(
                footprint: input.oracleFootprint,
                brushToWorld: input.brushToWorld,
                tileSize: configuration.pixelSize,
                tiling: configuration.tiling,
                supersampling: 1
            )
        case .rectangularTile:
            let center = Self.taskEightRectangularCenter
            let fragments = try gridRenderer.injectHarnessDab(at: center)
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: fragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: center,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            artifacts.oracle = TilingCoverageOracle.renderCanonical(
                footprint: .hardRound(
                    radius: GridCanvasContract.brushRadius
                ),
                brushToWorld: Affine2D(
                    xAxis: SIMD2(1, 0),
                    yAxis: SIMD2(0, 1),
                    translation: center.simd
                ),
                tileSize: configuration.pixelSize,
                tiling: configuration.tiling,
                supersampling: 1
            )
        case .noncentralVisibleCell:
            let input = Self.taskEightNoncentralInput(
                for: configuration.tiling
            )
            guard input.tileSize == configuration.pixelSize else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "noncentral input tile does not match scene tile"
                )
            }

            let centralFragments = try gridRenderer.injectHarnessDab(
                at: input.central
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: centralFragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: input.central,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try finishCommit(
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.committedScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            let centralCanonical =
                try gridRenderer.copyCanonicalForHarness()
            artifacts.canonical = centralCanonical

            let visibleRenderer = try makeGridRenderer(
                scene: scene,
                configuration: configuration
            )
            var visibleMeasurements = GridMeasurements()
            let visibleFragments = try visibleRenderer.injectHarnessDab(
                at: input.visible
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: visibleFragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: input.visible,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: visibleRenderer,
                measurements: &visibleMeasurements
            )
            try finishCommit(
                renderer: visibleRenderer,
                measurements: &visibleMeasurements
            )
            let visibleCanonical =
                try visibleRenderer.copyCanonicalForHarness()
            visibleCellCanonicalByteDelta = Self.differingByteCount(
                textureBytes(centralCanonical),
                textureBytes(visibleCanonical)
            )

            guard visibleFragments.contains(where: {
                $0.cell == input.visibleCell
            }) else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "noncentral stroke did not project through approved visible cell"
                )
            }
            if configuration.tiling == .rotational {
                try validateRotationalVisibleCellPair(
                    scene: scene,
                    fragments: centralFragments,
                    expectedCell: CellIndex(column: 0, row: 0)
                )
                try validateRotationalVisibleCellPair(
                    scene: scene,
                    fragments: visibleFragments,
                    expectedCell: input.visibleCell
                )
            }
        case .metadataTilingSwitch:
            let fragments = try gridRenderer.injectHarnessDab(
                at: Self.taskEightMetadataCenter
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: fragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: Self.taskEightMetadataCenter,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try finishCommit(
                renderer: gridRenderer,
                measurements: &measurements
            )
            let beforeCanonical =
                try gridRenderer.copyCanonicalForHarness()
            canonicalBefore = textureBytes(beforeCanonical)
            revisionStart = gridRenderer.harnessRevision.rawValue
            let beforeScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )

            let activeProbe = gridRenderer.viewport.worldToScreen(
                WorldPoint(x: 96, y: 96)
            )
            let activeToken = RendererOperationToken(rawValue: UInt64.max)
            try gridRenderer.beginStroke(
                token: activeToken,
                sample: .mouse(
                    position: activeProbe,
                    timestamp: 0,
                    phase: .began
                ),
                style: Self.defaultStrokeStyle
            )
            let rejectedState =
                gridRenderer.harnessTilingMutationSnapshot
            do {
                try gridRenderer.setTiling(.brick)
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "active-stroke tiling change unexpectedly succeeded"
                )
            } catch MetalRendererError.tilingChangeRequiresIdle {
                guard gridRenderer.harnessTiling == .grid,
                      gridRenderer.harnessTilingMutationSnapshot
                        == rejectedState
                else {
                    throw HarnessRunError.counterInvariant(
                        sceneName: scene.name,
                        message: "rejected tiling change mutated renderer state"
                    )
                }
            }
            try gridRenderer.cancelStroke(token: activeToken)
            let unchangedState =
                gridRenderer.harnessTilingMutationSnapshot

            try gridRenderer.setTiling(.mirrorXY)
            guard gridRenderer.harnessTilingMutationSnapshot
                    == unchangedState
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "tiling switch changed resources, live state, counters, or revision"
                )
            }
            let alternateScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            let changedDisplayBytes = Self.differingByteCount(
                textureBytes(beforeScreen),
                textureBytes(alternateScreen)
            )
            guard changedDisplayBytes > 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "mirrorXY switch did not change any display byte"
                )
            }

            try gridRenderer.setTiling(.grid)
            guard gridRenderer.harnessTilingMutationSnapshot
                    == unchangedState
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "restoring tiling changed resources, live state, counters, or revision"
                )
            }
            let restoredScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            restoredDisplayMaximumDelta = Self.maximumByteDelta(
                textureBytes(beforeScreen),
                textureBytes(restoredScreen)
            )
            artifacts.initialTilingScreen = beforeScreen
            artifacts.alternateTilingScreen = alternateScreen
            artifacts.restoredTilingScreen = restoredScreen
            artifacts.committedScreen = restoredScreen
            artifacts.canonical =
                try gridRenderer.copyCanonicalForHarness()
        case .projectedLiveCommit:
            let points = Self.taskEightLiveCommitPoints
            let auditedFragmentCount =
                try Self.auditInterpolatedHardRoundStroke(
                    sceneName: scene.name,
                    points: points,
                    configuration: configuration,
                    into: &fragmentMeasurements
                )
            measureHandle(
                .began,
                world: points[0],
                renderer: gridRenderer,
                into: &measurements
            )
            measureHandle(
                .ended,
                world: points[1],
                renderer: gridRenderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
            previewCommitViolationCount =
                Self.previewCommitViolationCount(
                    textureBytes(artifacts.liveScreen!),
                    textureBytes(artifacts.committedScreen!),
                    tolerance: 1
                )
            guard
                measurements.newInstanceCounts.reduce(0, +)
                    == auditedFragmentCount
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "interactive projected-instance count disagrees with deterministic projection audit"
                )
            }
        case .projectedLongStroke:
            let points = Self.taskEightLongStrokePoints
            guard points.count
                    == BenchmarkLongStrokeMetrics.segmentCount + 1
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "long-stroke program does not contain exactly 400 segments"
                )
            }
            for (index, pair) in zip(
                points,
                points.dropFirst()
            ).enumerated() {
                guard pair.0.y == pair.1.y,
                      abs(pair.1.x - pair.0.x) == 32
                else {
                    throw HarnessRunError.counterInvariant(
                        sceneName: scene.name,
                        message: "long-stroke segment \(index) is not an exact horizontal 32-pixel segment"
                    )
                }
            }

            var processingStart = CFAbsoluteTimeGetCurrent()
            var fragments =
                try gridRenderer.beginFixedProjectedStrokeForHarness(
                    at: points[0]
                )
            measurements.brushProcessingMilliseconds.append(
                elapsedMilliseconds(since: processingStart)
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: fragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: points[0],
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )

            for point in points.dropFirst() {
                let frameResult = try Self
                    .performLongStrokeProductionThenAudit(
                        production: {
                            processingStart = CFAbsoluteTimeGetCurrent()
                            measurements.pendingEventStart =
                                processingStart
                            let producedFragments =
                                try gridRenderer
                                    .appendFixedProjectedSegmentForHarness(
                                        to: point
                                    )
                            measurements.brushProcessingMilliseconds.append(
                                elapsedMilliseconds(
                                    since: processingStart
                                )
                            )
                            let flushResult = try flushPending(
                                scene: scene,
                                renderer: gridRenderer,
                                measurements: &measurements,
                                recordsLongStrokeFrame: true
                            )
                            return (
                                value: producedFragments,
                                measurement: flushResult
                            )
                        },
                        audit: { producedFragments in
                            try Self.appendFragmentAudit(
                                sceneName: scene.name,
                                fragments: producedFragments,
                                repeatedFragments:
                                    Self.hardRoundFragments(
                                        at: point,
                                        radius:
                                            GridCanvasContract.brushRadius,
                                        configuration: configuration
                                    ),
                                into: &fragmentMeasurements
                            )
                        }
                    )
                fragments = frameResult.value
            }
            try gridRenderer.endFixedProjectedStrokeForHarness()
            artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &artifacts,
                measurements: &measurements
            )
        case .coloredDraw, .eraserLiveCommit, .regionUndoSeam,
             .clearUndo, .tilingUndo, .resizeCropFill:
            throw HarnessSceneError.programUnavailableForSchema(
                program: program,
                schemaVersion: scene.schemaVersion
            )
        }

        let oracleComparison: CoverageComparison?
        let transformMismatchCount: Int?
        let duplicateFixedPointWrites: Int?
        let coordinateContinuityMismatches: Int?
        let productionCanonicalBytes = artifacts.canonical.map(textureBytes)
        let validatesTaskSevenDisplay: Bool
        switch program {
        case .mirrorX, .mirrorY, .mirrorXY, .rotationalGenerator:
            validatesTaskSevenDisplay = true
        default:
            validatesTaskSevenDisplay = false
        }
        var displaySemanticMismatchCount: Int
        if validatesTaskSevenDisplay {
            guard
                let validationCanonical =
                    artifacts.displayValidationCanonical,
                let validationScreen = artifacts.displayValidationScreen,
                let validationGridLines =
                    artifacts.displayValidationGridLinesScreen
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "Task 7 display validation textures are missing"
                )
            }
            let screenSize = PixelSize(
                width: scene.width,
                height: scene.height
            )
            let canonicalBytes = textureBytes(validationCanonical)
            let screenBytes = textureBytes(validationScreen)
            let gridLineBytes = textureBytes(validationGridLines)
            displaySemanticMismatchCount =
                Self.displayFoldMismatchCount(
                    productionScreenBGRA: screenBytes,
                    canonicalBGRA: canonicalBytes,
                    screenSize: screenSize,
                    tileSize: configuration.pixelSize,
                    tiling: configuration.tiling
                )
                + Self.gridLineLatticeMismatchCount(
                    productionGridBGRA: gridLineBytes,
                    productionBaseBGRA: screenBytes,
                    screenSize: screenSize,
                    tileSize: configuration.pixelSize
                )
            if program == .rotationalGenerator,
               let input = taskSevenHarnessInput
            {
                displaySemanticMismatchCount +=
                    Self.displayProbeMismatchCount(
                        productionScreenBGRA: screenBytes,
                        canonicalBGRA: canonicalBytes,
                        screenSize: screenSize,
                        tileSize: configuration.pixelSize,
                        tiling: configuration.tiling,
                        worldPoints:
                            Self.rotationalGeneratorWorldProbes(
                                input: input,
                                tileSize: configuration.pixelSize
                            )
                    )
            }
        } else {
            displaySemanticMismatchCount = 0
        }
        if let oracle = artifacts.oracle,
           let canonicalBytes = productionCanonicalBytes
        {
            let actualCoverage = Self.productionCoverage(
                fromBGRA: canonicalBytes,
                pixelSize: oracle.coverage.pixelSize
            )
            let comparison = TilingCoverageOracle.compare(
                expected: oracle.coverage,
                actual: actualCoverage,
                boundaryTolerance: 1
            )
            oracleComparison = comparison
            let mismatchCount = zip(
                oracle.coverage.bytes,
                actualCoverage.bytes
            ).reduce(0) {
                $0 + ($1.0 == $1.1 ? 0 : 1)
            }
            if let input = taskSevenHarnessInput,
               input.diagnosticMode != .hardRound
            {
                transformMismatchCount =
                    Self.independentTransformMismatchCount(
                        fragments: taskSevenFragments,
                        brushToWorld: input.brushToWorld,
                        tileSize: oracle.coverage.pixelSize,
                        tiling: configuration.tiling
                    ) + mismatchCount + displaySemanticMismatchCount
            } else {
                transformMismatchCount =
                    mismatchCount + displaySemanticMismatchCount
            }
            if program == .rotationalFixedPoint {
                duplicateFixedPointWrites =
                    Self.duplicateFixedPointWriteCount(
                        fragments: taskSevenFragments
                    )
            } else {
                duplicateFixedPointWrites = nil
            }
            switch configuration.diagnosticMode {
            case .canonicalCoordinates:
                coordinateContinuityMismatches =
                    Self.coordinateContinuityMismatchCount(
                        productionBGRA: canonicalBytes,
                        oracleBGRA: oracle.canonicalCoordinatesBGRA,
                        usesCircularRGDistance: true
                    )
            case .brushLocalCoordinates:
                coordinateContinuityMismatches =
                    Self.coordinateContinuityMismatchCount(
                        productionBGRA: canonicalBytes,
                        oracleBGRA: oracle.brushLocalCoordinatesBGRA,
                        usesCircularRGDistance: false
                    )
            case .hardRound, .asymmetricCoverage:
                coordinateContinuityMismatches = nil
            }
            artifacts.oracleMetrics = HarnessOracleMetrics(
                oracleHoleCount: comparison.holeCount,
                oraclePhantomCount: comparison.phantomCount,
                oracleMaximumDelta: Int(comparison.maximumDelta),
                transformMismatchCount: transformMismatchCount ?? 0,
                duplicateFixedPointWriteCount: duplicateFixedPointWrites,
                coordinateContinuityMismatchCount:
                    coordinateContinuityMismatches
            )
        } else {
            oracleComparison = nil
            transformMismatchCount = nil
            duplicateFixedPointWrites = nil
            coordinateContinuityMismatches = nil
        }

        let longStrokeMetrics: BenchmarkLongStrokeMetrics?
        if program == .projectedLongStroke {
            do {
                longStrokeMetrics =
                    try BenchmarkLongStrokeMetrics.measure(
                        cpuMilliseconds:
                            measurements.longStrokeCPUMilliseconds,
                        dabGPUMilliseconds:
                            measurements.longStrokeDabGPUMilliseconds,
                        projectedInstanceCounts:
                            measurements
                                .longStrokeProjectedInstanceCounts
                    )
            } catch {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: error.localizedDescription
                )
            }
        } else {
            longStrokeMetrics = nil
        }

        let revisionDelta = Int(
            gridRenderer.harnessRevision.rawValue - revisionStart
        )
        let previewCommitDelta = maximumByteDelta(
            artifacts.liveScreen,
            artifacts.committedScreen
        )
        let canonicalByteDelta: Int
        if let canonicalBefore, let canonical = artifacts.canonical {
            canonicalByteDelta = Self.differingByteCount(
                canonicalBefore,
                textureBytes(canonical)
            )
        } else {
            canonicalByteDelta = 0
        }

        let counters = gridRenderer.harnessCounters
        var structuralValues: [HarnessStructuralMetric: Int] = [
            .emittedDabCount: counters.totalDabsThisStroke,
            .encodedInstanceCount: measurements.newInstanceCounts.reduce(0, +),
            .restampedInstanceCount: measurements.restampedInstanceCount,
            .missedFrameCount: measurements.missedFrameCount,
        ]
        if artifacts.canonical != nil {
            structuralValues[.canonicalRevisionDelta] = revisionDelta
        }
        if artifacts.liveScreen != nil, artifacts.committedScreen != nil {
            structuralValues[.previewCommitMaximumDelta] = previewCommitDelta
        }
        if canonicalBefore != nil, artifacts.canonical != nil {
            structuralValues[.canonicalByteDelta] = canonicalByteDelta
        }
        if let oracleComparison {
            structuralValues[.oracleHoleCount] =
                oracleComparison.holeCount
            structuralValues[.oraclePhantomCount] =
                oracleComparison.phantomCount
            structuralValues[.oracleMaximumDelta] =
                Int(oracleComparison.maximumDelta)
        }
        if let transformMismatchCount {
            structuralValues[.transformMismatchCount] =
                transformMismatchCount
        }
        if let duplicateFixedPointWrites {
            structuralValues[.duplicateFixedPointWriteCount] =
                duplicateFixedPointWrites
        }
        if let coordinateContinuityMismatches {
            structuralValues[.coordinateContinuityMismatchCount] =
                coordinateContinuityMismatches
        }
        if let visibleCellCanonicalByteDelta {
            structuralValues[.visibleCellCanonicalByteDelta] =
                visibleCellCanonicalByteDelta
        }
        if let restoredDisplayMaximumDelta {
            structuralValues[.restoredDisplayMaximumDelta] =
                restoredDisplayMaximumDelta
        }
        if let previewCommitViolationCount {
            structuralValues[.previewCommitViolationCount] =
                previewCommitViolationCount
        }

        guard
            scene.schemaVersion != 3
                || fragmentMeasurements.totalProjectedFragmentCount > 0
        else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "projected-fragment metrics are unavailable"
            )
        }

        let processInfo = ProcessInfo.processInfo
        let record = BenchmarkRecord(
            schemaVersion: scene.schemaVersion == 3 ? 3 : 2,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: gridRenderer.device.name,
                logicalProcessorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            ),
            operatingSystem: processInfo.operatingSystemVersionString,
            build: build,
            frameCount: measurements.newInstanceCounts.count,
            cpuEncodeMilliseconds: measurements.cpuEncodeMilliseconds,
            gpuMilliseconds: measurements.gpuMilliseconds,
            peakResidentBytes: try Self.peakResidentBytes(),
            brushProcessingMilliseconds:
                measurements.brushProcessingMilliseconds,
            eventToSubmitMilliseconds:
                measurements.eventToSubmitMilliseconds,
            dabGPUMilliseconds: measurements.dabGPUMilliseconds,
            gridGPUMilliseconds: measurements.gridGPUMilliseconds,
            commitGPUMilliseconds: measurements.commitGPUMilliseconds,
            commitPendingMilliseconds:
                measurements.commitPendingMilliseconds,
            displayFrameBudgetMilliseconds:
                measurements.displayFrameBudgetMilliseconds,
            newInstanceCounts: measurements.newInstanceCounts,
            totalStrokeInstanceCounts:
                measurements.totalStrokeInstanceCounts,
            missedFrameCount: measurements.missedFrameCount,
            tilingRawValue: scene.schemaVersion == 3
                ? configuration.tiling.rawValue
                : nil,
            tileWidth: scene.schemaVersion == 3
                ? configuration.pixelSize.width
                : nil,
            tileHeight: scene.schemaVersion == 3
                ? configuration.pixelSize.height
                : nil,
            totalProjectedFragmentCount: scene.schemaVersion == 3
                ? fragmentMeasurements.totalProjectedFragmentCount
                : nil,
            maximumFragmentsPerFootprint: scene.schemaVersion == 3
                ? fragmentMeasurements.maximumFragmentsPerFootprint
                : nil,
            totalInstanceBytes: scene.schemaVersion == 3
                ? fragmentMeasurements.totalInstanceBytes
                : nil,
            oracleHoleCount: oracleComparison?.holeCount,
            oraclePhantomCount: oracleComparison?.phantomCount,
            oracleMaximumDelta: oracleComparison.map {
                Int($0.maximumDelta)
            },
            diagnosticMode: scene.schemaVersion == 3
                ? configuration.diagnosticMode.rawValue
                : nil,
            longStrokeEarlyCPUP95Milliseconds:
                longStrokeMetrics?.earlyCPUP95Milliseconds,
            longStrokeLateCPUP95Milliseconds:
                longStrokeMetrics?.lateCPUP95Milliseconds,
            longStrokeEarlyDabGPUP95Milliseconds:
                longStrokeMetrics?.earlyDabGPUP95Milliseconds,
            longStrokeLateDabGPUP95Milliseconds:
                longStrokeMetrics?.lateDabGPUP95Milliseconds,
            longStrokeCPUMillisecondsPerFrameSlope:
                longStrokeMetrics?.cpuMillisecondsPerFrameSlope,
            longStrokeDabGPUMillisecondsPerFrameSlope:
                longStrokeMetrics?.dabGPUMillisecondsPerFrameSlope
        )

        let emitted = try writeGridArtifacts(
            scene: scene,
            artifacts: artifacts,
            record: record,
            outputDirectory: outputDirectory
        )
        try validateCoreTaskNineInvariants(
            scene: scene,
            program: program,
            measurements: measurements,
            fragmentMeasurements: fragmentMeasurements,
            oracleComparison: oracleComparison,
            revisionDelta: revisionDelta,
            canonicalByteDelta: canonicalByteDelta,
            restoredDisplayMaximumDelta: restoredDisplayMaximumDelta,
            previewCommitViolationCount: previewCommitViolationCount,
            longStrokeMetrics: longStrokeMetrics,
            structuralValues: structuralValues
        )
        try evaluatePixelChecks(
            scene: scene,
            artifacts: artifacts
        )
        try Self.evaluateStructuralChecks(
            scene: scene,
            values: structuralValues
        )

        return HarnessRunResult(
            imageURL: emitted.primaryImageURL,
            benchmarkURL: emitted.benchmarkURL,
            benchmark: record,
            artifactURLs: emitted.artifactURLs
        )
    }

    private func measureHandle(
        _ phase: StrokePhase,
        x: Float,
        y: Float,
        renderer: GridRenderer,
        into measurements: inout GridMeasurements
    ) {
        let start = CFAbsoluteTimeGetCurrent()
        if phase == .began {
            measurements.encodedInstanceHighWater = 0
        }
        if measurements.pendingEventStart == nil {
            measurements.pendingEventStart = start
        }
        let sample = StrokeSample.mouse(
            position: ScreenPoint(x: x, y: y),
            timestamp: measurements.timestamp,
            phase: phase
        )
        do {
            switch phase {
            case .began:
                let token = RendererOperationToken(
                    rawValue: measurements.nextOperationRawValue
                )
                measurements.nextOperationRawValue &+= 1
                try renderer.beginStroke(
                    token: token,
                    sample: sample,
                    style: Self.defaultStrokeStyle
                )
                measurements.activeOperationToken = token
            case .moved:
                guard let token = measurements.activeOperationToken else {
                    preconditionFailure(
                        "Harness move requires an active renderer token."
                    )
                }
                try renderer.appendStroke(token: token, sample: sample)
            case .ended:
                guard let token = measurements.activeOperationToken else {
                    preconditionFailure(
                        "Harness end requires an active renderer token."
                    )
                }
                try renderer.requestStrokeCommit(
                    token: token,
                    sample: sample,
                    maximumRetainedBytes: 200 * 1_024 * 1_024
                )
                measurements.activeOperationToken = nil
            case .cancelled:
                guard let token = measurements.activeOperationToken else {
                    preconditionFailure(
                        "Harness cancel requires an active renderer token."
                    )
                }
                try renderer.cancelStroke(token: token)
                measurements.activeOperationToken = nil
            }
        } catch {
            preconditionFailure(
                "Harness renderer input failed: \(error.localizedDescription)"
            )
        }
        measurements.timestamp += 1.0 / 120.0
        measurements.brushProcessingMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
    }

    private func measureHandle(
        _ phase: StrokePhase,
        world: WorldPoint,
        renderer: GridRenderer,
        into measurements: inout GridMeasurements
    ) {
        let screen = renderer.viewport.worldToScreen(world)
        measureHandle(
            phase,
            x: screen.x,
            y: screen.y,
            renderer: renderer,
            into: &measurements
        )
    }

    private func makeGridRenderer(
        scene: HarnessScene,
        configuration: HarnessRenderConfiguration
    ) throws -> GridRenderer {
        try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(
                width: Float(scene.width),
                height: Float(scene.height)
            ),
            configuration: TilingCanvasConfiguration(
                pixelSize: configuration.pixelSize,
                tiling: configuration.tiling
            )
        )
    }

    private func validateRotationalVisibleCellPair(
        scene: HarnessScene,
        fragments: [CellFragment],
        expectedCell: CellIndex
    ) throws {
        let ordinals = Set(
            fragments.lazy
                .filter { $0.cell == expectedCell }
                .map(\.imageOrdinal)
        )
        guard ordinals == Set([UInt8(0), UInt8(1)]) else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "rotational visible cell \(expectedCell.column),\(expectedCell.row) did not contain the p2 image pair"
            )
        }
    }

    @discardableResult
    private func flushPending(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements,
        recordsLongStrokeFrame: Bool = false
    ) throws -> HarnessLiveFlushResult {
        let submitStart = measurements.pendingEventStart
            ?? CFAbsoluteTimeGetCurrent()
        let eventProcessingMilliseconds = elapsedMilliseconds(
            since: submitStart
        )
        let flushResult = try renderer.flushPendingLiveForHarness()
        let metrics = flushResult.metrics
        let submitMilliseconds = eventProcessingMilliseconds
            + metrics.cpuEncodeMilliseconds
        let counters = renderer.harnessCounters
        let identityAudit = try Self.auditEncodedInstanceIdentityRanges(
            sceneName: scene.name,
            previousEncodedHighWater:
                measurements.encodedInstanceHighWater,
            emittedHighWater: flushResult.emittedHighWater,
            encodedIdentityRanges: flushResult.encodedIdentityRanges
        )

        guard counters.newInstancesThisFrame <=
                GridCanvasContract.pendingCapacity
        else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "frame encoded \(counters.newInstancesThisFrame) instances beyond the fixed \(GridCanvasContract.pendingCapacity) bound"
            )
        }

        guard counters.newInstancesThisFrame
                == identityAudit.newlyEncodedInstanceCount
        else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "encoded projected-instance counter disagrees with encoded identity range"
            )
        }
        measurements.restampedInstanceCount +=
            identityAudit.restampedInstanceCount
        measurements.newInstanceCounts.append(
            counters.newInstancesThisFrame
        )
        measurements.totalStrokeInstanceCounts.append(
            counters.totalInstancesThisStroke
        )
        measurements.encodedInstanceHighWater =
            identityAudit.encodedHighWater
        measurements.eventToSubmitMilliseconds.append(submitMilliseconds)
        measurements.cpuEncodeMilliseconds.append(
            metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(metrics.gpuMilliseconds)
        measurements.dabGPUMilliseconds.append(metrics.gpuMilliseconds)
        if recordsLongStrokeFrame {
            measurements.longStrokeCPUMilliseconds.append(
                submitMilliseconds
            )
            measurements.longStrokeDabGPUMilliseconds.append(
                metrics.gpuMilliseconds
            )
            measurements.longStrokeProjectedInstanceCounts.append(
                counters.newInstancesThisFrame
            )
        }
        if submitMilliseconds >
            measurements.displayFrameBudgetMilliseconds
        {
            measurements.missedFrameCount += 1
        }
        measurements.pendingEventStart = nil
        return flushResult
    }

    private func captureLive(
        scene: HarnessScene,
        renderer: GridRenderer,
        artifacts: inout GridArtifacts,
        measurements: inout GridMeasurements
    ) throws {
        try flushPending(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        artifacts.liveScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
    }

    private func captureDisplay(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws -> any MTLTexture {
        let frame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: false
        )
        measurements.cpuEncodeMilliseconds.append(
            frame.metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(frame.metrics.gpuMilliseconds)
        measurements.gridGPUMilliseconds.append(frame.metrics.gpuMilliseconds)
        return frame.texture
    }

    private func capturePhasedGridDisplay(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws -> any MTLTexture {
        let frame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: true
        )
        measurements.cpuEncodeMilliseconds.append(
            frame.metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(frame.metrics.gpuMilliseconds)
        measurements.gridGPUMilliseconds.append(frame.metrics.gpuMilliseconds)
        return frame.texture
    }

    private func validatePhasedGridLine(
        scene: HarnessScene,
        program: TilingHarnessProgram,
        texture: any MTLTexture
    ) throws {
        let world: WorldPoint
        switch program {
        case .halfDropInterior, .halfDropCorner:
            world = WorldPoint(x: 300, y: 96)
        case .halfDropEdge:
            world = WorldPoint(x: 300, y: 288)
        case .brickTranspose:
            world = WorldPoint(x: 144, y: 300)
        default:
            return
        }
        let configuration = Self.configuration(for: scene)
        let viewport = ViewportTransform(
            drawableSize: PatternSize(
                width: Float(scene.width),
                height: Float(scene.height)
            ),
            worldCenter: WorldPoint(
                x: Float(configuration.pixelSize.width) * 0.5,
                y: Float(configuration.pixelSize.height) * 0.5
            )
        )
        let screen = viewport.worldToScreen(world)
        let x = Int(screen.x)
        let y = Int(screen.y)
        let line = PNGWriter.pixel(in: texture, x: x, y: y)
        let offLine = PNGWriter.pixel(
            in: texture,
            x: min(texture.width - 1, x + 4),
            y: min(texture.height - 1, y + 4)
        )
        let lineIsVisible = Self.isPhasedGridLineVisible(
            line: line,
            offLine: offLine
        )
        guard lineIsVisible else {
            throw HarnessRunError.tilingPixelMismatch(
                sceneName: scene.name,
                tiling: configuration.tiling,
                cell: nil,
                channel: .committedScreen,
                x: x,
                y: y,
                expected: [199, 202, 198, 255],
                actual: [line.x, line.y, line.z, line.w],
                tolerance: 5
            )
        }
    }

    private func finishCommit(
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws {
        let start = CFAbsoluteTimeGetCurrent()
        let metrics = try renderer.finishCommitForHarness()
        measurements.commitPendingMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
        measurements.cpuEncodeMilliseconds.append(
            metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(metrics.gpuMilliseconds)
        measurements.commitGPUMilliseconds.append(metrics.gpuMilliseconds)
    }

    private func captureCommittedAndCanonical(
        scene: HarnessScene,
        renderer: GridRenderer,
        artifacts: inout GridArtifacts,
        measurements: inout GridMeasurements
    ) throws {
        try finishCommit(
            renderer: renderer,
            measurements: &measurements
        )
        artifacts.committedScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        artifacts.canonical = try renderer.copyCanonicalForHarness()
    }

    private func replayLongZigzag(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws {
        measureHandle(
            .began,
            x: 48,
            y: 48,
            renderer: renderer,
            into: &measurements
        )
        for index in 0..<240 {
            let point = longZigzagPoint(index: index)
            measureHandle(
                .moved,
                x: point.x,
                y: point.y,
                renderer: renderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: renderer,
                measurements: &measurements
            )
        }
    }

    private func longZigzagPoint(index: Int) -> ScreenPoint {
        ScreenPoint(
            x: index.isMultiple(of: 2) ? 208 : 48,
            y: 48 + Float(index % 161)
        )
    }

    private func evaluatePixelChecks(
        scene: HarnessScene,
        artifacts: GridArtifacts
    ) throws {
        for check in scene.checks {
            let actual: SIMD4<UInt8>
            if let oracle = artifacts.oracleBGRA(for: check.channel) {
                guard
                    (0..<oracle.pixelSize.width).contains(check.x),
                    (0..<oracle.pixelSize.height).contains(check.y)
                else {
                    throw HarnessSceneError.invalidCheckCoordinate(
                        x: check.x,
                        y: check.y
                    )
                }
                let offset = (check.y * oracle.pixelSize.width + check.x) * 4
                actual = SIMD4(
                    oracle.bytes[offset],
                    oracle.bytes[offset + 1],
                    oracle.bytes[offset + 2],
                    oracle.bytes[offset + 3]
                )
            } else {
                guard let texture = artifacts.texture(for: check.channel) else {
                    throw HarnessRunError.missingArtifact(
                        sceneName: scene.name,
                        channel: check.channel
                    )
                }
                actual = try checkedPixel(in: texture, check: check)
            }
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
                if scene.schemaVersion == 3, let tiling = scene.tiling {
                    throw HarnessRunError.tilingPixelMismatch(
                        sceneName: scene.name,
                        tiling: tiling,
                        cell: nil,
                        channel: check.channel,
                        x: check.x,
                        y: check.y,
                        expected: check.expectedBGRA,
                        actual: [actual.x, actual.y, actual.z, actual.w],
                        tolerance: check.tolerance
                    )
                } else {
                    throw HarnessRunError.gridPixelMismatch(
                        sceneName: scene.name,
                        channel: check.channel,
                        x: check.x,
                        y: check.y,
                        expected: check.expectedBGRA,
                        actual: [actual.x, actual.y, actual.z, actual.w],
                        tolerance: check.tolerance
                    )
                }
            }
        }
    }

    private func validateCoreTaskNineInvariants(
        scene: HarnessScene,
        program: TilingHarnessProgram,
        measurements: GridMeasurements,
        fragmentMeasurements: HarnessFragmentMeasurements,
        oracleComparison: CoverageComparison?,
        revisionDelta: Int,
        canonicalByteDelta: Int,
        restoredDisplayMaximumDelta: Int?,
        previewCommitViolationCount: Int?,
        longStrokeMetrics: BenchmarkLongStrokeMetrics?,
        structuralValues: [HarnessStructuralMetric: Int]
    ) throws {
        guard scene.schemaVersion == 3 else {
            return
        }
        guard fragmentMeasurements.maximumClipPlaneCount <= 4 else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "a generated fragment exceeded four clip planes"
            )
        }
        guard measurements.restampedInstanceCount == 0 else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "restamped \(measurements.restampedInstanceCount) old projected instances"
            )
        }
        if let primaryMetric = scene.structuralChecks.first?.metric {
            guard let actual = structuralValues[primaryMetric] else {
                throw HarnessRunError.missingStructuralMetric(
                    sceneName: scene.name,
                    metric: primaryMetric
                )
            }
            guard actual == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "primary correctness metric \(primaryMetric.rawValue) is \(actual) instead of 0"
                )
            }
        }

        let requiresOracle: Bool
        switch program {
        case .generalizedGrid, .halfDropInterior, .halfDropEdge,
             .halfDropCorner, .brickTranspose, .mirrorX, .mirrorY,
             .mirrorXY, .rotationalGenerator, .rotationalFixedPoint,
             .rotationalOrientation, .largeFootprint,
             .asymmetricFootprint, .canonicalCoordinateContinuity,
             .brushLocalCoordinateContinuity, .rectangularTile:
            requiresOracle = true
        default:
            requiresOracle = false
        }
        if requiresOracle {
            guard let oracleComparison else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "oracle metrics are unavailable"
                )
            }
            guard oracleComparison.holeCount == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "oracle reported \(oracleComparison.holeCount) holes"
                )
            }
            guard oracleComparison.phantomCount == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "oracle reported \(oracleComparison.phantomCount) phantoms"
                )
            }
            guard oracleComparison.maximumDelta <= 1 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "oracle maximum delta \(oracleComparison.maximumDelta) exceeds 1"
                )
            }
        }

        if program == .metadataTilingSwitch {
            guard canonicalByteDelta == 0, revisionDelta == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "tiling switch changed canonical bytes or revision"
                )
            }
            guard restoredDisplayMaximumDelta == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "restored tiling display did not match the initial display"
                )
            }
        }
        if program == .projectedLiveCommit {
            guard previewCommitViolationCount == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "preview/commit channels differed by more than 1"
                )
            }
        }
        if program == .projectedLongStroke {
            guard longStrokeMetrics != nil else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "long-stroke timing metrics are unavailable"
                )
            }
            guard
                measurements.longStrokeProjectedInstanceCounts.count
                    == BenchmarkLongStrokeMetrics.segmentCount
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "long-stroke measured-frame count is not exactly 400"
                )
            }
        }
    }

    nonisolated static func evaluateStructuralChecks(
        scene: HarnessScene,
        values: [HarnessStructuralMetric: Int]
    ) throws {
        for check in scene.structuralChecks {
            guard let actual = values[check.metric] else {
                throw HarnessRunError.missingStructuralMetric(
                    sceneName: scene.name,
                    metric: check.metric
                )
            }
            let passed: Bool
            switch check.relation {
            case .equal:
                passed = actual == check.value
            case .lessThanOrEqual:
                passed = actual <= check.value
            }
            guard passed else {
                if scene.schemaVersion == 3, let tiling = scene.tiling {
                    throw HarnessRunError.tilingStructuralMismatch(
                        sceneName: scene.name,
                        tiling: tiling,
                        cell: nil,
                        metric: check.metric,
                        expectedRelation: check.relation,
                        expectedValue: check.value,
                        actualValue: actual
                    )
                } else {
                    throw HarnessRunError.structuralMismatch(
                        sceneName: scene.name,
                        metric: check.metric,
                        expectedRelation: check.relation,
                        expectedValue: check.value,
                        actualValue: actual
                    )
                }
            }
        }
    }

    private func checkedPixel(
        in texture: any MTLTexture,
        check: HarnessPixelCheck
    ) throws -> SIMD4<UInt8> {
        guard
            (0..<texture.width).contains(check.x),
            (0..<texture.height).contains(check.y)
        else {
            throw HarnessSceneError.invalidCheckCoordinate(
                x: check.x,
                y: check.y
            )
        }
        return PNGWriter.pixel(in: texture, x: check.x, y: check.y)
    }

    private func writeGridArtifacts(
        scene: HarnessScene,
        artifacts: GridArtifacts,
        record: BenchmarkRecord,
        outputDirectory: URL
    ) throws -> (
        primaryImageURL: URL,
        benchmarkURL: URL,
        artifactURLs: [URL]
    ) {
        var artifactURLs: [URL] = []
        var liveURL: URL?
        var committedURL: URL?
        var restoredTilingURL: URL?

        if let texture = artifacts.liveScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).live.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            liveURL = url
            artifactURLs.append(url)
        }
        if let texture = artifacts.committedScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).committed.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            committedURL = url
            artifactURLs.append(url)
        }
        if let texture = artifacts.canonical {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).canonical.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.initialTilingScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).initial-tiling.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.alternateTilingScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).alternate-tiling.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.restoredTilingScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).restored-tiling.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            restoredTilingURL = url
            artifactURLs.append(url)
        }
        if let texture = artifacts.phasedGridScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).grid-lines.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.displayValidationCanonical {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).display-validation.canonical.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.displayValidationScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).display-validation.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.displayValidationGridLinesScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).display-validation.grid-lines.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let oracle = artifacts.oracle {
            let coverageURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.coverage.png"
            )
            try PNGWriter.write(
                coverage: oracle.coverage,
                to: coverageURL
            )
            artifactURLs.append(coverageURL)

            let canonicalURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.canonical-coordinates.png"
            )
            try PNGWriter.writeBGRA(
                oracle.canonicalCoordinatesBGRA,
                pixelSize: oracle.coverage.pixelSize,
                to: canonicalURL
            )
            artifactURLs.append(canonicalURL)

            let brushLocalURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.brush-local-coordinates.png"
            )
            try PNGWriter.writeBGRA(
                oracle.brushLocalCoordinatesBGRA,
                pixelSize: oracle.coverage.pixelSize,
                to: brushLocalURL
            )
            artifactURLs.append(brushLocalURL)
        }
        if let oracleMetrics = artifacts.oracleMetrics {
            let metricsURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.metrics.json"
            )
            try HarnessOracleMetrics.encode(oracleMetrics).write(
                to: metricsURL,
                options: .atomic
            )
            artifactURLs.append(metricsURL)
        }

        let benchmarkURL = outputDirectory.appendingPathComponent(
            "\(scene.name).benchmark.json"
        )
        try BenchmarkRecord.encode(record).write(
            to: benchmarkURL,
            options: .atomic
        )
        artifactURLs.append(benchmarkURL)

        guard let primaryImageURL =
                restoredTilingURL ?? committedURL ?? liveURL
        else {
            throw HarnessRunError.missingArtifact(
                sceneName: scene.name,
                channel: .screen
            )
        }
        return (primaryImageURL, benchmarkURL, artifactURLs)
    }

    private func maximumByteDelta(
        _ lhsTexture: (any MTLTexture)?,
        _ rhsTexture: (any MTLTexture)?
    ) -> Int {
        guard let lhsTexture, let rhsTexture else {
            return 0
        }
        let lhs = textureBytes(lhsTexture)
        let rhs = textureBytes(rhsTexture)
        guard lhs.count == rhs.count else {
            return 255
        }
        return zip(lhs, rhs).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
    }

    private func textureBytes(_ texture: any MTLTexture) -> [UInt8] {
        precondition(texture.pixelFormat == .bgra8Unorm)
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * texture.height
        )
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(
                    0,
                    0,
                    texture.width,
                    texture.height
                ),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    private func elapsedMilliseconds(
        since start: CFAbsoluteTime
    ) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    private static func peakResidentBytes() throws -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
            throw HarnessRunError.processMetricsUnavailable
        }
        return UInt64(usage.ru_maxrss)
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
