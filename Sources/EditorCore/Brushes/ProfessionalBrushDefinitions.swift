import PatternEngine
import simd

/// Authored professional dry-media definitions. Stage 5 entries are separate
/// from the immutable Stage 4 diagnostic anchors.
public enum ProfessionalBrushDefinitions {
    public static let technicalInk = makeTechnicalInk()

    private static let limits = BrushDefinitionLimits(
        minimumDiameter: 0.01,
        maximumDiameter: 16_384,
        maximumOpacity: 1,
        maximumSpacingFraction: 4,
        maximumResourceDimension: 4_096,
        maximumResidentBytes: 64 * 1_024 * 1_024
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
        missingInputValue: Float = 1
    ) -> BrushMappingDefinition {
        BrushMappingDefinition(
            input: input,
            response: .linear,
            scale: output.upperBound - output.lowerBound,
            offset: output.lowerBound,
            lowerClamp: output.lowerBound,
            upperClamp: output.upperBound,
            inverted: false,
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
                seedPolicy: .perStroke,
                limits: limits,
                performanceIntent: .realtime120,
                compatibility: BrushCompatibilityMetadata(
                    nativeFeatureVersion: 1,
                    sourceSettingKeys: [],
                    requiredSemanticKeys: []
                )
            )
        } catch {
            preconditionFailure("Invalid professional Technical Ink definition: \(error)")
        }
    }
}
