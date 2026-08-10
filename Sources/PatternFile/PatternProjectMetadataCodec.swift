import Foundation
import PatternEngine

public enum PatternProjectMetadataCodec {
    public static let maximumMetadataBytesPerFile = 1_048_576
    public static let maximumLayerCount = 8

    public static func encode(
        _ metadata: PatternProjectMetadata
    ) throws -> PatternProjectMetadataFiles {
        let compiled = try validate(metadata)
        let normalizedConfiguration = configuration(from: compiled)
        let orderedLayers = metadata.layers.sorted {
            if $0.order == $1.order {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.order < $1.order
        }
        let layerPaths = orderedLayers.map {
            "layers/\($0.id.uuidString.lowercased()).json"
        }
        let manifest = ManifestWire(
            schemaVersion: PatternProjectFormat.currentSchemaVersion,
            canonicalSurfaceLayoutVersion:
                PatternProjectFormat.canonicalSurfaceLayoutVersion,
            documentID: metadata.documentID,
            title: metadata.title,
            appVersion: metadata.appVersion,
            createdAt: metadata.createdAt.timeIntervalSince1970,
            modifiedAt: metadata.modifiedAt.timeIntervalSince1970,
            canvasWidth: metadata.canvasSize.width,
            canvasHeight: metadata.canvasSize.height,
            viewport: ViewportWire(metadata.viewport),
            activeLayerID: metadata.activeLayerID,
            layerFiles: layerPaths
        )
        let symmetry = SymmetryWire(
            domain: normalizedConfiguration.domainID.rawValue,
            preset: compiled.presetID.rawValue,
            periodic: periodicWire(normalizedConfiguration),
            radial: radialWire(normalizedConfiguration),
            documentDomainLocked: metadata.documentDomainLocked,
            radialGeometryLocked: metadata.radialGeometryLocked,
            rasterMetric: RasterMetricWire(compiled.rasterMetric)
        )

        let nativeSurfaces = orderedLayers.map { layer in
            PatternPaintTileSurface(
                layerID: layer.id,
                pixelSize: layer.surface.pixelSize,
                rasterRevision: layer.surface.rasterRevision,
                tiles: layer.surface.tiles
            )
        }
        do {
            try PatternPaintTileCodec.validateMetadata(nativeSurfaces)
        } catch {
            throw PatternProjectLoadError.invalidDocumentMetadata
        }

        var layersByPath: [String: Data] = [:]
        var surfacesByPath: [String: Data] = [:]
        for (layer, path) in zip(orderedLayers, layerPaths) {
            let surface = layer.surface
            let layerWire = LayerWire(
                id: layer.id,
                kind: layer.kind.rawValue,
                name: layer.name,
                order: layer.order,
                opacity: layer.opacity,
                blendMode: layer.blendMode.rawValue,
                isVisible: layer.isVisible,
                isLocked: layer.isLocked,
                originX: layer.origin?.x,
                originY: layer.origin?.y,
                paintTileSurfaceManifestFile: surface.manifestFile
            )
            let nativeSurface = PatternPaintTileSurface(
                layerID: layer.id,
                pixelSize: surface.pixelSize,
                rasterRevision: surface.rasterRevision,
                tiles: surface.tiles
            )
            surfacesByPath[surface.manifestFile] = try PatternPaintTileCodec
                .encodeManifestOfValidatedSurface(nativeSurface)
            layersByPath[path] = try encodeJSON(layerWire)
        }

        return PatternProjectMetadataFiles(
            manifest: try encodeJSON(manifest),
            symmetry: try encodeJSON(symmetry),
            layersByPath: layersByPath,
            surfacesByPath: surfacesByPath
        )
    }

    public static func decode(
        _ files: PatternProjectMetadataFiles
    ) throws -> ValidatedPatternProjectMetadata {
        try requireCurrentSchema(files.manifest)
        return try decodeCurrentFiles(files)
    }

    public static func decode(
        from archive: PatternProjectArchive
    ) throws -> ValidatedPatternProjectMetadata {
        try decodeCurrentFiles(metadataFiles(from: archive))
    }

    static func extractedMetadata(
        from archive: PatternProjectArchive
    ) throws -> (
        files: PatternProjectMetadataFiles,
        validated: ValidatedPatternProjectMetadata
    ) {
        let files = try metadataFiles(from: archive)
        return (files, try decodeCurrentFiles(files))
    }
}

private extension PatternProjectMetadataCodec {
    static func decodeCurrentFiles(
        _ files: PatternProjectMetadataFiles
    ) throws -> ValidatedPatternProjectMetadata {
        let manifest: ManifestWire = try decodeJSON(
            files.manifest,
            path: PatternProjectFormat.manifestPath
        )
        return try decodeCurrent(manifest: manifest, files: files)
    }

