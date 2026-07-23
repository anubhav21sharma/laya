import CShaderTypes
import Darwin
import Foundation
import Metal
import PatternEngine

@MainActor
extension HarnessRunner {
    @MainActor
    private final class GridProgramState {
        var measurements = GridMeasurements()
        var artifacts = GridArtifacts()
        var revisionStart: UInt64
        var canonicalBefore: [UInt8]?
        var taskSevenHarnessInput: TaskSevenHarnessInput?
        var taskSevenFragments: [CellFragment] = []
        var visibleCellCanonicalByteDelta: Int?
        var restoredDisplayMaximumDelta: Int?
        var previewCommitViolationCount: Int?
        var fragmentMeasurements = HarnessFragmentMeasurements()

        init(renderer: GridRenderer) {
            revisionStart = renderer.harnessRevision.rawValue
        }
    }

    func runGrid(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        guard let program = scene.program else {
            throw HarnessSceneError.missingProgram
        }
        let configuration = Self.configuration(for: scene)

        let gridRenderer: GridRenderer
        if configuration == HarnessRenderConfiguration(
            pixelSize: GridCanvasContract.defaultPixelSize,
            tiling: .grid,
            diagnosticMode: .hardRound
        ), let initialRenderer = pristineGridRenderer {
            pristineGridRenderer = nil
            gridRenderer = initialRenderer
        } else {
            gridRenderer = try GridRenderer(
                device: device,
                library: library,
                drawableSize: PatternSize(
                    width: Float(scene.width),
                    height: Float(scene.height)
                ),
                configuration: try TilingCanvasConfiguration(
                    pixelSize: configuration.pixelSize,
                    periodicConfiguration:
                        configuration.periodicConfiguration
                )
            )
        }

        let state = GridProgramState(renderer: gridRenderer)
        try executeGridProgram(
            scene: scene,
            program: program,
            configuration: configuration,
            renderer: gridRenderer,
            state: state
        )
        return try finishGridRun(
            scene: scene,
            program: program,
            configuration: configuration,
            renderer: gridRenderer,
            state: state,
            outputDirectory: outputDirectory,
            build: build
        )
    }

