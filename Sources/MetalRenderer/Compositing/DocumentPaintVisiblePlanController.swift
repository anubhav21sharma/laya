import Foundation
@preconcurrency import Metal

enum DocumentPaintVisiblePlanControllerError: Error, Equatable, Sendable {
    case foreignRequest
    case staleRequest
    case foreignPreparedPlan
    case stalePreparedPlan
    case noCurrentPlan
    case currentPlanNotPresentable
    case foreignSubmission
    case submissionAlreadyConsumed
    case submissionRevoked
    case staleSubmission
    case preparationBackpressure(capacity: Int)
    case retirementBackpressure(capacity: Int)
    case shuttingDown
    case identityOverflow
    case transientSourceNotAvailable
}

struct DocumentPaintVisiblePlanSpecification: Equatable, Sendable {
    let key: SparseTileSamplingPlanKey
    let outputRegion: SparseTileOutputRegion

    var documentGeneration: UInt64 { key.documentGeneration }
    var addressingGeneration: UInt64 { key.addressingRevision }
    var outputGeneration: UInt64 { key.outputGeometryRevision }
}

struct DocumentPaintVisiblePlanRequestToken: Sendable {
    fileprivate let ownerIdentity: UUID
    fileprivate let sequence: UInt64
    fileprivate let specification: DocumentPaintVisiblePlanSpecification
}

struct DocumentPaintPreparedVisiblePlanToken: Sendable {
    fileprivate let ownerIdentity: UUID
    fileprivate let sequence: UInt64
}

struct DocumentPaintInstalledVisiblePlanToken: Sendable {
    fileprivate let ownerIdentity: UUID
    fileprivate let planIdentity: UUID
    let specification: DocumentPaintVisiblePlanSpecification
}

enum DocumentPaintRenderContextShutdownReason: Sendable {
    case applicationShutdown
    case sessionReplacement
}

struct DocumentPaintRenderContextShutdownSnapshot: Equatable, Sendable {
    let isComplete: Bool
    let ownedPlanReservationCount: Int
    let preparedSubmissionCount: Int
    let submittedSubmissionCount: Int
    let retiringPlanCount: Int
    let pendingP4CompletionCount: Int
}

actor DocumentPaintPreparationTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }

    func close() {
        precondition(waiters.isEmpty)
        isOpen = false
    }

    var waitingCount: Int { waiters.count }
}

#if DEBUG
final class DocumentPaintPreparedCoreRevocationRaceGate: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let revocationPaused: Bool
        let coreDeinitEntered: Bool
    }

    private let condition = NSCondition()
    private var revocationPaused = false
    private var coreDeinitEntered = false
    private var revocationReleased = false

    fileprivate func pauseRevocation() {
        condition.lock()
        revocationPaused = true
        condition.broadcast()
        while !revocationReleased { condition.wait() }
        condition.unlock()
    }

    fileprivate func recordCoreDeinitEntry() {
        condition.lock()
        coreDeinitEntered = true
        condition.broadcast()
        condition.unlock()
    }

    func releaseRevocation() {
        condition.lock()
        revocationReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return Snapshot(
            revocationPaused: revocationPaused,
            coreDeinitEntered: coreDeinitEntered
        )
    }
}
#endif

final class DocumentPaintVisiblePlanFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var retirementFailures: Int

    init(retirementFailures: Int = 0) {
        self.retirementFailures = retirementFailures
    }

    func consumeRetirementFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard retirementFailures > 0 else { return false }
        retirementFailures -= 1
        return true
    }
}

struct DocumentPaintVisiblePlanControllerConfiguration: @unchecked Sendable {
    var maximumPreparedSubmissions = 3
    var maximumOwnedPlans = 8
    var planBuildGate: DocumentPaintPreparationTestGate?
    var preparationGate: DocumentPaintPreparationTestGate?
    var failureInjector: DocumentPaintVisiblePlanFailureInjector?
    var preparedAbandonmentFailureInjector:
        SparseTileSamplingPreparedAbandonmentFailureInjector?
    #if DEBUG
    var preparedCoreRevocationRaceGate:
        DocumentPaintPreparedCoreRevocationRaceGate?
    #endif
    var injectEarlyTerminalNotification = false
    var injectDuplicateTerminalNotification = false
    var forceTerminalFailure = false

    static let production = Self()
}

private final class DocumentPaintWeakSubmissionCore: @unchecked Sendable {
    weak var value: DocumentPaintPreparedDisplaySubmissionCore?
    init(_ value: DocumentPaintPreparedDisplaySubmissionCore) {
        self.value = value
    }
}