    static func metadataFiles(
        from archive: PatternProjectArchive
    ) throws -> PatternProjectMetadataFiles {
        let manifestData = try boundedMetadataData(
            for: PatternProjectFormat.manifestPath,
            from: archive
        )
        try requireCurrentSchema(manifestData)
        let manifest: ManifestWire = try decodeJSON(
            manifestData,
            path: PatternProjectFormat.manifestPath
        )
        guard (1...maximumLayerCount).contains(manifest.layerFiles.count)
        else {
            throw PatternProjectLoadError.layerCountOutOfRange(
                manifest.layerFiles.count
            )
        }
        var layersByPath: [String: Data] = [:]
        var surfacesByPath: [String: Data] = [:]
        for path in manifest.layerFiles {
            try validateResourcePath(path)
            guard !reservedArchivePaths.contains(path) else {
                throw PatternProjectLoadError.resourcePathCollision(path)
            }
            guard layersByPath[path] == nil else {
                throw PatternProjectLoadError.invalidDocumentMetadata
            }
            let layerData = try boundedMetadataData(
                for: path,
                from: archive
            )
            layersByPath[path] = layerData
            let layer: LayerWire = try decodeJSON(
                layerData,
                path: path
            )
            let surfacePath = layer.paintTileSurfaceManifestFile
            try validateResourcePath(surfacePath)
            guard !reservedArchivePaths.contains(surfacePath),
                  !manifest.layerFiles.contains(surfacePath)
            else {
                throw PatternProjectLoadError
                    .resourcePathCollision(surfacePath)
            }
            if surfacesByPath[surfacePath] == nil {
                surfacesByPath[surfacePath] = try boundedMetadataData(
                    for: surfacePath,
                    from: archive
                )
            }
        }
        let symmetry = try boundedMetadataData(
            for: PatternProjectFormat.symmetryPath,
            from: archive
        )
        return PatternProjectMetadataFiles(
            manifest: manifestData,
            symmetry: symmetry,
            layersByPath: layersByPath,
            surfacesByPath: surfacesByPath
        )
    }

    static func boundedMetadataData(
        for path: String,
        from archive: PatternProjectArchive
    ) throws -> Data {
        let byteCount: Int
        do {
            byteCount = try archive.byteCount(for: path)
        } catch PatternProjectArchiveError.missingEntry {
            throw PatternProjectLoadError.missingMetadata(path)
        }
        guard byteCount <= maximumMetadataBytesPerFile else {
            throw PatternProjectLoadError.metadataTooLarge(
                path: path,
                actual: byteCount,
                maximum: maximumMetadataBytesPerFile
            )
        }
        do {
            return try archive.data(
                for: path,
                maximumByteCount: UInt64(maximumMetadataBytesPerFile)
            )
        } catch PatternProjectArchiveError.missingEntry {
            throw PatternProjectLoadError.missingMetadata(path)
        }
    }

