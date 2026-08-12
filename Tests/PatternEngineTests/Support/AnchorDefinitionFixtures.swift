@testable import PatternEngine

struct AnchorDefinitionFixture: Sendable {
    let displayName: String
    let definition: BrushDefinition
}

enum AnchorDefinitionFixtures {
    static let all: [AnchorDefinitionFixture] = [
        AnchorDefinitionFixture(
            displayName: "Current Ink",
            definition: nativeTestDefinition(
                id: BrushRecipeID("test.anchor.current-ink")
            )
        ),
        AnchorDefinitionFixture(
            displayName: "Current Dry Media",
            definition: nativeTestDefinition(
                id: BrushRecipeID("test.anchor.current-dry"),
                coverage: coverage(
                    shape: .hardRound,
                    grain: .paper,
                    hardness: 0.75,
                    aspectRatio: 0.7
                ),
                material: material(
                    accumulation: .flow,
                    edgeTreatment: .dryBreakup,
                    strength: 0.85,
                    accumulationLimit: 1
                )
            )
        ),
        AnchorDefinitionFixture(
            displayName: "Current Marker",
            definition: nativeTestDefinition(
                id: BrushRecipeID("test.anchor.current-marker"),
                coverage: coverage(
                    shape: .chisel,
                    hardness: 0.7,
                    aspectRatio: 0.7
                ),
                material: material(
                    accumulation: .uniformGlaze,
                    edgeTreatment: .markerOverlap,
                    strength: 0.8,
                    accumulationLimit: 0.85
                )
            )
        ),
        AnchorDefinitionFixture(
            displayName: "Current Replay Tail",
            definition: nativeTestDefinition(
                id: BrushRecipeID("test.anchor.current-replay-tail"),
                coverage: coverage(
                    shape: .softRound,
                    grain: .paper,
                    hardness: 0.2,
                    aspectRatio: 1
                ),
                replayMode: .replayTail,
                replayLimits: BrushRecipePolicy.replayTailLimits
            )
        ),
        AnchorDefinitionFixture(
            displayName: "Current Eraser Geometry",
            definition: nativeTestDefinition(
                id: BrushRecipeID("test.anchor.current-eraser")
            )
        ),
    ]

    private static func coverage(
        shape: BrushShapeDescriptor,
        grain: BrushGrainDescriptor? = nil,
        hardness: Float,
        aspectRatio: Float
    ) -> BrushCoverageDefinition {
        BrushCoverageDefinition(
            shapes: [BrushShapeLayerDefinition(
                shape: shape,
                combination: .replace,
                scale: 1,
                rotation: 0,
                offset: .zero
            )],
            grains: grain.map {
                [BrushGrainLayerDefinition(
                    grain: $0,
                    coordinateMode: .canonical,
                    transform: .identity,
                    grainMovementFraction: 0,
                    grainFollowsBrushRotation: false,
                    strength: 1
                )]
            } ?? [],
            baseHardness: hardness,
            aspectRatio: aspectRatio,
            tipThreshold: 0,
            antialiasing: true
        )
    }

    private static func material(
        accumulation: BrushAccumulationMode,
        edgeTreatment: BrushEdgeTreatment,
        strength: Float,
        accumulationLimit: Float
    ) -> BrushMaterialDefinition {
        BrushMaterialDefinition(
            accumulation: accumulation,
            interaction: .none,
            edgeTreatment: edgeTreatment,
            strength: strength,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: accumulationLimit,
            interactionParameters: nil
        )
    }
}
