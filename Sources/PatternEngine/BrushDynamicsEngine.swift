import Foundation
import simd

public struct BrushStrokeContext: Equatable, Sendable {
    public let nominalDiameter: Float
    public let color: InkColor
    public let direction: Float
    public let strokeAge: Float
    public let traveledDistance: Float
    public let totalDistance: Float?
    public let ordinal: UInt64
    public let isPredicted: Bool
    public let speedReference: Float
    public let ageReference: Float
    public let distanceReference: Float

    public init(
        nominalDiameter: Float,
        color: InkColor,
        direction: Float,
        strokeAge: Float,
        traveledDistance: Float,
        totalDistance: Float? = nil,
        ordinal: UInt64,
        isPredicted: Bool,
        speedReference: Float = BrushInputContract.maximumWorldVelocity,
        ageReference: Float = 1,
        distanceReference: Float? = nil
    ) {
        let distanceReference = distanceReference ?? nominalDiameter * 10
        precondition(
            nominalDiameter.isFinite && nominalDiameter > 0,
            "Nominal brush diameter must be finite and positive"
        )
        precondition(direction.isFinite, "Travel direction must be finite")
        precondition(
            strokeAge.isFinite && strokeAge >= 0,
            "Stroke age must be finite and nonnegative"
        )
        precondition(
            traveledDistance.isFinite && traveledDistance >= 0,
            "Traveled distance must be finite and nonnegative"
        )
        precondition(
            totalDistance?.isFinite != false && totalDistance ?? 0 >= 0,
            "Total distance must be finite and nonnegative"
        )
        precondition(
            speedReference.isFinite && speedReference > 0,
            "Speed reference must be finite and positive"
        )
        precondition(
            ageReference.isFinite && ageReference > 0,
            "Age reference must be finite and positive"
        )
        precondition(
            distanceReference.isFinite && distanceReference > 0,
            "Distance reference must be finite and positive"
        )
        self.nominalDiameter = nominalDiameter
        self.color = color
        self.direction = direction
        self.strokeAge = strokeAge
        self.traveledDistance = traveledDistance
        self.totalDistance = totalDistance
        self.ordinal = ordinal
        self.isPredicted = isPredicted
        self.speedReference = speedReference
        self.ageReference = ageReference
        self.distanceReference = distanceReference
    }
}

public struct DabAttributes: Equatable, Sendable {
    public let position: WorldPoint
    public let brushToWorld: Affine2D
    public let radius: Float
    public let diameter: Float
    public let spacing: Float
    public let flow: Float
    public let strokeOpacity: Float
    public let rotation: Float
    public let scatter: SIMD2<Float>
    public let hardness: Float
    public let grainOffset: SIMD2<Float>
    public let grainScale: Float
    public let grainRotation: Float
    public let color: InkColor
    public let colorAdjustment: BrushColorAdjustment
    public let materialFamily: BrushMaterialFamily
    public let materialContribution: Float
    public let sourceDistance: Float
    public let ordinal: UInt64
    public let isPredicted: Bool

    public init(
        position: WorldPoint,
        brushToWorld: Affine2D,
        radius: Float,
        diameter: Float,
        spacing: Float,
        flow: Float,
        strokeOpacity: Float,
        rotation: Float,
        scatter: SIMD2<Float>,
        hardness: Float,
        grainOffset: SIMD2<Float>,
        grainScale: Float,
        grainRotation: Float,
        color: InkColor,
        colorAdjustment: BrushColorAdjustment,
        materialFamily: BrushMaterialFamily,
        materialContribution: Float,
        sourceDistance: Float,
        ordinal: UInt64,
        isPredicted: Bool
    ) {
        self.position = position
        self.brushToWorld = brushToWorld
        self.radius = radius
        self.diameter = diameter
        self.spacing = spacing
        self.flow = flow
        self.strokeOpacity = strokeOpacity
        self.rotation = rotation
        self.scatter = scatter
        self.hardness = hardness
        self.grainOffset = grainOffset
        self.grainScale = grainScale
        self.grainRotation = grainRotation
        self.color = color
        self.colorAdjustment = colorAdjustment
        self.materialFamily = materialFamily
        self.materialContribution = materialContribution
        self.sourceDistance = sourceDistance
        self.ordinal = ordinal
        self.isPredicted = isPredicted
    }

