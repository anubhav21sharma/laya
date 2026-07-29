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

public struct LogicalDab: Equatable, Sendable {
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
    public let primaryGrainToWorld: Affine2D?
    public let secondaryGrainToWorld: Affine2D?
    public let materialInputs: BrushMaterialInputs
    public let randomValues: BrushLogicalRandomValues
    public let worldBounds: AxisAlignedRect

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
        secondaryColorMix: Float = 0,
        primaryGrainToWorld: Affine2D? = nil,
        secondaryGrainToWorld: Affine2D? = nil,
        materialInputs: BrushMaterialInputs = .neutral,
        randomValues: BrushLogicalRandomValues = .neutral
    ) {
        self.init(
            position: position,
            brushToWorld: brushToWorld,
            radius: radius,
            diameter: diameter,
            spacing: spacing,
            flow: flow,
            strokeOpacity: strokeOpacity,
            rotation: rotation,
            scatter: scatter,
            hardness: hardness,
            grainOffset: grainOffset,
            grainScale: grainScale,
            grainRotation: grainRotation,
            color: color,
            colorAdjustment: colorAdjustment,
            materialFamily: materialFamily,
            materialContribution: materialContribution,
            sourceDistance: sourceDistance,
            ordinal: ordinal,
            isPredicted: isPredicted,
            secondaryColorMix: secondaryColorMix,
            primaryGrainToWorld: primaryGrainToWorld,
            secondaryGrainToWorld: secondaryGrainToWorld,
            materialInputs: materialInputs,
            randomValues: randomValues,
            evaluatedShapeFrames: [brushToWorld]
        )
    }

    init(
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
        secondaryColorMix: Float,
        primaryGrainToWorld: Affine2D?,
        secondaryGrainToWorld: Affine2D?,
        materialInputs: BrushMaterialInputs,
        randomValues: BrushLogicalRandomValues,
        evaluatedShapeFrames: [Affine2D]
    ) {
        precondition(
            !evaluatedShapeFrames.isEmpty,
            "A logical dab requires at least one evaluated shape frame"
        )
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
        self.primaryGrainToWorld = primaryGrainToWorld
        self.secondaryGrainToWorld = secondaryGrainToWorld
        self.materialInputs = materialInputs
        self.randomValues = randomValues
        worldBounds = Self.conservativeWorldBounds(
            shapeFrames: evaluatedShapeFrames,
            haloRadius: materialInputs.conservativeHaloRadius
        )
    }

    public var flowContribution: Float { flow }
    public var strokeOpacityContribution: Float { strokeOpacity }

    var hasFiniteBatchValues: Bool {
        [
            position.x,
            position.y,
            radius,
            diameter,
            spacing,
            flow,
            strokeOpacity,
            rotation,
            scatter.x,
            scatter.y,
            hardness,
            grainOffset.x,
            grainOffset.y,
            grainScale,
            grainRotation,
            color.red,
            color.green,
            color.blue,
            color.alpha,
            colorAdjustment.redMultiplier,
            colorAdjustment.greenMultiplier,
            colorAdjustment.blueMultiplier,
            colorAdjustment.alphaMultiplier,
            secondaryColorMix,
            materialContribution,
            sourceDistance,
            worldBounds.minimum.x,
            worldBounds.minimum.y,
            worldBounds.maximum.x,
            worldBounds.maximum.y,
        ].allSatisfy(\.isFinite)
            && Self.affineHasFiniteValues(brushToWorld)
            && primaryGrainToWorld.map(Self.affineHasFiniteValues) != false
            && secondaryGrainToWorld.map(Self.affineHasFiniteValues) != false
            && materialInputs.isFinite
            && randomValues.isFinite
    }

    private static func conservativeWorldBounds(
        shapeFrames: [Affine2D],
        haloRadius: Float
    ) -> AxisAlignedRect {
        let unitCorners = [
            SIMD2<Float>(-1, -1),
            SIMD2<Float>(1, -1),
            SIMD2<Float>(1, 1),
            SIMD2<Float>(-1, 1),
        ]
        let corners = shapeFrames.flatMap { frame in
            unitCorners.map(frame.applying(to:))
        }
        let minimum = SIMD2(
            corners.map(\.x).min()! - haloRadius,
            corners.map(\.y).min()! - haloRadius
        )
        let maximum = SIMD2(
            corners.map(\.x).max()! + haloRadius,
            corners.map(\.y).max()! + haloRadius
        )
        return AxisAlignedRect(minimum: minimum, maximum: maximum)
    }

    private static func affineHasFiniteValues(_ affine: Affine2D) -> Bool {
        [
            affine.xAxis.x,
            affine.xAxis.y,
            affine.yAxis.x,
            affine.yAxis.y,
            affine.translation.x,
            affine.translation.y,
        ].allSatisfy(\.isFinite)
    }
}

