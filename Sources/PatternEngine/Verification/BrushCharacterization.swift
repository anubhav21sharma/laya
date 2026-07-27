import Foundation
import simd

public struct BrushCharacterizationRecord: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let traceName: String
    public let recipeID: String
    public let nominalDiameter: Float
    public let seed: UInt64
    public let sampleCount: Int
    public let logicalDabCount: Int
    public let logicalDabDigest: String

    public init(
        schemaVersion: UInt16,
        traceName: String,
        recipeID: String,
        nominalDiameter: Float,
        seed: UInt64,
        sampleCount: Int,
        logicalDabCount: Int,
        logicalDabDigest: String
    ) {
        self.schemaVersion = schemaVersion
        self.traceName = traceName
        self.recipeID = recipeID
        self.nominalDiameter = nominalDiameter
        self.seed = seed
        self.sampleCount = sampleCount
        self.logicalDabCount = logicalDabCount
        self.logicalDabDigest = logicalDabDigest
    }
}

public enum BrushLogicalBaselineError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt16)
    case recordsNotSorted
    case duplicateRecord
    case mismatch
}

public struct BrushLogicalBaseline: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let records: [BrushCharacterizationRecord]

    public init(
        validatingSchemaVersion schemaVersion: UInt16,
        records: [BrushCharacterizationRecord]
    ) throws {
        guard schemaVersion == Self.schemaVersion,
              records.allSatisfy({ $0.schemaVersion == schemaVersion })
        else {
            throw BrushLogicalBaselineError.unsupportedSchemaVersion(schemaVersion)
        }
        guard records == records.sorted(by: Self.isOrdered) else {
            throw BrushLogicalBaselineError.recordsNotSorted
        }
        guard Set(records.map(Self.key(for:))).count == records.count else {
            throw BrushLogicalBaselineError.duplicateRecord
        }
        self.schemaVersion = schemaVersion
        self.records = records
    }

    public func requireMatches(
        _ actual: [BrushCharacterizationRecord]
    ) throws {
        guard actual == records else {
            throw BrushLogicalBaselineError.mismatch
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingSchemaVersion: container.decode(
                UInt16.self,
                forKey: .schemaVersion
            ),
            records: container.decode(
                [BrushCharacterizationRecord].self,
                forKey: .records
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(records, forKey: .records)
    }

    private static func key(for record: BrushCharacterizationRecord) -> String {
        "\(record.recipeID)\u{0}\(record.traceName)"
    }

    private static func isOrdered(
        _ lhs: BrushCharacterizationRecord,
        _ rhs: BrushCharacterizationRecord
    ) -> Bool {
        key(for: lhs) < key(for: rhs)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
    }
}

/// A future `LogicalDab` uses this exact payload and byte encoder. Keeping it
/// separate from the legacy renderer types makes the compatibility digest a
/// stable boundary rather than another renderer representation.
public struct BrushCharacterizationDigestPayload: Equatable, Sendable {
    public let ordinal: UInt64
    public let dab: LogicalDab
    public let primaryGrainFrame: Affine2D
    public let secondaryGrainFrame: Affine2D
    public let hasPrimaryGrain: Bool
    public let hasSecondaryGrain: Bool
    public let secondaryColorMix: Float
    public let accumulationEnabled: Bool
    public let interactionEnabled: Bool
    public let edgeEnabled: Bool
    public let materialStrength: Float
    public let materialWetness: Float
    public let materialBleedRadius: Float
    public let materialSoftenPasses: UInt64
    public let materialAccumulationLimit: Float
    public let compatibilityRandom: BrushRandomValues
    public let extensionRandom: BrushExtensionRandomChannels
    public let worldBoundsMinimum: SIMD2<Float>
    public let worldBoundsMaximum: SIMD2<Float>

    public init(
        ordinal: UInt64,
        dab: LogicalDab,
        primaryGrainFrame: Affine2D,
        secondaryGrainFrame: Affine2D,
        hasPrimaryGrain: Bool,
        hasSecondaryGrain: Bool,
        secondaryColorMix: Float,
        accumulationEnabled: Bool,
        interactionEnabled: Bool,
        edgeEnabled: Bool,
        materialStrength: Float,
        materialWetness: Float,
        materialBleedRadius: Float,
        materialSoftenPasses: UInt64,
        materialAccumulationLimit: Float,
        compatibilityRandom: BrushRandomValues,
        extensionRandom: BrushExtensionRandomChannels,
        worldBoundsMinimum: SIMD2<Float>,
        worldBoundsMaximum: SIMD2<Float>
    ) {
        self.ordinal = ordinal
        self.dab = dab
        self.primaryGrainFrame = primaryGrainFrame
        self.secondaryGrainFrame = secondaryGrainFrame
        self.hasPrimaryGrain = hasPrimaryGrain
        self.hasSecondaryGrain = hasSecondaryGrain
        self.secondaryColorMix = secondaryColorMix
        self.accumulationEnabled = accumulationEnabled
        self.interactionEnabled = interactionEnabled
        self.edgeEnabled = edgeEnabled
        self.materialStrength = materialStrength
        self.materialWetness = materialWetness
        self.materialBleedRadius = materialBleedRadius
        self.materialSoftenPasses = materialSoftenPasses
        self.materialAccumulationLimit = materialAccumulationLimit
        self.compatibilityRandom = compatibilityRandom
        self.extensionRandom = extensionRandom
        self.worldBoundsMinimum = worldBoundsMinimum
        self.worldBoundsMaximum = worldBoundsMaximum
    }

    public static func legacy(
        recipe: BrushRecipe,
        dab: LogicalDab,
        seed: UInt64,
        ordinal: UInt64
    ) -> Self {
        legacy(
            recipe: recipe,
            dab: dab,
            seed: seed,
            ordinal: ordinal,
            compatibilityRandom: randomValues(seed: seed, ordinal: ordinal)
        )
    }

    static func legacy(
        recipe: BrushRecipe,
        dab: LogicalDab,
        seed: UInt64,
        ordinal: UInt64,
        compatibilityRandom: BrushRandomValues
    ) -> Self {
        let primaryGrainFrame = grainFrame(
            scale: dab.grainScale,
            rotation: dab.grainRotation,
            offset: dab.grainOffset
        )
        let secondaryGrainFrame = Affine2D.identity
        let extent = SIMD2(
            abs(dab.brushToWorld.xAxis.x) + abs(dab.brushToWorld.yAxis.x),
            abs(dab.brushToWorld.xAxis.y) + abs(dab.brushToWorld.yAxis.y)
        )
        return Self(
            ordinal: ordinal,
            dab: dab,
            primaryGrainFrame: primaryGrainFrame,
            secondaryGrainFrame: secondaryGrainFrame,
            hasPrimaryGrain: recipe.grain != .opaque,
            hasSecondaryGrain: false,
            secondaryColorMix: 0,
            accumulationEnabled: recipe.material.accumulationLimit < 1,
            interactionEnabled: recipe.material.wetness > 0,
            edgeEnabled: recipe.material.bleedRadius > 0,
            materialStrength: recipe.material.strength,
            materialWetness: recipe.material.wetness,
            materialBleedRadius: recipe.material.bleedRadius,
            materialSoftenPasses: UInt64(recipe.material.softenPasses),
            materialAccumulationLimit: recipe.material.accumulationLimit,
            compatibilityRandom: compatibilityRandom,
            extensionRandom: .zero,
            worldBoundsMinimum: dab.position.simd - extent,
            worldBoundsMaximum: dab.position.simd + extent
        )
    }

    /// Builds the frozen schema-v1 payload from a runtime logical dab.
    ///
    /// Runtime bounds include the material halo. Schema v1 predates that
    /// contract and permanently records tip-only bounds, so this factory
    /// deliberately derives the legacy footprint instead of serializing
    /// `dab.worldBounds`. The recipe remains necessary only for the legacy
    /// soften-pass scalar, which is not part of `BrushMaterialInputs`.
    public static func logicalDab(
        _ dab: LogicalDab,
        compatibilityRecipe recipe: BrushRecipe
    ) -> Self {
        // Schema v1 encoded the evaluated frame even when the recipe's
        // primary grain was opaque. Reconstructing it here also preserves the
        // signed-zero bits produced by the legacy trigonometric path.
        let primaryGrainFrame = dab.primaryGrainToWorld ?? grainFrame(
            scale: dab.grainScale,
            rotation: dab.grainRotation,
            offset: dab.grainOffset
        )
        let secondaryGrainFrame = dab.secondaryGrainToWorld ?? .identity
        let extent = SIMD2(
            abs(dab.brushToWorld.xAxis.x) + abs(dab.brushToWorld.yAxis.x),
            abs(dab.brushToWorld.xAxis.y) + abs(dab.brushToWorld.yAxis.y)
        )
        return Self(
            ordinal: dab.ordinal,
            dab: dab,
            primaryGrainFrame: primaryGrainFrame,
            secondaryGrainFrame: secondaryGrainFrame,
            hasPrimaryGrain: recipe.grain != .opaque,
            hasSecondaryGrain: dab.secondaryGrainToWorld != nil,
            secondaryColorMix: dab.secondaryColorMix,
            // These scalar-derived flags are part of the frozen schema-v1
            // digest contract; do not reinterpret them through new enums.
            accumulationEnabled: dab.materialInputs.accumulationLimit < 1,
            interactionEnabled: dab.materialInputs.wetness > 0,
            edgeEnabled: dab.materialInputs.bleedRadius > 0,
            materialStrength: dab.materialInputs.strength,
            materialWetness: dab.materialInputs.wetness,
            materialBleedRadius: dab.materialInputs.bleedRadius,
            materialSoftenPasses: UInt64(recipe.material.softenPasses),
            materialAccumulationLimit: dab.materialInputs.accumulationLimit,
            compatibilityRandom: dab.randomValues.compatibility,
            extensionRandom: BrushExtensionRandomChannels(
                values: dab.randomValues.extensionValues
            ),
            worldBoundsMinimum: dab.position.simd - extent,
            worldBoundsMaximum: dab.position.simd + extent
        )
    }

    private static func grainFrame(
        scale: Float,
        rotation: Float,
        offset: SIMD2<Float>
    ) -> Affine2D {
        let cosine = cos(rotation) * scale
        let sine = sin(rotation) * scale
        return Affine2D(
            xAxis: SIMD2(cosine, sine),
            yAxis: SIMD2(-sine, cosine),
            translation: offset
        )
    }

    private static func randomValues(
        seed: UInt64,
        ordinal: UInt64
    ) -> BrushRandomValues {
        var random = BrushRandom(seed: seed)
        var values = BrushRandomValues.centered
        for _ in 0...ordinal {
            values = random.nextValues()
        }
        return values
    }
}

public enum BrushCharacterizer {
    public static func record(
        trace: StrokeTraceFixture,
        recipe: BrushRecipe,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        viewport: ViewportTransform
    ) -> BrushCharacterizationRecord {
        let definition = try! LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: recipe.id.rawValue
        )
        let program = try! BrushProgramCompiler.compile(definition)
        return record(
            trace: trace,
            program: program,
            nominalDiameter: nominalDiameter,
            color: color,
            seed: seed,
            viewport: viewport
        )
    }

    public static func record(
        trace: StrokeTraceFixture,
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        viewport: ViewportTransform
    ) -> BrushCharacterizationRecord {
        precondition(trace.samples.first?.phase == .began)
        precondition(
            trace.samples.last?.phase == .ended
                || trace.samples.last?.phase == .cancelled
        )
        precondition(trace.samples.filter { $0.phase == .began }.count == 1)
        precondition(
            trace.samples.filter {
                $0.phase == .ended || $0.phase == .cancelled
            }.count == 1
        )
        let compatibilityRecipe: BrushRecipe
        if let recipe = program.compatibilityRecipe {
            compatibilityRecipe = recipe
        } else {
            preconditionFailure(
                "Native program characterization belongs to logical batches"
            )
        }

        var input = BrushInputDeriver()
        var generator = BrushStrokeGenerator(
            program: program,
            nominalDiameter: nominalDiameter,
            color: color,
            seed: seed
        )
        var sampleCount = 0
        var payloads: [BrushCharacterizationDigestPayload] = []

        for sample in trace.samples where sample.kind != .predicted {
            let worldSample = input.derive(sample, viewport: viewport)
            sampleCount += 1
            let emit: (LogicalDab) -> Void = { dab in
                let payload = BrushCharacterizationDigestPayload.logicalDab(
                    dab,
                    compatibilityRecipe: compatibilityRecipe
                )
                payloads.append(payload)
            }
            switch worldSample.phase {
            case .began:
                generator.begin(worldSample, emit: emit)
            case .moved:
                generator.append(worldSample, emit: emit)
            case .ended:
                generator.finish(worldSample, emit: emit)
            case .cancelled:
                generator.cancel()
            }
        }

        return BrushCharacterizationRecord(
            schemaVersion: BrushLogicalBaseline.schemaVersion,
            traceName: trace.name,
            recipeID: program.definition.id.rawValue,
            nominalDiameter: nominalDiameter,
            seed: seed,
            sampleCount: sampleCount,
            logicalDabCount: payloads.count,
            logicalDabDigest: BrushCharacterizationDigest.digest(payloads)
        )
    }
}

