package struct CanvasPresentationRevision:
    Equatable,
    Comparable,
    Hashable,
    Sendable
{
    package let sequence: UInt64

    package init(sequence: UInt64) {
        self.sequence = sequence
    }

    package static func < (
        lhs: CanvasPresentationRevision,
        rhs: CanvasPresentationRevision
    ) -> Bool {
        lhs.sequence < rhs.sequence
    }
}

enum InteractiveFrameDemand: Equatable, Sendable {
    case input
    case cachePublished(CanvasPresentationRevision)
    case viewportChanged(CanvasPresentationRevision)
    case drawableChanged(CanvasPresentationRevision)
    case telemetry
}

enum InteractiveFrameOutcome: Equatable, Sendable {
    case submitted(CanvasPresentationRevision)
    case superseded(CanvasPresentationRevision)
    case drawableUnavailable(CanvasPresentationRevision?)
    case noCompatibleSnapshot(CanvasPresentationRevision?)
    case failed(CanvasPresentationRevision?, String)
}

struct InteractiveFramePump: Sendable {
    private var latestDemandedRevision: CanvasPresentationRevision?
    private var hasUnrevisionedDemand = false
    private var demandEpoch: UInt64 = 0
    private var frameIsActive = false
    private var activeFrameRevision: CanvasPresentationRevision?
    private var activeFrameDemandEpoch: UInt64 = 0

    var hasDemand: Bool {
        hasUnrevisionedDemand || latestDemandedRevision != nil
    }

    mutating func signal(_ demand: InteractiveFrameDemand) {
        demandEpoch &+= 1
        switch demand {
        case .input, .telemetry:
            hasUnrevisionedDemand = true
        case let .cachePublished(revision),
             let .viewportChanged(revision),
             let .drawableChanged(revision):
            if latestDemandedRevision.map({ $0 < revision }) ?? true {
                latestDemandedRevision = revision
            }
        }
    }

    mutating func beginFrame() -> CanvasPresentationRevision? {
        frameIsActive = true
        activeFrameRevision = latestDemandedRevision
        activeFrameDemandEpoch = demandEpoch
        return activeFrameRevision
    }

    mutating func finishFrame(_ outcome: InteractiveFrameOutcome) -> Bool {
        guard frameIsActive else { return hasDemand }
        let receivedNewerDemand = activeFrameDemandEpoch != demandEpoch
        frameIsActive = false
        activeFrameRevision = nil
        switch outcome {
        case .submitted:
            if !receivedNewerDemand { hasUnrevisionedDemand = false }
        case .superseded:
            break
        case .drawableUnavailable, .noCompatibleSnapshot:
            break
        case let .failed(revision, _):
            if !receivedNewerDemand { hasUnrevisionedDemand = false }
            if !receivedNewerDemand,
               revision == nil || latestDemandedRevision == revision
            {
                latestDemandedRevision = nil
            }
        }
        return hasDemand
    }

    mutating func markPresented(
        _ revision: CanvasPresentationRevision
    ) -> Bool {
        if let latestDemandedRevision,
           latestDemandedRevision <= revision
        {
            self.latestDemandedRevision = nil
        }
        return hasDemand
    }
}
