import Foundation
import PatternEngine
import SafeArchive
import Testing
@testable import BrushFormat

@Test func packageRoundTripsDeterministically() throws {
    let package = try BrushFormatTestSupport.package()

    let first = try BrushPackageCodec.encode(package)
    let second = try BrushPackageCodec.encode(package)

    #expect(first == second)
    let decoded = try BrushPackageCodec.decode(first)
    #expect(decoded == package)
    #expect(try BrushPackageCodec.encode(decoded) == first)
}

@Test func resourcePathAndHashUseCanonicalContentIdentity() throws {
    let bytes = try BrushFormatTestSupport.fixturePNG()
    let resource = try BrushFormatTestSupport.resource(bytes: bytes)

    #expect(
        resource.sha256
            == "bba3504e9623c317edd949fbd508e29610c17a2266aaa333fd012032236cbb94"
    )
    #expect(resource.path == "resources/\(resource.sha256).png")
    #expect(
        BrushContentHash.sha256Hex(of: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
}

@Test func provenanceAndUnknownSupportedVersionKeysRoundTrip() throws {
    let provenance = BrushPackageProvenance(
        buildTool: "layabrush-convert",
        sourceApplication: "Test Source",
        sourceVersion: "1.2"
    )
    let package = try BrushFormatTestSupport.package(provenance: provenance)
    var entries = try BrushFormatTestSupport.archiveEntries(package)
    var manifest = String(decoding: entries["manifest.json"]!, as: UTF8.self)
    manifest.insert(
        contentsOf: "\"future\":{\"ignored\":true},",
        at: manifest.index(after: manifest.startIndex)
    )
    entries["manifest.json"] = Data(manifest.utf8)
    var definition = String(decoding: entries["definition.json"]!, as: UTF8.self)
    definition.insert(
        contentsOf: "\"futureDefinition\":{\"ignored\":true},",
        at: definition.index(after: definition.startIndex)
    )
    entries["definition.json"] = Data(definition.utf8)

    let decoded = try BrushPackageCodec.decode(
        BrushFormatTestSupport.encodeArchive(entries)
    )
    #expect(decoded.manifest.provenance == provenance)
    #expect(decoded == package)
}

@Test func semanticHashIgnoresJSONRepresentationButPinsSchema() throws {
    let package = try BrushFormatTestSupport.package()
    let expected = try package.contentHash
    #expect(expected == "f1ffa12acfe6d34d53479591cb4454fe91724ef1dfbf75d703893b9a81a2ff6c")
    var entries = try BrushFormatTestSupport.archiveEntries(package)
    var definition = try replacingRootObjectOrder(in: entries["definition.json"]!)
    var spelling = String(decoding: definition, as: UTF8.self)
    spelling = spelling.replacingOccurrences(
        of: "\"stabilization\":0",
        with: "\"stabilization\":0.0"
    )
    definition = Data(spelling.utf8)
    entries["definition.json"] = definition

    let reencoded = try BrushFormatTestSupport.encodeArchive(entries)
    let canonical = try BrushPackageCodec.encode(package)
    #expect(reencoded != canonical)
    #expect(try BrushPackageCodec.decode(reencoded).contentHash == expected)
}

