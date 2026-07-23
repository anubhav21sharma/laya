import Foundation
import simd

public enum SymmetryDimension: Equatable, Sendable {
    case width
    case height
}

public enum SymmetryDescriptorError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case nonFiniteDimension(SymmetryDimension)
    case nonIntegerDimension(SymmetryDimension)
    case dimensionOutOfRange(SymmetryDimension, value: Float)
    case nonFiniteOrientation
    case unsupportedOrientation(SymmetryPresetID)
    case nonSquareRepeat(width: Float, height: Float)
    case singularTranslationBasis
    case imageCostExceedsLimit(actual: Int, maximum: Int)
    case projectionCostExceedsLimit(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .nonFiniteDimension(dimension):
            "Symmetry \(dimension.label) must be finite."
        case let .nonIntegerDimension(dimension):
            "Symmetry \(dimension.label) must be a whole number."
        case let .dimensionOutOfRange(dimension, value):
            "Symmetry \(dimension.label) \(value) is outside 64...4096."
        case .nonFiniteOrientation:
            "Symmetry orientation must be finite."
        case let .unsupportedOrientation(preset):
            "Preset \(preset.rawValue) does not support orientation."
        case let .nonSquareRepeat(width, height):
            "Square symmetry requires equal repeat extents, got \(width)x\(height)."
        case .singularTranslationBasis:
            "Symmetry translation basis is singular."
        case let .imageCostExceedsLimit(actual, maximum):
            "Symmetry image count \(actual) exceeds the limit \(maximum)."
        case let .projectionCostExceedsLimit(actual, maximum):
            "Symmetry worst-case projected instance count \(actual) exceeds the limit \(maximum)."
        }
    }
}

private extension SymmetryDimension {
    var label: String {
        switch self {
        case .width: "width"
        case .height: "height"
        }
    }
}

public enum SymmetryDescriptorCompiler {
    public static let maximumImagesPerCell = 24

    public static func compile(
        presetID: SymmetryPresetID,
        tileSize: PatternSize
    ) throws -> CompiledSymmetry {
        let canonicalRasterSize = try pixelSize(from: tileSize)
        return try compile(
            configuration: .defaultConfiguration(
                presetID: presetID,
                canonicalRasterSize: canonicalRasterSize
            ),
            canonicalRasterSize: canonicalRasterSize
        )
    }

