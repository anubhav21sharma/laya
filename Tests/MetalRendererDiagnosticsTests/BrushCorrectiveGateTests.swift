import Foundation
@testable import MetalRendererDiagnostics
import Testing

@Suite("Brush corrective evidence gate")
struct BrushCorrectiveGateTests {
    @Test
    func matrixNamesAndCategoriesAreExactAndStable() {
        #expect(BrushCorrectiveGate.positiveSceneNames == [
            "professional-chisel-marker",
            "professional-graphite-pencil",
            "professional-natural-charcoal",
            "professional-technical-ink",
        ])
        #expect(BrushCorrectiveGate.negativeSceneNames
            == BrushCorrectiveGate.positiveSceneNames.map {
                "\($0)-negative-control"
            })
        #expect(BrushCorrectiveGateCategory.allCases.map(\.rawValue) == [
            "boundedResources",
            "cursorSupport",
            "determinism",
            "historyParity",
            "inputPath",
            "visibleOutput",
        ])
    }

    @Test
    func everyNegativeControlCategoryFailsIndependently() throws {
        let passing = Dictionary(uniqueKeysWithValues:
            BrushCorrectiveGateCategory.allCases.map { ($0, true) })
        try BrushCorrectiveGate.validateCategoryControls(passing)

        for category in BrushCorrectiveGateCategory.allCases {
            var negative = passing
            negative[category] = false
            #expect(
                throws: BrushCorrectiveGateError.failedCategory(category)
            ) {
                try BrushCorrectiveGate.validateCategoryControls(negative)
            }
        }
    }

    @Test
    func missingOrUnknownCategorySetsAreRejectedBeforeEvaluation() {
        #expect(throws: BrushCorrectiveGateError.invalidCategorySet) {
            try BrushCorrectiveGate.validateCategoryControls([:])
        }
    }
}
