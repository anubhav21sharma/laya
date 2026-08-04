import CryptoKit
import Foundation
import PatternEngine
import PatternFile
import Testing

@Suite("Stage D project baseline contracts")
struct StageDProjectBaselineTests {
    @Test
    func legacyArchivesDecodeAndReencodeDeterministically() throws {
        for fixture in stageDProjectArchives {
            let archiveHash = try fixture.archiveSHA256()
            #expect(archiveHash == fixture.inputSHA256, Comment(rawValue: fixture.name))

            let decoded = try PatternProjectPackageCodec.open(fixture.archive)
            #expect(decoded.metadata.sourceSchemaVersion == fixture.schemaVersion)
            #expect(decoded.rastersByPath == fixture.expectedRasters)

            let reencoded = try PatternProjectPackageCodec.encode(
                metadata: decoded.metadata.metadata,
                rastersByPath: decoded.rastersByPath
            )
            let reencodedHash = try stageDSHA256(reencoded)
            #expect(reencodedHash == fixture.reencodedSHA256, Comment(rawValue: fixture.name))
            let repeated = try PatternProjectPackageCodec.encode(
                metadata: decoded.metadata.metadata,
                rastersByPath: decoded.rastersByPath
            )
            #expect(reencoded == repeated)
        }
    }
}

private struct StageDProjectArchiveFixture: Sendable {
    let name: String
    let schemaVersion: Int
    let archive: Data
    let expectedRasters: [String: PatternRasterImage]
    let inputSHA256: String
    let reencodedSHA256: String

    func archiveSHA256() throws -> String { try stageDSHA256(archive) }
}

private let stageDProjectArchives: [StageDProjectArchiveFixture] = try! {
    [
        try stageDLegacySingleRasterArchive(),
        try stageDSchemaTwoLayerMetadataArchive(),
        try stageDSchemaThreeRadialArchive(),
    ]
}()

private func stageDLegacySingleRasterArchive() throws -> StageDProjectArchiveFixture {
    let documentID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let layerID = "11111111-2222-3333-4444-555555555555"
    let layerPath = "layers/\(layerID).json"
    let rasterPath = "rasters/\(layerID).png"
    let raster = try stageDRaster(
        PixelSize(width: 64, height: 64),
        bytes: stageDPatternBytes(pixelCount: 64 * 64)
    )
    let entries: [String: Data] = [
        "manifest.json": try stageDJSON([
            "schemaVersion": 1, "documentID": documentID, "title": "Stage D v1", "appVersion": "0.0.9",
            "createdAt": 1_700_000_000.0, "modifiedAt": 1_700_000_100.0, "canvasWidth": 64, "canvasHeight": 64,
            "viewport": ["scale": 1.0, "offsetX": 0.0, "offsetY": 0.0], "activeLayerID": layerID, "layerFiles": [layerPath],
        ]),
        "tiling.json": try stageDJSON(["type": 0]),
        layerPath: try stageDJSON([
            "id": layerID, "kind": 0, "name": "Transparent raster", "order": 0, "opacity": 1.0,
            "blendMode": 0, "isVisible": true, "isLocked": false, "rasterFile": rasterPath,
        ]),
        rasterPath: try PatternRasterPNGCodec.encode(raster),
    ]
    return StageDProjectArchiveFixture(
        name: "schema-v1-single-transparent-raster", schemaVersion: 1,
        archive: try PatternProjectArchiveCodec.encode(entries: entries),
        expectedRasters: [rasterPath: raster],
        inputSHA256: "0d670938b2b95253f8dc3147833b2497b07ba5838d218a08de51f292915ba894",
        reencodedSHA256: "1c04150a60fc56e34cea2ca3fc0ebc1ebc463e06125d0e0300e88580de74c97a"
    )
}

private func stageDSchemaTwoLayerMetadataArchive() throws -> StageDProjectArchiveFixture {
    let (metadata, rasters) = try stageDPeriodicMetadata(twoLayers: true)
    let files = try PatternProjectMetadataCodec.encode(metadata)
    var entries = try stageDEntries(files)
    entries["manifest.json"] = try stageDMutateJSON(entries["manifest.json"]!) {
        $0["schemaVersion"] = 2
    }
    entries["tiling.json"] = try stageDMutateJSON(entries["tiling.json"]!) {
        $0.removeValue(forKey: "documentDomainLocked")
    }
    for (path, raster) in rasters { entries[path] = try PatternRasterPNGCodec.encode(raster) }
    return StageDProjectArchiveFixture(
        name: "schema-v2-layer-metadata", schemaVersion: 2,
        archive: try PatternProjectArchiveCodec.encode(entries: entries), expectedRasters: rasters,
        inputSHA256: "c1904ed355876513cd9a461a13dd3e70c15929dcc6b95437c28552240ad4c0cf",
        reencodedSHA256: "cbde346d978c422c19c183aef2467d72393393414f2359b7f0fac92a81730950"
    )
}