    static func decodeCurrent(
        manifest: ManifestWire,
        files: PatternProjectMetadataFiles
    ) throws -> ValidatedPatternProjectMetadata {
        guard manifest.canonicalSurfaceLayoutVersion
            == PatternProjectFormat.canonicalSurfaceLayoutVersion
        else {
            throw PatternProjectLoadError.unsupportedSurfaceLayout(
                manifest.canonicalSurfaceLayoutVersion
            )
        }
        let canvasSize = try validateManifest(manifest)
        let symmetry: SymmetryWire = try decodeJSON(
            files.symmetry,
            path: PatternProjectFormat.symmetryPath
        )
        let decodedConfiguration = try documentConfiguration(
            symmetry,
            canvasSize: canvasSize
        )
        let compiled = try compile(
            decodedConfiguration,
            canvasSize: canvasSize
        )
        let configuration = configuration(from: compiled)
        guard symmetry.rasterMetric.matches(compiled.rasterMetric) else {
            throw PatternProjectLoadError.rasterMetricMismatch
        }
        let layers = try decodeLayers(
            manifest: manifest,
            files: files
        )
        let metadata = try makeMetadata(
            manifest: manifest,
            canvasSize: canvasSize,
            configuration: configuration,
            documentDomainLocked: symmetry.documentDomainLocked,
            radialGeometryLocked: symmetry.radialGeometryLocked,
            layers: layers
        )
        try validateSemantics(metadata, compiled: compiled)
        return ValidatedPatternProjectMetadata(
            metadata: metadata,
            compiledSymmetry: compiled
        )
    }

    static func validate(
        _ metadata: PatternProjectMetadata
    ) throws -> CompiledSymmetry {
        try validateIdentity(
            title: metadata.title,
            appVersion: metadata.appVersion,
            createdAt: metadata.createdAt.timeIntervalSince1970,
            modifiedAt: metadata.modifiedAt.timeIntervalSince1970
        )
        try validateViewport(metadata.viewport)
        let compiled = try compile(
            metadata.documentConfiguration,
            canvasSize: metadata.canvasSize
        )
        try validateSemantics(metadata, compiled: compiled)
        return compiled
    }

    static func validateSemantics(
        _ metadata: PatternProjectMetadata,
        compiled: CompiledSymmetry
    ) throws {
        switch metadata.documentConfiguration {
        case .periodic, .finite(.plain):
            guard !metadata.radialGeometryLocked else {
                throw PatternProjectLoadError.symmetryConfigurationMismatch
            }
        case .finite(.radial):
            guard metadata.documentDomainLocked
                == metadata.radialGeometryLocked
            else {
                throw PatternProjectLoadError.symmetryConfigurationMismatch
            }
        }
        try validateLayers(
            metadata.layers,
            activeLayerID: metadata.activeLayerID,
            canvasSize: metadata.canvasSize,
            compiled: compiled
        )
    }

    static func compile(
        _ configuration: SymmetryDocumentConfiguration,
        canvasSize: PixelSize
    ) throws -> CompiledSymmetry {
        do {
            return try SymmetryDescriptorCompiler.compile(
                documentConfiguration: configuration,
                canvasSize: canvasSize
            )
        } catch let error as SymmetryDescriptorError {
            throw PatternProjectLoadError.descriptorRejected(error)
        } catch {
            throw PatternProjectLoadError.invalidSymmetryParameters
        }
    }

    static func documentConfiguration(
        _ wire: SymmetryWire,
        canvasSize: PixelSize
    ) throws -> SymmetryDocumentConfiguration {
        guard let domain = SymmetryDocumentDomainID(rawValue: wire.domain)
        else {
            throw PatternProjectLoadError.unknownDomain(wire.domain)
        }
        guard let preset = SymmetryPresetID(rawValue: wire.preset) else {
            throw PatternProjectLoadError.unknownPreset(wire.preset)
        }
        switch domain {
        case .periodic:
            guard preset.isPeriodic,
                  let periodic = wire.periodic,
                  wire.radial == nil,
                  !wire.radialGeometryLocked,
                  periodic.repeatWidth.isFinite,
                  periodic.repeatHeight.isFinite,
                  periodic.orientationRadians.isFinite,
                  periodic.repeatWidth > 0,
                  periodic.repeatHeight > 0
            else {
                throw PatternProjectLoadError.symmetryConfigurationMismatch
            }
            return .periodic(PeriodicSymmetryConfiguration(
                presetID: preset,
                repeatSize: PatternSize(
                    width: periodic.repeatWidth,
                    height: periodic.repeatHeight
                ),
                orientationRadians: periodic.orientationRadians
            ))
        case .finite:
            guard wire.periodic == nil else {
                throw PatternProjectLoadError.symmetryConfigurationMismatch
            }
            if preset == .plainCanvas {
                guard wire.radial == nil, !wire.radialGeometryLocked else {
                    throw PatternProjectLoadError
                        .symmetryConfigurationMismatch
                }
                return .finite(.plain)
            }
            guard let radial = wire.radial,
                  let kind = RadialSymmetryKind(rawValue: radial.kind),
                  radial.centerX.isFinite,
                  radial.centerY.isFinite,
                  radial.referenceAngleRadians.isFinite
            else {
                throw PatternProjectLoadError.invalidSymmetryParameters
            }
            let expectedPreset: SymmetryPresetID
            switch kind {
            case .mirror: expectedPreset = .radialMirror
            case .rotation: expectedPreset = .radialRotation
            case .mandala: expectedPreset = .radialMandala
            }
            guard preset == expectedPreset else {
                throw PatternProjectLoadError.symmetryConfigurationMismatch
            }
            return .finite(.radial(RadialSymmetryConfiguration(
                kind: kind,
                rayCount: radial.rayCount,
                center: WorldPoint(x: radial.centerX, y: radial.centerY),
                referenceAngleRadians: radial.referenceAngleRadians
            )))
        }
    }