    public var flowContribution: Float { flow }
    public var strokeOpacityContribution: Float { strokeOpacity }
}

/// Pure, renderer-free evaluation of one attributed path point.
public struct BrushDynamicsEngine: Sendable {
    public init() {}

    public func evaluate(
        sample: InterpolatedStrokeSample,
        context: BrushStrokeContext,
        recipe: BrushRecipe,
        random: BrushRandomValues
    ) -> DabAttributes {
        let pressure = sample.capabilities.contains(.pressure)
            ? sample.pressure
            : recipe.noPressureNeutral
        let inputs = Inputs(
            sample: sample,
            context: context,
            pressure: pressure
        )

        let sizeFactor = evaluate(
            recipe.sizeMapping,
            inputs: inputs,
            disabledValue: 1
        )
        let taperEnvelope = taperEnvelope(
            context: context,
            recipe: recipe
        )
        let sizeTaper = recipe.taper.effects.contains(.size)
            ? interpolate(
                from: recipe.taper.minimumSize,
                to: 1,
                fraction: taperEnvelope
            )
            : 1
        let diameter = context.nominalDiameter * sizeFactor * sizeTaper
        let radius = diameter * 0.5

        let spacingFactor = evaluate(
            recipe.spacingMapping,
            inputs: inputs,
            disabledValue: 1
        )
        let randomizedSpacing = diameter
            * recipe.baseSpacingFraction
            * spacingFactor
            * (1 + symmetric(random.spacing) * recipe.randomization.spacing)
        let spacingUpperBound = max(
            1,
            min(8, diameter * recipe.maximumSpacingFraction)
        )
        let spacing = min(
            spacingUpperBound,
            max(1, randomizedSpacing)
        )

        let flowFactor = evaluate(
            recipe.flowMapping,
            inputs: inputs,
            disabledValue: 1
        )
        let flowTaper = recipe.taper.effects.contains(.flow)
            ? interpolate(
                from: recipe.taper.minimumFlow,
                to: 1,
                fraction: taperEnvelope
            )
            : 1
        let flow = clamp01(recipe.baseFlow * flowFactor * flowTaper)

        let rotation = recipe.baseRotation
            + evaluate(
                recipe.rotationMapping,
                inputs: inputs,
                disabledValue: 0
            )
            + symmetric(random.rotation) * recipe.randomization.rotation
        let scatterFactor = evaluate(
            recipe.scatterMapping,
            inputs: inputs,
            disabledValue: 1
        )
        let maximumScatter = context.nominalDiameter
            * recipe.baseScatterFraction
            * scatterFactor
            * recipe.randomization.scatter
        let scatter = SIMD2(
            symmetric(random.scatterX) * maximumScatter,
            symmetric(random.scatterY) * maximumScatter
        )
        let position = WorldPoint(sample.position.simd + scatter)

        let cosine = cos(rotation)
        let sine = sin(rotation)
        let brushToWorld = Affine2D(
            xAxis: SIMD2(cosine, sine) * radius,
            yAxis: SIMD2(-sine, cosine) * radius * recipe.aspectRatio,
            translation: position.simd
        )

        let hardness = clamp01(
            recipe.baseHardness
                * evaluate(
                    recipe.hardnessMapping,
                    inputs: inputs,
                    disabledValue: 1
                )
        )
        let grainScale = recipe.grainTransform.scale
            * evaluate(
                recipe.grainMapping,
                inputs: inputs,
                disabledValue: 1
            )
        let grainOffset = recipe.grainTransform.offset + SIMD2(
            symmetric(random.grainX) * recipe.randomization.grain,
            symmetric(random.grainY) * recipe.randomization.grain
        )
        let color = adjustedColor(
            context.color,
            adjustment: recipe.colorAdjustment
        )
        let materialContribution = clamp01(
            recipe.material.strength
                * (
                    1
                        + symmetric(random.materialVariation)
                        * recipe.randomization.material
                )
        )

        return DabAttributes(
            position: position,
            brushToWorld: brushToWorld,
            radius: radius,
            diameter: diameter,
            spacing: spacing,
            flow: flow,
            strokeOpacity: recipe.strokeOpacity,
            rotation: rotation,
            scatter: scatter,
            hardness: hardness,
            grainOffset: grainOffset,
            grainScale: grainScale,
            grainRotation: recipe.grainTransform.rotation,
            color: color,
            colorAdjustment: recipe.colorAdjustment,
            materialFamily: recipe.material.family,
            materialContribution: materialContribution,
            sourceDistance: context.traveledDistance,
            ordinal: context.ordinal,
            isPredicted: context.isPredicted
        )
    }

