import PatternEngine
import simd

/// Authored professional dry-media definitions. Stage 5 entries are separate
/// from the immutable Stage 4 diagnostic anchors.
public enum ProfessionalBrushDefinitions {
    public static let technicalInk = makeTechnicalInk()
    public static let graphitePencil = makeGraphitePencil()
    public static let naturalCharcoal = makeNaturalCharcoal()
    public static let chiselMarker = makeChiselMarker()

    private static let limits = BrushDefinitionLimits(
        minimumDiameter: 0.01,
        maximumDiameter: 16_384,
        maximumOpacity: 1,
        maximumSpacingFraction: 4,
        maximumResourceDimension: 4_096,
        maximumResidentBytes: 64 * 1_024 * 1_024
    )

    private static let replayTailTermination =
        BrushTerminationDefinition.boundedCorrection(
            maximumSamples:
                BrushRecipePolicy.replayTailLimits.maximumSamples,
            maximumWorldLength: 4_096,
            maximumDabs:
                BrushRecipePolicy.replayTailLimits.maximumDabs
        )

    private static func constant(_ value: Float) -> BrushMappingDefinition {
        BrushMappingDefinition(
            input: .pressure,
            response: .constant(value),
            scale: 1,
            offset: 0,
            lowerClamp: value,
            upperClamp: value,
            inverted: false,
            jitter: 0,
            missingInputValue: 1
        )
    }

    private static func linear(
        _ input: BrushDynamicsInput,
        output: ClosedRange<Float>,
        inverted: Bool = false,
        missingInputValue: Float = 1
    ) -> BrushMappingDefinition {
        BrushMappingDefinition(
            input: input,
            response: .linear,
            scale: output.upperBound - output.lowerBound,
            offset: output.lowerBound,
            lowerClamp: output.lowerBound,
            upperClamp: output.upperBound,
            inverted: inverted,
            jitter: 0,
            missingInputValue: missingInputValue
        )
    }

    private static func makeTechnicalInk() -> BrushDefinition {
        do {
            let one = constant(1)
            let zero = constant(0)
            return try BrushDefinition(
                id: BrushRecipeID("builtin.professional-technical-ink"),
                metadata: BrushMetadata(displayName: "Technical Ink"),
                capabilities: [],
                resources: [
                    BrushResourceReference(
                        identifier: "builtin.shape.technical-nib",
                        kind: .shape,
                        required: false,
                        fallback: .builtIn(identifier: "builtin.shape.technical-nib")
                    ),
                ],
                coverage: BrushCoverageDefinition(
                    shapes: [
                        BrushShapeLayerDefinition(
                            shape: .asset("builtin.shape.technical-nib"),
                            combination: .replace,
                            scale: 1,
                            rotation: 0,
                            offset: .zero
                        ),
                    ],
                    grains: [],
                    baseHardness: 0.98,
                    aspectRatio: 0.92,
                    tipThreshold: 0.01,
                    antialiasing: true
                ),
                placement: BrushPlacementDefinition(
                    baseSpacingFraction: 0.045,
                    maximumSpacingFraction: 0.12,
                    baseFlow: 0.9,
                    strokeOpacity: 1,
                    baseScatterFraction: 0,
                    baseRotation: 0,
                    baseJitterFraction: 0,
                    baseOffset: .zero
                ),
                dynamics: BrushDynamicsDefinition(
                    size: linear(.pressure, output: 0.18...1),
                    flow: linear(.pressure, output: 0.65...1),
                    opacity: one,
                    spacing: linear(.speed, output: 0.8...1.15),
                    rotation: linear(.direction, output: 0...(2 * .pi)),
                    scatter: one,
                    hardness: one,
                    grain: one,
                    offsetX: zero,
                    offsetY: zero,
                    hue: zero,
                    saturation: zero,
                    brightness: zero,
                    secondaryColorMix: zero,
                    noPressureNeutral: 1,
                    randomization: .none
                ),
                color: BrushColorBehaviorDefinition(
                    baseAdjustment: .identity,
                    perStampJitter: BrushColorJitter(
                        hue: 0,
                        saturation: 0,
                        brightness: 0,
                        secondaryColorMix: 0
                    ),
                    perStrokeJitter: BrushColorJitter(
                        hue: 0,
                        saturation: 0,
                        brightness: 0,
                        secondaryColorMix: 0
                    )
                ),
                // Ordinary flow ink has no edge-specific strength or opacity cap.
                material: BrushMaterialDefinition(
                    accumulation: .flow,
                    interaction: .none,
                    edgeTreatment: .none,
                    strength: 1,
                    wetness: 0,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 1,
                    interactionParameters: nil
                ),
                stabilization: 0.22,
                taper: BrushTaperConfiguration(
                    start: .diameterMultiples(1.25),
                    end: .diameterMultiples(1.5),
                    minimumSize: 0.08,
                    minimumFlow: 0.25,
                    effects: [.size, .flow]
                ),
                replayMode: .replayTail,
                replayLimits: BrushRecipePolicy.replayTailLimits,
                termination: replayTailTermination,
                seedPolicy: .perStroke,
                limits: limits,
                performanceIntent: .realtime60,
                compatibility: BrushCompatibilityMetadata(
                    sourceSettingKeys: [],
                    requiredSemanticKeys: []
                )
            )
        } catch {
            preconditionFailure("Invalid professional Technical Ink definition: \(error)")
        }
    }

