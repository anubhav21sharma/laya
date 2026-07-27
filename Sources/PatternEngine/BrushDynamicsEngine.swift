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
    /// Native secondary-color blend amount. Legacy brushes leave this neutral.
    public let secondaryColorMix: Float
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
        isPredicted: Bool,
        secondaryColorMix: Float = 0
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
        self.secondaryColorMix = secondaryColorMix
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
        program: BrushProgram,
        random: BrushRandomValues,
        strokeSeed: UInt64
    ) -> DabAttributes {
        if let recipe = program.compatibilityRecipe {
            return evaluateLegacy(
                sample: sample,
                context: context,
                recipe: recipe,
                random: random
            )
        }
        return evaluateNative(
            sample: sample,
            context: context,
            program: program,
            random: random,
            strokeSeed: strokeSeed
        )
    }

    /// Temporary compatibility entry point. Production stroke setup passes a
    /// precompiled `BrushProgram`; this adapter remains for test harnesses.
    @available(
        *, deprecated,
        message: "Compile BrushDefinition to BrushProgram and call evaluate(sample:context:program:random:strokeSeed:)."
    )
    public func evaluate(
        sample: InterpolatedStrokeSample,
        context: BrushStrokeContext,
        recipe: BrushRecipe,
        random: BrushRandomValues
    ) -> DabAttributes {
        let definition = try! LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: recipe.id.rawValue
        )
        let program = try! BrushProgramCompiler.compile(definition)
        return evaluate(
            sample: sample,
            context: context,
            program: program,
            random: random,
            strokeSeed: 1
        )
    }

    private func evaluateLegacy(
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

    private func evaluateNative(
        sample: InterpolatedStrokeSample,
        context: BrushStrokeContext,
        program: BrushProgram,
        random: BrushRandomValues,
        strokeSeed: UInt64
    ) -> DabAttributes {
        let definition = program.definition
        let inputs = Inputs(sample: sample, context: context)
        let dynamics = program.dynamics
        let sizeFactor = evaluate(
            dynamics.size, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .size
        )
        let taperEnvelope = taperEnvelope(context: context, taper: definition.taper)
        let sizeTaper = definition.taper.effects.contains(.size)
            ? interpolate(from: definition.taper.minimumSize, to: 1, fraction: taperEnvelope)
            : 1
        let diameter = context.nominalDiameter * sizeFactor * sizeTaper
        let radius = diameter * 0.5

        let spacingFactor = evaluate(
            dynamics.spacing, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .spacing
        )
        let randomizedSpacing = diameter
            * definition.placement.baseSpacingFraction
            * spacingFactor
            * (1 + symmetric(random.spacing) * definition.dynamics.randomization.spacing)
        let spacingUpperBound = max(
            1,
            min(8, diameter * definition.placement.maximumSpacingFraction)
        )
        let spacing = min(spacingUpperBound, max(1, randomizedSpacing))

        let flowFactor = evaluate(
            dynamics.flow, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .flow
        )
        let flowTaper = definition.taper.effects.contains(.flow)
            ? interpolate(from: definition.taper.minimumFlow, to: 1, fraction: taperEnvelope)
            : 1
        let flow = clamp01(definition.placement.baseFlow * flowFactor * flowTaper)
        let opacity = evaluate(
            dynamics.opacity, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .opacity
        )

        let rotation = definition.placement.baseRotation
            + evaluate(dynamics.rotation, inputs: inputs, strokeSeed: strokeSeed,
                       ordinal: context.ordinal, channel: .rotation)
            + symmetric(random.rotation) * definition.dynamics.randomization.rotation
        let scatterFactor = evaluate(
            dynamics.scatter, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .scatter
        )
        let maximumScatter = context.nominalDiameter
            * definition.placement.baseScatterFraction
            * scatterFactor
            * definition.dynamics.randomization.scatter
        let scatter = SIMD2(
            symmetric(random.scatterX) * maximumScatter,
            symmetric(random.scatterY) * maximumScatter
        )
        let offset = SIMD2(
            evaluate(dynamics.offsetX, inputs: inputs, strokeSeed: strokeSeed,
                     ordinal: context.ordinal, channel: .offsetX),
            evaluate(dynamics.offsetY, inputs: inputs, strokeSeed: strokeSeed,
                     ordinal: context.ordinal, channel: .offsetY)
        ) + definition.placement.baseOffset
        let placementJitter = nativePlacementJitter(
            fraction: definition.placement.baseJitterFraction,
            nominalDiameter: context.nominalDiameter,
            strokeSeed: strokeSeed,
            ordinal: context.ordinal
        )
        let position = WorldPoint(sample.position.simd + scatter + offset + placementJitter)
        let cosine = cos(rotation)
        let sine = sin(rotation)
        let brushToWorld = Affine2D(
            xAxis: SIMD2(cosine, sine) * radius,
            yAxis: SIMD2(-sine, cosine) * radius * definition.coverage.aspectRatio,
            translation: position.simd
        )
        let hardness = clamp01(definition.coverage.baseHardness * evaluate(
            dynamics.hardness, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .hardness
        ))
        let grain = definition.coverage.grains.first
        let grainScale = (grain?.transform.scale ?? 1) * evaluate(
            dynamics.grain, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .grain
        )
        let grainOffset = (grain?.transform.offset ?? .zero) + SIMD2(
            symmetric(random.grainX) * definition.dynamics.randomization.grain,
            symmetric(random.grainY) * definition.dynamics.randomization.grain
        )
        // Hue is measured in turns; saturation, brightness, and secondary mix
        // use additive normalized deltas. Mapping output and both jitter scopes
        // are combined before the final HSB/mix bounds are applied.
        let perStampColorJitter = nativeColorJitter(
            definition.color.perStampJitter,
            strokeSeed: strokeSeed,
            ordinal: context.ordinal,
            scope: .perStamp
        )
        let perStrokeColorJitter = nativeColorJitter(
            definition.color.perStrokeJitter,
            strokeSeed: strokeSeed,
            ordinal: context.ordinal,
            scope: .perStroke
        )
        let hue = evaluate(
            dynamics.hue, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .hue
        ) + perStampColorJitter.hue + perStrokeColorJitter.hue
        let saturation = evaluate(
            dynamics.saturation, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .saturation
        ) + perStampColorJitter.saturation + perStrokeColorJitter.saturation
        let brightness = evaluate(
            dynamics.brightness, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .brightness
        ) + perStampColorJitter.brightness + perStrokeColorJitter.brightness
        let secondaryColorMix = clamp01(evaluate(
            dynamics.secondaryColorMix, inputs: inputs, strokeSeed: strokeSeed,
            ordinal: context.ordinal, channel: .secondaryColorMix
        ) + perStampColorJitter.secondaryColorMix
            + perStrokeColorJitter.secondaryColorMix)
        let materialFamily = program.compatibilityRecipe?.material.family
            ?? nativeMaterialFamily(definition.material)
        let materialContribution = clamp01(
            definition.material.strength * (
                1 + symmetric(random.materialVariation)
                    * definition.dynamics.randomization.material
            )
        )
        return DabAttributes(
            position: position, brushToWorld: brushToWorld, radius: radius,
            diameter: diameter, spacing: spacing, flow: flow,
            strokeOpacity: definition.placement.strokeOpacity * opacity,
            rotation: rotation, scatter: scatter, hardness: hardness,
            grainOffset: grainOffset, grainScale: grainScale,
            grainRotation: grain?.transform.rotation ?? 0,
            color: applyingColorDynamics(
                adjustedColor(context.color, adjustment: definition.color.baseAdjustment),
                hueTurns: hue,
                saturationDelta: saturation,
                brightnessDelta: brightness
            ),
            colorAdjustment: definition.color.baseAdjustment,
            materialFamily: materialFamily,
            materialContribution: materialContribution,
            sourceDistance: context.traveledDistance, ordinal: context.ordinal,
            isPredicted: context.isPredicted,
            secondaryColorMix: secondaryColorMix
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
            isPredicted: dab.isPredicted,
            secondaryColorMix: dab.secondaryColorMix
        )
    }
}

