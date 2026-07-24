import Foundation
import simd

public enum SymmetryKernelFamily: UInt32, Codable, Sendable {
    case rectangular = 0
    case triangular = 1
    case radial = 2
}

public struct PeriodicSymmetryConfiguration: Equatable, Sendable {
    public let presetID: SymmetryPresetID
    public let repeatSize: PatternSize
    public let orientationRadians: Float

    public init(
        presetID: SymmetryPresetID,
        repeatSize: PatternSize,
        orientationRadians: Float = 0
    ) {
        self.presetID = presetID
        self.repeatSize = repeatSize
        self.orientationRadians = orientationRadians
    }

    public static func legacy(
        presetID: SymmetryPresetID,
        tileSize: PatternSize
    ) -> Self {
        Self(
            presetID: presetID,
            repeatSize: tileSize,
            orientationRadians: 0
        )
    }
}

public enum RadialSymmetryKind: UInt32, Codable, Equatable, Sendable {
    case mirror = 0
    case rotation = 1
    case mandala = 2
}

public struct RadialSymmetryConfiguration: Equatable, Sendable {
    public let kind: RadialSymmetryKind
    public let rayCount: Int
    public let center: WorldPoint
    public let referenceAngleRadians: Float

    public init(
        kind: RadialSymmetryKind,
        rayCount: Int,
        center: WorldPoint,
        referenceAngleRadians: Float = 0
    ) {
        self.kind = kind
        self.rayCount = rayCount
        self.center = center
        self.referenceAngleRadians = referenceAngleRadians
    }
}

public enum FiniteSymmetryConfiguration: Equatable, Sendable {
    case plain
    case radial(RadialSymmetryConfiguration)
}

public enum SymmetryDocumentConfiguration: Equatable, Sendable {
    case periodic(PeriodicSymmetryConfiguration)
    case finite(FiniteSymmetryConfiguration)

    public var domainID: SymmetryDocumentDomainID {
        switch self {
        case .periodic:
            .periodic
        case .finite:
            .finite
        }
    }
}

public enum SymmetryAxis: Equatable, Sendable {
    case x
    case y
}

public struct SymmetryReflectionAxes: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let x = Self(rawValue: 1 << 0)
    public static let y = Self(rawValue: 1 << 1)
}

public struct PeriodicPhaseProgram: Equatable, Sendable {
    public let indexAxis: SymmetryAxis
    public let offsetAxis: SymmetryAxis
    public let fractions: [Float]

    public init(indexAxis: SymmetryAxis, offsetAxis: SymmetryAxis, fractions: [Float]) {
        self.indexAxis = indexAxis
        self.offsetAxis = offsetAxis
        self.fractions = fractions
    }
}

public enum CoincidentImagePolicy: Equatable, Sendable {
    case byteEqualOnly
    case halfTurnInvariantCoverage
    case quarterTurnInvariantCoverage
    case squareDihedralInvariantCoverage
    case triangularCyclicInvariantCoverage
    case triangularDihedralInvariantCoverage
    case radialCyclicInvariantCoverage
    case radialDihedralInvariantCoverage
}

public struct PeriodicTranslationBasis: Equatable, Sendable {
    public let origin: SIMD2<Float>
    public let u: SIMD2<Float>
    public let v: SIMD2<Float>

    public init(origin: SIMD2<Float>, u: SIMD2<Float>, v: SIMD2<Float>) {
        self.origin = origin
        self.u = u
        self.v = v
    }
}

public struct CompiledPeriodicDomain: Equatable, Sendable {
    public let configuration: PeriodicSymmetryConfiguration
    public let tileSize: PatternSize
    public let translationBasis: PeriodicTranslationBasis
    public let worldToLattice: Affine2D
    public let phase: PeriodicPhaseProgram?
    public let alternatingReflections: SymmetryReflectionAxes
    public let coincidentImagePolicy: CoincidentImagePolicy
}

public struct CompiledRadialDomain: Equatable, Sendable {
    public let configuration: RadialSymmetryConfiguration?
    public let canvasSize: PixelSize
    public let sectorAngleRadians: Float
    public let displayedSectorCount: Int
    public let maximumRadius: Float
    public let layout: RadialSectorLayout?
    public let coincidentImagePolicy: CoincidentImagePolicy

    public var isPlain: Bool { configuration == nil }
}

public struct CompiledFiniteDomain: Equatable, Sendable {
    public let configuration: FiniteSymmetryConfiguration
    public let radial: CompiledRadialDomain
}

public enum CompiledSymmetryDomain: Equatable, Sendable {
    case periodic(CompiledPeriodicDomain)
    case finite(CompiledFiniteDomain)

    public var periodic: CompiledPeriodicDomain? {
        guard case let .periodic(value) = self else { return nil }
        return value
    }