    static func decodeLayers(
        manifest: ManifestWire,
        files: PatternProjectMetadataFiles
    ) throws -> [PatternProjectLayer] {
        guard (1...maximumLayerCount).contains(manifest.layerFiles.count)
        else {
            throw PatternProjectLoadError.layerCountOutOfRange(
                manifest.layerFiles.count
            )
        }
        var layers: [PatternProjectLayer] = []
        layers.reserveCapacity(manifest.layerFiles.count)
        for path in manifest.layerFiles {
            try validateResourcePath(path)
            guard let data = files.layersByPath[path] else {
                throw PatternProjectLoadError.missingMetadata(path)
            }
            let wire: LayerWire = try decodeJSON(data, path: path)
            let layer = try decodeLayer(
                wire,
                files: files
            )
            layers.append(layer)
        }
        let metadataPaths = Set(manifest.layerFiles).union(reservedArchivePaths)
        for layer in layers {
            for path in [layer.surface.manifestFile]
                + layer.surface.tiles.map(\.file)
                where metadataPaths.contains(path) {
                throw PatternProjectLoadError.resourcePathCollision(path)
            }
        }
        return layers
    }

    static func decodeLayer(
        _ wire: LayerWire,
        files: PatternProjectMetadataFiles
    ) throws -> PatternProjectLayer {
        guard let kind = PatternProjectLayerKind(rawValue: wire.kind),
              let blendMode = PatternProjectBlendMode(
                  rawValue: wire.blendMode
              )
        else {
            throw PatternProjectLoadError.invalidLayer(wire.id)
        }
        let origin: WorldPoint?
        switch (wire.originX, wire.originY) {
        case (nil, nil):
            origin = nil
        case let (.some(x), .some(y)) where x.isFinite && y.isFinite:
            origin = WorldPoint(x: x, y: y)
        default:
            throw PatternProjectLoadError.invalidLayer(wire.id)
        }

        let manifestFile = wire.paintTileSurfaceManifestFile
        try validateResourcePath(manifestFile)
        guard !reservedArchivePaths.contains(manifestFile) else {
            throw PatternProjectLoadError.resourcePathCollision(manifestFile)
        }
        guard let surfaceData = files.surfacesByPath[manifestFile] else {
            throw PatternProjectLoadError.missingMetadata(manifestFile)
        }
        let native: PatternPaintTileSurface
        do {
            native = try PatternPaintTileCodec
                .decodeManifestMetadataStructure(surfaceData)
        } catch {
            throw PatternProjectLoadError.invalidLayer(wire.id)
        }
        guard native.layerID == wire.id else {
            throw PatternProjectLoadError.layerIdentityMismatch(
                expected: wire.id,
                actual: native.layerID
            )
        }
        let surface = PatternProjectPaintTileSurface(
            manifestFile: manifestFile,
            pixelSize: native.pixelSize,
            rasterRevision: native.rasterRevision,
            tiles: native.tiles
        )

        return PatternProjectLayer(
            id: wire.id,
            kind: kind,
            name: wire.name,
            order: wire.order,
            opacity: wire.opacity,
            blendMode: blendMode,
            isVisible: wire.isVisible,
            isLocked: wire.isLocked,
            origin: origin,
            surface: surface
        )
    }

