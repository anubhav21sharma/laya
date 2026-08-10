import PatternEngine

public enum DepositionABI {
    public static let version: UInt16 = 2
}

public enum DepositionFrameBudgetError: Error, Equatable, Sendable {
    case nonpositive(String)
    case perFrameExceedsPending(String)
    case invalidInFlightUploadBufferCount
}

public struct DepositionFrameBudget: Equatable, Sendable {
    public let cpuPreparationNanoseconds: UInt64
    public let maximumAuthoritativeInstances: Int
    public let maximumPredictedInstances: Int
    public let maximumPendingAuthoritativeInstances: Int
    public let maximumPendingPredictedInstances: Int
    public let inFlightUploadBufferCount: Int

    public init(
        cpuPreparationNanoseconds: UInt64,
        maximumAuthoritativeInstances: Int,
        maximumPredictedInstances: Int,
        maximumPendingAuthoritativeInstances: Int,
        maximumPendingPredictedInstances: Int,
        inFlightUploadBufferCount: Int
    ) throws {
        guard cpuPreparationNanoseconds > 0 else {
            throw DepositionFrameBudgetError.nonpositive(
                "cpuPreparationNanoseconds"
            )
        }
        for (name, value) in [
            (
                "maximumAuthoritativeInstances",
                maximumAuthoritativeInstances
            ),
            ("maximumPredictedInstances", maximumPredictedInstances),
            (
                "maximumPendingAuthoritativeInstances",
                maximumPendingAuthoritativeInstances
            ),
            (
                "maximumPendingPredictedInstances",
                maximumPendingPredictedInstances
            ),
        ] {
            guard value > 0 else {
                throw DepositionFrameBudgetError.nonpositive(name)
            }
        }
        guard maximumAuthoritativeInstances
            <= maximumPendingAuthoritativeInstances
        else {
            throw DepositionFrameBudgetError.perFrameExceedsPending(
                "maximumAuthoritativeInstances"
            )
        }
        guard maximumPredictedInstances
            <= maximumPendingPredictedInstances
        else {
            throw DepositionFrameBudgetError.perFrameExceedsPending(
                "maximumPredictedInstances"
            )
        }
        guard (1...8).contains(inFlightUploadBufferCount) else {
            throw DepositionFrameBudgetError
                .invalidInFlightUploadBufferCount
        }

        self.cpuPreparationNanoseconds = cpuPreparationNanoseconds
        self.maximumAuthoritativeInstances = maximumAuthoritativeInstances
        self.maximumPredictedInstances = maximumPredictedInstances
        self.maximumPendingAuthoritativeInstances =
            maximumPendingAuthoritativeInstances
        self.maximumPendingPredictedInstances =
            maximumPendingPredictedInstances
        self.inFlightUploadBufferCount = inFlightUploadBufferCount
    }
}

public enum DepositionPreparationError: Error, Equatable, Sendable {
    case unsupportedInteraction(BrushInteractionMode)
    case unsupportedEdgeTreatment(BrushEdgeTreatment)
    case missingRequiredResource(String)
    case pipelinePreparationFailed(String)
}
