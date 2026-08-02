import Foundation

public struct BrushDirectionUpdate: Equatable, Sendable {
    public let direction: Float?
    public let signedTurn: Float?
}

/// Tracks a finite, unwrapped tangent angle along a stabilized world-space path.
public struct BrushDirectionTracker: Equatable, Sendable {
    private static let halfTurnTolerance = Double(Float.pi.ulp) * 8

    private var previousPosition: WorldPoint?
    private var unwrappedDirection: Float?
    private var lastNonzeroTurnSign: Float?

    public init() {}

    public mutating func begin(at position: WorldPoint) {
        precondition(Self.isFinite(position), "Direction input must be finite")
        reset()
        previousPosition = position
    }

    @discardableResult
    public mutating func update(
        to position: WorldPoint
    ) -> BrushDirectionUpdate {
        precondition(Self.isFinite(position), "Direction input must be finite")
        guard let previousPosition else {
            self.previousPosition = position
            return BrushDirectionUpdate(direction: nil, signedTurn: nil)
        }

        let deltaX = Double(position.x) - Double(previousPosition.x)
        let deltaY = Double(position.y) - Double(previousPosition.y)
        self.previousPosition = position

        guard deltaX != 0 || deltaY != 0 else {
            return BrushDirectionUpdate(
                direction: unwrappedDirection,
                signedTurn: nil
            )
        }

        let wrappedDirection = atan2(deltaY, deltaX)
        guard let unwrappedDirection else {
            let initializedDirection = Float(wrappedDirection)
            precondition(
                initializedDirection.isFinite,
                "Direction must remain finite"
            )
            self.unwrappedDirection = initializedDirection
            return BrushDirectionUpdate(
                direction: initializedDirection,
                signedTurn: nil
            )
        }

        var signedTurn = Self.shortestSignedDelta(
            from: Double(unwrappedDirection),
            to: wrappedDirection
        )
        if abs(abs(signedTurn) - Double.pi) <= Self.halfTurnTolerance {
            signedTurn = Double(lastNonzeroTurnSign ?? 1) * Double.pi
        }

        let finiteTurn = Float(signedTurn)
        let nextDirection = unwrappedDirection + finiteTurn
        precondition(
            finiteTurn.isFinite && nextDirection.isFinite,
            "Direction must remain finite"
        )
        if finiteTurn != 0 {
            lastNonzeroTurnSign = finiteTurn.sign == .minus ? -1 : 1
        }
        self.unwrappedDirection = nextDirection
        return BrushDirectionUpdate(
            direction: nextDirection,
            signedTurn: finiteTurn
        )
    }

    public mutating func reset() {
        previousPosition = nil
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
