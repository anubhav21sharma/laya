import Foundation
import simd

public enum ProfessionalBrushCharacterizationRecordError:
    Error, Equatable, Sendable
{
    case unsupportedSchemaVersion(UInt16)
    case invalidIdentity
    case invalidCount
    case nonfiniteMetric
    case malformedMetricRange
    case malformedBounds
    case emptyAuthoritativeOutput
    case renderIdentityMismatch
}

public struct ProfessionalBrushWorldBounds: Codable, Equatable, Sendable {
    public let minimumX: Float
    public let minimumY: Float
    public let maximumX: Float
    public let maximumY: Float

    public init(
        minimumX: Float,
        minimumY: Float,
        maximumX: Float,
        maximumY: Float
    ) {
        self.minimumX = minimumX
        self.minimumY = minimumY
        self.maximumX = maximumX
        self.maximumY = maximumY
    }
}

public struct ProfessionalBrushCharacterizationRecord:
    Codable, Equatable, Sendable
{
    public let schemaVersion: UInt16
    public let family: String
    public let brushID: String
    public let definitionSemanticHash: String
    public let traceName: String
    public let sampleCount: Int
    public let logicalDabCount: Int
    public let logicalDabDigest: String
    public let minimumDiameter: Float
    public let maximumDiameter: Float
    public let minimumFlow: Float
    public let maximumFlow: Float
    public let minimumOpacity: Float
    public let maximumOpacity: Float
    public let minimumHardness: Float
    public let maximumHardness: Float
    public let minimumGrainScale: Float
    public let maximumGrainScale: Float
    public let minimumRotation: Float
    public let maximumRotation: Float
    public let minimumScatterMagnitude: Float
    public let maximumScatterMagnitude: Float
    public let worldBounds: ProfessionalBrushWorldBounds

    public init(
        schemaVersion: UInt16,
        family: String,
        brushID: String,
        definitionSemanticHash: String,
        traceName: String,
        sampleCount: Int,
        logicalDabCount: Int,
        logicalDabDigest: String,
        minimumDiameter: Float,
        maximumDiameter: Float,
        minimumFlow: Float,
        maximumFlow: Float,
        minimumOpacity: Float,
        maximumOpacity: Float,
        minimumHardness: Float,
        maximumHardness: Float,
        minimumGrainScale: Float,
        maximumGrainScale: Float,
        minimumRotation: Float,
        maximumRotation: Float,
        minimumScatterMagnitude: Float,
        maximumScatterMagnitude: Float,
        worldBounds: ProfessionalBrushWorldBounds
    ) throws {
        guard schemaVersion == ProfessionalBrushLogicalBaseline.schemaVersion
        else {
            throw ProfessionalBrushCharacterizationRecordError
                .unsupportedSchemaVersion(schemaVersion)
        }
        guard !family.isEmpty,
              !brushID.isEmpty,
              !brushID.unicodeScalars.contains(where: { $0.value == 0 }),
              definitionSemanticHash.utf8.count == 64,
              definitionSemanticHash.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              !traceName.isEmpty,
              !traceName.unicodeScalars.contains(where: { $0.value == 0 }),
              !logicalDabDigest.isEmpty
        else {
            throw ProfessionalBrushCharacterizationRecordError.invalidIdentity
        }
        guard sampleCount >= 0, logicalDabCount >= 0 else {
            throw ProfessionalBrushCharacterizationRecordError.invalidCount
        }
        let metrics = [
            minimumDiameter, maximumDiameter,
            minimumFlow, maximumFlow,
            minimumOpacity, maximumOpacity,
            minimumHardness, maximumHardness,
            minimumGrainScale, maximumGrainScale,
            minimumRotation, maximumRotation,
            minimumScatterMagnitude, maximumScatterMagnitude,
        ]
        guard metrics.allSatisfy(\.isFinite) else {
            throw ProfessionalBrushCharacterizationRecordError.nonfiniteMetric
        }
        guard minimumDiameter <= maximumDiameter,
              minimumFlow <= maximumFlow,
              minimumOpacity <= maximumOpacity,
              minimumHardness <= maximumHardness,
              minimumGrainScale <= maximumGrainScale,
              minimumRotation <= maximumRotation,
              minimumScatterMagnitude <= maximumScatterMagnitude
        else {
            throw ProfessionalBrushCharacterizationRecordError
                .malformedMetricRange
        }
        guard [
            worldBounds.minimumX,
            worldBounds.minimumY,
            worldBounds.maximumX,
            worldBounds.maximumY,
        ].allSatisfy(\.isFinite),
            worldBounds.minimumX <= worldBounds.maximumX,
            worldBounds.minimumY <= worldBounds.maximumY
        else {
            throw ProfessionalBrushCharacterizationRecordError.malformedBounds
        }
        self.schemaVersion = schemaVersion
        self.family = family
        self.brushID = brushID
        self.definitionSemanticHash = definitionSemanticHash
        self.traceName = traceName
        self.sampleCount = sampleCount
        self.logicalDabCount = logicalDabCount
        self.logicalDabDigest = logicalDabDigest
        self.minimumDiameter = minimumDiameter
        self.maximumDiameter = maximumDiameter
        self.minimumFlow = minimumFlow
        self.maximumFlow = maximumFlow
        self.minimumOpacity = minimumOpacity
        self.maximumOpacity = maximumOpacity
        self.minimumHardness = minimumHardness
        self.maximumHardness = maximumHardness
        self.minimumGrainScale = minimumGrainScale
        self.maximumGrainScale = maximumGrainScale
        self.minimumRotation = minimumRotation
        self.maximumRotation = maximumRotation
        self.minimumScatterMagnitude = minimumScatterMagnitude
        self.maximumScatterMagnitude = maximumScatterMagnitude
        self.worldBounds = worldBounds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            family: container.decode(String.self, forKey: .family),
            brushID: container.decode(String.self, forKey: .brushID),
            definitionSemanticHash: container.decode(
                String.self,
                forKey: .definitionSemanticHash
            ),
            traceName: container.decode(String.self, forKey: .traceName),
            sampleCount: container.decode(Int.self, forKey: .sampleCount),
            logicalDabCount: container.decode(Int.self, forKey: .logicalDabCount),
            logicalDabDigest: container.decode(
                String.self,
                forKey: .logicalDabDigest
            ),
            minimumDiameter: container.decode(Float.self, forKey: .minimumDiameter),
            maximumDiameter: container.decode(Float.self, forKey: .maximumDiameter),
            minimumFlow: container.decode(Float.self, forKey: .minimumFlow),
            maximumFlow: container.decode(Float.self, forKey: .maximumFlow),
            minimumOpacity: container.decode(Float.self, forKey: .minimumOpacity),
            maximumOpacity: container.decode(Float.self, forKey: .maximumOpacity),
            minimumHardness: container.decode(Float.self, forKey: .minimumHardness),
            maximumHardness: container.decode(Float.self, forKey: .maximumHardness),
            minimumGrainScale: container.decode(
                Float.self,
                forKey: .minimumGrainScale
            ),
            maximumGrainScale: container.decode(
                Float.self,
                forKey: .maximumGrainScale
            ),
            minimumRotation: container.decode(Float.self, forKey: .minimumRotation),
            maximumRotation: container.decode(Float.self, forKey: .maximumRotation),
            minimumScatterMagnitude: container.decode(
                Float.self,
                forKey: .minimumScatterMagnitude
            ),
            maximumScatterMagnitude: container.decode(
                Float.self,
                forKey: .maximumScatterMagnitude
            ),
            worldBounds: container.decode(
                ProfessionalBrushWorldBounds.self,
                forKey: .worldBounds
            )
        )
    }
}