    static func validateLayers(
        _ layers: [PatternProjectLayer],
        activeLayerID: UUID,
        canvasSize: PixelSize,
        compiled: CompiledSymmetry
    ) throws {
        guard (1...maximumLayerCount).contains(layers.count) else {
            throw PatternProjectLoadError.layerCountOutOfRange(layers.count)
        }
        var ids = Set<UUID>()
        var orders = Set<Int>()
        var resourcePaths = reservedArchivePaths
        var nativeSurfaces: [PatternPaintTileSurface] = []
        nativeSurfaces.reserveCapacity(layers.count)
        resourcePaths.formUnion(layers.map {
            "layers/\($0.id.uuidString.lowercased()).json"
        })
        for layer in layers {
            guard ids.insert(layer.id).inserted else {
                throw PatternProjectLoadError.duplicateLayerID(layer.id)
            }
            guard orders.insert(layer.order).inserted else {
                throw PatternProjectLoadError.duplicateLayerOrder(
                    layer.order
                )
            }
            guard !layer.name.isEmpty,
                  layer.name.count <= 256,
                  layer.order >= 0,
                  layer.opacity.isFinite,
                  (0...1).contains(layer.opacity)
            else {
                throw PatternProjectLoadError.invalidLayer(layer.id)
            }
            switch layer.kind {
            case .pattern:
                guard layer.origin == nil else {
                    throw PatternProjectLoadError.invalidLayer(layer.id)
                }
            case .floating:
                guard let origin = layer.origin,
                      origin.x.isFinite,
                      origin.y.isFinite
                else {
                    throw PatternProjectLoadError.invalidLayer(layer.id)
                }
            }
            try validateSurface(
                layer,
                canvasSize: canvasSize,
                compiled: compiled,
                resourcePaths: &resourcePaths,
                nativeSurfaces: &nativeSurfaces
            )
        }
        do {
            try PatternPaintTileCodec.validateMetadata(nativeSurfaces)
        } catch {
            throw PatternProjectLoadError.invalidDocumentMetadata
        }
        guard orders == Set(0..<layers.count) else {
            throw PatternProjectLoadError.invalidDocumentMetadata
        }
        guard ids.contains(activeLayerID) else {
            throw PatternProjectLoadError.activeLayerMissing(activeLayerID)
        }
    }

    static func validateSurface(
        _ layer: PatternProjectLayer,
        canvasSize: PixelSize,
        compiled: CompiledSymmetry,
        resourcePaths: inout Set<String>,
        nativeSurfaces: inout [PatternPaintTileSurface]
    ) throws {
        let surface = layer.surface
        try validateResourcePath(surface.manifestFile)
        guard resourcePaths.insert(surface.manifestFile).inserted else {
            throw PatternProjectLoadError.resourcePathCollision(
                surface.manifestFile
            )
        }
        let expectedPixelSize = expectedPaintTilePixelSize(
            canvasSize: canvasSize,
            compiled: compiled
        )
        guard surface.pixelSize == expectedPixelSize else {
            throw PatternProjectLoadError.invalidRasterSize(
                layerID: layer.id,
                width: surface.pixelSize.width,
                height: surface.pixelSize.height
            )
        }
        nativeSurfaces.append(PatternPaintTileSurface(
            layerID: layer.id,
            pixelSize: surface.pixelSize,
            rasterRevision: surface.rasterRevision,
            tiles: surface.tiles
        ))
        for tile in surface.tiles {
            guard resourcePaths.insert(tile.file).inserted else {
                throw PatternProjectLoadError.resourcePathCollision(tile.file)
            }
        }
    }

    static func validateManifest(
        _ manifest: ManifestWire
    ) throws -> PixelSize {
        guard (64...4_096).contains(manifest.canvasWidth),
              (64...4_096).contains(manifest.canvasHeight)
        else {
            throw PatternProjectLoadError.invalidCanvasSize(
                width: manifest.canvasWidth,
                height: manifest.canvasHeight
            )
        }
        try validateIdentity(
            title: manifest.title,
            appVersion: manifest.appVersion,
            createdAt: manifest.createdAt,
            modifiedAt: manifest.modifiedAt
        )
        try validateViewport(manifest.viewport.value)
        return PixelSize(
            width: manifest.canvasWidth,
            height: manifest.canvasHeight
        )
    }

