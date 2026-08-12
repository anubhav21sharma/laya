import CryptoKit
import EditorCore
@preconcurrency import Foundation
import MetalRenderer
import PatternEngine
import SwiftUI

struct StageDAppRouteConfiguration: Equatable, Sendable {
    static let manifestEnvironmentKey = "STAGE_D_ACCEPTANCE_MANIFEST"
    static let projectEnvironmentKey = "STAGE_D_ACCEPTANCE_PROJECT"
    static let exportEnvironmentKey = "STAGE_D_ACCEPTANCE_EXPORT"
    static let commitEnvironmentKey = "STAGE_D_ACCEPTANCE_COMMIT"
    static let dateEnvironmentKey = "STAGE_D_ACCEPTANCE_DATE"

    let manifestURL: URL
    let projectURL: URL
    let exportURL: URL
    let gitCommit: String
    let generatedAt: Date

    init?(environment: [String: String]) {
        guard let manifest = environment[Self.manifestEnvironmentKey],
              let project = environment[Self.projectEnvironmentKey],
              let export = environment[Self.exportEnvironmentKey],
              let commit = environment[Self.commitEnvironmentKey],
              let dateValue = environment[Self.dateEnvironmentKey],
              let date = ISO8601DateFormatter().date(from: dateValue)
        else { return nil }
        manifestURL = Self.artifactURL(manifest)
        projectURL = Self.artifactURL(project)
        exportURL = Self.artifactURL(export)
        gitCommit = commit
        generatedAt = date
    }

    private static func artifactURL(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(path)
    }
}

enum StageDAppRouteRequirements {
    static let routeIDsByScenario: [String: [String]] = [
        StageDAcceptanceRequirements.appControls: [
            "controls.initial",
            "controls.brush-size",
            "controls.brush-selection",
            "controls.ink-color",
            "controls.draw",
            "controls.erase-tool",
            "controls.erase",
            "controls.undo-erase",
            "controls.redo-erase",
            "controls.layer-add",
            "controls.layer-lock",
            "controls.layer-unlock",
            "controls.layer-hide",
            "controls.layer-show",
            "controls.layer-select-painted",
            "controls.clear-painted-layer",
            "controls.undo-clear-restores",
            "controls.mode-half-drop",
            "controls.resize",
        ],
        StageDAcceptanceRequirements.appShortcuts: [
            "shortcuts.hud-show",
            "shortcuts.hud-hide",
            "shortcuts.grid",
            "shortcuts.mode",
            "shortcuts.undo",
            "shortcuts.redo",
            "shortcuts.numeric-field-owns-digit",
        ],
        StageDAcceptanceRequirements.appPersistence: [
            "persistence.save",
            "persistence.open-atomic-replacement",
            "persistence.flattened-png-export",
        ],
    ]

    static let orderedRoutes: [(scenarioID: String, routeID: String)] = [
        StageDAcceptanceRequirements.appControls,
        StageDAcceptanceRequirements.appShortcuts,
        StageDAcceptanceRequirements.appPersistence,
    ].flatMap { scenarioID in
        routeIDsByScenario[scenarioID, default: []].map {
            (scenarioID: scenarioID, routeID: $0)
        }
    }
}

private struct StageDAppRouteRecord: Codable, Equatable, Sendable {
    let routeID: String
    let tool: String
    let selectedBrushID: String
    let brushDiameter: Float
    let showGrid: Bool
    let documentConfiguration: String
    let pixelWidth: Int
    let pixelHeight: Int
    let layerIDs: [String]
    let activeLayerID: String
    let activeLayerIndex: Int
    let inkColorRGBA8Hex: String
    let canUndo: Bool
    let canRedo: Bool
    let canonicalSHA256: String
    let nativeIdentitySHA256: String
    let flattenedBGRA8SHA256: String
    let paintedPixelCount: Int
    let normalizedInputs: [StageDNormalizedInputRecord]
    let documentGeneration: UInt64
    let residentTileBytes: Int
    let residentTileHighWaterBytes: Int
    let revisionResidentBytes: Int
    let tileIndexEntryCount: Int
    let cpuCachedPlanCount: Int
    let gpuCachedPlanCount: Int
    let cachedPlanMetalBufferBytes: Int
    let pendingOwnershipCount: Int
    let activeSnapshotTokenCount: Int
    let retainedDisplaySnapshotTokenCount: Int
    let retainedHistorySnapshotTokenCount: Int
    let snapshotOwnershipAccountingMismatchCount: Int
    let activeTileLeaseCount: Int
    let activeStrokeSurfaceCount: Int
    let activeCommandOperationCount: Int
    let pendingLayerDisplayAcknowledgementCount: Int
    let activeUploadSlotCount: Int
    let pendingPlanCompletionCount: Int
    let pendingConsumerCompletionCount: Int
    let retainedSnapshotReferenceCount: Int
    let projectFileBytes: Int
    let exportFileBytes: Int
    let exportFilePrefixHex: String
}

