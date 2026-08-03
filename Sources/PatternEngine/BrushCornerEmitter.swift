import Foundation

public enum BrushCornerEmitterError: Error, Equatable, Sendable {
    case invalidMaximumAngularStep
    case invalidSignedTurn
    case invalidStartingDirection
    case canonicalKeyOverflow
    case capacityExceeded(
        requiredCandidateCount: Int,
        maximumCandidateCount: Int
    )
    case cornerSequenceOverflow
}

struct BrushCornerEmissionStep: Equatable, Sendable {
    let candidate: StrokeEmissionCandidate
    let continuation: BrushCornerEmissionCursor
}

/// Arithmetic cursor for one corner fan. It keeps a single vertex candidate
/// instead of materializing the maximum 32 fully attributed orientations.
struct BrushCornerEmissionCursor: Equatable, Sendable {
    private let startingDirection: Float
    private let signedTurn: Float
    private let gapCount: Int
    private let vertex: StrokeEmissionCandidate
    private let firstSequence: UInt64
    private var intermediateIndex: Int

    fileprivate init(
        startingDirection: Float,
        signedTurn: Float,
        gapCount: Int,
        vertex: StrokeEmissionCandidate,
        firstSequence: UInt64
    ) {
        self.startingDirection = startingDirection
        self.signedTurn = signedTurn
        self.gapCount = gapCount
        self.vertex = vertex
        self.firstSequence = firstSequence
        intermediateIndex = 1
    }

    var isComplete: Bool { intermediateIndex >= gapCount }

    var remainingCandidateCount: Int {
        max(0, gapCount - intermediateIndex)
    }

    func nextCandidate() -> BrushCornerEmissionStep? {
        guard !isComplete else { return nil }
        let fraction = Float(intermediateIndex) / Float(gapCount)
        let candidate = vertex.cornerCandidate(
            direction: startingDirection + signedTurn * fraction,
            sequence: firstSequence + UInt64(intermediateIndex - 1)
        )
        var continuation = self
        continuation.intermediateIndex += 1
        return BrushCornerEmissionStep(
            candidate: candidate,
            continuation: continuation
        )
    }
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
        let originalSequence = nextCornerSequence
        guard var cursor = try cursor(
            from: startingDirection,
            signedTurn: signedTurn,
            vertex: vertex,
            nextCornerSequence: &nextCornerSequence
        ) else { return }
        guard output.count <= StrokeEmissionCandidateBuffer.maximumCount
                - cursor.remainingCandidateCount
        else {
            nextCornerSequence = originalSequence
            throw BrushCornerEmitterError.capacityExceeded(
                requiredCandidateCount:
                    output.count + cursor.remainingCandidateCount,
                maximumCandidateCount:
                    StrokeEmissionCandidateBuffer.maximumCount
            )
        }
        while let step = cursor.nextCandidate() {
            output.append(step.candidate)
            cursor = step.continuation
        }
    }

    func cursor(
        from startingDirection: Float,
        signedTurn: Float,
        vertex: StrokeEmissionCandidate,
        nextCornerSequence: inout UInt64
    ) throws -> BrushCornerEmissionCursor? {
        guard signedTurn.isFinite, abs(signedTurn) <= .pi else {
            throw BrushCornerEmitterError.invalidSignedTurn
        }
        guard startingDirection.isFinite else {
            throw BrushCornerEmitterError.invalidStartingDirection
        }
        let turnMagnitude = abs(signedTurn)
        guard turnMagnitude > maximumAngularStep else {
            return nil
        }

        let gapCount = Int(
            ceil(Double(turnMagnitude) / Double(maximumAngularStep))
        )
        let requiredCandidateCount = gapCount - 1
        guard requiredCandidateCount > 0 else {
            return nil
        }
        guard
            requiredCandidateCount <= StrokeEmissionCandidateBuffer.maximumCount
        else {
            throw BrushCornerEmitterError.capacityExceeded(
                requiredCandidateCount: requiredCandidateCount,
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
        let cursor = BrushCornerEmissionCursor(
            startingDirection: startingDirection,
            signedTurn: signedTurn,
            gapCount: gapCount,
            vertex: vertex,
            firstSequence: nextCornerSequence
        )
        nextCornerSequence += UInt64(requiredCandidateCount)
        return cursor
    }
}
