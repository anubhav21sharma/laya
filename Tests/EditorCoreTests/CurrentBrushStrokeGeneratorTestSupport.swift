import PatternEngine

extension BrushStrokeGenerator {
    mutating func currentSampleDabsUnchecked(
        _ sample: WorldStrokeSample
    ) -> [LogicalDab] {
        do {
            return try currentSampleDabs(sample)
        } catch {
            preconditionFailure(
                "Trusted test sample exceeded a current generator bound: \(error)"
            )
        }
    }

    mutating func currentSampleDabs(
        _ sample: WorldStrokeSample
    ) throws -> [LogicalDab] {
        var cursor = try emissionCursor(
            for: sample,
            maximumPathSubdivisionCount: .max
        )
        var dabs: [LogicalDab] = []
        repeat {
            _ = try cursor.emitNextPage { dabs.append($0) }
        } while !cursor.isComplete
        guard let completed = cursor.completedGenerator else {
            preconditionFailure("Completed test cursor has no generator")
        }
        self = completed
        return dabs
    }
}