    private func executeGridProgram(
        scene: HarnessScene,
        program: TilingHarnessProgram,
        configuration: HarnessRenderConfiguration,
        renderer gridRenderer: GridRenderer,
        state: GridProgramState
    ) throws {
        switch program {
        case .gridInterior:
            measureHandle(
                .began,
                x: 200,
                y: 256,
                renderer: gridRenderer,
                into: &state.measurements
            )
            measureHandle(
                .moved,
                x: 240,
                y: 256,
                renderer: gridRenderer,
                into: &state.measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
            measureHandle(
                .ended,
                x: 240,
                y: 256,
                renderer: gridRenderer,
                into: &state.measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )

        case .gridBoundary:
            measureHandle(
                .began,
                x: 128,
                y: 128,
                renderer: gridRenderer,
                into: &state.measurements
            )
            measureHandle(
                .moved,
                x: 160,
                y: 160,
                renderer: gridRenderer,
                into: &state.measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
            measureHandle(
                .ended,
                x: 160,
                y: 160,
                renderer: gridRenderer,
                into: &state.measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )

        case .previewCommit:
            measureHandle(
                .began,
                x: 180,
                y: 220,
                renderer: gridRenderer,
                into: &state.measurements
            )
            measureHandle(
                .moved,
                x: 260,
                y: 300,
                renderer: gridRenderer,
                into: &state.measurements
            )
            measureHandle(
                .ended,
                x: 260,
                y: 300,
                renderer: gridRenderer,
                into: &state.measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            state.artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )

        case .cancelPreservesCanonical:
            measureHandle(
                .began,
                x: 180,
                y: 180,
                renderer: gridRenderer,
                into: &state.measurements
            )
            measureHandle(
                .ended,
                x: 220,
                y: 180,
                renderer: gridRenderer,
                into: &state.measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try finishCommit(
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            let beforeTexture = try gridRenderer.copyCanonicalForHarness()
            state.canonicalBefore = textureBytes(beforeTexture)
            state.revisionStart = gridRenderer.harnessRevision.rawValue

            measureHandle(
                .began,
                x: 300,
                y: 300,
                renderer: gridRenderer,
                into: &state.measurements
            )
            measureHandle(
                .moved,
                x: 340,
                y: 320,
                renderer: gridRenderer,
                into: &state.measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
            measureHandle(
                .cancelled,
                x: 340,
                y: 320,
                renderer: gridRenderer,
                into: &state.measurements
            )
            state.artifacts.committedScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            state.artifacts.canonical = try gridRenderer.copyCanonicalForHarness()

        case .fiveHundredDabs:
            let start = CFAbsoluteTimeGetCurrent()
            state.measurements.pendingEventStart = start
            try gridRenderer.injectFiveHundredInteriorDabsIntoOneFrame()
            state.measurements.brushProcessingMilliseconds.append(
                elapsedMilliseconds(since: start)
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )

        case .longStroke:
            try replayLongZigzag(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureLive(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
            guard state.measurements.newInstanceCounts.last == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "late frame encoded \(state.measurements.newInstanceCounts.last ?? -1) instances instead of 0"
                )
            }
            let last = longZigzagPoint(index: 239)
            measureHandle(
                .ended,
                x: last.x,
                y: last.y,
                renderer: gridRenderer,
                into: &state.measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            state.artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
        case .generalizedGrid, .halfDropInterior, .halfDropEdge,
             .halfDropCorner, .brickTranspose:
            guard let input = Self.translationInput(for: program),
                  input.tiling == configuration.tiling,
                  gridRenderer.harnessTiling == configuration.tiling
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "translation program and renderer tiling disagree"
                )
            }
            let fragments = try gridRenderer.injectHarnessDab(
                at: input.center
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: fragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: input.center,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &state.fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            state.artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
            if input.capturesPhasedGridLines {
                state.artifacts.phasedGridScreen =
                    try capturePhasedGridDisplay(
                        scene: scene,
                        renderer: gridRenderer,
                        measurements: &state.measurements
                    )
                try validatePhasedGridLine(
                    scene: scene,
                    program: program,
                    texture: state.artifacts.phasedGridScreen!
                )
            }
            state.artifacts.oracle = TilingCoverageOracle.renderCanonical(
                footprint: .hardRound(
                    radius: GridCanvasContract.brushRadius
                ),
                brushToWorld: Affine2D(
                    xAxis: SIMD2(1, 0),
                    yAxis: SIMD2(0, 1),
                    translation: input.center.simd
                ),
                tileSize: configuration.pixelSize,
                tiling: configuration.tiling,
                supersampling: 1
            )
        case .mirrorX, .mirrorY, .mirrorXY,
             .rotationalGenerator, .rotationalFixedPoint,
             .rotationalOrientation, .largeFootprint,
             .asymmetricFootprint, .canonicalCoordinateContinuity,
             .brushLocalCoordinateContinuity:
            guard let input = Self.taskSevenInput(for: program),
                  input.diagnosticMode == configuration.diagnosticMode,
                  gridRenderer.harnessTiling == configuration.tiling
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "Task 7 program and renderer configuration disagree"
                )
            }
            state.taskSevenHarnessInput = input

            if input.diagnosticMode == .hardRound {
                state.taskSevenFragments = try gridRenderer.injectHarnessDab(
                    at: WorldPoint(input.brushToWorld.translation),
                    radius: input.radius
                )
                try Self.appendFragmentAudit(
                    sceneName: scene.name,
                    fragments: state.taskSevenFragments,
                    repeatedFragments: Self.repeatedFragments(
                        for: input.stampFootprint,
                        configuration: configuration
                    ),
                    into: &state.fragmentMeasurements
                )
                try flushPending(
                    scene: scene,
                    renderer: gridRenderer,
                    measurements: &state.measurements
                )
                state.artifacts.liveScreen = try captureDisplay(
                    scene: scene,
                    renderer: gridRenderer,
                    measurements: &state.measurements
                )
                try captureCommittedAndCanonical(
                    scene: scene,
                    renderer: gridRenderer,
                    artifacts: &state.artifacts,
                    measurements: &state.measurements
                )
            } else {
                guard let diagnosticWire = Self.diagnosticWire(
                    for: input.diagnosticMode
                ) else {
                    throw HarnessRunError.counterInvariant(
                        sceneName: scene.name,
                        message: "diagnostic program resolved to hard-round wire"
                    )
                }
                let frame = try gridRenderer
                    .renderDiagnosticFootprintForHarness(
                        footprint: input.stampFootprint,
                        radius: input.radius,
                        diagnosticMode: diagnosticWire,
                        width: scene.width,
                        height: scene.height
                    )
                state.taskSevenFragments = frame.fragments
                try Self.appendFragmentAudit(
                    sceneName: scene.name,
                    fragments: frame.fragments,
                    repeatedFragments: Self.repeatedFragments(
                        for: input.stampFootprint,
                        configuration: configuration
                    ),
                    into: &state.fragmentMeasurements
                )
                state.artifacts.liveScreen = frame.screen
                state.artifacts.canonical = frame.canonical
                state.artifacts.displayValidationCanonical =
                    frame.displayValidationCanonical
                state.artifacts.displayValidationScreen =
                    frame.displayValidationScreen
                state.artifacts.displayValidationGridLinesScreen =
                    frame.gridLinesScreen
                state.measurements.cpuEncodeMilliseconds.append(
                    frame.metrics.cpuEncodeMilliseconds
                )
                state.measurements.gpuMilliseconds.append(
                    frame.metrics.gpuMilliseconds
                )
                state.measurements.dabGPUMilliseconds.append(
                    frame.metrics.gpuMilliseconds
                )
                state.measurements.newInstanceCounts.append(
                    frame.fragments.count
                )
                state.measurements.totalStrokeInstanceCounts.append(
                    frame.fragments.count
                )
            }

            if input.requiresDistantCells,
               !state.taskSevenFragments.contains(where: {
                   abs($0.cell.column) > 1 || abs($0.cell.row) > 1
               })
            {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "large footprint did not cross beyond immediate neighbors"
                )
            }
            state.artifacts.oracle = TilingCoverageOracle.renderCanonical(
                footprint: input.oracleFootprint,
                brushToWorld: input.brushToWorld,
                tileSize: configuration.pixelSize,
                tiling: configuration.tiling,
                supersampling: 1
            )
        case .rectangularTile:
            let center = Self.taskEightRectangularCenter
            let fragments = try gridRenderer.injectHarnessDab(at: center)
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: fragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: center,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &state.fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            state.artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
            state.artifacts.oracle = TilingCoverageOracle.renderCanonical(
                footprint: .hardRound(
                    radius: GridCanvasContract.brushRadius
                ),
                brushToWorld: Affine2D(
                    xAxis: SIMD2(1, 0),
                    yAxis: SIMD2(0, 1),
                    translation: center.simd
                ),
                tileSize: configuration.pixelSize,
                tiling: configuration.tiling,
                supersampling: 1
            )
        case .noncentralVisibleCell:
            let input = Self.taskEightNoncentralInput(
                for: configuration
            )
            guard input.tileSize == configuration.pixelSize else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "noncentral input tile does not match scene tile"
                )
            }

            let centralFragments = try gridRenderer.injectHarnessDab(
                at: input.central
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: centralFragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: input.central,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &state.fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try finishCommit(
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            state.artifacts.committedScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            let centralCanonical =
                try gridRenderer.copyCanonicalForHarness()
            state.artifacts.canonical = centralCanonical
            if configuration.tiling.isSquare {
                state.artifacts.oracle =
                    TilingCoverageOracle.renderCanonical(
                        footprint: .hardRound(
                            radius: GridCanvasContract.brushRadius
                        ),
                        brushToWorld: Affine2D(
                            xAxis: SIMD2(1, 0),
                            yAxis: SIMD2(0, 1),
                            translation: input.central.simd
                        ),
                        configuration:
                            configuration.periodicConfiguration,
                        canonicalRasterSize: configuration.pixelSize,
                        supersampling: 1,
                        coverageSymmetry: .halfTurnInvariant
                    )
            }

            let visibleRenderer = try makeGridRenderer(
                scene: scene,
                configuration: configuration
            )
            var visibleMeasurements = GridMeasurements()
            let visibleFragments = try visibleRenderer.injectHarnessDab(
                at: input.visible
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: visibleFragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: input.visible,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &state.fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: visibleRenderer,
                measurements: &visibleMeasurements
            )
            try finishCommit(
                renderer: visibleRenderer,
                measurements: &visibleMeasurements
            )
            let visibleCanonical =
                try visibleRenderer.copyCanonicalForHarness()
            state.visibleCellCanonicalByteDelta = Self.differingByteCount(
                textureBytes(centralCanonical),
                textureBytes(visibleCanonical)
            )

            guard visibleFragments.contains(where: {
                $0.cell == input.visibleCell
            }) else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "noncentral stroke did not project through approved visible cell"
                )
            }
            if configuration.tiling == .rotational {
                try validateRotationalVisibleCellPair(
                    scene: scene,
                    fragments: centralFragments,
                    expectedCell: CellIndex(column: 0, row: 0)
                )
                try validateRotationalVisibleCellPair(
                    scene: scene,
                    fragments: visibleFragments,
                    expectedCell: input.visibleCell
                )
            } else if configuration.tiling.isSquare {
                let expectedImageCount =
                    configuration.tiling == .squareRotation ? 4 : 8
                try validateSquareVisibleCellOrbit(
                    scene: scene,
                    fragments: centralFragments,
                    expectedCell: CellIndex(column: 0, row: 0),
                    expectedImageCount: expectedImageCount
                )
                try validateSquareVisibleCellOrbit(
                    scene: scene,
                    fragments: visibleFragments,
                    expectedCell: input.visibleCell,
                    expectedImageCount: expectedImageCount
                )
            }
        case .squareFixedPoint:
            guard configuration.tiling.isSquare else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "square fixed-point program requires a square preset"
                )
            }
            let strategy = configuration.makeStrategy()
            let basis = strategy.compiledSymmetry.domain.periodic!
                .translationBasis
            let center = basis.origin + (basis.u + basis.v) * 0.5
            state.taskSevenFragments = try gridRenderer.injectHarnessDab(
                at: WorldPoint(center),
                radius: GridCanvasContract.brushRadius,
                coverageSymmetry: .rotationAndReflectionInvariant
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: state.taskSevenFragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: WorldPoint(center),
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration,
                    coverageSymmetry: .rotationAndReflectionInvariant
                ),
                into: &state.fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            state.artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
            state.artifacts.oracle = TilingCoverageOracle.renderCanonical(
                footprint: .hardRound(
                    radius: GridCanvasContract.brushRadius
                ),
                brushToWorld: Affine2D(
                    xAxis: SIMD2(1, 0),
                    yAxis: SIMD2(0, 1),
                    translation: center
                ),
                configuration: configuration.periodicConfiguration,
                canonicalRasterSize: configuration.pixelSize,
                supersampling: 1,
                coverageSymmetry: .rotationAndReflectionInvariant
            )
        case .metadataTilingSwitch:
            let fragments = try gridRenderer.injectHarnessDab(
                at: Self.taskEightMetadataCenter
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: fragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: Self.taskEightMetadataCenter,
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &state.fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try finishCommit(
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            let beforeCanonical =
                try gridRenderer.copyCanonicalForHarness()
            state.canonicalBefore = textureBytes(beforeCanonical)
            state.revisionStart = gridRenderer.harnessRevision.rawValue
            let beforeScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )

            let activeProbe = gridRenderer.viewport.worldToScreen(
                WorldPoint(x: 96, y: 96)
            )
            let activeToken = RendererOperationToken(rawValue: UInt64.max)
            try gridRenderer.beginStroke(
                token: activeToken,
                sample: .mouse(
                    position: activeProbe,
                    timestamp: 0,
                    phase: .began
                ),
                style: Self.defaultStrokeStyle
            )
            let rejectedState =
                gridRenderer.harnessTilingMutationSnapshot
            do {
                try gridRenderer.setTiling(.brick)
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "active-stroke tiling change unexpectedly succeeded"
                )
            } catch MetalRendererError.tilingChangeRequiresIdle {
                guard gridRenderer.harnessTiling == .grid,
                      gridRenderer.harnessTilingMutationSnapshot
                        == rejectedState
                else {
                    throw HarnessRunError.counterInvariant(
                        sceneName: scene.name,
                        message: "rejected tiling change mutated renderer state"
                    )
                }
            }
            try gridRenderer.cancelStroke(token: activeToken)
            let unchangedState =
                gridRenderer.harnessTilingMutationSnapshot

