import Foundation
import simd

public struct BrushMaterialInputs: Equatable, Sendable {
    public let accumulation: BrushAccumulationMode
    public let interaction: BrushInteractionMode
    public let edgeTreatment: BrushEdgeTreatment
    public let strength: Float
    public let wetness: Float
    public let bleedRadius: Float
    public let accumulationLimit: Float
    public let interactionParameters: BrushInteractionDefinition?

    public init(
        accumulation: BrushAccumulationMode,
        interaction: BrushInteractionMode,
        edgeTreatment: BrushEdgeTreatment,
        strength: Float,
        wetness: Float,
        bleedRadius: Float,
        accumulationLimit: Float,
        interactionParameters: BrushInteractionDefinition?
    ) {
        self.accumulation = accumulation
        self.interaction = interaction
        self.edgeTreatment = edgeTreatment
        self.strength = strength
        self.wetness = wetness
        self.bleedRadius = bleedRadius
        self.accumulationLimit = accumulationLimit
        self.interactionParameters = interactionParameters
    }

    public static let neutral = BrushMaterialInputs(
        accumulation: .opaque,
        interaction: .none,
        edgeTreatment: .none,
        strength: 1,
        wetness: 0,
        bleedRadius: 0,
        accumulationLimit: 1,
        interactionParameters: nil
    )

    var conservativeHaloRadius: Float {
        max(bleedRadius, interactionParameters?.dirtyHaloRadius ?? 0)
    }

    var isFinite: Bool {
        strength.isFinite
            && wetness.isFinite
            && bleedRadius.isFinite
            && accumulationLimit.isFinite
            && interactionParameters?.isFinite != false
    }
}

public struct BrushLogicalRandomValues: Equatable, Sendable {
    public let compatibility: BrushRandomValues
    public let size: Float
    public let flow: Float
    public let opacity: Float
    public let hardness: Float
    public let offsetX: Float
    public let offsetY: Float
    public let hue: Float
    public let saturation: Float
    public let brightness: Float
    public let secondaryColorMix: Float

    public init(
        compatibility: BrushRandomValues,
        size: Float,
        flow: Float,
        opacity: Float,
        hardness: Float,
        offsetX: Float,
        offsetY: Float,
        hue: Float,
        saturation: Float,
        brightness: Float,
        secondaryColorMix: Float
    ) {
        self.compatibility = compatibility
        self.size = size
        self.flow = flow
        self.opacity = opacity
        self.hardness = hardness
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.secondaryColorMix = secondaryColorMix
    }

    /// Legacy brushes had no extension random channels. Zero is the frozen
    /// schema-v1 characterization value for every appended channel.
    public static let neutral = BrushLogicalRandomValues(
        compatibility: .centered,
        size: 0,
        flow: 0,
        opacity: 0,
        hardness: 0,
        offsetX: 0,
        offsetY: 0,
        hue: 0,
        saturation: 0,
        brightness: 0,
        secondaryColorMix: 0
    )

    var isFinite: Bool {
        [
            size,
            flow,
            opacity,
            hardness,
            offsetX,
            offsetY,
            hue,
            saturation,
            brightness,
            secondaryColorMix,
        ].allSatisfy(\.isFinite)
    }

    var extensionValues: [Float] {
        [
            size,
            flow,
            opacity,
            hardness,
            offsetX,
            offsetY,
            hue,
            saturation,
            brightness,
            secondaryColorMix,
        ]
    }
}

public enum LogicalDabBatchError: Error, Equatable, Sendable {
    case zeroSeed
    case tooManyDabs(actual: Int, maximum: Int)
    case noncontiguousOrdinal(expected: UInt64, actual: UInt64)
    case ordinalOverflow
    case mixedProvenance
    case provenanceMismatch(expectedPredicted: Bool)
    case nonfiniteDab(ordinal: UInt64)
    case nonfiniteBatchBounds
}

public struct LogicalDabBatch: Equatable, Sendable {
    public static let maximumDabCount = 512

    public let seed: UInt64
    public let dabs: [LogicalDab]
    public let ordinalRange: Range<UInt64>
    public let isPredicted: Bool
    public let worldBounds: AxisAlignedRect?