    private static func makeGraphitePencil() -> BrushDefinition {
        do {
            let one = constant(1)
            let zero = constant(0)
            return try BrushDefinition(
                id: BrushRecipeID("builtin.professional-graphite-pencil"),
                metadata: BrushMetadata(displayName: "Graphite Pencil"),
                capabilities: [
                    BrushCapabilityDeclaration(identifier: "dualGrain", required: true),
                ],
                resources: [
                    BrushResourceReference(
                        identifier: "builtin.grain.graphite",
                        kind: .grain,
                        required: false,
                        fallback: .builtIn(identifier: "builtin.grain.graphite")
                    ),
                    BrushResourceReference(
                        identifier: "builtin.grain.graphite-paper",
                        kind: .grain,
                        required: false,
                        fallback: .builtIn(identifier: "builtin.grain.graphite-paper")
                    ),
                    BrushResourceReference(
                        identifier: "builtin.shape.graphite-tip",
                        kind: .shape,
                        required: false,
                        fallback: .builtIn(identifier: "builtin.shape.graphite-tip")
                    ),
                ],
                coverage: BrushCoverageDefinition(
                    shapes: [
                        BrushShapeLayerDefinition(
                            shape: .asset("builtin.shape.graphite-tip"),
                            combination: .replace,
                            scale: 1,
                            rotation: 0,
                            offset: .zero
                        ),
                    ],
                    grains: [
                        BrushGrainLayerDefinition(
                            grain: .asset("builtin.grain.graphite"),
                            coordinateMode: .brushLocal,
                            transform: .identity,
                            grainMovementFraction: 0.12,
                            grainFollowsBrushRotation: true,
                            strength: 1
                        ),
                        BrushGrainLayerDefinition(
                            grain: .asset("builtin.grain.graphite-paper"),
                            coordinateMode: .canonical,
                            transform: .identity,
                            grainMovementFraction: 0.12,
                            grainFollowsBrushRotation: false,
                            strength: 1
                        ),
                    ],
                    baseHardness: 0.72,
                    aspectRatio: 0.82,
                    tipThreshold: 0.01,
                    antialiasing: true
                ),
                placement: BrushPlacementDefinition(
                    baseSpacingFraction: 0.055,
                    maximumSpacingFraction: 0.15,
                    baseFlow: 0.28,
                    strokeOpacity: 0.88,
                    baseScatterFraction: 0.015,
                    baseRotation: 0,
                    baseJitterFraction: 0.01,
                    baseOffset: .zero
                ),
                dynamics: BrushDynamicsDefinition(
                    size: linear(.pressure, output: 0.25...1),
                    flow: linear(.pressure, output: 0.10...1),
                    opacity: linear(.pressure, output: 0.20...1),
                    spacing: linear(.speed, output: 0.85...1.15),
                    rotation: linear(.direction, output: 0...(2 * .pi)),
                    scatter: one,
                    hardness: linear(
                        .tilt,
                        output: 0.35...0.90,
                        inverted: true
                    ),
                    grain: linear(.tilt, output: 0.75...1.40),
                    offsetX: zero,
                    offsetY: zero,
                    hue: zero,
                    saturation: zero,
                    brightness: zero,
                    secondaryColorMix: zero,
                    noPressureNeutral: 1,
                    randomization: BrushRandomization(
                        spacing: 0.04,
                        scatter: 0.08,
                        rotation: 0.08,
                        grain: 0.08,
                        material: 0.05
                    )
                ),
                color: BrushColorBehaviorDefinition(
                    baseAdjustment: .identity,
                    perStampJitter: BrushColorJitter(
                        hue: 0,
                        saturation: 0,
                        brightness: 0,
                        secondaryColorMix: 0
                    ),
                    perStrokeJitter: BrushColorJitter(
                        hue: 0,
                        saturation: 0,
                        brightness: 0,
                        secondaryColorMix: 0
                    )
                ),
                // §7.2 leaves material scalars open; use ordinary flow's
                // neutral strength and uncapped accumulation defaults.
                material: BrushMaterialDefinition(
                    accumulation: .flow,
                    interaction: .none,
                    edgeTreatment: .dryBreakup,
                    strength: 1,
                    wetness: 0,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 1,
                    interactionParameters: nil
                ),
                stabilization: 0.12,
                taper: BrushTaperConfiguration(
                    start: .diameterMultiples(0.75),
                    end: .diameterMultiples(1),
                    minimumSize: 0.20,
                    minimumFlow: 0.25,
                    effects: [.size, .flow]
                ),
                replayMode: .replayTail,
                replayLimits: BrushRecipePolicy.replayTailLimits,
                termination: replayTailTermination,
                seedPolicy: .perStroke,
                limits: limits,
                performanceIntent: .realtime60,
                compatibility: BrushCompatibilityMetadata(
                    sourceSettingKeys: [],
                    requiredSemanticKeys: []
                )
            )
        } catch {
            preconditionFailure("Invalid professional Graphite Pencil definition: \(error)")
        }
    }

