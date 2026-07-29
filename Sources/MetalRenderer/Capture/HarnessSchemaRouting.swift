public enum HarnessRunnerKind: Equatable, Sendable {
    case foundation
    case sliceThree
    case deposition
}

public enum HarnessSchemaRoutingError: Error, Equatable, Sendable {
    case unsupportedActiveSchema(Int)
}

public enum HarnessSchemaRouting {
    public static func runnerKind(
        for schemaVersion: Int
    ) throws -> HarnessRunnerKind {
        switch schemaVersion {
        case 1...3:
            .foundation
        case 4:
            .sliceThree
        case 6:
            .deposition
        default:
            throw HarnessSchemaRoutingError.unsupportedActiveSchema(
                schemaVersion
            )
        }
    }
}
