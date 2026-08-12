import CShaderTypes
import MetalRenderer
import PatternEngine
import simd

struct DepositionCoverageSamples: Equatable, Sendable {
    let primaryShape: Float
    let secondaryShape: Float?
    let primaryGrain: Float?
    let secondaryGrain: Float?
    let signedTipEdgeDistance: Float
}

struct DepositionReferenceMaterial: Equatable, Sendable {
    let secondaryShapeCombination: BrushShapeCombinationMode?
    let primaryGrainStrength: Float?
    let secondaryGrainStrength: Float?
    let tipThreshold: Float
    let antialiasing: Bool
    let accumulationMode: BrushAccumulationMode
    let edgeTreatment: BrushEdgeTreatment
    let materialStrength: Float
    let accumulationLimit: Float
}

enum DepositionReference {
    /// One normalized 8-bit channel step. The production shader uses this
    /// same stable threshold width so CPU/GPU fixtures do not depend on a
    /// device-specific derivative approximation.
    static let antialiasWidth: Float = 1 / 255

    static func coverage(
        samples: DepositionCoverageSamples,
        instance: PatternDepositionStampInstance,
        material: DepositionReferenceMaterial
    ) -> Float {
        guard inputsAreFinite(
            samples: samples,
            instance: instance,
            material: material
        ) else {
            return 0
        }

        var shape = clamp01(samples.primaryShape)
        if let combination = material.secondaryShapeCombination,
           let secondary = samples.secondaryShape {
            shape = combineShapes(
                primary: shape,
                secondary: clamp01(secondary),
                mode: combination
            )
        }

        let hardness = clamp01(instance.coverageInputs.z)
        shape = clamp01(
            (shape - (1 - hardness))
                / max(hardness, antialiasWidth)
        )
        shape = thresholdedShape(
            shape,
            threshold: clamp01(material.tipThreshold),
            antialiasing: material.antialiasing
        )

        var grain = Float(1)
        if let sample = samples.primaryGrain,
           let strength = material.primaryGrainStrength {
            grain *= mix(
                from: 1,
                to: clamp01(sample),
                fraction: clamp01(strength)
            )
        }
        if let sample = samples.secondaryGrain,
           let strength = material.secondaryGrainStrength {
            grain *= mix(
                from: 1,
                to: clamp01(sample),
                fraction: clamp01(strength)
            )
        }

        var evaluated = shape * clamp01(grain)
        evaluated = applyEdgeTreatment(
            to: evaluated,
            grainSample: combinedRawGrain(samples),
            signedTipEdgeDistance: samples.signedTipEdgeDistance,
            hardness: hardness,
            treatment: material.edgeTreatment,
            strength: clamp01(material.materialStrength)
        )

        // materialContribution is already the evaluated per-dab strength,
        // including deterministic material dynamics. Multiplying the static
        // definition strength again would square that setting.
        let base = evaluated
            * clamp01(instance.coverageInputs.x)
            * clamp01(instance.coverageInputs.w)
        return clamp01(base)
    }

    static func accumulateAlpha(
        current: Float,
        baseCoverage: Float,
        flowCoverage: Float,
        mode: BrushAccumulationMode,
        accumulationLimit: Float
    ) -> Float {
        guard current.isFinite,
              baseCoverage.isFinite,
              flowCoverage.isFinite,
              accumulationLimit.isFinite
        else {
            return 0
        }

        let limit = clamp01(accumulationLimit)
        let current = min(limit, clamp01(current))
        let base = clamp01(baseCoverage)
        let flow = clamp01(flowCoverage)
        let next: Float
        switch mode {
        case .opaque:
            next = current + (1 - current) * base
        case .flow:
            next = current + (1 - current) * flow
        case .uniformGlaze:
            next = max(current, flow)
        case .intenseGlaze:
            let intense = 1 - (1 - flow) * (1 - flow)
            next = current + (1 - current) * intense
        case .destinationOut:
            next = current + (1 - current) * flow
        }
        return min(limit, clamp01(next))
    }

