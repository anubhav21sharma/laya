import Foundation
import PatternEngine
import PatternFile
import Testing

@Suite("Pattern project package codec")
struct PatternProjectPackageCodecTests {
    @Test
    func periodicPackageRoundTripsMetadataPixelsAndAdvisoryFiles()
        throws
    {
        let (metadata, rasters) = try packageFixture(radial: false)
        let thumbnail = try opaqueImage(
            PixelSize(width: 16, height: 12),
            salt: 19
        )
        let palette = Data(
            ##"{"colors":["#112233","#abcdef"]}"##.utf8
        )

        let encoded = try PatternProjectPackageCodec.encode(
            metadata: metadata,
            rastersByPath: rasters,
            thumbnail: thumbnail,
            projectPaletteJSON: palette
        )
        let decoded = try PatternProjectPackageCodec.open(encoded)

        #expect(decoded.metadata.metadata == metadata)
        #expect(decoded.rastersByPath == rasters)
        #expect(decoded.thumbnail == thumbnail)
        #expect(decoded.projectPaletteJSON == palette)
    }

    @Test
    func radialSparsePagePackageRoundTripsExactPageBytes() throws {
        let (metadata, rasters) = try packageFixture(radial: true)
        let encoded = try PatternProjectPackageCodec.encode(
            metadata: metadata,
            rastersByPath: rasters
        )
        let decoded = try PatternProjectPackageCodec.open(encoded)

        #expect(decoded.metadata.metadata == metadata)
        #expect(decoded.rastersByPath == rasters)
        #expect(decoded.metadata.metadata.radialGeometryLocked)
    }

    @Test
    func legacyPackageMigratesAndDecodesItsRaster() throws {
        let raster = try opaqueImage(
            PixelSize(width: 64, height: 64),
            salt: 7
        )
        let encodedRaster = try PatternRasterPNGCodec.encode(raster)
        let layerID = "11111111-2222-3333-4444-555555555555"
        let layerPath = "layers/\(layerID).json"
        let rasterPath = "rasters/\(layerID).png"
        let entries: [String: Data] = [
            "manifest.json": try jsonData([
                "schemaVersion": 1,
                "documentID":
                    "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "title": "Legacy",
                "appVersion": "0.0.9",
                "createdAt": 1_700_000_000.0,
                "modifiedAt": 1_700_000_100.0,
                "canvasWidth": 64,
                "canvasHeight": 64,
                "viewport": [
                    "scale": 1.0,
                    "offsetX": 0.0,
                    "offsetY": 0.0,
                ],
                "activeLayerID": layerID,
                "layerFiles": [layerPath],
            ]),
            "tiling.json": try jsonData(["type": 6]),
            layerPath: try jsonData([
                "id": layerID,
                "kind": 0,
                "name": "Layer 1",
                "order": 0,
                "opacity": 1.0,
                "blendMode": 0,
                "isVisible": true,
                "isLocked": false,
                "rasterFile": rasterPath,
            ]),
            rasterPath: encodedRaster,
        ]
        let archive = try PatternProjectArchiveCodec.encode(entries: entries)

        let decoded = try PatternProjectPackageCodec.open(archive)

        #expect(decoded.metadata.wasMigrated)
        #expect(decoded.metadata.compiledSymmetry.presetID == .rotational)
        #expect(decoded.rastersByPath[rasterPath] == raster)
    }