@Test func semanticHashTracksEveryMajorRenderingGroupAndResource() throws {
    let package = try BrushFormatTestSupport.package()
    let base = package.definition
    let baseline = try package.contentHash
    let changedDefinitions: [BrushDefinition] = try [
        BrushFormatTestSupport.definition(
            capabilities: [BrushCapabilityDeclaration(identifier: "future.optional", required: false)]
        ),
        BrushFormatTestSupport.definition(
            metadata: BrushMetadata(displayName: "Changed", author: "A")
        ),
        BrushFormatTestSupport.definition(
            coverage: BrushCoverageDefinition(
                shapes: [
                    BrushShapeLayerDefinition(
                        shape: base.coverage.shapes[0].shape,
                        combination: .replace,
                        scale: 0.5,
                        rotation: 0,
                        offset: .zero
                    ),
                ],
                grains: [],
                baseHardness: 1,
                aspectRatio: 1,
                tipThreshold: 0,
                antialiasing: true
            )
        ),
        BrushFormatTestSupport.definition(
            placement: BrushPlacementDefinition(
                baseSpacingFraction: 0.2,
                maximumSpacingFraction: 0.2,
                baseFlow: 1,
                strokeOpacity: 1,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: .zero
            )
        ),
        BrushFormatTestSupport.definition(
            dynamics: BrushDynamicsDefinition(
                size: constantMapping(0.5),
                flow: base.dynamics.flow,
                opacity: base.dynamics.opacity,
                spacing: base.dynamics.spacing,
                rotation: base.dynamics.rotation,
                scatter: base.dynamics.scatter,
                hardness: base.dynamics.hardness,
                grain: base.dynamics.grain,
                offsetX: base.dynamics.offsetX,
                offsetY: base.dynamics.offsetY,
                hue: base.dynamics.hue,
                saturation: base.dynamics.saturation,
                brightness: base.dynamics.brightness,
                secondaryColorMix: base.dynamics.secondaryColorMix,
                noPressureNeutral: base.dynamics.noPressureNeutral,
                randomization: base.dynamics.randomization
            )
        ),
        BrushFormatTestSupport.definition(
            color: BrushColorBehaviorDefinition(
                baseAdjustment: BrushColorAdjustment(
                    redMultiplier: 0.5,
                    greenMultiplier: 1,
                    blueMultiplier: 1,
                    alphaMultiplier: 1
                ),
                perStampJitter: base.color.perStampJitter,
                perStrokeJitter: base.color.perStrokeJitter
            )
        ),
        BrushFormatTestSupport.definition(
            material: BrushMaterialDefinition(
                accumulation: base.material.accumulation,
                interaction: .none,
                edgeTreatment: base.material.edgeTreatment,
                strength: 0.5,
                wetness: base.material.wetness,
                bleedRadius: base.material.bleedRadius,
                softenPasses: base.material.softenPasses,
                accumulationLimit: base.material.accumulationLimit,
                interactionParameters: nil
            )
        ),
        BrushFormatTestSupport.definition(stabilization: 0.25),
        BrushFormatTestSupport.definition(
            taper: BrushTaperConfiguration(
                start: .worldPixels(4),
                end: .disabled,
                minimumSize: 0.5,
                minimumFlow: 1,
                effects: .size
            )
        ),
        BrushFormatTestSupport.definition(
            replayMode: .replayTail,
            replayLimits: .some(BrushRecipePolicy.replayTailLimits)
        ),
        BrushFormatTestSupport.definition(seedPolicy: .fixed(42)),
        BrushFormatTestSupport.definition(
            limits: BrushDefinitionLimits(
                minimumDiameter: 0.01,
                maximumDiameter: 8_192,
                maximumOpacity: 1,
                maximumSpacingFraction: 4,
                maximumResourceDimension: 4_096,
                maximumResidentBytes: 32 * 1_024 * 1_024
            )
        ),
        BrushFormatTestSupport.definition(performanceIntent: .quality),
        BrushFormatTestSupport.definition(
            compatibility: BrushCompatibilityMetadata(
                nativeFeatureVersion: 2,
                sourceSettingKeys: [],
                requiredSemanticKeys: []
            )
        ),
    ]

    for definition in changedDefinitions {
        let changed = try BrushPackage(
            manifest: package.manifest,
            definition: definition,
            resourceData: package.resourceData
        )
        #expect(try changed.contentHash != baseline)
    }

    var changedBytes = try BrushFormatTestSupport.fixturePNG()
    changedBytes.append(0)
    #expect(
        try BrushFormatTestSupport.package(resourceBytes: changedBytes).contentHash
            != baseline
    )
}

@Test func semanticHashExcludesPreviewAndProvenanceMetadata() throws {
    let base = try BrushFormatTestSupport.package()
    let previewBytes = Data([1, 2, 3])
    let preview = try BrushFormatTestSupport.resource(
        id: "preview.generated",
        kind: .preview,
        bytes: previewBytes
    )
    let decorated = try BrushPackage(
        manifest: BrushPackageManifest(
            resources: base.manifest.resources + [preview],
            provenance: BrushPackageProvenance(buildTool: "tool", sourceVersion: "2")
        ),
        definition: base.definition,
        resourceData: base.resourceData.merging(["preview.generated": previewBytes]) {
            _, new in new
        }
    )

    #expect(decorated != base)
    #expect(try decorated.contentHash == base.contentHash)

    let previewReference = BrushResourceReference(
        identifier: "preview.generated",
        kind: .preview,
        required: false,
        fallback: nil
    )
    let referencedDefinition = try BrushFormatTestSupport.definition(
        resources: (base.definition.resources + [previewReference]).sorted {
            $0.identifier < $1.identifier
        }
    )
    let referenced = try BrushPackage(
        manifest: decorated.manifest,
        definition: referencedDefinition,
        resourceData: decorated.resourceData
    )
    #expect(try referenced.contentHash == base.contentHash)
}