    private static func makeNaturalCharcoal() -> BrushDefinition {
        do {
            let zero = constant(0)
            return try BrushDefinition(
                id: BrushRecipeID("builtin.professional-natural-charcoal"),
                metadata: BrushMetadata(displayName: "Natural Charcoal"),
                capabilities: [
                    BrushCapabilityDeclaration(identifier: "dualGrain", required: true),
                    BrushCapabilityDeclaration(identifier: "dualShape", required: true),
                ],
                resources: [
                    BrushResourceReference(
                        identifier: "builtin.grain.charcoal",
                        kind: .grain,
                        required: false,
                        fallback: .builtIn(identifier: "builtin.grain.charcoal")
                    ),
                    BrushResourceReference(
                        identifier: "builtin.grain.charcoal-fine-paper",
                        kind: .grain,
                        required: false,
                        fallback: .builtIn(identifier: "builtin.grain.charcoal-fine-paper")
                    ),
                    BrushResourceReference(
                        identifier: "builtin.shape.charcoal-tip",
                        kind: .shape,
                        required: false,
                        fallback: .builtIn(identifier: "builtin.shape.charcoal-tip")
                    ),
                ],
                coverage: BrushCoverageDefinition(
                    shapes: [
                        BrushShapeLayerDefinition(
                            shape: .asset("builtin.shape.charcoal-tip"),
                            combination: .replace,
                            scale: 1,
                            rotation: 0,
                            offset: .zero
                        ),
                        BrushShapeLayerDefinition(
                            shape: .softRound,
                            combination: .maximum,
                            scale: 1,
                            rotation: 0,
                            offset: .zero
                        ),
                    ],
                    grains: [
                        BrushGrainLayerDefinition(
                            grain: .asset("builtin.grain.charcoal"),
                            coordinateMode: .brushLocal,
                            transform: .identity,
                            grainMovementFraction: 0.12,
                            grainFollowsBrushRotation: true,
                            strength: 1
                        ),
                        BrushGrainLayerDefinition(
                            grain: .asset("builtin.grain.charcoal-fine-paper"),
                            coordinateMode: .canonical,
                            transform: .identity,
                            grainMovementFraction: 0.12,
                            grainFollowsBrushRotation: false,
                            strength: 1
                        ),
                    ],
                    baseHardness: 0.58,
                    aspectRatio: 0.55,
                    tipThreshold: 0.01,
                    antialiasing: true
                ),
                placement: BrushPlacementDefinition(
                    baseSpacingFraction: 0.09,
                    maximumSpacingFraction: 0.22,
                    baseFlow: 0.82,
                    strokeOpacity: 0.92,
                    baseScatterFraction: 0.08,
                    baseRotation: 0,
                    baseJitterFraction: 0.035,
                    baseOffset: .zero
                ),
                dynamics: BrushDynamicsDefinition(
                    size: linear(.tilt, output: 0.45...1.70),
                    flow: linear(.pressure, output: 0.10...1),
                    opacity: linear(.pressure, output: 0.25...1),
                    spacing: linear(.speed, output: 0.75...1.25),
                    rotation: linear(.direction, output: 0...(2 * .pi)),
                    scatter: linear(.speed, output: 0.70...1.50),
                    hardness: linear(
                        .tilt,
                        output: 0.22...0.82,
                        inverted: true
                    ),
                    grain: linear(
                        .pressure,
                        output: 0.80...1.40,
                        inverted: true
                    ),
                    offsetX: zero,
                    offsetY: zero,
                    hue: zero,
                    saturation: zero,
                    brightness: zero,
                    secondaryColorMix: zero,
                    noPressureNeutral: 1,
                    randomization: BrushRandomization(
                        spacing: 0.08,
                        scatter: 0.18,
                        rotation: 0.18,
                        grain: 0.16,
                        material: 0.12
                    )
                ),
                color: BrushColorBehaviorDefinition(
                    baseAdjustment: .identity,
                    perStampJitter: BrushColorJitter(
                        hue: 0,
                        saturation: 0,
                        brightness: 0,
                        secondaryColorMix: 0
                    ),
                    perStrokeJitter: BrushColorJitter(
                        hue: 0,
                        saturation: 0,
                        brightness: 0,
                        secondaryColorMix: 0
                    )
                ),
                // §7.3 leaves material scalars open; ordinary dry flow uses
                // neutral strength and the full normalized accumulation limit.
                material: BrushMaterialDefinition(
                    accumulation: .flow,
                    interaction: .none,
                    edgeTreatment: .dryBreakup,
                    strength: 1,
                    wetness: 0,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 1,
                    interactionParameters: nil
                ),
                stabilization: 0.05,
                taper: BrushTaperConfiguration(
                    start: .diameterMultiples(0.5),
                    end: .diameterMultiples(0.5),
                    minimumSize: 0.35,
                    minimumFlow: 0.30,
                    effects: [.size, .flow]
                ),
                replayMode: .replayTail,
                replayLimits: BrushRecipePolicy.replayTailLimits,
                termination: replayTailTermination,
                seedPolicy: .perStroke,
                limits: limits,
                performanceIntent: .realtime60,
                compatibility: BrushCompatibilityMetadata(
                    sourceSettingKeys: [],
                    requiredSemanticKeys: []
                )
            )
        } catch {
            preconditionFailure("Invalid professional Natural Charcoal definition: \(error)")
        }
    }

