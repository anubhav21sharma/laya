import BrushFormat
import Foundation
import PatternEngine

public struct SyntheticV1BrushMapper: ForeignBrushMapper {
    public static let converterIdentifier = "laya.synthetic-v1-mapper"
    public static let converterVersion = "1"

    public init() {}

    public func map(
        _ document: ForeignBrushDocument
    ) throws -> ForeignBrushMappingResult {
        try validateSource(document.ir.provenance)
        for setting in document.ir.settings
        where !setting.semanticKey.hasPrefix("synthetic.v1.") {
            throw SyntheticV1MappingError.unexpectedSettingNamespace(
                setting.semanticKey
            )
        }
        let settings = Dictionary(
            uniqueKeysWithValues: document.ir.settings.map {
                ($0.semanticKey, $0)
            }
        )
        for required in SyntheticV1SemanticKeys.dry
        where settings[required] == nil {
            throw SyntheticV1MappingError.missingSetting(required)
        }

        let shapeID = try resourceReference(
            SyntheticV1SemanticKeys.shape,
            settings: settings
        )
        let grainID = try resourceReference(
            SyntheticV1SemanticKeys.grain,
            settings: settings
        )
        guard shapeID != grainID else {
            throw SyntheticV1MappingError.invalidSetting(
                key: SyntheticV1SemanticKeys.grain,
                reason: "shape-and-grain-must-be-distinct"
            )
        }

        let unknownResourceIDs: [String] = document.ir.settings.compactMap {
            setting -> String? in
            guard !SyntheticV1SemanticKeys.all.contains(setting.semanticKey),
                  case let .resourceReference(identifier) = setting.value
            else {
                return nil
            }
            return identifier
        }
        let expectedResourceIDs = Set([shapeID, grainID] + unknownResourceIDs)
        let actualResourceIDs = Set(document.ir.resources.map(\.id))
        if let missing = expectedResourceIDs
            .subtracting(actualResourceIDs).sorted().first
        {
            throw SyntheticV1MappingError.missingResource(missing)
        }
        if let unexpected = actualResourceIDs
            .subtracting(expectedResourceIDs).sorted().first
        {
            throw SyntheticV1MappingError.unexpectedResource(unexpected)
        }

        let shapeSource = try sourceResource(
            shapeID,
            role: .shape,
            in: document
        )
        let grainSource = try sourceResource(
            grainID,
            role: .grain,
            in: document
        )
        let shape = try ForeignBrushResourceNormalizer.normalize(
            shapeSource,
            data: try resourceData(shapeID, in: document),
            kind: .shape
        )
        let grain = try ForeignBrushResourceNormalizer.normalize(
            grainSource,
            data: try resourceData(grainID, in: document),
            kind: .grain
        )

        let spacing = try spacing(settings)
        let flow = try normalizedScalar(
            SyntheticV1SemanticKeys.flow,
            settings: settings
        )
        let opacity = try normalizedScalar(
            SyntheticV1SemanticKeys.opacity,
            settings: settings
        )
        let rotation = try rotationRadians(settings)
        let scatter = try normalizedScalar(
            SyntheticV1SemanticKeys.scatter,
            settings: settings
        )
        let sizePressure = try sizePressure(settings)
        let materialFamily = try materialFamily(settings)
        let wet = try wetIntent(settings)
        guard !wet else {
            throw SyntheticV1MappingError.invalidSetting(
                key: SyntheticV1SemanticKeys.wet,
                reason: "unsupported-by-native-schema-3"
            )
        }

        let sourceKeys = document.ir.settings.map(\.semanticKey)
        let requiredKeys = sourceKeys.filter {
            !SyntheticV1SemanticKeys.all.contains($0)
        }
        let definition = try makeDefinition(
            document: document,
            shapeID: shapeID,
            grainID: grainID,
            spacing: spacing,
            flow: flow,
            opacity: opacity,
            rotation: rotation,
            scatter: scatter,
            sizePressure: sizePressure,
            materialFamily: materialFamily,
            sourceKeys: sourceKeys,
            requiredKeys: requiredKeys
        )

        let packageResources = [grain.descriptor, shape.descriptor]
            .sorted { $0.id < $1.id }
        let resourceData = [
            grain.descriptor.id: grain.data,
            shape.descriptor.id: shape.data,
        ]
        let provenance = BrushPackageProvenance(
            buildTool: Self.converterIdentifier,
            sourceApplication: document.ir.provenance.sourceFormatFamily,
            sourceVersion: document.ir.provenance.sourceFormatVersion
        )
        let plainPackage = try BrushPackage(
            manifest: BrushPackageManifest(
                resources: packageResources,
                provenance: provenance
            ),
            definition: definition,
            resourceData: resourceData
        )
        let entries = try makeEntries(
            document: document,
            settings: settings,
            shape: shape,
            grain: grain,
            spacing: spacing,
            flow: flow,
            opacity: opacity,
            rotation: rotation,
            scatter: scatter,
            sizePressure: sizePressure,
            materialFamily: materialFamily
        )
        let diagnostics = try conversionDiagnostics(
            document.ir.diagnostics
        )
        let report = try BrushConversionReport(
            sourceFormat: document.ir.provenance.sourceFormatFamily,
            sourceVersion: document.ir.provenance.sourceFormatVersion,
            sourceContentHash:
                document.ir.provenance.sourceContentSHA256,
            converterIdentifier: Self.converterIdentifier,
            converterVersion: Self.converterVersion,
            targetDefinitionID: definition.id.rawValue,
            targetPackageContentHash: plainPackage.contentHash,
            entries: entries,
            diagnostics: diagnostics
        )
        let finalPackage = try BrushPackage(
            manifest: BrushPackageManifest(
                resources: packageResources,
                provenance: provenance,
                conversionReport:
                    BrushPackageConversionReportDescriptor(report: report)
            ),
            definition: definition,
            resourceData: resourceData,
            conversionReport: report
        )
        return try ForeignBrushMappingResult(
            package: finalPackage,
            report: report
        )
    }