@Test func manifestAndResourceInitializersEnforceLimitsAndCanonicalFields() throws {
    let sha = String(repeating: "a", count: 64)
    for invalid in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
        #expect(throws: BrushPackageError.self) {
            try BrushPackageResource(
                id: "shape",
                kind: .shape,
                path: "resources/\(invalid).png",
                mediaType: "image/png",
                sha256: invalid,
                encodedByteCount: 1,
                pixelWidth: 1,
                pixelHeight: 1
            )
        }
    }
    for mediaType in ["image/jpg", "IMAGE/PNG"] {
        #expect(throws: BrushPackageError.self) {
            try BrushPackageResource(
                id: "shape",
                kind: .shape,
                path: "resources/\(sha).png",
                mediaType: mediaType,
                sha256: sha,
                encodedByteCount: 1,
                pixelWidth: 1,
                pixelHeight: 1
            )
        }
    }
    for count in [0, BrushFormatLimits.maximumEncodedResourceBytes + 1] {
        #expect(throws: BrushPackageError.self) {
            try BrushPackageResource(
                id: "shape",
                kind: .shape,
                path: "resources/\(sha).png",
                mediaType: "image/png",
                sha256: sha,
                encodedByteCount: count,
                pixelWidth: 1,
                pixelHeight: 1
            )
        }
    }
    for dimension in [0, 8_193] {
        #expect(throws: BrushPackageError.self) {
            try BrushPackageResource(
                id: "shape",
                kind: .shape,
                path: "resources/\(sha).png",
                mediaType: "image/png",
                sha256: sha,
                encodedByteCount: 1,
                pixelWidth: dimension,
                pixelHeight: 1
            )
        }
    }
    #expect(try BrushPackageResource(
        id: "shape",
        kind: .shape,
        path: "resources/\(sha).tiff",
        mediaType: "image/tiff",
        sha256: sha,
        encodedByteCount: BrushFormatLimits.maximumEncodedResourceBytes,
        pixelWidth: 8_192,
        pixelHeight: 8_192
    ).path.hasSuffix(".tiff"))
    #expect(throws: BrushPackageError.self) {
        try BrushPackageResource(
            id: "shape",
            kind: .shape,
            path: "resources/\(sha).png",
            mediaType: "image/tiff",
            sha256: sha,
            encodedByteCount: 1,
            pixelWidth: 1,
            pixelHeight: 1
        )
    }
}

@Test func manifestRejectsDuplicateIdentityPathsAndSeventeenResources() throws {
    let bytes = try BrushFormatTestSupport.fixturePNG()
    let first = try BrushFormatTestSupport.resource(id: "a", bytes: bytes)
    let second = try BrushFormatTestSupport.resource(id: "b", bytes: bytes)
    #expect(throws: BrushPackageError.self) {
        try BrushPackageManifest(resources: [first, first])
    }
    #expect(throws: BrushPackageError.self) {
        try BrushPackageManifest(resources: [first, second])
    }

    let resources = try (0..<17).map { index in
        try BrushFormatTestSupport.resource(
            id: "shape.\(index)",
            bytes: Data(bytes + [UInt8(index)])
        )
    }
    #expect(try BrushPackageManifest(resources: Array(resources.prefix(16))).resources.count == 16)
    #expect(throws: BrushPackageError.self) {
        try BrushPackageManifest(resources: resources)
    }
}