public enum ProfessionalBrushLogicalBaselineError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt16)
    case recordsNotSorted
    case duplicateRecord
    case mismatch
}

public struct ProfessionalBrushLogicalBaseline:
    Codable, Equatable, Sendable
{
    public static let schemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let records: [ProfessionalBrushCharacterizationRecord]

    public init(
        validatingSchemaVersion schemaVersion: UInt16,
        records: [ProfessionalBrushCharacterizationRecord]
    ) throws {
        guard schemaVersion == Self.schemaVersion,
              records.allSatisfy({ $0.schemaVersion == schemaVersion })
        else {
            throw ProfessionalBrushLogicalBaselineError
                .unsupportedSchemaVersion(schemaVersion)
        }
        guard records == records.sorted(by: Self.isOrdered) else {
            throw ProfessionalBrushLogicalBaselineError.recordsNotSorted
        }
        guard Set(records.map(Self.key(for:))).count == records.count else {
            throw ProfessionalBrushLogicalBaselineError.duplicateRecord
        }
        self.schemaVersion = schemaVersion
        self.records = records
    }

    public func requireMatches(
        _ actual: [ProfessionalBrushCharacterizationRecord]
    ) throws {
        guard actual == records else {
            throw ProfessionalBrushLogicalBaselineError.mismatch
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingSchemaVersion: container.decode(
                UInt16.self,
                forKey: .schemaVersion
            ),
            records: container.decode(
                [ProfessionalBrushCharacterizationRecord].self,
                forKey: .records
            )
        )
    }

    private static func key(
        for record: ProfessionalBrushCharacterizationRecord
    ) -> String {
        "\(record.brushID)\u{0}\(record.traceName)"
    }

    private static func isOrdered(
        _ lhs: ProfessionalBrushCharacterizationRecord,
        _ rhs: ProfessionalBrushCharacterizationRecord
    ) -> Bool {
        key(for: lhs) < key(for: rhs)
    }
}