    static func validateIdentity(
        title: String,
        appVersion: String,
        createdAt: TimeInterval,
        modifiedAt: TimeInterval
    ) throws {
        guard !title.isEmpty,
              title.count <= 256,
              !appVersion.isEmpty,
              appVersion.count <= 64
        else {
            throw PatternProjectLoadError.invalidDocumentMetadata
        }
        guard createdAt.isFinite,
              modifiedAt.isFinite,
              createdAt >= 0,
              modifiedAt >= createdAt
        else {
            throw PatternProjectLoadError.invalidTimestamp
        }
    }

    static func validateViewport(
        _ viewport: PatternProjectViewport
    ) throws {
        guard viewport.scale.isFinite,
              viewport.offsetX.isFinite,
              viewport.offsetY.isFinite,
              (0.25...8).contains(viewport.scale)
        else {
            throw PatternProjectLoadError.invalidViewport
        }
    }

    static func makeMetadata(
        manifest: ManifestWire,
        canvasSize: PixelSize,
        configuration: SymmetryDocumentConfiguration,
        documentDomainLocked: Bool,
        radialGeometryLocked: Bool,
        layers: [PatternProjectLayer]
    ) throws -> PatternProjectMetadata {
        let metadata = PatternProjectMetadata(
            documentID: manifest.documentID,
            title: manifest.title,
            appVersion: manifest.appVersion,
            createdAt: Date(timeIntervalSince1970: manifest.createdAt),
            modifiedAt: Date(timeIntervalSince1970: manifest.modifiedAt),
            canvasSize: canvasSize,
            viewport: manifest.viewport.value,
            documentConfiguration: configuration,
            documentDomainLocked: documentDomainLocked,
            radialGeometryLocked: radialGeometryLocked,
            activeLayerID: manifest.activeLayerID,
            layers: layers
        )
        return metadata
    }

    static func expectedPaintTilePixelSize(
        canvasSize: PixelSize,
        compiled: CompiledSymmetry
    ) -> PixelSize {
        compiled.domain.finite?.radial.layout?.atlasPixelSize ?? canvasSize
    }

    static func validateResourcePath(_ path: String) throws {
        guard !path.isEmpty,
              path.utf8.count <= 512,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else {
            throw PatternProjectLoadError.unsafeResourcePath(path)
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              })
        else {
            throw PatternProjectLoadError.unsafeResourcePath(path)
        }
    }

    static var reservedArchivePaths: Set<String> {
        [
            PatternProjectFormat.manifestPath,
            PatternProjectFormat.symmetryPath,
            "thumbnail.png",
            "palettes/project_palette.json",
        ]
    }

    static func periodicWire(
        _ configuration: SymmetryDocumentConfiguration
    ) -> PeriodicWire? {
        guard case let .periodic(periodic) = configuration else {
            return nil
        }
        return PeriodicWire(
            repeatWidth: periodic.repeatSize.width,
            repeatHeight: periodic.repeatSize.height,
            orientationRadians: periodic.orientationRadians
        )
    }

    static func configuration(
        from compiled: CompiledSymmetry
    ) -> SymmetryDocumentConfiguration {
        switch compiled.domain {
        case let .periodic(periodic):
            return .periodic(periodic.configuration)
        case let .finite(finite):
            return .finite(finite.configuration)
        }
    }

    static func radialWire(
        _ configuration: SymmetryDocumentConfiguration
    ) -> RadialWire? {
        guard case let .finite(.radial(radial)) = configuration else {
            return nil
        }
        return RadialWire(
            kind: radial.kind.rawValue,
            rayCount: radial.rayCount,
            centerX: radial.center.x,
            centerY: radial.center.y,
            referenceAngleRadians: radial.referenceAngleRadians
        )
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        do {
            return try encoder.encode(value)
        } catch {
            throw PatternProjectLoadError.invalidDocumentMetadata
        }
    }

