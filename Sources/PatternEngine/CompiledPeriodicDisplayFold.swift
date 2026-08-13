import Foundation
import simd

public enum CompiledPeriodicFoldCoordinateSpace: UInt32, Sendable {
    case axisAlignedRepeat = 0
    case unitLattice = 1
}

public struct CompiledPeriodicDisplayFold: Equatable, Sendable {
    public let family: SymmetryKernelFamily
    public let coordinateSpace: CompiledPeriodicFoldCoordinateSpace
    public let worldToLattice: Affine2D
    public let canonicalSize: PatternSize
    public let repeatSize: PatternSize
    public let phase: PeriodicPhaseProgram?
    public let alternatingReflections: SymmetryReflectionAxes

    init(
        family: SymmetryKernelFamily,
        coordinateSpace: CompiledPeriodicFoldCoordinateSpace,
        worldToLattice: Affine2D,
        canonicalSize: PatternSize,
        repeatSize: PatternSize,
        phase: PeriodicPhaseProgram?,
        alternatingReflections: SymmetryReflectionAxes
    ) {
        precondition(family != .radial)
        precondition(phase == nil || phase?.fractions.isEmpty == false)
        self.family = family
        self.coordinateSpace = coordinateSpace
        self.worldToLattice = worldToLattice
        self.canonicalSize = canonicalSize
        self.repeatSize = repeatSize
        self.phase = phase
        self.alternatingReflections = alternatingReflections
    }

    public func applying(to world: WorldPoint) -> CanonicalPoint {
        switch coordinateSpace {
        case .axisAlignedRepeat:
            applyingInAxisAlignedRepeat(to: world)
        case .unitLattice:
            applyingInUnitLattice(to: world)
        }
    }

    private func applyingInAxisAlignedRepeat(
        to world: WorldPoint
    ) -> CanonicalPoint {
        let cell = axisAlignedCell(containing: world)
        var phasedPoint = world.simd
        if let phase {
            let index = switch phase.indexAxis {
            case .x: cell.column
            case .y: cell.row
            }
            let offset = phaseOffset(for: index, program: phase)
            switch phase.offsetAxis {
            case .x: phasedPoint.x -= offset
            case .y: phasedPoint.y -= offset
            }
        }

        let localX = Self.positiveModulo(
            phasedPoint.x,
            extent: repeatSize.width
        ) * canonicalSize.width / repeatSize.width
        let localY = Self.positiveModulo(
            phasedPoint.y,
            extent: repeatSize.height
        ) * canonicalSize.height / repeatSize.height
        let reflectsX = alternatingReflections.contains(.x)
            && !cell.column.isMultiple(of: 2)
        let reflectsY = alternatingReflections.contains(.y)
            && !cell.row.isMultiple(of: 2)
        return CanonicalPoint(
            x: reflectsX
                ? Self.positiveModulo(
                    canonicalSize.width - localX,
                    extent: canonicalSize.width
                )
                : localX,
            y: reflectsY
                ? Self.positiveModulo(
                    canonicalSize.height - localY,
                    extent: canonicalSize.height
                )
                : localY
        )
    }

    private func applyingInUnitLattice(
        to world: WorldPoint
    ) -> CanonicalPoint {
        let lattice = worldToLattice.applying(to: world.simd)
        if family == .rectangular {
            _ = checkedCellIndex(
                coordinate: lattice.x,
                extent: 1,
                phase: 0,
                axis: .x
            )
            _ = checkedCellIndex(
                coordinate: lattice.y,
                extent: 1,
                phase: 0,
                axis: .y
            )
        }
        return CanonicalPoint(
            x: Self.positiveModulo(lattice.x, extent: 1)
                * canonicalSize.width,
            y: Self.positiveModulo(lattice.y, extent: 1)
                * canonicalSize.height
        )
    }

    private func axisAlignedCell(containing world: WorldPoint) -> CellIndex {
        guard let phase else {
            return CellIndex(
                column: checkedCellIndex(
                    coordinate: world.x,
                    extent: repeatSize.width,
                    phase: 0,
                    axis: .x
                ),
                row: checkedCellIndex(
                    coordinate: world.y,
                    extent: repeatSize.height,
                    phase: 0,
                    axis: .y
                )
            )
        }

        switch phase.indexAxis {
        case .x:
            let column = checkedCellIndex(
                coordinate: world.x,
                extent: repeatSize.width,
                phase: 0,
                axis: .x
            )
            let offset = phaseOffset(for: column, program: phase)
            return CellIndex(
                column: column,
                row: checkedCellIndex(
                    coordinate: world.y,
                    extent: repeatSize.height,
                    phase: offset,
                    axis: .y
                )
            )
        case .y:
            let row = checkedCellIndex(
                coordinate: world.y,
                extent: repeatSize.height,
                phase: 0,
                axis: .y
            )
            let offset = phaseOffset(for: row, program: phase)
            return CellIndex(
                column: checkedCellIndex(
                    coordinate: world.x,
                    extent: repeatSize.width,
                    phase: offset,
                    axis: .x
                ),
                row: row
            )
        }
    }

