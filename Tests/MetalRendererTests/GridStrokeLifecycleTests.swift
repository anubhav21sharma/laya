import MetalRenderer
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
