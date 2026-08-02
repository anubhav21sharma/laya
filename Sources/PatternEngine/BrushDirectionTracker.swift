import Foundation

public enum BrushDirectionTrackerError: Error, Equatable, Sendable {
    case invalidPosition
}

public struct BrushDirectionUpdate: Equatable, Sendable {
    public let direction: Float?
    public let signedTurn: Float?
}

/// Tracks a finite, unwrapped tangent angle along a stabilized world-space path.
public struct BrushDirectionTracker: Equatable, Sendable {
    private static let halfTurnTolerance = Double(Float.pi.ulp) * 8

    private var previousPosition: WorldPoint?
    private var previousWrappedDirection: Double?
    private var unwrappedDirection: Double?
    private var lastNonzeroTurnSign: Float?

    public init() {}

    public mutating func begin(at position: WorldPoint) throws {
        guard Self.isFinite(position) else {
            throw BrushDirectionTrackerError.invalidPosition
        }
        reset()
        previousPosition = position
    }

    @discardableResult
    public mutating func update(
        to position: WorldPoint
    ) throws -> BrushDirectionUpdate {
        guard Self.isFinite(position) else {
            throw BrushDirectionTrackerError.invalidPosition
        }
        guard let previousPosition else {
            self.previousPosition = position
            return BrushDirectionUpdate(direction: nil, signedTurn: nil)
        }

        let deltaX = Double(position.x) - Double(previousPosition.x)
        let deltaY = Double(position.y) - Double(previousPosition.y)
        self.previousPosition = position

        guard deltaX != 0 || deltaY != 0 else {
            return BrushDirectionUpdate(
                direction: unwrappedDirection.map(Float.init),
                signedTurn: nil
            )
        }

        let wrappedDirection = atan2(deltaY, deltaX)
        guard let unwrappedDirection else {
            previousWrappedDirection = wrappedDirection
            self.unwrappedDirection = wrappedDirection
            return BrushDirectionUpdate(
                direction: Float(wrappedDirection),
                signedTurn: nil
            )
        }

        var signedTurn = Self.shortestSignedDelta(
            from: previousWrappedDirection!,
            to: wrappedDirection
        )
        if abs(abs(signedTurn) - Double.pi) <= Self.halfTurnTolerance {
            signedTurn = Double(lastNonzeroTurnSign ?? 1) * Double.pi
        }

        let nextDirection = unwrappedDirection + signedTurn
        precondition(
            signedTurn.isFinite && nextDirection.isFinite,
            "Direction must remain finite"
        )
        if signedTurn != 0 {
            lastNonzeroTurnSign = signedTurn.sign == .minus ? -1 : 1
        }
        previousWrappedDirection = wrappedDirection
        self.unwrappedDirection = nextDirection
        return BrushDirectionUpdate(
            direction: Float(nextDirection),
            signedTurn: Float(signedTurn)
        )
    }

    public mutating func reset() {
        previousPosition = nil
        previousWrappedDirection = nil
        unwrappedDirection = nil
        lastNonzeroTurnSign = nil
    }

    private static func isFinite(_ point: WorldPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func shortestSignedDelta(
        from start: Double,
        to end: Double
    ) -> Double {
        let fullTurn = 2 * Double.pi
        var delta = (end - start).truncatingRemainder(
            dividingBy: fullTurn
        )
        if delta >= Double.pi {
            delta -= fullTurn
        }
        if delta < -Double.pi {
            delta += fullTurn
        }
        return delta
    }
}
