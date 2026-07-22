import Metal
import PatternEngine

public struct BrushAssetFallbackDiagnostic:
    Equatable, Hashable, Sendable
{
    public let kind: BrushTextureKind
    public let requestedIdentity: String
    public let fallbackIdentity: BrushTextureIdentity

    public init(
        kind: BrushTextureKind,
        requestedIdentity: String,
        fallbackIdentity: BrushTextureIdentity
    ) {
        self.kind = kind
        self.requestedIdentity = requestedIdentity
        self.fallbackIdentity = fallbackIdentity
    }
}

public struct BrushTextureResolution {
    public let texture: any MTLTexture
    public let requestedIdentity: String
    public let resolvedIdentity: BrushTextureIdentity
    public let usedFallback: Bool

    public var isExact: Bool {
        !usedFallback && requestedIdentity == resolvedIdentity.rawValue
    }
}

/// Resolves the built-in validation pack before a stroke starts.
///
/// Resolution performs no file access. Unknown identities return a typed
/// procedural fallback and emit at most one diagnostic per requested identity.
@MainActor
public final class BrushTextureResolver {
    public typealias DiagnosticHandler = @MainActor (
        BrushAssetFallbackDiagnostic
    ) -> Void

    private let factory: BrushTextureFactory
    private let diagnosticHandler: DiagnosticHandler
    private let availableIdentities: Set<BrushTextureIdentity>
    private var cache: [BrushTextureIdentity: any MTLTexture]
    private var reportedFallbackIdentities: Set<String>

    public init(
        device: any MTLDevice,
        availableIdentities: Set<BrushTextureIdentity> = Set(
            BrushTextureIdentity.allCases
        ),
        diagnosticHandler: @escaping DiagnosticHandler = { _ in }
    ) {
        factory = BrushTextureFactory(device: device)
        self.diagnosticHandler = diagnosticHandler
        self.availableIdentities = availableIdentities.union([
            .hardRoundShape,
            .opaqueGrain,
        ])
        cache = [:]
        reportedFallbackIdentities = []
    }

    public var cachedTextureCount: Int { cache.count }

    public var reportedFallbackCount: Int {
        reportedFallbackIdentities.count
    }

    /// Allocates the available built-in pack during renderer setup, keeping
    /// procedural generation out of the input and draw hot paths.
    public func preloadValidationPack() throws {
        for identity in BrushTextureIdentity.allCases
            where availableIdentities.contains(identity)
        {
            _ = try cachedTexture(identity: identity)
        }
    }

    public func resolve(
        shape descriptor: BrushShapeDescriptor
    ) throws -> BrushTextureResolution {
        let requestedIdentity: String
        let exactIdentity: BrushTextureIdentity?

        switch descriptor {
        case .hardRound:
            requestedIdentity = BrushTextureIdentity.hardRoundShape.rawValue
            exactIdentity = .hardRoundShape
        case .softRound:
            requestedIdentity = BrushTextureIdentity.softRoundShape.rawValue
            exactIdentity = .softRoundShape
        case .chisel:
            requestedIdentity = BrushTextureIdentity.chiselShape.rawValue
            exactIdentity = .chiselShape
        case let .asset(identity):
            requestedIdentity = identity
            let candidate = BrushTextureIdentity(rawValue: identity)
            exactIdentity = candidate?.kind == .shape ? candidate : nil
        }

        return try resolve(
            kind: .shape,
            requestedIdentity: requestedIdentity,
            exactIdentity: exactIdentity,
            fallbackIdentity: .hardRoundShape
        )
    }

    public func resolve(
        grain descriptor: BrushGrainDescriptor
    ) throws -> BrushTextureResolution {
        let requestedIdentity: String
        let exactIdentity: BrushTextureIdentity?

        switch descriptor {
        case .opaque:
            requestedIdentity = BrushTextureIdentity.opaqueGrain.rawValue
            exactIdentity = .opaqueGrain
        case .paper:
            requestedIdentity = BrushTextureIdentity.paperGrain.rawValue
            exactIdentity = .paperGrain
        case .noise:
            requestedIdentity = BrushTextureIdentity.noiseGrain.rawValue
            exactIdentity = .noiseGrain
        case let .asset(identity):
            requestedIdentity = identity
            let candidate = BrushTextureIdentity(rawValue: identity)
            exactIdentity = candidate?.kind == .grain ? candidate : nil
        }

        return try resolve(
            kind: .grain,
            requestedIdentity: requestedIdentity,
            exactIdentity: exactIdentity,
            fallbackIdentity: .opaqueGrain
        )
    }

    private func resolve(
        kind: BrushTextureKind,
        requestedIdentity: String,
        exactIdentity: BrushTextureIdentity?,
        fallbackIdentity: BrushTextureIdentity
    ) throws -> BrushTextureResolution {
        let availableExactIdentity = exactIdentity.flatMap {
            availableIdentities.contains($0) ? $0 : nil
        }
        let resolvedIdentity = availableExactIdentity ?? fallbackIdentity
        let texture = try cachedTexture(identity: resolvedIdentity)
        let usedFallback = availableExactIdentity == nil

        if usedFallback {
            let diagnostic = BrushAssetFallbackDiagnostic(
                kind: kind,
                requestedIdentity: requestedIdentity,
                fallbackIdentity: fallbackIdentity
            )
            if reportedFallbackIdentities.insert(requestedIdentity).inserted {
                diagnosticHandler(diagnostic)
            }
        }

        return BrushTextureResolution(
            texture: texture,
            requestedIdentity: requestedIdentity,
            resolvedIdentity: resolvedIdentity,
            usedFallback: usedFallback
        )
    }

    private func cachedTexture(
        identity: BrushTextureIdentity
    ) throws -> any MTLTexture {
        if let texture = cache[identity] {
            return texture
        }
        let texture = try factory.makeTexture(identity: identity)
        cache[identity] = texture
        return texture
    }
}
