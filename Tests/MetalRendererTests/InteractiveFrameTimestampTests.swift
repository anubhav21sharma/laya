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
#endif
