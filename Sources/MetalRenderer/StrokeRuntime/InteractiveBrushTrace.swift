import Foundation

public struct StrokeTraceIdentity: Hashable, Codable, Sendable {
    public let strokeGeneration: UInt64
    public let authoritativeSequence: UInt64
    public let sampleSequence: UInt64
    public let provenance: StrokeTraceProvenance

    public init(
        strokeGeneration: UInt64,
        authoritativeSequence: UInt64,
        sampleSequence: UInt64,
        provenance: StrokeTraceProvenance
    ) {
        self.strokeGeneration = strokeGeneration
        self.authoritativeSequence = authoritativeSequence
        self.sampleSequence = sampleSequence
        self.provenance = provenance
    }
}

public enum StrokeTraceProvenance: String, Codable, Sendable {
    case authoritative
    case coalesced
    case predicted
}

public enum InteractiveBrushTraceStage: String, Codable, Sendable {
    case eventReceived
    case workerDequeued
    case dabPrepared
    case transientCacheSubmitted
    case transientCacheCompleted
    case drawableSubmitted
    case drawablePresented
    case settled
    case progress
    case failure
}

public struct InteractiveBrushTraceRecord: Codable, Sendable {
    public let schemaVersion: UInt32
    public let stage: InteractiveBrushTraceStage
    public let identity: StrokeTraceIdentity?
    public let monotonicNanoseconds: UInt64
    public let documentGeneration: UInt64?
    public let canonicalRevision: UInt64?
    public let transientRevision: UInt64?
    public let presentationRevision: UInt64?
    public let authoritativeBacklog: Int
    public let dirtyTileCount: Int
    public let residentBytes: Int
    public let activeOwnershipCount: Int
    public let message: String?

    public init(
        schemaVersion: UInt32 = 1,
        stage: InteractiveBrushTraceStage,
        identity: StrokeTraceIdentity? = nil,
        monotonicNanoseconds: UInt64,
        documentGeneration: UInt64? = nil,
        canonicalRevision: UInt64? = nil,
        transientRevision: UInt64? = nil,
        presentationRevision: UInt64? = nil,
        authoritativeBacklog: Int = 0,
        dirtyTileCount: Int = 0,
        residentBytes: Int = 0,
        activeOwnershipCount: Int = 0,
        message: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.stage = stage
        self.identity = identity
        self.monotonicNanoseconds = monotonicNanoseconds
        self.documentGeneration = documentGeneration
        self.canonicalRevision = canonicalRevision
        self.transientRevision = transientRevision
        self.presentationRevision = presentationRevision
        self.authoritativeBacklog = authoritativeBacklog
        self.dirtyTileCount = dirtyTileCount
        self.residentBytes = residentBytes
        self.activeOwnershipCount = activeOwnershipCount
        self.message = message
    }
}

public protocol InteractiveBrushTraceSink: Sendable {
    func record(_ record: InteractiveBrushTraceRecord)
}

struct InteractiveBrushInputTrace: Equatable, Sendable {
    let identity: StrokeTraceIdentity?
    let eventReceiptMonotonicNanoseconds: UInt64?
}

struct StrokeInputEnvelope: Equatable, Sendable {
    let message: StrokeInputMessage
    let traceLineage: [InteractiveBrushInputTrace]
}