private final class DocumentPaintSubmissionCompletionMailbox: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let sequence: UInt64
        let secret: UUID
    }

    struct Reservation: Sendable {
        let key: Key
    }

    struct ObligationSettlementEvent: Sendable {
        let sequence: UInt64
        let planIdentity: UUID
        let closesTransientPlan: Bool
    }

    struct RecordSnapshot: Equatable, @unchecked Sendable {
        let sequence: UInt64
        let planIdentity: UUID
        let specification: DocumentPaintVisiblePlanSpecification
        let isReserved: Bool
        let isSubmitted: Bool
        let resources: SparseTileSamplingPreparedResourceIdentity?
    }

    struct Snapshot: Equatable, @unchecked Sendable {
        let capacity: Int
        let reservationCount: Int
        let preparedCount: Int
        let submittedCount: Int
        let terminalEventCount: Int
        let completedCount: UInt64
        let failedCount: UInt64
        let ignoredEarlyCount: UInt64
        let ignoredDuplicateCount: UInt64
        let records: [RecordSnapshot]
    }

    private enum State: Equatable {
        case reserved, prepared, encoding, submitted, abandoning
    }
    private struct Record {
        let planIdentity: UUID
        let specification: DocumentPaintVisiblePlanSpecification
        var state: State
        var resources: SparseTileSamplingPreparedResourceIdentity?
        var core: DocumentPaintWeakSubmissionCore?
    }

    private let capacity: Int
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var records: [Key: Record] = [:]
    private var settlementEvents: [ObligationSettlementEvent] = []
    private var recentReceipts: [SparseTileSamplingResourceReturnReceipt] = []
    private var completedCount: UInt64 = 0
    private var failedCount: UInt64 = 0
    private var ignoredEarlyCount: UInt64 = 0
    private var ignoredDuplicateCount: UInt64 = 0
    #if DEBUG
    private var preparedCoreRevocationRaceGate:
        DocumentPaintPreparedCoreRevocationRaceGate?
    #endif

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        settlementEvents.reserveCapacity(capacity)
        recentReceipts.reserveCapacity(capacity)
    }

    #if DEBUG
    func installPreparedCoreRevocationRaceGate(
        _ gate: DocumentPaintPreparedCoreRevocationRaceGate?
    ) {
        preparedCoreRevocationRaceGate = gate
    }

    func recordCoreDeinitEntryForTesting() {
        preparedCoreRevocationRaceGate?.recordCoreDeinitEntry()
    }
    #endif

    func reserve(
        planIdentity: UUID,
        specification: DocumentPaintVisiblePlanSpecification
    ) throws -> Reservation {
        lock.lock()
        defer { lock.unlock() }
        guard records.count < capacity, settlementEvents.isEmpty else {
            throw DocumentPaintVisiblePlanControllerError
                .preparationBackpressure(capacity: capacity)
        }
        let (next, overflow) = nextSequence.addingReportingOverflow(1)
        guard !overflow else {
            throw DocumentPaintVisiblePlanControllerError.identityOverflow
        }
        nextSequence = next
        let key = Key(sequence: next, secret: UUID())
        records[key] = Record(
            planIdentity: planIdentity,
            specification: specification,
            state: .reserved,
            resources: nil,
            core: nil
        )
        return Reservation(key: key)
    }

    func publish(
        _ reservation: Reservation,
        core: DocumentPaintPreparedDisplaySubmissionCore,
        resources: SparseTileSamplingPreparedResourceIdentity
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[reservation.key], record.state == .reserved else {
            throw DocumentPaintVisiblePlanControllerError.staleSubmission
        }
        record.state = .prepared
        record.resources = resources
        record.core = DocumentPaintWeakSubmissionCore(core)
        records[reservation.key] = record
    }

    func cancel(_ reservation: Reservation) {
        lock.lock()
        if let record = records[reservation.key], record.state == .reserved {
            precondition(settlementEvents.count < capacity)
            records.removeValue(forKey: reservation.key)
            settlementEvents.append(ObligationSettlementEvent(
                sequence: reservation.key.sequence,
                planIdentity: record.planIdentity,
                closesTransientPlan: false
            ))
        }
        lock.unlock()
    }

    func claimForEncoding(_ key: Key) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[key] else {
            throw DocumentPaintVisiblePlanControllerError.submissionRevoked
        }
        guard record.state == .prepared else {
            switch record.state {
            case .abandoning:
                throw DocumentPaintVisiblePlanControllerError.submissionRevoked
            default:
                throw DocumentPaintVisiblePlanControllerError.submissionAlreadyConsumed
            }
        }
        record.state = .encoding
        records[key] = record
    }

    func markSubmitted(_ key: Key) {
        lock.lock()
        if var record = records[key], record.state == .encoding {
            record.state = .submitted
            records[key] = record
        }
        lock.unlock()
    }

    func requestAbandonment(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[key] else { return false }
        guard record.state == .prepared || record.state == .encoding else {
            return false
        }
        record.state = .abandoning
        records[key] = record
        return true
    }

    func revokePrepared(planIdentity: UUID?)
        -> [DocumentPaintPreparedDisplaySubmissionCore]
    {
        lock.lock()
        var result: [DocumentPaintPreparedDisplaySubmissionCore] = []
        for (key, var record) in records
        where record.state == .prepared
            && (planIdentity == nil || record.planIdentity == planIdentity)
        {
            record.state = .abandoning
            records[key] = record
            #if DEBUG
            preparedCoreRevocationRaceGate?.pauseRevocation()
            #endif
            if let core = record.core?.value { result.append(core) }
        }
        lock.unlock()
        return result
    }

    func terminalObligationSequences(planIdentity: UUID) -> Set<UInt64> {
        lock.lock()
        defer { lock.unlock() }
        return Set(records.compactMap { key, record in
            record.planIdentity == planIdentity ? key.sequence : nil
        })
    }

    func recordTerminal(
        _ key: Key,
        receipt: SparseTileSamplingResourceReturnReceipt,
        succeeded: Bool
    ) {
        lock.lock()
        if recentReceipts.contains(receipt) {
            ignoredDuplicateCount &+= 1
            lock.unlock()
            return
        }
        guard let record = records[key],
              record.state == .submitted || record.state == .abandoning
        else {
            ignoredEarlyCount &+= 1
            lock.unlock()
            return
        }
        precondition(settlementEvents.count < capacity)
        records.removeValue(forKey: key)
        settlementEvents.append(ObligationSettlementEvent(
            sequence: key.sequence,
            planIdentity: record.planIdentity,
            closesTransientPlan: true
        ))
        if succeeded { completedCount &+= 1 } else { failedCount &+= 1 }
        recentReceipts.append(receipt)
        if recentReceipts.count > capacity { recentReceipts.removeFirst() }
        lock.unlock()
    }

    func recordEarlyForTesting(_ key: Key) {
        recordTerminal(
            key,
            receipt: SparseTileSamplingResourceReturnReceipt(),
            succeeded: false
        )
    }

    func drainSettlementEvents() -> [ObligationSettlementEvent] {
        lock.lock()
        let result = settlementEvents
        settlementEvents.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let ordered = records.map { key, record in
            RecordSnapshot(
                sequence: key.sequence,
                planIdentity: record.planIdentity,
                specification: record.specification,
                isReserved: record.state == .reserved,
                isSubmitted: record.state == .encoding || record.state == .submitted,
                resources: record.resources
            )
        }.sorted { $0.sequence < $1.sequence }
        return Snapshot(
            capacity: capacity,
            reservationCount: ordered.lazy.filter(\.isReserved).count,
            preparedCount: ordered.lazy.filter {
                !$0.isReserved && !$0.isSubmitted
            }.count,
            submittedCount: ordered.lazy.filter(\.isSubmitted).count,
            terminalEventCount: settlementEvents.count,
            completedCount: completedCount,
            failedCount: failedCount,
            ignoredEarlyCount: ignoredEarlyCount,
            ignoredDuplicateCount: ignoredDuplicateCount,
            records: ordered
        )
    }
}