private extension BrushDynamicsEngine {
    enum NativeColorJitterScope {
        case perStamp
        case perStroke
    }

    struct Inputs {
        let pressure: Float
        let hasPressure: Bool
        let speed: Float
        let direction: Float
        let tilt: Float
        let hasTilt: Bool
        let azimuth: Float
        let hasAzimuth: Bool
        let roll: Float
        let hasRoll: Bool
        let age: Float
        let distance: Float

        init(
            sample: InterpolatedStrokeSample,
            context: BrushStrokeContext,
            pressure: Float
        ) {
            self.pressure = clamp01(pressure)
            hasPressure = sample.capabilities.contains(.pressure)
            speed = clamp01(sample.velocity / context.speedReference)
            direction = normalizedAngle(context.direction)
            if sample.capabilities.contains(.altitude),
               let altitude = sample.altitude
            {
                tilt = clamp01(1 - altitude / (.pi / 2))
                hasTilt = true
            } else {
                tilt = 0
                hasTilt = false
            }
            if sample.capabilities.contains(.azimuth),
               let sampleAzimuth = sample.azimuth
            {
                azimuth = normalizedAngle(sampleAzimuth)
                hasAzimuth = true
            } else {
                azimuth = 0
                hasAzimuth = false
            }
            if sample.capabilities.contains(.roll), let sampleRoll = sample.roll {
                roll = normalizedAngle(sampleRoll)
                hasRoll = true
            } else {
                roll = 0
                hasRoll = false
            }
            age = clamp01(context.strokeAge / context.ageReference)
            distance = clamp01(
                context.traveledDistance / context.distanceReference
            )
        }

