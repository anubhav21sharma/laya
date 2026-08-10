import Foundation
import EditorCore
import PatternEngine

public struct RendererOperationToken:
    RawRepresentable, Hashable, Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct RasterMutationReceipt: Equatable, Sendable {
    public let token: RendererOperationToken
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference
    public let layerID: UUID?
    public let generation: UInt64?
    public let tileCoordinates: [RasterRevisionTileCoordinate]

    public init(
        token: RendererOperationToken,
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        precondition(
            before.layerID == after.layerID,
            "A raster mutation pair cannot cross layer storage."
        )
        self.token = token
        self.before = before
        self.after = after
        layerID = before.layerID
        generation = before.generation == after.generation
            ? before.generation
            : nil
        tileCoordinates = Array(Set(
            before.tileCoordinates + after.tileCoordinates
        )).sorted()
    }
}

public struct LayerGeometryMutationReceipt: Equatable, Sendable {
    public let token: RendererOperationToken
    public let beforePixelSize: PixelSize
    public let afterPixelSize: PixelSize
    public let revision: LayerSurfaceRevisionReference

    public init(
        token: RendererOperationToken,
        beforePixelSize: PixelSize,
        afterPixelSize: PixelSize,
        revision: LayerSurfaceRevisionReference
    ) {
        self.token = token
        self.beforePixelSize = beforePixelSize
        self.afterPixelSize = afterPixelSize
        self.revision = revision
    }
}

public enum RendererOperationCompletion: Sendable {
    case rasterSuccess(RasterMutationReceipt)
    case layerGeometrySuccess(LayerGeometryMutationReceipt)
    case operationSuccess(RendererOperationToken)
    case failure(RendererOperationToken, MetalRendererError)
}

struct RendererRasterSubmissionOutcome: Sendable {
    let submissionID: UInt64
    let token: RendererOperationToken
    let succeeded: Bool
    let errorMessage: String?
}

final class RendererRasterCompletionMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [RendererRasterSubmissionOutcome] = []

    func push(_ outcome: RendererRasterSubmissionOutcome) {
        lock.lock()
        outcomes.append(outcome)
        lock.unlock()
    }

    @MainActor
    func drain() -> [RendererRasterSubmissionOutcome] {
        lock.lock()
        let drained = outcomes
        outcomes.removeAll(keepingCapacity: true)
        lock.unlock()
        return drained
    }
}
