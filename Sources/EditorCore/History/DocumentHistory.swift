import Foundation
import PatternEngine

public enum RasterEditKind: UInt8, Equatable, Sendable {
    case draw
    case erase
    case clear
}

public struct RasterHistoryCommand: Equatable, Sendable {
    public let layerID: UUID
    public let kind: RasterEditKind
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference

    public init(
        layerID: UUID,
        kind: RasterEditKind,
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        precondition(before.pixelSize == after.pixelSize)
        precondition(before.regions == after.regions)
        self.layerID = layerID
        self.kind = kind
        self.before = before
        self.after = after
    }

    public var retainedBytes: Int {
        saturatedSum(before.retainedBytes, after.retainedBytes)
    }
}

public struct MetadataChange<Value: Equatable & Sendable>: Equatable, Sendable {
    public let before: Value
    public let after: Value

    public init(before: Value, after: Value) {
        self.before = before
        self.after = after
    }
}

public struct TileResizeHistoryCommand: Equatable, Sendable {
    public let beforePixelSize: PixelSize
    public let afterPixelSize: PixelSize
    public let layerRevision: LayerSurfaceRevisionReference

    public init(
        beforePixelSize: PixelSize,
        afterPixelSize: PixelSize,
        layerRevision: LayerSurfaceRevisionReference
    ) {
        self.beforePixelSize = beforePixelSize
        self.afterPixelSize = afterPixelSize
        self.layerRevision = layerRevision
    }

    public var retainedBytes: Int { layerRevision.retainedBytes }
}

public struct LayerStackSnapshot: Equatable, Sendable {
    public let layers: [LayerDescriptor]
    public let activeLayerID: UUID

    public init(layers: [LayerDescriptor], activeLayerID: UUID) {
        self.layers = layers
        self.activeLayerID = activeLayerID
    }

    public var orderedLayerIDs: [UUID] { layers.map(\.id) }
}

public struct LayerSurfaceRevisionReference: Equatable, Sendable {
    public let id: StoredRasterRevisionID
    public let retainedBytes: Int

    public init(id: StoredRasterRevisionID, retainedBytes: Int) {
        precondition(retainedBytes >= 0)
        self.id = id
        self.retainedBytes = retainedBytes
    }
}

public struct LayerStackMetadataCommand: Equatable, Sendable {
    public let before: LayerStackSnapshot
    public let after: LayerStackSnapshot
    public let layerRevision: LayerSurfaceRevisionReference

    public init(
        before: LayerStackSnapshot,
        after: LayerStackSnapshot,
        layerRevision: LayerSurfaceRevisionReference
    ) {
        self.before = before
        self.after = after
        self.layerRevision = layerRevision
    }
}

public enum LayerDeletionHistoryError: Error, Equatable, Sendable {
    case retainedRevisionMissing(StoredRasterRevisionID)
}

public struct LayerDeletionHistoryCommand: Equatable, Sendable {
    public let removedLayer: LayerDescriptor
    public let removedOrder: Int
    public let activeLayerIDBefore: UUID
    public let activeLayerIDAfter: UUID
    public let layerRevision: LayerSurfaceRevisionReference

    public init(
        removedLayer: LayerDescriptor,
        removedOrder: Int,
        activeLayerIDBefore: UUID,
        activeLayerIDAfter: UUID,
        layerRevision: LayerSurfaceRevisionReference
    ) {
        precondition(removedOrder >= 0)
        self.removedLayer = removedLayer
        self.removedOrder = removedOrder
        self.activeLayerIDBefore = activeLayerIDBefore
        self.activeLayerIDAfter = activeLayerIDAfter
        self.layerRevision = layerRevision
    }

    public init(
        removal: LayerRemoval,
        layerRevision: LayerSurfaceRevisionReference
    ) {
        self.init(
            removedLayer: removal.descriptor,
            removedOrder: removal.order,
            activeLayerIDBefore: removal.activeLayerIDBefore,
            activeLayerIDAfter: removal.activeLayerIDAfter,
            layerRevision: layerRevision
        )
    }