private struct StageDNormalizedInputRecord:
    Codable,
    Equatable,
    Sendable
{
    let sequence: Int
    let x: Float
    let y: Float
    let pressure: Float
    let timestampFromStrokeStart: TimeInterval
    let altitude: Float?
    let azimuth: Float?
    let roll: Float?
    let tangentialPressure: Float?
    let estimationUpdateIndex: Int?
    let estimatedProperties: UInt8
    let estimatedPropertiesExpectingUpdates: UInt8
    let phase: UInt8
    let source: UInt8
    let kind: UInt8
    let capabilities: UInt8
}

private struct StageDAppRouteSemanticRecord: Codable, Sendable {
    let routeID: String
    let tool: String
    let selectedBrushID: String
    let brushDiameter: Float
    let showGrid: Bool
    let documentConfiguration: String
    let pixelWidth: Int
    let pixelHeight: Int
    let layerCount: Int
    let activeLayerIndex: Int
    let inkColorRGBA8Hex: String
    let canUndo: Bool
    let canRedo: Bool
    let paintedContentPresent: Bool
    let normalizedStrokes: [StageDNormalizedStrokeSemanticRecord]
    let documentGeneration: UInt64

    init(_ record: StageDAppRouteRecord) {
        routeID = record.routeID
        tool = record.tool
        selectedBrushID = record.selectedBrushID
        brushDiameter = record.brushDiameter
        showGrid = record.showGrid
        documentConfiguration = record.documentConfiguration
        pixelWidth = record.pixelWidth
        pixelHeight = record.pixelHeight
        layerCount = record.layerIDs.count
        activeLayerIndex = record.activeLayerIndex
        inkColorRGBA8Hex = record.inkColorRGBA8Hex
        canUndo = record.canUndo
        canRedo = record.canRedo
        paintedContentPresent = record.paintedPixelCount > 0
        normalizedStrokes = StageDNormalizedStrokeSemanticRecord
            .canonicalStrokes(from: record.normalizedInputs)
        documentGeneration = record.documentGeneration
    }
}

private struct StageDNormalizedStrokeSemanticRecord: Codable, Sendable {
    let ordinal: Int
    let startXQuarterPixels: Int
    let startYQuarterPixels: Int
    let endXQuarterPixels: Int
    let endYQuarterPixels: Int
    let startPressure1024: Int
    let endPressure1024: Int
    let source: UInt8
    let capabilities: UInt8
    let terminalPhase: UInt8

    static func canonicalStrokes(
        from inputs: [StageDNormalizedInputRecord]
    ) -> [Self] {
        var result: [Self] = []
        var start: StageDNormalizedInputRecord?
        for input in inputs {
            if input.phase == StrokePhase.began.rawValue {
                start = input
            }
            guard input.phase == StrokePhase.ended.rawValue
                    || input.phase == StrokePhase.cancelled.rawValue,
                  let strokeStart = start
            else { continue }
            result.append(Self(
                ordinal: result.count,
                startXQuarterPixels: quantize(input: strokeStart.x),
                startYQuarterPixels: quantize(input: strokeStart.y),
                endXQuarterPixels: quantize(input: input.x),
                endYQuarterPixels: quantize(input: input.y),
                startPressure1024: quantizePressure(strokeStart.pressure),
                endPressure1024: quantizePressure(input.pressure),
                source: strokeStart.source,
                capabilities: strokeStart.capabilities,
                terminalPhase: input.phase
            ))
            start = nil
        }
        return result
    }

    private static func quantize(input: Float) -> Int {
        Int((input * 4).rounded())
    }

    private static func quantizePressure(_ input: Float) -> Int {
        Int((input * 1_024).rounded())
    }
}

private struct StageDNativeArchiveEvidence: Sendable {
    let contentSHA256: String
    let identitySHA256: String
}

@MainActor
final class StageDAppRouteEvidenceRecorder {
    nonisolated static let scenarioUserInfoKey = "scenarioID"
    nonisolated static let routeUserInfoKey = "routeID"
    nonisolated static let strokeSeed: UInt64 = 0x5354_4147_4544

    let configuration: StageDAppRouteConfiguration?

