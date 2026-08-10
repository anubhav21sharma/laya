import EditorCore
import Foundation
import Metal
import MetalRenderer
import PatternEngine
import PatternFile

struct PatternProjectIdentity: Equatable, Sendable {
    let documentID: UUID
    var title: String
    let createdAt: Date

    static func new(title: String = "Untitled Pattern") -> Self {
        Self(
            documentID: UUID(),
            title: title,
            createdAt: Date()
        )
    }
}

final class CapturedPatternProject:
    PatternProjectTilePayloadProvider,
    @unchecked Sendable
{
    let metadata: PatternProjectMetadata
    private let capture: DocumentPaintNativeArchiveCapture

    init(
        metadata: PatternProjectMetadata,
        capture: DocumentPaintNativeArchiveCapture
    ) {
        self.metadata = metadata
        self.capture = capture
    }

    func providePayloadChunks(
        for record: PatternPaintTileRecord,
        layerID: UUID,
        maximumChunkByteCount: Int,
        consume: (Data) throws -> Void
    ) throws {
        let payload = try capture.payload(for: record.id)
        var offset = 0
        while offset < payload.count {
            let end = min(payload.count, offset + maximumChunkByteCount)
            try consume(payload.subdata(in: offset..<end))
            offset = end
        }
    }

    func close() { capture.close() }

    deinit { close() }
}

enum PatternProjectBridgeError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unsupportedLayerModel
    case incompatibleSurface

    var errorDescription: String? {
        switch self {
        case .unsupportedLayerModel:
            "This project contains a layer model unsupported by this build."
        case .incompatibleSurface:
            "The native paint surface does not match document symmetry."
        }
    }
}

@MainActor
enum PatternProjectBridge {
    static func capture(
        renderer: GridRenderer,
        identity: PatternProjectIdentity,
        appVersion: String,
        modifiedAt: Date = Date()
    ) async throws -> CapturedPatternProject {
        let capture = try renderer.captureNativeArchive()
        do {
            let stack = capture.layerStack
            var layers: [PatternProjectLayer] = []
            layers.reserveCapacity(stack.layers.count)
            for (order, pair) in zip(stack.layers, capture.layers).enumerated() {
                let descriptor = pair.0
                let capturedLayer = pair.1
                guard descriptor.id == capturedLayer.layerID else {
                    throw PatternProjectBridgeError.incompatibleSurface
                }
                var records: [PatternPaintTileRecord] = []
                records.reserveCapacity(capturedLayer.tiles.count)
                for tile in capturedLayer.tiles {
                    let payload = try capture.payload(for: tile.persistedID)
                    let path = "tiles/\(descriptor.id.uuidString.lowercased())/"
                        + "\(tile.persistedID.uuidString.lowercased()).rgba16f"
                    records.append(try PatternPaintTileCodec.makeRecord(
                        layerID: descriptor.id,
                        id: tile.persistedID,
                        coordinate: PatternPaintTileCoordinate(
                            x: tile.coordinate.x,
                            y: tile.coordinate.y
                        ),
                        logicalBounds: PatternPaintTileBounds(
                            minX: tile.logicalBounds.minX,
                            minY: tile.logicalBounds.minY,
                            width: tile.logicalBounds.width,
                            height: tile.logicalBounds.height
                        ),
                        pixelSize: capture.geometry.storagePixelSize,
                        rasterRevision: capturedLayer.rasterRevision,
                        file: path,
                        payload: payload
                    ))
                }
                let surfacePath = "surfaces/"
                    + "\(descriptor.id.uuidString.lowercased()).tiles.json"
                layers.append(PatternProjectLayer(
                    id: descriptor.id,
                    name: descriptor.name,
                    order: order,
                    opacity: descriptor.opacity,
                    blendMode: patternBlendMode(descriptor.blendMode),
                    isVisible: descriptor.isVisible,
                    isLocked: descriptor.isLocked,
                    surface: PatternProjectPaintTileSurface(
                        manifestFile: surfacePath,
                        pixelSize: capture.geometry.storagePixelSize,
                        rasterRevision: capturedLayer.rasterRevision,
                        tiles: records
                    )
                ))
            }
            let viewport = renderer.viewport
            let metadata = PatternProjectMetadata(
                documentID: identity.documentID,
                title: identity.title,
                appVersion: appVersion,
                createdAt: identity.createdAt,
                modifiedAt: max(modifiedAt, identity.createdAt),
                canvasSize: capture.geometry.documentPixelSize,
                viewport: PatternProjectViewport(
                    scale: viewport.zoom,
                    offsetX: viewport.worldCenter.x,
                    offsetY: viewport.worldCenter.y
                ),
                documentConfiguration: renderer.documentConfiguration,
                documentDomainLocked: renderer.documentDomainLocked,
                radialGeometryLocked: renderer.radialGeometryLocked,
                activeLayerID: stack.activeLayerID,
                layers: layers
            )
            return CapturedPatternProject(
                metadata: metadata,
                capture: capture
            )
        } catch {
            capture.close()
            throw error
        }
    }

    static func identity(
        from project: DecodedPatternProject
    ) throws -> PatternProjectIdentity {
        let metadata = project.metadata.metadata
        _ = try layerStack(from: metadata)
        return PatternProjectIdentity(
            documentID: metadata.documentID,
            title: metadata.title,
            createdAt: metadata.createdAt
        )
    }