            try gridRenderer.setTiling(.mirrorXY)
            guard gridRenderer.harnessTilingMutationSnapshot
                    == unchangedState
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "tiling switch changed resources, live state, counters, or revision"
                )
            }
            let alternateScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            let changedDisplayBytes = Self.differingByteCount(
                textureBytes(beforeScreen),
                textureBytes(alternateScreen)
            )
            guard changedDisplayBytes > 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "mirrorXY switch did not change any display byte"
                )
            }

            try gridRenderer.setTiling(.grid)
            guard gridRenderer.harnessTilingMutationSnapshot
                    == unchangedState
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "restoring tiling changed resources, live state, counters, or revision"
                )
            }
            let restoredScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            state.restoredDisplayMaximumDelta = Self.maximumByteDelta(
                textureBytes(beforeScreen),
                textureBytes(restoredScreen)
            )
            state.artifacts.initialTilingScreen = beforeScreen
            state.artifacts.alternateTilingScreen = alternateScreen
            state.artifacts.restoredTilingScreen = restoredScreen
            state.artifacts.committedScreen = restoredScreen
            state.artifacts.canonical =
                try gridRenderer.copyCanonicalForHarness()
        case .projectedLiveCommit:
            let points = Self.taskEightLiveCommitPoints
            let auditedFragmentCount =
                try Self.auditInterpolatedHardRoundStroke(
                    sceneName: scene.name,
                    points: points,
                    configuration: configuration,
                    into: &state.fragmentMeasurements
                )
            measureHandle(
                .began,
                world: points[0],
                renderer: gridRenderer,
                into: &state.measurements
            )
            measureHandle(
                .ended,
                world: points[1],
                renderer: gridRenderer,
                into: &state.measurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            state.artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
            state.previewCommitViolationCount =
                Self.previewCommitViolationCount(
                    textureBytes(state.artifacts.liveScreen!),
                    textureBytes(state.artifacts.committedScreen!),
                    tolerance: 1
                )
            guard
                state.measurements.newInstanceCounts.reduce(0, +)
                    == auditedFragmentCount
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "interactive projected-instance count disagrees with deterministic projection audit"
                )
            }
        case .projectedLongStroke:
            let points = Self.taskEightLongStrokePoints
            guard points.count
                    == BenchmarkLongStrokeMetrics.segmentCount + 1
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "long-stroke program does not contain exactly 400 segments"
                )
            }
            for (index, pair) in zip(
                points,
                points.dropFirst()
            ).enumerated() {
                guard pair.0.y == pair.1.y,
                      abs(pair.1.x - pair.0.x) == 32
                else {
                    throw HarnessRunError.counterInvariant(
                        sceneName: scene.name,
                        message: "long-stroke segment \(index) is not an exact horizontal 32-pixel segment"
                    )
                }
            }

            var processingStart = CFAbsoluteTimeGetCurrent()
            var fragments =
                try gridRenderer.beginFixedProjectedStrokeForHarness(
                    at: points[0]
                )
            state.measurements.brushProcessingMilliseconds.append(
                elapsedMilliseconds(since: processingStart)
            )
            try Self.appendFragmentAudit(
                sceneName: scene.name,
                fragments: fragments,
                repeatedFragments: Self.hardRoundFragments(
                    at: points[0],
                    radius: GridCanvasContract.brushRadius,
                    configuration: configuration
                ),
                into: &state.fragmentMeasurements
            )
            try flushPending(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )

            for point in points.dropFirst() {
                let frameResult = try Self
                    .performLongStrokeProductionThenAudit(
                        production: {
                            processingStart = CFAbsoluteTimeGetCurrent()
                            state.measurements.pendingEventStart =
                                processingStart
                            let producedFragments =
                                try gridRenderer
                                    .appendFixedProjectedSegmentForHarness(
                                        to: point
                                    )
                            state.measurements.brushProcessingMilliseconds.append(
                                elapsedMilliseconds(
                                    since: processingStart
                                )
                            )
                            let flushResult = try flushPending(
                                scene: scene,
                                renderer: gridRenderer,
                                measurements: &state.measurements,
                                recordsLongStrokeFrame: true
                            )
                            return (
                                value: producedFragments,
                                measurement: flushResult
                            )
                        },
                        audit: { producedFragments in
                            try Self.appendFragmentAudit(
                                sceneName: scene.name,
                                fragments: producedFragments,
                                repeatedFragments:
                                    Self.hardRoundFragments(
                                        at: point,
                                        radius:
                                            GridCanvasContract.brushRadius,
                                        configuration: configuration
                                    ),
                                into: &state.fragmentMeasurements
                            )
                        }
                    )
                fragments = frameResult.value
            }
            try gridRenderer.endFixedProjectedStrokeForHarness()
            state.artifacts.liveScreen = try captureDisplay(
                scene: scene,
                renderer: gridRenderer,
                measurements: &state.measurements
            )
            try captureCommittedAndCanonical(
                scene: scene,
                renderer: gridRenderer,
                artifacts: &state.artifacts,
                measurements: &state.measurements
            )
        case .coloredDraw, .eraserLiveCommit, .regionUndoSeam,
             .clearUndo, .tilingUndo, .resizeCropFill:
            throw HarnessSceneError.programUnavailableForSchema(
                program: program,
                schemaVersion: scene.schemaVersion
            )
        }

    }

    private func finishGridRun(
        scene: HarnessScene,
        program: TilingHarnessProgram,
        configuration: HarnessRenderConfiguration,
        renderer gridRenderer: GridRenderer,
        state: GridProgramState,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        let measurements = state.measurements
        var artifacts = state.artifacts
        let revisionStart = state.revisionStart
        let canonicalBefore = state.canonicalBefore
        let taskSevenHarnessInput = state.taskSevenHarnessInput
        let taskSevenFragments = state.taskSevenFragments
        let visibleCellCanonicalByteDelta =
            state.visibleCellCanonicalByteDelta
        let restoredDisplayMaximumDelta =
            state.restoredDisplayMaximumDelta
        let previewCommitViolationCount =
            state.previewCommitViolationCount
        let fragmentMeasurements = state.fragmentMeasurements

        let oracleComparison: CoverageComparison?
        let transformMismatchCount: Int?
        let duplicateFixedPointWrites: Int?
        let coordinateContinuityMismatches: Int?
        let productionCanonicalBytes = artifacts.canonical.map(textureBytes)
        let validatesTaskSevenDisplay: Bool
        switch program {
        case .mirrorX, .mirrorY, .mirrorXY, .rotationalGenerator:
            validatesTaskSevenDisplay = true
        default:
            validatesTaskSevenDisplay = false
        }
        var displaySemanticMismatchCount: Int
        if validatesTaskSevenDisplay {
            guard
                let validationCanonical =
                    artifacts.displayValidationCanonical,
                let validationScreen = artifacts.displayValidationScreen,
                let validationGridLines =
                    artifacts.displayValidationGridLinesScreen
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "Task 7 display validation textures are missing"
                )
            }
            let screenSize = PixelSize(
                width: scene.width,
                height: scene.height
            )
            let canonicalBytes = textureBytes(validationCanonical)
            let screenBytes = textureBytes(validationScreen)
            let gridLineBytes = textureBytes(validationGridLines)
            displaySemanticMismatchCount =
                Self.displayFoldMismatchCount(
                    productionScreenBGRA: screenBytes,
                    canonicalBGRA: canonicalBytes,
                    screenSize: screenSize,
                    tileSize: configuration.pixelSize,
                    tiling: configuration.tiling
                )
                + Self.gridLineLatticeMismatchCount(
                    productionGridBGRA: gridLineBytes,
                    productionBaseBGRA: screenBytes,
                    screenSize: screenSize,
                    tileSize: configuration.pixelSize
                )
            if program == .rotationalGenerator,
               let input = taskSevenHarnessInput
            {
                displaySemanticMismatchCount +=
                    Self.displayProbeMismatchCount(
                        productionScreenBGRA: screenBytes,
                        canonicalBGRA: canonicalBytes,
                        screenSize: screenSize,
                        tileSize: configuration.pixelSize,
                        tiling: configuration.tiling,
                        worldPoints:
                            Self.rotationalGeneratorWorldProbes(
                                input: input,
                                tileSize: configuration.pixelSize
                            )
                    )
            }
        } else {
            displaySemanticMismatchCount = 0
        }
        if let oracle = artifacts.oracle,
           let canonicalBytes = productionCanonicalBytes
        {
            let actualCoverage = Self.productionCoverage(
                fromBGRA: canonicalBytes,
                pixelSize: oracle.coverage.pixelSize
            )
            let comparison = TilingCoverageOracle.compare(
                expected: oracle.coverage,
                actual: actualCoverage,
                boundaryTolerance: 1
            )
            oracleComparison = comparison
            let mismatchCount = zip(
                oracle.coverage.bytes,
                actualCoverage.bytes
            ).reduce(0) {
                $0 + ($1.0 == $1.1 ? 0 : 1)
            }
            if let input = taskSevenHarnessInput,
               input.diagnosticMode != .hardRound
            {
                transformMismatchCount =
                    Self.independentTransformMismatchCount(
                        fragments: taskSevenFragments,
                        brushToWorld: input.brushToWorld,
                        tileSize: oracle.coverage.pixelSize,
                        tiling: configuration.tiling
                    ) + mismatchCount + displaySemanticMismatchCount
            } else {
                transformMismatchCount =
                    mismatchCount + displaySemanticMismatchCount
            }
            if program == .rotationalFixedPoint
                || program == .squareFixedPoint
            {
                duplicateFixedPointWrites =
                    Self.duplicateFixedPointWriteCount(
                        fragments: taskSevenFragments
                    )
            } else {
                duplicateFixedPointWrites = nil
            }
            switch configuration.diagnosticMode {
            case .canonicalCoordinates:
                coordinateContinuityMismatches =
                    Self.coordinateContinuityMismatchCount(
                        productionBGRA: canonicalBytes,
                        oracleBGRA: oracle.canonicalCoordinatesBGRA,
                        usesCircularRGDistance: true
                    )
            case .brushLocalCoordinates:
                coordinateContinuityMismatches =
                    Self.coordinateContinuityMismatchCount(
                        productionBGRA: canonicalBytes,
                        oracleBGRA: oracle.brushLocalCoordinatesBGRA,
                        usesCircularRGDistance: false
                    )
            case .hardRound, .asymmetricCoverage:
                coordinateContinuityMismatches = nil
            }
            artifacts.oracleMetrics = HarnessOracleMetrics(
                oracleHoleCount: comparison.holeCount,
                oraclePhantomCount: comparison.phantomCount,
                oracleMaximumDelta: Int(comparison.maximumDelta),
                transformMismatchCount: transformMismatchCount ?? 0,
                duplicateFixedPointWriteCount: duplicateFixedPointWrites,
                coordinateContinuityMismatchCount:
                    coordinateContinuityMismatches
            )
        } else {
            oracleComparison = nil
            transformMismatchCount = nil
            duplicateFixedPointWrites = nil
            coordinateContinuityMismatches = nil
        }

        let longStrokeMetrics: BenchmarkLongStrokeMetrics?
        if program == .projectedLongStroke {
            do {
                longStrokeMetrics =
                    try BenchmarkLongStrokeMetrics.measure(
                        cpuMilliseconds:
                            measurements.longStrokeCPUMilliseconds,
                        dabGPUMilliseconds:
                            measurements.longStrokeDabGPUMilliseconds,
                        projectedInstanceCounts:
                            measurements
                                .longStrokeProjectedInstanceCounts
                    )
            } catch {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: error.localizedDescription
                )
            }
        } else {
            longStrokeMetrics = nil
        }

        let revisionDelta = Int(
            gridRenderer.harnessRevision.rawValue - revisionStart
        )
        let previewCommitDelta = maximumByteDelta(
            artifacts.liveScreen,
            artifacts.committedScreen
        )
        let canonicalByteDelta: Int
        if let canonicalBefore, let canonical = artifacts.canonical {
            canonicalByteDelta = Self.differingByteCount(
                canonicalBefore,
                textureBytes(canonical)
            )
        } else {
            canonicalByteDelta = 0
        }

        let counters = gridRenderer.harnessCounters
        var structuralValues: [HarnessStructuralMetric: Int] = [
            .emittedDabCount: counters.totalDabsThisStroke,
            .encodedInstanceCount: measurements.newInstanceCounts.reduce(0, +),
            .restampedInstanceCount: measurements.restampedInstanceCount,
            .missedFrameCount: measurements.missedFrameCount,
        ]
        if artifacts.canonical != nil {
            structuralValues[.canonicalRevisionDelta] = revisionDelta
        }
        if artifacts.liveScreen != nil, artifacts.committedScreen != nil {
            structuralValues[.previewCommitMaximumDelta] = previewCommitDelta
        }
        if canonicalBefore != nil, artifacts.canonical != nil {
            structuralValues[.canonicalByteDelta] = canonicalByteDelta
        }
        if let oracleComparison {
            structuralValues[.oracleHoleCount] =
                oracleComparison.holeCount
            structuralValues[.oraclePhantomCount] =
                oracleComparison.phantomCount
            structuralValues[.oracleMaximumDelta] =
                Int(oracleComparison.maximumDelta)
        }
        if let transformMismatchCount {
            structuralValues[.transformMismatchCount] =
                transformMismatchCount
        }
        if let duplicateFixedPointWrites {
            structuralValues[.duplicateFixedPointWriteCount] =
                duplicateFixedPointWrites
        }
        if let coordinateContinuityMismatches {
            structuralValues[.coordinateContinuityMismatchCount] =
                coordinateContinuityMismatches
        }
        if let visibleCellCanonicalByteDelta {
            structuralValues[.visibleCellCanonicalByteDelta] =
                visibleCellCanonicalByteDelta
        }
        if let restoredDisplayMaximumDelta {
            structuralValues[.restoredDisplayMaximumDelta] =
                restoredDisplayMaximumDelta
        }
        if let previewCommitViolationCount {
            structuralValues[.previewCommitViolationCount] =
                previewCommitViolationCount
        }

        guard
            scene.schemaVersion != 3
                || fragmentMeasurements.totalProjectedFragmentCount > 0
        else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "projected-fragment metrics are unavailable"
            )
        }

        let processInfo = ProcessInfo.processInfo
        let record = BenchmarkRecord(
            schemaVersion: scene.schemaVersion == 3 ? 3 : 2,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: gridRenderer.device.name,
                logicalProcessorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            ),
            operatingSystem: processInfo.operatingSystemVersionString,
            build: build,
            frameCount: measurements.newInstanceCounts.count,
            cpuEncodeMilliseconds: measurements.cpuEncodeMilliseconds,
            gpuMilliseconds: measurements.gpuMilliseconds,
            peakResidentBytes: try Self.peakResidentBytes(),
            brushProcessingMilliseconds:
                measurements.brushProcessingMilliseconds,
            eventToSubmitMilliseconds:
                measurements.eventToSubmitMilliseconds,
            dabGPUMilliseconds: measurements.dabGPUMilliseconds,
            gridGPUMilliseconds: measurements.gridGPUMilliseconds,
            commitGPUMilliseconds: measurements.commitGPUMilliseconds,
            commitPendingMilliseconds:
                measurements.commitPendingMilliseconds,
            displayFrameBudgetMilliseconds:
                measurements.displayFrameBudgetMilliseconds,
            newInstanceCounts: measurements.newInstanceCounts,
            totalStrokeInstanceCounts:
                measurements.totalStrokeInstanceCounts,
            missedFrameCount: measurements.missedFrameCount,
            tilingRawValue: scene.schemaVersion == 3
                ? configuration.tiling.rawValue
                : nil,
            tileWidth: scene.schemaVersion == 3
                ? configuration.pixelSize.width
                : nil,
            tileHeight: scene.schemaVersion == 3
                ? configuration.pixelSize.height
                : nil,
            totalProjectedFragmentCount: scene.schemaVersion == 3
                ? fragmentMeasurements.totalProjectedFragmentCount
                : nil,
            maximumFragmentsPerFootprint: scene.schemaVersion == 3
                ? fragmentMeasurements.maximumFragmentsPerFootprint
                : nil,
            totalInstanceBytes: scene.schemaVersion == 3
                ? fragmentMeasurements.totalInstanceBytes
                : nil,
            oracleHoleCount: oracleComparison?.holeCount,
            oraclePhantomCount: oracleComparison?.phantomCount,
            oracleMaximumDelta: oracleComparison.map {
                Int($0.maximumDelta)
            },
            diagnosticMode: scene.schemaVersion == 3
                ? configuration.diagnosticMode.rawValue
                : nil,
            longStrokeEarlyCPUP95Milliseconds:
                longStrokeMetrics?.earlyCPUP95Milliseconds,
            longStrokeLateCPUP95Milliseconds:
                longStrokeMetrics?.lateCPUP95Milliseconds,
            longStrokeEarlyDabGPUP95Milliseconds:
                longStrokeMetrics?.earlyDabGPUP95Milliseconds,
            longStrokeLateDabGPUP95Milliseconds:
                longStrokeMetrics?.lateDabGPUP95Milliseconds,
            longStrokeCPUMillisecondsPerFrameSlope:
                longStrokeMetrics?.cpuMillisecondsPerFrameSlope,
            longStrokeDabGPUMillisecondsPerFrameSlope:
                longStrokeMetrics?.dabGPUMillisecondsPerFrameSlope
        )

        let emitted = try writeGridArtifacts(
            scene: scene,
            artifacts: artifacts,
            record: record,
            outputDirectory: outputDirectory
        )
        try validateCoreTaskNineInvariants(
            scene: scene,
            program: program,
            measurements: measurements,
            fragmentMeasurements: fragmentMeasurements,
            oracleComparison: oracleComparison,
            revisionDelta: revisionDelta,
            canonicalByteDelta: canonicalByteDelta,
            restoredDisplayMaximumDelta: restoredDisplayMaximumDelta,
            previewCommitViolationCount: previewCommitViolationCount,
            longStrokeMetrics: longStrokeMetrics,
            structuralValues: structuralValues,
            tiling: configuration.tiling
        )
        try evaluatePixelChecks(
            scene: scene,
            artifacts: artifacts
        )
        try Self.evaluateStructuralChecks(
            scene: scene,
            values: structuralValues
        )

        return HarnessRunResult(
            imageURL: emitted.primaryImageURL,
            benchmarkURL: emitted.benchmarkURL,
            benchmark: record,
            artifactURLs: emitted.artifactURLs
        )
    }

    private func measureHandle(
        _ phase: StrokePhase,
        x: Float,
        y: Float,
        renderer: GridRenderer,
        into measurements: inout GridMeasurements
    ) {
        let start = CFAbsoluteTimeGetCurrent()
        if phase == .began {
            measurements.encodedInstanceHighWater = 0
        }
        if measurements.pendingEventStart == nil {
            measurements.pendingEventStart = start
        }
        let sample = StrokeSample.mouse(
            position: ScreenPoint(x: x, y: y),
            timestamp: measurements.timestamp,
            phase: phase
        )
        do {
            switch phase {
            case .began:
                let token = RendererOperationToken(
                    rawValue: measurements.nextOperationRawValue
                )
                measurements.nextOperationRawValue &+= 1
                try renderer.beginStroke(
                    token: token,
                    sample: sample,
                    style: Self.defaultStrokeStyle
                )
                measurements.activeOperationToken = token
            case .moved:
                guard let token = measurements.activeOperationToken else {
                    preconditionFailure(
                        "Harness move requires an active renderer token."
                    )
                }
                try renderer.appendStroke(token: token, sample: sample)
            case .ended:
                guard let token = measurements.activeOperationToken else {
                    preconditionFailure(
                        "Harness end requires an active renderer token."
                    )
                }
                try renderer.requestStrokeCommit(
                    token: token,
                    sample: sample,
                    maximumRetainedBytes: 200 * 1_024 * 1_024
                )
                measurements.activeOperationToken = nil
            case .cancelled:
                guard let token = measurements.activeOperationToken else {
                    preconditionFailure(
                        "Harness cancel requires an active renderer token."
                    )
                }
                try renderer.cancelStroke(token: token)
                measurements.activeOperationToken = nil
            }
        } catch {
            preconditionFailure(
                "Harness renderer input failed: \(error.localizedDescription)"
            )
        }
        measurements.timestamp += 1.0 / 120.0
        measurements.brushProcessingMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
    }

    private func measureHandle(
        _ phase: StrokePhase,
        world: WorldPoint,
        renderer: GridRenderer,
        into measurements: inout GridMeasurements
    ) {
        let screen = renderer.viewport.worldToScreen(world)
        measureHandle(
            phase,
            x: screen.x,
            y: screen.y,
            renderer: renderer,
            into: &measurements
        )
    }

    private func makeGridRenderer(
        scene: HarnessScene,
        configuration: HarnessRenderConfiguration
    ) throws -> GridRenderer {
        try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(
                width: Float(scene.width),
                height: Float(scene.height)
            ),
            configuration: TilingCanvasConfiguration(
                pixelSize: configuration.pixelSize,
                periodicConfiguration: configuration.periodicConfiguration
            )
        )
    }

    private func validateRotationalVisibleCellPair(
        scene: HarnessScene,
        fragments: [CellFragment],
        expectedCell: CellIndex
    ) throws {
        let ordinals = Set(
            fragments.lazy
                .filter { $0.cell == expectedCell }
                .map(\.imageOrdinal)
        )
        guard ordinals == Set([UInt8(0), UInt8(1)]) else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "rotational visible cell \(expectedCell.column),\(expectedCell.row) did not contain the p2 image pair"
            )
        }
    }

    private func validateSquareVisibleCellOrbit(
        scene: HarnessScene,
        fragments: [CellFragment],
        expectedCell: CellIndex,
        expectedImageCount: Int
    ) throws {
        let ordinals = Set(
            fragments.lazy
                .filter { $0.cell == expectedCell }
                .map(\.imageOrdinal)
        )
        let expectedOrdinals = Set(
            (0..<expectedImageCount).map(UInt8.init)
        )
        guard ordinals == expectedOrdinals else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "square visible cell \(expectedCell.column),\(expectedCell.row) did not contain the complete \(expectedImageCount)-image orbit"
            )
        }
    }

    @discardableResult
    private func flushPending(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements,
        recordsLongStrokeFrame: Bool = false
    ) throws -> HarnessLiveFlushResult {
        let submitStart = measurements.pendingEventStart
            ?? CFAbsoluteTimeGetCurrent()
        let eventProcessingMilliseconds = elapsedMilliseconds(
            since: submitStart
        )
        let flushResult = try renderer.flushPendingLiveForHarness()
        let metrics = flushResult.metrics
        let submitMilliseconds = HarnessSubmissionTiming
            .eventToSubmitMilliseconds(
                eventProcessingMilliseconds: eventProcessingMilliseconds,
                flushThroughSubmissionMilliseconds:
                    metrics.cpuEncodeMilliseconds
            )
        let counters = renderer.harnessCounters
        let identityAudit = try Self.auditEncodedInstanceIdentityRanges(
            sceneName: scene.name,
            previousEncodedHighWater:
                measurements.encodedInstanceHighWater,
            emittedHighWater: flushResult.emittedHighWater,
            encodedIdentityRanges: flushResult.encodedIdentityRanges
        )

        guard counters.newInstancesThisFrame <=
                GridCanvasContract.pendingCapacity
        else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "frame encoded \(counters.newInstancesThisFrame) instances beyond the fixed \(GridCanvasContract.pendingCapacity) bound"
            )
        }

        guard counters.newInstancesThisFrame
                == identityAudit.newlyEncodedInstanceCount
        else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "encoded projected-instance counter disagrees with encoded identity range"
            )
        }
        measurements.restampedInstanceCount +=
            identityAudit.restampedInstanceCount
        measurements.newInstanceCounts.append(
            counters.newInstancesThisFrame
        )
        measurements.totalStrokeInstanceCounts.append(
            counters.totalInstancesThisStroke
        )
        measurements.encodedInstanceHighWater =
            identityAudit.encodedHighWater
        measurements.eventToSubmitMilliseconds.append(submitMilliseconds)
        measurements.cpuEncodeMilliseconds.append(
            metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(metrics.gpuMilliseconds)
        measurements.dabGPUMilliseconds.append(metrics.gpuMilliseconds)
        if recordsLongStrokeFrame {
            measurements.longStrokeCPUMilliseconds.append(
                submitMilliseconds
            )
            measurements.longStrokeDabGPUMilliseconds.append(
                metrics.gpuMilliseconds
            )
            measurements.longStrokeProjectedInstanceCounts.append(
                counters.newInstancesThisFrame
            )
        }
        if submitMilliseconds >
            measurements.displayFrameBudgetMilliseconds
        {
            measurements.missedFrameCount += 1
        }
        measurements.pendingEventStart = nil
        return flushResult
    }

    private func captureLive(
        scene: HarnessScene,
        renderer: GridRenderer,
        artifacts: inout GridArtifacts,
        measurements: inout GridMeasurements
    ) throws {
        try flushPending(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        artifacts.liveScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
    }

    private func captureDisplay(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws -> any MTLTexture {
        let frame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: false
        )
        measurements.cpuEncodeMilliseconds.append(
            frame.metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(frame.metrics.gpuMilliseconds)
        measurements.gridGPUMilliseconds.append(frame.metrics.gpuMilliseconds)
        return frame.texture
    }

    private func capturePhasedGridDisplay(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws -> any MTLTexture {
        let frame = try renderer.renderOffscreenDisplayForHarness(
            width: scene.width,
            height: scene.height,
            showGridLines: true
        )
        measurements.cpuEncodeMilliseconds.append(
            frame.metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(frame.metrics.gpuMilliseconds)
        measurements.gridGPUMilliseconds.append(frame.metrics.gpuMilliseconds)
        return frame.texture
    }

    private func validatePhasedGridLine(
        scene: HarnessScene,
        program: TilingHarnessProgram,
        texture: any MTLTexture
    ) throws {
        let world: WorldPoint
        switch program {
        case .halfDropInterior, .halfDropCorner:
            world = WorldPoint(x: 300, y: 96)
        case .halfDropEdge:
            world = WorldPoint(x: 300, y: 288)
        case .brickTranspose:
            world = WorldPoint(x: 144, y: 300)
        default:
            return
        }
        let configuration = Self.configuration(for: scene)
        let viewport = ViewportTransform(
            drawableSize: PatternSize(
                width: Float(scene.width),
                height: Float(scene.height)
            ),
            worldCenter: WorldPoint(
                x: Float(configuration.pixelSize.width) * 0.5,
                y: Float(configuration.pixelSize.height) * 0.5
            )
        )
        let screen = viewport.worldToScreen(world)
        let x = Int(screen.x)
        let y = Int(screen.y)
        let line = PNGWriter.pixel(in: texture, x: x, y: y)
        let offLine = PNGWriter.pixel(
            in: texture,
            x: min(texture.width - 1, x + 4),
            y: min(texture.height - 1, y + 4)
        )
        let lineIsVisible = Self.isPhasedGridLineVisible(
            line: line,
            offLine: offLine
        )
        guard lineIsVisible else {
            throw HarnessRunError.tilingPixelMismatch(
                sceneName: scene.name,
                tiling: configuration.tiling,
                cell: nil,
                channel: .committedScreen,
                x: x,
                y: y,
                expected: [199, 202, 198, 255],
                actual: [line.x, line.y, line.z, line.w],
                tolerance: 5
            )
        }
    }

    private func finishCommit(
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws {
        let start = CFAbsoluteTimeGetCurrent()
        let metrics = try renderer.finishCommitForHarness()
        measurements.commitPendingMilliseconds.append(
            elapsedMilliseconds(since: start)
        )
        measurements.cpuEncodeMilliseconds.append(
            metrics.cpuEncodeMilliseconds
        )
        measurements.gpuMilliseconds.append(metrics.gpuMilliseconds)
        measurements.commitGPUMilliseconds.append(metrics.gpuMilliseconds)
    }

    private func captureCommittedAndCanonical(
        scene: HarnessScene,
        renderer: GridRenderer,
        artifacts: inout GridArtifacts,
        measurements: inout GridMeasurements
    ) throws {
        try finishCommit(
            renderer: renderer,
            measurements: &measurements
        )
        artifacts.committedScreen = try captureDisplay(
            scene: scene,
            renderer: renderer,
            measurements: &measurements
        )
        artifacts.canonical = try renderer.copyCanonicalForHarness()
    }

    private func replayLongZigzag(
        scene: HarnessScene,
        renderer: GridRenderer,
        measurements: inout GridMeasurements
    ) throws {
        measureHandle(
            .began,
            x: 48,
            y: 48,
            renderer: renderer,
            into: &measurements
        )
        for index in 0..<240 {
            let point = longZigzagPoint(index: index)
            measureHandle(
                .moved,
                x: point.x,
                y: point.y,
                renderer: renderer,
                into: &measurements
            )
            try flushPending(
                scene: scene,
                renderer: renderer,
                measurements: &measurements
            )
        }
    }

    private func longZigzagPoint(index: Int) -> ScreenPoint {
        ScreenPoint(
            x: index.isMultiple(of: 2) ? 208 : 48,
            y: 48 + Float(index % 161)
        )
    }

    private func evaluatePixelChecks(
        scene: HarnessScene,
        artifacts: GridArtifacts
    ) throws {
        for check in scene.checks {
            let actual: SIMD4<UInt8>
            if let oracle = artifacts.oracleBGRA(for: check.channel) {
                guard
                    (0..<oracle.pixelSize.width).contains(check.x),
                    (0..<oracle.pixelSize.height).contains(check.y)
                else {
                    throw HarnessSceneError.invalidCheckCoordinate(
                        x: check.x,
                        y: check.y
                    )
                }
                let offset = (check.y * oracle.pixelSize.width + check.x) * 4
                actual = SIMD4(
                    oracle.bytes[offset],
                    oracle.bytes[offset + 1],
                    oracle.bytes[offset + 2],
                    oracle.bytes[offset + 3]
                )
            } else {
                guard let texture = artifacts.texture(for: check.channel) else {
                    throw HarnessRunError.missingArtifact(
                        sceneName: scene.name,
                        channel: check.channel
                    )
                }
                actual = try checkedPixel(in: texture, check: check)
            }
            let expected = SIMD4(
                check.expectedBGRA[0],
                check.expectedBGRA[1],
                check.expectedBGRA[2],
                check.expectedBGRA[3]
            )
            guard BlankCanvasContract.matches(
                actual: actual,
                expected: expected,
                tolerance: check.tolerance
            ) else {
                if scene.schemaVersion == 3, let tiling = scene.tiling {
                    throw HarnessRunError.tilingPixelMismatch(
                        sceneName: scene.name,
                        tiling: tiling,
                        cell: nil,
                        channel: check.channel,
                        x: check.x,
                        y: check.y,
                        expected: check.expectedBGRA,
                        actual: [actual.x, actual.y, actual.z, actual.w],
                        tolerance: check.tolerance
                    )
                } else {
                    throw HarnessRunError.gridPixelMismatch(
                        sceneName: scene.name,
                        channel: check.channel,
                        x: check.x,
                        y: check.y,
                        expected: check.expectedBGRA,
                        actual: [actual.x, actual.y, actual.z, actual.w],
                        tolerance: check.tolerance
                    )
                }
            }
        }
    }

    private func validateCoreTaskNineInvariants(
        scene: HarnessScene,
        program: TilingHarnessProgram,
        measurements: GridMeasurements,
        fragmentMeasurements: HarnessFragmentMeasurements,
        oracleComparison: CoverageComparison?,
        revisionDelta: Int,
        canonicalByteDelta: Int,
        restoredDisplayMaximumDelta: Int?,
        previewCommitViolationCount: Int?,
        longStrokeMetrics: BenchmarkLongStrokeMetrics?,
        structuralValues: [HarnessStructuralMetric: Int],
        tiling: TilingKind
    ) throws {
        guard scene.schemaVersion == 3 else {
            return
        }
        guard fragmentMeasurements.maximumClipPlaneCount <= 4 else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "a generated fragment exceeded four clip planes"
            )
        }
        guard measurements.restampedInstanceCount == 0 else {
            throw HarnessRunError.counterInvariant(
                sceneName: scene.name,
                message: "restamped \(measurements.restampedInstanceCount) old projected instances"
            )
        }
        if let primaryMetric = scene.structuralChecks.first?.metric {
            guard let actual = structuralValues[primaryMetric] else {
                throw HarnessRunError.missingStructuralMetric(
                    sceneName: scene.name,
                    metric: primaryMetric
                )
            }
            guard actual == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "primary correctness metric \(primaryMetric.rawValue) is \(actual) instead of 0"
                )
            }
        }

        let requiresOracle: Bool
        switch program {
        case .generalizedGrid, .halfDropInterior, .halfDropEdge,
             .halfDropCorner, .brickTranspose, .mirrorX, .mirrorY,
             .mirrorXY, .rotationalGenerator, .rotationalFixedPoint,
             .rotationalOrientation, .largeFootprint,
             .asymmetricFootprint, .canonicalCoordinateContinuity,
             .brushLocalCoordinateContinuity, .rectangularTile,
             .squareFixedPoint:
            requiresOracle = true
        case .noncentralVisibleCell:
            requiresOracle = tiling.isSquare
        default:
            requiresOracle = false
        }
        if requiresOracle {
            guard let oracleComparison else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "oracle metrics are unavailable"
                )
            }
            guard oracleComparison.holeCount == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "oracle reported \(oracleComparison.holeCount) holes"
                )
            }
            guard oracleComparison.phantomCount == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "oracle reported \(oracleComparison.phantomCount) phantoms"
                )
            }
            guard oracleComparison.maximumDelta <= 1 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "oracle maximum delta \(oracleComparison.maximumDelta) exceeds 1"
                )
            }
        }

        if program == .metadataTilingSwitch {
            guard canonicalByteDelta == 0, revisionDelta == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "tiling switch changed canonical bytes or revision"
                )
            }
            guard restoredDisplayMaximumDelta == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "restored tiling display did not match the initial display"
                )
            }
        }
        if program == .projectedLiveCommit {
            guard previewCommitViolationCount == 0 else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "preview/commit channels differed by more than 1"
                )
            }
        }
        if program == .projectedLongStroke {
            guard longStrokeMetrics != nil else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "long-stroke timing metrics are unavailable"
                )
            }
            guard
                measurements.longStrokeProjectedInstanceCounts.count
                    == BenchmarkLongStrokeMetrics.segmentCount
            else {
                throw HarnessRunError.counterInvariant(
                    sceneName: scene.name,
                    message: "long-stroke measured-frame count is not exactly 400"
                )
            }
        }
    }

    nonisolated static func evaluateStructuralChecks(
        scene: HarnessScene,
        values: [HarnessStructuralMetric: Int]
    ) throws {
        for check in scene.structuralChecks {
            guard let actual = values[check.metric] else {
                throw HarnessRunError.missingStructuralMetric(
                    sceneName: scene.name,
                    metric: check.metric
                )
            }
            let passed: Bool
            switch check.relation {
            case .equal:
                passed = actual == check.value
            case .lessThanOrEqual:
                passed = actual <= check.value
            case .greaterThanOrEqual:
                passed = actual >= check.value
            }
            guard passed else {
                if scene.schemaVersion == 3, let tiling = scene.tiling {
                    throw HarnessRunError.tilingStructuralMismatch(
                        sceneName: scene.name,
                        tiling: tiling,
                        cell: nil,
                        metric: check.metric,
                        expectedRelation: check.relation,
                        expectedValue: check.value,
                        actualValue: actual
                    )
                } else {
                    throw HarnessRunError.structuralMismatch(
                        sceneName: scene.name,
                        metric: check.metric,
                        expectedRelation: check.relation,
                        expectedValue: check.value,
                        actualValue: actual
                    )
                }
            }
        }
    }

    func checkedPixel(
        in texture: any MTLTexture,
        check: HarnessPixelCheck
    ) throws -> SIMD4<UInt8> {
        guard
            (0..<texture.width).contains(check.x),
            (0..<texture.height).contains(check.y)
        else {
            throw HarnessSceneError.invalidCheckCoordinate(
                x: check.x,
                y: check.y
            )
        }
        return PNGWriter.pixel(in: texture, x: check.x, y: check.y)
    }

    private func writeGridArtifacts(
        scene: HarnessScene,
        artifacts: GridArtifacts,
        record: BenchmarkRecord,
        outputDirectory: URL
    ) throws -> (
        primaryImageURL: URL,
        benchmarkURL: URL,
        artifactURLs: [URL]
    ) {
        var artifactURLs: [URL] = []
        var liveURL: URL?
        var committedURL: URL?
        var restoredTilingURL: URL?

        if let texture = artifacts.liveScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).live.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            liveURL = url
            artifactURLs.append(url)
        }
        if let texture = artifacts.committedScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).committed.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            committedURL = url
            artifactURLs.append(url)
        }
        if let texture = artifacts.canonical {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).canonical.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.initialTilingScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).initial-tiling.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.alternateTilingScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).alternate-tiling.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.restoredTilingScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).restored-tiling.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            restoredTilingURL = url
            artifactURLs.append(url)
        }
        if let texture = artifacts.phasedGridScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).grid-lines.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.displayValidationCanonical {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).display-validation.canonical.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.displayValidationScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).display-validation.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let texture = artifacts.displayValidationGridLinesScreen {
            let url = outputDirectory.appendingPathComponent(
                "\(scene.name).display-validation.grid-lines.screen.png"
            )
            try PNGWriter.write(texture: texture, to: url)
            artifactURLs.append(url)
        }
        if let oracle = artifacts.oracle {
            let coverageURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.coverage.png"
            )
            try PNGWriter.write(
                coverage: oracle.coverage,
                to: coverageURL
            )
            artifactURLs.append(coverageURL)

            let canonicalURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.canonical-coordinates.png"
            )
            try PNGWriter.writeBGRA(
                oracle.canonicalCoordinatesBGRA,
                pixelSize: oracle.coverage.pixelSize,
                to: canonicalURL
            )
            artifactURLs.append(canonicalURL)

            let brushLocalURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.brush-local-coordinates.png"
            )
            try PNGWriter.writeBGRA(
                oracle.brushLocalCoordinatesBGRA,
                pixelSize: oracle.coverage.pixelSize,
                to: brushLocalURL
            )
            artifactURLs.append(brushLocalURL)
        }
        if let oracleMetrics = artifacts.oracleMetrics {
            let metricsURL = outputDirectory.appendingPathComponent(
                "\(scene.name).oracle.metrics.json"
            )
            try HarnessOracleMetrics.encode(oracleMetrics).write(
                to: metricsURL,
                options: .atomic
            )
            artifactURLs.append(metricsURL)
        }

        let benchmarkURL = outputDirectory.appendingPathComponent(
            "\(scene.name).benchmark.json"
        )
        try BenchmarkRecord.encode(record).write(
            to: benchmarkURL,
            options: .atomic
        )
        artifactURLs.append(benchmarkURL)

        guard let primaryImageURL =
                restoredTilingURL ?? committedURL ?? liveURL
        else {
            throw HarnessRunError.missingArtifact(
                sceneName: scene.name,
                channel: .screen
            )
        }
        return (primaryImageURL, benchmarkURL, artifactURLs)
    }

    private func maximumByteDelta(
        _ lhsTexture: (any MTLTexture)?,
        _ rhsTexture: (any MTLTexture)?
    ) -> Int {
        guard let lhsTexture, let rhsTexture else {
            return 0
        }
        let lhs = textureBytes(lhsTexture)
        let rhs = textureBytes(rhsTexture)
        guard lhs.count == rhs.count else {
            return 255
        }
        return zip(lhs, rhs).reduce(0) {
            max($0, abs(Int($1.0) - Int($1.1)))
        }
    }

    private func textureBytes(_ texture: any MTLTexture) -> [UInt8] {
        precondition(texture.pixelFormat == .bgra8Unorm)
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * texture.height
        )
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(
                    0,
                    0,
                    texture.width,
                    texture.height
                ),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    private func elapsedMilliseconds(
        since start: CFAbsoluteTime
    ) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    static func peakResidentBytes() throws -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
            throw HarnessRunError.processMetricsUnavailable
        }
        return UInt64(usage.ru_maxrss)
    }
}
