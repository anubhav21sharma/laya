import Foundation
import PatternEngine

public enum PatternProjectMetadataCodec {
    public static let maximumMetadataBytesPerFile = 1_048_576
    public static let maximumLayerCount = 256

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
            radialGeometryLocked: metadata.radialGeometryLocked,
            rasterMetric: RasterMetricWire(compiled.rasterMetric)
        )

        var layersByPath: [String: Data] = [:]
        var surfacesByPath: [String: Data] = [:]
        for (layer, path) in zip(orderedLayers, layerPaths) {
            let layerWire: LayerWire
            switch layer.surface {
            case let .singleRaster(raster):
                layerWire = LayerWire(
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
                    surfaceKind: SurfaceKindWire.single.rawValue,
                    rasterFile: raster.file,
                    rasterWidth: raster.pixelSize.width,
                    rasterHeight: raster.pixelSize.height,
                    radialSurfaceManifestFile: nil
                )
            case let .radialPages(surface):
                layerWire = LayerWire(
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
                    surfaceKind: SurfaceKindWire.radialPages.rawValue,
                    rasterFile: nil,
                    rasterWidth: nil,
                    rasterHeight: nil,
                    radialSurfaceManifestFile: surface.manifestFile
                )
                let surfaceWire = RadialSurfaceWire(
                    layoutVersion: surface.layoutVersion,
                    pageSide: surface.pageSide,
                    pages: surface.pages.sorted {
                        if $0.coordinate == $1.coordinate {
                            return $0.file < $1.file
                        }
                        return $0.coordinate < $1.coordinate
                    }.map {
                        RadialPageWire(
                            x: $0.coordinate.x,
                            y: $0.coordinate.y,
                            file: $0.file
                        )
                    }
                )
                surfacesByPath[surface.manifestFile] =
                    try encodeJSON(surfaceWire)
            }
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
        let manifest: ManifestWire = try decodeJSON(
            files.manifest,
            path: PatternProjectFormat.manifestPath
        )
        switch manifest.schemaVersion {
        case PatternProjectFormat.legacySchemaVersion:
            return try decodeLegacy(manifest: manifest, files: files)
        case PatternProjectFormat.currentSchemaVersion:
            return try decodeCurrent(manifest: manifest, files: files)
        default:
            throw PatternProjectLoadError.unsupportedSchema(
                manifest.schemaVersion
            )
        }
    }

    public static func decode(
        from archive: PatternProjectArchive
    ) throws -> ValidatedPatternProjectMetadata {
        try decode(metadataFiles(from: archive))
    }

    static func extractedMetadataFiles(
        from archive: PatternProjectArchive
    ) throws -> PatternProjectMetadataFiles {
        try metadataFiles(from: archive)
    }
}