@Test func sixteenResourcePackageRoundTripsAndMultiplePreviewsFail() throws {
    let fixture = try BrushFormatTestSupport.fixturePNG()
    let ids = (0..<16).map { String(format: "builtin.shape.%02d", $0) }
    let references = ids.map {
        BrushResourceReference(
            identifier: $0,
            kind: .shape,
            required: false,
            fallback: .builtIn(identifier: $0)
        )
    }
    let resources = try ids.enumerated().map { index, id in
        try BrushFormatTestSupport.resource(
            id: id,
            bytes: Data(fixture + [UInt8(index)])
        )
    }
    let coverage = BrushCoverageDefinition(
        shapes: [
            BrushShapeLayerDefinition(
                shape: .asset(ids[0]),
                combination: .replace,
                scale: 1,
                rotation: 0,
                offset: .zero
            ),
        ],
        grains: [],
        baseHardness: 1,
        aspectRatio: 1,
        tipThreshold: 0,
        antialiasing: true
    )
    let definition = try BrushFormatTestSupport.definition(
        resources: references,
        coverage: coverage
    )
    let resourceData = Dictionary(
        uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, Data(fixture + [UInt8(index)]))
        }
    )
    let package = try BrushPackage(
        manifest: BrushPackageManifest(resources: resources),
        definition: definition,
        resourceData: resourceData
    )
    #expect(try BrushPackageCodec.decode(BrushPackageCodec.encode(package)) == package)

    let previews = try [
        BrushFormatTestSupport.resource(
            id: "preview.a",
            kind: .preview,
            bytes: Data([1])
        ),
        BrushFormatTestSupport.resource(
            id: "preview.b",
            kind: .preview,
            bytes: Data([2])
        ),
    ]
    #expect(throws: BrushPackageError.self) {
        try BrushPackageManifest(resources: previews)
    }
}

@Test func packageValidationRequiresExactBytesReferencesKindsAndFallbacks() throws {
    let package = try BrushFormatTestSupport.package()
    #expect(throws: BrushPackageError.self) {
        try BrushPackage(
            manifest: package.manifest,
            definition: package.definition,
            resourceData: [:]
        )
    }
    #expect(throws: BrushPackageError.self) {
        try BrushPackage(
            manifest: package.manifest,
            definition: package.definition,
            resourceData: package.resourceData.merging(["extra": Data([1])]) { _, new in new }
        )
    }

    let wrongKind = try BrushFormatTestSupport.resource(kind: .grain)
    #expect(throws: BrushPackageError.self) {
        try BrushPackage(
            manifest: BrushPackageManifest(resources: [wrongKind]),
            definition: package.definition,
            resourceData: [wrongKind.id: package.resourceData[wrongKind.id]!]
        )
    }

    let required = BrushResourceReference(
        identifier: BrushFormatTestSupport.shapeID,
        kind: .shape,
        required: true,
        fallback: nil
    )
    let requiredDefinition = try BrushFormatTestSupport.definition(resources: [required])
    #expect(throws: BrushPackageError.missingResource(BrushFormatTestSupport.shapeID)) {
        try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: requiredDefinition,
            resourceData: [:]
        )
    }
    #expect(try BrushFormatTestSupport.fallbackOnlyPackage().resourceData.isEmpty)

    let wrongHash = String(repeating: "a", count: 64)
    let wrongHashResource = try BrushPackageResource(
        id: BrushFormatTestSupport.shapeID,
        kind: .shape,
        path: "resources/\(wrongHash).png",
        mediaType: "image/png",
        sha256: wrongHash,
        encodedByteCount: package.resourceData[BrushFormatTestSupport.shapeID]!.count,
        pixelWidth: 4,
        pixelHeight: 4
    )
    #expect(throws: BrushPackageError.self) {
        try BrushPackage(
            manifest: BrushPackageManifest(resources: [wrongHashResource]),
            definition: package.definition,
            resourceData: package.resourceData
        )
    }

    let unreferencedBytes = Data([9])
    let unreferenced = try BrushFormatTestSupport.resource(
        id: "builtin.shape.unreferenced",
        bytes: unreferencedBytes
    )
    #expect(throws: BrushPackageError.self) {
        try BrushPackage(
            manifest: BrushPackageManifest(
                resources: package.manifest.resources + [unreferenced]
            ),
            definition: package.definition,
            resourceData: package.resourceData.merging([
                unreferenced.id: unreferencedBytes,
            ]) { _, new in new }
        )
    }
}