public enum ProfessionalBrushCharacterizer {
    public static let nominalDiameter: Float = 40
    public static let color: InkColor = .black
    public static let seed: UInt64 = 0x5A17_E5
    public static let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 512, height: 512),
        worldCenter: WorldPoint(x: 256, y: 256)
    )

    public static func record(
        family: String,
        definitionSemanticHash: String,
        trace: StrokeTraceFixture,
        program: BrushProgram
    ) throws -> ProfessionalBrushCharacterizationRecord {
        try characterize(
            family: family,
            definitionSemanticHash: definitionSemanticHash,
            trace: trace,
            program: program
        ).record
    }

    static func characterize(
        family: String,
        definitionSemanticHash: String,
        trace: StrokeTraceFixture,
        program: BrushProgram
    ) throws -> ProfessionalBrushCharacterizationResult {
        var authoritativeInput = BrushInputDeriver()
        var authoritativeGenerator = BrushStrokeGenerator(
            program: program,
            nominalDiameter: nominalDiameter,
            color: color,
            seed: seed
        )
        var predictionCursor: PredictionCursor?
        var sampleCount = 0
        var dabs: [LogicalDab] = []
        var payloads: [BrushCharacterizationDigestPayload] = []
        var evaluatedPredictedSampleCount = 0
        var evaluatedPredictedLogicalDabCount = 0

        for sample in trace.samples {
            switch sample.kind {
            case .actual, .coalesced:
                predictionCursor = nil
                let worldSample = authoritativeInput.derive(
                    sample,
                    viewport: viewport
                )
                sampleCount += 1
                try generate(
                    worldSample,
                    with: &authoritativeGenerator
                ) { dab in
                    dabs.append(dab)
                    payloads.append(
                        BrushCharacterizationDigestPayload.logicalDab(
                            dab,
                            definition: program.definition
                        )
                    )
                }
            case .predicted:
                var cursor = predictionCursor ?? PredictionCursor(
                    input: authoritativeInput,
                    generator: authoritativeGenerator
                )
                let worldSample = cursor.input.deriveAdvancingPrediction(
                    sample,
                    viewport: viewport
                )
                evaluatedPredictedSampleCount += 1
                try generate(worldSample, with: &cursor.generator) { _ in
                    evaluatedPredictedLogicalDabCount += 1
                }
                predictionCursor = cursor
            case .estimatedUpdate:
                continue
            }
        }

        guard !dabs.isEmpty else {
            throw ProfessionalBrushCharacterizationRecordError
                .emptyAuthoritativeOutput
        }
        let metrics = Metrics(dabs: dabs)
        let record = try ProfessionalBrushCharacterizationRecord(
            schemaVersion: ProfessionalBrushLogicalBaseline.schemaVersion,
            family: family,
            brushID: program.definition.id.rawValue,
            definitionSemanticHash: definitionSemanticHash,
            traceName: trace.name,
            sampleCount: sampleCount,
            logicalDabCount: dabs.count,
            logicalDabDigest: BrushCharacterizationDigest.digest(payloads),
            minimumDiameter: metrics.minimumDiameter,
            maximumDiameter: metrics.maximumDiameter,
            minimumFlow: metrics.minimumFlow,
            maximumFlow: metrics.maximumFlow,
            minimumOpacity: metrics.minimumOpacity,
            maximumOpacity: metrics.maximumOpacity,
            minimumHardness: metrics.minimumHardness,
            maximumHardness: metrics.maximumHardness,
            minimumGrainScale: metrics.minimumGrainScale,
            maximumGrainScale: metrics.maximumGrainScale,
            minimumRotation: metrics.minimumRotation,
            maximumRotation: metrics.maximumRotation,
            minimumScatterMagnitude: metrics.minimumScatterMagnitude,
            maximumScatterMagnitude: metrics.maximumScatterMagnitude,
            worldBounds: metrics.worldBounds
        )
        return ProfessionalBrushCharacterizationResult(
            record: record,
            evaluatedPredictedSampleCount:
                evaluatedPredictedSampleCount,
            evaluatedPredictedLogicalDabCount:
                evaluatedPredictedLogicalDabCount
        )
    }

    private static func generate(
        _ sample: WorldStrokeSample,
        with generator: inout BrushStrokeGenerator,
        emit: (LogicalDab) -> Void
    ) throws {
        if sample.phase == .cancelled {
            generator.cancel()
            return
        }
        var cursor = try generator.emissionCursor(
            for: sample,
            maximumPathSubdivisionCount: .max
        )
        repeat {
            _ = try cursor.emitNextPage(emit)
        } while !cursor.isComplete
        guard let completed = cursor.completedGenerator else {
            preconditionFailure(
                "Completed characterization cursor has no generator"
            )
        }
        generator = completed
    }

    private struct PredictionCursor {
        var input: BrushInputDeriver
        var generator: BrushStrokeGenerator
    }

    public static func record(
        family: String,
        renderIdentity: BrushRenderIdentity,
        trace: StrokeTraceFixture,
        program: BrushProgram
    ) throws -> ProfessionalBrushCharacterizationRecord {
        guard renderIdentity.definitionID == program.definition.id else {
            throw ProfessionalBrushCharacterizationRecordError
                .renderIdentityMismatch
        }
        return try record(
            family: family,
            definitionSemanticHash: renderIdentity.semanticHash,
            trace: trace,
            program: program
        )
    }

    private struct Metrics {
        let minimumDiameter: Float
        let maximumDiameter: Float
        let minimumFlow: Float
        let maximumFlow: Float
        let minimumOpacity: Float
        let maximumOpacity: Float
        let minimumHardness: Float
        let maximumHardness: Float
        let minimumGrainScale: Float
        let maximumGrainScale: Float
        let minimumRotation: Float
        let maximumRotation: Float
        let minimumScatterMagnitude: Float
        let maximumScatterMagnitude: Float
        let worldBounds: ProfessionalBrushWorldBounds

        init(dabs: [LogicalDab]) {
            minimumDiameter = dabs.map(\.diameter).min()!
            maximumDiameter = dabs.map(\.diameter).max()!
            minimumFlow = dabs.map(\.flow).min()!
            maximumFlow = dabs.map(\.flow).max()!
            minimumOpacity = dabs.map(\.strokeOpacity).min()!
            maximumOpacity = dabs.map(\.strokeOpacity).max()!
            minimumHardness = dabs.map(\.hardness).min()!
            maximumHardness = dabs.map(\.hardness).max()!
            minimumGrainScale = dabs.map(\.grainScale).min()!
            maximumGrainScale = dabs.map(\.grainScale).max()!
            minimumRotation = dabs.map(\.rotation).min()!
            maximumRotation = dabs.map(\.rotation).max()!
            let scatterMagnitudes = dabs.map { simd_length($0.scatter) }
            minimumScatterMagnitude = scatterMagnitudes.min()!
            maximumScatterMagnitude = scatterMagnitudes.max()!
            let minimum = dabs.reduce(dabs[0].worldBounds.minimum) {
                simd_min($0, $1.worldBounds.minimum)
            }
            let maximum = dabs.reduce(dabs[0].worldBounds.maximum) {
                simd_max($0, $1.worldBounds.maximum)
            }
            worldBounds = ProfessionalBrushWorldBounds(
                minimumX: minimum.x,
                minimumY: minimum.y,
                maximumX: maximum.x,
                maximumY: maximum.y
            )
        }
    }
}

struct ProfessionalBrushCharacterizationResult: Equatable, Sendable {
    let record: ProfessionalBrushCharacterizationRecord
    let evaluatedPredictedSampleCount: Int
    let evaluatedPredictedLogicalDabCount: Int
}
