import EditorCore
import Foundation
import Testing

@Suite("Layer stack")
struct LayerStackTests {
    @Test
    func operationsKeepStableIdentityAndDeterministicOrder() throws {
        let first = descriptor(1, name: "Ink")
        let second = descriptor(2, name: "Color")
        var stack = try LayerStack(layers: [first], activeLayerID: first.id)

        try stack.add(second, at: 0)
        try stack.rename(first.id, to: "Line art")
        try stack.setVisibility(first.id, isVisible: false)
        try stack.setOpacity(first.id, opacity: 0.625)
        try stack.setLock(first.id, isLocked: true)
        try stack.setBlendMode(first.id, blendMode: .multiply)
        try stack.move(first.id, to: 0)
        try stack.setActiveLayer(second.id)

        #expect(stack.orderedLayerIDs == [first.id, second.id])
        #expect(stack.activeLayerID == second.id)
        #expect(stack.layer(id: first.id) == (try LayerDescriptor(
            id: first.id,
            name: "Line art",
            isVisible: false,
            opacity: 0.625,
            isLocked: true,
            blendMode: .multiply
        )))
    }

    @Test
    func activeDeletionUsesNextThenPreviousFallbackAndCanRestoreExactly()
        throws
    {
        let first = descriptor(1)
        let active = descriptor(2, name: "Active")
        let third = descriptor(3)
        var stack = try LayerStack(
            layers: [first, active, third],
            activeLayerID: active.id
        )

        let removal = try stack.delete(active.id)
        #expect(removal.descriptor == active)
        #expect(removal.order == 1)
        #expect(removal.activeLayerIDBefore == active.id)
        #expect(removal.activeLayerIDAfter == third.id)
        #expect(stack.activeLayerID == third.id)

        try stack.restore(removal)
        #expect(stack.layers == [first, active, third])
        #expect(stack.activeLayerID == active.id)

        _ = try stack.delete(third.id)
        let lastRemoval = try stack.delete(active.id)
        #expect(lastRemoval.activeLayerIDAfter == first.id)
    }

    @Test
    func validationRejectsInvalidStacksWithoutPartialMutation() throws {
        let first = descriptor(1)
        #expect(throws: LayerStackError.emptyStack) {
            _ = try LayerStack(layers: [], activeLayerID: first.id)
        }
        #expect(throws: LayerStackError.duplicateLayerID(first.id)) {
            _ = try LayerStack(
                layers: [first, first],
                activeLayerID: first.id
            )
        }
        #expect(throws: LayerStackError.activeLayerMissing(layerID(9))) {
            _ = try LayerStack(layers: [first], activeLayerID: layerID(9))
        }
        #expect(throws: LayerStackError.invalidName) {
            _ = try LayerDescriptor(id: layerID(8), name: " \n ")
        }
        #expect(throws: LayerStackError.invalidName) {
            _ = try LayerDescriptor(
                id: layerID(8),
                name: String(repeating: "x", count: 257)
            )
        }
        for opacity: Float in [Float.nan, -Float.leastNonzeroMagnitude, 1.0001] {
            #expect(throws: LayerStackError.invalidOpacity) {
                _ = try LayerDescriptor(
                    id: layerID(8),
                    name: "Layer",
                    opacity: opacity
                )
            }
        }

        var stack = try LayerStack(layers: [first], activeLayerID: first.id)
        let before = stack
        #expect(throws: LayerStackError.invalidOrder(2)) {
            try stack.add(descriptor(2), at: 2)
        }
        #expect(stack == before)
        #expect(throws: LayerStackError.cannotDeleteOnlyLayer) {
            _ = try stack.delete(first.id)
        }
        #expect(stack == before)
    }

    @Test
    func maximumEightAndMissingLayerOperationsFailTransactionally() throws {
        let layers = (1...8).map { descriptor($0) }
        var stack = try LayerStack(
            layers: layers,
            activeLayerID: layers[0].id
        )
        let before = stack

        #expect(throws: LayerStackError.maximumLayerCountExceeded(8)) {
            try stack.add(descriptor(9), at: 8)
        }
        #expect(stack == before)
        #expect(throws: LayerStackError.layerMissing(layerID(99))) {
            try stack.move(layerID(99), to: 0)
        }
        #expect(stack == before)
        #expect(throws: LayerStackError.duplicateLayerID(layers[1].id)) {
            try stack.add(layers[1], at: 0)
        }
        #expect(stack == before)
    }

    @Test
    func lockedActiveLayerRejectsRasterMutationUntilUnlocked() throws {
        let first = descriptor(1)
        var stack = try LayerStack(layers: [first], activeLayerID: first.id)
        try stack.setLock(first.id, isLocked: true)

        #expect(throws: LayerStackError.activeLayerLocked(first.id)) {
            _ = try stack.activeLayerForRasterMutation()
        }

        try stack.setLock(first.id, isLocked: false)
        #expect(try stack.activeLayerForRasterMutation().id == first.id)
    }
}

private func descriptor(
    _ value: Int,
    name: String = "Layer"
) -> LayerDescriptor {
    try! LayerDescriptor(id: layerID(value), name: name)
}

private func layerID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "00000000-0000-0000-0000-%012d",
        value
    ))!
}
