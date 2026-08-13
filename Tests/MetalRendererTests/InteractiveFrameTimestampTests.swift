#if DEBUG && os(macOS)
@testable import MetalRenderer
import Testing

@Test
func interactiveFrameTimestampFallsBackWhenDrawableTimeIsUnavailable() {
    #expect(
        GridRenderer.interactivePresentationTimestamp(
            presentedTime: 0,
            fallback: 42
        ) == 42
    )
    #expect(
        GridRenderer.interactivePresentationTimestamp(
            presentedTime: .nan,
            fallback: 43
        ) == 43
    )
    #expect(
        GridRenderer.interactivePresentationTimestamp(
            presentedTime: 12.5,
            fallback: 44
        ) == 12.5
    )
}

@Test
func interactiveFrameDemandRequiresAtLeastOneLiveReason() {
    #expect(
        !GridRenderer.interactiveFrameDemand(
            hasActiveStroke: false,
            isViewportAnimating: false,
            hasPendingComposite: false,
            isHUDSamplePending: false
        )
    )
    #expect(
        GridRenderer.interactiveFrameDemand(
            hasActiveStroke: true,
            isViewportAnimating: false,
            hasPendingComposite: false,
            isHUDSamplePending: false
        )
    )
    #expect(
        GridRenderer.interactiveFrameDemand(
            hasActiveStroke: false,
            isViewportAnimating: true,
            hasPendingComposite: false,
            isHUDSamplePending: false
        )
    )
    #expect(
        GridRenderer.interactiveFrameDemand(
            hasActiveStroke: false,
            isViewportAnimating: false,
            hasPendingComposite: true,
            isHUDSamplePending: false
        )
    )
    #expect(
        GridRenderer.interactiveFrameDemand(
            hasActiveStroke: false,
            isViewportAnimating: false,
            hasPendingComposite: false,
            isHUDSamplePending: true
        )
    )
}

@Test
func activeUnpresentedRevisionRequestsAnotherPausedViewFrame() {
    var pump = InteractiveFramePump()
    let revision = CanvasPresentationRevision(sequence: 7)

    pump.signal(.cachePublished(revision))

    let begun = pump.beginFrame()
    let shouldContinue = pump.finishFrame(.submitted(revision))
    #expect(begun == revision)
    #expect(shouldContinue)
    #expect(pump.hasDemand)
    let afterPresentation = pump.markPresented(revision)
    #expect(!afterPresentation)
    #expect(!pump.hasDemand)
}

@Test
func missingDrawableRetainsTheActiveRevisionDemand() {
    var pump = InteractiveFramePump()
    let revision = CanvasPresentationRevision(sequence: 11)
    pump.signal(.drawableChanged(revision))

    let begun = pump.beginFrame()
    let shouldContinue = pump.finishFrame(.drawableUnavailable(revision))
    #expect(begun == revision)
    #expect(shouldContinue)
    #expect(pump.hasDemand)
    let retried = pump.beginFrame()
    #expect(retried == revision)
}

@Test
func presentingAnOlderRevisionDoesNotSettleTheNewestDemand() {
    var pump = InteractiveFramePump()
    let older = CanvasPresentationRevision(sequence: 2)
    let newest = CanvasPresentationRevision(sequence: 3)
    pump.signal(.cachePublished(older))
    pump.signal(.viewportChanged(newest))

    let begun = pump.beginFrame()
    let afterSubmission = pump.finishFrame(.submitted(newest))
    let afterOlderPresentation = pump.markPresented(older)
    #expect(begun == newest)
    #expect(afterSubmission)
    #expect(afterOlderPresentation)
    #expect(pump.hasDemand)
    let afterNewestPresentation = pump.markPresented(newest)
    #expect(!afterNewestPresentation)
    #expect(!pump.hasDemand)
}

@Test
func terminalFailureSettlesDemandWhenNoNewerRevisionExists() {
    var pump = InteractiveFramePump()
    let revision = CanvasPresentationRevision(sequence: 19)
    pump.signal(.cachePublished(revision))

    let begun = pump.beginFrame()
    let afterFailure = pump.finishFrame(.failed(revision, "encode failed"))
    #expect(begun == revision)
    #expect(!afterFailure)
    #expect(!pump.hasDemand)
    let idle = pump.beginFrame()
    #expect(idle == nil)
}

@Test
func demandSignalledDuringAFrameSurvivesItsSubmissionAndPresentation() {
    var pump = InteractiveFramePump()
    let revision = CanvasPresentationRevision(sequence: 23)
    pump.signal(.cachePublished(revision))
    _ = pump.beginFrame()

    pump.signal(.input)

    let afterSubmission = pump.finishFrame(.submitted(revision))
    let afterPresentation = pump.markPresented(revision)
    #expect(afterSubmission)
    #expect(afterPresentation)
    #expect(pump.hasDemand)
}

@Test
func terminalPreparationFailureSettlesOnlyDemandObservedAtItsStart() {
    var pump = InteractiveFramePump()
    let failed = CanvasPresentationRevision(sequence: 29)
    let newer = CanvasPresentationRevision(sequence: 30)
    pump.signal(.cachePublished(failed))
    let checkpoint = pump.demandCheckpoint

    let afterExactFailure = pump.settleTerminalFailure(
        upTo: failed,
        since: checkpoint
    )
    #expect(!afterExactFailure)
    #expect(!pump.hasDemand)

    pump.signal(.cachePublished(failed))
    let olderCheckpoint = pump.demandCheckpoint
    pump.signal(.viewportChanged(newer))
    pump.signal(.input)

    let afterSupersededFailure = pump.settleTerminalFailure(
        upTo: failed,
        since: olderCheckpoint
    )
    #expect(afterSupersededFailure)
    #expect(pump.hasDemand)
    #expect(pump.beginFrame() == newer)
}
#endif