    public static func compile(
        configuration: PeriodicSymmetryConfiguration,
        canonicalRasterSize: PixelSize
    ) throws -> CompiledSymmetry {
        let canonicalSize = PatternSize(
            width: Float(canonicalRasterSize.width),
            height: Float(canonicalRasterSize.height)
        )
        try validate(canonicalSize.width, dimension: .width)
        try validate(canonicalSize.height, dimension: .height)
        try validateRepeatDimension(
            configuration.repeatSize.width,
            dimension: .width
        )
        try validateRepeatDimension(
            configuration.repeatSize.height,
            dimension: .height
        )

        guard configuration.orientationRadians.isFinite else {
            throw SymmetryDescriptorError.nonFiniteOrientation
        }
        let orientation = normalizedAngle(configuration.orientationRadians)
        let isSquarePreset = configuration.presetID.isSquare
        if isSquarePreset {
            guard configuration.repeatSize.width == configuration.repeatSize.height else {
                throw SymmetryDescriptorError.nonSquareRepeat(
                    width: configuration.repeatSize.width,
                    height: configuration.repeatSize.height
                )
            }
        } else if orientation != 0 {
            throw SymmetryDescriptorError.unsupportedOrientation(
                configuration.presetID
            )
        }

        let normalizedConfiguration = PeriodicSymmetryConfiguration(
            presetID: configuration.presetID,
            repeatSize: configuration.repeatSize,
            orientationRadians: orientation
        )
        let basis = translationBasis(for: normalizedConfiguration)
        let latticeToWorld = Affine2D(
            xAxis: basis.u,
            yAxis: basis.v,
            translation: basis.origin
        )
        let determinant = basis.u.x * basis.v.y - basis.u.y * basis.v.x
        guard determinant.isFinite, abs(determinant) >= Float.ulpOfOne else {
            throw SymmetryDescriptorError.singularTranslationBasis
        }
        let worldToLattice = latticeToWorld.inverted()
        let latticeToRaster = Affine2D(
            xAxis: SIMD2(canonicalSize.width, 0),
            yAxis: SIMD2(0, canonicalSize.height),
            translation: .zero
        )
        let worldToRaster = worldToLattice.concatenating(latticeToRaster)
        let rasterMetric = RasterMetric2D(
            worldToRaster: worldToRaster,
            rasterToWorld: worldToRaster.inverted()
        )

        let program = try compiledProgram(
            for: normalizedConfiguration.presetID,
            canonicalSize: canonicalSize
        )
        guard program.images.count <= maximumImagesPerCell else {
            throw SymmetryDescriptorError.imageCostExceedsLimit(
                actual: program.images.count,
                maximum: maximumImagesPerCell
            )
        }
        let maximumProjectedInstances = worstCaseProjectedInstanceCount(
            worldToLattice: worldToLattice,
            canonicalRasterSize: canonicalRasterSize,
            imagesPerCell: program.images.count
        )
        guard maximumProjectedInstances
            <= TransientStrokeBufferContract
                .visibleEpochProjectedInstanceCapacity
        else {
            throw SymmetryDescriptorError.projectionCostExceedsLimit(
                actual: maximumProjectedInstances,
                maximum: TransientStrokeBufferContract
                    .visibleEpochProjectedInstanceCapacity
            )
        }

        return CompiledSymmetry(
            presetID: normalizedConfiguration.presetID,
            domain: .periodic(CompiledPeriodicDomain(
                configuration: normalizedConfiguration,
                tileSize: canonicalSize,
                translationBasis: basis,
                worldToLattice: worldToLattice,
                phase: program.phase,
                alternatingReflections: program.reflections,
                coincidentImagePolicy: program.coincidentPolicy
            )),
            family: .rectangular,
            images: program.images,
            ownership: program.ownership,
            displayProgram: CompiledDisplayProgram(
                family: .rectangular,
                presetWireID: normalizedConfiguration.presetID.rawValue,
                guideKind: program.guideKind
            ),
            rasterMetric: rasterMetric,
            exportCapability: .rectangularRepeat,
            cost: SymmetryCostBound(
                maximumImagesPerCell: program.images.count,
                maximumProjectedInstancesPerDab:
                    maximumProjectedInstances
            )
        )
    }

    private static func compiledProgram(
        for presetID: SymmetryPresetID,
        canonicalSize: PatternSize
    ) throws -> CompiledProgram {
        let identity = CompiledIsometry(
            ordinal: 0,
            localToCanonical: .identity
        )
        switch presetID {
        case .grid:
            return .legacy(identity: identity)
        case .halfDrop:
            return .legacy(
                identity: identity,
                phase: PeriodicPhaseProgram(
                    indexAxis: .x,
                    offsetAxis: .y,
                    fractions: [0, 0.5]
                )
            )
        case .brick:
            return .legacy(
                identity: identity,
                phase: PeriodicPhaseProgram(
                    indexAxis: .y,
                    offsetAxis: .x,
                    fractions: [0, 0.5]
                )
            )
        case .mirrorX:
            return .legacy(identity: identity, reflections: [.x])
        case .mirrorY:
            return .legacy(identity: identity, reflections: [.y])
        case .mirrorXY:
            return .legacy(identity: identity, reflections: [.x, .y])
        case .rotational:
            return CompiledProgram(
                phase: nil,
                reflections: [],
                images: [
                    identity,
                    CompiledIsometry(
                        ordinal: 1,
                        localToCanonical: Affine2D(
                            xAxis: SIMD2(-1, 0),
                            yAxis: SIMD2(0, -1),
                            translation: canonicalSize.simd
                        ),
                        operation: CompiledGroupOperation(
                            quarterTurns: 2,
                            reflected: false
                        )
                    ),
                ],
                coincidentPolicy: .halfTurnInvariantCoverage,
                ownership: .rectangularHalfOpen,
                guideKind: .rectangular
            )
        case .squareRotation:
            let images = squareImages(
                canonicalSize: canonicalSize,
                includeReflections: false
            )
            return CompiledProgram(
                phase: nil,
                reflections: [],
                images: images,
                coincidentPolicy: .quarterTurnInvariantCoverage,
                ownership: .squareRotation(
                    sectors: squareRotationSectors(canonicalSize),
                    stabilizers: squareRotationStabilizers(canonicalSize)
                ),
                guideKind: .squareRotation
            )
        case .squareKaleidoscope:
            let images = squareImages(
                canonicalSize: canonicalSize,
                includeReflections: true
            )
            return CompiledProgram(
                phase: nil,
                reflections: [],
                images: images,
                coincidentPolicy: .squareDihedralInvariantCoverage,
                ownership: .squareMirrorTriangles(
                    triangles: squareMirrorTriangles(canonicalSize),
                    stabilizers: squareKaleidoscopeStabilizers(canonicalSize)
                ),
                guideKind: .squareKaleidoscope
            )
        }
    }

