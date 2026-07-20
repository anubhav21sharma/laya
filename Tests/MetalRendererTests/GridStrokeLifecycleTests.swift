import MetalRenderer
import PatternEngine
import Testing

@Test
func lifecycleSerializesStrokeAndCommit() throws {
    var lifecycle = GridStrokeLifecycle()
    try lifecycle.begin()
    try lifecycle.requestCommit()
    let token = try lifecycle.markCommitSubmitted()

    #expect(lifecycle.state == .commitPending(token))
    #expect(throws: MetalRendererError.commitPendingInput) {
        try lifecycle.begin()
    }

    try lifecycle.completeCommit(token: token, succeeded: true)
    #expect(lifecycle.state == .idle)
}

@Test
func failedCommitReturnsToIdleWithoutAcceptingScratch() throws {
    var lifecycle = GridStrokeLifecycle()
    try lifecycle.begin()
    try lifecycle.requestCommit()
    let token = try lifecycle.markCommitSubmitted()
    try lifecycle.completeCommit(token: token, succeeded: false)

    #expect(lifecycle.state == .idle)
}

@Test
func cancelOnlyAppliesToAnActiveStroke() throws {
    var lifecycle = GridStrokeLifecycle()
    try lifecycle.begin()
    try lifecycle.cancelActive()

    #expect(lifecycle.state == .idle)
    #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
        try lifecycle.cancelActive()
    }
}

@Test
func tilingChangeSucceedsOnlyWhenIdleAndLeavesPriorTilingOnEveryRejection()
    throws
{
    let idle = GridStrokeLifecycle()
    var idleTiling = TilingKind.grid
    idleTiling = try idle.validatedTilingChange(to: .mirrorXY)
    #expect(idleTiling == .mirrorXY)

    var active = GridStrokeLifecycle()
    try active.begin()
    var activeTiling = TilingKind.grid
    #expect(throws: MetalRendererError.tilingChangeRequiresIdle) {
        activeTiling = try active.validatedTilingChange(to: .halfDrop)
    }
    #expect(activeTiling == .grid)

    var requested = GridStrokeLifecycle()
    try requested.begin()
    try requested.requestCommit()
    var requestedTiling = TilingKind.grid
    #expect(throws: MetalRendererError.tilingChangeRequiresIdle) {
        requestedTiling = try requested.validatedTilingChange(to: .brick)
    }
    #expect(requestedTiling == .grid)

    var pending = requested
    _ = try pending.markCommitSubmitted()
    var pendingTiling = TilingKind.grid
    #expect(throws: MetalRendererError.tilingChangeRequiresIdle) {
        pendingTiling = try pending.validatedTilingChange(to: .rotational)
    }
    #expect(pendingTiling == .grid)
}
