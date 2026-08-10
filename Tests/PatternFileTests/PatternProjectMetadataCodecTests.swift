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
                surface: tiled
            )]
        )

        let files = try PatternProjectMetadataCodec.encode(metadata)
        #expect(files.surfacesByPath[tiled.manifestFile] != nil)
        let layerJSON = try jsonObject(
            try #require(files.layersByPath.values.first)
        )
        #expect(layerJSON["surfaceKind"] == nil)
        #expect(layerJSON["rasterFile"] == nil)
        #expect(layerJSON["radialSurfaceManifestFile"] == nil)
        #expect(
            layerJSON["paintTileSurfaceManifestFile"] as? String
                == tiled.manifestFile
        )

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
            surface: surface
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
            surface: PatternProjectPaintTileSurface(
                manifestFile: surface.manifestFile,
                pixelSize: wrongSize,
                rasterRevision: surface.rasterRevision,
                tiles: []
            )
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
                surface: PatternProjectPaintTileSurface(
                    manifestFile: "surfaces/maximum-\(index).tiles.json",
                    pixelSize: canvasSize,
                    rasterRevision: UInt64(index + 1),
                    tiles: []
                )
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
        let size = PixelSize(width: 256, height: 256)
        let compiled = try SymmetryDescriptorCompiler.compile(
            documentConfiguration: configuration,
            canvasSize: size
        )
        let metadata = project(
            configuration: configuration,
            canvasSize: size,
            surface: PatternProjectPaintTileSurface(
                manifestFile: "surfaces/layer.tiles.json",
                pixelSize: try #require(
                    compiled.domain.finite?.radial.layout?.atlasPixelSize
                ),
                rasterRevision: 0,
                tiles: []
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
    func unsafeNativeManifestPathIsRejected() throws {
        let valid = try PatternProjectMetadataCodec.encode(
            fixture(preset: .plainCanvas)
        )
        let layerPath = try #require(valid.layersByPath.keys.first)
        var layers = valid.layersByPath
        layers[layerPath] = try mutateJSON(
            try #require(valid.layersByPath[layerPath])
        ) {
            $0["paintTileSurfaceManifestFile"] = "../outside.tiles.json"
        }
        let changed = PatternProjectMetadataFiles(
            manifest: valid.manifest,
            symmetry: valid.symmetry,
            layersByPath: layers,
            surfacesByPath: valid.surfacesByPath
        )
        #expect(
            throws: PatternProjectLoadError.unsafeResourcePath(
                "../outside.tiles.json"
            )
        ) {
            try PatternProjectMetadataCodec.decode(changed)
        }

        var collidingLayers = valid.layersByPath
        collidingLayers[layerPath] = try mutateJSON(
            try #require(valid.layersByPath[layerPath])
        ) {
            $0["paintTileSurfaceManifestFile"] =
                PatternProjectFormat.manifestPath
        }
        let colliding = PatternProjectMetadataFiles(
            manifest: valid.manifest,
            symmetry: valid.symmetry,
            layersByPath: collidingLayers,
            surfacesByPath: valid.surfacesByPath
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
    func crossLayerTileIdentityIsValidatedOnceForTheWholeDocument() throws {
        let size = PixelSize(width: 256, height: 256)
        let tileID = UUID(
            uuidString: "77777777-8888-9999-aaaa-bbbbbbbbbbbb"
        )!
        let layers = [0, 1].map { order in
            let layerID = UUID(
                uuidString: order == 0
                    ? "11111111-2222-3333-4444-555555555555"
                    : "66666666-7777-8888-9999-aaaaaaaaaaaa"
            )!
            let record = PatternPaintTileRecord(
                id: tileID,
                coordinate: .init(x: 0, y: 0),
                logicalBounds: .init(
                    minX: 0,
                    minY: 0,
                    width: 256,
                    height: 256
                ),
                pixelFormat: .rgba16Float,
                byteOrder: .littleEndian,
                byteCount: PatternPaintTileCodec.bytesPerTile,
                semanticSHA256: String(repeating: "0", count: 64),
                rasterRevision: 1,
                file: "tiles/\(order).rgba16f"
            )
            return PatternProjectLayer(
                id: layerID,
                name: "Layer \(order)",
                order: order,
                surface: PatternProjectPaintTileSurface(
                    manifestFile: "surfaces/\(order).tiles.json",
                    pixelSize: size,
                    rasterRevision: 1,
                    tiles: [record]
                )
            )
        }
        let base = project(
            configuration: .finite(.plain),
            canvasSize: size,
            surface: layers[0].surface
        )
        let duplicate = replacingLayers(base, with: layers)

        #expect(throws: PatternProjectLoadError.invalidDocumentMetadata) {
            try PatternProjectMetadataCodec.encode(duplicate)
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
        let wrong = project(
            configuration: radial,
            canvasSize: PixelSize(width: 256, height: 256),
            surface: PatternProjectPaintTileSurface(
                manifestFile: "surfaces/layer.tiles.json",
                pixelSize: PixelSize(width: 64, height: 64),
                rasterRevision: 0,
                tiles: []
            )
        )
        #expect(
            throws: PatternProjectLoadError.invalidRasterSize(
                layerID: wrong.activeLayerID,
                width: 64,
                height: 64
            )
        ) {
            try PatternProjectMetadataCodec.encode(wrong)
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
            surface: PatternProjectPaintTileSurface(
                manifestFile: "surfaces/layer.tiles.json",
                pixelSize: PixelSize(width: 256, height: 256),
                rasterRevision: 0,
                tiles: []
            )
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
    let compiled = try SymmetryDescriptorCompiler.compile(
        documentConfiguration: configuration,
        canvasSize: size
    )
    let surface = PatternProjectPaintTileSurface(
        manifestFile: "surfaces/layer.tiles.json",
        pixelSize:
            compiled.domain.finite?.radial.layout?.atlasPixelSize ?? size,
        rasterRevision: 0,
        tiles: []
    )
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
    surface: PatternProjectPaintTileSurface
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

private func replacingLayers(
    _ metadata: PatternProjectMetadata,
    with layers: [PatternProjectLayer]
) -> PatternProjectMetadata {
    PatternProjectMetadata(
        documentID: metadata.documentID,
        title: metadata.title,
        appVersion: metadata.appVersion,
        createdAt: metadata.createdAt,
        modifiedAt: metadata.modifiedAt,
        canvasSize: metadata.canvasSize,
        viewport: metadata.viewport,
        documentConfiguration: metadata.documentConfiguration,
        documentDomainLocked: metadata.documentDomainLocked,
        radialGeometryLocked: metadata.radialGeometryLocked,
        activeLayerID: layers[0].id,
        layers: layers
    )
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