/// The only payload encoder for logical-dab characterization. Future logical
/// dab factories construct `BrushCharacterizationDigestPayload` values and
/// call this API, preserving this byte order and FNV implementation.
public enum BrushCharacterizationDigest {
    public static func digest(
        _ payloads: [BrushCharacterizationDigestPayload],
        schemaVersion: UInt16 = BrushLogicalBaseline.schemaVersion
    ) -> String {
        precondition(schemaVersion == BrushLogicalBaseline.schemaVersion)
        var accumulator = FNV1a64()
        accumulator.append(UInt64(schemaVersion))
        for payload in payloads {
            accumulator.append(payload)
        }
        return accumulator.hex
    }
}

public struct BrushExtensionRandomChannels: Equatable, Sendable {
    public let values: [Float]

    public init(values: [Float]) {
        precondition(values.count == 10)
        self.values = values
    }

    public static let zero = BrushExtensionRandomChannels(
        values: Array(repeating: 0, count: 10)
    )
}

private struct FNV1a64 {
    private var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func append(_ value: UInt64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            for byte in bytes {
                self.value ^= UInt64(byte)
                self.value &*= 0x0000_0100_0000_01b3
            }
        }
    }

    mutating func append(_ value: Float) {
        append(UInt64(value.bitPattern))
    }

    mutating func append(_ value: Bool) {
        append(UInt64(value ? 1 : 0))
    }

    mutating func append(_ vector: SIMD2<Float>) {
        append(vector.x)
        append(vector.y)
    }

    mutating func append(_ transform: Affine2D) {
        append(transform.xAxis)
        append(transform.yAxis)
        append(transform.translation)
    }

    mutating func append(_ payload: BrushCharacterizationDigestPayload) {
        let dab = payload.dab
        append(payload.ordinal)
        append(dab.position.x)
        append(dab.position.y)
        append(dab.brushToWorld)
        append(dab.radius)
        append(dab.diameter)
        append(dab.spacing)
        append(dab.flow)
        append(dab.strokeOpacity)
        append(dab.rotation)
        append(dab.scatter)
        append(dab.hardness)
        append(dab.grainOffset)
        append(dab.grainScale)
        append(dab.grainRotation)
        append(dab.color.red)
        append(dab.color.green)
        append(dab.color.blue)
        append(dab.color.alpha)
        append(dab.colorAdjustment.redMultiplier)
        append(dab.colorAdjustment.greenMultiplier)
        append(dab.colorAdjustment.blueMultiplier)
        append(dab.colorAdjustment.alphaMultiplier)
        append(UInt64(dab.materialFamily.rawValue))
        append(dab.materialContribution)
        append(dab.sourceDistance)
        append(dab.isPredicted)

        append(payload.hasPrimaryGrain)
        append(payload.primaryGrainFrame)
        append(payload.hasSecondaryGrain)
        append(payload.secondaryGrainFrame)
        append(payload.secondaryColorMix)
        append(payload.accumulationEnabled)
        append(payload.interactionEnabled)
        append(payload.edgeEnabled)
        append(payload.materialStrength)
        append(payload.materialWetness)
        append(payload.materialBleedRadius)
        append(payload.materialSoftenPasses)
        append(payload.materialAccumulationLimit)
        append(payload.compatibilityRandom.spacing)
        append(payload.compatibilityRandom.scatterX)
        append(payload.compatibilityRandom.scatterY)
        append(payload.compatibilityRandom.rotation)
        append(payload.compatibilityRandom.grainX)
        append(payload.compatibilityRandom.grainY)
        append(payload.compatibilityRandom.materialVariation)
        for value in payload.extensionRandom.values { append(value) }
        append(payload.worldBoundsMinimum)
        append(payload.worldBoundsMaximum)
    }

    var hex: String { String(format: "%016llx", value) }
}
