import Foundation
import PatternEngine

/// Affine commit linearization shared by the facade and transaction worker.
/// Once canonical publication is marked, a competing renderer failure request
/// must allow the already-published commit to finalize as success.
final class StrokeCommitPublicationState: @unchecked Sendable {
    private enum Owner {
        case pending
        case publication
        case failure
    }

    private let lock = NSLock()
    private var owner = Owner.pending

    /// Claims the sole terminal outcome immediately before irreversible
    /// publication. False means a renderer failure already won and the
    /// transaction must discard its prepared terminal mutation.
    func claimPublication() -> Bool {
        lock.withLock {
            switch owner {
            case .pending:
                owner = .publication
                return true
            case .publication:
                return true
            case .failure:
                return false
            }
        }
    }

    /// Claims failure before publication. False means publication already
    /// owns the terminal result, so the renderer must defer to commit success.
    func claimFailure() -> Bool {
        lock.withLock {
            switch owner {
            case .pending:
                owner = .failure
                return true
            case .publication:
                return false
            case .failure:
                return true
            }
        }
    }
}

/// Bridges a sealed transient stroke into the canonical sparse document and
/// returns the history-bearing application result to the facade.
enum StrokeCommitter {
    static func parameters(
        mode: StrokeCompositeMode,
        strokeOpacity: Float,
        eraserStrength: Float
    ) -> DocumentPaintStrokeCompositeParameters {
        DocumentPaintStrokeCompositeParameters(
            mode: mode,
            strokeOpacity: strokeOpacity,
            accumulationLimit: 1,
            eraserStrength: mode == .erase ? eraserStrength : 1
        )
    }

    static func commit(
        _ mutation: StrokePreparedCommitMutation,
        context: DocumentPaintRenderContext,
        capability: DocumentPaintStrokeSurfaceCapability?,
        parameters: DocumentPaintStrokeCompositeParameters,
        publicationState: StrokeCommitPublicationState? = nil
    ) async throws -> DocumentPaintSurfaceApplicationResult {
        switch mutation {
        case let .source(source):
            return try await context.commitStroke(
                source,
                compositeParameters: parameters,
                publicationState: publicationState
            )
        case .noOp:
            guard let capability, capability.isTerminal else {
                throw MetalRendererError.invalidStrokeLifecycle
            }
            let identity = await context.canonicalStateIdentity()
            return DocumentPaintSurfaceApplicationResult(
                didPublish: false,
                layerID: capability.layerID,
                generation: capability.generation,
                dirtyCoordinates: [],
                baseCanonicalIdentity: identity,
                canonicalIdentity: identity,
                compositeInvalidation: .none,
                historyPair: nil
            )
        }
    }
}
