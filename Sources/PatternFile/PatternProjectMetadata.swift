import Foundation
import PatternEngine

public enum PatternProjectFormat {
    public static let currentSchemaVersion = 4
    public static let canonicalSurfaceLayoutVersion = 1

    public static let manifestPath = "manifest.json"
    public static let symmetryPath = "tiling.json"
}

public struct PatternProjectViewport: Equatable, Sendable {
    public let scale: Float
    public let offsetX: Float
    public let offsetY: Float

    public init(scale: Float, offsetX: Float, offsetY: Float) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

public enum PatternProjectLayerKind: UInt32, Equatable, Sendable {
    case pattern = 0
    case floating = 1
}

public enum PatternProjectBlendMode: UInt32, Equatable, Sendable {
    case normal = 0
    case multiply = 1
    case screen = 2
}

public struct PatternProjectPaintTileSurface: Equatable, Sendable {
    public let manifestFile: String
    public let pixelSize: PixelSize
    public let rasterRevision: UInt64
    public let tiles: [PatternPaintTileRecord]

    public init(
        manifestFile: String,
        pixelSize: PixelSize,
        rasterRevision: UInt64,
        tiles: [PatternPaintTileRecord]
    ) {
        self.manifestFile = manifestFile
        self.pixelSize = pixelSize
        self.rasterRevision = rasterRevision
        self.tiles = tiles
    }
}

public struct PatternProjectLayer: Equatable, Sendable {
    public let id: UUID
    public let kind: PatternProjectLayerKind
    public let name: String
    public let order: Int
    public let opacity: Float
    public let blendMode: PatternProjectBlendMode
    public let isVisible: Bool
    public let isLocked: Bool
    public let origin: WorldPoint?
    public let surface: PatternProjectPaintTileSurface

    public init(
        id: UUID,
        kind: PatternProjectLayerKind = .pattern,
        name: String,
        order: Int,
        opacity: Float = 1,
        blendMode: PatternProjectBlendMode = .normal,
        isVisible: Bool = true,
        isLocked: Bool = false,
        origin: WorldPoint? = nil,
        surface: PatternProjectPaintTileSurface
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.order = order
        self.opacity = opacity
        self.blendMode = blendMode
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.origin = origin
        self.surface = surface
    }
}

public struct PatternProjectMetadata: Equatable, Sendable {
    public let documentID: UUID
    public let title: String
    public let appVersion: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let canvasSize: PixelSize
    public let viewport: PatternProjectViewport
    public let documentConfiguration: SymmetryDocumentConfiguration
    public let documentDomainLocked: Bool
    public let radialGeometryLocked: Bool
    public let activeLayerID: UUID
    public let layers: [PatternProjectLayer]

    public init(
        documentID: UUID,
        title: String,
        appVersion: String,
        createdAt: Date,
        modifiedAt: Date,
        canvasSize: PixelSize,
        viewport: PatternProjectViewport,
        documentConfiguration: SymmetryDocumentConfiguration,
        documentDomainLocked: Bool,
        radialGeometryLocked: Bool,
        activeLayerID: UUID,
        layers: [PatternProjectLayer]
    ) {
        self.documentID = documentID
        self.title = title
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.canvasSize = canvasSize
        self.viewport = viewport
        self.documentConfiguration = documentConfiguration
        self.documentDomainLocked = documentDomainLocked
        self.radialGeometryLocked = radialGeometryLocked
        self.activeLayerID = activeLayerID
        self.layers = layers
    }
}

public struct ValidatedPatternProjectMetadata: Equatable, Sendable {
    public let metadata: PatternProjectMetadata
    public let compiledSymmetry: CompiledSymmetry

    init(
        metadata: PatternProjectMetadata,
        compiledSymmetry: CompiledSymmetry
    ) {
        self.metadata = metadata
        self.compiledSymmetry = compiledSymmetry
    }
}

public struct PatternProjectMetadataFiles: Equatable, Sendable {
    public let manifest: Data
    public let symmetry: Data
    public let layersByPath: [String: Data]
    public let surfacesByPath: [String: Data]

    public init(
        manifest: Data,
        symmetry: Data,
        layersByPath: [String: Data],
        surfacesByPath: [String: Data] = [:]
    ) {
        self.manifest = manifest
        self.symmetry = symmetry
        self.layersByPath = layersByPath
        self.surfacesByPath = surfacesByPath
    }
}

public enum PatternProjectLoadError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case metadataTooLarge(path: String, actual: Int, maximum: Int)
    case invalidJSON(path: String)
    case unsupportedSchema(Int)
    case unsupportedSurfaceLayout(Int)
    case missingMetadata(String)
    case unsafeResourcePath(String)
    case resourcePathCollision(String)
    case unknownDomain(UInt32)
    case unknownPreset(UInt32)
    case invalidCanvasSize(width: Int, height: Int)
    case invalidTimestamp
    case invalidViewport
    case invalidDocumentMetadata
    case invalidSymmetryParameters
    case symmetryConfigurationMismatch
    case descriptorRejected(SymmetryDescriptorError)
    case rasterMetricMismatch
    case layerCountOutOfRange(Int)
    case duplicateLayerID(UUID)
    case duplicateLayerOrder(Int)
    case activeLayerMissing(UUID)
    case layerIdentityMismatch(expected: UUID, actual: UUID)
    case invalidLayer(UUID)
    case invalidRasterSize(layerID: UUID, width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case let .metadataTooLarge(path, actual, maximum):
            "\(path) is \(actual) bytes; the metadata limit is \(maximum)."
        case let .invalidJSON(path):
            "\(path) is not valid project metadata."
        case let .unsupportedSchema(version):
            "Project schema \(version) is unsupported."
        case let .unsupportedSurfaceLayout(version):
            "Canonical surface layout \(version) is unsupported."
        case let .missingMetadata(path):
            "Required project metadata \(path) is missing."
        case let .unsafeResourcePath(path):
            "Project resource path \(path) is unsafe."
        case let .resourcePathCollision(path):
            "Project resource path \(path) collides with project metadata."
        case let .unknownDomain(rawValue):
            "Project domain \(rawValue) is unknown."
        case let .unknownPreset(rawValue):
            "Symmetry preset \(rawValue) is unknown."
        case let .invalidCanvasSize(width, height):
            "Canvas size \(width)x\(height) is invalid."
        case .invalidTimestamp:
            "Project timestamps are invalid."
        case .invalidViewport:
            "Saved viewport is invalid."
        case .invalidDocumentMetadata:
            "Project identity metadata is invalid."
        case .invalidSymmetryParameters:
            "Persisted symmetry parameters are invalid."
        case .symmetryConfigurationMismatch:
            "Persisted domain, preset, and parameters conflict."
        case let .descriptorRejected(error):
            error.localizedDescription
        case .rasterMetricMismatch:
            "Persisted raster metric does not match compiled geometry."
        case let .layerCountOutOfRange(count):
            "Layer count \(count) is outside the supported range."
        case let .duplicateLayerID(id):
            "Layer \(id) is listed more than once."
        case let .duplicateLayerOrder(order):
            "Layer order \(order) is listed more than once."
        case let .activeLayerMissing(id):
            "Active layer \(id) is absent."
        case let .layerIdentityMismatch(expected, actual):
            "Layer file identity \(actual) does not match \(expected)."
        case let .invalidLayer(id):
            "Layer \(id) contains invalid metadata."
        case let .invalidRasterSize(layerID, width, height):
            "Layer \(layerID) raster size \(width)x\(height) is invalid."
        }
    }
}
