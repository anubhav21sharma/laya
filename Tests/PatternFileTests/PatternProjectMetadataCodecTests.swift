import Foundation
import PatternEngine
import PatternFile
import Testing

@Suite("Pattern project metadata codec")
struct PatternProjectMetadataCodecTests {
    @Test
    func onlySchemaFourReachesManifestPayloadDecoding() throws {
        #expect(PatternProjectFormat.currentSchemaVersion == 4)
        let encoded = try PatternProjectMetadataCodec.encode(
            fixture(preset: .grid)
        )
        #expect(try jsonObject(encoded.manifest)["schemaVersion"] as? Int == 4)

        for version in [1, 2, 3, 5] {
            let files = PatternProjectMetadataFiles(
                manifest: Data("{\"schemaVersion\":\(version)}".utf8),
                symmetry: Data(repeating: 0xFF, count: 32),
                layersByPath: [
                    "layers/should-not-decode.json":
                        Data(repeating: 0xFF, count: 32),
                ]
            )
            #expect(
                throws: PatternProjectLoadError.unsupportedSchema(version)
            ) {
                try PatternProjectMetadataCodec.decode(files)
            }
        }

        let expected = try fixture(preset: .grid)
        let decoded = try PatternProjectMetadataCodec.decode(encoded)
        #expect(decoded.metadata == expected)
    }

    @Test
    func schemaFourTiledSurfaceManifestRoundTripsWithoutPNGIndirection()
        throws
    {
        let base = try fixture(preset: .grid)
        let layer = try #require(base.layers.first)
        let tiled = PatternProjectPaintTileSurface(
            manifestFile: "surfaces/layer.tiles.json",
            pixelSize: base.canvasSize,
            rasterRevision: 17,
            tiles: []
        )
        let metadata = PatternProjectMetadata(
            documentID: base.documentID,
            title: base.title,
            appVersion: base.appVersion,
            createdAt: base.createdAt,
            modifiedAt: base.modifiedAt,
            canvasSize: base.canvasSize,
            viewport: base.viewport,
            documentConfiguration: base.documentConfiguration,
            documentDomainLocked: base.documentDomainLocked,
            radialGeometryLocked: base.radialGeometryLocked,
            activeLayerID: base.activeLayerID,
            layers: [PatternProjectLayer(
                id: layer.id,
                name: layer.name,
                order: layer.order,
                surface: .paintTiles(tiled)
            )]
        )

        let files = try PatternProjectMetadataCodec.encode(metadata)
        #expect(files.surfacesByPath[tiled.manifestFile] != nil)
        let layerJSON = try jsonObject(
            try #require(files.layersByPath.values.first)
        )
        #expect(layerJSON["surfaceKind"] as? Int == 2)
        #expect(layerJSON["rasterFile"] == nil)

        let decoded = try PatternProjectMetadataCodec.decode(files)
        #expect(decoded.metadata == metadata)
    }

    @Test
    func schemaFourRadialTilesUseExactCompiledAtlasBeyondLegacyRasterLimit()
        throws
    {
        let canvasSize = PixelSize(width: 4_096, height: 4_096)
        let configuration = SymmetryDocumentConfiguration.finite(.radial(
            RadialSymmetryConfiguration(
                kind: .mirror,
                rayCount: 1,
                center: WorldPoint(x: 0, y: 0)
            )
        ))
        let compiled = try SymmetryDescriptorCompiler.compile(
            documentConfiguration: configuration,
            canvasSize: canvasSize
        )
        let atlasSize = try #require(
            compiled.domain.finite?.radial.layout?.atlasPixelSize
        )
        #expect(atlasSize.width > 4_096 || atlasSize.height > 4_096)
        #expect(atlasSize.width <= 16_384)
        #expect(atlasSize.height <= 16_384)

        let surface = PatternProjectPaintTileSurface(
            manifestFile: "surfaces/radial.tiles.json",
            pixelSize: atlasSize,
            rasterRevision: 29,
            tiles: []
        )
        let metadata = project(
            configuration: configuration,
            canvasSize: canvasSize,
            radialGeometryLocked: true,
            surface: .paintTiles(surface)
        )
        let files = try PatternProjectMetadataCodec.encode(metadata)
        let decoded = try PatternProjectMetadataCodec.decode(files)

        #expect(decoded.metadata == metadata)

        var wrongSurfaceFiles = files.surfacesByPath
        wrongSurfaceFiles[surface.manifestFile] = try mutateJSON(
            try #require(files.surfacesByPath[surface.manifestFile])
        ) {
            $0["pixelWidth"] = atlasSize.width - RadialSectorLayout.pageSide
        }
        let wrongDecoded = PatternProjectMetadataFiles(
            manifest: files.manifest,
            symmetry: files.symmetry,
            layersByPath: files.layersByPath,
            surfacesByPath: wrongSurfaceFiles
        )
        #expect(throws: PatternProjectLoadError.invalidRasterSize(
            layerID: metadata.activeLayerID,
            width: atlasSize.width - RadialSectorLayout.pageSide,
            height: atlasSize.height
        )) {
            try PatternProjectMetadataCodec.decode(wrongDecoded)
        }

        let wrongSize = PixelSize(
            width: atlasSize.width - RadialSectorLayout.pageSide,
            height: atlasSize.height
        )
        let wrong = project(
            configuration: configuration,
            canvasSize: canvasSize,
            radialGeometryLocked: true,
            surface: .paintTiles(PatternProjectPaintTileSurface(
                manifestFile: surface.manifestFile,
                pixelSize: wrongSize,
                rasterRevision: surface.rasterRevision,
                tiles: []
            ))
        )
        #expect(throws: PatternProjectLoadError.invalidRasterSize(
            layerID: wrong.activeLayerID,
            width: wrongSize.width,
            height: wrongSize.height
        )) {
            try PatternProjectMetadataCodec.encode(wrong)
        }
    }

    @Test
    func schemaFourPlainAndPeriodicTilesUseMaximumCanvasStorage() throws {
        let canvasSize = PixelSize(width: 4_096, height: 4_096)
        let configurations: [SymmetryDocumentConfiguration] = [
            .finite(.plain),
            .periodic(.legacy(
                presetID: .grid,
                tileSize: PatternSize(width: 4_096, height: 4_096)
            )),
        ]

        for (index, configuration) in configurations.enumerated() {
            let metadata = project(
                configuration: configuration,
                canvasSize: canvasSize,
                surface: .paintTiles(PatternProjectPaintTileSurface(
                    manifestFile: "surfaces/maximum-\(index).tiles.json",
                    pixelSize: canvasSize,
                    rasterRevision: UInt64(index + 1),
                    tiles: []
                ))
            )

            let files = try PatternProjectMetadataCodec.encode(metadata)
            let decoded = try PatternProjectMetadataCodec.decode(files)
            #expect(decoded.metadata == metadata)
        }
    }

    @Test
    func currentFormatRoundTripsEveryStablePreset() throws {
        for preset in SymmetryPresetID.allCases {
            let metadata = try fixture(preset: preset)
            let files = try PatternProjectMetadataCodec.encode(metadata)
            let decoded = try PatternProjectMetadataCodec.decode(files)

            #expect(
                decoded.compiledSymmetry.presetID == preset,
                "preset \(preset.rawValue)"
            )
            #expect(
                decoded.metadata.documentID == metadata.documentID,
                "preset \(preset.rawValue)"
            )
            #expect(
                decoded.metadata.layers.count == 1,
                "preset \(preset.rawValue)"
            )
        }
    }

    @Test
    func radialSparsePagesRoundTripAndMissingPagesStayImplicit() throws {
        let configuration = SymmetryDocumentConfiguration.finite(
            .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 7,
                center: WorldPoint(x: 91, y: 137),
                referenceAngleRadians: 0.37
            ))
        )
        let size = PixelSize(width: 512, height: 384)
        let compiled = try SymmetryDescriptorCompiler.compile(
            documentConfiguration: configuration,
            canvasSize: size
        )
        let layout = try #require(compiled.domain.finite?.radial.layout)
        let stored = Array(layout.residentPages.prefix(1)).map {
            PatternProjectRadialPage(
                coordinate: $0.coordinate,
                file: radialPagePath($0.coordinate)
            )
        }
        let metadata = project(
            configuration: configuration,
            canvasSize: size,
            radialGeometryLocked: true,
            surface: .radialPages(PatternProjectRadialSurface(
                manifestFile: "rasters/layer/surface.json",
                pages: stored
            ))
        )

        let decoded = try PatternProjectMetadataCodec.decode(
            PatternProjectMetadataCodec.encode(metadata)
        )
        let layer = try #require(decoded.metadata.layers.first)
        guard case let .radialPages(surface) = layer.surface else {
            Issue.record("Expected radial page storage")
            return
        }
        #expect(surface.pages == stored)
        #expect(surface.pages.count < layout.residentPages.count)
        #expect(decoded.metadata.radialGeometryLocked)
    }

    @Test
    func encodingIsCanonicalAndDeterministic() throws {
        let metadata = try fixture(preset: .kaleidoscope30)
        let first = try PatternProjectMetadataCodec.encode(metadata)
        let second = try PatternProjectMetadataCodec.encode(metadata)
        #expect(first == second)
    }

    @Test
    func encoderNormalizesAnglesThroughDescriptorCompiler() throws {
        let configuration = SymmetryDocumentConfiguration.finite(
            .radial(RadialSymmetryConfiguration(
                kind: .rotation,
                rayCount: 5,
                center: WorldPoint(x: 128, y: 128),
                referenceAngleRadians: 9 * .pi
            ))
        )
        let metadata = project(
            configuration: configuration,
            canvasSize: PixelSize(width: 256, height: 256),
            surface: try radialSurface(
                configuration: configuration,
                canvasSize: PixelSize(width: 256, height: 256)
            )
        )
        let decoded = try PatternProjectMetadataCodec.decode(
            PatternProjectMetadataCodec.encode(metadata)
        )
        guard case let .finite(.radial(radial)) =
            decoded.metadata.documentConfiguration
        else {
            Issue.record("Expected radial document")
            return
        }
        #expect(radial.referenceAngleRadians >= -.pi)
        #expect(radial.referenceAngleRadians < .pi)
    }

    @Test
    func unknownCurrentPresetFailsTyped() throws {
        let valid = try PatternProjectMetadataCodec.encode(
            fixture(preset: .grid)
        )
        let unknownPreset = PatternProjectMetadataFiles(
            manifest: valid.manifest,
            symmetry: try mutateJSON(valid.symmetry) {
                $0["preset"] = 999
            },
            layersByPath: valid.layersByPath
        )
        #expect(
            throws: PatternProjectLoadError.unknownPreset(999)
        ) {
            try PatternProjectMetadataCodec.decode(unknownPreset)
        }
    }

    @Test
    func metricTamperingFailsBeforeSurfaceAcceptance() throws {
        let valid = try PatternProjectMetadataCodec.encode(
            fixture(preset: .kaleidoscope60)
        )
        let changed = PatternProjectMetadataFiles(
            manifest: valid.manifest,
            symmetry: try mutateJSON(valid.symmetry) { root in
                var metric = root["rasterMetric"] as! [String: Any]
                var transform =
                    metric["worldToRaster"] as! [String: Any]
                transform["xAxisX"] = 47
                metric["worldToRaster"] = transform
                root["rasterMetric"] = metric
            },
            layersByPath: valid.layersByPath
        )
        #expect(throws: PatternProjectLoadError.rasterMetricMismatch) {
            try PatternProjectMetadataCodec.decode(changed)
        }
    }

    @Test
    func unsafeRasterPathIsRejected() throws {
        let valid = try PatternProjectMetadataCodec.encode(
            fixture(preset: .plainCanvas)
        )
        let layerPath = try #require(valid.layersByPath.keys.first)
        var layers = valid.layersByPath
        layers[layerPath] = try mutateJSON(
            try #require(valid.layersByPath[layerPath])
        ) {
            $0["rasterFile"] = "../outside.png"
        }
        let changed = PatternProjectMetadataFiles(
            manifest: valid.manifest,
            symmetry: valid.symmetry,
            layersByPath: layers
        )
        #expect(
            throws: PatternProjectLoadError.unsafeResourcePath(
                "../outside.png"
            )
        ) {
            try PatternProjectMetadataCodec.decode(changed)
        }

        var collidingLayers = valid.layersByPath
        collidingLayers[layerPath] = try mutateJSON(
            try #require(valid.layersByPath[layerPath])
        ) {
            $0["rasterFile"] = PatternProjectFormat.manifestPath
        }
        let colliding = PatternProjectMetadataFiles(
            manifest: valid.manifest,
            symmetry: valid.symmetry,
            layersByPath: collidingLayers
        )
        #expect(
            throws: PatternProjectLoadError.resourcePathCollision(
                PatternProjectFormat.manifestPath
            )
        ) {
            try PatternProjectMetadataCodec.decode(colliding)
        }
    }

    @Test
    func radialPagesRejectDuplicatesAndNonresidentCoordinates() throws {
        let valid = try PatternProjectMetadataCodec.encode(
            fixture(preset: .radialMandala)
        )
        let surfacePath = try #require(valid.surfacesByPath.keys.first)
        let surfaceData = try #require(valid.surfacesByPath[surfacePath])
        let root = try jsonObject(surfaceData)
        let pages = try #require(root["pages"] as? [[String: Any]])
        let first = try #require(pages.first)

        var duplicateSurfaces = valid.surfacesByPath
        duplicateSurfaces[surfacePath] = try mutateJSON(surfaceData) {
            $0["pages"] = [first, first]
        }
        let duplicate = PatternProjectMetadataFiles(
            manifest: valid.manifest,
            symmetry: valid.symmetry,
            layersByPath: valid.layersByPath,
            surfacesByPath: duplicateSurfaces
        )
        let coordinate = RadialPageCoordinate(
            x: first["x"] as! Int,
            y: first["y"] as! Int
        )
        #expect(
            throws: PatternProjectLoadError.duplicateRadialPage(coordinate)
        ) {
            try PatternProjectMetadataCodec.decode(duplicate)
        }

        var unexpectedSurfaces = valid.surfacesByPath
        unexpectedSurfaces[surfacePath] = try mutateJSON(surfaceData) {
            var page = first
            page["x"] = 1_000_000
            page["y"] = -1_000_000
            $0["pages"] = [page]
        }
        let unexpected = PatternProjectMetadataFiles(
            manifest: valid.manifest,
            symmetry: valid.symmetry,
            layersByPath: valid.layersByPath,
            surfacesByPath: unexpectedSurfaces
        )
        #expect(
            throws: PatternProjectLoadError.unexpectedRadialPage(
                RadialPageCoordinate(x: 1_000_000, y: -1_000_000)
            )
        ) {
            try PatternProjectMetadataCodec.decode(unexpected)
        }
    }

    @Test
    func incompatibleSurfaceAndInvalidRadialCostFailTyped() throws {
        let radial = SymmetryDocumentConfiguration.finite(
            .radial(RadialSymmetryConfiguration(
                kind: .rotation,
                rayCount: 7,
                center: WorldPoint(x: 128, y: 128)
            ))
        )
        let single = project(
            configuration: radial,
            canvasSize: PixelSize(width: 256, height: 256),
            surface: .singleRaster(PatternProjectRasterReference(
                file: "rasters/layer.png",
                pixelSize: PixelSize(width: 256, height: 256)
            ))
        )
        #expect(
            throws: PatternProjectLoadError.surfaceKindMismatch(
                single.activeLayerID
            )
        ) {
            try PatternProjectMetadataCodec.encode(single)
        }

        let unsupported = SymmetryDocumentConfiguration.finite(
            .radial(RadialSymmetryConfiguration(
                kind: .mandala,
                rayCount: 33,
                center: WorldPoint(x: 128, y: 128)
            ))
        )
        let invalid = project(
            configuration: unsupported,
            canvasSize: PixelSize(width: 256, height: 256),
            surface: .radialPages(PatternProjectRadialSurface(
                manifestFile: "rasters/layer/surface.json",
                pages: []
            ))
        )
        #expect(
            throws: PatternProjectLoadError.descriptorRejected(
                .unsupportedRadialRayCount(actual: 33, maximum: 32)
            )
        ) {
            try PatternProjectMetadataCodec.encode(invalid)
        }
    }

    @Test
    func invalidCanvasAndOversizedMetadataFailBeforeConfiguration() throws {
        let valid = try PatternProjectMetadataCodec.encode(
            fixture(preset: .grid)
        )
        let invalidCanvas = PatternProjectMetadataFiles(
            manifest: try mutateJSON(valid.manifest) {
                $0["canvasWidth"] = 0
            },
            symmetry: valid.symmetry,
            layersByPath: valid.layersByPath
        )
        #expect(
            throws: PatternProjectLoadError.invalidCanvasSize(
                width: 0,
                height: 256
            )
        ) {
            try PatternProjectMetadataCodec.decode(invalidCanvas)
        }

        let oversized = PatternProjectMetadataFiles(
            manifest: Data(
                repeating: 0x20,
                count:
                    PatternProjectMetadataCodec
                        .maximumMetadataBytesPerFile + 1
            ),
            symmetry: valid.symmetry,
            layersByPath: valid.layersByPath
        )
        #expect(
            throws: PatternProjectLoadError.metadataTooLarge(
                path: PatternProjectFormat.manifestPath,
                actual:
                    PatternProjectMetadataCodec
                        .maximumMetadataBytesPerFile + 1,
                maximum:
                    PatternProjectMetadataCodec
                        .maximumMetadataBytesPerFile
            )
        ) {
            try PatternProjectMetadataCodec.decode(oversized)
        }
    }
}

