import PatternEngine
import Testing

private func logicalDab(
    ordinal: UInt64,
    isPredicted: Bool = false,
    brushToWorld: Affine2D = .identity,
    primaryGrainToWorld: Affine2D? = nil,
    secondaryGrainToWorld: Affine2D? = nil,
    materialInputs: BrushMaterialInputs = .neutral,
    randomValues: BrushLogicalRandomValues = .neutral,
    colorAdjustment: BrushColorAdjustment = .identity,
    radius: Float = 1
) -> LogicalDab {
    LogicalDab(
        position: WorldPoint(brushToWorld.translation),
        brushToWorld: brushToWorld,
        radius: radius,
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
        colorAdjustment: colorAdjustment,
        materialFamily: .ink,
        materialContribution: 1,
        sourceDistance: Float(ordinal),
        ordinal: ordinal,
        isPredicted: isPredicted,
        secondaryColorMix: 0,
        primaryGrainToWorld: primaryGrainToWorld,
        secondaryGrainToWorld: secondaryGrainToWorld,
        materialInputs: materialInputs,
        randomValues: randomValues
    )
}

@Test
func batchAccepts512DabsAndRejects513() throws {
    let acceptedDabs = (0..<512).map {
        logicalDab(ordinal: UInt64($0))
    }
    let accepted = try LogicalDabBatch(
        seed: 9,
        startingOrdinal: 0,
        isPredicted: false,
        dabs: acceptedDabs
    )

    #expect(accepted.dabs.count == 512)
    #expect(accepted.ordinalRange == 0..<512)
    #expect(throws: LogicalDabBatchError.tooManyDabs(
        actual: 513,
        maximum: 512
    )) {
        try LogicalDabBatch(
            seed: 9,
            startingOrdinal: 0,
            isPredicted: false,
            dabs: acceptedDabs + [logicalDab(ordinal: 512)]
        )
    }
}

@Test
func batchRejectsEveryOrdinalOrderingFailure() {
    for dabs in [
        [logicalDab(ordinal: 3), logicalDab(ordinal: 3)],
        [logicalDab(ordinal: 3), logicalDab(ordinal: 2)],
        [logicalDab(ordinal: 3), logicalDab(ordinal: 5)],
    ] {
        #expect(throws: LogicalDabBatchError.self) {
            try LogicalDabBatch(
                seed: 9,
                startingOrdinal: 3,
                isPredicted: false,
                dabs: dabs
            )
        }
    }

    #expect(throws: LogicalDabBatchError.noncontiguousOrdinal(
        expected: 4,
        actual: 5
    )) {
        try LogicalDabBatch(
            seed: 9,
            startingOrdinal: 3,
            isPredicted: false,
            dabs: [logicalDab(ordinal: 3), logicalDab(ordinal: 5)]
        )
    }
}

@Test
func batchRejectsZeroSeedOrdinalOverflowAndNonfiniteDab() {
    #expect(throws: LogicalDabBatchError.zeroSeed) {
        try LogicalDabBatch(
            seed: 0,
            startingOrdinal: 0,
            isPredicted: false,
            dabs: []
        )
    }
    #expect(throws: LogicalDabBatchError.ordinalOverflow) {
        try LogicalDabBatch(
            seed: 9,
            startingOrdinal: .max,
            isPredicted: false,
            dabs: [logicalDab(ordinal: .max)]
        )
    }
    #expect(throws: LogicalDabBatchError.nonfiniteDab(ordinal: 0)) {
        try LogicalDabBatch(
            seed: 9,
            startingOrdinal: 0,
            isPredicted: false,
            dabs: [logicalDab(ordinal: 0, radius: .nan)]
        )
    }
    #expect(throws: LogicalDabBatchError.nonfiniteDab(ordinal: 0)) {
        try LogicalDabBatch(
            seed: 9,
            startingOrdinal: 0,
            isPredicted: false,
            dabs: [logicalDab(
                ordinal: 0,
                colorAdjustment: BrushColorAdjustment(
                    redMultiplier: .nan,
                    greenMultiplier: 1,
                    blueMultiplier: 1,
                    alphaMultiplier: 1
                )
            )]
        )
    }
}

@Test
func batchRejectsMixedAndExplicitlyMismatchedProvenance() {
    #expect(throws: LogicalDabBatchError.mixedProvenance) {
        try LogicalDabBatch(
            seed: 9,
            startingOrdinal: 0,
            isPredicted: false,
            dabs: [
                logicalDab(ordinal: 0),
                logicalDab(ordinal: 1, isPredicted: true),
            ]
        )
    }
    #expect(throws: LogicalDabBatchError.provenanceMismatch(
        expectedPredicted: true
    )) {
        try LogicalDabBatch(
            seed: 9,
            startingOrdinal: 0,
            isPredicted: true,
            dabs: [logicalDab(ordinal: 0)]
        )
    }
}

@Test
func emptyBatchPreservesPredictionAndStartingOrdinal() throws {
    let batch = try LogicalDabBatch(
        seed: 9,
        startingOrdinal: 73,
        isPredicted: true,
        dabs: []
    )

    #expect(batch.dabs.isEmpty)
    #expect(batch.isPredicted)
    #expect(batch.ordinalRange == 73..<73)
    #expect(batch.worldBounds == nil)
}

