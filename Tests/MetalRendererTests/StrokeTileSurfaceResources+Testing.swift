import Foundation
import Metal
import PatternEngine
@testable import MetalRenderer

extension StrokeTileSurfaceResources {
    @MainActor
    convenience init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        store: PaintTileStore,
        layerID: UUID,
        pixelSize: PixelSize,
        generation: UInt64,
        maximumRecordCount: Int,
        maximumTileReferenceCount: Int,
        namespaceLease: StrokeTileSurfaceNamespaceLease
    ) throws {
        guard namespaceLease.authoritativeSurfaceID
                != namespaceLease.predictionSurfaceID
        else {
            throw StrokeTileSurfaceError.duplicateSurfaceNamespace(
                namespaceLease.authoritativeSurfaceID
            )
        }
        guard namespaceLease.isStandaloneTestOnly
                || namespaceLease.isAuthenticated(
                    storeIdentity: store.identity,
                    layerID: layerID,
                    generation: generation
                )
        else {
            throw StrokeTileSurfaceError.unauthenticatedSurfaceNamespace
        }
        let boundNamespace: StrokeTileSurfaceNamespaceLease
        if namespaceLease.storeIdentity == store.identity,
           namespaceLease.layerID == layerID,
           namespaceLease.generation == generation {
            boundNamespace = namespaceLease
        } else {
            boundNamespace = .testing(
                storeIdentity: store.identity,
                layerID: layerID,
                generation: generation,
                authoritativeSurfaceID:
                    namespaceLease.authoritativeSurfaceID,
                predictionSurfaceID: namespaceLease.predictionSurfaceID
            )
            namespaceLease.cancel()
        }
        try self.init(
            device: device,
            commandQueue: commandQueue,
            capability: try .testing(
                store: store,
                pixelSize: pixelSize,
                generation: generation,
                namespaceLease: boundNamespace
            ),
            maximumRecordCount: maximumRecordCount,
            maximumTileReferenceCount: maximumTileReferenceCount
        )
    }

    @MainActor
    convenience init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        byteBudget: Int,
        layerID: UUID,
        pixelSize: PixelSize,
        generation: UInt64,
        maximumRecordCount: Int,
        maximumTileReferenceCount: Int
    ) throws {
        try self.init(
            device: device,
            commandQueue: commandQueue,
            capability: try .testing(
                store: PaintTileStore(device: device, byteBudget: byteBudget),
                layerID: layerID,
                pixelSize: pixelSize,
                generation: generation
            ),
            maximumRecordCount: maximumRecordCount,
            maximumTileReferenceCount: maximumTileReferenceCount
        )
    }
}