@Test func codecRejectsDeclaredHashByteCountAndFallbackMismatch() throws {
    let package = try BrushFormatTestSupport.package()

    var entries = try BrushFormatTestSupport.archiveEntries(package)
    var manifest = try #require(
        JSONSerialization.jsonObject(with: entries["manifest.json"]!) as? [String: Any]
    )
    var resources = try #require(manifest["resources"] as? [[String: Any]])
    resources[0]["encodedByteCount"] = package.manifest.resources[0].encodedByteCount + 1
    manifest["resources"] = resources
    entries["manifest.json"] = try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.sortedKeys]
    )
    #expect(throws: BrushPackageError.self) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    manifest = try #require(
        JSONSerialization.jsonObject(with: entries["manifest.json"]!) as? [String: Any]
    )
    resources = try #require(manifest["resources"] as? [[String: Any]])
    let wrongHash = String(repeating: "b", count: 64)
    let oldPath = try #require(resources[0]["path"] as? String)
    let newPath = "resources/\(wrongHash).png"
    resources[0]["sha256"] = wrongHash
    resources[0]["path"] = newPath
    manifest["resources"] = resources
    entries["manifest.json"] = try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.sortedKeys]
    )
    entries[newPath] = entries.removeValue(forKey: oldPath)
    #expect(throws: BrushPackageError.self) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    var definition = try #require(
        JSONSerialization.jsonObject(with: entries["definition.json"]!) as? [String: Any]
    )
    var definitionResources = try #require(
        definition["resources"] as? [[String: Any]]
    )
    definitionResources[0].removeValue(forKey: "fallback")
    definition["resources"] = definitionResources
    entries["definition.json"] = try JSONSerialization.data(
        withJSONObject: definition,
        options: [.sortedKeys]
    )
    #expect(throws: BrushPackageError.invalidDefinition) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }
}

@Test func codecRejectsMissingExtraMalformedAndUnsupportedMetadata() throws {
    let package = try BrushFormatTestSupport.package()
    var entries = try BrushFormatTestSupport.archiveEntries(package)
    entries.removeValue(forKey: "manifest.json")
    #expect(throws: BrushPackageError.archive(.missingEntry("manifest.json"))) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    entries.removeValue(forKey: "definition.json")
    #expect(throws: BrushPackageError.archive(.missingEntry("definition.json"))) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    entries["extra.bin"] = Data([1])
    #expect(throws: BrushPackageError.unexpectedEntry("extra.bin")) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    entries["manifest.json"] = Data("{".utf8)
    #expect(throws: BrushPackageError.malformedJSON("manifest")) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    entries["manifest.json"] = Data(
        String(decoding: entries["manifest.json"]!, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":3")
            .utf8
    )
    #expect(throws: BrushPackageError.unsupportedManifestSchema(3)) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    entries["definition.json"] = Data(
        String(decoding: entries["definition.json"]!, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
            .utf8
    )
    #expect(throws: BrushPackageError.unsupportedDefinitionSchema) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }

    entries = try BrushFormatTestSupport.archiveEntries(package)
    entries["definition.json"] = Data(
        String(decoding: entries["definition.json"]!, as: UTF8.self)
            .replacingOccurrences(
                of: "\"stabilization\":0",
                with: "\"stabilization\":1e999"
            )
            .utf8
    )
    #expect(throws: BrushPackageError.malformedJSON("definition")) {
        try BrushPackageCodec.decode(BrushFormatTestSupport.encodeArchive(entries))
    }
}

@Test func codecPreservesUnknownCapabilityStringsAndArchiveSafetyErrors() throws {
    let base = try BrushFormatTestSupport.package()
    let definition = try BrushFormatTestSupport.definition(
        capabilities: [
            BrushCapabilityDeclaration(identifier: "future.capability", required: true),
        ]
    )
    let package = try BrushPackage(
        manifest: base.manifest,
        definition: definition,
        resourceData: base.resourceData
    )
    #expect(
        try BrushPackageCodec.decode(BrushPackageCodec.encode(package))
            .definition.capabilities == definition.capabilities
    )

    let unsafe = try SafeArchiveCodec.encode(
        entries: ["safe-name": Data([1])],
        limits: BrushPackageCodec.archiveLimits
    )
    var forged = unsafe
    let safeName = Data("safe-name".utf8)
    let unsafeName = Data("../escape".utf8)
    var search = forged.startIndex
    while let range = forged.range(of: safeName, in: search..<forged.endIndex) {
        forged.replaceSubrange(range, with: unsafeName)
        search = range.upperBound
    }
    #expect(throws: BrushPackageError.archive(.unsafePath("../escape"))) {
        try BrushPackageCodec.decode(forged)
    }

    var duplicate = try SafeArchiveCodec.encode(
        entries: [
            "manifest.json": Data([1]),
            "manifest.jsox": Data([2]),
        ],
        limits: BrushPackageCodec.archiveLimits
    )
    let secondName = Data("manifest.jsox".utf8)
    let firstName = Data("manifest.json".utf8)
    search = duplicate.startIndex
    while let range = duplicate.range(of: secondName, in: search..<duplicate.endIndex) {
        duplicate.replaceSubrange(range, with: firstName)
        search = range.upperBound
    }
    #expect(throws: BrushPackageError.archive(.duplicateEntry("manifest.json"))) {
        try BrushPackageCodec.decode(duplicate)
    }
}

