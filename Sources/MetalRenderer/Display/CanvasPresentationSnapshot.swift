import PatternEngine

enum CanvasPresentationSnapshotCompatibilityError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case revisionConflict(
        component: String,
        prepared: UInt64,
        current: UInt64
    )
    case valueConflict(component: String)
    case incompleteTransientIdentity(
        generation: UInt64?,
        revision: UInt64?
    )

    var description: String {
        switch self {
        case let .revisionConflict(component, prepared, current):
            "\(component) revision conflict "
                + "(prepared: \(prepared), current: \(current))"
        case let .valueConflict(component):
            "\(component) value conflict"
        case let .incompleteTransientIdentity(generation, revision):
            "incomplete transient identity "
                + "(generation: \(String(describing: generation)), "
                + "revision: \(String(describing: revision)))"
        }
    }
}

struct CanvasPresentationSnapshot: Equatable, @unchecked Sendable {
    let revision: CanvasPresentationRevision
    let canonicalIdentity: CanvasCanonicalStateIdentity
    let canonicalCacheRevision: UInt64
    let transientGeneration: UInt64?
    let transientRevision: UInt64?
    let outputMappingRevision: UInt64
    let viewportRevision: UInt64
    let viewport: ViewportTransform
    let drawablePixelSize: PixelSize
    let backingScaleRevision: UInt64
    let showGridLines: Bool
    let showCanvasBoundary: Bool

    func validateCompatibility() throws {
        guard canonicalCacheRevision
                == canonicalIdentity.compositeRevision
        else {
            throw CanvasPresentationSnapshotCompatibilityError
                .revisionConflict(
                    component: "canonical cache",
                    prepared: canonicalCacheRevision,
                    current: canonicalIdentity.compositeRevision
                )
        }
        guard (transientGeneration == nil) == (transientRevision == nil) else {
            throw CanvasPresentationSnapshotCompatibilityError
                .incompleteTransientIdentity(
                    generation: transientGeneration,
                    revision: transientRevision
                )
        }
    }

    func validateCompatibility(
        with current: CanvasPresentationSnapshot
    ) throws {
        try validateCompatibility()
        try current.validateCompatibility()
        try requireRevision(
            "presentation",
            revision.sequence,
            current.revision.sequence
        )
        try requireRevision(
            "document generation",
            canonicalIdentity.documentGeneration,
            current.canonicalIdentity.documentGeneration
        )
        try requireRevision(
            "canonical geometry",
            canonicalIdentity.geometryRevision,
            current.canonicalIdentity.geometryRevision
        )
        try requireRevision(
            "canonical layer stack",
            canonicalIdentity.layerStackRevision,
            current.canonicalIdentity.layerStackRevision
        )
        try requireRevision(
            "canonical composite",
            canonicalIdentity.compositeRevision,
            current.canonicalIdentity.compositeRevision
        )
        guard canonicalIdentity.geometry == current.canonicalIdentity.geometry
        else {
            throw CanvasPresentationSnapshotCompatibilityError
                .valueConflict(component: "canonical geometry")
        }
        try requireRevision(
            "canonical cache",
            canonicalCacheRevision,
            current.canonicalCacheRevision
        )
        try requireOptionalRevision(
            "transient generation",
            transientGeneration,
            current.transientGeneration
        )
        try requireOptionalRevision(
            "transient",
            transientRevision,
            current.transientRevision
        )
        try requireRevision(
            "output mapping",
            outputMappingRevision,
            current.outputMappingRevision
        )
        try requireRevision(
            "viewport",
            viewportRevision,
            current.viewportRevision
        )
        guard viewport == current.viewport else {
            throw CanvasPresentationSnapshotCompatibilityError
                .valueConflict(component: "viewport")
        }
        guard drawablePixelSize == current.drawablePixelSize else {
            throw CanvasPresentationSnapshotCompatibilityError
                .valueConflict(component: "drawable pixel size")
        }
        try requireRevision(
            "backing scale",
            backingScaleRevision,
            current.backingScaleRevision
        )
        guard showGridLines == current.showGridLines,
              showCanvasBoundary == current.showCanvasBoundary
        else {
            throw CanvasPresentationSnapshotCompatibilityError
                .valueConflict(component: "presentation options")
        }
    }

    private func requireRevision(
        _ component: String,
        _ prepared: UInt64,
        _ current: UInt64
    ) throws {
        guard prepared == current else {
            throw CanvasPresentationSnapshotCompatibilityError
                .revisionConflict(
                    component: component,
                    prepared: prepared,
                    current: current
                )
        }
    }

    private func requireOptionalRevision(
        _ component: String,
        _ prepared: UInt64?,
        _ current: UInt64?
    ) throws {
        guard prepared == current else {
            throw CanvasPresentationSnapshotCompatibilityError
                .revisionConflict(
                    component: component,
                    prepared: prepared ?? 0,
                    current: current ?? 0
                )
        }
    }
}
