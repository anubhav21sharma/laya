import Foundation
@testable import MetalRenderer
import Testing

@Test
func harnessSubmissionTimingStopsOnlyAfterSubmission() {
    var order: [String] = []
    let milliseconds = HarnessSubmissionTiming.measureThroughSubmission(
        since: 10,
        submit: { order.append("submit") },
        now: {
            order.append("stop")
            return 10.002
        }
    )

    #expect(order == ["submit", "stop"])
    #expect(abs(milliseconds - 2) < 0.000_001)
}

@Test
func eventToSubmitSpanIncludesEventProcessingAndFlushSubmission() {
    #expect(
        HarnessSubmissionTiming.eventToSubmitMilliseconds(
            eventProcessingMilliseconds: 1.25,
            flushThroughSubmissionMilliseconds: 2.5
        ) == 3.75
    )
}