        init(sample: InterpolatedStrokeSample, context: BrushStrokeContext) {
            self.init(sample: sample, context: context, pressure: sample.pressure)
        }

        func value(for input: BrushDynamicsInput) -> Float {
            switch input {
            case .pressure: pressure
            case .speed: speed
            case .direction: direction
            case .tilt: tilt
            case .azimuth: azimuth
            case .roll: roll
            case .tangentialPressure: 0
            case .age: age
            case .distance: distance
            case .random: 0
            }
        }

        func value(
            for input: BrushDynamicsInput,
            missingInputValue: Float,
            randomValue: Float
        ) -> Float {
            switch input {
            case .pressure:
                return hasPressure ? pressure : missingInputValue
            case .tilt:
                return hasTilt ? tilt : missingInputValue
            case .azimuth:
                return hasAzimuth ? azimuth : missingInputValue
            case .roll:
                return hasRoll ? roll : missingInputValue
            case .tangentialPressure:
                return missingInputValue
            case .random:
                return randomValue
            case .speed, .direction, .age, .distance:
                return value(for: input)
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

    func nativePlacementJitter(
        fraction: Float,
        nominalDiameter: Float,
        strokeSeed: UInt64,
        ordinal: UInt64
    ) -> SIMD2<Float> {
        guard fraction != 0 else { return .zero }
        let magnitude = nominalDiameter * fraction
        return SIMD2(
            symmetric(BrushRandom.extensionUnitFloat(
                strokeSeed: strokeSeed,
                logicalDabOrdinal: ordinal,
                outputChannel: .placementJitterX
            )) * magnitude,
            symmetric(BrushRandom.extensionUnitFloat(
                strokeSeed: strokeSeed,
                logicalDabOrdinal: ordinal,
                outputChannel: .placementJitterY
            )) * magnitude
        )
    }

    func nativeColorJitter(
        _ jitter: BrushColorJitter,
        strokeSeed: UInt64,
        ordinal: UInt64,
        scope: NativeColorJitterScope
    ) -> BrushColorJitter {
        let channels: (
            hue: BrushProgramRandomChannel,
            saturation: BrushProgramRandomChannel,
            brightness: BrushProgramRandomChannel,
            secondaryColorMix: BrushProgramRandomChannel
        )
        let scopedOrdinal: UInt64
        switch scope {
        case .perStamp:
            channels = (
                .perStampHue, .perStampSaturation, .perStampBrightness,
                .perStampSecondaryColorMix
            )
            scopedOrdinal = ordinal
        case .perStroke:
            channels = (
                .perStrokeHue, .perStrokeSaturation, .perStrokeBrightness,
                .perStrokeSecondaryColorMix
            )
            scopedOrdinal = 0
        }
        return BrushColorJitter(
            hue: nativeJitterValue(
                jitter.hue, strokeSeed: strokeSeed, ordinal: scopedOrdinal,
                channel: channels.hue
            ),
            saturation: nativeJitterValue(
                jitter.saturation, strokeSeed: strokeSeed, ordinal: scopedOrdinal,
                channel: channels.saturation
            ),
            brightness: nativeJitterValue(
                jitter.brightness, strokeSeed: strokeSeed, ordinal: scopedOrdinal,
                channel: channels.brightness
            ),
            secondaryColorMix: nativeJitterValue(
                jitter.secondaryColorMix, strokeSeed: strokeSeed,
                ordinal: scopedOrdinal, channel: channels.secondaryColorMix
            )
        )
    }

    func nativeJitterValue(
        _ amplitude: Float,
        strokeSeed: UInt64,
        ordinal: UInt64,
        channel: BrushProgramRandomChannel
    ) -> Float {
        guard amplitude != 0 else { return 0 }
        return symmetric(BrushRandom.extensionUnitFloat(
            strokeSeed: strokeSeed,
            logicalDabOrdinal: ordinal,
            outputChannel: channel
        )) * amplitude
    }

    func evaluate(
        _ response: CompiledBrushResponse,
        inputs: Inputs,
        strokeSeed: UInt64,
        ordinal: UInt64,
        channel: BrushProgramRandomChannel
    ) -> Float {
        switch response {
        case let .constant(value):
            return value
        case let .legacyLinear(input, minimum, maximum, missingInputValue):
            return interpolate(
                from: minimum,
                to: maximum,
                fraction: inputs.value(
                    for: input,
                    missingInputValue: missingInputValue,
                    randomValue: BrushRandom.extensionUnitFloat(
                        strokeSeed: strokeSeed,
                        logicalDabOrdinal: ordinal,
                        outputChannel: channel
                    )
                )
            )
        case let .legacyBoundedPower(
            input, minimum, maximum, exponent, missingInputValue
        ):
            return interpolate(
                from: minimum,
                to: maximum,
                fraction: pow(inputs.value(
                    for: input,
                    missingInputValue: missingInputValue,
                    randomValue: BrushRandom.extensionUnitFloat(
                        strokeSeed: strokeSeed,
                        logicalDabOrdinal: ordinal,
                        outputChannel: channel
                    )
                ), exponent)
            )
        case let .sampledCurve(
            input, samples, scale, offset, lowerClamp, upperClamp, inverted,
            jitter, missingInputValue
        ):
            let extensionValue = BrushRandom.extensionUnitFloat(
                strokeSeed: strokeSeed,
                logicalDabOrdinal: ordinal,
                outputChannel: channel
            )
            let normalized = inputs.value(
                for: input,
                missingInputValue: missingInputValue,
                randomValue: extensionValue
            )
            let response = sampledValue(samples, at: normalized)
            let oriented = inverted ? 1 - response : response
            let mapped = offset + scale * oriented
            let jittered = mapped + symmetric(extensionValue) * jitter
            return min(upperClamp, max(lowerClamp, jittered))
        }
    }

    func sampledValue(_ samples: [Float], at input: Float) -> Float {
        precondition(samples.count == BrushProgramCompiler.sampleCount)
        let bounded = clamp01(input)
        let scaled = bounded * Float(samples.count - 1)
        let lower = max(0, min(samples.count - 1, Int(scaled.rounded(.down))))
        let upper = min(samples.count - 1, lower + 1)
        let fraction = scaled - Float(lower)
        return samples[lower] + (samples[upper] - samples[lower]) * fraction
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

    func taperEnvelope(
        context: BrushStrokeContext,
        taper: BrushTaperConfiguration
    ) -> Float {
        let start = envelope(
            distance: context.traveledDistance,
            length: taper.start,
            nominalDiameter: context.nominalDiameter
        )
        let end: Float
        if let totalDistance = context.totalDistance {
            end = envelope(
                distance: max(0, totalDistance - context.traveledDistance),
                length: taper.end,
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

    func applyingColorDynamics(
        _ color: InkColor,
        hueTurns: Float,
        saturationDelta: Float,
        brightnessDelta: Float
    ) -> InkColor {
        guard hueTurns != 0 || saturationDelta != 0 || brightnessDelta != 0
        else { return color }
        let maximum = max(color.red, max(color.green, color.blue))
        let minimum = min(color.red, min(color.green, color.blue))
        let chroma = maximum - minimum
        let hue: Float
        if chroma == 0 {
            hue = 0
        } else if maximum == color.red {
            hue = ((color.green - color.blue) / chroma).truncatingRemainder(dividingBy: 6) / 6
        } else if maximum == color.green {
            hue = ((color.blue - color.red) / chroma + 2) / 6
        } else {
            hue = ((color.red - color.green) / chroma + 4) / 6
        }
        let adjustedHue = hue + hueTurns - floor(hue + hueTurns)
        let adjustedSaturation = maximum == 0 ? 0 : clamp01(chroma / maximum + saturationDelta)
        let adjustedBrightness = clamp01(maximum + brightnessDelta)
        let sector = adjustedHue * 6
        let adjustedChroma = adjustedBrightness * adjustedSaturation
        let x = adjustedChroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = adjustedBrightness - adjustedChroma
        let rgb: SIMD3<Float>
        switch Int(floor(sector)) {
        case 0: rgb = SIMD3(adjustedChroma, x, 0)
        case 1: rgb = SIMD3(x, adjustedChroma, 0)
        case 2: rgb = SIMD3(0, adjustedChroma, x)
        case 3: rgb = SIMD3(0, x, adjustedChroma)
        case 4: rgb = SIMD3(x, 0, adjustedChroma)
        default: rgb = SIMD3(adjustedChroma, 0, x)
        }
        return InkColor(
            red: rgb.x + m,
            green: rgb.y + m,
            blue: rgb.z + m,
            alpha: color.alpha
        )!
    }

    func nativeMaterialFamily(
        _ material: BrushMaterialDefinition
    ) -> BrushMaterialFamily {
        switch (material.accumulation, material.edgeTreatment) {
        case (.flow, .dryBreakup): return .dry
        case (.uniformGlaze, .markerOverlap): return .glaze
        case (.flow, .wetConcentration): return .boundedWash
        default: return .ink
        }
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