public typealias DabAttributes = LogicalDab

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
        evaluateNative(
            sample: sample,
            context: context,
            program: program,
            random: random,
            strokeSeed: strokeSeed
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
        let tipToWorld = Affine2D(
            xAxis: SIMD2(cosine, sine) * radius,
            yAxis: SIMD2(-sine, cosine) * radius * definition.coverage.aspectRatio,
            translation: position.simd
        )
        let evaluatedShapeFrames = definition.coverage.shapes.map { shape in
            let shapeCosine = cos(shape.rotation) * shape.scale
            let shapeSine = sin(shape.rotation) * shape.scale
            return Affine2D(
                xAxis: SIMD2(shapeCosine, shapeSine),
                yAxis: SIMD2(-shapeSine, shapeCosine),
                translation: shape.offset
            ).concatenating(tipToWorld)
        }
        let brushToWorld = evaluatedShapeFrames[0]
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
        let materialFamily = nativeMaterialFamily(definition.material)
        let materialContribution = clamp01(
            definition.material.strength * (
                1 + symmetric(random.materialVariation)
                    * definition.dynamics.randomization.material
            )
        )
        let primaryGrainToWorld = grain.map {
            nativeGrainFrame(
                layer: $0,
                scale: grainScale,
                offset: grainOffset,
                position: position,
                brushRotation: rotation
            )
        }
        let secondaryGrainToWorld = definition.coverage.grains.dropFirst().first.map {
            nativeGrainFrame(
                layer: $0,
                scale: $0.transform.scale * evaluate(
                    dynamics.grain,
                    inputs: inputs,
                    strokeSeed: strokeSeed,
                    ordinal: context.ordinal,
                    channel: .grain
                ),
                offset: $0.transform.offset + SIMD2(
                    symmetric(random.grainX)
                        * definition.dynamics.randomization.grain,
                    symmetric(random.grainY)
                        * definition.dynamics.randomization.grain
                ),
                position: position,
                brushRotation: rotation
            )
        }
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
            secondaryColorMix: secondaryColorMix,
            primaryGrainToWorld: primaryGrainToWorld,
            secondaryGrainToWorld: secondaryGrainToWorld,
            materialInputs: materialInputs(definition.material),
            randomValues: nativeRandomValues(
                compatibility: random,
                strokeSeed: strokeSeed,
                ordinal: context.ordinal
            ),
            evaluatedShapeFrames: evaluatedShapeFrames
        )
    }

    /// Re-evaluates only the retroactive taper components once total length is
    /// known, preserving every random channel and non-taper attribute.
    public func applyingKnownTotalDistance(
        _ dab: DabAttributes,
        totalDistance: Float,
        nominalDiameter: Float,
        definition: BrushDefinition,
        retainedReplayStartDistance: Float? = nil
    ) -> DabAttributes {
        applyingKnownTotalDistance(
            dab,
            totalDistance: totalDistance,
            nominalDiameter: nominalDiameter,
            taper: definition.taper,
            retainedReplayStartDistance: retainedReplayStartDistance
        )
    }

    private func applyingKnownTotalDistance(
        _ dab: DabAttributes,
        totalDistance: Float,
        nominalDiameter: Float,
        taper: BrushTaperConfiguration,
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
            length: taper.start,
            nominalDiameter: nominalDiameter
        )
        let absoluteEndEnvelope = envelope(
            distance: max(0, totalDistance - dab.sourceDistance),
            length: taper.end,
            nominalDiameter: nominalDiameter
        )
        let endEnvelope: Float
        if let retainedReplayStartDistance {
            let boundaryEnvelope = envelope(
                distance: max(0, totalDistance - retainedReplayStartDistance),
                length: taper.end,
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
        let originalSize = taper.effects.contains(.size)
            ? interpolate(
                from: taper.minimumSize,
                to: 1,
                fraction: originalEnvelope
            )
            : 1
        let finalSize = taper.effects.contains(.size)
            ? interpolate(
                from: taper.minimumSize,
                to: 1,
                fraction: finalEnvelope
            )
            : 1
        let sizeRatio = originalSize > 0 ? finalSize / originalSize : 1
        let originalFlow = taper.effects.contains(.flow)
            ? interpolate(
                from: taper.minimumFlow,
                to: 1,
                fraction: originalEnvelope
            )
            : 1
        let finalFlow = taper.effects.contains(.flow)
            ? interpolate(
                from: taper.minimumFlow,
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
            secondaryColorMix: dab.secondaryColorMix,
            primaryGrainToWorld: dab.primaryGrainToWorld,
            secondaryGrainToWorld: dab.secondaryGrainToWorld,
            materialInputs: dab.materialInputs,
            randomValues: dab.randomValues
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
        let tangentialPressure: Float
        let hasTangentialPressure: Bool
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
            if sample.capabilities.contains(.tangentialPressure),
               let sampleTangentialPressure = sample.tangentialPressure
            {
                tangentialPressure = clamp01(
                    (sampleTangentialPressure + 1) * 0.5
                )
                hasTangentialPressure = true
            } else {
                tangentialPressure = 0
                hasTangentialPressure = false
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
            case .tangentialPressure: tangentialPressure
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
                return hasTangentialPressure
                    ? tangentialPressure
                    : missingInputValue
            case .random:
                return randomValue
            case .speed, .direction, .age, .distance:
                return value(for: input)
            }
        }
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

    func materialInputs(
        _ material: BrushMaterialDefinition
    ) -> BrushMaterialInputs {
        BrushMaterialInputs(
            accumulation: material.accumulation,
            interaction: material.interaction,
            edgeTreatment: material.edgeTreatment,
            strength: material.strength,
            wetness: material.wetness,
            bleedRadius: material.bleedRadius,
            accumulationLimit: material.accumulationLimit,
            interactionParameters: material.interactionParameters
        )
    }

    /// Stage 2 preserves the evaluated grain transform without introducing
    /// renderer anchoring semantics that are intentionally deferred.
    func grainFrame(
        scale: Float,
        rotation: Float,
        offset: SIMD2<Float>
    ) -> Affine2D {
        let cosine = cos(rotation) * scale
        let sine = sin(rotation) * scale
        return Affine2D(
            xAxis: SIMD2(cosine, sine),
            yAxis: SIMD2(-sine, cosine),
            translation: offset
        )
    }

    /// Native grain frames carry their Stage 2 anchoring convention in world
    /// space. Canonical grains slide from a fixed canvas anchor to the dab
    /// position according to `grainMovementFraction`; brush-local grains stay
    /// centered on the dab. Brush-follow rotation rotates both the authored
    /// axes and authored/random offset before the frame is projected through
    /// symmetry.
    func nativeGrainFrame(
        layer: BrushGrainLayerDefinition,
        scale: Float,
        offset: SIMD2<Float>,
        position: WorldPoint,
        brushRotation: Float
    ) -> Affine2D {
        let followRotation = layer.grainFollowsBrushRotation
            ? brushRotation
            : 0
        let rotation = layer.transform.rotation + followRotation
        let cosine = cos(rotation) * scale
        let sine = sin(rotation) * scale
        let followCosine = cos(followRotation)
        let followSine = sin(followRotation)
        let rotatedOffset = SIMD2(
            followCosine * offset.x - followSine * offset.y,
            followSine * offset.x + followCosine * offset.y
        )
        let anchor: SIMD2<Float>
        switch layer.coordinateMode {
        case .canonical:
            anchor = position.simd * layer.grainMovementFraction
        case .brushLocal:
            anchor = position.simd
        }
        return Affine2D(
            xAxis: SIMD2(cosine, sine),
            yAxis: SIMD2(-sine, cosine),
            translation: anchor + rotatedOffset
        )
    }

    func nativeRandomValues(
        compatibility: BrushRandomValues,
        strokeSeed: UInt64,
        ordinal: UInt64
    ) -> BrushLogicalRandomValues {
        func value(_ channel: BrushProgramRandomChannel) -> Float {
            BrushRandom.extensionUnitFloat(
                strokeSeed: strokeSeed,
                logicalDabOrdinal: ordinal,
                outputChannel: channel
            )
        }
        return BrushLogicalRandomValues(
            compatibility: compatibility,
            size: value(.size),
            flow: value(.flow),
            opacity: value(.opacity),
            hardness: value(.hardness),
            offsetX: value(.offsetX),
            offsetY: value(.offsetY),
            hue: value(.hue),
            saturation: value(.saturation),
            brightness: value(.brightness),
            secondaryColorMix: value(.secondaryColorMix)
        )
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