    @Test
    func invalidMetadataWinsBeforeRasterDecode() throws {
        let (metadata, rasters) = try packageFixture(radial: false)
        let encoded = try PatternProjectPackageCodec.encode(
            metadata: metadata,
            rastersByPath: rasters
        )
        let archive = try PatternProjectArchiveCodec.open(encoded)
        var entries = try archiveEntries(archive)
        entries["tiling.json"] = try mutateObject(
            try #require(entries["tiling.json"])
        ) {
            $0["preset"] = 999
        }
        entries["rasters/layer.png"] = Data("not a PNG".utf8)
        let corrupt = try PatternProjectArchiveCodec.encode(entries: entries)

        #expect(
            throws: PatternProjectFileError.metadata(.unknownPreset(999))
        ) {
            try PatternProjectPackageCodec.open(corrupt)
        }
    }

    @Test
    func missingUnexpectedAndWrongSizedRastersFailTyped() throws {
        let (metadata, rasters) = try packageFixture(radial: false)
        #expect(
            throws: PatternProjectFileError.missingRaster(
                "rasters/layer.png"
            )
        ) {
            try PatternProjectPackageCodec.encode(
                metadata: metadata,
                rastersByPath: [:]
            )
        }
        var unexpected = rasters
        unexpected["rasters/extra.png"] = try opaqueImage(
            PixelSize(width: 64, height: 64),
            salt: 1
        )
        #expect(
            throws: PatternProjectFileError.unexpectedRaster(
                "rasters/extra.png"
            )
        ) {
            try PatternProjectPackageCodec.encode(
                metadata: metadata,
                rastersByPath: unexpected
            )
        }

        let metadataFiles = try PatternProjectMetadataCodec.encode(metadata)
        var entries: [String: Data] = [
            "manifest.json": metadataFiles.manifest,
            "tiling.json": metadataFiles.symmetry,
        ]
        for (path, data) in metadataFiles.layersByPath {
            entries[path] = data
        }
        entries["rasters/layer.png"] = try PatternRasterPNGCodec.encode(
            opaqueImage(PixelSize(width: 32, height: 32), salt: 3)
        )
        let wrongSize = try PatternProjectArchiveCodec.encode(
            entries: entries
        )
        #expect(
            throws: PatternProjectFileError.raster(
                path: "rasters/layer.png",
                error: .unexpectedDimensions(
                    expected: PixelSize(width: 64, height: 64),
                    actualWidth: 32,
                    actualHeight: 32
                )
            )
        ) {
            try PatternProjectPackageCodec.open(wrongSize)
        }
    }

    @Test
    func undeclaredArchiveEntriesAndInvalidPaletteFailClosed() throws {
        let (metadata, rasters) = try packageFixture(radial: false)
        let encoded = try PatternProjectPackageCodec.encode(
            metadata: metadata,
            rastersByPath: rasters
        )
        let archive = try PatternProjectArchiveCodec.open(encoded)
        var entries = try archiveEntries(archive)
        entries["rasters/stale-page.png"] = Data()
        let stale = try PatternProjectArchiveCodec.encode(entries: entries)
        #expect(
            throws: PatternProjectFileError.unexpectedArchiveEntry(
                "rasters/stale-page.png"
            )
        ) {
            try PatternProjectPackageCodec.open(stale)
        }

        entries.removeValue(forKey: "rasters/stale-page.png")
        entries[PatternProjectPackageCodec.palettePath] =
            Data("invalid json".utf8)
        let invalidPalette = try PatternProjectArchiveCodec.encode(
            entries: entries
        )
        #expect(throws: PatternProjectFileError.invalidPalette) {
            try PatternProjectPackageCodec.open(invalidPalette)
        }
    }
}

private func packageFixture(
    radial: Bool
) throws -> (
    metadata: PatternProjectMetadata,
    rasters: [String: PatternRasterImage]
) {
    let canvasSize = PixelSize(width: 64, height: 64)
    let documentID = UUID(
        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )!
    let layerID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!
    let configuration: SymmetryDocumentConfiguration
    let surface: PatternProjectLayerSurface
    var rasters: [String: PatternRasterImage] = [:]
    if radial {
        configuration = .finite(.radial(RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 5,
            center: WorldPoint(x: 31, y: 29),
            referenceAngleRadians: 0.25
        )))
        let compiled = try SymmetryDescriptorCompiler.compile(
            documentConfiguration: configuration,
            canvasSize: canvasSize
        )
        let layout = try #require(compiled.domain.finite?.radial.layout)
        let page = try #require(layout.residentPages.first)
        let pagePath = "rasters/layer/page-\(page.coordinate.x)-\(page.coordinate.y).png"
        surface = .radialPages(PatternProjectRadialSurface(
            manifestFile: "rasters/layer/surface.json",
            pages: [
                PatternProjectRadialPage(
                    coordinate: page.coordinate,
                    file: pagePath
                ),
            ]
        ))
        rasters[pagePath] = try opaqueImage(
            PixelSize(
                width: RadialSectorLayout.pageSide,
                height: RadialSectorLayout.pageSide
            ),
            salt: 11
        )
    } else {
        configuration = .periodic(.legacy(
            presetID: .grid,
            tileSize: PatternSize(width: 64, height: 64)
        ))
        surface = .singleRaster(PatternProjectRasterReference(
            file: "rasters/layer.png",
            pixelSize: canvasSize
        ))
        rasters["rasters/layer.png"] = try opaqueImage(
            canvasSize,
            salt: 5
        )
    }
    let metadata = PatternProjectMetadata(
        documentID: documentID,
        title: "Package",
        appVersion: "0.1.0",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
        canvasSize: canvasSize,
        viewport: PatternProjectViewport(
            scale: 1,
            offsetX: 0,
            offsetY: 0
        ),
        documentConfiguration: configuration,
        radialGeometryLocked: radial,
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
    return (metadata, rasters)
}

private func opaqueImage(
    _ size: PixelSize,
    salt: UInt8
) throws -> PatternRasterImage {
    var bytes = [UInt8]()
    bytes.reserveCapacity(size.width * size.height * 4)
    for index in 0..<(size.width * size.height) {
        let value = UInt8(truncatingIfNeeded: index) &+ salt
        bytes.append(value)
        bytes.append(value &* 3)
        bytes.append(value &* 7)
        bytes.append(255)
    }
    return try PatternRasterImage(
        pixelSize: size,
        bgra8PremultipliedBytes: bytes
    )
}

private func archiveEntries(
    _ archive: PatternProjectArchive
) throws -> [String: Data] {
    try Dictionary(uniqueKeysWithValues: archive.paths.map {
        ($0, try archive.data(for: $0))
    })
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func mutateObject(
    _ data: Data,
    mutation: (inout [String: Any]) -> Void
) throws -> Data {
    var object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    mutation(&object)
    return try jsonData(object)
}