    private static func translationBasis(
        for configuration: PeriodicSymmetryConfiguration
    ) -> PeriodicTranslationBasis {
        guard configuration.presetID.isSquare else {
            return PeriodicTranslationBasis(
                origin: .zero,
                u: SIMD2(configuration.repeatSize.width, 0),
                v: SIMD2(0, configuration.repeatSize.height)
            )
        }
        let side = configuration.repeatSize.width
        let cosine = cos(configuration.orientationRadians)
        let sine = sin(configuration.orientationRadians)
        return PeriodicTranslationBasis(
            origin: .zero,
            u: SIMD2(side * cosine, side * sine),
            v: SIMD2(-side * sine, side * cosine)
        )
    }

    private static func squareImages(
        canonicalSize: PatternSize,
        includeReflections: Bool
    ) -> [CompiledIsometry] {
        let width = canonicalSize.width
        let height = canonicalSize.height
        let widthPerHeight = width / height
        let heightPerWidth = height / width
        var images = [
            CompiledIsometry(ordinal: 0, localToCanonical: .identity),
            CompiledIsometry(
                ordinal: 1,
                localToCanonical: Affine2D(
                    xAxis: SIMD2(0, heightPerWidth),
                    yAxis: SIMD2(-widthPerHeight, 0),
                    translation: SIMD2(width, 0)
                ),
                operation: CompiledGroupOperation(
                    quarterTurns: 1,
                    reflected: false
                )
            ),
            CompiledIsometry(
                ordinal: 2,
                localToCanonical: Affine2D(
                    xAxis: SIMD2(-1, 0),
                    yAxis: SIMD2(0, -1),
                    translation: SIMD2(width, height)
                ),
                operation: CompiledGroupOperation(
                    quarterTurns: 2,
                    reflected: false
                )
            ),
            CompiledIsometry(
                ordinal: 3,
                localToCanonical: Affine2D(
                    xAxis: SIMD2(0, -heightPerWidth),
                    yAxis: SIMD2(widthPerHeight, 0),
                    translation: SIMD2(0, height)
                ),
                operation: CompiledGroupOperation(
                    quarterTurns: 3,
                    reflected: false
                )
            ),
        ]
        guard includeReflections else { return images }
        images.append(contentsOf: [
            CompiledIsometry(
                ordinal: 4,
                localToCanonical: Affine2D(
                    xAxis: SIMD2(1, 0),
                    yAxis: SIMD2(0, -1),
                    translation: SIMD2(0, height)
                ),
                operation: CompiledGroupOperation(
                    quarterTurns: 0,
                    reflected: true
                )
            ),
            CompiledIsometry(
                ordinal: 5,
                localToCanonical: Affine2D(
                    xAxis: SIMD2(0, heightPerWidth),
                    yAxis: SIMD2(widthPerHeight, 0),
                    translation: .zero
                ),
                operation: CompiledGroupOperation(
                    quarterTurns: 1,
                    reflected: true
                )
            ),
            CompiledIsometry(
                ordinal: 6,
                localToCanonical: Affine2D(
                    xAxis: SIMD2(-1, 0),
                    yAxis: SIMD2(0, 1),
                    translation: SIMD2(width, 0)
                ),
                operation: CompiledGroupOperation(
                    quarterTurns: 2,
                    reflected: true
                )
            ),
            CompiledIsometry(
                ordinal: 7,
                localToCanonical: Affine2D(
                    xAxis: SIMD2(0, -heightPerWidth),
                    yAxis: SIMD2(-widthPerHeight, 0),
                    translation: SIMD2(width, height)
                ),
                operation: CompiledGroupOperation(
                    quarterTurns: 3,
                    reflected: true
                )
            ),
        ])
        return images
    }