    static func makeRenderer(
        from project: DecodedPatternProject,
        device: any MTLDevice,
        library: any MTLLibrary,
        drawableSize: PatternSize
    ) async throws -> GridRenderer {
        let metadata = project.metadata.metadata
        let stack = try layerStack(from: metadata)
        let manifest = try nativeImportManifest(
            from: metadata,
            layerStack: stack,
            compiled: project.metadata.compiledSymmetry
        )
        let hasPaint = manifest.layers.contains { !$0.tiles.isEmpty }
        guard metadata.documentDomainLocked || !hasPaint else {
            throw PatternProjectBridgeError.incompatibleSurface
        }
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: drawableSize,
            configuration: try TilingCanvasConfiguration(
                pixelSize: metadata.canvasSize,
                documentConfiguration: metadata.documentConfiguration
            ),
            initialLayerStack: stack
        )
        try await renderer.importNativeArchive(
            manifest,
            documentDomainLocked: metadata.documentDomainLocked,
            radialGeometryLocked: metadata.radialGeometryLocked
        ) { writer in
            let consumer = NativeTileImportConsumer(writer: writer)
            try project.consumeTilePayloads(
                maximumChunkByteCount:
                    PatternProjectPackageCodec.tileChunkByteCount,
                consumer: consumer
            )
        }
        renderer.restoreSavedViewport(
            worldCenter: WorldPoint(
                x: metadata.viewport.offsetX,
                y: metadata.viewport.offsetY
            ),
            zoom: metadata.viewport.scale
        )
        return renderer
    }
}

private final class NativeTileImportConsumer:
    PatternProjectTilePayloadConsumer,
    @unchecked Sendable
{
    private let writer: DocumentPaintNativeArchiveImportWriter
    private var activeRecord: PatternPaintTileRecord?
    private var payload = Data()

    init(writer: DocumentPaintNativeArchiveImportWriter) {
        self.writer = writer
    }

    func beginTile(
        _ record: PatternPaintTileRecord,
        layerID: UUID
    ) throws {
        activeRecord = record
        payload.removeAll(keepingCapacity: true)
        payload.reserveCapacity(record.byteCount)
    }

    func consumeTileChunk(
        _ chunk: Data,
        record: PatternPaintTileRecord,
        layerID: UUID
    ) throws {
        payload.append(chunk)
    }

    func finishTile(
        _ record: PatternPaintTileRecord,
        layerID: UUID
    ) throws {
        guard activeRecord == record else {
            throw PatternProjectBridgeError.incompatibleSurface
        }
        try writer.install(payload, for: record.id)
        activeRecord = nil
        payload.removeAll(keepingCapacity: true)
    }

    func close() {
        activeRecord = nil
        payload.removeAll(keepingCapacity: false)
    }
}

private extension PatternProjectBridge {
    static func layerStack(
        from metadata: PatternProjectMetadata
    ) throws -> LayerStack {
        let descriptors = try metadata.layers.sorted {
            $0.order < $1.order
        }.map { layer -> LayerDescriptor in
            guard layer.kind == .pattern, layer.origin == nil else {
                throw PatternProjectBridgeError.unsupportedLayerModel
            }
            return try LayerDescriptor(
                id: layer.id,
                name: layer.name,
                isVisible: layer.isVisible,
                opacity: layer.opacity,
                isLocked: layer.isLocked,
                blendMode: rendererBlendMode(layer.blendMode)
            )
        }
        return try LayerStack(
            layers: descriptors,
            activeLayerID: metadata.activeLayerID
        )
    }

    static func nativeImportManifest(
        from metadata: PatternProjectMetadata,
        layerStack: LayerStack,
        compiled: CompiledSymmetry
    ) throws -> DocumentPaintNativeArchiveImportManifest {
        let sortedLayers = metadata.layers.sorted { $0.order < $1.order }
        let storagePixelSize: PixelSize
        guard let first = sortedLayers.first else {
            throw PatternProjectBridgeError.unsupportedLayerModel
        }
        let firstSurface = first.surface
        storagePixelSize = firstSurface.pixelSize
        let geometry = try DocumentPaintGeometry(
            documentPixelSize: metadata.canvasSize,
            storagePixelSize: storagePixelSize,
            radialLayout: compiled.domain.finite?.radial.layout
        )
        let layers = try sortedLayers.map { layer
            -> DocumentPaintNativeArchiveLayer in
            let surface = layer.surface
            guard surface.pixelSize == storagePixelSize else {
                throw PatternProjectBridgeError.unsupportedLayerModel
            }
            let tiles = try surface.tiles.map { record
                -> DocumentPaintNativeArchiveTile in
                guard let bounds = PixelRect(
                    minX: record.logicalBounds.minX,
                    minY: record.logicalBounds.minY,
                    maxX: record.logicalBounds.minX
                        + record.logicalBounds.width,
                    maxY: record.logicalBounds.minY
                        + record.logicalBounds.height
                ) else {
                    throw PatternProjectBridgeError.incompatibleSurface
                }
                return DocumentPaintNativeArchiveTile(
                    persistedID: record.id,
                    coordinate: PaintTileCoordinate(
                        x: record.coordinate.x,
                        y: record.coordinate.y
                    ),
                    logicalBounds: bounds
                )
            }
            return DocumentPaintNativeArchiveLayer(
                layerID: layer.id,
                rasterRevision: surface.rasterRevision,
                tiles: tiles
            )
        }
        return try DocumentPaintNativeArchiveImportManifest(
            geometry: geometry,
            layerStack: layerStack,
            layers: layers
        )
    }

    static func patternBlendMode(
        _ mode: LayerBlendMode
    ) -> PatternProjectBlendMode {
        switch mode {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        }
    }

    static func rendererBlendMode(
        _ mode: PatternProjectBlendMode
    ) -> LayerBlendMode {
        switch mode {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        }
    }
}
