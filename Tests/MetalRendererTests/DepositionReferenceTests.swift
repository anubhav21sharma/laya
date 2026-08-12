import CShaderTypes
@testable import MetalRenderer
@testable import MetalRendererDiagnostics
import PatternEngine
import Testing

@Suite("Deposition CPU reference")
struct DepositionReferenceTests {
    @Test(
        "Secondary shape combinations use their declared operation",
        arguments: [
            (BrushShapeCombinationMode.replace, Float(0.25)),
            (.multiply, 0.2),
            (.minimum, 0.25),
            (.maximum, 0.8),
        ]
    )
    func combinesSecondaryShape(
        mode: BrushShapeCombinationMode,
        expected: Float
    ) {
        let actual = DepositionReference.coverage(
            samples: samples(primaryShape: 0.8, secondaryShape: 0.25),
            instance: instance(),
            material: material(secondaryShapeCombination: mode)
        )

        #expect(actual.isApproximatelyEqual(to: expected))
    }

    @Test(
        "Zero, one, and two grain layers honor declared strength",
        arguments: [
            (
                DepositionCoverageSamples(
                    primaryShape: 1,
                    secondaryShape: nil,
                    primaryGrain: nil,
                    secondaryGrain: nil,
                    signedTipEdgeDistance: 2
                ),
                DepositionReferenceMaterial(
                    secondaryShapeCombination: nil,
                    primaryGrainStrength: nil,
                    secondaryGrainStrength: nil,
                    tipThreshold: 0,
                    antialiasing: true,
                    accumulationMode: .flow,
                    edgeTreatment: .none,
                    materialStrength: 1,
                    accumulationLimit: 1
                ),
                Float(1)
            ),
            (
                DepositionCoverageSamples(
                    primaryShape: 1,
                    secondaryShape: nil,
                    primaryGrain: 0.2,
                    secondaryGrain: nil,
                    signedTipEdgeDistance: 2
                ),
                DepositionReferenceMaterial(
                    secondaryShapeCombination: nil,
                    primaryGrainStrength: 0.5,
                    secondaryGrainStrength: nil,
                    tipThreshold: 0,
                    antialiasing: true,
                    accumulationMode: .flow,
                    edgeTreatment: .none,
                    materialStrength: 1,
                    accumulationLimit: 1
                ),
                Float(0.6)
            ),
            (
                DepositionCoverageSamples(
                    primaryShape: 1,
                    secondaryShape: nil,
                    primaryGrain: 0.2,
                    secondaryGrain: 0.5,
                    signedTipEdgeDistance: 2
                ),
                DepositionReferenceMaterial(
                    secondaryShapeCombination: nil,
                    primaryGrainStrength: 0.5,
                    secondaryGrainStrength: 0.25,
                    tipThreshold: 0,
                    antialiasing: true,
                    accumulationMode: .flow,
                    edgeTreatment: .none,
                    materialStrength: 1,
                    accumulationLimit: 1
                ),
                Float(0.525)
            ),
        ]
    )
    func combinesGrains(
        samples: DepositionCoverageSamples,
        material: DepositionReferenceMaterial,
        expected: Float
    ) {
        let actual = DepositionReference.coverage(
            samples: samples,
            instance: instance(),
            material: material
        )

        #expect(actual.isApproximatelyEqual(to: expected))
    }

    @Test(
        "Hardness remaps sampled shape coverage",
        arguments: [
            (Float(0), Float(0)),
            (0.5, 0.5),
            (1, 0.75),
        ]
    )
    func hardness(hardness: Float, expected: Float) {
        let actual = DepositionReference.coverage(
            samples: samples(primaryShape: 0.75),
            instance: instance(hardness: hardness),
            material: material()
        )

        #expect(actual.isApproximatelyEqual(to: expected))
    }