    public func restoreMetadata(
        into stack: inout LayerStack,
        revisionIsAvailable: (StoredRasterRevisionID) -> Bool
    ) throws {
        guard revisionIsAvailable(layerRevision.id) else {
            throw LayerDeletionHistoryError.retainedRevisionMissing(
                layerRevision.id
            )
        }

        var restored = stack
        try restored.restore(
            LayerRemoval(
                descriptor: removedLayer,
                order: removedOrder,
                activeLayerIDBefore: activeLayerIDBefore,
                activeLayerIDAfter: activeLayerIDAfter
            )
        )
        stack = restored
    }

    public var retainedBytes: Int { layerRevision.retainedBytes }
}

public enum DocumentHistoryCommand: Equatable, Sendable {
    case raster(RasterHistoryCommand)
    case tiling(MetadataChange<TilingKind>)
    case periodicConfiguration(
        MetadataChange<PeriodicSymmetryConfiguration>
    )
    case tileResize(TileResizeHistoryCommand)
    case layerMetadata(LayerStackMetadataCommand)
    case layerDeletion(LayerDeletionHistoryCommand)

    public var retainedBytes: Int {
        switch self {
        case let .raster(command):
            command.retainedBytes
        case .tiling, .periodicConfiguration:
            0
        case let .layerMetadata(command):
            command.layerRevision.retainedBytes
        case let .tileResize(command):
            command.retainedBytes
        case let .layerDeletion(command):
            command.retainedBytes
        }
    }

    public var revisionIDs: Set<StoredRasterRevisionID> {
        switch self {
        case let .raster(command):
            [command.before.id, command.after.id]
        case .tiling, .periodicConfiguration:
            []
        case let .layerMetadata(command):
            [command.layerRevision.id]
        case let .tileResize(command):
            [command.layerRevision.id]
        case let .layerDeletion(command):
            [command.layerRevision.id]
        }
    }
}

public struct HistoryNavigation: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case undo
        case redo
    }

    public let token: UInt64
    public let direction: Direction
    public let command: DocumentHistoryCommand
    public let targetDocumentIsEmpty: Bool

    public init(
        token: UInt64,
        direction: Direction,
        command: DocumentHistoryCommand,
        targetDocumentIsEmpty: Bool
    ) {
        self.token = token
        self.direction = direction
        self.command = command
        self.targetDocumentIsEmpty = targetDocumentIsEmpty
    }
}

public enum DocumentHistoryError: Error, Equatable, Sendable {
    case navigationPending
    case staleNavigationToken
    case negativeRetainedBytes(Int)
    case commandExceedsMaximumBytes(retainedBytes: Int, maximumBytes: Int)
}

/// Internal, payload-complete history state used by transaction rollback
/// tests. This deliberately exposes no public diagnostics API.
struct DocumentHistoryDiagnosticSnapshot: Equatable, Sendable {
    let commands: [DocumentHistoryCommand]
    let cursor: Int
    let retainedRasterBytes: Int
    let pendingNavigation: HistoryNavigation?
    let baseDocumentIsEmpty: Bool
    let nextNavigationToken: UInt64
}

public final class DocumentHistory {
    public let maximumCommands: Int
    public let maximumBytes: Int

    public private(set) var commandCount = 0
    public private(set) var retainedRasterBytes = 0

    private var commands: [DocumentHistoryCommand] = []
    private var cursor = 0
    private var pendingNavigation: HistoryNavigation?
    private var nextNavigationToken: UInt64 = 0
    private var baseDocumentIsEmpty: Bool

    public init(
        maximumCommands: Int = 100,
        maximumBytes: Int = 200 * 1_024 * 1_024,
        initialDocumentIsEmpty: Bool = true
    ) {
        precondition(maximumCommands >= 0)
        precondition(maximumBytes >= 0)
        self.maximumCommands = maximumCommands
        self.maximumBytes = maximumBytes
        baseDocumentIsEmpty = initialDocumentIsEmpty
    }

    public var canUndo: Bool {
        cursor > 0
    }

    public var canRedo: Bool {
        cursor < commands.count
    }

    public var currentDocumentIsEmpty: Bool {
        documentIsEmpty(at: cursor)
    }

    func diagnosticSnapshotForTesting() -> DocumentHistoryDiagnosticSnapshot {
        .init(
            commands: commands,
            cursor: cursor,
            retainedRasterBytes: retainedRasterBytes,
            pendingNavigation: pendingNavigation,
            baseDocumentIsEmpty: baseDocumentIsEmpty,
            nextNavigationToken: nextNavigationToken
        )
    }

