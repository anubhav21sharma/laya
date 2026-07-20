import PatternEngine

public struct GridStrokeLifecycle: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case active
        case commitRequested
        case commitPending(UInt64)
    }

    public private(set) var state: State = .idle
    private var nextCommitToken: UInt64 = 1

    public init() {}

    public mutating func begin() throws {
        guard state == .idle else {
            if state == .commitRequested {
                throw MetalRendererError.commitPendingInput
            }
            if case .commitPending = state {
                throw MetalRendererError.commitPendingInput
            }
            throw MetalRendererError.invalidStrokeLifecycle
        }
        state = .active
    }

    public mutating func requestCommit() throws {
        guard state == .active else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        state = .commitRequested
    }

    public mutating func markCommitSubmitted() throws -> UInt64 {
        guard state == .commitRequested else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let token = nextCommitToken
        nextCommitToken &+= 1
        state = .commitPending(token)
        return token
    }

    public mutating func completeCommit(
        token: UInt64,
        succeeded: Bool
    ) throws {
        guard state == .commitPending(token) else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        state = .idle
    }

    public mutating func cancelActive() throws {
        guard state == .active else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        state = .idle
    }

    public mutating func resetTransiently() {
        state = .idle
    }

    public func validatedTilingChange(
        to candidate: TilingKind
    ) throws -> TilingKind {
        guard state == .idle else {
            throw MetalRendererError.tilingChangeRequiresIdle
        }
        return candidate
    }
}
