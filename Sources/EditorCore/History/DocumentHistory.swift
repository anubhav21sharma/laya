import PatternEngine

public enum RasterEditKind: UInt8, Equatable, Sendable {
    case draw
    case erase
    case clear
}

public struct RasterHistoryCommand: Equatable, Sendable {
    public let kind: RasterEditKind
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference

    public init(
        kind: RasterEditKind,
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        precondition(before.pixelSize == after.pixelSize)
        precondition(before.regions == after.regions)
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
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference

    public init(
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        self.before = before
        self.after = after
    }

    public var retainedBytes: Int {
        saturatedSum(before.retainedBytes, after.retainedBytes)
    }
}

public enum DocumentHistoryCommand: Equatable, Sendable {
    case raster(RasterHistoryCommand)
    case tiling(MetadataChange<TilingKind>)
    case tileResize(TileResizeHistoryCommand)

    public var retainedBytes: Int {
        switch self {
        case let .raster(command):
            command.retainedBytes
        case .tiling:
            0
        case let .tileResize(command):
            command.retainedBytes
        }
    }

    public var revisionIDs: Set<StoredRasterRevisionID> {
        switch self {
        case let .raster(command):
            [command.before.id, command.after.id]
        case .tiling:
            []
        case let .tileResize(command):
            [command.before.id, command.after.id]
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

    public init(
        token: UInt64,
        direction: Direction,
        command: DocumentHistoryCommand
    ) {
        self.token = token
        self.direction = direction
        self.command = command
    }
}

public enum DocumentHistoryError: Error, Equatable, Sendable {
    case navigationPending
    case staleNavigationToken
    case negativeRetainedBytes(Int)
    case commandExceedsMaximumBytes(retainedBytes: Int, maximumBytes: Int)
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

    public init(
        maximumCommands: Int = 100,
        maximumBytes: Int = 200 * 1_024 * 1_024
    ) {
        precondition(maximumCommands >= 0)
        precondition(maximumBytes >= 0)
        self.maximumCommands = maximumCommands
        self.maximumBytes = maximumBytes
    }

    public var canUndo: Bool {
        cursor > 0
    }

    public var canRedo: Bool {
        cursor < commands.count
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
            commands.removeFirst()
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
        let navigation = HistoryNavigation(
            token: nextNavigationToken,
            direction: direction,
            command: command
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
}

private func saturatedSum(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}