    private static func squareRotationSectors(
        _ size: PatternSize
    ) -> [CompiledOwnershipFragment] {
        let center = size.simd * 0.5
        let corners = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(size.width, 0),
            SIMD2<Float>(size.width, size.height),
            SIMD2<Float>(0, size.height),
        ]
        return corners.indices.map { index in
            CompiledOwnershipFragment(
                ownerOrdinal: UInt8(index),
                canonicalVertices: [
                    center,
                    corners[index],
                    corners[(index + 1) % corners.count],
                ]
            )
        }
    }

    private static func squareMirrorTriangles(
        _ size: PatternSize
    ) -> [CompiledOwnershipFragment] {
        let center = size.simd * 0.5
        let boundary = [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(size.width * 0.5, 0),
            SIMD2<Float>(size.width, 0),
            SIMD2<Float>(size.width, size.height * 0.5),
            SIMD2<Float>(size.width, size.height),
            SIMD2<Float>(size.width * 0.5, size.height),
            SIMD2<Float>(0, size.height),
            SIMD2<Float>(0, size.height * 0.5),
        ]
        return boundary.indices.map { index in
            CompiledOwnershipFragment(
                ownerOrdinal: UInt8(index),
                canonicalVertices: [
                    center,
                    boundary[index],
                    boundary[(index + 1) % boundary.count],
                ]
            )
        }
    }

    private static func squareRotationStabilizers(
        _ size: PatternSize
    ) -> [CompiledStabilizer] {
        [
            CompiledStabilizer(
                canonicalPoint: .zero,
                kind: .rotation(order: 4)
            ),
            CompiledStabilizer(
                canonicalPoint: size.simd * 0.5,
                kind: .rotation(order: 4)
            ),
            CompiledStabilizer(
                canonicalPoint: SIMD2(size.width * 0.5, 0),
                kind: .rotation(order: 2)
            ),
            CompiledStabilizer(
                canonicalPoint: SIMD2(0, size.height * 0.5),
                kind: .rotation(order: 2)
            ),
        ]
    }

    private static func squareKaleidoscopeStabilizers(
        _ size: PatternSize
    ) -> [CompiledStabilizer] {
        [
            CompiledStabilizer(
                canonicalPoint: .zero,
                kind: .dihedral(rotationOrder: 4)
            ),
            CompiledStabilizer(
                canonicalPoint: size.simd * 0.5,
                kind: .dihedral(rotationOrder: 4)
            ),
            CompiledStabilizer(
                canonicalPoint: SIMD2(size.width * 0.5, 0),
                kind: .dihedral(rotationOrder: 2)
            ),
            CompiledStabilizer(
                canonicalPoint: SIMD2(0, size.height * 0.5),
                kind: .dihedral(rotationOrder: 2)
            ),
        ]
    }

    private static func normalizedAngle(_ value: Float) -> Float {
        let fullTurn = 2 * Float.pi
        var result = value.truncatingRemainder(dividingBy: fullTurn)
        if result >= Float.pi {
            result -= fullTurn
        } else if result < -Float.pi {
            result += fullTurn
        }
        return result == 0 ? 0 : result
    }

    private static func pixelSize(from size: PatternSize) throws -> PixelSize {
        try validate(size.width, dimension: .width)
        try validate(size.height, dimension: .height)
        return PixelSize(width: Int(size.width), height: Int(size.height))
    }

    private static func validate(
        _ value: Float,
        dimension: SymmetryDimension
    ) throws {
        guard value.isFinite else {
            throw SymmetryDescriptorError.nonFiniteDimension(dimension)
        }
        guard value.rounded(.towardZero) == value else {
            throw SymmetryDescriptorError.nonIntegerDimension(dimension)
        }
        guard (64...4096).contains(value) else {
            throw SymmetryDescriptorError.dimensionOutOfRange(
                dimension,
                value: value
            )
        }
    }

    private static func validateRepeatDimension(
        _ value: Float,
        dimension: SymmetryDimension
    ) throws {
        guard value.isFinite else {
            throw SymmetryDescriptorError.nonFiniteDimension(dimension)
        }
        // Repeat geometry is expressed in continuous world units. The
        // integer 64...4096 contract belongs only to canonical raster and
        // export density.
        guard value > 0 else {
            throw SymmetryDescriptorError.dimensionOutOfRange(
                dimension,
                value: value
            )
        }
    }

    private static func worstCaseProjectedInstanceCount(
        worldToLattice: Affine2D,
        canonicalRasterSize: PixelSize,
        imagesPerCell: Int
    ) -> Int {
        // The editor and renderer cap a dab radius at the same value. Project
        // that largest axis-aligned world footprint through the compiled
        // lattice inverse, then include the one possible boundary-crossing
        // cell on each axis. This rejects configurations that could enumerate
        // more instances than one visible replay epoch can retain.
        let radius = min(
            1_000,
            4 * Float(
                min(
                    canonicalRasterSize.width,
                    canonicalRasterSize.height
                )
            )
        )
        // Brush-local bounds are square. A round brush's affine basis can
        // rotate that square by 45 degrees, so its world AABB can span
        // 2 * sqrt(2) * radius on either axis.
        let diameter = Double(radius * 2 * sqrt(2))
        let columnSpan = diameter * (
            abs(Double(worldToLattice.xAxis.x))
                + abs(Double(worldToLattice.yAxis.x))
        )
        let rowSpan = diameter * (
            abs(Double(worldToLattice.xAxis.y))
                + abs(Double(worldToLattice.yAxis.y))
        )
        let columns = ceil(columnSpan) + 1
        let rows = ceil(rowSpan) + 1
        let projected = columns * rows * Double(imagesPerCell)
        guard projected.isFinite, projected < Double(Int.max) else {
            return Int.max
        }
        return Int(projected)
    }
}