private final class DocumentPaintPreparedDisplaySubmissionCore:
    @unchecked Sendable
{
    private enum State: Equatable { case available, submitted, consumed }

    private let ownerIdentity: UUID
    private let key: DocumentPaintSubmissionCompletionMailbox.Key
    private let mailbox: DocumentPaintSubmissionCompletionMailbox
    private let injectEarly: Bool
    private let injectDuplicate: Bool
    private let forceTerminalFailure: Bool
    private let lock = NSLock()
    private var prepared: SparseTileSamplingPreparedSubmission?
    private var state = State.available

    init(
        ownerIdentity: UUID,
        key: DocumentPaintSubmissionCompletionMailbox.Key,
        mailbox: DocumentPaintSubmissionCompletionMailbox,
        prepared: SparseTileSamplingPreparedSubmission,
        injectEarly: Bool,
        injectDuplicate: Bool,
        forceTerminalFailure: Bool
    ) {
        self.ownerIdentity = ownerIdentity
        self.key = key
        self.mailbox = mailbox
        self.prepared = prepared
        self.injectEarly = injectEarly
        self.injectDuplicate = injectDuplicate
        self.forceTerminalFailure = forceTerminalFailure
    }

    func encode(
        expectedOwner: UUID,
        target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) throws {
        guard expectedOwner == ownerIdentity else {
            throw DocumentPaintVisiblePlanControllerError.foreignSubmission
        }
        lock.lock()
        guard state == .available, let prepared = self.prepared else {
            lock.unlock()
            throw DocumentPaintVisiblePlanControllerError.submissionAlreadyConsumed
        }
        lock.unlock()
        try prepared.validateTarget(
            target,
            renderPassDescriptor: renderPassDescriptor
        )
        try mailbox.claimForEncoding(key)
        lock.lock()
        guard state == .available,
              let claimedPrepared = self.prepared
        else {
            lock.unlock()
            throw DocumentPaintVisiblePlanControllerError.submissionAlreadyConsumed
        }
        self.prepared = nil
        state = .consumed
        lock.unlock()

        if injectEarly { mailbox.recordEarlyForTesting(key) }
        do {
            try claimedPrepared.encode(
                target: target,
                commandBuffer: commandBuffer,
                renderPassDescriptor: renderPassDescriptor
            ) { [mailbox, key, injectDuplicate, forceTerminalFailure]
                receipt, succeeded in
                let acceptedSuccess = succeeded && !forceTerminalFailure
                mailbox.recordTerminal(
                    key,
                    receipt: receipt,
                    succeeded: acceptedSuccess
                )
                if injectDuplicate {
                    mailbox.recordTerminal(
                        key,
                        receipt: receipt,
                        succeeded: acceptedSuccess
                    )
                }
            }
            mailbox.markSubmitted(key)
            lock.lock()
            state = .submitted
            lock.unlock()
        } catch {
            _ = mailbox.requestAbandonment(key)
            claimedPrepared.abandon { [mailbox, key] receipt in
                mailbox.recordTerminal(key, receipt: receipt, succeeded: false)
            }
            throw error
        }
    }

    func cancel(expectedOwner: UUID) throws {
        guard expectedOwner == ownerIdentity else {
            throw DocumentPaintVisiblePlanControllerError.foreignSubmission
        }
        guard mailbox.requestAbandonment(key) else {
            throw DocumentPaintVisiblePlanControllerError.submissionAlreadyConsumed
        }
        abandonAlreadyMarked()
    }

    func abandonAlreadyMarked() {
        lock.lock()
        guard state == .available, let prepared else {
            lock.unlock()
            return
        }
        self.prepared = nil
        state = .consumed
        lock.unlock()
        prepared.abandon { [mailbox, key] receipt in
            mailbox.recordTerminal(key, receipt: receipt, succeeded: false)
        }
    }

    deinit {
        #if DEBUG
        mailbox.recordCoreDeinitEntryForTesting()
        #endif
        // Revocation may have already marked the weakly-held record abandoning
        // before this core entered deinit. The core-local transition is
        // independently one-shot, so always return any preparation it still
        // owns and publish its exact P4 receipt.
        _ = mailbox.requestAbandonment(key)
        abandonAlreadyMarked()
    }
}

final class DocumentPaintPreparedDisplaySubmission: @unchecked Sendable {
    fileprivate let core: DocumentPaintPreparedDisplaySubmissionCore
    let specification: DocumentPaintVisiblePlanSpecification
    let resources: SparseTileSamplingPreparedResourceIdentity

    fileprivate init(
        core: DocumentPaintPreparedDisplaySubmissionCore,
        specification: DocumentPaintVisiblePlanSpecification,
        resources: SparseTileSamplingPreparedResourceIdentity
    ) {
        self.core = core
        self.specification = specification
        self.resources = resources
    }

    func encode(
        expectedOwner: UUID,
        target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) throws {
        try core.encode(
            expectedOwner: expectedOwner,
            target: target,
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor
        )
    }

    func cancel(expectedOwner: UUID) throws {
        try core.cancel(expectedOwner: expectedOwner)
    }
}

struct DocumentPaintVisiblePlanControllerSnapshot: Equatable, @unchecked Sendable {
    struct Submission: Equatable, @unchecked Sendable {
        let sequence: UInt64
        let planIdentity: UUID
        let specification: DocumentPaintVisiblePlanSpecification
        let isSubmitted: Bool
        let resources: SparseTileSamplingPreparedResourceIdentity?
    }