    static func destinationOut(
        destinationPremultiplied: SIMD4<Float>,
        eraseCoverage: Float,
        strokeOpacity: Float
    ) -> SIMD4<Float> {
        guard destinationPremultiplied.x.isFinite,
              destinationPremultiplied.y.isFinite,
              destinationPremultiplied.z.isFinite,
              destinationPremultiplied.w.isFinite,
              eraseCoverage.isFinite,
              strokeOpacity.isFinite
        else {
            return .zero
        }

        let retained = 1
            - clamp01(eraseCoverage) * clamp01(strokeOpacity)
        return destinationPremultiplied * retained
    }

    private static func combineShapes(
        primary: Float,
        secondary: Float,
        mode: BrushShapeCombinationMode
    ) -> Float {
        switch mode {
        case .replace:
            secondary
        case .multiply:
            primary * secondary
        case .minimum:
            min(primary, secondary)
        case .maximum:
            max(primary, secondary)
        }
    }

    private static func thresholdedShape(
        _ shape: Float,
        threshold: Float,
        antialiasing: Bool
    ) -> Float {
        guard threshold > 0 else { return shape }
        if antialiasing {
            return shape * smoothstep(
                edge0: threshold - antialiasWidth,
                edge1: threshold + antialiasWidth,
                value: shape
            )
        }
        return shape >= threshold ? shape : 0
    }

    private static func applyEdgeTreatment(
        to coverage: Float,
        grainSample: Float,
        signedTipEdgeDistance: Float,
        hardness: Float,
        treatment: BrushEdgeTreatment,
        strength: Float
    ) -> Float {
        let edgeBand = 1 - smoothstep(
            edge0: 0,
            edge1: 1,
            value: abs(signedTipEdgeDistance)
        )
        switch treatment {
        case .none:
            return coverage
        case .dryBreakup:
            let breakupThreshold = clamp01(
                (1 - hardness) * 0.35 + edgeBand * 0.35
            )
            let dryMask = smoothstep(
                edge0: breakupThreshold,
                edge1: min(1, breakupThreshold + 0.25),
                value: grainSample
            )
            return coverage * mix(
                from: 1,
                to: dryMask,
                fraction: strength
            )
        case .markerOverlap:
            return clamp01(
                coverage * (1 + 0.25 * strength * edgeBand)
            )
        case .wetConcentration:
            // Stage 4 compilation rejects this mode. Fail closed if an
            // invalid binding nevertheless reaches the reference boundary.
            return 0
        }
    }

    private static func combinedRawGrain(
        _ samples: DepositionCoverageSamples
    ) -> Float {
        clamp01(
            (samples.primaryGrain ?? 1)
                * (samples.secondaryGrain ?? 1)
        )
    }

    private static func inputsAreFinite(
        samples: DepositionCoverageSamples,
        instance: PatternDepositionStampInstance,
        material: DepositionReferenceMaterial
    ) -> Bool {
        let sampleValues = [
            samples.primaryShape,
            samples.secondaryShape,
            samples.primaryGrain,
            samples.secondaryGrain,
            samples.signedTipEdgeDistance,
        ]
        let materialValues = [
            material.primaryGrainStrength,
            material.secondaryGrainStrength,
            material.tipThreshold,
            material.materialStrength,
            material.accumulationLimit,
        ]
        return sampleValues.allSatisfy { $0?.isFinite != false }
            && materialValues.allSatisfy { $0?.isFinite != false }
            && instance.coverageInputs.x.isFinite
            && instance.coverageInputs.y.isFinite
            && instance.coverageInputs.z.isFinite
            && instance.coverageInputs.w.isFinite
    }

    private static func smoothstep(
        edge0: Float,
        edge1: Float,
        value: Float
    ) -> Float {
        guard edge1 > edge0 else {
            return value >= edge1 ? 1 : 0
        }
        let fraction = clamp01((value - edge0) / (edge1 - edge0))
        return fraction * fraction * (3 - 2 * fraction)
    }

    private static func mix(
        from start: Float,
        to end: Float,
        fraction: Float
    ) -> Float {
        start + (end - start) * fraction
    }

    private static func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}
