import Foundation

public enum BrushCornerEmitterError: Error, Equatable, Sendable {
    case invalidMaximumAngularStep
    case invalidSignedTurn
    case capacityExceeded(
        requiredCandidateCount: Int,
        maximumCandidateCount: Int
    )
    case cornerSequenceOverflow
}

/// Builds a bounded, allocation-free orientation fan at one path vertex.
public struct BrushCornerEmitter: Equatable, Sendable {
    public static let minimumAngularStep = Float.pi / 180

    public let maximumAngularStep: Float

    public init(maximumAngularStep: Float) throws {
        guard
            maximumAngularStep.isFinite,
            maximumAngularStep >= Self.minimumAngularStep,
            maximumAngularStep <= .pi
        else {
            throw BrushCornerEmitterError.invalidMaximumAngularStep
        }
        self.maximumAngularStep = maximumAngularStep
    }

    public func emit(
        from startingDirection: Float,
        signedTurn: Float,
        vertex: StrokeEmissionCandidate,
        into output: inout StrokeEmissionCandidateBuffer,
        nextCornerSequence: inout UInt64
    ) throws {
        guard signedTurn.isFinite, abs(signedTurn) <= .pi else {
            throw BrushCornerEmitterError.invalidSignedTurn
        }
        precondition(
            startingDirection.isFinite,
            "Corner direction must be finite"
        )
        let turnMagnitude = abs(signedTurn)
        guard turnMagnitude > maximumAngularStep else {
            return
        }

        let gapRatio = Double(turnMagnitude) / Double(maximumAngularStep)
        let nearestGapCount = gapRatio.rounded()
        let ratioTolerance = Double(Float.ulpOfOne) * 8 * max(1, gapRatio)
        let gapCount = Int(
            abs(gapRatio - nearestGapCount) <= ratioTolerance
                ? nearestGapCount
                : ceil(gapRatio)
        )
        let requiredCandidateCount = gapCount - 1
        guard
            requiredCandidateCount <= StrokeEmissionCandidateBuffer.maximumCount,
            output.count <= StrokeEmissionCandidateBuffer.maximumCount
                - requiredCandidateCount
        else {
            throw BrushCornerEmitterError.capacityExceeded(
                requiredCandidateCount: output.count + requiredCandidateCount,
                maximumCandidateCount:
                    StrokeEmissionCandidateBuffer.maximumCount
            )
        }
        guard
            UInt64(requiredCandidateCount)
                <= UInt64.max - nextCornerSequence
        else {
            throw BrushCornerEmitterError.cornerSequenceOverflow
        }

        for intermediateIndex in 1...requiredCandidateCount {
            let fraction = Float(intermediateIndex) / Float(gapCount)
            let direction = startingDirection + signedTurn * fraction
            output.append(
                vertex.cornerCandidate(
                    direction: direction,
                    sequence: nextCornerSequence
                )
            )
            nextCornerSequence += 1
        }
    }
}