private func fixture(
    preset: SymmetryPresetID
) throws -> PatternProjectMetadata {
    let size = PixelSize(width: 256, height: 256)
    let configuration: SymmetryDocumentConfiguration
    switch preset {
    case .plainCanvas:
        configuration = .finite(.plain)
    case .radialMirror:
        configuration = .finite(.radial(RadialSymmetryConfiguration(
            kind: .mirror,
            rayCount: 1,
            center: WorldPoint(x: 173, y: 119),
            referenceAngleRadians: 0.17
        )))
    case .radialRotation:
        configuration = .finite(.radial(RadialSymmetryConfiguration(
            kind: .rotation,
            rayCount: 7,
            center: WorldPoint(x: 173, y: 119),
            referenceAngleRadians: 0.17
        )))
    case .radialMandala:
        configuration = .finite(.radial(RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 8,
            center: WorldPoint(x: 173, y: 119),
            referenceAngleRadians: 0.17
        )))
    case .squareRotation, .squareKaleidoscope:
        configuration = .periodic(PeriodicSymmetryConfiguration(
            presetID: preset,
            repeatSize: PatternSize(width: 192, height: 192),
            orientationRadians: 0.21
        ))
    case .hexagons, .rotation3, .rotation6, .kaleidoscope60,
         .kaleidoscope30:
        configuration = .periodic(PeriodicSymmetryConfiguration(
            presetID: preset,
            repeatSize: PatternSize(width: 256, height: 256),
            orientationRadians: -0.13
        ))
    case .grid, .halfDrop, .brick, .mirrorX, .mirrorY, .mirrorXY,
         .rotational:
        configuration = .periodic(.legacy(
            presetID: preset,
            tileSize: PatternSize(width: 256, height: 256)
        ))
    }
    let surface: PatternProjectLayerSurface
    switch configuration {
    case .finite(.radial):
        surface = try radialSurface(
            configuration: configuration,
            canvasSize: size
        )
    case .periodic, .finite(.plain):
        surface = .singleRaster(PatternProjectRasterReference(
            file: "rasters/layer.png",
            pixelSize: size
        ))
    }
    return project(
        configuration: configuration,
        canvasSize: size,
        radialGeometryLocked: preset == .radialMandala,
        surface: surface
    )
}