    public func beginUndo() throws -> HistoryNavigation? {
        try requireNoPendingNavigation()
        guard cursor > 0 else { return nil }

        return beginNavigation(direction: .undo, command: commands[cursor - 1])
    }

    public func beginRedo() throws -> HistoryNavigation? {
        try requireNoPendingNavigation()
        guard cursor < commands.count else { return nil }

        return beginNavigation(direction: .redo, command: commands[cursor])
    }

    public func finishNavigation(token: UInt64, succeeded: Bool) throws {
        guard let navigation = pendingNavigation, navigation.token == token else {
            throw DocumentHistoryError.staleNavigationToken
        }

        pendingNavigation = nil
        guard succeeded else { return }

        switch navigation.direction {
        case .undo:
            cursor -= 1
        case .redo:
            cursor += 1
        }
    }

    public func validateNewCommand(retainedBytes: Int) throws {
        try requireNoPendingNavigation()
        guard retainedBytes >= 0 else {
            throw DocumentHistoryError.negativeRetainedBytes(retainedBytes)
        }
        guard retainedBytes <= maximumBytes else {
            throw DocumentHistoryError.commandExceedsMaximumBytes(
                retainedBytes: retainedBytes,
                maximumBytes: maximumBytes
            )
        }
    }

    /// Removes setup history when an empty document changes storage domain.
    /// The caller releases the returned raster revisions.
    @discardableResult
    public func removeAll() -> Set<StoredRasterRevisionID> {
        precondition(pendingNavigation == nil)
        let released = referencedRevisionIDs
        commands.removeAll(keepingCapacity: true)
        cursor = 0
        commandCount = 0
        retainedRasterBytes = 0
        baseDocumentIsEmpty = true
        return released
    }

    @discardableResult
    public func appendSuccessful(
        _ command: DocumentHistoryCommand
    ) -> Set<StoredRasterRevisionID> {
        precondition(pendingNavigation == nil)
        precondition(command.retainedBytes <= maximumBytes)

        let candidateReleasedIDs = referencedRevisionIDs.union(command.revisionIDs)
        commands.removeSubrange(cursor..<commands.count)
        commands.append(command)
        cursor = commands.count
        updateRetainedRasterBytes()

        while commands.count > maximumCommands || retainedRasterBytes > maximumBytes {
            let removed = commands.removeFirst()
            baseDocumentIsEmpty = documentIsEmpty(
                after: removed,
                startingEmpty: baseDocumentIsEmpty
            )
            cursor -= 1
            updateRetainedRasterBytes()
        }

        commandCount = commands.count
        return candidateReleasedIDs.subtracting(referencedRevisionIDs)
    }

    private var referencedRevisionIDs: Set<StoredRasterRevisionID> {
        commands.reduce(into: []) { ids, command in
            ids.formUnion(command.revisionIDs)
        }
    }

    private func beginNavigation(
        direction: HistoryNavigation.Direction,
        command: DocumentHistoryCommand
    ) -> HistoryNavigation {
        let targetCursor = direction == .undo ? cursor - 1 : cursor + 1
        let navigation = HistoryNavigation(
            token: nextNavigationToken,
            direction: direction,
            command: command,
            targetDocumentIsEmpty: documentIsEmpty(at: targetCursor)
        )
        nextNavigationToken &+= 1
        pendingNavigation = navigation
        return navigation
    }

    private func requireNoPendingNavigation() throws {
        guard pendingNavigation == nil else {
            throw DocumentHistoryError.navigationPending
        }
    }

    private func updateRetainedRasterBytes() {
        retainedRasterBytes = commands.reduce(into: 0) { total, command in
            total = saturatedSum(total, command.retainedBytes)
        }
    }

    private func documentIsEmpty(at cursor: Int) -> Bool {
        precondition((0...commands.count).contains(cursor))
        return commands[..<cursor].reduce(baseDocumentIsEmpty) {
            documentIsEmpty(after: $1, startingEmpty: $0)
        }
    }

    private func documentIsEmpty(
        after command: DocumentHistoryCommand,
        startingEmpty: Bool
    ) -> Bool {
        switch command {
        case let .raster(command):
            switch command.kind {
            case .draw, .erase:
                false
            case .clear:
                true
            }
        case .tiling, .periodicConfiguration, .tileResize,
             .layerMetadata, .layerDeletion:
            startingEmpty
        }
    }
}

private func saturatedSum(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}