    let requestedSpecification: DocumentPaintVisiblePlanSpecification?
    let currentPlanIdentity: UUID?
    let currentSpecification: DocumentPaintVisiblePlanSpecification?
    let currentIsPresentable: Bool
    let preparedPlanCount: Int
    let retiringPlanCount: Int
    let preparationReservationCount: Int
    let preparedSubmissionCount: Int
    let submittedSubmissionCount: Int
    let submissions: [Submission]
    let cpuPlanCache: SparseTileSamplingPlanCacheSnapshot
    let gpuPlanCache: SparseTileSamplingGPUCacheSnapshot
    let uploadRing: SparseTileSamplingUploadRingSnapshot?
    let pendingPlanCompletionCount: Int
    let pendingConsumerCompletionCount: Int
    let pendingTerminalEventCount: Int
    let completedSubmissionCount: UInt64
    let failedSubmissionCount: UInt64
    let ignoredEarlyTerminalCount: UInt64
    let ignoredDuplicateTerminalCount: UInt64
    let isShuttingDown: Bool
    let transientAcknowledgementPendingCount: Int
    let transientAcknowledgementFailureCount: Int
    let transientAcknowledgementOwnedCount: Int
}

/// Bounded display-pipeline set owned by the one visible-plan controller.
/// Geometry transitions select exhaustively from trusted installed content;
/// they never compile a pipeline or create a second plan owner.
struct DocumentPaintVisiblePlanPipelines {
    let affine: SparseTileSamplingPipelineBinding
    let periodic: SparseTileSamplingPipelineBinding
    let finiteRadial: SparseTileSamplingPipelineBinding

    init(
        affine: SparseTileSamplingPipelineBinding,
        periodic: SparseTileSamplingPipelineBinding,
        finiteRadial: SparseTileSamplingPipelineBinding
    ) {
        precondition(affine.key.outputMappingKind == .affine)
        precondition(periodic.key.outputMappingKind == .periodic)
        precondition(finiteRadial.key.outputMappingKind == .finiteRadial)
        self.affine = affine
        self.periodic = periodic
        self.finiteRadial = finiteRadial
    }

    func binding(
        for kind: SparseTileSamplingOutputMappingKind
    ) -> SparseTileSamplingPipelineBinding {
        switch kind {
        case .affine: affine
        case .periodic: periodic
        case .finiteRadial: finiteRadial
        }
    }
}

