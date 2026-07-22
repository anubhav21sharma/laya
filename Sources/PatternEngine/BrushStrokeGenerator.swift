import Foundation
import simd

/// Deterministic input-to-dab generator for one captured stroke configuration.
public struct BrushStrokeGenerator: Equatable, Sendable {
    public let recipe: BrushRecipe
    public let nominalDiameter: Float
    public let color: InkColor
    public let seed: UInt64

    public private(set) var currentSpacing: Float
    public private(set) var emittedDabCount: UInt64

    private var stabilizer: StrokeStabilizer
    private var path: CentripetalCatmullRomPathInterpolator
    private var random: BrushRandom
    private var isActive: Bool
    private var strokeStartTimestamp: TimeInterval?
    private var processedPathDistance: Float
    private var distanceUntilNext: Float
    private var lastDirection: Float
    private var lastEmittedSourcePosition: WorldPoint?

    public init(
        recipe: BrushRecipe,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64
    ) {
        precondition(
            nominalDiameter.isFinite && nominalDiameter > 0,
            "Nominal brush diameter must be finite and positive"
        )
        precondition(seed != 0, "Brush stroke seed must be nonzero")

        let spacing = Self.initialSpacing(
            recipe: recipe,
            nominalDiameter: nominalDiameter
        )
        self.recipe = recipe
        self.nominalDiameter = nominalDiameter
        self.color = color
        self.seed = seed
        currentSpacing = spacing
        emittedDabCount = 0
        stabilizer = StrokeStabilizer(strength: recipe.stabilization)
        path = CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: min(0.5, spacing * 0.2),
            minimumSubdivisionEstimate: spacing
        )
        random = BrushRandom(seed: seed)
        isActive = false
        strokeStartTimestamp = nil
        processedPathDistance = 0
        distanceUntilNext = spacing
        lastDirection = 0
        lastEmittedSourcePosition = nil
    }

    public mutating func begin(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        precondition(sample.phase == .began)
        var updated = self
        try updated.start(sample, emit: emit)
        self = updated
    }

    public mutating func append(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        precondition(sample.phase == .moved)
        var updated = self
        if updated.isActive {
            try updated.appendActive(sample, emit: emit)
        } else {
            try updated.start(sample, emit: emit)
        }
        self = updated
    }

    public mutating func finish(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        precondition(sample.phase == .ended)
        var updated = self
        if !updated.isActive {
            try updated.start(sample, emit: emit)
        } else {
            try updated.finishActive(sample, emit: emit)
        }
        updated.resetRuntimeState()
        self = updated
    }

    public mutating func cancel() {
        resetRuntimeState()
    }

    private mutating func start(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        resetRuntimeState()
        isActive = true
        strokeStartTimestamp = sample.timestamp
        let stabilized = stabilizer.process(sample)
        let attributed = InterpolatedStrokeSample(stabilized)
        _ = path.begin(at: attributed)
        let dab = nextDab(
            sample: attributed,
            traveledDistance: 0,
            direction: 0,
            totalDistance: sample.phase == .ended ? 0 : nil
        )
        try emit(dab)
        lastEmittedSourcePosition = attributed.position
        currentSpacing = dab.spacing
        distanceUntilNext = dab.spacing
    }

    private mutating func appendActive(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        let stabilized = stabilizer.process(sample)
        let attributed = InterpolatedStrokeSample(stabilized)
        var updatedPath = path
        try updatedPath.append(attributed) { segment in
            try consume(segment, emit: emit)
        }
        path = updatedPath
    }

    private mutating func finishActive(
        _ sample: WorldStrokeSample,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        let stabilized = stabilizer.process(sample)
        let attributed = InterpolatedStrokeSample(stabilized)
        var updatedPath = path
        let endpoint = try updatedPath.finish(at: attributed) { segment in
            try consume(segment, emit: emit)
        }
        path = updatedPath

        if lastEmittedSourcePosition != endpoint.position {
            let dab = nextDab(
                sample: endpoint,
                traveledDistance: processedPathDistance,
                direction: lastDirection,
                totalDistance: nil
            )
            try emit(dab)
            lastEmittedSourcePosition = endpoint.position
            currentSpacing = dab.spacing
            distanceUntilNext = dab.spacing
        }
    }

    private mutating func consume(
        _ segment: AttributedStrokePathSegment,
        emit: (DabAttributes) throws -> Void
    ) rethrows {
        let length = segment.length
        guard length > 0 else { return }

        let delta = segment.end.position.simd - segment.start.position.simd
        let direction = atan2(delta.y, delta.x)
        var distanceFromStart: Float = 0
        var remainingLength = length

        while remainingLength >= distanceUntilNext {
            distanceFromStart += distanceUntilNext
            let fraction = min(1, distanceFromStart / length)
            let exactPosition = WorldPoint(
                segment.start.position.simd + delta * fraction
            )
            let sample = segment.sample(
                at: fraction,
                exactPosition: exactPosition
            )
            let sourceDistance = processedPathDistance + distanceFromStart
            if lastEmittedSourcePosition != sample.position {
                let dab = nextDab(
                    sample: sample,
                    traveledDistance: sourceDistance,
                    direction: direction,
                    totalDistance: nil
                )
                try emit(dab)
                lastEmittedSourcePosition = sample.position
                currentSpacing = dab.spacing
                distanceUntilNext = dab.spacing
            } else {
                // A rounded path position is not a dab: it must not consume
                // the ordinal or deterministic random channels.
                distanceUntilNext = currentSpacing
            }
            remainingLength = length - distanceFromStart
        }

        distanceUntilNext -= remainingLength
        processedPathDistance += length
        lastDirection = direction
    }

    private mutating func nextDab(
        sample: InterpolatedStrokeSample,
        traveledDistance: Float,
        direction: Float,
        totalDistance: Float?
    ) -> DabAttributes {
        let start = strokeStartTimestamp ?? sample.timestamp
        let age = max(0, Float(sample.timestamp - start))
        let context = BrushStrokeContext(
            nominalDiameter: nominalDiameter,
            color: color,
            direction: direction,
            strokeAge: age,
            traveledDistance: traveledDistance,
            totalDistance: totalDistance,
            ordinal: emittedDabCount,
            isPredicted: sample.kind == .predicted
        )
        let dab = BrushDynamicsEngine().evaluate(
            sample: sample,
            context: context,
            recipe: recipe,
            random: random.nextValues()
        )
        emittedDabCount &+= 1
        return dab
    }

    private mutating func resetRuntimeState() {
        let spacing = Self.initialSpacing(
            recipe: recipe,
            nominalDiameter: nominalDiameter
        )
        currentSpacing = spacing
        emittedDabCount = 0
        stabilizer = StrokeStabilizer(strength: recipe.stabilization)
        path = CentripetalCatmullRomPathInterpolator(
            maximumSegmentLength: min(0.5, spacing * 0.2),
            minimumSubdivisionEstimate: spacing
        )
        random = BrushRandom(seed: seed)
        isActive = false
        strokeStartTimestamp = nil
        processedPathDistance = 0
        distanceUntilNext = spacing
        lastDirection = 0
        lastEmittedSourcePosition = nil
    }

    private static func initialSpacing(
        recipe: BrushRecipe,
        nominalDiameter: Float
    ) -> Float {
        let upperBound = max(
            1,
            min(8, nominalDiameter * recipe.maximumSpacingFraction)
        )
        return min(
            upperBound,
            max(1, nominalDiameter * recipe.baseSpacingFraction)
        )
    }
}