private func stageDSchemaThreeRadialArchive() throws -> StageDProjectArchiveFixture {
    let (metadata, rasters) = try stageDRadialMetadata()
    return StageDProjectArchiveFixture(
        name: "schema-v3-radial-pages", schemaVersion: 3,
        archive: try PatternProjectPackageCodec.encode(metadata: metadata, rastersByPath: rasters),
        expectedRasters: rasters,
        inputSHA256: "21b573da781e279c85559fd6d348a3faa38fdc48b8b98e62f549d1f06817e7ec",
        reencodedSHA256: "21b573da781e279c85559fd6d348a3faa38fdc48b8b98e62f549d1f06817e7ec"
    )
}

private func stageDPeriodicMetadata(twoLayers: Bool) throws -> (PatternProjectMetadata, [String: PatternRasterImage]) {
    let size = PixelSize(width: 64, height: 64)
    let primary = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let secondary = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let firstPath = "rasters/first.png"
    let secondPath = "rasters/second.png"
    let first = try stageDRaster(size, bytes: stageDPatternBytes(pixelCount: 64 * 64))
    let second = try stageDRaster(size, bytes: stageDPatternBytes(pixelCount: 64 * 64, offset: 2))
    let layers = [
        PatternProjectLayer(id: primary, name: "Ink", order: 0, opacity: 0.75, blendMode: .multiply, isVisible: true, isLocked: false, surface: .singleRaster(.init(file: firstPath, pixelSize: size))),
    ] + (twoLayers ? [PatternProjectLayer(id: secondary, name: "Highlights", order: 1, opacity: 0.5, blendMode: .screen, isVisible: false, isLocked: true, surface: .singleRaster(.init(file: secondPath, pixelSize: size)))] : [])
    return (PatternProjectMetadata(
        documentID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!, title: "Stage D periodic", appVersion: "0.1.0",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), modifiedAt: Date(timeIntervalSince1970: 1_700_000_100), canvasSize: size,
        viewport: .init(scale: 1.25, offsetX: -3, offsetY: 5),
        documentConfiguration: .periodic(.legacy(presetID: .grid, tileSize: .init(width: 64, height: 64))),
        radialGeometryLocked: false, activeLayerID: primary, layers: layers
    ), twoLayers ? [firstPath: first, secondPath: second] : [firstPath: first])
}

private func stageDRadialMetadata() throws -> (PatternProjectMetadata, [String: PatternRasterImage]) {
    let size = PixelSize(width: 512, height: 512)
    let layerID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
    let configuration: SymmetryDocumentConfiguration = .finite(.radial(.init(kind: .mandala, rayCount: 5, center: .init(x: 256, y: 256), referenceAngleRadians: 0.25)))
    let compiled = try SymmetryDescriptorCompiler.compile(documentConfiguration: configuration, canvasSize: size)
    let pages = try #require(compiled.domain.finite?.radial.layout?.residentPages.prefix(2))
    let mappedPages = pages.map { page -> PatternProjectRadialPage in
        PatternProjectRadialPage(coordinate: page.coordinate, file: "rasters/radial/\(page.coordinate.x)-\(page.coordinate.y).png")
    }
    let rasters = try Dictionary(uniqueKeysWithValues: mappedPages.enumerated().map { index, page in
        (page.file, try stageDRaster(.init(width: RadialSectorLayout.pageSide, height: RadialSectorLayout.pageSide), bytes: stageDRepeatingBytes(seed: UInt8(12 + index))))
    })
    return (PatternProjectMetadata(
        documentID: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!, title: "Stage D radial", appVersion: "0.1.0",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), modifiedAt: Date(timeIntervalSince1970: 1_700_000_100), canvasSize: size,
        viewport: .init(scale: 1, offsetX: 0, offsetY: 0), documentConfiguration: configuration, radialGeometryLocked: true,
        activeLayerID: layerID, layers: [.init(id: layerID, name: "Radial", order: 0, surface: .radialPages(.init(manifestFile: "rasters/radial/surface.json", pages: mappedPages)))]
    ), rasters)
}

private func stageDRaster(_ size: PixelSize, bytes: [UInt8]) throws -> PatternRasterImage {
    try PatternRasterImage(pixelSize: size, bgra8PremultipliedBytes: bytes)
}

private func stageDRepeatingBytes(seed: UInt8) -> [UInt8] {
    (0..<(RadialSectorLayout.pageSide * RadialSectorLayout.pageSide)).flatMap { index in
        let value = UInt8(truncatingIfNeeded: index) &+ seed
        return [value / 2, value / 3, value / 4, 255]
    }
}

private func stageDPatternBytes(pixelCount: Int, offset: UInt8 = 0) -> [UInt8] {
    let pattern: [[UInt8]] = [
        [0, 0, 0, 0], [32, 64, 128, 128], [255, 0, 255, 255],
        [12, 180, 224, 224], [16, 32, 64, 96], [24, 48, 96, 160],
    ]
    return (0..<pixelCount).flatMap { index in
        pattern[(index + Int(offset)) % pattern.count]
    }
}

private func stageDEntries(_ files: PatternProjectMetadataFiles) throws -> [String: Data] {
    var entries = ["manifest.json": files.manifest, "tiling.json": files.symmetry]
    entries.merge(files.layersByPath) { _, new in new }
    entries.merge(files.surfacesByPath) { _, new in new }
    return entries
}

private func stageDJSON(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

private func stageDMutateJSON(_ data: Data, _ mutation: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    mutation(&object)
    return try stageDJSON(object)
}

private func stageDSHA256(_ data: Data) throws -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
