@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Deposition contracts")
struct DepositionContractsTests {
    @Test
    func abiVersionIsPinned() {
        #expect(DepositionABI.version == 1)
    }

    @Test
    func frameBudgetRejectsNonpositiveValues() {
        #expect(throws: DepositionFrameBudgetError.nonpositive(
            "cpuPreparationNanoseconds"
        )) {
            _ = try budget(cpuPreparationNanoseconds: 0)
        }
        #expect(throws: DepositionFrameBudgetError.nonpositive(
            "maximumAuthoritativeInstances"
        )) {
            _ = try budget(maximumAuthoritativeInstances: 0)
        }
        #expect(throws: DepositionFrameBudgetError.nonpositive(
            "maximumPredictedInstances"
        )) {
            _ = try budget(maximumPredictedInstances: -1)
        }
        #expect(throws: DepositionFrameBudgetError.nonpositive(
            "maximumPendingAuthoritativeInstances"
        )) {
            _ = try budget(maximumPendingAuthoritativeInstances: 0)
        }
        #expect(throws: DepositionFrameBudgetError.nonpositive(
            "maximumPendingPredictedInstances"
        )) {
            _ = try budget(maximumPendingPredictedInstances: -1)
        }
    }

    @Test
    func frameBudgetRejectsPerFrameCapacityAbovePendingCapacity() {
        #expect(throws: DepositionFrameBudgetError.perFrameExceedsPending(
            "maximumAuthoritativeInstances"
        )) {
            _ = try budget(
                maximumAuthoritativeInstances: 9,
                maximumPendingAuthoritativeInstances: 8
            )
        }
        #expect(throws: DepositionFrameBudgetError.perFrameExceedsPending(
            "maximumPredictedInstances"
        )) {
            _ = try budget(
                maximumPredictedInstances: 9,
                maximumPendingPredictedInstances: 8
            )
        }
    }

    @Test
    func frameBudgetRejectsInvalidInFlightUploadBufferCount() {
        for count in [0, 9] {
            #expect(
                throws:
                    DepositionFrameBudgetError
                        .invalidInFlightUploadBufferCount
            ) {
                _ = try budget(inFlightUploadBufferCount: count)
            }
        }
    }

    @Test
    func frameBudgetPreservesValidatedValues() throws {
        let value = try budget()

        #expect(value.cpuPreparationNanoseconds == 1_500_000)
        #expect(value.maximumAuthoritativeInstances == 4_096)
        #expect(value.maximumPredictedInstances == 2_048)
        #expect(value.maximumPendingAuthoritativeInstances == 12_288)
        #expect(value.maximumPendingPredictedInstances == 4_096)
        #expect(value.inFlightUploadBufferCount == 3)
    }

    @Test
    func renderIdentityRequiresCanonicalSHA256() throws {
        #expect(throws: BrushRenderIdentityError.emptyDefinitionID) {
            _ = try BrushRenderIdentity(
                definitionID: BrushRecipeID(""),
                semanticHash: String(repeating: "a", count: 64)
            )
        }

        for hash in [
            "",
            "not-a-hash",
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ] {
            #expect(throws: BrushRenderIdentityError.invalidSemanticHash) {
                _ = try BrushRenderIdentity(
                    definitionID: BrushRecipeID("native.ink"),
                    semanticHash: hash
                )
            }
        }

        let valid = try BrushRenderIdentity(
            definitionID: BrushRecipeID("native.ink"),
            semanticHash: String(repeating: "0f", count: 32)
        )
        #expect(valid.definitionID == BrushRecipeID("native.ink"))
        #expect(valid.semanticHash == String(repeating: "0f", count: 32))
    }

    private func budget(
        cpuPreparationNanoseconds: UInt64 = 1_500_000,
        maximumAuthoritativeInstances: Int = 4_096,
        maximumPredictedInstances: Int = 2_048,
        maximumPendingAuthoritativeInstances: Int = 12_288,
        maximumPendingPredictedInstances: Int = 4_096,
        inFlightUploadBufferCount: Int = 3
    ) throws -> DepositionFrameBudget {
        try DepositionFrameBudget(
            cpuPreparationNanoseconds: cpuPreparationNanoseconds,
            maximumAuthoritativeInstances: maximumAuthoritativeInstances,
            maximumPredictedInstances: maximumPredictedInstances,
            maximumPendingAuthoritativeInstances:
                maximumPendingAuthoritativeInstances,
            maximumPendingPredictedInstances:
                maximumPendingPredictedInstances,
            inFlightUploadBufferCount: inFlightUploadBufferCount
        )
    }
}