    /// Re-evaluates only the retroactive taper components once total length is
    /// known, preserving every random channel and non-taper attribute.
    public func applyingKnownTotalDistance(
        _ dab: DabAttributes,
        totalDistance: Float,
        nominalDiameter: Float,
        recipe: BrushRecipe,
        retainedReplayStartDistance: Float? = nil
    ) -> DabAttributes {
        precondition(totalDistance.isFinite && totalDistance >= 0)
        if let retainedReplayStartDistance {
            precondition(
                retainedReplayStartDistance.isFinite
                    && retainedReplayStartDistance >= 0
                    && retainedReplayStartDistance <= totalDistance,
                "Retained replay start distance must be finite and within the stroke"
            )
        }
        let startEnvelope = envelope(
            distance: dab.sourceDistance,
            length: recipe.taper.start,
            nominalDiameter: nominalDiameter
        )
        let absoluteEndEnvelope = envelope(
            distance: max(0, totalDistance - dab.sourceDistance),
            length: recipe.taper.end,
            nominalDiameter: nominalDiameter
        )
        let endEnvelope: Float
        if let retainedReplayStartDistance {
            let boundaryEnvelope = envelope(
                distance: max(0, totalDistance - retainedReplayStartDistance),
                length: recipe.taper.end,
                nominalDiameter: nominalDiameter
            )
            endEnvelope = boundaryEnvelope > 0
                ? clamp01(absoluteEndEnvelope / boundaryEnvelope)
                : 1
        } else {
            endEnvelope = absoluteEndEnvelope
        }
        let originalEnvelope = startEnvelope
        let finalEnvelope = min(startEnvelope, endEnvelope)
        let originalSize = recipe.taper.effects.contains(.size)
            ? interpolate(
                from: recipe.taper.minimumSize,
                to: 1,
                fraction: originalEnvelope
            )
            : 1
        let finalSize = recipe.taper.effects.contains(.size)
            ? interpolate(
                from: recipe.taper.minimumSize,
                to: 1,
                fraction: finalEnvelope
            )
            : 1
        let sizeRatio = originalSize > 0 ? finalSize / originalSize : 1
        let originalFlow = recipe.taper.effects.contains(.flow)
            ? interpolate(
                from: recipe.taper.minimumFlow,
                to: 1,
                fraction: originalEnvelope
            )
            : 1
        let finalFlow = recipe.taper.effects.contains(.flow)
            ? interpolate(
                from: recipe.taper.minimumFlow,
                to: 1,
                fraction: finalEnvelope
            )
            : 1
        let flowRatio = originalFlow > 0 ? finalFlow / originalFlow : 1
        let affine = Affine2D(
            xAxis: dab.brushToWorld.xAxis * sizeRatio,
            yAxis: dab.brushToWorld.yAxis * sizeRatio,
            translation: dab.brushToWorld.translation
        )
        return DabAttributes(
            position: dab.position,
            brushToWorld: affine,
            radius: dab.radius * sizeRatio,
            diameter: dab.diameter * sizeRatio,
            spacing: dab.spacing,
            flow: clamp01(dab.flow * flowRatio),
            strokeOpacity: dab.strokeOpacity,
            rotation: dab.rotation,
            scatter: dab.scatter,
            hardness: dab.hardness,
            grainOffset: dab.grainOffset,
            grainScale: dab.grainScale,
            grainRotation: dab.grainRotation,
            color: dab.color,
            colorAdjustment: dab.colorAdjustment,
            materialFamily: dab.materialFamily,
            materialContribution: dab.materialContribution,
            sourceDistance: dab.sourceDistance,
            ordinal: dab.ordinal,
            isPredicted: dab.isPredicted
        )
    }
}

