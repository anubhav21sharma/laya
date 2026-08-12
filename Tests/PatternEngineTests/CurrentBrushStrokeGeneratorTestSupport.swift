@testable import PatternEngine

extension BrushStrokeGenerator {
    mutating func consumeCurrentSample(
        _ sample: WorldStrokeSample,
        emit: (LogicalDab) -> Void
    ) {
        do {
            try consumeCurrentSample(
                sample,
                maximumPathSubdivisionCount: .max,
                emit: emit
            )
        } catch {
            preconditionFailure(
                "Trusted test sample exceeded a current generator bound: \(error)"
            )
        }
    }

    mutating func consumeCurrentSample(
        _ sample: WorldStrokeSample,
        emit: (LogicalDab) throws -> Void
    ) throws {
        try consumeCurrentSample(
            sample,
            maximumPathSubdivisionCount: .max,
            emit: emit
        )
    }

    mutating func consumeCurrentSample(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int,
        emit: (LogicalDab) throws -> Void
    ) throws {
        var cursor = try emissionCursor(
            for: sample,
            maximumPathSubdivisionCount: maximumPathSubdivisionCount
        )
        repeat {
            _ = try cursor.emitNextPageDeciding { dab in
                try emit(dab)
                return .accept
            }
        } while !cursor.isComplete
        guard let completed = cursor.completedGenerator else {
            preconditionFailure("Completed test cursor has no generator")
        }
        self = completed
    }

    mutating func currentSampleDabs(
        _ sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int = .max
    ) throws -> [LogicalDab] {
        var dabs: [LogicalDab] = []
        try consumeCurrentSample(
            sample,
            maximumPathSubdivisionCount: maximumPathSubdivisionCount
        ) { dabs.append($0) }
        return dabs
    }
}