    public init(
        seed: UInt64,
        startingOrdinal: UInt64,
        isPredicted: Bool,
        dabs: [LogicalDab]
    ) throws {
        guard seed != 0 else {
            throw LogicalDabBatchError.zeroSeed
        }
        guard dabs.count <= Self.maximumDabCount else {
            throw LogicalDabBatchError.tooManyDabs(
                actual: dabs.count,
                maximum: Self.maximumDabCount
            )
        }
        let (endOrdinal, overflow) = startingOrdinal.addingReportingOverflow(
            UInt64(dabs.count)
        )
        guard !overflow else {
            throw LogicalDabBatchError.ordinalOverflow
        }

        if let first = dabs.first {
            let firstPrediction = first.isPredicted
            guard dabs.allSatisfy({ $0.isPredicted == firstPrediction }) else {
                throw LogicalDabBatchError.mixedProvenance
            }
            guard firstPrediction == isPredicted else {
                throw LogicalDabBatchError.provenanceMismatch(
                    expectedPredicted: isPredicted
                )
            }
        }

        for (offset, dab) in dabs.enumerated() {
            let expected = startingOrdinal + UInt64(offset)
            guard dab.ordinal == expected else {
                throw LogicalDabBatchError.noncontiguousOrdinal(
                    expected: expected,
                    actual: dab.ordinal
                )
            }
            guard dab.hasFiniteBatchValues else {
                throw LogicalDabBatchError.nonfiniteDab(
                    ordinal: dab.ordinal
                )
            }
        }

        let union = Self.union(dabs.map(\.worldBounds))
        guard union?.isFinite != false else {
            throw LogicalDabBatchError.nonfiniteBatchBounds
        }
        self.seed = seed
        self.dabs = dabs
        ordinalRange = startingOrdinal..<endOrdinal
        self.isPredicted = isPredicted
        worldBounds = union
    }

    private static func union(
        _ bounds: [AxisAlignedRect]
    ) -> AxisAlignedRect? {
        guard let first = bounds.first else { return nil }
        var minimum = first.minimum
        var maximum = first.maximum
        for bounds in bounds.dropFirst() {
            minimum = simd_min(minimum, bounds.minimum)
            maximum = simd_max(maximum, bounds.maximum)
        }
        return AxisAlignedRect(minimum: minimum, maximum: maximum)
    }
}

public struct TransformedStampFrame: Equatable, Sendable {
    public let logicalOrdinal: UInt64
    public let isometryOrdinal: UInt8
    public let brushToCanonical: Affine2D
    public let primaryGrainToCanonical: Affine2D?
    public let secondaryGrainToCanonical: Affine2D?
    public let reflected: Bool

    public init(
        logicalOrdinal: UInt64,
        isometryOrdinal: UInt8,
        brushToCanonical: Affine2D,
        primaryGrainToCanonical: Affine2D?,
        secondaryGrainToCanonical: Affine2D?,
        reflected: Bool
    ) {
        self.logicalOrdinal = logicalOrdinal
        self.isometryOrdinal = isometryOrdinal
        self.brushToCanonical = brushToCanonical
        self.primaryGrainToCanonical = primaryGrainToCanonical
        self.secondaryGrainToCanonical = secondaryGrainToCanonical
        self.reflected = reflected
    }
}

public enum LogicalDabTransformer {
    public static func transform(
        batch: LogicalDabBatch,
        through isometries: [CompiledIsometry]
    ) -> [TransformedStampFrame] {
        batch.dabs.flatMap { dab in
            isometries.map { isometry in
                TransformedStampFrame(
                    logicalOrdinal: dab.ordinal,
                    isometryOrdinal: isometry.ordinal,
                    brushToCanonical: dab.brushToWorld.concatenating(
                        isometry.localToCanonical
                    ),
                    primaryGrainToCanonical: dab.primaryGrainToWorld?.concatenating(
                        isometry.localToCanonical
                    ),
                    secondaryGrainToCanonical: dab.secondaryGrainToWorld?.concatenating(
                        isometry.localToCanonical
                    ),
                    reflected: isometry.operation.reflected
                )
            }
        }
    }
}

private extension BrushInteractionDefinition {
    var isFinite: Bool {
        [
            pickup,
            pull,
            dilution,
            charge,
            persistence,
            dirtyHaloRadius,
        ].allSatisfy(\.isFinite)
    }
}

private extension AxisAlignedRect {
    var isFinite: Bool {
        minimum.x.isFinite
            && minimum.y.isFinite
            && maximum.x.isFinite
            && maximum.y.isFinite
    }
}