private extension BrushDynamicsEngine {
    struct Inputs {
        let pressure: Float
        let speed: Float
        let direction: Float
        let tilt: Float
        let azimuth: Float
        let roll: Float
        let age: Float
        let distance: Float

        init(
            sample: InterpolatedStrokeSample,
            context: BrushStrokeContext,
            pressure: Float
        ) {
            self.pressure = clamp01(pressure)
            speed = clamp01(sample.velocity / context.speedReference)
            direction = normalizedAngle(context.direction)
            if sample.capabilities.contains(.altitude),
               let altitude = sample.altitude
            {
                tilt = clamp01(1 - altitude / (.pi / 2))
            } else {
                tilt = 0
            }
            if sample.capabilities.contains(.azimuth),
               let sampleAzimuth = sample.azimuth
            {
                azimuth = normalizedAngle(sampleAzimuth)
            } else {
                azimuth = 0
            }
            if sample.capabilities.contains(.roll), let sampleRoll = sample.roll {
                roll = normalizedAngle(sampleRoll)
            } else {
                roll = 0
            }
            age = clamp01(context.strokeAge / context.ageReference)
            distance = clamp01(
                context.traveledDistance / context.distanceReference
            )
        }

        func value(for input: BrushDynamicsInput) -> Float {
            switch input {
            case .pressure: pressure
            case .speed: speed
            case .direction: direction
            case .tilt: tilt
            case .azimuth: azimuth
            case .roll: roll
            case .age: age
            case .distance: distance
            }
        }
    }

    func evaluate(
        _ mapping: BrushMapping,
        inputs: Inputs,
        disabledValue: Float
    ) -> Float {
        guard mapping.response != .disabled else { return disabledValue }
        let input = inputs.value(for: mapping.input)
        let response: Float
        switch mapping.response {
        case .disabled:
            return disabledValue
        case .linear:
            response = input
        case .boundedPower:
            response = pow(input, mapping.exponent)
        }
        return interpolate(
            from: mapping.outputMinimum,
            to: mapping.outputMaximum,
            fraction: response
        )
    }

    func taperEnvelope(
        context: BrushStrokeContext,
        recipe: BrushRecipe
    ) -> Float {
        let start = envelope(
            distance: context.traveledDistance,
            length: recipe.taper.start,
            nominalDiameter: context.nominalDiameter
        )
        let end: Float
        if let totalDistance = context.totalDistance {
            end = envelope(
                distance: max(0, totalDistance - context.traveledDistance),
                length: recipe.taper.end,
                nominalDiameter: context.nominalDiameter
            )
        } else {
            end = 1
        }
        return min(start, end)
    }

    func envelope(
        distance: Float,
        length: BrushTaperLength,
        nominalDiameter: Float
    ) -> Float {
        let resolvedLength: Float
        switch length {
        case .disabled:
            return 1
        case let .worldPixels(value):
            resolvedLength = value
        case let .diameterMultiples(value):
            resolvedLength = value * nominalDiameter
        }
        return clamp01(distance / resolvedLength)
    }

    func adjustedColor(
        _ color: InkColor,
        adjustment: BrushColorAdjustment
    ) -> InkColor {
        InkColor(
            red: color.red * adjustment.redMultiplier,
            green: color.green * adjustment.greenMultiplier,
            blue: color.blue * adjustment.blueMultiplier,
            alpha: color.alpha * adjustment.alphaMultiplier
        )!
    }
}

private func clamp01(_ value: Float) -> Float {
    min(1, max(0, value))
}

private func interpolate(
    from start: Float,
    to end: Float,
    fraction: Float
) -> Float {
    start + (end - start) * fraction
}

private func normalizedAngle(_ value: Float) -> Float {
    let signed = atan2(sin(value), cos(value))
    return clamp01((signed + .pi) / (2 * .pi))
}

private func symmetric(_ value: Float) -> Float {
    value * 2 - 1
}