    static func decodeJSON<T: Decodable>(
        _ data: Data,
        path: String
    ) throws -> T {
        guard data.count <= maximumMetadataBytesPerFile else {
            throw PatternProjectLoadError.metadataTooLarge(
                path: path,
                actual: data.count,
                maximum: maximumMetadataBytesPerFile
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PatternProjectLoadError.invalidJSON(path: path)
        }
    }

    static func requireCurrentSchema(_ manifestData: Data) throws {
        let envelope: ManifestVersionEnvelope = try decodeJSON(
            manifestData,
            path: PatternProjectFormat.manifestPath
        )
        guard envelope.schemaVersion
                == PatternProjectFormat.currentSchemaVersion
        else {
            throw PatternProjectLoadError.unsupportedSchema(
                envelope.schemaVersion
            )
        }
    }
}

private struct ManifestVersionEnvelope: Decodable {
    let schemaVersion: Int
}

private struct ManifestWire: Codable {
    let schemaVersion: Int
    let canonicalSurfaceLayoutVersion: Int
    let documentID: UUID
    let title: String
    let appVersion: String
    let createdAt: TimeInterval
    let modifiedAt: TimeInterval
    let canvasWidth: Int
    let canvasHeight: Int
    let viewport: ViewportWire
    let activeLayerID: UUID
    let layerFiles: [String]
}

private struct ViewportWire: Codable {
    let scale: Float
    let offsetX: Float
    let offsetY: Float

    init(_ value: PatternProjectViewport) {
        scale = value.scale
        offsetX = value.offsetX
        offsetY = value.offsetY
    }

    var value: PatternProjectViewport {
        PatternProjectViewport(
            scale: scale,
            offsetX: offsetX,
            offsetY: offsetY
        )
    }
}

private struct SymmetryWire: Codable {
    let domain: UInt32
    let preset: UInt32
    let periodic: PeriodicWire?
    let radial: RadialWire?
    let documentDomainLocked: Bool
    let radialGeometryLocked: Bool
    let rasterMetric: RasterMetricWire
}

private struct PeriodicWire: Codable {
    let repeatWidth: Float
    let repeatHeight: Float
    let orientationRadians: Float
}

private struct RadialWire: Codable {
    let kind: UInt32
    let rayCount: Int
    let centerX: Float
    let centerY: Float
    let referenceAngleRadians: Float
}

private struct RasterMetricWire: Codable {
    let worldToRaster: AffineWire
    let rasterToWorld: AffineWire

    init(_ metric: RasterMetric2D) {
        worldToRaster = AffineWire(metric.worldToRaster)
        rasterToWorld = AffineWire(metric.rasterToWorld)
    }

    func matches(_ metric: RasterMetric2D) -> Bool {
        worldToRaster.matches(metric.worldToRaster)
            && rasterToWorld.matches(metric.rasterToWorld)
    }
}

private struct AffineWire: Codable {
    let xAxisX: Float
    let xAxisY: Float
    let yAxisX: Float
    let yAxisY: Float
    let translationX: Float
    let translationY: Float

    init(_ affine: Affine2D) {
        xAxisX = affine.xAxis.x
        xAxisY = affine.xAxis.y
        yAxisX = affine.yAxis.x
        yAxisY = affine.yAxis.y
        translationX = affine.translation.x
        translationY = affine.translation.y
    }

    func matches(_ affine: Affine2D) -> Bool {
        approximatelyEqual(xAxisX, affine.xAxis.x)
            && approximatelyEqual(xAxisY, affine.xAxis.y)
            && approximatelyEqual(yAxisX, affine.yAxis.x)
            && approximatelyEqual(yAxisY, affine.yAxis.y)
            && approximatelyEqual(translationX, affine.translation.x)
            && approximatelyEqual(translationY, affine.translation.y)
    }

    private func approximatelyEqual(_ lhs: Float, _ rhs: Float) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        return abs(lhs - rhs) <= max(1, abs(rhs)) * 1e-5
    }
}

private struct LayerWire: Codable {
    let id: UUID
    let kind: UInt32
    let name: String
    let order: Int
    let opacity: Float
    let blendMode: UInt32
    let isVisible: Bool
    let isLocked: Bool
    let originX: Float?
    let originY: Float?
    let paintTileSurfaceManifestFile: String
}
