import PatternEngine

/// Native deposition fixtures. Their small, explicit tuning range is intended
/// for backend diagnosis, not a claim of final brush character.
public enum StageFourAnchorDefinitions {
    public static let ink = make(
        id: "builtin.native-ink", name: "Native Ink", shape: .hardRound,
        grains: [], flow: 0.82, hardness: 0.9, aspect: 1,
        accumulation: .flow, edge: .none
    )
    public static let dryMedia = make(
        id: "builtin.native-dry-media", name: "Native Dry Media",
        shape: .hardRound,
        grains: [grain(.paper, strength: 0.72)], flow: 0.68, hardness: 0.74,
        aspect: 0.72, accumulation: .flow, edge: .dryBreakup
    )
    public static let glaze = make(
        id: "builtin.native-glaze", name: "Native Glaze", shape: .softRound,
        grains: [], flow: 0.55, hardness: 1, aspect: 1,
        accumulation: .uniformGlaze, edge: .none
    )
    public static let marker = make(
        id: "builtin.native-marker", name: "Native Marker", shape: .chisel,
        grains: [], flow: 0.65, hardness: 0.9, aspect: 0.82,
        accumulation: .uniformGlaze, edge: .markerOverlap
    )
    public static let airbrush = make(
        id: "builtin.native-airbrush", name: "Native Airbrush", shape: .softRound,
        grains: [], flow: 0.3, hardness: 1, aspect: 1,
        accumulation: .flow, edge: .none
    )
    public static let eraser = make(
        id: "builtin.native-eraser", name: "Native Eraser", shape: .hardRound,
        grains: [], flow: 1, hardness: 1, aspect: 1,
        accumulation: .destinationOut, edge: .none, strokeOpacity: 1,
        materialStrength: 1, accumulationLimit: 1, scatterFraction: 0,
        jitterFraction: 0
    )

    private static let limits = BrushDefinitionLimits(
        minimumDiameter: 0.01, maximumDiameter: 16_384, maximumOpacity: 1,
        maximumSpacingFraction: 4, maximumResourceDimension: 4_096,
        maximumResidentBytes: 64 * 1_024 * 1_024
    )

    private static func grain(
        _ descriptor: BrushGrainDescriptor, strength: Float
    ) -> BrushGrainLayerDefinition {
        BrushGrainLayerDefinition(
            grain: descriptor, coordinateMode: .canonical, transform: .identity,
            grainMovementFraction: 0.12, grainFollowsBrushRotation: false,
            strength: strength
        )
    }

    private static func constant(_ value: Float) -> BrushMappingDefinition {
        BrushMappingDefinition(
            input: .pressure, response: .constant(value), scale: 1, offset: 0,
            lowerClamp: value, upperClamp: value, inverted: false, jitter: 0,
            missingInputValue: 1
        )
    }

    private static func make(
        id: String, name: String, shape: BrushShapeDescriptor,
        grains: [BrushGrainLayerDefinition], flow: Float, hardness: Float,
        aspect: Float, accumulation: BrushAccumulationMode,
        edge: BrushEdgeTreatment, strokeOpacity: Float = 0.9,
        materialStrength: Float = 0.9, accumulationLimit: Float = 0.9,
        scatterFraction: Float = 0.02, jitterFraction: Float = 0.01
    ) -> BrushDefinition {
        do {
            let one = constant(1)
            let zero = constant(0)
            return try BrushDefinition(
                id: BrushRecipeID(id), metadata: BrushMetadata(displayName: name),
                capabilities: [], resources: [],
                coverage: BrushCoverageDefinition(
                    shapes: [BrushShapeLayerDefinition(
                        shape: shape, combination: .replace, scale: 1,
                        rotation: 0, offset: .zero
                    )], grains: grains, baseHardness: hardness, aspectRatio: aspect,
                    tipThreshold: 0.01, antialiasing: true
                ),
                placement: BrushPlacementDefinition(
                    baseSpacingFraction: 0.1, maximumSpacingFraction: 0.25,
                    baseFlow: flow, strokeOpacity: strokeOpacity,
                    baseScatterFraction: scatterFraction,
                    baseRotation: 0, baseJitterFraction: jitterFraction,
                    baseOffset: .zero
                ),
                dynamics: BrushDynamicsDefinition(
                    size: BrushMappingDefinition(
                        input: .pressure, response: .boundedPower(exponent: 0.8),
                        scale: 0.7, offset: 0.3, lowerClamp: 0.3, upperClamp: 1,
                        inverted: false, jitter: 0, missingInputValue: 1
                    ), flow: one, opacity: one, spacing: one, rotation: zero,
                    scatter: one, hardness: one, grain: one, offsetX: zero,
                    offsetY: zero, hue: zero, saturation: zero, brightness: zero,
                    secondaryColorMix: zero, noPressureNeutral: 1,
                    randomization: .none
                ),
                color: BrushColorBehaviorDefinition(
                    baseAdjustment: .identity,
                    perStampJitter: BrushColorJitter(hue: 0, saturation: 0, brightness: 0, secondaryColorMix: 0),
                    perStrokeJitter: BrushColorJitter(hue: 0, saturation: 0, brightness: 0, secondaryColorMix: 0)
                ),
                material: BrushMaterialDefinition(
                    accumulation: accumulation, interaction: .none,
                    edgeTreatment: edge, strength: materialStrength,
                    wetness: 0, bleedRadius: 0, softenPasses: 0,
                    accumulationLimit: accumulationLimit,
                    interactionParameters: nil
                ), stabilization: 0, taper: .none, replayMode: .appendOnly,
                replayLimits: nil, seedPolicy: .perStroke, limits: limits,
                performanceIntent: .realtime120,
                compatibility: BrushCompatibilityMetadata(
                    nativeFeatureVersion: 1, sourceSettingKeys: [],
                    requiredSemanticKeys: []
                )
            )
        } catch {
            preconditionFailure("Invalid Stage 4 anchor definition: \(error)")
        }
    }
}
