import Foundation
import simd

public enum SymmetryKernelFamily: UInt32, Codable, Sendable {
    case rectangular = 0
    case triangular = 1
    case radial = 2
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
    public let tileSize: PatternSize
    public let translationBasis: PeriodicTranslationBasis
    public let phase: PeriodicPhaseProgram?
    public let alternatingReflections: SymmetryReflectionAxes
    public let coincidentImagePolicy: CoincidentImagePolicy
}

public enum CompiledSymmetryDomain: Equatable, Sendable {
    case periodic(CompiledPeriodicDomain)

    public var periodic: CompiledPeriodicDomain? {
        guard case let .periodic(value) = self else { return nil }
        return value
    }
}

public struct CompiledIsometry: Equatable, Sendable {
    public let ordinal: UInt8
    public let localToCanonical: Affine2D
}

public enum CompiledOwnership: Equatable, Sendable { case rectangularHalfOpen }

public struct CompiledDisplayProgram: Equatable, Sendable {
    public let family: SymmetryKernelFamily
    public let presetWireID: UInt32
}

public struct RasterMetric2D: Equatable, Sendable {
    public let worldToRaster: Affine2D
    public let rasterToWorld: Affine2D

    public static let identity = RasterMetric2D(worldToRaster: .identity, rasterToWorld: .identity)
}

public enum SymmetryExportCapability: Equatable, Sendable { case rectangularRepeat }

public struct SymmetryCostBound: Equatable, Sendable {
    public let maximumImagesPerCell: Int
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