private func project(
    configuration: SymmetryDocumentConfiguration,
    canvasSize: PixelSize,
    radialGeometryLocked: Bool = false,
    surface: PatternProjectLayerSurface
) -> PatternProjectMetadata {
    let documentID = UUID(
        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )!
    let layerID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!
    return PatternProjectMetadata(
        documentID: documentID,
        title: "Pattern",
        appVersion: "0.1.0",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
        canvasSize: canvasSize,
        viewport: PatternProjectViewport(
            scale: 1.25,
            offsetX: -14,
            offsetY: 27
        ),
        documentConfiguration: configuration,
        documentDomainLocked: radialGeometryLocked,
        radialGeometryLocked: radialGeometryLocked,
        activeLayerID: layerID,
        layers: [
            PatternProjectLayer(
                id: layerID,
                name: "Layer 1",
                order: 0,
                surface: surface
            ),
        ]
    )
}

private func radialSurface(
    configuration: SymmetryDocumentConfiguration,
    canvasSize: PixelSize
) throws -> PatternProjectLayerSurface {
    let compiled = try SymmetryDescriptorCompiler.compile(
        documentConfiguration: configuration,
        canvasSize: canvasSize
    )
    let layout = try #require(compiled.domain.finite?.radial.layout)
    let pages = Array(layout.residentPages.prefix(2)).map {
        PatternProjectRadialPage(
            coordinate: $0.coordinate,
            file: radialPagePath($0.coordinate)
        )
    }
    return .radialPages(PatternProjectRadialSurface(
        manifestFile: "rasters/layer/surface.json",
        pages: pages
    ))
}

private func radialPagePath(_ coordinate: RadialPageCoordinate) -> String {
    "rasters/layer/page-\(coordinate.x)-\(coordinate.y).png"
}

private func mutateJSON(
    _ data: Data,
    mutation: (inout [String: Any]) throws -> Void
) throws -> Data {
    var object = try jsonObject(data)
    try mutation(&object)
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}