    private static func makeChiselMarker() -> BrushDefinition {
        do {
            let one = constant(1)
            let zero = constant(0)
            return try BrushDefinition(
                id: BrushRecipeID("builtin.professional-chisel-marker"),
                metadata: BrushMetadata(displayName: "Chisel Marker"),
                capabilities: [],
                resources: [
                    BrushResourceReference(
                        identifier: "builtin.shape.marker-chisel",
                        kind: .shape,
                        required: false,
                        fallback: .builtIn(identifier: "builtin.shape.marker-chisel")
                    ),
                ],
                coverage: BrushCoverageDefinition(
                    shapes: [
                        BrushShapeLayerDefinition(
                            shape: .asset("builtin.shape.marker-chisel"),
                            combination: .replace,
                            scale: 1,
                            rotation: 0,
                            offset: .zero
                        ),
                    ],
                    grains: [],
                    baseHardness: 0.96,
                    aspectRatio: 1,
                    tipThreshold: 0.01,
                    antialiasing: true
                ),
                placement: BrushPlacementDefinition(
                    baseSpacingFraction: 0.035,
                    maximumSpacingFraction: 0.10,
                    baseFlow: 0.56,
                    strokeOpacity: 0.82,
                    baseScatterFraction: 0,
                    baseRotation: 0,
                    baseJitterFraction: 0,
                    baseOffset: .zero
                ),
                dynamics: BrushDynamicsDefinition(
                    size: linear(.pressure, output: 0.70...1),
                    flow: linear(.speed, output: 0.75...1, inverted: true),
                    opacity: one,
                    spacing: one,
                    rotation: linear(.direction, output: 0...(2 * .pi)),
                    scatter: one,
                    hardness: one,
                    grain: one,
                    offsetX: zero,
                    offsetY: zero,
                    hue: zero,
                    saturation: zero,
                    brightness: zero,
                    secondaryColorMix: zero,
                    noPressureNeutral: 1,
                    randomization: .none
                ),
                color: BrushColorBehaviorDefinition(
                    baseAdjustment: .identity,
                    perStampJitter: BrushColorJitter(
                        hue: 0,
                        saturation: 0,
                        brightness: 0,
                        secondaryColorMix: 0
                    ),
                    perStrokeJitter: BrushColorJitter(
                        hue: 0,
                        saturation: 0,
                        brightness: 0,
                        secondaryColorMix: 0
                    )
                ),
                material: BrushMaterialDefinition(
                    accumulation: .uniformGlaze,
                    interaction: .none,
                    edgeTreatment: .markerOverlap,
                    strength: 0.95,
                    wetness: 0,
                    bleedRadius: 0,
                    softenPasses: 0,
                    accumulationLimit: 0.82,
                    interactionParameters: nil
                ),
                stabilization: 0,
                taper: BrushTaperConfiguration(
                    start: .diameterMultiples(0.35),
                    end: .diameterMultiples(0.35),
                    minimumSize: 0.85,
                    minimumFlow: 0.85,
                    effects: [.size, .flow]
                ),
                replayMode: .replayTail,
                replayLimits: BrushRecipePolicy.replayTailLimits,
                termination: replayTailTermination,
                seedPolicy: .perStroke,
                limits: limits,
                performanceIntent: .realtime60,
                compatibility: BrushCompatibilityMetadata(
                    sourceSettingKeys: [],
                    requiredSemanticKeys: []
                ),
                direction: BrushDirectionDefinition(
                    maximumAngularStep: .pi / 12,
                    stationaryDirection: 0
                )
            )
        } catch {
            preconditionFailure("Invalid professional Chisel Marker definition: \(error)")
        }
    }
}