    @Test
    func tipThresholdCanBeHardOrAntialiased() {
        let hard = DepositionReference.coverage(
            samples: samples(primaryShape: 0.49),
            instance: instance(),
            material: material(tipThreshold: 0.5, antialiasing: false)
        )
        let hardAtThreshold = DepositionReference.coverage(
            samples: samples(primaryShape: 0.5),
            instance: instance(),
            material: material(tipThreshold: 0.5, antialiasing: false)
        )
        let antialiasedAtThreshold = DepositionReference.coverage(
            samples: samples(primaryShape: 0.5),
            instance: instance(),
            material: material(tipThreshold: 0.5, antialiasing: true)
        )

        #expect(hard == 0)
        #expect(hardAtThreshold == 0.5)
        #expect(
            antialiasedAtThreshold.isApproximatelyEqual(to: 0.25)
        )
    }

    @Test
    func dryBreakupIsDeterministicAndStrongerAtTheTipEdge() {
        let dry = material(edgeTreatment: .dryBreakup)
        let edgeSamples = samples(
            primaryShape: 1,
            primaryGrain: 0.5,
            signedTipEdgeDistance: 0
        )
        let bodySamples = samples(
            primaryShape: 1,
            primaryGrain: 0.5,
            signedTipEdgeDistance: 2
        )

        let first = DepositionReference.coverage(
            samples: edgeSamples,
            instance: instance(hardness: 0.5),
            material: dry
        )
        let second = DepositionReference.coverage(
            samples: edgeSamples,
            instance: instance(hardness: 0.5),
            material: dry
        )
        let body = DepositionReference.coverage(
            samples: bodySamples,
            instance: instance(hardness: 0.5),
            material: dry
        )

        #expect(first.bitPattern == second.bitPattern)
        #expect(first < body)
    }

    @Test
    func markerPreservesBodyAndAddsBoundedEdgeDensity() {
        let marker = material(
            edgeTreatment: .markerOverlap,
            materialStrength: 1,
            accumulationLimit: 0.7
        )
        let body = DepositionReference.coverage(
            samples: samples(
                primaryShape: 0.4,
                signedTipEdgeDistance: 2
            ),
            instance: instance(),
            material: marker
        )
        let edge = DepositionReference.coverage(
            samples: samples(
                primaryShape: 0.4,
                signedTipEdgeDistance: 0
            ),
            instance: instance(),
            material: marker
        )

        #expect(body.isApproximatelyEqual(to: 0.4))
        #expect(edge > body)
        #expect(edge <= 0.7)
    }

    @Test(
        "Accumulation modes use the approved equations",
        arguments: [
            (BrushAccumulationMode.opaque, Float(0.6)),
            (.flow, 0.4),
            (.uniformGlaze, 0.25),
            (.intenseGlaze, 0.55),
            (.destinationOut, 0.4),
        ]
    )
    func accumulation(mode: BrushAccumulationMode, expected: Float) {
        let actual = DepositionReference.accumulateAlpha(
            current: 0.2,
            baseCoverage: 0.5,
            flowCoverage: 0.25,
            mode: mode,
            accumulationLimit: 1
        )

        #expect(actual.isApproximatelyEqual(to: expected))
    }

    @Test
    func repeatedDabsRespectModeAndAccumulationLimit() {
        let flow = repeatedAlpha(
            mode: .flow,
            coverage: 0.25,
            accumulationLimit: 1,
            count: 3
        )
        let uniform = repeatedAlpha(
            mode: .uniformGlaze,
            coverage: 0.25,
            accumulationLimit: 1,
            count: 3
        )
        let limited = repeatedAlpha(
            mode: .intenseGlaze,
            coverage: 0.5,
            accumulationLimit: 0.6,
            count: 8
        )

        #expect(flow.isApproximatelyEqual(to: 0.578125))
        #expect(uniform == 0.25)
        #expect(limited == 0.6)
    }

    @Test
    func accumulationLimitDoesNotAttenuateFlowBeforeAccumulation() {
        let base = DepositionReference.coverage(
            samples: samples(primaryShape: 1),
            instance: instance(),
            material: material(accumulationLimit: 0.5)
        )
        let next = DepositionReference.accumulateAlpha(
            current: 0,
            baseCoverage: base,
            flowCoverage: base * 0.1,
            mode: .flow,
            accumulationLimit: 0.5
        )

        #expect(base == 1)
        #expect(next.isApproximatelyEqual(to: 0.1))
    }

    @Test
    func destinationOutScalesPremultipliedRGBAndAlphaTogether() {
        let destination = SIMD4<Float>(0.4, 0.2, 0.1, 0.5)

        let erased = DepositionReference.destinationOut(
            destinationPremultiplied: destination,
            eraseCoverage: 0.5,
            strokeOpacity: 0.5
        )

        #expect(erased.isApproximatelyEqual(
            to: SIMD4(0.3, 0.15, 0.075, 0.375)
        ))
    }

    @Test
    func eraseEquationHasNoBrushColorInput() {
        let erase = material(accumulationMode: .destinationOut)
        let red = DepositionReference.coverage(
            samples: samples(primaryShape: 0.75),
            instance: instance(
                premultipliedColor: SIMD4(1, 0, 0, 1)
            ),
            material: erase
        )
        let blue = DepositionReference.coverage(
            samples: samples(primaryShape: 0.75),
            instance: instance(
                premultipliedColor: SIMD4(0, 0, 1, 1)
            ),
            material: erase
        )

        #expect(red == blue)
    }

    @Test
    func invalidSamplesFailClosedAndBoundaryValuesClamp() {
        let invalid = DepositionReference.coverage(
            samples: samples(primaryShape: .nan),
            instance: instance(),
            material: material()
        )
        let clamped = DepositionReference.coverage(
            samples: samples(
                primaryShape: 2,
                primaryGrain: -1
            ),
            instance: instance(opacity: 2, materialContribution: 2),
            material: material(primaryGrainStrength: 2)
        )
        let invalidAccumulation = DepositionReference.accumulateAlpha(
            current: .nan,
            baseCoverage: 1,
            flowCoverage: 1,
            mode: .flow,
            accumulationLimit: 1
        )

        #expect(invalid == 0)
        #expect(clamped == 0)
        #expect(invalidAccumulation == 0)
    }

    private func repeatedAlpha(
        mode: BrushAccumulationMode,
        coverage: Float,
        accumulationLimit: Float,
        count: Int
    ) -> Float {
        (0..<count).reduce(Float.zero) { current, _ in
            DepositionReference.accumulateAlpha(
                current: current,
                baseCoverage: coverage,
                flowCoverage: coverage,
                mode: mode,
                accumulationLimit: accumulationLimit
            )
        }
    }

    private func samples(
        primaryShape: Float,
        secondaryShape: Float? = nil,
        primaryGrain: Float? = nil,
        secondaryGrain: Float? = nil,
        signedTipEdgeDistance: Float = 2
    ) -> DepositionCoverageSamples {
        DepositionCoverageSamples(
            primaryShape: primaryShape,
            secondaryShape: secondaryShape,
            primaryGrain: primaryGrain,
            secondaryGrain: secondaryGrain,
            signedTipEdgeDistance: signedTipEdgeDistance
        )
    }

    private func material(
        secondaryShapeCombination: BrushShapeCombinationMode? = nil,
        primaryGrainStrength: Float? = nil,
        secondaryGrainStrength: Float? = nil,
        tipThreshold: Float = 0,
        antialiasing: Bool = true,
        accumulationMode: BrushAccumulationMode = .flow,
        edgeTreatment: BrushEdgeTreatment = .none,
        materialStrength: Float = 1,
        accumulationLimit: Float = 1
    ) -> DepositionReferenceMaterial {
        DepositionReferenceMaterial(
            secondaryShapeCombination: secondaryShapeCombination,
            primaryGrainStrength: primaryGrainStrength,
            secondaryGrainStrength: secondaryGrainStrength,
            tipThreshold: tipThreshold,
            antialiasing: antialiasing,
            accumulationMode: accumulationMode,
            edgeTreatment: edgeTreatment,
            materialStrength: materialStrength,
            accumulationLimit: accumulationLimit
        )
    }

    private func instance(
        opacity: Float = 1,
        flow: Float = 1,
        hardness: Float = 1,
        materialContribution: Float = 1,
        premultipliedColor: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    ) -> PatternDepositionStampInstance {
        PatternDepositionStampInstance(
            tipFrame0: .zero,
            tipFrame1: SIMD4(0, 0, 1, 0),
            primaryGrainFrame0: .zero,
            primaryGrainFrame1: .zero,
            secondaryGrainFrame0: .zero,
            secondaryGrainFrame1: .zero,
            premultipliedColor: premultipliedColor,
            coverageInputs: SIMD4(
                opacity,
                flow,
                hardness,
                materialContribution
            ),
            clip0: zeroClip,
            clip1: zeroClip,
            clip2: zeroClip,
            clip3: zeroClip,
            identity: .zero,
            metadata: SIMD4(0, 0, 0, UInt32(DepositionABI.version)),
            reserved0: .zero,
            reserved1: .zero
        )
    }

    private var zeroClip: PatternClipHalfPlane {
        PatternClipHalfPlane(normal: .zero, offset: 0, padding: 0)
    }
}

private extension Float {
    func isApproximatelyEqual(
        to other: Float,
        tolerance: Float = 1e-6
    ) -> Bool {
        abs(self - other) <= tolerance
    }
}

private extension SIMD4 where Scalar == Float {
    func isApproximatelyEqual(
        to other: SIMD4<Float>,
        tolerance: Float = 1e-6
    ) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(z - other.z) <= tolerance
            && abs(w - other.w) <= tolerance
    }
}
