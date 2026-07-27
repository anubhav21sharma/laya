import PatternEngine
import Testing

@Test
func constructedPayloadUsesTheSharedDigestAPI() {
    let dab = DabAttributes(
        position: WorldPoint(x: 0, y: 0),
        brushToWorld: .identity,
        radius: 1,
        diameter: 2,
        spacing: 1,
        flow: 1,
        strokeOpacity: 1,
        rotation: 0,
        scatter: .zero,
        hardness: 1,
        grainOffset: .zero,
        grainScale: 1,
        grainRotation: 0,
        color: .black,
        colorAdjustment: .identity,
        materialFamily: .ink,
        materialContribution: 1,
        sourceDistance: 0,
        ordinal: 0,
        isPredicted: false
    )
    let payload = BrushCharacterizationDigestPayload(
        ordinal: 0,
        dab: dab,
        primaryGrainFrame: .identity,
        secondaryGrainFrame: .identity,
        hasPrimaryGrain: false,
        hasSecondaryGrain: false,
        secondaryColorMix: 0,
        accumulationEnabled: false,
        interactionEnabled: false,
        edgeEnabled: false,
        materialStrength: 1,
        materialWetness: 0,
        materialBleedRadius: 0,
        materialSoftenPasses: 0,
        materialAccumulationLimit: 1,
        compatibilityRandom: .centered,
        extensionRandom: .zero,
        worldBoundsMinimum: .zero,
        worldBoundsMaximum: .zero
    )

    let digest = BrushCharacterizationDigest.digest([payload])
    #expect(digest.count == 16)
    #expect(digest == BrushCharacterizationDigest.digest([payload]))
}
