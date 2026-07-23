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
    case nonUniformTriangularSpacing(width: Float, height: Float)
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
        case let .nonUniformTriangularSpacing(width, height):
            "Triangular symmetry requires one spacing value, got \(width)x\(height)."
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
        let isTriangularPreset = configuration.presetID.isTriangular
        if isSquarePreset || isTriangularPreset {
            guard configuration.repeatSize.width == configuration.repeatSize.height else {
                if isSquarePreset {
                    throw SymmetryDescriptorError.nonSquareRepeat(
                        width: configuration.repeatSize.width,
                        height: configuration.repeatSize.height
                    )
                } else {
                    throw SymmetryDescriptorError
                        .nonUniformTriangularSpacing(
                            width: configuration.repeatSize.width,
                            height: configuration.repeatSize.height
                        )
                }
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
            family: program.family,
            images: program.images,
            ownership: program.ownership,
            displayProgram: CompiledDisplayProgram(
                family: program.family,
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
        case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
             .kaleidoscope30:
            let images = triangularImages(
                for: presetID,
                canonicalSize: canonicalSize
            )
            let stabilizers = triangularStabilizers(
                for: presetID,
                canonicalSize: canonicalSize
            )
            return CompiledProgram(
                family: .triangular,
                phase: nil,
                reflections: [],
                images: images,
                coincidentPolicy: presetID.isTriangularKaleidoscope
                    ? .triangularDihedralInvariantCoverage
                    : presetID == .hexagons
                        ? .byteEqualOnly
                        : .triangularCyclicInvariantCoverage,
                ownership: .triangularDomains(
                    triangles: triangularOwnershipTriangles(
                        for: presetID,
                        canonicalSize: canonicalSize
                    ),
                    stabilizers: stabilizers
                ),
                guideKind: triangularGuideKind(for: presetID)
            )
        }
    }

    private static func translationBasis(
        for configuration: PeriodicSymmetryConfiguration
    ) -> PeriodicTranslationBasis {
        if configuration.presetID.isTriangular {
            let spacing = configuration.repeatSize.width
            let cosine = cos(configuration.orientationRadians)
            let sine = sin(configuration.orientationRadians)
            return PeriodicTranslationBasis(
                origin: .zero,
                u: SIMD2(spacing * cosine, spacing * sine),
                v: SIMD2(
                    -sqrt(3) * spacing * sine,
                    sqrt(3) * spacing * cosine
                )
            )
        }
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

    private static func triangularImages(
        for presetID: SymmetryPresetID,
        canonicalSize: PatternSize
    ) -> [CompiledIsometry] {
        let operations = triangularPointOperations(for: presetID)
        let cosets = [
            SIMD2<Float>.zero,
            canonicalSize.simd * 0.5,
        ]
        var images: [CompiledIsometry] = []
        images.reserveCapacity(operations.count * cosets.count)

        for coset in cosets {
            for operation in operations {
                let rasterOperation = triangularRasterOperation(
                    operation,
                    canonicalSize: canonicalSize,
                    translation: coset
                )
                images.append(
                    CompiledIsometry(
                        ordinal: UInt8(images.count),
                        localToCanonical: rasterOperation,
                        operation: CompiledGroupOperation(
                            rotationStep: operation.rotationStep,
                            rotationOrder: operation.rotationOrder,
                            reflected: operation.reflected
                        )
                    )
                )
            }
        }
        return images
    }

    private static func triangularPointOperations(
        for presetID: SymmetryPresetID
    ) -> [TriangularOperationSpec] {
        let order: UInt8
        let includesReflections: Bool
        switch presetID {
        case .hexagons:
            order = 1
            includesReflections = false
        case .rotation3:
            order = 3
            includesReflections = false
        case .rotation6:
            order = 6
            includesReflections = false
        case .kaleidoscope60:
            order = 3
            includesReflections = true
        case .kaleidoscope30:
            order = 6
            includesReflections = true
        case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
             .rotational, .squareRotation, .squareKaleidoscope:
            preconditionFailure(
                "Triangular point operations require a triangular preset"
            )
        }

        var result = (0..<order).map {
            TriangularOperationSpec(
                rotationStep: $0,
                rotationOrder: order,
                reflected: false,
                reflectionSeed: .horizontal
            )
        }
        if includesReflections {
            let reflectionSeed: TriangularReflectionSeed =
                presetID == .kaleidoscope60
                    ? .thirtyDegrees
                    : .horizontal
            result.append(contentsOf: (0..<order).map {
                TriangularOperationSpec(
                    rotationStep: $0,
                    rotationOrder: order,
                    reflected: true,
                    reflectionSeed: reflectionSeed
                )
            })
        }
        return result
    }

    private static func triangularRasterOperation(
        _ operation: TriangularOperationSpec,
        canonicalSize: PatternSize,
        translation: SIMD2<Float>
    ) -> Affine2D {
        let sixthTurn: UInt8
        switch operation.rotationOrder {
        case 1:
            sixthTurn = 0
        case 3:
            sixthTurn = operation.rotationStep * 2
        case 6:
            sixthTurn = operation.rotationStep
        default:
            preconditionFailure(
                "Triangular operations require orders 1, 3, or 6"
            )
        }
        let rotation = triangularNormalizedRotation(sixthTurn)
        let normalized: (
            xAxis: SIMD2<Float>,
            yAxis: SIMD2<Float>
        )
        if operation.reflected {
            let reflection: Affine2D = switch operation.reflectionSeed {
            case .horizontal:
                Affine2D(
                    xAxis: SIMD2(1, 0),
                    yAxis: SIMD2(0, -1),
                    translation: .zero
                )
            case .thirtyDegrees:
                Affine2D(
                    xAxis: SIMD2(0.5, 0.5),
                    yAxis: SIMD2(1.5, -0.5),
                    translation: .zero
                )
            }
            let rotatedReflection = reflection.concatenating(Affine2D(
                xAxis: rotation.xAxis,
                yAxis: rotation.yAxis,
                translation: .zero
            ))
            normalized = (
                rotatedReflection.xAxis,
                rotatedReflection.yAxis
            )
        } else {
            normalized = rotation
        }
        return Affine2D(
            xAxis: SIMD2(
                normalized.xAxis.x,
                normalized.xAxis.y
                    * canonicalSize.height / canonicalSize.width
            ),
            yAxis: SIMD2(
                normalized.yAxis.x
                    * canonicalSize.width / canonicalSize.height,
                normalized.yAxis.y
            ),
            translation: translation
        )
    }

    private static func triangularNormalizedRotation(
        _ sixthTurn: UInt8
    ) -> (
        xAxis: SIMD2<Float>,
        yAxis: SIMD2<Float>
    ) {
        switch sixthTurn % 6 {
        case 0:
            (SIMD2(1, 0), SIMD2(0, 1))
        case 1:
            (SIMD2(0.5, 0.5), SIMD2(-1.5, 0.5))
        case 2:
            (SIMD2(-0.5, 0.5), SIMD2(-1.5, -0.5))
        case 3:
            (SIMD2(-1, 0), SIMD2(0, -1))
        case 4:
            (SIMD2(-0.5, -0.5), SIMD2(1.5, -0.5))
        case 5:
            (SIMD2(0.5, -0.5), SIMD2(1.5, 0.5))
        default:
            preconditionFailure("Sixth-turn modulo must be in 0...5")
        }
    }

    private static func triangularOwnershipTriangles(
        for presetID: SymmetryPresetID,
        canonicalSize: PatternSize
    ) -> [CompiledOwnershipFragment] {
        let seedRaster = [
            SIMD2<Float>.zero,
            SIMD2(canonicalSize.width * 0.5, 0),
            SIMD2(
                canonicalSize.width * 0.5,
                canonicalSize.height / 6
            ),
        ]
        let provingImages = triangularImages(
            for: .kaleidoscope30,
            canonicalSize: canonicalSize
        )

        return provingImages.indices.map { index in
            var vertices = seedRaster.map(
                provingImages[index].localToCanonical.applying
            )
            let centroid = vertices.reduce(.zero, +)
                / Float(vertices.count)
            let column = floor(centroid.x / canonicalSize.width)
            let row = floor(centroid.y / canonicalSize.height)
            let shift = SIMD2(
                -column * canonicalSize.width,
                -row * canonicalSize.height
            )
            vertices = vertices.map {
                triangularCanonicalBoundary(
                    $0 + shift,
                    canonicalSize: canonicalSize
                )
            }
            return CompiledOwnershipFragment(
                ownerOrdinal: triangularOwnerOrdinal(
                    provingTriangleIndex: index,
                    presetID: presetID
                ),
                canonicalVertices: vertices
            )
        }
    }

    private static func triangularCanonicalBoundary(
        _ point: SIMD2<Float>,
        canonicalSize: PatternSize
    ) -> SIMD2<Float> {
        SIMD2(
            triangularBoundaryCoordinate(
                point.x,
                extent: canonicalSize.width
            ),
            triangularBoundaryCoordinate(
                point.y,
                extent: canonicalSize.height
            )
        )
    }

    private static func triangularBoundaryCoordinate(
        _ value: Float,
        extent: Float
    ) -> Float {
        let scale = max(extent, 1)
        let tolerance = 16 * Float.ulpOfOne * scale
        if abs(value) <= tolerance {
            return 0
        }
        if abs(value - extent) <= tolerance {
            return extent
        }
        precondition(
            value > 0 && value < extent,
            "Triangular ownership vertex must lie in the supercell"
        )
        return value
    }

    private static func triangularOwnerOrdinal(
        provingTriangleIndex index: Int,
        presetID: SymmetryPresetID
    ) -> UInt8 {
        let coset = index / 12
        let withinCoset = index % 12
        let reflected = withinCoset >= 6
        let rotation = withinCoset % 6
        switch presetID {
        case .hexagons:
            return UInt8(coset)
        case .rotation3:
            return UInt8(coset * 3 + rotation / 2)
        case .rotation6:
            return UInt8(coset * 6 + rotation)
        case .kaleidoscope60:
            return UInt8(
                coset * 6 + (reflected ? 3 : 0) + rotation / 2
            )
        case .kaleidoscope30:
            return UInt8(index)
        case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
             .rotational, .squareRotation, .squareKaleidoscope:
            preconditionFailure(
                "Triangular ownership requires a triangular preset"
            )
        }
    }

    private static func triangularStabilizers(
        for presetID: SymmetryPresetID,
        canonicalSize: PatternSize
    ) -> [CompiledStabilizer] {
        let normalized: [(Float, Float, UInt8)]
        switch presetID {
        case .hexagons:
            normalized = []
        case .rotation3, .kaleidoscope60:
            normalized = [
                (0, 0, 3),
                (0.5, 1 / 6, 3),
                (0, 1 / 3, 3),
                (0.5, 0.5, 3),
                (0, 2 / 3, 3),
                (0.5, 5 / 6, 3),
            ]
        case .rotation6, .kaleidoscope30:
            normalized = [
                (0, 0, 6),
                (0.5, 0, 2),
                (0.5, 1 / 6, 3),
                (0.25, 0.25, 2),
                (0.75, 0.25, 2),
                (0, 1 / 3, 3),
                (0, 0.5, 2),
                (0.5, 0.5, 6),
                (0, 2 / 3, 3),
                (0.25, 0.75, 2),
                (0.75, 0.75, 2),
                (0.5, 5 / 6, 3),
            ]
        case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
             .rotational, .squareRotation, .squareKaleidoscope:
            preconditionFailure(
                "Triangular stabilizers require a triangular preset"
            )
        }

        return normalized.map { x, y, order in
            CompiledStabilizer(
                canonicalPoint: SIMD2(
                    x * canonicalSize.width,
                    y * canonicalSize.height
                ),
                kind: presetID.isTriangularKaleidoscope
                    ? .dihedral(rotationOrder: order)
                    : .rotation(order: order)
            )
        }
    }

    private static func triangularGuideKind(
        for presetID: SymmetryPresetID
    ) -> CompiledGuideKind {
        switch presetID {
        case .hexagons:
            .hexagons
        case .rotation3:
            .triangularRotation3
        case .rotation6:
            .triangularRotation6
        case .kaleidoscope60:
            .triangularKaleidoscope60
        case .kaleidoscope30:
            .triangularKaleidoscope30
        case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
             .rotational, .squareRotation, .squareKaleidoscope:
            preconditionFailure(
                "Triangular guide kind requires a triangular preset"
            )
        }
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
    let family: SymmetryKernelFamily
    let phase: PeriodicPhaseProgram?
    let reflections: SymmetryReflectionAxes
    let images: [CompiledIsometry]
    let coincidentPolicy: CoincidentImagePolicy
    let ownership: CompiledOwnership
    let guideKind: CompiledGuideKind

    init(
        family: SymmetryKernelFamily = .rectangular,
        phase: PeriodicPhaseProgram?,
        reflections: SymmetryReflectionAxes,
        images: [CompiledIsometry],
        coincidentPolicy: CoincidentImagePolicy,
        ownership: CompiledOwnership,
        guideKind: CompiledGuideKind
    ) {
        self.family = family
        self.phase = phase
        self.reflections = reflections
        self.images = images
        self.coincidentPolicy = coincidentPolicy
        self.ownership = ownership
        self.guideKind = guideKind
    }

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
        guard presetID.supportsSpacingAndOrientation else {
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
             .rotational, .hexagons, .rotation3, .rotation6,
             .kaleidoscope60, .kaleidoscope30:
            false
        }
    }

    var isTriangular: Bool {
        switch self {
        case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
             .kaleidoscope30:
            true
        case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
             .rotational, .squareRotation, .squareKaleidoscope:
            false
        }
    }

    var isTriangularKaleidoscope: Bool {
        switch self {
        case .kaleidoscope60, .kaleidoscope30:
            true
        case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
             .rotational, .squareRotation, .squareKaleidoscope, .hexagons,
             .rotation3, .rotation6:
            false
        }
    }

    var supportsSpacingAndOrientation: Bool {
        isSquare || isTriangular
    }

    var supportsMetricRepeatExport: Bool {
        supportsSpacingAndOrientation
    }
}

private struct TriangularOperationSpec {
    let rotationStep: UInt8
    let rotationOrder: UInt8
    let reflected: Bool
    let reflectionSeed: TriangularReflectionSeed
}

private enum TriangularReflectionSeed {
    case horizontal
    case thirtyDegrees
}