private struct CompiledProgram {
    let phase: PeriodicPhaseProgram?
    let reflections: SymmetryReflectionAxes
    let images: [CompiledIsometry]
    let coincidentPolicy: CoincidentImagePolicy
    let ownership: CompiledOwnership
    let guideKind: CompiledGuideKind

    static func legacy(
        identity: CompiledIsometry,
        phase: PeriodicPhaseProgram? = nil,
        reflections: SymmetryReflectionAxes = []
    ) -> Self {
        Self(
            phase: phase,
            reflections: reflections,
            images: [identity],
            coincidentPolicy: .byteEqualOnly,
            ownership: .rectangularHalfOpen,
            guideKind: .rectangular
        )
    }
}

public extension PeriodicSymmetryConfiguration {
    static func defaultConfiguration(
        presetID: SymmetryPresetID,
        canonicalRasterSize: PixelSize
    ) -> Self {
        let rasterSize = PatternSize(
            width: Float(canonicalRasterSize.width),
            height: Float(canonicalRasterSize.height)
        )
        guard presetID.isSquare else {
            return .legacy(presetID: presetID, tileSize: rasterSize)
        }
        let side = Float(min(
            canonicalRasterSize.width,
            canonicalRasterSize.height
        ))
        return Self(
            presetID: presetID,
            repeatSize: PatternSize(width: side, height: side),
            orientationRadians: 0
        )
    }
}

public extension SymmetryPresetID {
    var isSquare: Bool {
        switch self {
        case .squareRotation, .squareKaleidoscope:
            true
        case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
             .rotational:
            false
        }
    }
}