    private func phaseOffset(
        for index: Int,
        program: PeriodicPhaseProgram
    ) -> Float {
        let count = program.fractions.count
        let remainder = index % count
        let fractionIndex = remainder >= 0 ? remainder : remainder + count
        let extent = switch program.offsetAxis {
        case .x: repeatSize.width
        case .y: repeatSize.height
        }
        return program.fractions[fractionIndex] * extent
    }

    private static func positiveModulo(
        _ value: Float,
        extent: Float
    ) -> Float {
        let normalized = abs(value) < Float.leastNormalMagnitude ? 0 : value
        let remainder = normalized.truncatingRemainder(dividingBy: extent)
        if remainder == 0 || abs(remainder) < Float.leastNormalMagnitude {
            return 0
        }
        if remainder < 0 {
            return min(remainder + extent, extent.nextDown)
        }
        return remainder
    }
}

enum CoordinateAxis: String {
    case x
    case y
}

func checkedCellIndex(
    coordinate: Float,
    extent: Float,
    phase: Float,
    axis: CoordinateAxis
) -> Int {
    let candidateIndex = resolvedCellIndex(
        coordinate: coordinate,
        extent: extent,
        phase: phase,
        axis: axis
    )
    let floatIndex = Float(candidateIndex)
    precondition(
        exactCellIndex(floatIndex, axis: axis) == candidateIndex,
        "TilingStrategy \(axis.rawValue) cell index must be exactly representable as Float"
    )

    let unphasedOrigin = floatIndex * extent
    let origin = unphasedOrigin + phase
    let boundary = origin + extent
    precondition(
        unphasedOrigin.isFinite && origin.isFinite && boundary.isFinite,
        "TilingStrategy \(axis.rawValue) cell boundaries must be finite"
    )
    precondition(
        phase == 0 || origin - unphasedOrigin == phase,
        "TilingStrategy \(axis.rawValue) cell phase must be preserved"
    )
    precondition(
        boundary - origin == extent,
        "TilingStrategy \(axis.rawValue) cell extent must be preserved"
    )

    let (successorIndex, successorOverflowed) =
        candidateIndex.addingReportingOverflow(1)
    precondition(
        !successorOverflowed
            && resolvedCellIndex(
                coordinate: origin,
                extent: extent,
                phase: phase,
                axis: axis
            ) == candidateIndex
            && resolvedCellIndex(
                coordinate: boundary.nextDown,
                extent: extent,
                phase: phase,
                axis: axis
            ) == candidateIndex
            && resolvedCellIndex(
                coordinate: boundary,
                extent: extent,
                phase: phase,
                axis: axis
            ) == successorIndex,
        "TilingStrategy \(axis.rawValue) cell boundaries must round-trip half-open"
    )
    precondition(
        coordinate >= origin && coordinate < boundary,
        "TilingStrategy \(axis.rawValue) coordinate must resolve inside its cell"
    )
    return candidateIndex
}

private func resolvedCellIndex(
    coordinate: Float,
    extent: Float,
    phase: Float,
    axis: CoordinateAxis
) -> Int {
    var candidateIndex = quotientCellIndex(
        coordinate: coordinate,
        extent: extent,
        phase: phase,
        axis: axis
    )
    let origin = Float(candidateIndex) * extent + phase
    let boundary = origin + extent
    if coordinate < origin {
        let (previousIndex, overflowed) =
            candidateIndex.subtractingReportingOverflow(1)
        precondition(
            !overflowed,
            "TilingStrategy \(axis.rawValue) cell index must be Int-representable"
        )
        candidateIndex = previousIndex
    } else if coordinate >= boundary {
        let (nextIndex, overflowed) = candidateIndex.addingReportingOverflow(1)
        precondition(
            !overflowed,
            "TilingStrategy \(axis.rawValue) cell index must be Int-representable"
        )
        candidateIndex = nextIndex
    }
    return candidateIndex
}

private func quotientCellIndex(
    coordinate: Float,
    extent: Float,
    phase: Float,
    axis: CoordinateAxis
) -> Int {
    precondition(
        coordinate.isFinite,
        "TilingStrategy \(axis.rawValue) coordinate must be finite"
    )
    precondition(
        phase.isFinite,
        "TilingStrategy \(axis.rawValue) phase must be finite"
    )

    let phasedCoordinate = coordinate - phase
    precondition(
        phasedCoordinate.isFinite,
        "TilingStrategy \(axis.rawValue) phase subtraction must be finite"
    )
    let quotient = phasedCoordinate / extent
    precondition(
        quotient.isFinite,
        "TilingStrategy \(axis.rawValue) cell quotient must be finite"
    )
    return exactCellIndex(floor(quotient), axis: axis)
}

private func exactCellIndex(
    _ value: Float,
    axis: CoordinateAxis
) -> Int {
    precondition(
        value >= Float(Int.min) && value < Float(Int.max),
        "TilingStrategy \(axis.rawValue) cell index must be Int-representable"
    )
    guard let index = Int(exactly: value) else {
        preconditionFailure(
            "TilingStrategy \(axis.rawValue) cell index must be exactly representable as Float"
        )
    }
    return index
}
