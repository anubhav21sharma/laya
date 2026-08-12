import BrushFormat
import Foundation
import PatternEngine

public enum ProcreateClassicV1MappingError:
    Error, Equatable, Sendable
{
    case unsupportedSource
    case unsupportedParser(identifier: String, version: String)
    case unsupportedBrush(String)
    case invalidComponentTopology
    case missingSetting(component: String, key: String)
    case invalidSetting(component: String, key: String)
    case unusedSubstitution(String)
}

public struct ProcreateClassicV1BrushMapper: ForeignBrushMapper {
    public static let converterIdentifier = "laya.procreate-classic-v1"
    public static let converterVersion = "1"
    public static let supportedBrushIDs: Set<String> = [
        "CC70504F-0D16-4D26-88A6-BF47BDA8ADE8",
        "21AF8C6B-3FB1-4BF8-8F89-F5768271DA35",
    ]

    private let substitutions: ProcreateResourceSubstitutionRegistry

    public init(substitutions: ProcreateResourceSubstitutionRegistry) {
        self.substitutions = substitutions
    }

    public func map(
        _ document: ForeignBrushDocument
    ) throws -> ForeignBrushMappingResult {
        try validate(document)
        var mappedComponents = [MappedComponent]()
        var usedSubstitutions = Set<String>()
        for component in document.ir.components {
            try mappedComponents.append(mapComponent(
                component,
                usedSubstitutions: &usedSubstitutions
            ))
        }
        if let unused = Set(substitutions.sourceNames)
            .subtracting(usedSubstitutions).sorted().first
        {
            throw ProcreateClassicV1MappingError.unusedSubstitution(unused)
        }

        let entries = mappedComponents.flatMap(\.entries)
            .sorted { $0.sourceSemanticKey < $1.sourceSemanticKey }
        let sourceKeys = entries.map(\.sourceSemanticKey)
        let requiredKeys = entries.compactMap { entry in
            entry.disposition == .unsupported
                && entry.requiredForFaithfulRendering
                ? entry.sourceSemanticKey
                : nil
        }
        let definition = try BrushDefinition(
            id: BrushRecipeID(
                "converted.procreate."
                    + document.ir.sourceBrushIdentifier.lowercased()
            ),
            metadata: BrushMetadata(
                displayName: document.ir.displayName,
                author: document.ir.author,
                sourceApplication: "procreate",
                sourceIdentifier: document.ir.sourceBrushIdentifier
            ),
            capabilities: [],
            composition: .orderedSourceOver,
            components: mappedComponents.map(\.definition),
            stabilization: 0,
            replayMode: .appendOnly,
            replayLimits: nil,
            termination: .cap,
            seedPolicy: .perStroke,
            limits: BrushDefinitionLimits(
                minimumDiameter: 0.01,
                maximumDiameter: 4_096,
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
                fullScaleWorldVelocity: 2_400,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 1,
                fullScaleStrokeDistanceInDiameters: 10
            ),
            stabilizationV2: .none,
            direction: BrushDirectionDefinition(
                maximumAngularStep: .pi / 8,
                stationaryDirection: 0
            )
        )

        var resourceByID: [String: ProcreateResourceSubstitution] = [:]
        for component in mappedComponents {
            for resource in component.resources {
                resourceByID[resource.resourceID] = resource
            }
        }
        let packageResources = try resourceByID.values.map { resource in
            try BrushPackageResource(
                id: resource.resourceID,
                kind: resource.role == .shape ? .shape : .grain,
                mediaType: resource.mediaType,
                data: resource.data,
                pixelWidth: resource.pixelWidth,
                pixelHeight: resource.pixelHeight
            )
        }.sorted { $0.id < $1.id }
        let resourceData = Dictionary(
            uniqueKeysWithValues: resourceByID.values.map {
                ($0.resourceID, $0.data)
            }
        )
        let provenance = BrushPackageProvenance(
            buildTool: Self.converterIdentifier,
            sourceApplication: "procreate",
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
        let report = try BrushConversionReport(
            sourceFormat: "procreate",
            sourceVersion: document.ir.provenance.sourceFormatVersion,
            sourceContentHash: document.ir.provenance.sourceContentSHA256,
            converterIdentifier: Self.converterIdentifier,
            converterVersion: Self.converterVersion,
            targetDefinitionID: definition.id.rawValue,
            targetPackageContentHash: plainPackage.contentHash,
            entries: entries,
            diagnostics: try conversionDiagnostics(document.ir.diagnostics)
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

    private func validate(_ document: ForeignBrushDocument) throws {
        guard document.ir.provenance.sourceFormatFamily == "procreate",
              document.ir.provenance.sourceFormatVersion
                == ProcreateLegacyBrushSetParser.sourceFormatVersion
        else {
            throw ProcreateClassicV1MappingError.unsupportedSource
        }
        guard document.ir.provenance.parserIdentifier
                == ProcreateLegacyBrushSetParser.parserIdentifier,
              document.ir.provenance.parserVersion
                == ProcreateLegacyBrushSetParser.parserVersion
        else {
            throw ProcreateClassicV1MappingError.unsupportedParser(
                identifier: document.ir.provenance.parserIdentifier,
                version: document.ir.provenance.parserVersion
            )
        }
        guard Self.supportedBrushIDs.contains(
            document.ir.sourceBrushIdentifier
        ) else {
            throw ProcreateClassicV1MappingError.unsupportedBrush(
                document.ir.sourceBrushIdentifier
            )
        }
        guard document.ir.components.map(\.identifier) == ["root", "sub01"]
        else {
            throw ProcreateClassicV1MappingError.invalidComponentTopology
        }
    }

    private func mapComponent(
        _ component: ForeignBrushComponent,
        usedSubstitutions: inout Set<String>
    ) throws -> MappedComponent {
        var settings: [String: ForeignBrushSetting] = [:]
        for setting in component.settings {
            guard settings.updateValue(
                setting,
                forKey: setting.semanticKey
            ) == nil else {
                throw ProcreateClassicV1MappingError.invalidSetting(
                    component: component.identifier,
                    key: setting.semanticKey
                )
            }
        }
        let shapeName = try token(
            ProcreateBrushSemanticKeys.bundledShapePath,
            component: component,
            settings: settings
        )
        let grainName = try token(
            ProcreateBrushSemanticKeys.bundledGrainPath,
            component: component,
            settings: settings
        )
        let shape = try substitutions.resolve(
            sourceName: shapeName,
            expectedRole: .shape
        )
        let grain = try substitutions.resolve(
            sourceName: grainName,
            expectedRole: .grain
        )
        usedSubstitutions.insert(shapeName)
        usedSubstitutions.insert(grainName)

        let size = try scalar(
            ProcreateBrushSemanticKeys.paintSize,
            component: component,
            settings: settings
        )
        let spacing = try scalar(
            ProcreateBrushSemanticKeys.plotSpacing,
            component: component,
            settings: settings
        )
        let pressureSize = try scalar(
            ProcreateBrushSemanticKeys.pressureSize,
            component: component,
            settings: settings
        )
        let pressureOpacity = try scalar(
            ProcreateBrushSemanticKeys.pressureOpacity,
            component: component,
            settings: settings
        )
        let tiltRoundness = try scalar(
            ProcreateBrushSemanticKeys.tiltShapeRoundness,
            component: component,
            settings: settings
        )
        let textureScale = try scalar(
            ProcreateBrushSemanticKeys.textureScale,
            component: component,
            settings: settings
        )
        let textureMovement = try scalar(
            ProcreateBrushSemanticKeys.textureMovement,
            component: component,
            settings: settings
        )
        let scatter = try optionalScalar(
            ProcreateBrushSemanticKeys.shapeScatter,
            settings: settings,
            defaultValue: 0
        )
        let rotation = try optionalScalar(
            ProcreateBrushSemanticKeys.shapeRotation,
            settings: settings,
            defaultValue: 0
        )
        let opacity = try optionalScalar(
            ProcreateBrushSemanticKeys.paintOpacity,
            settings: settings,
            defaultValue: 1
        )
        let grainDepth = try optionalScalar(
            ProcreateBrushSemanticKeys.grainDepth,
            settings: settings,
            defaultValue: 0.7
        )
        let dynamics = makeDynamics(
            pressureSize: pressureSize,
            pressureOpacity: pressureOpacity,
            tiltRoundness: tiltRoundness
        )
        let references = [
            BrushResourceReference(
                identifier: grain.resourceID,
                kind: .grain,
                required: true,
                fallback: nil
            ),
            BrushResourceReference(
                identifier: shape.resourceID,
                kind: .shape,
                required: true,
                fallback: nil
            ),
        ].sorted { $0.identifier < $1.identifier }
        let definition = BrushComponentDefinition(
            identifier: BrushComponentIdentifier(component.identifier),
            ordinal: UInt8(component.ordinal),
            resources: references,
            coverage: BrushCoverageDefinition(
                shapes: [BrushShapeLayerDefinition(
                    shape: .asset(shape.resourceID),
                    combination: .replace,
                    scale: Float(max(0.05, min(2, size))),
                    rotation: Float(rotation),
                    offset: .zero
                )],
                grains: [BrushGrainLayerDefinition(
                    grain: .asset(grain.resourceID),
                    coordinateMode: textureMovement >= 0.5
                        ? .brushLocal
                        : .canonical,
                    transform: BrushGrainTransform(
                        scale: Float(max(0.05, min(8, textureScale))),
                        rotation: 0,
                        offset: .zero
                    ),
                    grainMovementFraction: Float(
                        max(0, min(1, textureMovement))
                    ),
                    grainFollowsBrushRotation: textureMovement >= 0.5,
                    strength: Float(max(0.05, min(1, grainDepth)))
                )],
                baseHardness: Float(max(0.2, min(1, tiltRoundness))),
                aspectRatio: 0.55,
                tipThreshold: 0.01,
                antialiasing: true
            ),
            placement: BrushPlacementDefinition(
                baseSpacingFraction: Float(max(0.005, min(1, spacing))),
                maximumSpacingFraction: Float(max(0.01, min(1, spacing * 2))),
                baseFlow: Float(max(0.1, min(1, grainDepth * 0.7))),
                strokeOpacity: Float(max(0.05, min(1, opacity))),
                baseScatterFraction: Float(max(0, min(1, scatter))),
                baseRotation: Float(rotation),
                baseJitterFraction: 0.02,
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
            material: BrushMaterialDefinition(
                accumulation: .flow,
                interaction: .none,
                edgeTreatment: .dryBreakup,
                strength: 1,
                wetness: 0,
                bleedRadius: 0,
                softenPasses: 0,
                accumulationLimit: 1,
                interactionParameters: nil
            ),
            taper: .none,
            sensorProgram: BrushSensorProgramDefinition(
                singleMappingDynamics: dynamics
            ),
            emission: BrushEmissionDefinition(
                mode: .distance,
                timeInterval: nil
            ),
            tipSupports: [.analyticEllipse]
        )
        return MappedComponent(
            definition: definition,
            resources: [shape, grain],
            entries: try conversionEntries(
                component: component,
                shape: shape,
                grain: grain
            )
        )
    }

    private func makeDynamics(
        pressureSize: Double,
        pressureOpacity: Double,
        tiltRoundness: Double
    ) -> BrushDynamicsDefinition {
        let zero = constant(0)
        let one = constant(1)
        return BrushDynamicsDefinition(
            size: linear(
                .pressure,
                lower: Float(max(0.1, 1 - pressureSize * 0.8)),
                upper: 1
            ),
            flow: one,
            opacity: linear(
                .pressure,
                lower: Float(max(0.05, 1 - pressureOpacity)),
                upper: 1
            ),
            spacing: one,
            rotation: zero,
            scatter: one,
            hardness: linear(
                .tilt,
                lower: Float(max(0.1, 1 - tiltRoundness * 0.75)),
                upper: 1
            ),
            grain: one,
            offsetX: zero,
            offsetY: zero,
            hue: zero,
            saturation: zero,
            brightness: zero,
            secondaryColorMix: zero,
            noPressureNeutral: 1,
            randomization: BrushRandomization(
                spacing: 0.03,
                scatter: 0.05,
                rotation: 0.03,
                grain: 0.05,
                material: 0.03
            )
        )
    }

    private func constant(_ value: Float) -> BrushMappingDefinition {
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

    private func linear(
        _ input: BrushDynamicsInput,
        lower: Float,
        upper: Float
    ) -> BrushMappingDefinition {
        BrushMappingDefinition(
            input: input,
            response: .linear,
            scale: upper - lower,
            offset: lower,
            lowerClamp: lower,
            upperClamp: upper,
            inverted: false,
            jitter: 0,
            missingInputValue: 1
        )
    }

    private func conversionEntries(
        component: ForeignBrushComponent,
        shape: ProcreateResourceSubstitution,
        grain: ProcreateResourceSubstitution
    ) throws -> [BrushConversionEntry] {
        try component.settings.map { setting in
            let qualified = qualifiedKey(
                component: component.identifier,
                setting: setting.semanticKey
            )
            let index = Int(component.ordinal)
            let mapping: ([String], String, String)? = switch setting.semanticKey {
            case ProcreateBrushSemanticKeys.bundledShapePath:
                ([
                    "components[\(index)].coverage.shapes[0]",
                    "components[\(index)].resources",
                ], shape.resourceID, shape.reason)
            case ProcreateBrushSemanticKeys.bundledGrainPath:
                ([
                    "components[\(index)].coverage.grains[0]",
                    "components[\(index)].resources",
                ], grain.resourceID, grain.reason)
            case ProcreateBrushSemanticKeys.paintSize:
                (["components[\(index)].coverage.shapes[0].scale"],
                 "native shape scale", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.plotSpacing:
                ([
                    "components[\(index)].placement.baseSpacingFraction",
                    "components[\(index)].placement.maximumSpacingFraction",
                ], "native spacing", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.paintOpacity:
                (["components[\(index)].placement.strokeOpacity"],
                 "native opacity", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.pressureSize:
                (["components[\(index)].dynamics.size"],
                 "native pressure size", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.pressureOpacity:
                (["components[\(index)].dynamics.opacity"],
                 "native pressure opacity", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.tiltSize,
                 ProcreateBrushSemanticKeys.tiltShapeRoundness:
                (["components[\(index)].dynamics.hardness"],
                 "native tilt response", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.textureScale:
                (["components[\(index)].coverage.grains[0].transform.scale"],
                 "native grain scale", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.textureMovement:
                (["components[\(index)].coverage.grains[0].grainMovementFraction"],
                 "native grain movement", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.shapeScatter:
                (["components[\(index)].placement.baseScatterFraction"],
                 "native scatter", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.shapeRotation:
                (["components[\(index)].placement.baseRotation"],
                 "native rotation", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.grainDepth,
                 ProcreateBrushSemanticKeys.grainDepthMinimum:
                (["components[\(index)].coverage.grains[0].strength"],
                 "native grain strength", "normalized-parameter-approximation")
            case ProcreateBrushSemanticKeys.dualBlendMode:
                (["composition"], "native ordered source-over",
                 "dual-blend-mode-1-approximation")
            default:
                nil
            }
            guard let mapping else {
                return try BrushConversionEntry(
                    sourceSemanticKey: qualified,
                    nativeSemanticKeys: [],
                    disposition: .unsupported,
                    sourceSummary: summary(setting.value),
                    targetSummary: nil,
                    reasonCode: "unsupported-active-setting",
                    message:
                        "This active component field is retained but has no characterized native equivalence.",
                    requiredForFaithfulRendering: true
                )
            }
            return try BrushConversionEntry(
                sourceSemanticKey: qualified,
                nativeSemanticKeys: mapping.0.sorted(),
                disposition: .approximated,
                sourceSummary: summary(setting.value),
                targetSummary: mapping.1,
                reasonCode: mapping.2,
                message:
                    "The source field is mapped to the closest characterized dry native behavior.",
                approximation: BrushConversionApproximationEvidence(
                    metric: "bounded-dry-parameter-map",
                    relativeError: 0
                )
            )
        }.sorted { $0.sourceSemanticKey < $1.sourceSemanticKey }
    }

    private func qualifiedKey(component: String, setting: String) -> String {
        let prefix = "procreate.classic.v1."
        let suffix = setting.hasPrefix(prefix)
            ? String(setting.dropFirst(prefix.count))
            : setting
        return "\(prefix)component.\(component).\(suffix)"
    }

    private func scalar(
        _ key: String,
        component: ForeignBrushComponent,
        settings: [String: ForeignBrushSetting]
    ) throws -> Double {
        guard let setting = settings[key] else {
            throw ProcreateClassicV1MappingError.missingSetting(
                component: component.identifier,
                key: key
            )
        }
        guard case let .scalar(value) = setting.value else {
            throw ProcreateClassicV1MappingError.invalidSetting(
                component: component.identifier,
                key: key
            )
        }
        return value
    }

    private func optionalScalar(
        _ key: String,
        settings: [String: ForeignBrushSetting],
        defaultValue: Double
    ) throws -> Double {
        guard let setting = settings[key] else { return defaultValue }
        guard case let .scalar(value) = setting.value else {
            throw ProcreateClassicV1MappingError.invalidSetting(
                component: "unknown",
                key: key
            )
        }
        return value
    }

    private func token(
        _ key: String,
        component: ForeignBrushComponent,
        settings: [String: ForeignBrushSetting]
    ) throws -> String {
        guard let setting = settings[key] else {
            throw ProcreateClassicV1MappingError.missingSetting(
                component: component.identifier,
                key: key
            )
        }
        guard case let .token(value) = setting.value else {
            throw ProcreateClassicV1MappingError.invalidSetting(
                component: component.identifier,
                key: key
            )
        }
        return value
    }

    private func summary(_ value: ForeignBrushSettingValue) -> String {
        switch value {
        case .null: "null"
        case let .boolean(value): "boolean:\(value)"
        case let .integer(value): "integer:\(value)"
        case let .scalar(value): "scalar:\(value)"
        case let .token(value): "token:\(value)"
        case let .vector(value): "vector:\(value.count)"
        case let .curve(value): "curve:\(value.count)"
        case .color: "color:rgba"
        case let .resourceReference(value): "resource:\(value)"
        }
    }

    private func conversionDiagnostics(
        _ diagnostics: [ForeignBrushDiagnostic]
    ) throws -> [BrushConversionDiagnostic] {
        try diagnostics.map { diagnostic in
            let severity: BrushConversionDiagnosticSeverity
            switch diagnostic.severity {
            case .information:
                severity = .info
            case .warning:
                severity = .warning
            case .error:
                severity = .error
            }
            return try BrushConversionDiagnostic(
                severity: severity,
                code: diagnostic.code,
                message: diagnostic.message,
                location: diagnostic.location
            )
        }.sorted {
            diagnosticSortKey($0) < diagnosticSortKey($1)
        }
    }

    private func diagnosticSortKey(
        _ diagnostic: BrushConversionDiagnostic
    ) -> String {
        [
            diagnostic.location ?? "",
            diagnostic.code,
            diagnostic.severity.rawValue,
            diagnostic.message,
        ].joined(separator: "\u{001F}")
    }

    private struct MappedComponent {
        let definition: BrushComponentDefinition
        let resources: [ProcreateResourceSubstitution]
        let entries: [BrushConversionEntry]
    }
}
