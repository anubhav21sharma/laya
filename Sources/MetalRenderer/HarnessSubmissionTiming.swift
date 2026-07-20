import Foundation

enum HarnessSubmissionTiming {
    static func measureThroughSubmission(
        since start: CFAbsoluteTime,
        submit: () -> Void,
        now: () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    ) -> Double {
        submit()
        return max(0, (now() - start) * 1_000)
    }

    static func eventToSubmitMilliseconds(
        eventProcessingMilliseconds: Double,
        flushThroughSubmissionMilliseconds: Double
    ) -> Double {
        eventProcessingMilliseconds + flushThroughSubmissionMilliseconds
    }
}