actor DocumentPaintVisiblePlanController {
    private struct OwnedPlan {
        let identity: UUID
        let requestSequence: UInt64
        let specification: DocumentPaintVisiblePlanSpecification
        let lease: SparseTileSamplingPlanLease
        let transientSource: DocumentPaintTransientDisplaySource?
    }
    private struct CurrentPlan { let plan: OwnedPlan; var isPresentable: Bool }
    private struct PreparedPlan {
        let sequence: UInt64
        let requestSequence: UInt64
        let plan: OwnedPlan
    }
    private struct RetiringPlan {
        let plan: OwnedPlan
        var outstandingObligations: Set<UInt64>
        var leaseRetired = false
        var transientUseReleased = false
    }
    private enum RequestedState {
        case ready(DocumentPaintVisiblePlanOwnedSources)
        case building
        case planOwned
        case terminalFailed
    }
    private struct RequestedRecord {
        let token: DocumentPaintVisiblePlanRequestToken
        let transientSource: DocumentPaintTransientDisplaySource?
        var state: RequestedState
    }
    private struct TransientObligation {
        let source: DocumentPaintTransientDisplaySource
        var useCount: Int
    }
    private enum Lifecycle: Equatable { case active, shuttingDown, shutDown }

    private let identity = UUID()
    private let submissionOwnerIdentity: UUID
    private let planCache: SparseTileSamplingPlanCache
    private let gpuPlanCache: SparseTileSamplingGPUPlanCache
    private let pipelines: DocumentPaintVisiblePlanPipelines
    private let configuration: DocumentPaintVisiblePlanControllerConfiguration
    private let submissionMailbox: DocumentPaintSubmissionCompletionMailbox
    private var lifecycle = Lifecycle.active
    private var nextRequestSequence: UInt64 = 0
    private var nextPreparedSequence: UInt64 = 0
    private var ownedPlanReservations = 0
    private var requested: RequestedRecord?
    private var current: CurrentPlan?
    private var prepared: PreparedPlan?
    private var retiring: [UUID: RetiringPlan] = [:]
    private var transientObligations: [UUID: TransientObligation] = [:]

    init(
        device: any MTLDevice,
        pipelines: DocumentPaintVisiblePlanPipelines,
        submissionOwnerIdentity: UUID,
        configuration: DocumentPaintVisiblePlanControllerConfiguration = .production,
        planCache: SparseTileSamplingPlanCache = SparseTileSamplingPlanCache(),
        gpuPlanCache: SparseTileSamplingGPUPlanCache? = nil
    ) {
        self.submissionOwnerIdentity = submissionOwnerIdentity
        self.planCache = planCache
        self.gpuPlanCache = gpuPlanCache
            ?? SparseTileSamplingGPUPlanCache(
                device: device,
                limits: .production,
                preparedAbandonmentFailureInjector:
                    configuration.preparedAbandonmentFailureInjector
            )
        self.pipelines = pipelines
        self.configuration = configuration
        let submissionMailbox = DocumentPaintSubmissionCompletionMailbox(
            capacity: configuration.maximumPreparedSubmissions
        )
        #if DEBUG
        submissionMailbox.installPreparedCoreRevocationRaceGate(
            configuration.preparedCoreRevocationRaceGate
        )
        #endif
        self.submissionMailbox = submissionMailbox
    }

    func request(
        _ specification: DocumentPaintVisiblePlanSpecification,
        ownedSources: DocumentPaintVisiblePlanOwnedSources
    ) throws
        -> DocumentPaintVisiblePlanRequestToken
    {
        do {
            try ensureActive()
            guard ownedSources.contextIdentity == submissionOwnerIdentity else {
                throw DocumentPaintVisiblePlanControllerError.foreignRequest
            }
        } catch {
            try ownedSources.sourceBatch.abandon()
            throw error
        }
        reconcileTerminalEvents()
        let next: UInt64
        do {
            next = try incremented(nextRequestSequence)
        } catch {
            try ownedSources.sourceBatch.abandon()
            throw error
        }
        let token = DocumentPaintVisiblePlanRequestToken(
            ownerIdentity: identity,
            sequence: next,
            specification: specification
        )
        do {
            try registerTransientUse(ownedSources.transientSource)
        } catch {
            try ownedSources.sourceBatch.abandon()
            throw error
        }
        do {
            try settleRequestedIfReady()
        } catch {
            try ownedSources.sourceBatch.abandon()
            releaseTransientUse(ownedSources.transientSource)
            throw error
        }
        nextRequestSequence = next
        requested = RequestedRecord(
            token: token,
            transientSource: ownedSources.transientSource,
            state: .ready(ownedSources)
        )
        if let obsolete = prepared {
            prepared = nil
            moveToRetiring(obsolete.plan, outstanding: [])
        }
        if var installed = current {
            installed.isPresentable = installed.plan.specification == specification
            current = installed
            if !installed.isPresentable {
                revokePreparedSubmissions(planIdentity: installed.plan.identity)
            }
        }
        reconcileTerminalEvents()
        return token
    }

    func cancel(_ token: DocumentPaintVisiblePlanRequestToken) throws {
        guard token.ownerIdentity == identity else {
            throw DocumentPaintVisiblePlanControllerError.foreignRequest
        }
        guard let active = requested,
              active.token.sequence == token.sequence,
              active.token.specification == token.specification
        else { throw DocumentPaintVisiblePlanControllerError.staleRequest }
        let fallback = current.flatMap { installed -> CurrentPlan? in
            guard installed.plan.requestSequence != token.sequence,
                  installed.isPresentable,
                  installed.plan.specification == token.specification
            else { return nil }
            return installed
        }
        if case let .ready(ownedSources) = active.state {
            try ownedSources.sourceBatch.abandon()
            requested = nil
            releaseTransientUse(active.transientSource)
        } else if case .terminalFailed = active.state {
            requested = nil
            retryTransientAcknowledgement(active.transientSource)
        } else if case .planOwned = active.state {
            requested = nil
            if let candidate = prepared,
               candidate.requestSequence == token.sequence {
                prepared = nil
                moveToRetiring(candidate.plan, outstanding: [])
            }
            if let installed = current,
               installed.plan.requestSequence == token.sequence {
                current = nil
                revokePreparedSubmissions(
                    planIdentity: installed.plan.identity
                )
                moveToRetiring(
                    installed.plan,
                    outstanding: submissionMailbox
                        .terminalObligationSequences(
                            planIdentity: installed.plan.identity
                        )
                )
            }
        } else {
            requested = nil
        }
        if let fallback {
            current = fallback
            requested = RequestedRecord(
                token: DocumentPaintVisiblePlanRequestToken(
                    ownerIdentity: identity,
                    sequence: fallback.plan.requestSequence,
                    specification: fallback.plan.specification
                ),
                transientSource: fallback.plan.transientSource,
                state: .planOwned
            )
        } else if let superseded = current {
            current = nil
            revokePreparedSubmissions(planIdentity: superseded.plan.identity)
            moveToRetiring(
                superseded.plan,
                outstanding: submissionMailbox.terminalObligationSequences(
                    planIdentity: superseded.plan.identity
                )
            )
        }
        reconcileTerminalEvents()
    }

    func prepare(
        request token: DocumentPaintVisiblePlanRequestToken,
        limits: SparseTilePlanLimits
    ) async throws -> DocumentPaintPreparedVisiblePlanToken {
        try ensureActive()
        try validateCurrentRequest(token)
        guard var active = requested,
              case let .ready(ownedSources) = active.state
        else { throw DocumentPaintVisiblePlanControllerError.staleRequest }
        try reserveOwnedPlanCapacity()
        active.state = .building
        requested = active
        var reservationConsumed = false
        defer { if !reservationConsumed { ownedPlanReservations -= 1 } }
        let cache = planCache
        let specification = token.specification
        let previous = current?.plan.lease.content
        let sourceBatch = ownedSources.sourceBatch
        if let gate = configuration.planBuildGate { await gate.wait() }
        let candidate: SparseTileSamplingPlanLease
        do {
            candidate = try await Task.detached {
                try cache.acquire(
                    key: specification.key,
                    sourceBatch: sourceBatch,
                    outputRegion: specification.outputRegion,
                    limits: limits,
                    updating: previous
                )
            }.value
        } catch {
            handleBuildFailure(
                for: token,
                transientSource: ownedSources.transientSource
            )
            restoreCurrentAfterBuildFailure(for: token)
            throw error
        }
        let owned = OwnedPlan(
            identity: UUID(),
            requestSequence: token.sequence,
            specification: specification,
            lease: candidate,
            transientSource: ownedSources.transientSource
        )
        reservationConsumed = true
        ownedPlanReservations -= 1
        guard lifecycle == .active,
              requested?.token.ownerIdentity == token.ownerIdentity,
              requested?.token.sequence == token.sequence
        else {
            moveToRetiring(owned, outstanding: [])
            throw lifecycle == .active
                ? DocumentPaintVisiblePlanControllerError.staleRequest
                : DocumentPaintVisiblePlanControllerError.shuttingDown
        }
        if let obsolete = prepared {
            prepared = nil
            moveToRetiring(obsolete.plan, outstanding: [])
        }
        if var active = requested,
           active.token.sequence == token.sequence {
            active.state = .planOwned
            requested = active
        }
        let nextPrepared: UInt64
        do {
            nextPrepared = try incremented(nextPreparedSequence)
        } catch {
            if requested?.token.sequence == token.sequence {
                requested = nil
            }
            moveToRetiring(owned, outstanding: [])
            throw error
        }
        nextPreparedSequence = nextPrepared
        prepared = PreparedPlan(
            sequence: nextPrepared,
            requestSequence: token.sequence,
            plan: owned
        )
        return DocumentPaintPreparedVisiblePlanToken(
            ownerIdentity: identity,
            sequence: nextPrepared
        )
    }

    func install(_ token: DocumentPaintPreparedVisiblePlanToken) throws
        -> DocumentPaintInstalledVisiblePlanToken
    {
        try ensureActive()
        reconcileTerminalEvents()
        guard token.ownerIdentity == identity else {
            throw DocumentPaintVisiblePlanControllerError.foreignPreparedPlan
        }
        guard let candidate = prepared, candidate.sequence == token.sequence else {
            throw DocumentPaintVisiblePlanControllerError.stalePreparedPlan
        }
        guard let requested,
              requested.token.sequence == candidate.requestSequence,
              requested.token.specification == candidate.plan.specification
        else { throw DocumentPaintVisiblePlanControllerError.stalePreparedPlan }
        prepared = nil
        if let old = current {
            revokePreparedSubmissions(planIdentity: old.plan.identity)
            moveToRetiring(
                old.plan,
                outstanding: submissionMailbox.terminalObligationSequences(
                    planIdentity: old.plan.identity
                )
            )
        }
        current = CurrentPlan(plan: candidate.plan, isPresentable: true)
        reconcileTerminalEvents()
        return DocumentPaintInstalledVisiblePlanToken(
            ownerIdentity: identity,
            planIdentity: candidate.plan.identity,
            specification: candidate.plan.specification
        )
    }

    func prepareDisplaySubmission(
        parameters: SparseTileSamplingEncodeParameters
    ) async throws -> DocumentPaintPreparedDisplaySubmission {
        try ensureActive()
        reconcileTerminalEvents()
        guard let installed = current else {
            throw DocumentPaintVisiblePlanControllerError.noCurrentPlan
        }
        guard installed.isPresentable,
              requested?.token.specification == installed.plan.specification
        else {
            throw DocumentPaintVisiblePlanControllerError.currentPlanNotPresentable
        }
        let reservation = try submissionMailbox.reserve(
            planIdentity: installed.plan.identity,
            specification: installed.plan.specification
        )
        var published = false
        defer {
            if !published {
                submissionMailbox.cancel(reservation)
                reconcileTerminalEvents()
            }
        }

        if let gate = configuration.preparationGate { await gate.wait() }
        let pipeline = pipelines.binding(
            for: installed.plan.specification.key.outputMapping.kind
        )
        let gpuLease = try await gpuPlanCache.acquire(
            plan: installed.plan.lease,
            pipeline: pipeline
        )
        guard lifecycle == .active,
              let latest = current,
              latest.plan.identity == installed.plan.identity,
              latest.isPresentable,
              requested?.token.specification == installed.plan.specification
        else {
            try gpuLease.complete()
            throw DocumentPaintVisiblePlanControllerError.staleSubmission
        }
        let preparedSubmission = try SparseTileSamplingEncoder.prepareSubmission(
            plan: gpuLease,
            parameters: parameters
        )
        let core = DocumentPaintPreparedDisplaySubmissionCore(
            ownerIdentity: submissionOwnerIdentity,
            key: reservation.key,
            mailbox: submissionMailbox,
            prepared: preparedSubmission,
            injectEarly: configuration.injectEarlyTerminalNotification,
            injectDuplicate: configuration.injectDuplicateTerminalNotification,
            forceTerminalFailure: configuration.forceTerminalFailure
        )
        try submissionMailbox.publish(
            reservation,
            core: core,
            resources: preparedSubmission.resourceIdentity
        )
        published = true
        return DocumentPaintPreparedDisplaySubmission(
            core: core,
            specification: installed.plan.specification,
            resources: preparedSubmission.resourceIdentity
        )
    }

    func retryRetirementsAndCompletions() async throws {
        _ = await gpuPlanCache.retryPendingPlanCompletions()
        try planCache.retryPendingRetirements()
        reconcileTerminalEvents()
        for identity in Array(retiring.keys) { tryRetireIfReady(identity) }
        retryPendingTransientAcknowledgements()
    }

    func retainAndSettleUnrequestedTransientSource(
        _ source: DocumentPaintTransientDisplaySource
    ) {
        let isAlreadyOwned = ownedTransientSources.contains {
            $0.sourceIdentity == source.sourceIdentity
        }
        guard !isAlreadyOwned else { return }
        transientObligations[source.sourceIdentity] = TransientObligation(
            source: source,
            useCount: 0
        )
        retryTransientAcknowledgement(source)
    }

    /// Ends the display lifetime of the exact transient source before a
    /// committed document mutation advances its surface generation. An active
    /// request may own a ready batch, a prepared plan, or the installed plan;
    /// `cancel` already provides the transactional retirement path for each.
    func retireTransientSource(
        _ source: DocumentPaintTransientDisplaySource
    ) throws {
        reconcileTerminalEvents()
        if let active = requested,
           active.transientSource?.sourceIdentity == source.sourceIdentity {
            try cancel(active.token)
        } else {
            retainAndSettleUnrequestedTransientSource(source)
        }
    }

    func shutdown(
        reason: DocumentPaintRenderContextShutdownReason
    ) async throws -> DocumentPaintRenderContextShutdownSnapshot {
        _ = reason
        if lifecycle == .active { lifecycle = .shuttingDown }
        try settleRequestedIfReady()
        if let candidate = prepared {
            prepared = nil
            moveToRetiring(candidate.plan, outstanding: [])
        }
        if let installed = current {
            current = nil
            revokePreparedSubmissions(planIdentity: installed.plan.identity)
            moveToRetiring(
                installed.plan,
                outstanding: submissionMailbox.terminalObligationSequences(
                    planIdentity: installed.plan.identity
                )
            )
        }
        revokePreparedSubmissions(planIdentity: nil)
        _ = await gpuPlanCache.retryPendingPlanCompletions()
        try planCache.retryPendingRetirements()
        reconcileTerminalEvents()
        for identity in Array(retiring.keys) { tryRetireIfReady(identity) }
        retryPendingTransientAcknowledgements()
        let gpu = await gpuPlanCache.completionSnapshot
        let submissions = submissionMailbox.snapshot
        let isComplete = submissions.records.isEmpty
            && submissions.terminalEventCount == 0
            && ownedPlanReservations == 0
            && retiring.isEmpty
            && transientObligations.isEmpty
            && gpu.pendingPlanCompletionCount == 0
            && gpu.pendingConsumerCompletionCount == 0
        if isComplete { lifecycle = .shutDown }
        return DocumentPaintRenderContextShutdownSnapshot(
            isComplete: isComplete,
            ownedPlanReservationCount: ownedPlanReservations,
            preparedSubmissionCount: submissions.preparedCount,
            submittedSubmissionCount: submissions.submittedCount,
            retiringPlanCount: retiring.count,
            pendingP4CompletionCount: gpu.pendingPlanCompletionCount
                + gpu.pendingConsumerCompletionCount
        )
    }

    func snapshot() async -> DocumentPaintVisiblePlanControllerSnapshot {
        reconcileTerminalEvents()
        let cpu = planCache.snapshot()
        let gpu = await gpuPlanCache.allocationSnapshot
        let completion = await gpuPlanCache.completionSnapshot
        let mailbox = submissionMailbox.snapshot
        return DocumentPaintVisiblePlanControllerSnapshot(
            requestedSpecification: requested?.token.specification,
            currentPlanIdentity: current?.plan.identity,
            currentSpecification: current?.plan.specification,
            currentIsPresentable: current?.isPresentable ?? false,
            preparedPlanCount: prepared == nil ? 0 : 1,
            retiringPlanCount: retiring.count,
            preparationReservationCount: mailbox.reservationCount,
            preparedSubmissionCount: mailbox.preparedCount,
            submittedSubmissionCount: mailbox.submittedCount,
            submissions: mailbox.records.map {
                .init(
                    sequence: $0.sequence,
                    planIdentity: $0.planIdentity,
                    specification: $0.specification,
                    isSubmitted: $0.isSubmitted,
                    resources: $0.resources
                )
            },
            cpuPlanCache: cpu,
            gpuPlanCache: gpu,
            uploadRing: gpu.uploadRing,
            pendingPlanCompletionCount: completion.pendingPlanCompletionCount,
            pendingConsumerCompletionCount: completion.pendingConsumerCompletionCount,
            pendingTerminalEventCount: mailbox.terminalEventCount,
            completedSubmissionCount: mailbox.completedCount,
            failedSubmissionCount: mailbox.failedCount,
            ignoredEarlyTerminalCount: mailbox.ignoredEarlyCount,
            ignoredDuplicateTerminalCount: mailbox.ignoredDuplicateCount,
            isShuttingDown: lifecycle != .active,
            transientAcknowledgementPendingCount:
                ownedTransientSources.filter {
                    $0.acknowledgementStatus == .pending
                }.count,
            transientAcknowledgementFailureCount:
                ownedTransientSources.filter {
                    if case .failed = $0.acknowledgementStatus { return true }
                    return false
                }.count,
            transientAcknowledgementOwnedCount: transientObligations.count
        )
    }

    private func ensureActive() throws {
        guard lifecycle == .active else {
            throw DocumentPaintVisiblePlanControllerError.shuttingDown
        }
    }

    private func validateCurrentRequest(
        _ token: DocumentPaintVisiblePlanRequestToken
    ) throws {
        guard token.ownerIdentity == identity else {
            throw DocumentPaintVisiblePlanControllerError.foreignRequest
        }
        guard requested?.token.sequence == token.sequence,
              requested?.token.specification == token.specification
        else { throw DocumentPaintVisiblePlanControllerError.staleRequest }
    }

    private func restoreCurrentAfterBuildFailure(
        for token: DocumentPaintVisiblePlanRequestToken
    ) {
        guard requested?.token.sequence == token.sequence,
              var installed = current
        else {
            return
        }
        installed.isPresentable = installed.plan.specification == token.specification
        current = installed
    }

    private func reserveOwnedPlanCapacity() throws {
        let owned = (current == nil ? 0 : 1)
            + (prepared == nil ? 0 : 1)
            + retiring.count
            + ownedPlanReservations
        guard owned < configuration.maximumOwnedPlans else {
            throw DocumentPaintVisiblePlanControllerError.retirementBackpressure(
                capacity: configuration.maximumOwnedPlans
            )
        }
        ownedPlanReservations += 1
    }

    private func revokePreparedSubmissions(planIdentity: UUID?) {
        let cores = submissionMailbox.revokePrepared(planIdentity: planIdentity)
        for core in cores { core.abandonAlreadyMarked() }
    }

    private func reconcileTerminalEvents() {
        for event in submissionMailbox.drainSettlementEvents() {
            let closedCurrent = event.closesTransientPlan
                && closeCurrentTransientPlanIfNeeded(after: event)
            if !closedCurrent, var retired = retiring[event.planIdentity] {
                retired.outstandingObligations.remove(event.sequence)
                retiring[event.planIdentity] = retired
                tryRetireIfReady(event.planIdentity)
            }
        }
        pruneFulfilledTransientObligations()
    }

    private func pruneFulfilledTransientObligations() {
        for (identity, obligation) in transientObligations
        where obligation.useCount == 0
            && obligation.source.acknowledgementStatus == .fulfilled {
            transientObligations.removeValue(forKey: identity)
        }
    }

    @discardableResult
    private func closeCurrentTransientPlanIfNeeded(
        after event: DocumentPaintSubmissionCompletionMailbox
            .ObligationSettlementEvent
    ) -> Bool {
        guard let installed = current,
              installed.plan.identity == event.planIdentity,
              installed.plan.transientSource != nil
        else { return false }

        // A transient scheduler frame is a one-display-cycle source. The first
        // exact GPU terminal atomically closes it to further preparation, while
        // every already-submitted command remains an explicit retirement
        // obligation. Prepared-but-unsubmitted consumers are revoked before the
        // source can be acknowledged.
        current = nil
        if requested?.token.sequence == installed.plan.requestSequence {
            requested = nil
        }
        revokePreparedSubmissions(planIdentity: installed.plan.identity)
        moveToRetiring(
            installed.plan,
            outstanding: submissionMailbox.terminalObligationSequences(
                planIdentity: installed.plan.identity
            )
        )
        return true
    }

    private func moveToRetiring(_ plan: OwnedPlan, outstanding: Set<UInt64>) {
        retiring[plan.identity] = RetiringPlan(
            plan: plan,
            outstandingObligations: outstanding,
            leaseRetired: false,
            transientUseReleased: false
        )
        tryRetireIfReady(plan.identity)
    }

    private func tryRetireIfReady(_ identity: UUID) {
        guard var retired = retiring[identity] else { return }
        guard retired.outstandingObligations.isEmpty else { return }
        if configuration.failureInjector?.consumeRetirementFailure() == true {
            return
        }
        if !retired.leaseRetired {
            do {
                try retired.plan.lease.retire()
                retired.leaseRetired = true
            } catch SparseTileSamplingPlanError.leaseAlreadyRetired {
                retired.leaseRetired = true
            } catch {
                // Exact lease remains retained for typed retry/shutdown.
                return
            }
        }
        guard let source = retired.plan.transientSource else {
            retiring.removeValue(forKey: identity)
            return
        }
        if !retired.transientUseReleased {
            retired.transientUseReleased = true
            retiring[identity] = retired
            releaseTransientUse(source)
        }
        // This plan's lifetime is complete. Any other plan/request use and any
        // failed zero-use ACK remain independently retained by the central
        // source obligation record, not by a dead plan proxy.
        retiring.removeValue(forKey: identity)
    }

    private var ownedTransientSources: [DocumentPaintTransientDisplaySource] {
        Array(transientObligations.values.map(\.source))
    }

    private func settleRequestedIfReady() throws {
        guard let active = requested else { return }
        switch active.state {
        case let .ready(ownedSources):
            // A ready batch is never in use; close exact retention before ACK.
            try ownedSources.sourceBatch.abandon()
            requested = nil
            releaseTransientUse(active.transientSource)
        case .building:
            // The suspended prepare owns the batch and will retire/ACK after it
            // resumes and observes supersession or shutdown.
            requested = nil
        case .planOwned:
            // Ownership was transferred to PreparedPlan/CurrentPlan/retiring.
            requested = nil
        case .terminalFailed:
            requested = nil
            retryTransientAcknowledgement(active.transientSource)
        }
    }

    private func markRequestTerminalFailedIfCurrent(
        _ token: DocumentPaintVisiblePlanRequestToken
    ) {
        guard var active = requested,
              active.token.sequence == token.sequence
        else { return }
        active.state = .terminalFailed
        requested = active
        releaseTransientUse(active.transientSource)
    }

    private func handleBuildFailure(
        for token: DocumentPaintVisiblePlanRequestToken,
        transientSource: DocumentPaintTransientDisplaySource?
    ) {
        if requested?.token.sequence == token.sequence {
            markRequestTerminalFailedIfCurrent(token)
        } else {
            releaseTransientUse(transientSource)
        }
    }

    private func registerTransientUse(
        _ source: DocumentPaintTransientDisplaySource?
    ) throws {
        guard let source else { return }
        guard source.acknowledgementStatus == .available else {
            throw DocumentPaintVisiblePlanControllerError
                .transientSourceNotAvailable
        }
        if var obligation = transientObligations[source.sourceIdentity] {
            obligation.useCount += 1
            transientObligations[source.sourceIdentity] = obligation
        } else {
            transientObligations[source.sourceIdentity] = TransientObligation(
                source: source,
                useCount: 1
            )
        }
    }

    private func releaseTransientUse(
        _ source: DocumentPaintTransientDisplaySource?
    ) {
        guard let source,
              var obligation = transientObligations[source.sourceIdentity],
              obligation.useCount > 0
        else { return }
        obligation.useCount -= 1
        transientObligations[source.sourceIdentity] = obligation
        retryTransientAcknowledgement(source)
    }

    private func retryTransientAcknowledgement(
        _ source: DocumentPaintTransientDisplaySource?
    ) {
        guard let source,
              let obligation = transientObligations[source.sourceIdentity],
              obligation.useCount == 0
        else { return }
        requestTransientAcknowledgement(source)
        if source.acknowledgementStatus == .fulfilled {
            transientObligations.removeValue(forKey: source.sourceIdentity)
        }
    }

    private func retryPendingTransientAcknowledgements() {
        for obligation in Array(transientObligations.values)
        where obligation.useCount == 0 {
            retryTransientAcknowledgement(obligation.source)
        }
    }

    private func requestTransientAcknowledgement(
        _ source: DocumentPaintTransientDisplaySource?
    ) {
        guard let source else { return }
        do {
            try source.requestAcknowledgement()
        } catch StrokePreparationAcknowledgementError
                    .acknowledgementAlreadyPending,
                StrokePreparationAcknowledgementError
                    .acknowledgementAlreadyFulfilled {
            return
        } catch {
            // The exact source and its failure remain owned for later retry.
            return
        }
    }

    private func incremented(_ value: UInt64) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else {
            throw DocumentPaintVisiblePlanControllerError.identityOverflow
        }
        return next
    }
}

extension SparseTilePlanLimits {
    static let documentProduction = SparseTilePlanLimits(
        maximumPageEntries: 1_048_576,
        maximumPageChunks: 16_384,
        maximumPageTableBytes: 32 * 1_048_576,
        maximumBindingSlots: 512,
        maximumBindingChunks: 16_384,
        maximumBindingBytes: 512 * 64,
        maximumTexturesPerBatch: 16,
        maximumBatchCount: 65_536
    )
}