    private weak var controller: EditorSessionController?
    private var records: [String: [StageDAppRouteRecord]] = [:]
    private var normalizedInputs: [StageDNormalizedInputRecord] = []
    private var strokeTimestampOrigin: TimeInterval?
    private var previousNormalizedInput: ((StrokeSample) -> Void)?
    private var nextRouteIndex = 0
    private var lastRecordedRoute: (
        scenarioID: String,
        routeID: String
    )?
    private let quiescenceTimeoutNanoseconds: UInt64
    private var captureOrExportOperationIsActive = false

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        quiescenceTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        precondition(quiescenceTimeoutNanoseconds > 0)
        configuration = StageDAppRouteConfiguration(environment: environment)
        self.quiescenceTimeoutNanoseconds = quiescenceTimeoutNanoseconds
    }

    var isEnabled: Bool { configuration != nil }
    var projectURL: URL? { configuration?.projectURL }
    var exportURL: URL? { configuration?.exportURL }

    func bind(_ controller: EditorSessionController) {
        guard self.controller !== controller else { return }
        detachCurrentController()
        self.controller = controller
        guard configuration != nil else { return }
        try? controller.setDiagnosticFixedStrokeSeed(Self.strokeSeed)
        let forwarded = controller.onNormalizedInput
        previousNormalizedInput = forwarded
        controller.onNormalizedInput = { [weak self] sample in
            forwarded?(sample)
            self?.recordNormalizedInput(sample)
        }
    }

    func unbind(_ controller: EditorSessionController) {
        guard self.controller === controller else { return }
        detachCurrentController()
    }

    private func detachCurrentController() {
        guard let controller else { return }
        if configuration != nil {
            controller.onNormalizedInput = previousNormalizedInput
            try? controller.setDiagnosticFixedStrokeSeed(nil)
        }
        previousNormalizedInput = nil
        self.controller = nil
    }

    private func recordNormalizedInput(_ sample: StrokeSample) {
        if sample.phase == .began || strokeTimestampOrigin == nil {
            strokeTimestampOrigin = sample.timestamp
        }
        let origin = strokeTimestampOrigin ?? sample.timestamp
        normalizedInputs.append(StageDNormalizedInputRecord(
            sequence: normalizedInputs.count,
            x: sample.position.x,
            y: sample.position.y,
            pressure: sample.pressure,
            timestampFromStrokeStart: sample.timestamp - origin,
            altitude: sample.altitude,
            azimuth: sample.azimuth,
            roll: sample.roll,
            tangentialPressure: sample.tangentialPressure,
            estimationUpdateIndex: sample.estimationUpdateIndex,
            estimatedProperties: sample.estimatedProperties.rawValue,
            estimatedPropertiesExpectingUpdates:
                sample.estimatedPropertiesExpectingUpdates.rawValue,
            phase: sample.phase.rawValue,
            source: sample.source.rawValue,
            kind: sample.kind.rawValue,
            capabilities: sample.capabilities.rawValue
        ))
        if sample.phase == .ended || sample.phase == .cancelled {
            strokeTimestampOrigin = nil
        }
    }

    func record(
        scenarioID: String,
        routeID: String,
        progress: @MainActor (String) -> Void = { _ in }
    ) async throws {
        guard let configuration, let controller else { return }
        guard let requiredRouteIDs =
                StageDAppRouteRequirements.routeIDsByScenario[scenarioID],
              requiredRouteIDs.contains(routeID)
        else { return }

        let renderer = controller.renderer
        let started = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = started.addingReportingOverflow(
            quiescenceTimeoutNanoseconds
        )
        guard !overflow else {
            throw StageDAppRouteEvidenceError.quiescenceTimedOut
        }
        try await acquireCaptureOrExportOperation(deadline: deadline)
        defer { releaseCaptureOrExportOperation() }
        try await renderer.suspendPaintDisplayPreparationForCapture(
            deadlineUptimeNanoseconds: deadline
        )
        defer {
            try? renderer.resumePaintDisplayPreparationAfterCapture()
        }
        progress("controller-quiescence")
        try await awaitQuiescence(controller, deadline: deadline)
        progress("renderer-evidence")
        let rendererEvidence = await controller.renderer
            .stageDAcceptanceEvidence()
        progress("native-archive")
        let native = try Self.nativeArchiveEvidence(controller.renderer)
        progress("flattened-export")
        let flattened = try await controller.renderer.exportFlattenedScene(
            pixelSize: controller.model.pixelSize,
            transparentBackground: true
        )
        progress("manifest")
        let flattenedBytes = flattened.bgra8Bytes
        let history = controller.historyAvailabilityForTesting
        let stack = controller.currentLayerStack
        let projectData = try? Data(contentsOf: configuration.projectURL)
        let exportData = try? Data(contentsOf: configuration.exportURL)
        let record = StageDAppRouteRecord(
            routeID: routeID,
            tool: String(describing: controller.model.tool),
            selectedBrushID: controller.model.selectedRecipeID.rawValue,
            brushDiameter: controller.model.brushDiameter,
            showGrid: controller.model.showGrid,
            documentConfiguration: String(
                describing: controller.model.documentConfiguration
            ),
            pixelWidth: controller.model.pixelSize.width,
            pixelHeight: controller.model.pixelSize.height,
            layerIDs: stack.layers.map { $0.id.uuidString.lowercased() },
            activeLayerID: stack.activeLayerID.uuidString.lowercased(),
            activeLayerIndex: stack.layers.firstIndex {
                $0.id == stack.activeLayerID
            } ?? -1,
            inkColorRGBA8Hex: Self.inkColorRGBA8Hex(
                controller.model.inkColor
            ),
            canUndo: history.canUndo,
            canRedo: history.canRedo,
            canonicalSHA256: native.contentSHA256,
            nativeIdentitySHA256: native.identitySHA256,
            flattenedBGRA8SHA256: Self.sha256(Data(flattenedBytes)),
            paintedPixelCount: stride(
                from: 3,
                to: flattenedBytes.count,
                by: 4
            ).reduce(into: 0) { count, index in
                if flattenedBytes[index] != 0 { count += 1 }
            },
            normalizedInputs: normalizedInputs,
            documentGeneration: rendererEvidence.documentGeneration,
            residentTileBytes: rendererEvidence.residentTileBytes,
            residentTileHighWaterBytes:
                rendererEvidence.residentTileHighWaterBytes,
            revisionResidentBytes: rendererEvidence.revisionResidentBytes,
            tileIndexEntryCount: rendererEvidence.tileIndexEntryCount,
            cpuCachedPlanCount: rendererEvidence.cpuCachedPlanCount,
            gpuCachedPlanCount: rendererEvidence.gpuCachedPlanCount,
            cachedPlanMetalBufferBytes:
                rendererEvidence.cachedPlanMetalBufferBytes,
            pendingOwnershipCount: rendererEvidence.pendingOwnershipCount,
            activeSnapshotTokenCount:
                rendererEvidence.activeSnapshotTokenCount,
            retainedDisplaySnapshotTokenCount:
                rendererEvidence.retainedDisplaySnapshotTokenCount,
            retainedHistorySnapshotTokenCount:
                rendererEvidence.retainedHistorySnapshotTokenCount,
            snapshotOwnershipAccountingMismatchCount:
                rendererEvidence.snapshotOwnershipAccountingMismatchCount,
            activeTileLeaseCount: rendererEvidence.activeTileLeaseCount,
            activeStrokeSurfaceCount:
                rendererEvidence.activeStrokeSurfaceCount,
            activeCommandOperationCount:
                rendererEvidence.activeCommandOperationCount,
            pendingLayerDisplayAcknowledgementCount:
                rendererEvidence.pendingLayerDisplayAcknowledgementCount,
            activeUploadSlotCount:
                rendererEvidence.activeUploadSlotCount,
            pendingPlanCompletionCount:
                rendererEvidence.pendingPlanCompletionCount,
            pendingConsumerCompletionCount:
                rendererEvidence.pendingConsumerCompletionCount,
            retainedSnapshotReferenceCount:
                rendererEvidence.aggregateSnapshotReferenceCount,
            projectFileBytes: projectData?.count ?? 0,
            exportFileBytes: exportData?.count ?? 0,
            exportFilePrefixHex: exportData.map {
                $0.prefix(8).map { String(format: "%02x", $0) }.joined()
            } ?? ""
        )
        var scenarioRecords = records[scenarioID, default: []]
        scenarioRecords.removeAll { $0.routeID == routeID }
        scenarioRecords.append(record)
        records[scenarioID] = scenarioRecords
        try writeManifest(configuration: configuration)
    }

    private func awaitQuiescence(
        _ controller: EditorSessionController,
        deadline: UInt64
    ) async throws {
        _ = try await controller.renderer
            .completePendingInteractiveStrokeAndAwaitIdle(
                deadlineUptimeNanoseconds: deadline
            )
        while controller.model.isBusy {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw StageDAppRouteEvidenceError.quiescenceTimedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        _ = try await controller.renderer
            .completePendingInteractiveStrokeAndAwaitIdle(
                deadlineUptimeNanoseconds: deadline
            )
        guard !controller.model.isBusy, controller.renderer.isIdle else {
            throw StageDAppRouteEvidenceError.quiescenceTimedOut
        }
    }

    func withAcceptanceDisplayPreparationSuspended<Result>(
        for controller: EditorSessionController,
        operation: () async throws -> Result
    ) async throws -> Result {
        guard configuration != nil, self.controller === controller else {
            return try await operation()
        }
        try await acquireCaptureOrExportOperation(deadline: nil)
        defer { releaseCaptureOrExportOperation() }
        try await controller.renderer
            .suspendPaintDisplayPreparationForCapture()
        defer {
            try? controller.renderer.resumePaintDisplayPreparationAfterCapture()
        }
        return try await operation()
    }

    private func acquireCaptureOrExportOperation(
        deadline: UInt64?
    ) async throws {
        while captureOrExportOperationIsActive {
            if let deadline,
               DispatchTime.now().uptimeNanoseconds >= deadline
            {
                throw StageDAppRouteEvidenceError.quiescenceTimedOut
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        captureOrExportOperationIsActive = true
    }

    private func releaseCaptureOrExportOperation() {
        captureOrExportOperationIsActive = false
    }

    func recordNext(
        progress: @MainActor (String) -> Void = { _ in }
    ) async throws -> (
        scenarioID: String,
        routeID: String
    ) {
        guard nextRouteIndex < StageDAppRouteRequirements.orderedRoutes.count
        else {
            throw StageDAppRouteEvidenceError.routeSequenceExhausted
        }
        let route = StageDAppRouteRequirements.orderedRoutes[nextRouteIndex]
        try await record(
            scenarioID: route.scenarioID,
            routeID: route.routeID,
            progress: progress
        )
        nextRouteIndex += 1
        lastRecordedRoute = route
        return route
    }

    func rerecordLast(
        progress: @MainActor (String) -> Void = { _ in }
    ) async throws -> (
        scenarioID: String,
        routeID: String
    ) {
        guard let route = lastRecordedRoute else {
            throw StageDAppRouteEvidenceError.noRouteToRerecord
        }
        try await record(
            scenarioID: route.scenarioID,
            routeID: route.routeID,
            progress: progress
        )
        return route
    }

    func responseJSON(for scenarioID: String) throws -> String {
        guard let configuration else { return "" }
        let data = try Data(contentsOf: configuration.manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rows = root["rows"] as? [[String: Any]],
              let row = rows.first(where: {
                  $0["scenarioID"] as? String == scenarioID
              })
        else { return "" }
        let response = try JSONSerialization.data(
            withJSONObject: row,
            options: [.sortedKeys]
        )
        return String(decoding: response, as: UTF8.self)
    }

    private func writeManifest(
        configuration: StageDAppRouteConfiguration
    ) throws {
        let traceEncoder = JSONEncoder()
        traceEncoder.outputFormatting = [.sortedKeys]
        let rows: [StageDAcceptanceRow] = records.keys.sorted().compactMap {
            scenarioID in
            guard let routeRecords = records[scenarioID],
                  let latest = routeRecords.last,
                  let traceData = try? traceEncoder.encode(routeRecords),
                  let trace = String(data: traceData, encoding: .utf8),
                  let requiredRouteIDs = StageDAppRouteRequirements
                    .routeIDsByScenario[scenarioID],
                  let semanticData = try? traceEncoder.encode(
                    routeRecords.map(StageDAppRouteSemanticRecord.init)
                  )
            else { return nil }
            let allQuiescent = routeRecords.allSatisfy {
                $0.pendingOwnershipCount == 0
            }
            let routesComplete = routeRecords.map(\.routeID).sorted()
                == requiredRouteIDs.sorted()
            let semanticsProven = Self.provesScenarioSemantics(
                scenarioID: scenarioID,
                records: routeRecords
            )
            return StageDAcceptanceRow(
                scenarioID: scenarioID,
                producer: .applicationRoute,
                seed: 0x5354_4147_4544,
                inputTrace: trace,
                expectedSemanticHash: nil,
                numericOracle: .init(
                    expected: Double(requiredRouteIDs.count),
                    actual: Double(routeRecords.count),
                    tolerance: 0
                ),
                status: allQuiescent && routesComplete && semanticsProven
                    ? .passed : .failed,
                backend: .productionSparseMetal,
                metrics: [
                    "routeCount": Double(routeRecords.count),
                    "documentGeneration": Double(
                        latest.documentGeneration
                    ),
                    "residentTileBytes": Double(latest.residentTileBytes),
                    "residentTileHighWaterBytes": Double(
                        latest.residentTileHighWaterBytes
                    ),
                    "revisionResidentBytes": Double(
                        latest.revisionResidentBytes
                    ),
                    "tileIndexEntryCount": Double(
                        latest.tileIndexEntryCount
                    ),
                    "cpuCachedPlanCount": Double(latest.cpuCachedPlanCount),
                    "gpuCachedPlanCount": Double(latest.gpuCachedPlanCount),
                    "cachedPlanMetalBufferBytes": Double(
                        latest.cachedPlanMetalBufferBytes
                    ),
                    "pendingOwnershipCount": Double(
                        latest.pendingOwnershipCount
                    ),
                    "snapshotOwnershipAccountingMismatchCount": Double(
                        latest.snapshotOwnershipAccountingMismatchCount
                    ),
                    "retainedSnapshotReferenceCount": Double(
                        latest.retainedSnapshotReferenceCount
                    ),
                    "projectFileBytes": Double(latest.projectFileBytes),
                    "exportFileBytes": Double(latest.exportFileBytes),
                ],
                attributes: [
                    "lastRouteID": latest.routeID,
                    "canonicalSHA256": latest.canonicalSHA256,
                    "nativeIdentitySHA256": latest.nativeIdentitySHA256,
                    "flattenedBGRA8SHA256":
                        latest.flattenedBGRA8SHA256,
                    "paintedPixelCount": String(latest.paintedPixelCount),
                    "normalizedInputCount": String(
                        latest.normalizedInputs.count
                    ),
                    "activeLayerID": latest.activeLayerID,
                    "layerIDs": latest.layerIDs.joined(separator: ","),
                    "inkColorRGBA8Hex": latest.inkColorRGBA8Hex,
                    "selectedBrushID": latest.selectedBrushID,
                    "tool": latest.tool,
                    "showGrid": String(latest.showGrid),
                    "canUndo": String(latest.canUndo),
                    "canRedo": String(latest.canRedo),
                    "retainedSnapshotReferenceCount": String(
                        latest.retainedSnapshotReferenceCount
                    ),
                    "snapshotOwnershipAccountingMismatchCount": String(
                        latest.snapshotOwnershipAccountingMismatchCount
                    ),
                    "projectFileBytes": String(latest.projectFileBytes),
                    "exportFileBytes": String(latest.exportFileBytes),
                    "exportFilePrefixHex": latest.exportFilePrefixHex,
                    "observedSemanticHash": Self.sha256(semanticData),
                ]
            )
        }
        let manifest = StageDAcceptanceManifest(
            generatedAt: configuration.generatedAt,
            gitCommit: configuration.gitCommit,
            rows: rows
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(manifest)
        data.append(0x0a)
        let directory = configuration.manifestURL
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: configuration.manifestURL,
            options: Data.WritingOptions.atomic
        )
    }

    private static func provesScenarioSemantics(
        scenarioID: String,
        records: [StageDAppRouteRecord]
    ) -> Bool {
        let byRoute = Dictionary(uniqueKeysWithValues: records.map {
            ($0.routeID, $0)
        })
        switch scenarioID {
        case StageDAcceptanceRequirements.appControls:
            guard let initial = byRoute["controls.initial"],
                  let sized = byRoute["controls.brush-size"],
                  let brush = byRoute["controls.brush-selection"],
                  let color = byRoute["controls.ink-color"],
                  let drawn = byRoute["controls.draw"],
                  let eraseTool = byRoute["controls.erase-tool"],
                  let erased = byRoute["controls.erase"],
                  let undoneErase = byRoute["controls.undo-erase"],
                  let redoneErase = byRoute["controls.redo-erase"],
                  let layerAdded = byRoute["controls.layer-add"],
                  let layerLocked = byRoute["controls.layer-lock"],
                  let layerUnlocked = byRoute["controls.layer-unlock"],
                  let layerHidden = byRoute["controls.layer-hide"],
                  let layerShown = byRoute["controls.layer-show"],
                  let layerSelected = byRoute[
                    "controls.layer-select-painted"
                  ],
                  let cleared = byRoute["controls.clear-painted-layer"],
                  let restored = byRoute["controls.undo-clear-restores"],
                  let mode = byRoute["controls.mode-half-drop"],
                  let resized = byRoute["controls.resize"]
            else { return false }

            let drawStrokeCount = canonicalStrokeCount(drawn)
            let eraseStrokeCount = canonicalStrokeCount(erased)
            return initial.paintedPixelCount == 0
                && sized.brushDiameter > initial.brushDiameter
                && brush.selectedBrushID
                    == "builtin.native-dry-media"
                && color.inkColorRGBA8Hex == "10738cff"
                && drawn.paintedPixelCount > 0
                && drawn.flattenedBGRA8SHA256
                    != initial.flattenedBGRA8SHA256
                && drawStrokeCount == 1
                && eraseTool.tool == String(describing: EditorTool.erase)
                && erased.flattenedBGRA8SHA256
                    != drawn.flattenedBGRA8SHA256
                && eraseStrokeCount == drawStrokeCount + 1
                && undoneErase.flattenedBGRA8SHA256
                    == drawn.flattenedBGRA8SHA256
                && undoneErase.canRedo
                && redoneErase.flattenedBGRA8SHA256
                    == erased.flattenedBGRA8SHA256
                && !redoneErase.canRedo
                && layerAdded.layerIDs.count
                    == initial.layerIDs.count + 1
                && layerAdded.activeLayerIndex == 1
                && layerLocked.canonicalSHA256
                    != layerAdded.canonicalSHA256
                && layerUnlocked.canonicalSHA256
                    == layerAdded.canonicalSHA256
                && layerHidden.canonicalSHA256
                    != layerUnlocked.canonicalSHA256
                && layerShown.canonicalSHA256
                    == layerUnlocked.canonicalSHA256
                && layerSelected.activeLayerIndex == 0
                && cleared.paintedPixelCount == 0
                && cleared.flattenedBGRA8SHA256
                    != layerSelected.flattenedBGRA8SHA256
                && restored.flattenedBGRA8SHA256
                    == layerSelected.flattenedBGRA8SHA256
                && restored.paintedPixelCount > 0
                && mode.documentConfiguration
                    != restored.documentConfiguration
                && resized.pixelWidth == 320
                && resized.pixelHeight == 192
                && resized.paintedPixelCount > 0
        case StageDAcceptanceRequirements.appShortcuts:
            guard let hudShown = byRoute["shortcuts.hud-show"],
                  let hudHidden = byRoute["shortcuts.hud-hide"],
                  let grid = byRoute["shortcuts.grid"],
                  let mode = byRoute["shortcuts.mode"],
                  let undo = byRoute["shortcuts.undo"],
                  let redo = byRoute["shortcuts.redo"],
                  let field = byRoute[
                    "shortcuts.numeric-field-owns-digit"
                  ]
            else { return false }
            return hudShown.flattenedBGRA8SHA256
                    == hudHidden.flattenedBGRA8SHA256
                && grid.showGrid != hudHidden.showGrid
                && mode.documentConfiguration
                    != grid.documentConfiguration
                && undo.canRedo
                && !redo.canRedo
                && field.documentConfiguration
                    == redo.documentConfiguration
                && field.paintedPixelCount > 0
        case StageDAcceptanceRequirements.appPersistence:
            guard let saved = byRoute["persistence.save"],
                  let opened = byRoute[
                    "persistence.open-atomic-replacement"
                  ],
                  let exported = byRoute[
                    "persistence.flattened-png-export"
                  ]
            else { return false }
            let samePersistentState = [opened, exported].allSatisfy {
                $0.canonicalSHA256 == saved.canonicalSHA256
                    && $0.nativeIdentitySHA256
                        == saved.nativeIdentitySHA256
                    && $0.flattenedBGRA8SHA256
                        == saved.flattenedBGRA8SHA256
                    && $0.paintedPixelCount == saved.paintedPixelCount
                    && $0.layerIDs == saved.layerIDs
                    && $0.activeLayerID == saved.activeLayerID
                    && $0.activeLayerIndex == saved.activeLayerIndex
                    && $0.documentConfiguration
                        == saved.documentConfiguration
                    && $0.pixelWidth == saved.pixelWidth
                    && $0.pixelHeight == saved.pixelHeight
            }
            return saved.paintedPixelCount > 0
                && saved.canUndo
                && !saved.canRedo
                && !opened.canUndo
                && !opened.canRedo
                && !exported.canUndo
                && !exported.canRedo
                && samePersistentState
        default:
            return false
        }
    }

    private static func canonicalStrokeCount(
        _ record: StageDAppRouteRecord
    ) -> Int {
        StageDNormalizedStrokeSemanticRecord.canonicalStrokes(
            from: record.normalizedInputs
        ).count
    }

    private static func nativeArchiveEvidence(
        _ renderer: GridRenderer
    ) throws -> StageDNativeArchiveEvidence {
        let capture = try renderer.captureNativeArchive()
        defer { capture.close() }

        var contentHasher = SHA256()
        var identityHasher = SHA256()
        func updateBoth(_ value: String) {
            update(&contentHasher, value: value)
            update(&identityHasher, value: value)
        }

        let geometry = capture.geometry
        updateBoth("document-width:\(geometry.documentPixelSize.width)")
        updateBoth("document-height:\(geometry.documentPixelSize.height)")
        updateBoth("storage-width:\(geometry.storagePixelSize.width)")
        updateBoth("storage-height:\(geometry.storagePixelSize.height)")
        if let radial = geometry.radialLayout {
            updateBoth("radial-radius:\(radial.maximumRadius.bitPattern)")
            updateBoth("radial-angle:\(radial.sectorAngleRadians.bitPattern)")
        } else {
            updateBoth("radial:none")
        }
        updateBoth("layer-count:\(capture.layerStack.layers.count)")
        let activeIndex = capture.layerStack.layers.firstIndex {
            $0.id == capture.layerStack.activeLayerID
        } ?? -1
        updateBoth("active-index:\(activeIndex)")

        guard capture.layers.map(\.layerID)
                == capture.layerStack.orderedLayerIDs
        else {
            throw DocumentPaintNativeArchiveImportError.layerStackMismatch(
                expected: capture.layerStack.orderedLayerIDs,
                actual: capture.layers.map(\.layerID)
            )
        }
        for (descriptor, layer) in zip(
            capture.layerStack.layers,
            capture.layers
        ) {
            update(&contentHasher, value: "layer-name:\(descriptor.name)")
            update(&contentHasher, value: "visible:\(descriptor.isVisible)")
            update(&contentHasher, value: "opacity:\(descriptor.opacity.bitPattern)")
            update(&contentHasher, value: "locked:\(descriptor.isLocked)")
            update(&contentHasher, value: "blend:\(descriptor.blendMode.rawValue)")
            update(&identityHasher, value: "layer-id:\(descriptor.id.uuidString.lowercased())")
            update(&identityHasher, value: "layer-name:\(descriptor.name)")
            update(&identityHasher, value: "visible:\(descriptor.isVisible)")
            update(&identityHasher, value: "opacity:\(descriptor.opacity.bitPattern)")
            update(&identityHasher, value: "locked:\(descriptor.isLocked)")
            update(&identityHasher, value: "blend:\(descriptor.blendMode.rawValue)")
            update(&identityHasher, value: "raster-revision:\(layer.rasterRevision)")

            let tiles = layer.tiles.sorted {
                ($0.coordinate, $0.persistedID.uuidString)
                    < ($1.coordinate, $1.persistedID.uuidString)
            }
            updateBoth("tile-count:\(tiles.count)")
            for tile in tiles {
                updateBoth("coordinate:\(tile.coordinate.x),\(tile.coordinate.y)")
                updateBoth(
                    "bounds:\(tile.logicalBounds.minX),"
                        + "\(tile.logicalBounds.minY),"
                        + "\(tile.logicalBounds.maxX),"
                        + "\(tile.logicalBounds.maxY)"
                )
                update(
                    &identityHasher,
                    value: "persisted-id:"
                        + tile.persistedID.uuidString.lowercased()
                )
                let payload = try capture.payload(
                    for: tile.persistedID
                )
                update(&contentHasher, data: payload)
                update(&identityHasher, data: payload)
            }
        }
        update(
            &identityHasher,
            value: "active-layer-id:"
                + capture.layerStack.activeLayerID.uuidString.lowercased()
        )
        return StageDNativeArchiveEvidence(
            contentSHA256: digestHex(contentHasher.finalize()),
            identitySHA256: digestHex(identityHasher.finalize())
        )
    }

    private static func update(
        _ hasher: inout SHA256,
        value: String
    ) {
        let data = Data(value.utf8)
        var count = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private static func update(
        _ hasher: inout SHA256,
        data: Data
    ) {
        var count = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private static func digestHex<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func inkColorRGBA8Hex(_ color: InkColor) -> String {
        [color.red, color.green, color.blue, color.alpha].map { component in
            let scaled = Int((component * 255).rounded())
            let byte = UInt8(max(0, min(255, scaled)))
            return String(format: "%02x", byte)
        }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum StageDAppRouteEvidenceError: LocalizedError {
    case routeSequenceExhausted
    case noRouteToRerecord
    case quiescenceTimedOut

    var errorDescription: String? {
        switch self {
        case .routeSequenceExhausted:
            "all required Stage D routes have already been recorded"
        case .noRouteToRerecord:
            "no Stage D route has been recorded yet"
        case .quiescenceTimedOut:
            "Stage D evidence could not reach controller/renderer quiescence"
        }
    }
}

@MainActor
struct StageDAppRouteEvidenceControl: View {
    let recorder: StageDAppRouteEvidenceRecorder
    let fileOperationCompletionGeneration: UInt64
    let editorFocusCompletionGeneration: UInt64
    let debugHUDVisible: Bool
    let restoreEditorFocus: @MainActor () -> Void

    @State private var response = ""
    @State private var isRecording = false

    var body: some View {
        if recorder.isEnabled {
            HStack(spacing: 8) {
                Button("Record Next Stage D Route") {
                    captureNextRoute()
                }
                .accessibilityIdentifier("Record Next Stage D Route")
                .disabled(isRecording)

                Button("Rerecord Last Stage D Route") {
                    rerecordLastRoute()
                }
                .accessibilityIdentifier("Rerecord Last Stage D Route")
                .disabled(isRecording)

                Text(isRecording ? "recording" : "ready")
                    .accessibilityIdentifier("Stage D Evidence Response")
                    .accessibilityValue(response)

                Text(debugHUDVisible ? "visible" : "hidden")
                    .accessibilityIdentifier("Stage D HUD Status")
                    .accessibilityValue(
                        debugHUDVisible ? "visible" : "hidden"
                    )

                Text(String(fileOperationCompletionGeneration))
                    .accessibilityIdentifier(
                        "Stage D File Operation Generation"
                    )
                    .accessibilityValue(
                        String(fileOperationCompletionGeneration)
                    )

                Text(String(editorFocusCompletionGeneration))
                    .accessibilityIdentifier(
                        "Stage D Editor Focus Generation"
                    )
                    .accessibilityValue(
                        String(editorFocusCompletionGeneration)
                    )
            }
            .font(.caption)
            .frame(height: 24)
        }
    }

    private func captureNextRoute() {
        capture { progress in
            try await recorder.recordNext(progress: progress)
        }
    }

    private func rerecordLastRoute() {
        capture { progress in
            try await recorder.rerecordLast(progress: progress)
        }
    }

    private func capture(
        _ operation: @escaping @MainActor (
            @escaping @MainActor (String) -> Void
        ) async throws -> (
            scenarioID: String,
            routeID: String
        )
    ) {
        isRecording = true
        response = ""
        Task { @MainActor in
            do {
                let route = try await operation { phase in
                    response = "recording:\(phase)"
                }
                response = try recorder.responseJSON(
                    for: route.scenarioID
                )
            } catch {
                response = "error: \(error.localizedDescription)"
            }
            isRecording = false
            restoreEditorFocus()
        }
    }
}
