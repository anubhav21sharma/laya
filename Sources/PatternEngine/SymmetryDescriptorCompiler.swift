import Foundation
import simd

public enum SymmetryDimension: Equatable, Sendable {
    case width
    case height
}

public enum SymmetryDescriptorError: Error, Equatable, Sendable {
    case nonFiniteDimension(SymmetryDimension)
    case nonIntegerDimension(SymmetryDimension)
    case dimensionOutOfRange(SymmetryDimension, value: Float)
}

public enum SymmetryDescriptorCompiler {
    public static func compile(presetID: SymmetryPresetID, tileSize: PatternSize) throws -> CompiledSymmetry {
        try validate(tileSize.width, dimension: .width)
        try validate(tileSize.height, dimension: .height)

        let identity = CompiledIsometry(ordinal: 0, localToCanonical: .identity)
        let phase: PeriodicPhaseProgram?
        let reflections: SymmetryReflectionAxes
        let images: [CompiledIsometry]
        let coincidentPolicy: CoincidentImagePolicy

        switch presetID {
        case .grid:
            phase = nil; reflections = []; images = [identity]; coincidentPolicy = .byteEqualOnly
        case .halfDrop:
            phase = PeriodicPhaseProgram(indexAxis: .x, offsetAxis: .y, fractions: [0, 0.5])
            reflections = []; images = [identity]; coincidentPolicy = .byteEqualOnly
        case .brick:
            phase = PeriodicPhaseProgram(indexAxis: .y, offsetAxis: .x, fractions: [0, 0.5])
            reflections = []; images = [identity]; coincidentPolicy = .byteEqualOnly
        case .mirrorX:
            phase = nil; reflections = [.x]; images = [identity]; coincidentPolicy = .byteEqualOnly
        case .mirrorY:
            phase = nil; reflections = [.y]; images = [identity]; coincidentPolicy = .byteEqualOnly
        case .mirrorXY:
            phase = nil; reflections = [.x, .y]; images = [identity]; coincidentPolicy = .byteEqualOnly
        case .rotational:
            phase = nil
            reflections = []
            images = [
                identity,
                CompiledIsometry(ordinal: 1, localToCanonical: Affine2D(xAxis: SIMD2(-1, 0), yAxis: SIMD2(0, -1), translation: tileSize.simd)),
            ]
            coincidentPolicy = .halfTurnInvariantCoverage
        }

        return CompiledSymmetry(
            presetID: presetID,
            domain: .periodic(CompiledPeriodicDomain(
                tileSize: tileSize,
                translationBasis: PeriodicTranslationBasis(origin: .zero, u: SIMD2(tileSize.width, 0), v: SIMD2(0, tileSize.height)),
                phase: phase,
                alternatingReflections: reflections,
                coincidentImagePolicy: coincidentPolicy
            )),
            family: .rectangular,
            images: images,
            ownership: .rectangularHalfOpen,
            displayProgram: CompiledDisplayProgram(family: .rectangular, presetWireID: presetID.rawValue),
            rasterMetric: .identity,
            exportCapability: .rectangularRepeat,
            cost: SymmetryCostBound(maximumImagesPerCell: images.count)
        )
    }

    private static func validate(_ value: Float, dimension: SymmetryDimension) throws {
        guard value.isFinite else { throw SymmetryDescriptorError.nonFiniteDimension(dimension) }
        guard value.rounded(.towardZero) == value else { throw SymmetryDescriptorError.nonIntegerDimension(dimension) }
        guard (64...4096).contains(value) else { throw SymmetryDescriptorError.dimensionOutOfRange(dimension, value: value) }
    }
}