    private func validateSource(
        _ provenance: ForeignBrushProvenance
    ) throws {
        guard provenance.sourceFormatFamily
                == SyntheticV1BrushParser.sourceFormatFamily,
              provenance.sourceFormatVersion
                == SyntheticV1BrushParser.sourceFormatVersion
        else {
            throw SyntheticV1MappingError.unsupportedSourceFormat(
                family: provenance.sourceFormatFamily,
                version: provenance.sourceFormatVersion
            )
        }
        guard provenance.parserIdentifier
                == SyntheticV1BrushParser.parserIdentifier,
              provenance.parserVersion
                == SyntheticV1BrushParser.parserVersion
        else {
            throw SyntheticV1MappingError.unsupportedParser(
                identifier: provenance.parserIdentifier,
                version: provenance.parserVersion
            )
        }
    }

    private func makeDefinition(
        document: ForeignBrushDocument,
        shapeID: String,
        grainID: String,
        spacing: (base: Float, maximum: Float),
        flow: Float,
        opacity: Float,
        rotation: Float,
        scatter: Float,
        sizePressure: (minimum: Float, maximum: Float),
        materialFamily: BrushMaterialFamily,
        sourceKeys: [String],
        requiredKeys: [String]
    ) throws -> BrushDefinition {
        let id = BrushRecipeID(
            "converted.synthetic."
                + document.ir.provenance.sourceContentSHA256
        )
        func constant(_ value: Float) -> BrushMappingDefinition {
            BrushMappingDefinition(
                input: .pressure,
                response: .constant(value),
                scale: 1,
                offset: 0,
                lowerClamp: value,
                upperClamp: value,
                inverted: false,
                jitter: 0,
                missingInputValue: 1
            )
        }
        let sizeMapping = BrushMappingDefinition(
            input: .pressure,
            response: .linear,
            scale: sizePressure.maximum - sizePressure.minimum,
            offset: sizePressure.minimum,
            lowerClamp: sizePressure.minimum,
            upperClamp: sizePressure.maximum,
            inverted: false,
            jitter: 0,
            missingInputValue: 1
        )
        let dynamics = BrushDynamicsDefinition(
            size: sizeMapping,
            flow: constant(1),
            opacity: constant(1),
            spacing: constant(1),
            rotation: constant(0),
            scatter: constant(1),
            hardness: constant(1),
            grain: constant(1),
            offsetX: constant(0),
            offsetY: constant(0),
            hue: constant(0),
            saturation: constant(0),
            brightness: constant(0),
            secondaryColorMix: constant(0),
            noPressureNeutral: 1,
            randomization: .none
        )
        let materialSemantics: (BrushAccumulationMode, BrushEdgeTreatment) =
            switch materialFamily {
            case .ink: (.flow, .none)
            case .dry: (.flow, .dryBreakup)
            case .glaze: (.uniformGlaze, .markerOverlap)
            case .boundedWash: (.flow, .wetConcentration)
            }
        let mappedMaterial = BrushMaterialDefinition(
            accumulation: materialSemantics.0,
            interaction: .none,
            edgeTreatment: materialSemantics.1,
            strength: 1,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 1,
            interactionParameters: nil
        )
        let references = [
            BrushResourceReference(
                identifier: grainID,
                kind: .grain,
                required: true,
                fallback: nil
            ),
            BrushResourceReference(
                identifier: shapeID,
                kind: .shape,
                required: true,
                fallback: nil
            ),
        ].sorted { $0.identifier < $1.identifier }

        return try BrushDefinition(
            id: id,
            metadata: BrushMetadata(
                displayName: document.ir.displayName,
                author: document.ir.author,
                sourceApplication:
                    document.ir.provenance.sourceFormatFamily,
                sourceIdentifier: document.ir.sourceBrushIdentifier
            ),
            capabilities: [],
            resources: references,
            coverage: BrushCoverageDefinition(
                shapes: [
                    BrushShapeLayerDefinition(
                        shape: .asset(shapeID),
                        combination: .replace,
                        scale: 1,
                        rotation: 0,
                        offset: .zero
                    ),
                ],
                grains: [
                    BrushGrainLayerDefinition(
                        grain: .asset(grainID),
                        coordinateMode: .canonical,
                        transform: .identity,
                        grainMovementFraction: 0,
                        grainFollowsBrushRotation: false,
                        strength: 1
                    ),
                ],
                baseHardness: 1,
                aspectRatio: 1,
                tipThreshold: 0,
                antialiasing: true
            ),
            placement: BrushPlacementDefinition(
                baseSpacingFraction: spacing.base,
                maximumSpacingFraction: spacing.maximum,
                baseFlow: flow,
                strokeOpacity: opacity,
                baseScatterFraction: scatter,
                baseRotation: rotation,
                baseJitterFraction: 0,
                baseOffset: .zero
            ),
            dynamics: dynamics,
            color: BrushColorBehaviorDefinition(
                baseAdjustment: .identity,
                perStampJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                ),
                perStrokeJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                )
            ),
            material: mappedMaterial,
            stabilization: 0,
            taper: .none,
            replayMode: .appendOnly,
            replayLimits: nil,
            termination: .cap,
            seedPolicy: .perStroke,
            limits: BrushDefinitionLimits(
                minimumDiameter: 0.01,
                maximumDiameter: 16_384,
                maximumOpacity: 1,
                maximumSpacingFraction: 4,
                maximumResourceDimension: 4_096,
                maximumResidentBytes: 64 * 1_024 * 1_024
            ),
            performanceIntent: .realtime120,
            compatibility: BrushCompatibilityMetadata(
                sourceSettingKeys: sourceKeys,
                requiredSemanticKeys: requiredKeys
            ),
            sensorNormalization: BrushSensorNormalizationDefinition(
                fullScaleWorldVelocity:
                    BrushInputContract.maximumWorldVelocity,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 1,
                fullScaleStrokeDistanceInDiameters: 10
            ),
            sensorProgram: BrushSensorProgramDefinition(
                singleMappingDynamics: dynamics
            ),
            stabilizationV2: .none,
            direction: BrushDirectionDefinition(
                maximumAngularStep: .pi,
                stationaryDirection: 0
            ),
            emission: BrushEmissionDefinition(
                mode: .distance,
                timeInterval: nil
            ),
            tipSupports: [.analyticEllipse]
        )
    }

    private func makeEntries(
        document: ForeignBrushDocument,
        settings: [String: ForeignBrushSetting],
        shape: NormalizedForeignBrushResource,
        grain: NormalizedForeignBrushResource,
        spacing: (base: Float, maximum: Float),
        flow: Float,
        opacity: Float,
        rotation: Float,
        scatter: Float,
        sizePressure: (minimum: Float, maximum: Float),
        materialFamily: BrushMaterialFamily
    ) throws -> [BrushConversionEntry] {
        var entries: [String: BrushConversionEntry] = [:]
        entries[SyntheticV1SemanticKeys.accumulation] = try exactEntry(
            key: SyntheticV1SemanticKeys.accumulation,
            nativeKeys: [
                "components[0].material.accumulation",
                "components[0].material.edgeTreatment",
            ],
            source: try token(
                SyntheticV1SemanticKeys.accumulation,
                settings: settings
            ),
            target:
                "\(materialFamily)"
        )
        entries[SyntheticV1SemanticKeys.flow] = try exactEntry(
            key: SyntheticV1SemanticKeys.flow,
            nativeKeys: ["components[0].placement.baseFlow"],
            source: "\(flow)",
            target: "\(flow)"
        )
        entries[SyntheticV1SemanticKeys.grain] = try resourceEntry(
            key: SyntheticV1SemanticKeys.grain,
            nativeKeys: [
                "components[0].coverage.grains[0]",
                "components[0].resources",
            ],
            resourceID: grain.descriptor.id,
            transform: grain.transform
        )
        entries[SyntheticV1SemanticKeys.opacity] = try exactEntry(
            key: SyntheticV1SemanticKeys.opacity,
            nativeKeys: ["components[0].placement.strokeOpacity"],
            source: "\(opacity)",
            target: "\(opacity)"
        )
        let rotationDegrees = try scalar(
            SyntheticV1SemanticKeys.rotation,
            unit: .degrees,
            settings: settings
        )
        entries[SyntheticV1SemanticKeys.rotation] = try exactEntry(
            key: SyntheticV1SemanticKeys.rotation,
            nativeKeys: ["components[0].placement.baseRotation"],
            source: "\(rotationDegrees) degrees",
            target: "\(rotation) radians"
        )
        entries[SyntheticV1SemanticKeys.scatter] = try exactEntry(
            key: SyntheticV1SemanticKeys.scatter,
            nativeKeys: ["components[0].placement.baseScatterFraction"],
            source: "\(scatter)",
            target: "\(scatter)"
        )
        entries[SyntheticV1SemanticKeys.shape] = try resourceEntry(
            key: SyntheticV1SemanticKeys.shape,
            nativeKeys: [
                "components[0].coverage.shapes[0]",
                "components[0].resources",
            ],
            resourceID: shape.descriptor.id,
            transform: shape.transform
        )
        entries[SyntheticV1SemanticKeys.sizePressure] = try exactEntry(
            key: SyntheticV1SemanticKeys.sizePressure,
            nativeKeys: ["components[0].dynamics.size"],
            source: "\(sizePressure.minimum)...\(sizePressure.maximum)",
            target: "\(sizePressure.minimum)...\(sizePressure.maximum)"
        )
        entries[SyntheticV1SemanticKeys.spacing] = try exactEntry(
            key: SyntheticV1SemanticKeys.spacing,
            nativeKeys: [
                "components[0].placement.baseSpacingFraction",
                "components[0].placement.maximumSpacingFraction",
            ],
            source: "\(spacing.base)...\(spacing.maximum)",
            target: "\(spacing.base)...\(spacing.maximum)"
        )
        for setting in document.ir.settings
        where entries[setting.semanticKey] == nil {
            entries[setting.semanticKey] = try BrushConversionEntry(
                sourceSemanticKey: setting.semanticKey,
                nativeSemanticKeys: [],
                disposition: .unsupported,
                sourceSummary: summary(of: setting),
                targetSummary: nil,
                reasonCode: "unsupported-setting",
                message:
                    "The synthetic adapter retained this setting but has no faithful native mapping.",
                requiredForFaithfulRendering: true
            )
        }
        return try document.ir.settings.map { setting in
            guard let entry = entries[setting.semanticKey] else {
                throw SyntheticV1MappingError.invalidSetting(
                    key: setting.semanticKey,
                    reason: "internal-missing-disposition"
                )
            }
            return entry
        }
    }

    private func exactEntry(
        key: String,
        nativeKeys: [String],
        source: String,
        target: String
    ) throws -> BrushConversionEntry {
        try BrushConversionEntry(
            sourceSemanticKey: key,
            nativeSemanticKeys: nativeKeys.sorted(),
            disposition: .exact,
            sourceSummary: source,
            targetSummary: target,
            reasonCode: "exact-mapping",
            message: "Mapped exactly to the native brush definition."
        )
    }

    private func resourceEntry(
        key: String,
        nativeKeys: [String],
        resourceID: String,
        transform: BrushConversionResourceTransformEvidence?
    ) throws -> BrushConversionEntry {
        if let transform {
            return try BrushConversionEntry(
                sourceSemanticKey: key,
                nativeSemanticKeys: nativeKeys.sorted(),
                disposition: .resourceResampled,
                sourceSummary: "resource:\(resourceID)",
                targetSummary: "resource:\(resourceID)",
                reasonCode: "resource-normalized",
                message:
                    "Normalized a project-owned raw resource into deterministic TIFF.",
                resourceTransform: transform
            )
        }
        return try exactEntry(
            key: key,
            nativeKeys: nativeKeys,
            source: "resource:\(resourceID)",
            target: "resource:\(resourceID)"
        )
    }

    private func conversionDiagnostics(
        _ diagnostics: [ForeignBrushDiagnostic]
    ) throws -> [BrushConversionDiagnostic] {
        let mapped = try diagnostics.map { diagnostic in
            let severity: BrushConversionDiagnosticSeverity =
                switch diagnostic.severity {
                case .information: .info
                case .warning: .warning
                case .error: .error
                }
            return try BrushConversionDiagnostic(
                severity: severity,
                code: diagnostic.code,
                message: diagnostic.message,
                location: diagnostic.location
            )
        }
        return mapped.sorted {
            diagnosticSortKey($0) < diagnosticSortKey($1)
        }
    }

    private func diagnosticSortKey(
        _ diagnostic: BrushConversionDiagnostic
    ) -> String {
        "\(diagnostic.location ?? "")\u{0}\(diagnostic.code)\u{0}"
            + "\(diagnostic.severity.rawValue)\u{0}\(diagnostic.message)"
    }

    private func sourceResource(
        _ id: String,
        role: ForeignBrushResourceRole,
        in document: ForeignBrushDocument
    ) throws -> ForeignBrushResourceDescriptor {
        guard let resource = document.ir.resources.first(where: {
            $0.id == id
        }) else {
            throw SyntheticV1MappingError.missingResource(id)
        }
        guard resource.role == role else {
            throw SyntheticV1MappingError.resourceRoleMismatch(
                resourceID: id,
                expected: role,
                actual: resource.role
            )
        }
        return resource
    }

    private func resourceData(
        _ id: String,
        in document: ForeignBrushDocument
    ) throws -> Data {
        guard let data = document.resourceData[id] else {
            throw SyntheticV1MappingError.missingResource(id)
        }
        return data
    }

    private func resourceReference(
        _ key: String,
        settings: [String: ForeignBrushSetting]
    ) throws -> String {
        let setting = try requireSetting(
            key,
            unit: .unitless,
            domain: .resource,
            settings: settings
        )
        guard case let .resourceReference(identifier) = setting.value else {
            throw invalidValue(key)
        }
        return identifier
    }

    private func spacing(
        _ settings: [String: ForeignBrushSetting]
    ) throws -> (base: Float, maximum: Float) {
        let key = SyntheticV1SemanticKeys.spacing
        let setting = try requireSetting(
            key,
            unit: .normalized,
            domain: .vector,
            settings: settings
        )
        guard case let .vector(values) = setting.value,
              values.count == 2,
              values[0] > 0,
              values[0] <= values[1],
              values[1] <= 4
        else {
            throw invalidValue(key)
        }
        return (
            try exactFloat(values[0], key: key),
            try exactFloat(values[1], key: key)
        )
    }

    private func normalizedScalar(
        _ key: String,
        settings: [String: ForeignBrushSetting]
    ) throws -> Float {
        let value = try scalar(
            key,
            unit: .normalized,
            settings: settings
        )
        guard (0...1).contains(value) else {
            throw invalidValue(key)
        }
        return try exactFloat(value, key: key)
    }

    private func rotationRadians(
        _ settings: [String: ForeignBrushSetting]
    ) throws -> Float {
        let key = SyntheticV1SemanticKeys.rotation
        let degrees = try scalar(key, unit: .degrees, settings: settings)
        guard (-360...360).contains(degrees) else {
            throw invalidValue(key)
        }
        let radians = degrees * Double.pi / 180
        let result = Float(radians)
        guard result.isFinite else { throw invalidValue(key) }
        return result
    }

    private func sizePressure(
        _ settings: [String: ForeignBrushSetting]
    ) throws -> (minimum: Float, maximum: Float) {
        let key = SyntheticV1SemanticKeys.sizePressure
        let setting = try requireSetting(
            key,
            unit: .normalized,
            domain: .curve,
            settings: settings
        )
        guard case let .curve(points) = setting.value,
              points.count == 2,
              points[0].x == 0,
              points[1].x == 1,
              points[0].y > 0,
              points[0].y <= points[1].y,
              points[1].y <= Double(
                BrushRecipePolicy.maximumMappingMagnitude
              )
        else {
            throw invalidValue(key)
        }
        return (
            try exactFloat(points[0].y, key: key),
            try exactFloat(points[1].y, key: key)
        )
    }

    private func materialFamily(
        _ settings: [String: ForeignBrushSetting]
    ) throws -> BrushMaterialFamily {
        let key = SyntheticV1SemanticKeys.accumulation
        return switch try token(key, settings: settings) {
        case "flow":
            .ink
        case "dry-flow":
            .dry
        case "uniform-glaze":
            .glaze
        case "bounded-wash":
            .boundedWash
        default:
            throw invalidValue(key)
        }
    }

    private func wetIntent(
        _ settings: [String: ForeignBrushSetting]
    ) throws -> Bool {
        guard settings[SyntheticV1SemanticKeys.wet] != nil else {
            return false
        }
        let setting = try requireSetting(
            SyntheticV1SemanticKeys.wet,
            unit: .unitless,
            domain: .boolean,
            settings: settings
        )
        guard case .boolean(true) = setting.value else {
            throw invalidValue(SyntheticV1SemanticKeys.wet)
        }
        return true
    }

    private func token(
        _ key: String,
        settings: [String: ForeignBrushSetting]
    ) throws -> String {
        let setting = try requireSetting(
            key,
            unit: .unitless,
            domain: .token,
            settings: settings
        )
        guard case let .token(value) = setting.value else {
            throw invalidValue(key)
        }
        return value
    }

    private func scalar(
        _ key: String,
        unit: ForeignBrushSettingUnit,
        settings: [String: ForeignBrushSetting]
    ) throws -> Double {
        let setting = try requireSetting(
            key,
            unit: unit,
            domain: .scalar,
            settings: settings
        )
        guard case let .scalar(value) = setting.value else {
            throw invalidValue(key)
        }
        return value
    }

    private func requireSetting(
        _ key: String,
        unit: ForeignBrushSettingUnit,
        domain: ForeignBrushSettingDomain,
        settings: [String: ForeignBrushSetting]
    ) throws -> ForeignBrushSetting {
        guard let setting = settings[key] else {
            throw SyntheticV1MappingError.missingSetting(key)
        }
        guard setting.unit == unit else {
            throw SyntheticV1MappingError.invalidSetting(
                key: key,
                reason: "expected-unit-\(unit.rawValue)"
            )
        }
        guard setting.domain == domain else {
            throw SyntheticV1MappingError.invalidSetting(
                key: key,
                reason: "expected-domain-\(domain.rawValue)"
            )
        }
        return setting
    }

    private func exactFloat(_ value: Double, key: String) throws -> Float {
        let converted = Float(value)
        guard converted.isFinite,
              Double(converted) == value
        else {
            throw SyntheticV1MappingError.invalidSetting(
                key: key,
                reason: "not-exactly-representable-as-float"
            )
        }
        return converted
    }

    private func invalidValue(_ key: String) -> SyntheticV1MappingError {
        .invalidSetting(key: key, reason: "invalid-value")
    }

    private func summary(of setting: ForeignBrushSetting) -> String {
        switch setting.value {
        case .null:
            "null"
        case let .boolean(value):
            "\(setting.domain.rawValue):\(value)"
        case let .integer(value):
            "\(setting.domain.rawValue):\(value)"
        case let .scalar(value):
            "\(setting.domain.rawValue):\(value)"
        case let .token(value):
            "\(setting.domain.rawValue):\(value)"
        case let .vector(values):
            "\(setting.domain.rawValue):\(values.count)-components"
        case let .curve(points):
            "\(setting.domain.rawValue):\(points.count)-points"
        case .color:
            "\(setting.domain.rawValue):rgba"
        case let .resourceReference(identifier):
            "\(setting.domain.rawValue):\(identifier)"
        }
    }
}