    public var finite: CompiledFiniteDomain? {
        guard case let .finite(value) = self else { return nil }
        return value
    }
}

public struct CompiledGroupOperation: Equatable, Sendable {
    public let rotationStep: UInt8
    public let rotationOrder: UInt8
    public let reflected: Bool

    public init(
        rotationStep: UInt8,
        rotationOrder: UInt8,
        reflected: Bool
    ) {
        precondition(rotationOrder > 0)
        precondition(rotationStep < rotationOrder)
        self.rotationStep = rotationStep
        self.rotationOrder = rotationOrder
        self.reflected = reflected
    }

    public init(quarterTurns: UInt8, reflected: Bool) {
        precondition(quarterTurns < 4)
        self.init(
            rotationStep: quarterTurns,
            rotationOrder: 4,
            reflected: reflected
        )
    }

    public static let identity = Self(quarterTurns: 0, reflected: false)

    public var quarterTurns: UInt8 {
        precondition(
            rotationOrder == 4,
            "Only quarter-turn operations expose a quarterTurns value"
        )
        return rotationStep
    }
}

public struct CompiledIsometry: Equatable, Sendable {
    public let ordinal: UInt8
    public let localToCanonical: Affine2D
    public let operation: CompiledGroupOperation

    public init(
        ordinal: UInt8,
        localToCanonical: Affine2D
    ) {
        self.init(
            ordinal: ordinal,
            localToCanonical: localToCanonical,
            operation: .identity
        )
    }

    public init(
        ordinal: UInt8,
        localToCanonical: Affine2D,
        operation: CompiledGroupOperation
    ) {
        self.ordinal = ordinal
        self.localToCanonical = localToCanonical
        self.operation = operation
    }
}

public struct CompiledOwnershipFragment: Equatable, Sendable {
    public let ownerOrdinal: UInt8
    public let canonicalVertices: [SIMD2<Float>]

    public init(
        ownerOrdinal: UInt8,
        canonicalVertices: [SIMD2<Float>]
    ) {
        self.ownerOrdinal = ownerOrdinal
        self.canonicalVertices = canonicalVertices
    }
}

public enum CompiledStabilizerKind: Equatable, Sendable {
    case rotation(order: UInt8)
    case dihedral(rotationOrder: UInt8)
}

public struct CompiledStabilizer: Equatable, Sendable {
    public let canonicalPoint: SIMD2<Float>
    public let kind: CompiledStabilizerKind

    public init(
        canonicalPoint: SIMD2<Float>,
        kind: CompiledStabilizerKind
    ) {
        self.canonicalPoint = canonicalPoint
        self.kind = kind
    }
}

public enum CompiledOwnership: Equatable, Sendable {
    case rectangularHalfOpen
    case squareRotation(
        sectors: [CompiledOwnershipFragment],
        stabilizers: [CompiledStabilizer]
    )
    case squareMirrorTriangles(
        triangles: [CompiledOwnershipFragment],
        stabilizers: [CompiledStabilizer]
    )
    case triangularDomains(
        triangles: [CompiledOwnershipFragment],
        stabilizers: [CompiledStabilizer]
    )
    case radialSector(stabilizers: [CompiledStabilizer])
}

public enum CompiledGuideKind: UInt32, Equatable, Sendable {
    case rectangular = 0
    case squareRotation = 1
    case squareKaleidoscope = 2
    case hexagons = 3
    case triangularRotation3 = 4
    case triangularRotation6 = 5
    case triangularKaleidoscope60 = 6
    case triangularKaleidoscope30 = 7
    case finitePlain = 8
    case radialRotation = 9
    case radialMirror = 10
    case radialMandala = 11
}

public struct CompiledDisplayProgram: Equatable, Sendable {
    public let family: SymmetryKernelFamily
    public let presetWireID: UInt32
    public let guideKind: CompiledGuideKind
}

public struct RasterMetric2D: Equatable, Sendable {
    public let worldToRaster: Affine2D
    public let rasterToWorld: Affine2D

    public static let identity = RasterMetric2D(worldToRaster: .identity, rasterToWorld: .identity)
}

public enum SymmetryExportCapability: Equatable, Sendable {
    case rectangularRepeat
    case finiteCanvas
}

public struct SymmetryCostBound: Equatable, Sendable {
    public let maximumImagesPerCell: Int
    public let maximumProjectedInstancesPerDab: Int
}

public struct CompiledSymmetry: Equatable, Sendable {
    public let presetID: SymmetryPresetID
    public let domain: CompiledSymmetryDomain
    public let family: SymmetryKernelFamily
    public let images: [CompiledIsometry]
    public let ownership: CompiledOwnership
    public let displayProgram: CompiledDisplayProgram
    public let rasterMetric: RasterMetric2D
    public let exportCapability: SymmetryExportCapability
    public let cost: SymmetryCostBound
}