private extension PatternProjectMetadataCodec {
    static func metadataFiles(
        from archive: PatternProjectArchive
    ) throws -> PatternProjectMetadataFiles {
        let manifestData = try archive.data(
            for: PatternProjectFormat.manifestPath
        )
        let manifest: ManifestWire = try decodeJSON(
            manifestData,
            path: PatternProjectFormat.manifestPath
        )
        guard manifest.schemaVersion
                == PatternProjectFormat.legacySchemaVersion
                || manifest.schemaVersion
                    == PatternProjectFormat.currentSchemaVersion
        else {
            throw PatternProjectLoadError.unsupportedSchema(
                manifest.schemaVersion
            )
        }
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
            let layerData: Data
            do {
                layerData = try archive.data(for: path)
            } catch PatternProjectArchiveError.missingEntry {
                throw PatternProjectLoadError.missingMetadata(path)
            }
            layersByPath[path] = layerData
            if manifest.schemaVersion
                == PatternProjectFormat.currentSchemaVersion
            {
                let layer: LayerWire = try decodeJSON(
                    layerData,
                    path: path
                )
                if layer.surfaceKind
                    == SurfaceKindWire.radialPages.rawValue
                {
                    guard let surfacePath =
                        layer.radialSurfaceManifestFile
                    else {
                        throw PatternProjectLoadError.invalidLayer(layer.id)
                    }
                    try validateResourcePath(surfacePath)
                    guard !reservedArchivePaths.contains(surfacePath),
                          !manifest.layerFiles.contains(surfacePath)
                    else {
                        throw PatternProjectLoadError
                            .resourcePathCollision(surfacePath)
                    }
                    if surfacesByPath[surfacePath] == nil {
                        do {
                            surfacesByPath[surfacePath] =
                                try archive.data(for: surfacePath)
                        } catch PatternProjectArchiveError.missingEntry {
                            throw PatternProjectLoadError.missingMetadata(
                                surfacePath
                            )
                        }
                    }
                }
            }
        }
        let symmetry: Data
        do {
            symmetry = try archive.data(
                for: PatternProjectFormat.symmetryPath
            )
        } catch PatternProjectArchiveError.missingEntry {
            throw PatternProjectLoadError.missingMetadata(
                PatternProjectFormat.symmetryPath
            )
        }
        return PatternProjectMetadataFiles(
            manifest: manifestData,
            symmetry: symmetry,
            layersByPath: layersByPath,
            surfacesByPath: surfacesByPath
        )
    }

    static func decodeLegacy(
        manifest: ManifestWire,
        files: PatternProjectMetadataFiles
    ) throws -> ValidatedPatternProjectMetadata {
        let canvasSize = try validateManifest(manifest, legacy: true)
        let legacy: LegacySymmetryWire = try decodeJSON(
            files.symmetry,
            path: PatternProjectFormat.symmetryPath
        )
        guard legacy.type <= SymmetryPresetID.rotational.rawValue,
              let preset = SymmetryPresetID(rawValue: legacy.type)
        else {
            throw PatternProjectLoadError.legacyPresetUnsupported(legacy.type)
        }
        let configuration = SymmetryDocumentConfiguration.periodic(
            .legacy(
                presetID: preset,
                tileSize: PatternSize(
                    width: Float(canvasSize.width),
                    height: Float(canvasSize.height)
                )
            )
        )
        let layers = try decodeLayers(
            manifest: manifest,
            files: files,
            canvasSize: canvasSize,
            compiled: compile(configuration, canvasSize: canvasSize),
            schemaVersion: PatternProjectFormat.legacySchemaVersion
        )
        let metadata = try makeMetadata(
            manifest: manifest,
            canvasSize: canvasSize,
            configuration: configuration,
            radialGeometryLocked: false,
            layers: layers
        )
        let compiled = try validate(metadata)
        return ValidatedPatternProjectMetadata(
            sourceSchemaVersion: PatternProjectFormat.legacySchemaVersion,
            metadata: metadata,
            compiledSymmetry: compiled
        )
    }

    static func decodeCurrent(
        manifest: ManifestWire,
        files: PatternProjectMetadataFiles
    ) throws -> ValidatedPatternProjectMetadata {
        guard manifest.canonicalSurfaceLayoutVersion
            == PatternProjectFormat.canonicalSurfaceLayoutVersion
        else {
            throw PatternProjectLoadError.unsupportedSurfaceLayout(
                manifest.canonicalSurfaceLayoutVersion ?? -1
            )
        }
        let canvasSize = try validateManifest(manifest, legacy: false)
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
            files: files,
            canvasSize: canvasSize,
            compiled: compiled,
            schemaVersion: PatternProjectFormat.currentSchemaVersion
        )
        let metadata = try makeMetadata(
            manifest: manifest,
            canvasSize: canvasSize,
            configuration: configuration,
            radialGeometryLocked: symmetry.radialGeometryLocked,
            layers: layers
        )
        _ = try validate(metadata)
        return ValidatedPatternProjectMetadata(
            sourceSchemaVersion: PatternProjectFormat.currentSchemaVersion,
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
        switch metadata.documentConfiguration {
        case .periodic, .finite(.plain):
            guard !metadata.radialGeometryLocked else {
                throw PatternProjectLoadError.symmetryConfigurationMismatch
            }
        case .finite(.radial):
            break
        }
        try validateLayers(
            metadata.layers,
            activeLayerID: metadata.activeLayerID,
            canvasSize: metadata.canvasSize,
            compiled: compiled
        )
        return compiled
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
        files: PatternProjectMetadataFiles,
        canvasSize: PixelSize,
        compiled: CompiledSymmetry,
        schemaVersion: Int
    ) throws -> [PatternProjectLayer] {
        guard (1...maximumLayerCount).contains(manifest.layerFiles.count)
        else {
            throw PatternProjectLoadError.layerCountOutOfRange(
                manifest.layerFiles.count
            )
        }
        var layers: [PatternProjectLayer] = []
        layers.reserveCapacity(manifest.layerFiles.count)
        var expectedIDs = Set<UUID>()
        for path in manifest.layerFiles {
            try validateResourcePath(path)
            guard let data = files.layersByPath[path] else {
                throw PatternProjectLoadError.missingMetadata(path)
            }
            let wire: LayerWire = try decodeJSON(data, path: path)
            guard expectedIDs.insert(wire.id).inserted else {
                throw PatternProjectLoadError.duplicateLayerID(wire.id)
            }
            let layer = try decodeLayer(
                wire,
                files: files,
                canvasSize: canvasSize,
                compiled: compiled,
                schemaVersion: schemaVersion
            )
            layers.append(layer)
        }
        let metadataPaths = Set(manifest.layerFiles).union(
            reservedArchivePaths
        )
        for layer in layers {
            for path in resourcePaths(in: layer)
                where metadataPaths.contains(path)
            {
                throw PatternProjectLoadError.resourcePathCollision(path)
            }
        }
        return layers
    }

    static func decodeLayer(
        _ wire: LayerWire,
        files: PatternProjectMetadataFiles,
        canvasSize: PixelSize,
        compiled: CompiledSymmetry,
        schemaVersion: Int
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

        let surface: PatternProjectLayerSurface
        if schemaVersion == PatternProjectFormat.legacySchemaVersion {
            guard kind == .pattern,
                  let rasterFile = wire.rasterFile
            else {
                throw PatternProjectLoadError.invalidLayer(wire.id)
            }
            try validateResourcePath(rasterFile)
            surface = .singleRaster(PatternProjectRasterReference(
                file: rasterFile,
                pixelSize: canvasSize
            ))
        } else {
            guard let rawSurfaceKind = wire.surfaceKind,
                  let surfaceKind = SurfaceKindWire(
                      rawValue: rawSurfaceKind
                  )
            else {
                throw PatternProjectLoadError.invalidLayer(wire.id)
            }
            switch surfaceKind {
            case .single:
                guard let rasterFile = wire.rasterFile,
                      let width = wire.rasterWidth,
                      let height = wire.rasterHeight
                else {
                    throw PatternProjectLoadError.invalidLayer(wire.id)
                }
                try validateResourcePath(rasterFile)
                let size = try checkedPixelSize(
                    width: width,
                    height: height,
                    layerID: wire.id
                )
                surface = .singleRaster(PatternProjectRasterReference(
                    file: rasterFile,
                    pixelSize: size
                ))
            case .radialPages:
                guard let manifestFile = wire.radialSurfaceManifestFile
                else {
                    throw PatternProjectLoadError.invalidLayer(wire.id)
                }
                try validateResourcePath(manifestFile)
                guard let surfaceData = files.surfacesByPath[manifestFile]
                else {
                    throw PatternProjectLoadError.missingMetadata(
                        manifestFile
                    )
                }
                let surfaceWire: RadialSurfaceWire = try decodeJSON(
                    surfaceData,
                    path: manifestFile
                )
                let radial = try decodeRadialSurface(
                    surfaceWire,
                    manifestFile: manifestFile,
                    compiled: compiled
                )
                surface = .radialPages(radial)
            }
        }

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

    static func decodeRadialSurface(
        _ wire: RadialSurfaceWire,
        manifestFile: String,
        compiled: CompiledSymmetry
    ) throws -> PatternProjectRadialSurface {
        guard wire.layoutVersion
            == PatternProjectFormat.radialSurfaceLayoutVersion
        else {
            throw PatternProjectLoadError.unsupportedRadialSurfaceLayout(
                wire.layoutVersion
            )
        }
        guard wire.pageSide == RadialSectorLayout.pageSide else {
            throw PatternProjectLoadError.invalidRadialPageSide(
                wire.pageSide
            )
        }
        guard case let .finite(finite) = compiled.domain,
              let layout = finite.radial.layout
        else {
            throw PatternProjectLoadError.invalidSymmetryParameters
        }
        let allowed = Set(layout.residentPages.map(\.coordinate))
        var seen = Set<RadialPageCoordinate>()
        var pages: [PatternProjectRadialPage] = []
        pages.reserveCapacity(wire.pages.count)
        for page in wire.pages {
            let coordinate = RadialPageCoordinate(x: page.x, y: page.y)
            guard seen.insert(coordinate).inserted else {
                throw PatternProjectLoadError.duplicateRadialPage(coordinate)
            }
            guard allowed.contains(coordinate) else {
                throw PatternProjectLoadError.unexpectedRadialPage(
                    coordinate
                )
            }
            try validateResourcePath(page.file)
            pages.append(PatternProjectRadialPage(
                coordinate: coordinate,
                file: page.file
            ))
        }
        guard wire.pages.count <= layout.residentPages.count else {
            throw PatternProjectLoadError.radialPageCountOutOfRange(
                wire.pages.count
            )
        }
        pages.sort { $0.coordinate < $1.coordinate }
        return PatternProjectRadialSurface(
            layoutVersion: wire.layoutVersion,
            pageSide: wire.pageSide,
            manifestFile: manifestFile,
            pages: pages
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
                resourcePaths: &resourcePaths
            )
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
        resourcePaths: inout Set<String>
    ) throws {
        switch layer.surface {
        case let .singleRaster(raster):
            try validateResourcePath(raster.file)
            guard raster.pixelSize.width <= 4_096,
                  raster.pixelSize.height <= 4_096
            else {
                throw PatternProjectLoadError.invalidRasterSize(
                    layerID: layer.id,
                    width: raster.pixelSize.width,
                    height: raster.pixelSize.height
                )
            }
            guard resourcePaths.insert(raster.file).inserted else {
                throw PatternProjectLoadError.resourcePathCollision(
                    raster.file
                )
            }
            if layer.kind == .pattern {
                guard compiled.presetID != .radialMirror,
                      compiled.presetID != .radialRotation,
                      compiled.presetID != .radialMandala,
                      raster.pixelSize == canvasSize
                else {
                    throw PatternProjectLoadError.surfaceKindMismatch(
                        layer.id
                    )
                }
            }
        case let .radialPages(surface):
            guard layer.kind == .pattern,
                  compiled.presetID == .radialMirror
                    || compiled.presetID == .radialRotation
                    || compiled.presetID == .radialMandala
            else {
                throw PatternProjectLoadError.surfaceKindMismatch(layer.id)
            }
            try validateResourcePath(surface.manifestFile)
            guard resourcePaths.insert(surface.manifestFile).inserted else {
                throw PatternProjectLoadError.resourcePathCollision(
                    surface.manifestFile
                )
            }
            guard surface.layoutVersion
                    == PatternProjectFormat.radialSurfaceLayoutVersion
            else {
                throw PatternProjectLoadError.unsupportedRadialSurfaceLayout(
                    surface.layoutVersion
                )
            }
            guard surface.pageSide == RadialSectorLayout.pageSide else {
                throw PatternProjectLoadError.invalidRadialPageSide(
                    surface.pageSide
                )
            }
            guard case let .finite(finite) = compiled.domain,
                  let layout = finite.radial.layout
            else {
                throw PatternProjectLoadError.surfaceKindMismatch(layer.id)
            }
            let allowed = Set(layout.residentPages.map(\.coordinate))
            var coordinates = Set<RadialPageCoordinate>()
            for page in surface.pages {
                guard coordinates.insert(page.coordinate).inserted else {
                    throw PatternProjectLoadError.duplicateRadialPage(
                        page.coordinate
                    )
                }
                guard allowed.contains(page.coordinate) else {
                    throw PatternProjectLoadError.unexpectedRadialPage(
                        page.coordinate
                    )
                }
                try validateResourcePath(page.file)
                guard resourcePaths.insert(page.file).inserted else {
                    throw PatternProjectLoadError.resourcePathCollision(
                        page.file
                    )
                }
            }
            guard surface.pages.count <= layout.residentPages.count else {
                throw PatternProjectLoadError.radialPageCountOutOfRange(
                    surface.pages.count
                )
            }
        }
    }

    static func validateManifest(
        _ manifest: ManifestWire,
        legacy: Bool
    ) throws -> PixelSize {
        if !legacy {
            guard manifest.canonicalSurfaceLayoutVersion != nil else {
                throw PatternProjectLoadError.unsupportedSurfaceLayout(-1)
            }
        }
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
            radialGeometryLocked: radialGeometryLocked,
            activeLayerID: manifest.activeLayerID,
            layers: layers
        )
        return metadata
    }

    static func checkedPixelSize(
        width: Int,
        height: Int,
        layerID: UUID
    ) throws -> PixelSize {
        guard (1...4_096).contains(width), (1...4_096).contains(height) else {
            throw PatternProjectLoadError.invalidRasterSize(
                layerID: layerID,
                width: width,
                height: height
            )
        }
        return PixelSize(width: width, height: height)
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

    static func resourcePaths(
        in layer: PatternProjectLayer
    ) -> [String] {
        switch layer.surface {
        case let .singleRaster(raster):
            [raster.file]
        case let .radialPages(surface):
            [surface.manifestFile] + surface.pages.map(\.file)
        }
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
}

private struct ManifestWire: Codable {
    let schemaVersion: Int
    let canonicalSurfaceLayoutVersion: Int?
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

private struct LegacySymmetryWire: Codable {
    let type: UInt32
}

private struct SymmetryWire: Codable {
    let domain: UInt32
    let preset: UInt32
    let periodic: PeriodicWire?
    let radial: RadialWire?
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
    let surfaceKind: UInt32?
    let rasterFile: String?
    let rasterWidth: Int?
    let rasterHeight: Int?
    let radialSurfaceManifestFile: String?
}

private enum SurfaceKindWire: UInt32 {
    case single = 0
    case radialPages = 1
}

private struct RadialSurfaceWire: Codable {
    let layoutVersion: Int
    let pageSide: Int
    let pages: [RadialPageWire]
}

private struct RadialPageWire: Codable {
    let x: Int
    let y: Int
    let file: String
}