@Test
func rotatedAnisotropicBoundsIncludeAllCornersAndMaterialHalo() {
    let brushToWorld = Affine2D(
        xAxis: SIMD2(3, 4),
        yAxis: SIMD2(-2, 1.5),
        translation: SIMD2(20, 30)
    )
    let material = BrushMaterialInputs(
        accumulation: .flow,
        interaction: .none,
        edgeTreatment: .wetConcentration,
        strength: 1,
        wetness: 0.5,
        bleedRadius: 2,
        accumulationLimit: 0.75,
        interactionParameters: nil
    )

    let dab = logicalDab(
        ordinal: 0,
        brushToWorld: brushToWorld,
        materialInputs: material
    )

    #expect(dab.worldBounds.minimum == SIMD2(13, 22.5))
    #expect(dab.worldBounds.maximum == SIMD2(27, 37.5))
    for corner in [
        SIMD2<Float>(-1, -1),
        SIMD2<Float>(1, -1),
        SIMD2<Float>(1, 1),
        SIMD2<Float>(-1, 1),
    ] {
        let transformed = brushToWorld.applying(to: corner)
        #expect(transformed.x >= dab.worldBounds.minimum.x)
        #expect(transformed.x <= dab.worldBounds.maximum.x)
        #expect(transformed.y >= dab.worldBounds.minimum.y)
        #expect(transformed.y <= dab.worldBounds.maximum.y)
    }
}

@Test
func interactionHaloExpandsWorldBoundsConservatively() {
    let material = BrushMaterialInputs(
        accumulation: .flow,
        interaction: .smudge,
        edgeTreatment: .none,
        strength: 1,
        wetness: 0.5,
        bleedRadius: 2,
        accumulationLimit: 1,
        interactionParameters: BrushInteractionDefinition(
            pickup: 0,
            pull: 0,
            dilution: 0,
            charge: 0,
            persistence: 0,
            dirtyHaloRadius: 3
        )
    )
    let dab = logicalDab(ordinal: 0, materialInputs: material)

    #expect(dab.worldBounds.minimum == SIMD2(-4, -4))
    #expect(dab.worldBounds.maximum == SIMD2(4, 4))
}

@Test
func rotationAndReflectionTransformFullStampAndGrainFramesInOrder() throws {
    let brush = Affine2D(
        xAxis: SIMD2(10, 0),
        yAxis: SIMD2(0, 4),
        translation: SIMD2(20, 30)
    )
    let primary = Affine2D(
        xAxis: SIMD2(2, 0),
        yAxis: SIMD2(0, 3),
        translation: SIMD2(5, 7)
    )
    let secondary = Affine2D(
        xAxis: SIMD2(4, 0),
        yAxis: SIMD2(0, 6),
        translation: SIMD2(8, 9)
    )
    let random = BrushLogicalRandomValues(
        compatibility: .centered,
        size: 0.1,
        flow: 0.2,
        opacity: 0.3,
        hardness: 0.4,
        offsetX: 0.5,
        offsetY: 0.6,
        hue: 0.7,
        saturation: 0.8,
        brightness: 0.9,
        secondaryColorMix: 0.25
    )
    let dab = logicalDab(
        ordinal: 0,
        brushToWorld: brush,
        primaryGrainToWorld: primary,
        secondaryGrainToWorld: secondary,
        randomValues: random
    )
    let source = try LogicalDabBatch(
        seed: 9,
        startingOrdinal: 0,
        isPredicted: false,
        dabs: [dab]
    )
    let reflection = Affine2D(
        xAxis: SIMD2(-1, 0),
        yAxis: SIMD2(0, 1),
        translation: .zero
    )
    let frames = LogicalDabTransformer.transform(
        batch: source,
        through: [
            CompiledIsometry(
                ordinal: 7,
                localToCanonical: .identity,
                operation: .identity
            ),
            CompiledIsometry(
                ordinal: 3,
                localToCanonical: reflection,
                operation: CompiledGroupOperation(
                    rotationStep: 0,
                    rotationOrder: 1,
                    reflected: true
                )
            ),
        ]
    )

    #expect(frames.map(\.isometryOrdinal) == [7, 3])
    #expect(frames[0].brushToCanonical == brush)
    #expect(frames[0].primaryGrainToCanonical == primary)
    #expect(frames[0].secondaryGrainToCanonical == secondary)
    #expect(frames[1].brushToCanonical == brush.concatenating(reflection))
    #expect(frames[1].primaryGrainToCanonical == primary.concatenating(reflection))
    #expect(frames[1].secondaryGrainToCanonical == secondary.concatenating(reflection))
    #expect(frames[1].reflected)
    #expect(source.dabs == [dab])
    #expect(source.dabs[0].randomValues == random)
}

@Test
func batchBoundsAreTheExactUnionOfDabBounds() throws {
    let first = logicalDab(
        ordinal: 4,
        brushToWorld: Affine2D(
            xAxis: SIMD2(2, 0),
            yAxis: SIMD2(0, 1),
            translation: SIMD2(-5, 1)
        )
    )
    let second = logicalDab(
        ordinal: 5,
        brushToWorld: Affine2D(
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(0, 3),
            translation: SIMD2(10, 7)
        )
    )
    let batch = try LogicalDabBatch(
        seed: 9,
        startingOrdinal: 4,
        isPredicted: false,
        dabs: [first, second]
    )

    #expect(batch.worldBounds?.minimum == SIMD2(-7, 0))
    #expect(batch.worldBounds?.maximum == SIMD2(11, 10))
}