@Test func codecPreservesCompressionLinkAndChecksumArchiveFailures() throws {
    let original = try SafeArchiveCodec.encode(
        entries: ["manifest.json": Data([1, 2, 3])],
        limits: BrushPackageCodec.archiveLimits
    )
    let local = try #require(
        zipSignatureOffsets(0x0403_4B50, in: original).first
    )
    let central = try #require(
        zipSignatureOffsets(0x0201_4B50, in: original).first
    )

    var compressed = original
    zipSetUInt16(8, at: local + 8, in: &compressed)
    zipSetUInt16(8, at: central + 10, in: &compressed)
    #expect(
        throws: BrushPackageError.archive(
            .unsupportedCompression(path: "manifest.json", method: 8)
        )
    ) {
        try BrushPackageCodec.decode(compressed)
    }

    var link = original
    zipSetUInt32(0xA1FF_0000, at: central + 38, in: &link)
    #expect(
        throws: BrushPackageError.archive(.symbolicLink("manifest.json"))
    ) {
        try BrushPackageCodec.decode(link)
    }

    var checksum = original
    let nameLength = Int(zipUInt16(at: local + 26, in: checksum))
    let extraLength = Int(zipUInt16(at: local + 28, in: checksum))
    let payload = local + 30 + nameLength + extraLength
    checksum[payload] ^= 0xFF
    #expect(
        throws: BrushPackageError.archive(.checksumMismatch("manifest.json"))
    ) {
        try BrushPackageCodec.decode(checksum)
    }
}

@Test func codecPreservesConfiguredArchiveLimitFailures() throws {
    let lax = SafeArchiveLimits(
        maximumEntryCount: 65,
        maximumEntryBytes: UInt64(BrushFormatLimits.maximumEncodedResourceBytes + 1),
        maximumExpandedBytes: UInt64(BrushFormatLimits.maximumExpandedPackageBytes + 1),
        maximumPathBytes: BrushFormatLimits.maximumArchivePathBytes
    )
    let sixtyFiveEntries = Dictionary(
        uniqueKeysWithValues: (0..<65).map { ("e\($0)", Data([UInt8($0)])) }
    )
    let tooMany = try SafeArchiveCodec.encode(
        entries: sixtyFiveEntries,
        limits: lax
    )
    #expect(
        throws: BrushPackageError.archive(.entryCountOutOfRange(65))
    ) {
        try BrushPackageCodec.decode(tooMany)
    }

    var oversizedEntry = try SafeArchiveCodec.encode(
        entries: ["manifest.json": Data([1])],
        limits: BrushPackageCodec.archiveLimits
    )
    let central = try #require(
        zipSignatureOffsets(0x0201_4B50, in: oversizedEntry).first
    )
    let actual = UInt32(BrushFormatLimits.maximumEncodedResourceBytes + 1)
    zipSetUInt32(actual, at: central + 20, in: &oversizedEntry)
    zipSetUInt32(actual, at: central + 24, in: &oversizedEntry)
    #expect(
        throws: BrushPackageError.archive(
            .entryTooLarge(
                path: "manifest.json",
                actual: UInt64(actual),
                maximum: UInt64(BrushFormatLimits.maximumEncodedResourceBytes)
            )
        )
    ) {
        try BrushPackageCodec.decode(oversizedEntry)
    }

    #expect(
        BrushPackageCodec.archiveLimits.maximumExpandedBytes
            == UInt64(192 * 1_024 * 1_024)
    )
}

@Test func archiveEntryBoundariesRemainDistinctFromPackageMembership() throws {
    let sixtyFour = Dictionary(
        uniqueKeysWithValues: (0..<64).map { ("entry-\($0)", Data([UInt8($0)])) }
    )
    let admitted = try SafeArchiveCodec.encode(
        entries: sixtyFour,
        limits: BrushPackageCodec.archiveLimits
    )
    #expect(throws: BrushPackageError.archive(.missingEntry("manifest.json"))) {
        try BrushPackageCodec.decode(admitted)
    }

    var sixtyFive = sixtyFour
    sixtyFive["entry-64"] = Data([64])
    #expect(
        throws: SafeArchiveError.entryCountOutOfRange(65)
    ) {
        try SafeArchiveCodec.encode(
            entries: sixtyFive,
            limits: BrushPackageCodec.archiveLimits
        )
    }
}
