import Foundation

public enum HarnessSubmissionTiming {
    public static func measureThroughSubmission(
        since start: CFAbsoluteTime,
        submit: () -> Void,
        now: () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    ) -> Double {
        submit()
        return max(0, (now() - start) * 1_000)
    }

    public static func eventToSubmitMilliseconds(
        eventProcessingMilliseconds: Double,
        flushThroughSubmissionMilliseconds: Double
    ) -> Double {
        eventProcessingMilliseconds + flushThroughSubmissionMilliseconds
    }
}
