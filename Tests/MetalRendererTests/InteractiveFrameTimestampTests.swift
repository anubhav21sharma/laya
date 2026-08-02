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
#endif
